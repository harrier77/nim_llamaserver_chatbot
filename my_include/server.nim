# ============================================================
# server.nim - llama.cpp server management and models
# ============================================================
# Responsibilities:
# - Check if the server is alive (sync and async)
# - Load/save state from/to status.json
# - Fetch the list of available models from the server
#
# Dependencies: config.nim
# IMPORTANT: do not import chat.nim, input.nim, ui.nim, main.nim
# ============================================================

import httpclient, asyncdispatch, json, uri, os, strutils
import config

# ============================================================
# Server availability check
# ============================================================

proc checkServer*(): bool =
  ## SYNCHRONOUS check if the llama.cpp server is alive.
  ## Returns true if the server is reachable at /v1/models.
  ## EDIT: timeout is hardcoded to 5s, change here if needed.
  try:
    let client = newHttpClient()
    client.timeout = 5000
    let response = client.get(ServerBaseUrl & "/v1/models")
    client.close()
    return response.status == "200"
  except:
    return false

proc checkServerAsync*() {.async.} =
  ## ASYNCHRONOUS (non-blocking) check if the server is alive.
  ## Updates the global `serverAvailable` variable in config.
  ## Used in the main loop for periodic checks without blocking the UI.
  var client = newAsyncHttpClient()
  try:
    let response = await client.get(ServerBaseUrl & "/v1/models")
    serverAvailable = (response.code == Http200)
  except:
    serverAvailable = false
  finally:
    client.close()

# ============================================================
# State persistence (status.json)
# ============================================================

proc loadModelStatus*() =
  ## Loads the selected model and settings from status.json.
  ## Updates: ModelName, maxHistoryMessages, ServerBaseUrl/APIUrl.
  ## EDIT: if new settings need to be persisted, add the key here
  ## and in saveModelStatus.
  if not fileExists(StatusFile): return
  try:
    let content = readFile(StatusFile)
    let j = parseJson(content)
    if j.hasKey("selected_model"):
      ModelName = j["selected_model"].getStr()
      echo "Model loaded from status.json: ", ModelName
    if j.hasKey("max_history_messages"):
      maxHistoryMessages = j["max_history_messages"].getInt()
      echo "Max history messages loaded: ", maxHistoryMessages
    if j.hasKey("server_url"):
      # IMPORTANT: use updateServerUrl to also update APIUrl
      updateServerUrl(j["server_url"].getStr())
      echo "Server URL loaded from status.json: ", ServerBaseUrl
  except: discard

proc saveModelStatus*() =
  ## Saves the current model and settings to status.json.
  ## EDIT: if new settings are added, save them here too.
  try:
    let j = %*{
      "selected_model": ModelName,
      "max_history_messages": maxHistoryMessages,
      "server_url": ServerBaseUrl
    }
    writeFile(StatusFile, $j)
  except: discard

# ============================================================
# Fetch models from server
# ============================================================

proc fetchModels*() {.async.} =
  ## Fetches the list of available models from all providers.
  ## Populates availableModels and each provider's modelIds.
  availableModels = @[]

  for i, p in providerList:
    if not p.enabled: continue

    if p.name == "llamacpp":
      providerList[i].modelIds = @[]
      var clientLlama = newAsyncHttpClient()
      try:
        let response = await clientLlama.get(p.modelsUrl & "/v1/models")
        let jsonNode = parseJson(await response.body())
        if jsonNode.hasKey("data"):
          for model in jsonNode["data"]:
            let mName = model["id"].getStr()
            providerList[i].modelIds.add(mName)
            availableModels.add(mName)
      except: discard
      finally:
        clientLlama.close()

    elif p.name == "opencode" and p.apiKey.len > 0:
      providerList[i].modelIds = @[]
      var clientOc = newAsyncHttpClient()
      try:
        clientOc.headers = newHttpHeaders({"Authorization": "Bearer " & p.apiKey})
        let response = await clientOc.get(p.modelsUrl & "/models")
        if response.code == Http200:
          let jsonNode = parseJson(await response.body())
          if jsonNode.hasKey("data"):
            for model in jsonNode["data"]:
              let mName = model["id"].getStr()
              let lowerName = mName.toLowerAscii()
              if lowerName.contains("pickle") or lowerName.contains("free"):
                providerList[i].modelIds.add(mName)
                availableModels.add(mName)
      except: discard
      finally:
        clientOc.close()

    else:
      for mName in p.modelIds:
        availableModels.add(mName)

  if availableModels.len == 0:
    availableModels.add(ModelName)
