# ============================================================
# providers.nim - External provider configuration loaders
# ============================================================
# Responsibilities:
# - Load config for OpenCode, Ollama, Nvidia, Zaya providers
# - Read from models.json and auth.json files
#
# Dependencies: config.nim
# IMPORTANT: do not import chat.nim, input.nim, ui.nim, main.nim
# ============================================================

import os, json, strutils
import config
proc loadOpenCodeConfig*() =
  ## Legge ~/.nim_chatbot/models.json e auth.json.
  ## Se entrambi esistono e contengono dati validi per opencode,
  ## abilita il server OpenCode (OpenCodeEnabled = true).
  if not fileExists(ExternalModelsFile): return
  if not fileExists(AuthFile): return

  # Clear previous model list to avoid duplicates
  OpenCodeModelIds = @[]

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

proc loadOllamaConfig*() =
  ## Legge ~/.nim_chatbot/models.json e auth.json.
  ## Se entrambi esistono e contengono dati validi per ollama,
  ## abilita il server Ollama (OllamaEnabled = true).
  if not fileExists(ExternalModelsFile): return
  if not fileExists(AuthFile): return

  # Clear previous model list to avoid duplicates
  OllamaModelIds = @[]

  try:
    # --- models.json ---
    let modelsContent = readFile(ExternalModelsFile)
    let modelsJson = parseJson(modelsContent)
    let ollamaProvider = modelsJson["providers"]["ollama"]
    let ollamaBaseUrl = ollamaProvider["baseUrl"].getStr()
    if ollamaBaseUrl.len == 0: return

    # Deriva la base URL per la lista modelli:
    # da "https://ollama.com/v1" → "https://ollama.com"
    let idx = ollamaBaseUrl.find("/v1")
    if idx < 0: return
    OllamaModelsUrl = ollamaBaseUrl[0 .. idx - 1]  # "https://ollama.com"

    # Leggi i modelli direttamente da models.json
    let modelList = ollamaProvider["models"]
    for m in modelList:
      OllamaModelIds.add(m.getStr())

    # --- auth.json ---
    let authContent = readFile(AuthFile)
    let authJson = parseJson(authContent)
    let apiKey = authJson["ollama"]["key"].getStr()
    if apiKey.len == 0: return
    OllamaApiKey = apiKey

    # Tutto ok → abilita
    OllamaBaseUrl = ollamaBaseUrl & "/chat/completions"
    OllamaEnabled = true
  except: discard

proc loadNvidiaConfig*() =
  ## Legge ~/.nim_chatbot/models.json e auth.json.
  ## Se entrambi esistono e contengono dati validi per nvidia,
  ## abilita il server Nvidia (NvidiaEnabled = true).
  if not fileExists(ExternalModelsFile): return
  if not fileExists(AuthFile): return

  # Clear previous model list to avoid duplicates
  NvidiaModelIds = @[]

  try:
    # --- models.json ---
    let modelsContent = readFile(ExternalModelsFile)
    let modelsJson = parseJson(modelsContent)
    let nvidiaProvider = modelsJson["providers"]["nvidia"]
    let nvidiaBaseUrl = nvidiaProvider["baseUrl"].getStr()
    if nvidiaBaseUrl.len == 0: return

    # Deriva la base URL per la lista modelli:
    # da ".../v1/chat/completions" → ".../v1"
    let idx = nvidiaBaseUrl.find("/chat/completions")
    if idx < 0: return
    NvidiaModelsUrl = nvidiaBaseUrl[0 .. idx - 1]  # ".../v1"

    # Leggi i modelli direttamente da models.json
    let modelList = nvidiaProvider["models"]
    for m in modelList:
      NvidiaModelIds.add(m.getStr())

    # --- auth.json ---
    let authContent = readFile(AuthFile)
    let authJson = parseJson(authContent)
    let apiKey = authJson["nvidia"]["key"].getStr()
    if apiKey.len == 0: return
    NvidiaApiKey = apiKey

    # Tutto ok → abilita
    NvidiaBaseUrl = nvidiaBaseUrl
    NvidiaEnabled = true
  except: discard

proc loadZayaConfig*() =
  ## Legge ~/.nim_chatbot/models.json e auth.json.
  ## Se entrambi esistono e contengono dati validi per zaya,
  ## abilita il server Zaya (ZayaEnabled = true).
  if not fileExists(ExternalModelsFile): return
  if not fileExists(AuthFile): return

  # Clear previous model list to avoid duplicates
  ZayaModelIds = @[]

  try:
    # --- models.json ---
    let modelsContent = readFile(ExternalModelsFile)
    let modelsJson = parseJson(modelsContent)
    let zayaProvider = modelsJson["providers"]["zaya"]
    let zayaBaseUrl = zayaProvider["baseUrl"].getStr()
    if zayaBaseUrl.len == 0: return

    # Deriva la base URL per la lista modelli:
    # da ".../api/v1" → ".../api/v1" (stessa, ma per completezza)
    ZayaModelsUrl = zayaBaseUrl

    # Leggi i modelli direttamente da models.json
    let modelList = zayaProvider["models"]
    for m in modelList:
      ZayaModelIds.add(m.getStr())

    # --- auth.json ---
    let authContent = readFile(AuthFile)
    let authJson = parseJson(authContent)
    let apiKey = authJson["zaya"]["key"].getStr()
    if apiKey.len == 0: return
    ZayaApiKey = apiKey

    # Tutto ok → abilita
    ZayaBaseUrl = zayaBaseUrl & "/chat/completions"
    ZayaEnabled = true
  except: discard
