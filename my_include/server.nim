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
# OpenCode config loader
# ============================================================

proc loadOpenCodeConfig*() =
  ## Legge ~/.nim_chatbot/models.json e auth.json.
  ## Se entrambi esistono e contengono dati validi per opencode,
  ## abilita il server OpenCode (OpenCodeEnabled = true).
  if not fileExists(ExternalModelsFile): return
  if not fileExists(AuthFile): return

  try:
    # --- models.json ---
    let modelsContent = readFile(ExternalModelsFile)
    let modelsJson = parseJson(modelsContent)
    let ocProvider = modelsJson["providers"]["opencode"]
    let ocBaseUrl = ocProvider["baseUrl"].getStr()
    if ocBaseUrl.len == 0: return

    # Deriva la base URL per la lista modelli:
    # da ".../v1/chat/completions" → ".../v1"
    let idx = ocBaseUrl.find("/chat/completions")
    if idx < 0: return
    OpenCodeModelsUrl = ocBaseUrl[0 .. idx - 1]  # ".../v1"

    # --- auth.json ---
    let authContent = readFile(AuthFile)
    let authJson = parseJson(authContent)
    OpenCodeApiKey = authJson["opencode"]["key"].getStr()
    if OpenCodeApiKey.len == 0: return

    # Tutto ok → abilita
    OpenCodeBaseUrl = ocBaseUrl
    OpenCodeEnabled = true
  except: discard

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
  ## Fetches the list of available models from the server (/v1/models).
  ## Updates the global variables: availableModels, selectedMenuIndex.
  ## If the server does not respond, uses the current model as fallback.
  ##
  ## EDIT: if you need to change how models are filtered/sorted,
  ## modify the logic after JSON parsing.
  availableModels = @[]
  
  # 1. Try to fetch local models (don't block if it fails)
  var client = newAsyncHttpClient()
  try:
    let response = await client.get(ServerBaseUrl & "/v1/models")
    let jsonNode = parseJson(await response.body())
    if jsonNode.hasKey("data"):
      for model in jsonNode["data"]:
        availableModels.add(model["id"].getStr())
  except:
    discard # Ignore local server error for now
  finally:
    client.close()

  # 2. Try to fetch OpenCode models (if enabled)
  if OpenCodeEnabled:
    var ocClient = newAsyncHttpClient()
    try:
      ocClient.headers = newHttpHeaders({
        "Authorization": "Bearer " & OpenCodeApiKey
      })
      let modelsUrl = OpenCodeModelsUrl & "/models"
      let response = await ocClient.get(modelsUrl)
      if response.code == Http200:
        let jsonNode = parseJson(await response.body())
        if jsonNode.hasKey("data"):
          for model in jsonNode["data"]:
            let mName = model["id"].getStr()
            let lowerName = mName.toLowerAscii()
            # Filtra: solo "big pickle" (cerca "pickle") o modelli con "free" nel nome
            if lowerName.contains("pickle") or lowerName.contains("free"):
              availableModels.add(mName)
              OpenCodeModelIds.add(mName)
    except:
      discard # Ignore OpenCode error
    finally:
      ocClient.close()

  # Fallback if nothing was found
  if availableModels.len == 0:
    availableModels.add(ModelName)
  
  # Find the current model in the list to set the default selection
  selectedMenuIndex = 0
  for i, m in availableModels:
    if m == ModelName:
      selectedMenuIndex = i
      break
