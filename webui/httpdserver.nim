##
## WebUI HTTP Server Module
## Serves static files from the "static" directory
## Runs in a separate thread to avoid blocking the TUI
##

import std/[asyncdispatch, asynchttpserver, asyncnet, httpclient, httpcore, json, os, strutils, strformat, times, random, uri]
import tools
import system_prompt
import config_web

# Thread synchronization
var serverRunning*: bool = false
var serverThread*: Thread[void]
var serverPort*: Port

proc debugLog*(msg: string) {.gcsafe.} =
  ## Writes a timestamped message to nimlog.txt with automatic rotation.
  ## See config_web.writeLog for the rotation logic (rename to .bak at 1 MB).
  var dir: string
  {.cast(gcsafe).}:
    dir = ExeDir
  writeLog(dir, msg)

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
#
# Normalizes a provider's baseUrl into a valid /v1/chat/completions endpoint.
# Handles all forms:
#   - Already complete: "https://api.together.xyz/v1/chat/completions"  → as-is
#   - Ends with /v1:    "https://ollama.com/v1"                         → append /chat/completions
#   - Plain base:       "http://localhost:8080"                          → append /v1/chat/completions
#
# Uses the same logic as providers.nim (TUI) to ensure consistent behaviour
# between WebUI and TUI for all OpenAI-compatible providers.
proc getChatEndpoint*(providerUrl: string): string =
  var cleanUrl = providerUrl
  cleanUrl.removeSuffix('/')

  if cleanUrl.endsWith("/chat/completions"):
    # Already has the full path (e.g. together, nvidia, opencode, openrouter)
    return cleanUrl
  elif cleanUrl.endsWith("/v1"):
    # Ends with /v1 (e.g. ollama) — just append /chat/completions
    return cleanUrl & "/chat/completions"
  else:
    # Plain base URL — append the standard OpenAI path
    return cleanUrl & "/v1/chat/completions"

# Look up the provider name from models.json by matching the baseUrl.
# This replaces fragile hardcoded contains() checks with a dynamic lookup,
# so any provider added to models.json (cerebras, together, groq, …) is
# automatically found and its API key used.
proc getProviderNameByUrl*(providerUrl: string): string =
  let modelsJsonPath = getHomeDir() / ".nim_chatbot" / "models.json"
  if not fileExists(modelsJsonPath):
    return ""
  try:
    let content = readFile(modelsJsonPath)
    let j = parseJson(content)
    if not j.hasKey("providers"):
      return ""
    var cleanUrl = providerUrl
    cleanUrl.removeSuffix('/')
    for provName, provVal in j["providers"]:
      var baseUrl = provVal{"baseUrl"}.getStr("")
      baseUrl.removeSuffix('/')
      if baseUrl == cleanUrl:
        return provName
  except:
    discard
  return ""

# Get API key from auth.json for a provider
proc getApiKey*(provider: string): string {.gcsafe.} =
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

# Get extra headers from auth.json for a provider
proc getApiHeaders*(provider: string): seq[tuple[key, value: string]] {.gcsafe.} =
  let authFile = getHomeDir() / ".nim_chatbot" / "auth.json"
  if not fileExists(authFile):
    return @[]
  try:
    let content = readFile(authFile)
    let j = parseJson(content)
    if j.hasKey(provider) and j[provider].hasKey("headers"):
      var hdrs: seq[tuple[key, value: string]] = @[]
      for hdrKey, hdrVal in j[provider]["headers"]:
        hdrs.add((key: hdrKey, value: hdrVal.getStr("")))
      return hdrs
  except:
    discard
  return @[]

var
  ocServerSessionId {.threadvar.}: string
  ocRequestCounter {.threadvar.}: int

# OpenCode (Zen) headers required for free-tier models (big-pickle, *-free)
#
# The OpenCode Zen backend at https://opencode.ai/zen/v1 inspects these
# custom headers to distinguish official CLI traffic from anonymous clients.
# Without them, free-tier requests are throttled aggressively (429
# FreeUsageLimitError). The official opencode CLI sends all five headers
# automatically (see packages/opencode/src/session/llm.ts in the opencode repo).
#
# Required headers:
#   x-opencode-client:  "cli"                             (static)
#   x-opencode-project: project identifier                (static, per-user)
#   x-opencode-session: "ses_<random-hex>"                (per-process, must rotate)
#   x-opencode-request: "req_<incrementing-counter>"      (per-request, unique)
#   User-Agent:         "opencode/latest/<version>/cli"   (identifies as official CLI)
#
# REGRESSION WARNING:
# - If ANY of these five headers is missing or has a static value that is
#   reused across requests, the backend WILL return 429 for free-tier models.
# - The session and request IDs MUST be unique and non-repeating; the code
#   below uses a thread-local session ID (random at first call) and an
#   incrementing counter for request IDs.
# - The values "ses_" and "req_" in auth.json are TEMPLATES: the code detects
#   the prefix and substitutes the dynamic value. Never change them to a
#   static string or the substitution will be skipped.
# - The User-Agent MUST start with "opencode/" to pass the backend check.
proc applyOpenCodeHeaders*(headers: var HttpHeaders, provider: string) {.gcsafe.} =
  if provider != "opencode": return
  if ocServerSessionId.len == 0:
    var rng = initRand()
    ocServerSessionId = "ses_" & rng.rand(high(int32)).toHex(8) & rng.rand(high(int32)).toHex(8)
  inc(ocRequestCounter)
  let reqId = "req_" & ocRequestCounter.toHex
  let apiHeaders = getApiHeaders(provider)
  for h in apiHeaders:
    var val = h.value
    if h.key == "x-opencode-session" and val.startsWith("ses_"):
      val = ocServerSessionId
    elif h.key == "x-opencode-request" and val.startsWith("req_"):
      val = reqId
    headers[h.key] = val
  headers["User-Agent"] = "opencode/latest/1.3.15/cli"

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
      applyOpenCodeHeaders(client.headers, "opencode")
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

  # Generic cloud provider handler: try /v1/models with optional API key.
  # Works for any OpenAI-compatible provider (cerebras, together, groq, …).
  # Providers without an API key (e.g. 2nd_llama) are also supported.
  let apiProviderName = getProviderNameByUrl(providerUrl)
  if apiProviderName.len > 0:
    let apiKey = getApiKey(apiProviderName)
    var client = newAsyncHttpClient()
    try:
      if apiKey.len > 0:
        client.headers = newHttpHeaders({
          "Content-Type": "application/json",
          "Authorization": "Bearer " & apiKey
        })
      else:
        client.headers = newHttpHeaders({
          "Content-Type": "application/json"
        })
      # Construct /v1/models URL from the provider's baseUrl
      var modelsUrl = providerUrl
      modelsUrl.removeSuffix('/')
      if modelsUrl.endsWith("/chat/completions"):
        modelsUrl = modelsUrl.replace("/chat/completions", "/models")
      elif modelsUrl.endsWith("/v1"):
        modelsUrl = modelsUrl & "/models"
      else:
        modelsUrl = modelsUrl & "/v1/models"
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
    
    # Dynamic lookup: match against models.json (works for any provider)
    providerType = getProviderNameByUrl(providerUrl)
    
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
  ## Top-level request handler. Catches ALL exceptions to ensure the server
  ## always sends a response — preventing CLOSE_WAIT socket accumulation
  ## and async event-loop stalls that freeze the WebUI.
  try:
    var path = req.url.path

    if path == "/api/providers":
      let modelsJsonPath = getModelsJsonPath()
      var providersList: seq[JsonNode] = @[]
    
      # 1. Default localhost provider (always available)
      providersList.add(%*{
        "name": "🖥 Local Server",
        "baseUrl": "http://localhost:8080",
        "isRemote": false,
        "source": "default",
        "hasApiKey": false,
        "modelsKnown": false
      })
    
      # 2. Read ALL providers from models.json dynamically (like providers.nim does)
      if fileExists(modelsJsonPath):
        try:
          let content = readFile(modelsJsonPath)
          let json = parseJson(content)
          if json.hasKey("providers"):
            for provName, provVal in json["providers"]:
              var baseUrl = provVal{"baseUrl"}.getStr("")
              baseUrl.removeSuffix('/')
              if baseUrl.len == 0: continue
            
              let isRemote = provName != "llamacpp"
              let apiKey = getApiKey(provName)
              let hasApiKey = apiKey.len > 0
            
              var modelIds: seq[string] = @[]
              if provVal.hasKey("models"):
                for m in provVal["models"]:
                  modelIds.add(m.getStr())
            
              var entry = %*{
                "name": provName,
                "baseUrl": baseUrl,
                "isRemote": isRemote,
                "source": "config",
                "hasApiKey": hasApiKey,
                "modelsKnown": modelIds.len > 0
              }
              if modelIds.len > 0:
                entry["models"] = %modelIds
              providersList.add(entry)
        except:
          discard
    
      # 3. Custom URL entry (always at the end)
      providersList.add(%*{
        "name": "✏️ Custom URL...",
        "baseUrl": "",
        "isRemote": false,
        "source": "custom",
        "hasApiKey": false,
        "modelsKnown": false
      })
    
      let headers = newHttpHeaders([("Content-Type", "application/json")])
      let response = %*{ "providers": providersList }
      await req.respond(Http200, $response, headers)
      return

    if path == "/api/models":
      var providerUrl = "http://localhost:8080"
      var providerName = ""
    
      if req.url.query.len > 0:
        for param in req.url.query.split("&"):
          let parts = param.split("=")
          if parts.len == 2:
            if parts[0] == "provider":
              providerUrl = decodeUrlParam(parts[1])
            elif parts[0] == "providerName":
              providerName = decodeUrlParam(parts[1])
    
      debugLog("=== /api/models providerUrl=" & providerUrl & " providerName=" & providerName)
      var modelsResponse: string
    
      # Dynamic cloud detection: any provider in models.json that is not local
      let cloudProviderType = getProviderNameByUrl(providerUrl)
      let isCloud = cloudProviderType.len > 0 and
                     cloudProviderType != "llamacpp"

      if isCloud:
        debugLog("/api/models isCloud=true -> getModelsFromConfig")
        modelsResponse = await getModelsFromConfig(providerUrl)
      else:
        # Quick port check: if the provider port is not reachable, skip HTTP calls
        # and go directly to config fallback (avoids ~4s timeout delay).
        var parsed = parseUri(providerUrl)
        let host = if parsed.hostname.len > 0: parsed.hostname else: "localhost"
        let port = if parsed.port.len > 0: Port(parseInt(parsed.port)) else: Port(8080)
        var portReachable = false
        try:
          let checkSocket = newAsyncSocket()
          portReachable = await checkSocket.connect(host, port).withTimeout(1000)
          checkSocket.close()
        except:
          discard
      
        if not portReachable:
          debugLog("/api/models port " & $int(port) & " not reachable")
          if providerUrl.contains("localhost:8080"):
            debugLog("/api/models port unreachable for localhost:8080, reporting llamaserver missing")
            modelsResponse = """{"data":[{"id":"llamaserver missing","object":"model","owned_by":"local","status":{"value":"unloaded"}}]}"""
          else:
            modelsResponse = await getModelsFromConfig(providerUrl)
        else:
          debugLog("/api/models port " & $int(port) & " reachable, trying HTTP")
          # Use ASYNC httpclient to avoid blocking the event loop.
          # When a timeout occurs, we MUST await/consume the pending future
          # after closing the client, otherwise an unhandled future error
          # will crash the server's event loop thread.
          var asyncClient = newAsyncHttpClient()
          try:
            let apiKey = if providerName.len > 0: getApiKey(providerName) else: ""
            let fetchUrl = providerUrl & "/v1/models"
            debugLog("/api/models trying " & fetchUrl)
            if apiKey.len > 0:
              debugLog("/api/models using API key for " & providerName)
              asyncClient.headers = newHttpHeaders({
                "Content-Type": "application/json",
                "Authorization": "Bearer " & apiKey
              })
            
            # Try /v1/models (async — does NOT block the event loop)
            var succeeded = false
            let fut1 = asyncClient.getContent(fetchUrl)
            try:
              let ok1 = await fut1.withTimeout(3000)
              if ok1:
                modelsResponse = await fut1
                debugLog("/api/models SUCCESS " & $modelsResponse.len & " bytes")
                succeeded = true
            except CatchableError as e:
              debugLog("/api/models /v1/models FAILED: " & e.msg)
            
            if not succeeded:
              # Close client (synchronously fails all pending futures)
              # THEN consume any error to prevent unhandled-future crash in the event loop
              asyncClient.close()
              try:
                if fut1.finished:
                  discard fut1.read()
                else:
                  discard await fut1
              except:
                discard
              
              # Try fallback /models endpoint
              asyncClient = newAsyncHttpClient()
              let fetchUrl2 = providerUrl & "/models"
              debugLog("/api/models trying fallback " & fetchUrl2)
              let fut2 = asyncClient.getContent(fetchUrl2)
              try:
                let ok2 = await fut2.withTimeout(3000)
                if ok2:
                  modelsResponse = await fut2
                  debugLog("/api/models fallback SUCCESS " & $modelsResponse.len & " bytes")
                  succeeded = true
              except CatchableError as e2:
                debugLog("/api/models fallback ALSO FAILED: " & e2.msg)
              
              if not succeeded:
                asyncClient.close()
                try:
                  if fut2.finished:
                    discard fut2.read()
                  else:
                    discard await fut2
                except:
                  discard
                if providerUrl.contains("localhost:8080"):
                  debugLog("/api/models HTTP failed for localhost:8080, reporting llamaserver missing")
                  modelsResponse = """{"data":[{"id":"llamaserver missing","object":"model","owned_by":"local","status":{"value":"unloaded"}}]}"""
                elif providerName.len > 0:
                  debugLog("/api/models trying JSON fallback for " & providerName)
                  modelsResponse = await getModelsFromJsonFallback(providerUrl, providerName)
                else:
                  debugLog("/api/models trying getModelsFromConfig as fallback")
                  modelsResponse = await getModelsFromConfig(providerUrl)
          finally:
            asyncClient.close()

      # OpenRouter filter: mostra solo modelli free (contengono ":free" nel nome)
      let providerType = getProviderNameByUrl(providerUrl)
      if providerType == "openrouter" and modelsResponse.len > 0:
        try:
          let modelsJson = parseJson(modelsResponse)
          if modelsJson.hasKey("data"):
            var freeModels: seq[JsonNode] = @[]
            for m in modelsJson["data"]:
              if m{"id"}.getStr("").contains(":free"):
                freeModels.add(m)
            modelsResponse = $(%*{ "data": freeModels })
            debugLog("/api/models openrouter filter: " & $freeModels.len & " free models of " & $modelsJson["data"].len & " total")
        except:
          debugLog("/api/models openrouter filter FAILED to parse response")

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
            # Dynamic lookup: match the providerUrl against models.json to
            # find the provider name, then use it to fetch the API key.
            # Handles any provider without hardcoding (cerebras, together, …).
            authHeader = getProviderNameByUrl(providerUrl)
      
      # === DEBUG: log what we're about to send to the provider ===
      debugLog("[PROXY] providerUrl from query: " & (if req.url.query.len > 0: req.url.query else: "none"))
      debugLog("[PROXY] targetUrl: " & targetUrl)
      debugLog("[PROXY] authHeader (provider name): " & (if authHeader.len > 0: authHeader else: "(empty)"))
      if authHeader.len > 0:
        let apiKeyCheck = getApiKey(authHeader)
        debugLog("[PROXY] apiKey found: " & (if apiKeyCheck.len > 0: "YES (len=" & $apiKeyCheck.len & ")" else: "NO"))
      else:
        debugLog("[PROXY] apiKey found: NO (no authHeader)")
      debugLog("[PROXY] body (FULL, " & $bodyStr.len & " chars): " & bodyStr)
    
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
            applyOpenCodeHeaders(client.headers, authHeader)
        
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
          # Use a timeout (30s) only for reads AFTER the first chunk has arrived.
          # The first chunk can take long (model loading), so we wait indefinitely.
          var firstChunk = true
          while true:
            let readFut = response.bodyStream.read()
            var gotData: bool
            if firstChunk:
              # Wait indefinitely for the first chunk (slow model load)
              let (hasData, chunk) = await readFut
              gotData = hasData
              if gotData and chunk.len > 0:
                await req.client.send(chunk)
                if firstChunk:
                  debugLog("[CHAT-PROXY] ◀ first chunk (" & $chunk.len & " bytes): " & chunk)
                  firstChunk = false
                if chunk.contains("\"tool_calls\"") or chunk.contains("\"function\""):
                  debugLog("[CHAT-PROXY] ◀ TC_CHUNK: " & chunk)
            else:
              # Subsequent chunks: 30s timeout to detect upstream keep-alive
              if await readFut.withTimeout(30000):
                let (hasData, chunk) = readFut.read()
                gotData = hasData
                if gotData and chunk.len > 0:
                  await req.client.send(chunk)
              else:
                debugLog("Stream chunk timeout (30s) — upstream keep-alive, closing")
                break
            if not gotData: break
        
          debugLog("Stream finished — closing browser connection")
          # FIX: Explicitly close the browser connection to signal the end of the stream.
          # Without this, since we use 'Connection: close' without 'Transfer-Encoding: chunked',
          # the browser's fetch reader remains in a pending state indefinitely, 
          # preventing the WebUI from resetting its 'isProcessing' state for the next query.
          req.client.close()
        
        except CatchableError as e:
          debugLog("[CHAT-PROXY] ❌ ERROR: " & e.msg)
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
            applyOpenCodeHeaders(headers, authHeader)
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
      let headers = newHttpHeaders([("Content-Type", "application/json")])

      if toolName == "":
        let response = %*{"error": "Missing name parameter"}
        await req.respond(Http200, $response, headers)
        return

      # Defensive: arguments may arrive either as a JSON object (browser already
      # parsed) or as a raw JSON STRING (LLM streamed it). If string, run the
      # multi-level safe parser so malformed tool calls (LFM2.5 emits
      # {"file_path":"x","limit":}) don't fall through to "Missing file_path".
      var toolArgs: JsonNode
      if args.hasKey("arguments"):
        let rawArgs = args["arguments"]
        if rawArgs.kind == JString:
          toolArgs = tools.safeParseToolArgs(rawArgs.getStr())
        else:
          toolArgs = rawArgs
      else:
        toolArgs = %*{}

      let toolResult = tools.executeTool(toolName, toolArgs)
      await req.respond(Http200, toolResult, headers)
      return



    if path == "/":
      path = "/index.html"

    if path == "/api/cd":
      let headers = newHttpHeaders([("Content-Type", "application/json")])
      var targetDir = getCurrentDir()

      if req.url.query.len > 0:
        for param in req.url.query.split("&"):
          let parts = param.split("=")
          if parts.len == 2 and parts[0] == "path":
            let decoded = decodeUrlParam(parts[1])
            if decoded.len > 0:
              targetDir = decoded

      # Resolve relative paths against the project root (ExeDir) instead of the
      # current CWD, so that bookmarks with relative paths work consistently
      # regardless of previous directory navigation.
      if not isAbsolute(targetDir):
        {.cast(gcsafe).}:
          targetDir = ExeDir / targetDir
      targetDir = targetDir.replace("\\", "/")

      if dirExists(targetDir):
        {.cast(gcsafe).}:
          SessionDir = targetDir
        setCurrentDir(targetDir)
        let response = %*{"ok": true, "path": targetDir}
        await req.respond(Http200, $response, headers)
      else:
        let response = %*{"ok": false, "error": "Directory not found: " & targetDir}
        await req.respond(Http200, $response, headers)
      return

    if path == "/api/list-dir":
      let headers = newHttpHeaders([("Content-Type", "application/json")])
      var targetDir = getCurrentDir()

      if req.url.query.len > 0:
        for param in req.url.query.split("&"):
          let parts = param.split("=")
          if parts.len == 2 and parts[0] == "path":
            let decoded = decodeUrlParam(parts[1])
            if dirExists(decoded):
              targetDir = decoded

      var entries: seq[JsonNode] = @[]
      try:
        for (kind, filePath) in walkDir(targetDir, relative = true):
          let fullPath = targetDir / filePath
          var entry = %*{
            "name": filePath,
            "type": if kind == pcDir: "dir" else: "file"
          }
          if kind == pcFile:
            entry["size"] = %getFileSize(fullPath)
          entry["modified"] = %getLastModificationTime(fullPath).format("yyyy-MM-dd HH:mm")
          entries.add(entry)
      except CatchableError as e:
        let errResponse = %*{"path": targetDir, "error": e.msg, "entries": []}
        await req.respond(Http200, $errResponse, headers)
        return

      # Normalize path separators to forward slashes for the frontend
      let normalizedPath = targetDir.replace("\\", "/")
      let response = %*{"path": normalizedPath, "entries": entries}
      await req.respond(Http200, $response, headers)
      return

    if path == "/api/launch-llama":
      let headers = newHttpHeaders([("Content-Type", "application/json")])
      launchDetached(r"C:\down\llama-latest\lancia_router.bat")
      debugLog("Launching llama server via /api/launch-llama endpoint")
      let response = %*{"ok": true, "message": "Llama server launched"}
      await req.respond(Http200, $response, headers)
      return

    if path == "/api/llama-log":
      let headers = newHttpHeaders([("Content-Type", "application/json")])
      var logDir: string
      {.cast(gcsafe).}:
        logDir = if ExeDir.len > 0: ExeDir else: getCurrentDir()
      let logPath = logDir / "llama_server.log"
      var lines: seq[string] = @[]
      if fileExists(logPath):
        try:
          let content = readFile(logPath)
          var allLines = content.splitLines()
          # Filter empty lines, keep last 2 non-empty
          var nonEmpty: seq[string] = @[]
          for l in allLines:
            if l.len > 0:
              nonEmpty.add(l)
          let n = nonEmpty.len
          if n > 0:
            lines = nonEmpty[n - min(n, 2) .. ^1]
        except:
          discard
      let response = %*{"lines": lines}
      await req.respond(Http200, $response, headers)
      return

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
  except CatchableError as topErr:
    # Catch-all: any unhandled exception gets logged and returned as 500
    debugLog("/api UNHANDLED ERROR: " & topErr.msg)
    try:
      let errHeaders = newHttpHeaders([("Content-Type", "application/json")])
      let errBody = %*{"error": topErr.msg}
      await req.respond(Http500, $errBody, errHeaders)
    except:
      discard

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