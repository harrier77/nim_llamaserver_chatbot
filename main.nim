# ============================================================
# main.nim - Application entry point
# ============================================================
# Responsibilities:
# - Application initialization (TUI, hooks, state)
# - Main loop: server check → draw → input → poll → sleep
# - Clean shutdown handling (exitProc)
#
# This is the module that "orchestrates" all others.
# IMPORTANT: do not import main.nim from other local modules
# ============================================================

import os, asyncdispatch, times
import illwill
import config   # constants, global variables, types
import server   # server and model management
import input    # keyboard input handling
import ui       # TUI rendering

# ============================================================
# Exit proc (terminal cleanup)
# ============================================================

proc exitProc() {.noconv.} =
  ## Terminal cleanup on exit.
  ## FIX: ensures the terminal doesn't stay colored after exit.
  ##
  ## FLOW:
  ## 1. Clears the current illwill buffer
  ## 2. Deinitializes illwill (restores screen on some platforms)
  ## 3. Sends ANSI reset code (fail-safe for modern terminals)
  ## 4. Shows cursor and exits
  ##
  ## EDIT: if additional cleanup operations are needed, add them here.
  try:
    var tb = newTerminalBuffer(terminalWidth(), terminalHeight())
    tb.resetAttributes()
    tb.display()
  except: discard

  # Deinitialize illwill
  illwillDeinit()

  # ANSI reset code (fail-safe)
  stdout.write("\e[0m")
  stdout.flushFile()

  showCursor()
  quit(0)

# ============================================================
# Entry point
# ============================================================

proc main() =
  ## Main application loop.
  ##
  ## FLOW:
  ## 1. Initialize TUI and hooks
  ## 2. Load state from status.json
  ## 3. Async fetch models
  ## 4. Infinite loop:
  ##    a. Periodic server check (async, non-blocking)
  ##    b. Create TerminalBuffer
  ##    c. Check terminal size
  ##    d. Draw (chat or model selection)
  ##    e. tb.display()
  ##    f. Get key → handleInput
  ##    g. Poll async events
  ##    h. Sleep(20ms)
  ##
  ## EDIT: to change the main loop behavior
  ## (e.g. sleep interval, server check frequency), modify here.

  # --- TUI initialization ---
  illwillInit(fullscreen = true, mouse = true)
  setControlCHook(exitProc)
  hideCursor()

  # Register exitProc for openInMicro (callback to avoid circular dependencies)
  ui.setOpenInMicroExit(exitProc)

  # --- Load previous state ---
  server.loadModelStatus()

  # --- Fetch models at startup (async) ---
  asyncCheck server.fetchModels()

  # --- Welcome messages ---
  outputLines.add("Chat TUI - Connected to llama.cpp at " & ServerBaseUrl)
  outputLines.add("   Press Enter to send, Esc or /q to quit")
  outputLines.add("   /model: change model | /new: reset chat")
  outputLines.add("   /history <num>: message memory (current: " &
                   $maxHistoryMessages & ")")

  # --- Main loop ---
  while true:
    # (a) Periodic server check (async, non-blocking)
    let now = epochTime()
    if not serverAvailable and (now - lastServerCheck > 3.0):
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
    tb.display()

    # (f) Get key → handleInput
    var key = getKey()
    if key != illwill.Key.None:
      if key == illwill.Key.Mouse:
        # Handle mouse wheel scrolling
        let mi = illwill.getMouse()
        # DEBUG: salva tutti i dati
        try:
          let f = open("mouse_debug.txt", fmAppend)
          f.write("Mouse: scroll=" & $mi.scroll & " dir=" & $mi.scrollDir & " btn=" & $mi.button & " act=" & $mi.action & " move=" & $mi.move & " x=" & $mi.x & " y=" & $mi.y & "\n")
          f.close()
        except: discard
        if mi.scroll:
          if mi.scrollDir == ScrollDirection.sdUp:
            scrollOffset += 1
          elif mi.scrollDir == ScrollDirection.sdDown:
            if scrollOffset > 0: scrollOffset -= 1
      elif input.handleInput(key):
        exitProc()

    # (g) Poll async events
    try:
      poll()
    except:
      discard

    # (h) Sleep
    sleep(20)

# ============================================================
# Application startup
# ============================================================

main()
