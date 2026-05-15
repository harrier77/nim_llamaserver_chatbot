##
## WebUI HTTP Server Module
## Serves static files from the "static" directory
## Runs in a separate thread to avoid blocking the TUI
##

import std/[asyncdispatch, asynchttpserver, asyncnet, httpclient, httpcore, json, os, strutils, strformat, times]
import tools
import system_prompt

# Thread synchronization
var serverRunning*: bool = false
var serverThread*: Thread[void]
var serverPort*: Port

proc debugLog*(msg: string) =
  let logPath = getCurrentDir() / "nimlog.txt"
  let timestamp = now().format("HH:mm:ss")
  try:
    var f = open(logPath, fmAppend)
    f.writeLine(timestamp & " " & msg)
    f.close()
  except:
    discard

#const MaxReadLines = 1000

# Decode URL-encoded string
proc decodeUrlParam*(urlStr: string): string =
  result = ""
  var i = 0
  while i < urlStr.len:
    if urlStr[i] == '%' and i + 2 < urlStr.len:
      try:
        let hexVal = parseHexInt(urlStr[i + 1 .. i + 2])
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
  if providerUrl.contains("opencode.ai"):
    var client = newAsyncHttpClient()
    try:
      let apiKey = getApiKey("opencode")
      if apiKey.len == 0:
        return await getModelsFromJsonFallback(providerUrl, "opencode")
      
      client.headers = newHttpHeaders({
        "Authorization": "Bearer " & apiKey
      })
      let modelsUrl = "https://opencode.ai/zen/v1/models"
      let response = await client.getContent(modelsUrl)
      
      let jsonNode = parseJson(response)
      if jsonNode.hasKey("data"):
        var filteredModels: seq[JsonNode] = @[]
        for model in jsonNode["data"]:
          let mName = model["id"].getStr()
          let lowerName = mName.toLowerAscii()
          if lowerName.contains("pickle") or lowerName.contains("free"):
            filteredModels.add(model)
        let filtered = %*{ "data": filteredModels }
        return $filtered
      return response
    except:
      return await getModelsFromJsonFallback(providerUrl, "opencode")
    finally:
      client.close()
  elif providerUrl.contains("ollama.com"):
    # Use models.json fallback (same mechanism as nvidia provider)
    discard
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
    providers.add("http://172.20.14.47:8080")
    
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
          debugLog("/api/models raw parts[1]=" & parts[1])
          providerUrl = decodeUrlParam(parts[1])
          debugLog("/api/models decoded providerUrl=" & providerUrl)
    
    debugLog("=== /api/models final providerUrl=" & providerUrl)
    var modelsResponse = ""
    
    let isCloud = providerUrl.contains("ollama.com") or providerUrl.contains("opencode.ai") or
                   providerUrl.contains("nvidia") or providerUrl.contains("zyphra") or
                   providerUrl.contains("zaya")

    if isCloud:
      debugLog("/api/models isCloud=true -> getModelsFromConfig")
      modelsResponse = await getModelsFromConfig(providerUrl)
    else:
      var client = newAsyncHttpClient()
      try:
        let fetchUrl = providerUrl & "/v1/models"
        debugLog("/api/models trying " & fetchUrl)
        modelsResponse = await client.getContent(fetchUrl)
        debugLog("/api/models SUCCESS " & $modelsResponse.len & " bytes")
        debugLog("/api/models response body: " & modelsResponse)
      except CatchableError as e:
        debugLog("/api/models /v1/models FAILED: " & e.msg)
        try:
          let fetchUrl2 = providerUrl & "/models"
          debugLog("/api/models trying fallback " & fetchUrl2)
          modelsResponse = await client.getContent(fetchUrl2)
          debugLog("/api/models fallback SUCCESS " & $modelsResponse.len & " bytes")
          debugLog("/api/models fallback body: " & modelsResponse)
        except CatchableError as e2:
          debugLog("/api/models fallback ALSO FAILED: " & e2.msg)
          modelsResponse = "{\"data\": []}"
      finally:
        client.close()

    let modelHeaders = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, modelsResponse, modelHeaders)
    return

  if path == "/v1/embeddings":
    let bodyStr = req.body
    var targetUrl = "http://localhost:8080/v1/embeddings"

    if req.url.query.len > 0:
      let queryParams = req.url.query.split("&")
      for param in queryParams:
        let parts = param.split("=")
        if parts.len == 2 and parts[0] == "provider":
          let providerUrl = decodeUrlParam(parts[1])
          targetUrl = providerUrl & "/v1/embeddings"

    var client = newAsyncHttpClient()
    var embedResponse = ""
    try:
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      embedResponse = await client.postContent(targetUrl, bodyStr)
    except:
      embedResponse = "{\"error\": \"Failed to connect to " & targetUrl & "\"}"
    finally:
      client.close()
    
    let embedHeaders = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, embedResponse, embedHeaders)
    return

  if path == "/v1/chat/completions":
    let bodyStr = req.body
    var targetUrl = "http://localhost:8080/v1/chat/completions"
    var authHeader = ""
    
    # Parse stream flag from body
    var isStreaming = false
    try:
      let bodyJson = parseJson(bodyStr)
      if bodyJson.hasKey("stream"):
        isStreaming = bodyJson["stream"].getBool()
    except:
      discard

    if req.url.query.len > 0:
      let queryParams = req.url.query.split("&")
      for param in queryParams:
        let parts = param.split("=")
        if parts.len == 2 and parts[0] == "provider":
          let providerUrl = decodeUrlParam(parts[1])
          targetUrl = getChatEndpoint(providerUrl)
          if providerUrl.contains("ollama.com"):
            authHeader = "ollama"
          elif providerUrl.contains("opencode.ai"):
            authHeader = "opencode"
          elif providerUrl.contains("nvidia"):
            authHeader = "nvidia"
          elif providerUrl.contains("zyphra") or providerUrl.contains("zaya"):
            authHeader = "zaya"
    
    if isStreaming:
      var client = newAsyncHttpClient()
      var headersSent = false
      try:
        # FIX: Disable compression (gzip) to ensure we receive and forward plain text SSE events.
        # Remote providers like NVIDIA might otherwise send compressed chunks that break the browser's parser.
        client.headers = newHttpHeaders({
          "Content-Type": "application/json",
          "Accept-Encoding": "identity"
        })
        if authHeader.len > 0:
          let apiKey = getApiKey(authHeader)
          if apiKey.len > 0:
            client.headers["Authorization"] = "Bearer " & apiKey
        
        let response = await client.request(targetUrl, httpMethod = HttpPost, body = bodyStr)
        
        # If provider returns an error (e.g., 401, 429), catch it before starting the stream
        # to return a clean JSON error response to the frontend.
        if response.code != Http200:
          let errorBody = await response.body
          let errorHeaders = newHttpHeaders([
            ("Content-Type", "application/json"),
            ("Access-Control-Allow-Origin", "*")
          ])
          await req.respond(response.code, errorBody, errorHeaders)
          return

        # FIX: Use raw streaming mode with 'Connection: close' instead of 'Transfer-Encoding: chunked'.
        # Some browsers and remote endpoints struggle with manual chunked encoding over SSE.
        # Closing the connection is the most reliable way to signal the end of a proxied stream.
        var respHeaders = &"HTTP/1.1 200 OK\r\n"
        respHeaders.add("Content-Type: text/event-stream\r\n")
        respHeaders.add("Cache-Control: no-cache\r\n")
        respHeaders.add("Connection: close\r\n")
        respHeaders.add("Access-Control-Allow-Origin: *\r\n")
        respHeaders.add("\r\n")
        await req.client.send(respHeaders)
        headersSent = true
        
        # Stream the body raw to avoid protocol overhead or formatting errors.
        while true:
          let (hasData, chunk) = await response.bodyStream.read()
          if not hasData: break
          if chunk.len > 0:
            await req.client.send(chunk)
        
        # FIX: Explicitly close the browser connection to signal the end of the stream.
        # Without this, since we use 'Connection: close' without 'Transfer-Encoding: chunked',
        # the browser's fetch reader remains in a pending state indefinitely, 
        # preventing the WebUI from resetting its 'isProcessing' state for the next query.
        req.client.close()
        
      except CatchableError as e:
        if not headersSent:
          let errorMsg = "{\"error\": \"Failed to connect to provider: " & targetUrl & " - " & e.msg & "\"}"
          let errorHeaders = newHttpHeaders([("Content-Type", "application/json"), ("Access-Control-Allow-Origin", "*")])
          await req.respond(Http500, errorMsg, errorHeaders)
        else:
          # If headers were already sent, ensure the connection is closed even on error
          # to prevent the browser from hanging on a broken stream.
          req.client.close()
      finally:
        client.close()
      return
    else:
      var client = newAsyncHttpClient()
      var chatResponse = ""
      try:
        var headers = newHttpHeaders([("Content-Type", "application/json")])
        if authHeader.len > 0:
          let apiKey = getApiKey(authHeader)
          if apiKey.len > 0:
            headers["Authorization"] = "Bearer " & apiKey
        client.headers = headers
        chatResponse = await client.postContent(targetUrl, bodyStr)
      except:
        chatResponse = "{\"error\": \"Failed to connect to provider: " & targetUrl & "\"}"
      finally:
        client.close()
      
      let chatHeaders = newHttpHeaders([("Content-Type", "application/json")])
      await req.respond(Http200, chatResponse, chatHeaders)
      return

  if path == "/api/tools":
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, tools.ToolsSchemaJson, headers)
    return

  if path == "/api/system-prompt":
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    let response = %*{"content": getSystemPrompt()}
    await req.respond(Http200, $response, headers)
    return

  if path == "/api/execute-tool":
    let bodyStr = req.body
    let args = parseJson(bodyStr)
    let toolName = if args.hasKey("name"): args["name"].getStr() else: ""
    let toolArgs = if args.hasKey("arguments"): args["arguments"] else: %*{}
    let headers = newHttpHeaders([("Content-Type", "application/json")])

    if toolName == "":
      let response = %*{"error": "Missing name parameter"}
      await req.respond(Http200, $response, headers)
      return

    let toolResult = tools.executeTool(toolName, toolArgs)
    await req.respond(Http200, toolResult, headers)
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