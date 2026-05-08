##
## WebUI HTTP Server Module
## Serves static files from the "static" directory
## Runs in a separate thread to avoid blocking the TUI
##

import std/[asyncdispatch, asynchttpserver, httpclient, httpcore, json, os, osproc, strutils]

# Thread synchronization
var serverRunning*: bool = false
var serverThread*: Thread[void]
var serverPort*: Port

# Tool schema (embedded as JSON string to avoid GC-managed globals in async context)
const ToolsSchemaJson = """[
  {
    "type": "function",
    "function": {
      "name": "read",
      "description": "Read a file from the filesystem. Use this to read file contents.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_path": {
            "type": "string",
            "description": "Path to the file to read"
          },
          "offset": {
            "type": "number",
            "description": "Line number to start reading from (1-indexed)"
          },
          "limit": {
            "type": "number",
            "description": "Maximum number of lines to read"
          }
        },
        "required": ["file_path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Execute a bash command on the system. Use this for running shell commands.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The bash command to execute"
          }
        },
        "required": ["command"]
      }
    }
  }
]"""

const MaxReadLines = 1000

# Decode URL-encoded string
proc decodeUrlParam*(urlStr: string): string =
  result = ""
  var i = 0
  while i < urlStr.len:
    if urlStr[i] == '%' and i + 2 < urlStr.len:
      try:
        let hexVal = parseHexInt(urlStr.substr(i + 1, 2))
        result.add(chr(hexVal))
        i += 3
      except:
        result.add(urlStr[i])
        i += 1
    else:
      result.add(urlStr[i])
      i += 1
  result = result.replace("+", " ")

# Get the models.json path
proc getModelsJsonPath(): string =
  let homeDir = getHomeDir()
  return homeDir / ".nim_chatbot" / "models.json"

# Get chat endpoint for a provider
proc getChatEndpoint*(providerUrl: string): string =
  if providerUrl.contains("ollama.com"):
    return "https://ollama.com/v1/chat/completions"
  elif providerUrl.contains("opencode.ai"):
    return "https://opencode.ai/zen/v1/chat/completions"
  elif providerUrl.contains("nvidia"):
    return "https://integrate.api.nvidia.com/v1/chat/completions"
  elif providerUrl.contains("zyphra"):
    return "https://api.zyphracloud.com/api/v1/chat/completions"
  else:
    return providerUrl & "/v1/chat/completions"

# Get API key from auth.json for a provider
proc getApiKey*(provider: string): string =
  # provider can be "ollama", "opencode", "nvidia", or "zaya"
  let authFile = getHomeDir() / ".nim_chatbot" / "auth.json"
  if not fileExists(authFile):
    return ""
  try:
    let content = readFile(authFile)
    let j = parseJson(content)
    if j.hasKey(provider):
      if j[provider].hasKey("key"):
        return j[provider]["key"].getStr()
  except:
    discard
  return ""

# Fallback: read models from models.json config file
proc getModelsFromJsonFallback*(providerUrl: string, providerType: string): Future[string] {.async.} =
  let modelsJsonPath = getModelsJsonPath()
  if not fileExists(modelsJsonPath):
    return "{\"data\": []}"
  
  try:
    let content = readFile(modelsJsonPath)
    let json = parseJson(content)
    if not json.hasKey("providers"):
      return "{\"data\": []}"
    
    let provs = json["providers"]
    var foundModels: seq[string] = @[]
    
    if providerType.len > 0 and provs.hasKey(providerType):
      let providerData = provs[providerType]
      if providerData.hasKey("models"):
        for m in providerData["models"]:
          foundModels.add(m.getStr())
    
    # For OpenCode: apply same filter as server.nim
    if providerType == "opencode":
      var filteredModels: seq[string] = @[]
      for mName in foundModels:
        let lowerName = mName.toLowerAscii()
        if lowerName.contains("pickle") or lowerName.contains("free"):
          filteredModels.add(mName)
      foundModels = filteredModels
    
    var convertedData = newSeq[JsonNode]()
    for mName in foundModels:
      var modelItem = newJObject()
      modelItem["id"] = %*mName
      modelItem["object"] = %*"model"
      modelItem["owned_by"] = %*providerType
      convertedData.add(modelItem)
    let converted = %*{ "data": convertedData }
    return $converted
  except:
    return "{\"data\": []}"

# Get models list from models.json for a provider
proc getModelsFromConfig*(providerUrl: string): Future[string] {.async.} =
  # First try to fetch models directly from the provider's API
  if providerUrl.contains("opencode.ai"):
    var client = newAsyncHttpClient()
    try:
      # Get API key from auth.json (sync call)
      let apiKey = getApiKey("opencode")
      if apiKey.len == 0:
        # Fallback to reading from models.json config
        return await getModelsFromJsonFallback(providerUrl, "opencode")
      
      # OpenCode uses /zen/v1/models endpoint with Bearer auth
      client.headers = newHttpHeaders({
        "Authorization": "Bearer " & apiKey
      })
      let modelsUrl = "https://opencode.ai/zen/v1/models"
      let response = await client.getContent(modelsUrl)
      
      # Parse and filter models (same logic as server.nim)
      let jsonNode = parseJson(response)
      if jsonNode.hasKey("data"):
        var filteredModels: seq[JsonNode] = @[]
        for model in jsonNode["data"]:
          let mName = model["id"].getStr()
          let lowerName = mName.toLowerAscii()
          # Filter: only "pickle" or models with "free" in name
          if lowerName.contains("pickle") or lowerName.contains("free"):
            filteredModels.add(model)
        let filtered = %*{ "data": filteredModels }
        return $filtered
      return response
    except:
      # Fallback to reading from models.json config
      return await getModelsFromJsonFallback(providerUrl, "opencode")
    finally:
      client.close()
  elif providerUrl.contains("ollama.com"):
    var client = newAsyncHttpClient()
    try:
      let modelsUrl = "https://ollama.com/api/tags"
      let response = await client.getContent(modelsUrl)
      # Parse Ollama response format and convert to standard format
      try:
        let j = parseJson(response)
        var models: seq[JsonNode] = @[]
        if j.hasKey("models"):
          for m in j["models"]:
            var modelItem = newJObject()
            modelItem["id"] = m["name"]
            modelItem["object"] = %*"model"
            modelItem["owned_by"] = %*"ollama"
            models.add(modelItem)
        return $ %*{ "data": models }
      except:
        return response
    except:
      discard
    finally:
      client.close()
  elif providerUrl.contains("nvidia"):
    var client = newAsyncHttpClient()
    try:
      let modelsUrl = "https://catalog.ngc.ngm.com/v1/models"
      let response = await client.getContent(modelsUrl)
      return response
    except:
      discard
    finally:
      client.close()
  
  # Fallback to reading from models.json config
  let modelsJsonPath = getModelsJsonPath()
  let statusFile = getCurrentDir() / "my_include" / "status.json"
  if not fileExists(modelsJsonPath):
    return "{\"data\": []}"
  
  try:
    let content = readFile(modelsJsonPath)
    let json = parseJson(content)
    if not json.hasKey("providers"):
      return "{\"data\": []}"
    
    let provs = json["providers"]
    var foundModels: seq[string] = @[]
    var providerType = ""
    
    if providerUrl.contains("ollama"):
      providerType = "ollama"
    elif providerUrl.contains("zyphra"):
      providerType = "zaya"
    elif providerUrl.contains("nvidia"):
      providerType = "nvidia"
    elif providerUrl.contains("opencode"):
      providerType = "opencode"
    elif providerUrl.contains("localhost:8080"):
      providerType = "llamacpp"
    
    if providerType.len > 0 and provs.hasKey(providerType):
      let providerData = provs[providerType]
      if providerData.hasKey("models"):
        for m in providerData["models"]:
          foundModels.add(m.getStr())
    
    # Special case for llama.cpp: if no models configured, try to get from status.json
    if providerType == "llamacpp" and foundModels.len == 0:
      if fileExists(statusFile):
        try:
          let statusContent = readFile(statusFile)
          let statusJson = parseJson(statusContent)
          if statusJson.hasKey("selected_model"):
            let selectedModel = statusJson["selected_model"].getStr()
            foundModels.add(selectedModel)
        except:
          discard
    
    var convertedData = newSeq[JsonNode]()
    for mName in foundModels:
      var modelItem = newJObject()
      modelItem["id"] = %*mName
      modelItem["object"] = %*"model"
      modelItem["owned_by"] = %*providerType
      convertedData.add(modelItem)
    let converted = %*{ "data": convertedData }
    return $converted
  except:
    return "{\"data\": []}"

proc requestCallback(req: Request) {.async, gcsafe.} =
  var path = req.url.path

  if path == "/api/providers":
    let modelsJsonPath = getModelsJsonPath()
    var providers: seq[string] = @[]
    providers.add("http://localhost:8080")
    
    if fileExists(modelsJsonPath):
      try:
        let content = readFile(modelsJsonPath)
        let json = parseJson(content)
        if json.hasKey("providers"):
          let provs = json["providers"]
          if provs.hasKey("ollama"):
            let ollama = provs["ollama"]
            if ollama.hasKey("baseUrl"):
              let baseUrl = ollama["baseUrl"].getStr()
              if baseUrl.len > 0:
                let idx = baseUrl.find("/v1")
                if idx > 0:
                  providers.add(baseUrl[0 .. idx - 1])
                else:
                  providers.add(baseUrl)
          if provs.hasKey("nvidia"):
            let nvidia = provs["nvidia"]
            if nvidia.hasKey("baseUrl"):
              let baseUrl = nvidia["baseUrl"].getStr()
              if baseUrl.len > 0:
                let idx = baseUrl.find("/v1")
                if idx > 0:
                  providers.add(baseUrl[0 .. idx - 1])
          if provs.hasKey("zaya"):
            let zaya = provs["zaya"]
            if zaya.hasKey("baseUrl"):
              let baseUrl = zaya["baseUrl"].getStr()
              if baseUrl.len > 0:
                providers.add(baseUrl)
          if provs.hasKey("opencode"):
            let oc = provs["opencode"]
            if oc.hasKey("baseUrl"):
              let baseUrl = oc["baseUrl"].getStr()
              if baseUrl.len > 0:
                let idx = baseUrl.find("/v1")
                if idx > 0:
                  providers.add(baseUrl[0 .. idx - 1])
      except:
        discard
    
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    let response = %*{ "providers": providers }
    await req.respond(Http200, $response, headers)
    return

  if path == "/api/models":
    var providerUrl = "http://localhost:8080"
    
    if req.url.query.len > 0:
      let queryParams = req.url.query.split("&")
      for param in queryParams:
        let parts = param.split("=")
        if parts.len == 2 and parts[0] == "provider":
          providerUrl = decodeUrlParam(parts[1])
    
    var modelsResponse = ""
    
    if providerUrl.contains("localhost:8080"):
      var client = newAsyncHttpClient()
      try:
        modelsResponse = await client.getContent(providerUrl & "/models")
      except:
        try:
          modelsResponse = await client.getContent(providerUrl & "/v1/models")
        except:
          modelsResponse = "{\"data\": []}"
      finally:
        client.close()
    else:
      modelsResponse = await getModelsFromConfig(providerUrl)

    let modelHeaders = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, modelsResponse, modelHeaders)
    return

  if path == "/v1/embeddings":
    let bodyStr = req.body
    var client = newHttpClient()
    var embedResponse = ""
    try:
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      embedResponse = client.postContent("http://localhost:8080/v1/embeddings", bodyStr)
    except:
      embedResponse = "{\"error\": \"Failed to connect to provider\"}"
    finally:
      discard
    
    let embedHeaders = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, embedResponse, embedHeaders)
    return

  if path == "/v1/chat/completions":
    let bodyStr = req.body
    var targetUrl = "http://localhost:8080/v1/chat/completions"
    var authHeader = ""
    
    if req.url.query.len > 0:
      let queryParams = req.url.query.split("&")
      for param in queryParams:
        let parts = param.split("=")
        if parts.len == 2 and parts[0] == "provider":
          let providerUrl = decodeUrlParam(parts[1])
          targetUrl = getChatEndpoint(providerUrl)
          # Determine which API key to use based on the provider
          # NOTE: We need to access config variables from config.nim
          if providerUrl.contains("ollama.com"):
            authHeader = "ollama"
          elif providerUrl.contains("opencode.ai"):
            authHeader = "opencode"
          elif providerUrl.contains("nvidia"):
            authHeader = "nvidia"
          elif providerUrl.contains("zyphra") or providerUrl.contains("zaya"):
            authHeader = "zaya"
    
    var client = newHttpClient()
    var chatResponse = ""
    try:
      var headers = newHttpHeaders([("Content-Type", "application/json")])
      # Add auth header for external providers
      if authHeader.len > 0:
        let apiKey = getApiKey(authHeader)
        if apiKey.len > 0:
          headers["Authorization"] = "Bearer " & apiKey
      client.headers = headers
      chatResponse = client.postContent(targetUrl, bodyStr)
    except:
      chatResponse = "{\"error\": \"Failed to connect to provider: " & targetUrl & "\"}"
    finally:
      discard
    
    let chatHeaders = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, chatResponse, chatHeaders)
    return

  if path == "/api/tools":
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, ToolsSchemaJson, headers)
    return

  if path == "/api/read":
    let bodyStr = req.body
    let args = parseJson(bodyStr)
    let filePath = if args.hasKey("file_path"): args["file_path"].getStr() else: ""
    let offset = if args.hasKey("offset"): args["offset"].getInt() else: 1
    let limit = if args.hasKey("limit"): args["limit"].getInt() else: -1
    let headers = newHttpHeaders([("Content-Type", "application/json")])

    if filePath == "":
      let response = %*{"error": "Missing file_path parameter"}
      await req.respond(Http200, $response, headers)
      return

    var resolvedPath = filePath.replace("\\", "/")
    if not resolvedPath.startsWith("/") and not (resolvedPath.len >= 2 and resolvedPath[1] == ':'):
      resolvedPath = getCurrentDir() / resolvedPath

    if not fileExists(resolvedPath):
      let response = %*{"error": "File not found: " & resolvedPath}
      await req.respond(Http200, $response, headers)
      return

    try:
      let lines = readFile(resolvedPath).splitLines()
      let startIdx = max(0, offset - 1)
      let effectiveLimit = if limit == -1: MaxReadLines else: min(limit, MaxReadLines)
      let endIdx = min(lines.len - 1, startIdx + effectiveLimit - 1)
      let slice = lines[startIdx .. endIdx]
      var content = slice.join("\n")
      if endIdx + 1 < lines.len:
        content &= "\n[... truncated at " & $MaxReadLines & " lines]"
      let response = %*{"content": content}
      await req.respond(Http200, $response, headers)
    except Exception as e:
      let response = %*{"error": e.msg}
      await req.respond(Http200, $response, headers)
    return

  if path == "/api/bash":
    let bodyStr = req.body
    let args = parseJson(bodyStr)
    let command = if args.hasKey("command"): args["command"].getStr() else: ""
    let headers = newHttpHeaders([("Content-Type", "application/json")])

    if command == "":
      let response = %*{"error": "Missing command parameter"}
      await req.respond(Http200, $response, headers)
      return

    try:
      var res = ""
      var exitCode = 0
      when defined(windows):
        const gitBashPath = "C:\\Program Files\\git\\bin\\bash.exe"
        var cwd = getCurrentDir().replace("\\", "/")
        let fullCommand = "cd '" & cwd & "' && " & command
        (res, exitCode) = execCmdEx(quoteShell(gitBashPath) & " -c " & quoteShell(fullCommand))
      else:
        (res, exitCode) = execCmdEx(command)
      let response = %*{"content": res.strip(), "exit_code": $exitCode}
      await req.respond(Http200, $response, headers)
    except Exception as e:
      let response = %*{"error": e.msg}
      await req.respond(Http200, $response, headers)
    return

  if path == "/":
    path = "/index.html"

  let staticDir = getAppDir() / "webui" / "static"
  let filePath = staticDir / path

  if fileExists(filePath):
    let content = readFile(filePath)
    let contentType = if path.endsWith(".html"): "text/html"
                      elif path.endsWith(".css"): "text/css"
                      elif path.endsWith(".js"): "application/javascript"
                      else: "text/plain"
    let headers = newHttpHeaders([("Content-Type", contentType)])
    await req.respond(Http200, content, headers)
  else:
    await req.respond(Http404, "Not Found")

proc serverWorker() {.thread, gcsafe.} =
  let server = newAsyncHttpServer()
  waitFor server.serve(serverPort, requestCallback)

proc startServer*(port: Port = Port(8000)) =
  if serverRunning:
    return
  serverPort = port
  serverRunning = true
  createThread(serverThread, serverWorker)

proc stopServer*() =
  if not serverRunning:
    return
  serverRunning = false