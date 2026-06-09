# ============================================================
# simple.nim - Simplified TUI-only chat (no mouse, no webui)
# ============================================================
# A stripped-down version of main.nim that provides only the
# chat TUI experience without mouse support or the WebUI server.
#
# Differences from main.nim:
# - No --chat flag: always runs in TUI mode
# - No mouse support (mouse = false in illwillInit)
# - No mouse hover/click handling in the main loop
# - No WebUI HTTP server
# - No "server mode" (non-interactive console mode)
# - Cleaner, minimal main loop
#
# Dependencies: same modules as main.nim (config, server,
#   system_prompt, providers, input, ui, chat)
# ============================================================

import os, asyncdispatch, times, strutils, httpclient, json
import illwill
import config   # constants, global variables, types
import server   # server and model management
import system_prompt  # system prompt (initSystemPrompt)
import providers  # external provider config loaders
from config_web import loadFirecrawlApiKey  # Firecrawl API key loader
import input    # keyboard input handling
import ui       # TUI rendering

# ============================================================
# Exit proc (terminal cleanup)
# ============================================================

proc exitProc() {.noconv.} =
  try:
    var tb = newTerminalBuffer(terminalWidth(), terminalHeight())
    tb.resetAttributes()
    tb.display()
  except: discard

  illwillDeinit()
  stdout.write("\e[0m")
  stdout.flushFile()
  showCursor()
  quit(0)

# ============================================================
# Entry point
# ============================================================

proc main() =
  ## Simplified main loop — TUI only, no mouse, no webui.

  # --- TUI initialization (no mouse) ---
  illwillInit(fullscreen = true, mouse = false)
  hideCursor()
  # WSL2: explicitly disable mouse tracking that Windows Terminal may leak
  when defined(linux):
    if isWSL2():
      stdout.write("\e[?1000l\e[?1002l\e[?1006l")
      stdout.flushFile()
  ui.setOpenInMicroExit(exitProc)
  setControlCHook(exitProc)

  # Initialize lastServerCheck to now to prevent immediate async check
  # after the synchronous startup check
  lastServerCheck = epochTime()

  # Load all providers from ~/.nim_chatbot/
  providers.loadProvidersConfig()

  # --- Load Firecrawl API key from auth.json ---
  loadFirecrawlApiKey()

  # --- Resolve ExeDir for PATH-independent resource lookup ---
  ExeDir = getAppFilename().parentDir()
  SessionDir = ExeDir
  StatusFile = ExeDir / "my_include" / "status.json"
  SystemPromptPath = ExeDir / "my_include" / "system_prompt.yaml"

  # --- Reload system prompt with correct ExeDir-relative path ---
  system_prompt.initSystemPrompt()
  # Refresh conversation history so the first system message uses the
  # correctly-loaded prompt (instead of the initial CWD-relative fallback)
  config.resetConversation()

  # --- Load previous state ---
  server.loadModelStatus()

  # --- Determina il provider corrente (anche prima della fetch asincrona) ---
  # Cerca prima per corrispondenza esatta del nome modello, poi per presenza
  # di qualsiasi provider remoto abilitato (copre il caso models.json senza
  # lista modelli e fetch asincrona non ancora completata).
  proc getCurrentProvider(): tuple[name, url: string, isRemote: bool] =
    let p = findProviderForModel(ModelName)
    if p.isRemote and p.name != "llamacpp":
      return (p.name, p.baseUrl, true)
    # Se findProviderForModel non ha trovato il modello nei modelIds
    # (fetch asincrona non ancora completata), cerca il primo provider
    # remoto che NON sia llamacpp (llamacpp è l'unico provider locale)
    for prov in providerList:
      if prov.enabled and prov.isRemote and prov.name != "llamacpp":
        return (prov.name, prov.baseUrl, true)
    return ("llamacpp", ServerBaseUrl, false)

  let (provName, provUrl, isRemoteProv) = getCurrentProvider()

  # --- Fetch models at startup (async) ---
  # Use custom fetch that also queries providers with empty model lists
  proc fetchModelsAll() {.async.} =
    ## Enhanced model fetch: calls server.fetchModels() first, then for any
    ## enabled provider that still has empty modelIds (e.g. because models.json
    ## had no list), queries its API endpoint to discover available models.
    ##
    ## This makes simple.nim work out-of-the-box with any OpenAI-compatible
    ## provider (2ndllama, etc.) without having to manually list models.
    await server.fetchModels()

    for i, p in providerList:
      if not p.enabled: continue
      if p.modelIds.len > 0: continue  # already has models

      # Skip local llamacpp (already handled by server.fetchModels)
      if not p.isRemote: continue

      var client = newAsyncHttpClient()
      try:
        if p.apiKey.len > 0:
          client.headers = newHttpHeaders({"Authorization": "Bearer " & p.apiKey})
        for h in p.extraHeaders:
          client.headers[h.key] = h.value

        let response = await client.get(p.modelsUrl & "/v1/models")
        if response.code == Http200:
          let jsonNode = parseJson(await response.body())
          if jsonNode.hasKey("data"):
            for model in jsonNode["data"]:
              let mName = model["id"].getStr()
              providerList[i].modelIds.add(mName)
              availableModels.add(mName)
      except:
        discard
      finally:
        client.close()

    if availableModels.len == 0:
      availableModels.add(ModelName)

  asyncCheck fetchModelsAll()

  # --- Welcome messages ---
  if isRemoteProv:
    outputLines.add("Chat TUI - startup provider: " & provName & " (" & provUrl & ")")
  else:
    outputLines.add("Chat TUI - Local llama.cpp at " & ServerBaseUrl)
  outputLines.add("   Press Enter to send, Esc or /q to quit")
  outputLines.add("   /model: change model | /new: reset chat")
  outputLines.add("   /history <num>: message memory (current: " &
                  $maxHistoryMessages & ")")
  outputLines.add("   /cd <dir>: change working directory")

  # --- Main loop ---
  while true:
    # (a) Periodic server check (async, non-blocking)
    # If the current model uses a remote provider (e.g. 2ndllama),
    # skip the local server check so it never shows "server unavailable".
    let now = epochTime()
    if (now - lastServerCheck > 30.0):
      var curProvider = findProviderForModel(ModelName)
      # Fallback: se findProviderForModel non ha trovato il modello
      # (modelIds ancora vuoto), cerca il primo provider remoto
      # (escludendo llamacpp che è l'unico provider locale)
      if not curProvider.isRemote or curProvider.name == "llamacpp":
        for prov in providerList:
          if prov.enabled and prov.isRemote and prov.name != "llamacpp":
            curProvider = prov
            break
      if curProvider.isRemote and curProvider.name != "llamacpp":
        serverAvailable = true
      else:
        asyncCheck server.checkServerAsync()
      lastServerCheck = now

    # (b) Create TerminalBuffer
    var tb = newTerminalBuffer(terminalWidth(), terminalHeight())
    let w = tb.width
    let h = tb.height

    # (c) Check terminal size
    if h <= InputBarHeight + StatusBarHeight + 2 or w < 20:
      tb.setForegroundColor(fgRed, bright = true)
      tb.write(0, 0, "Terminal too small! Resize to continue.")
      tb.display()
      sleep(50)
      var key = getKey()
      if key == illwill.Key.Escape or key == illwill.Key.Q:
        exitProc()
      continue

    # (d) Draw the appropriate screen
    if state == SelectingModel:
      ui.drawModelSelectionMenu(tb, w, h)
    else:
      ui.drawChatScreen(tb, w, h)

    # Reset attributes and display the buffer
    tb.resetAttributes()
    if config.fullRedrawNeeded:
      setDoubleBuffering(true)
      config.fullRedrawNeeded = false
    tb.display()

    # (e) Get key → handleInput
    #
    # Flush input buffer first (handles paste / bulk input)
    input.flushInputBuffer()

    var key = getKey()
    if key != illwill.Key.None:
      # Keyboard input only — no mouse handling
      if input.handleInput(key):
        exitProc()

    # (f) Poll async events
    try:
      poll()
    except:
      discard

    # (g) Sleep
    sleep(20)

# ============================================================
# Application startup
# ============================================================

main()
