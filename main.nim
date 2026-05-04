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

  # Initialize lastServerCheck to now to prevent immediate async check
  # after the synchronous startup check
  lastServerCheck = epochTime()

  # Load OpenCode config from ~/.nim_chatbot/
  server.loadOpenCodeConfig()

  # Load Ollama config from ~/.nim_chatbot/
  server.loadOllamaConfig()

  # --- Load previous state ---
  server.loadModelStatus()

  # --- Fetch models at startup (async) ---
  asyncCheck server.fetchModels()

  # --- Initial server check removed ---
  # Server availability is now checked asynchronously.
  # Default is true (set in config.nim), async check will update if needed.

  # --- Welcome messages ---
  outputLines.add("Chat TUI - Connected to llama.cpp at " & ServerBaseUrl)
  outputLines.add("   Press Enter to send, Esc or /q to quit")
  outputLines.add("   /model: change model | /new: reset chat")
  outputLines.add("   /history <num>: message memory (current: " &
                   $maxHistoryMessages & ")")

  # --- Main loop ---
  while true:
    # (a) Periodic server check (async, non-blocking)
    # EDIT: check runs every 30s regardless of current state to detect
    # both server going offline and coming back online.
    let now = epochTime()
    if (now - lastServerCheck > 30.0):
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
    #
    # ----------------------------------------------------------------
    # NOTE ON MOUSE WHEEL FIX (2026-05-03):
    #
    # The mouse wheel did not work on Windows because of a bug in illwill
    # (v0.4.1) that consumed and discarded mouse events before the mouse
    # handler could process them. Three patches were applied to illwill.nim:
    #
    # ROOT CAUSE:
    #   getchTimeout() (illwill.nim, ~line 412) used readConsoleInput()
    #   directly to pull events from the Windows console buffer.  When a
    #   MOUSE_EVENT was encountered (eventType != 1), the function simply
    #   continued its loop — but the event had already been consumed and
    #   was lost.  hasMouseInput() (called afterwards) found nothing.
    #
    # FIX LOCATION 1 — getchTimeout() (illwill.nim, ~line 421-428):
    #   Added a PeekConsoleInputA() call BEFORE readConsoleInput().
    #   If the peeked event is a MOUSE_EVENT, the function returns
    #   immediately WITHOUT consuming it, leaving the event in the buffer
    #   for hasMouseInput() to handle.
    #
    # FIX LOCATION 2 — hasMouseInput() (illwill.nim, ~line 842-846):
    #   Added a guard: only call readConsoleInput() if the FIRST event
    #   in the buffer is a MOUSE_EVENT.  This prevents consuming keyboard
    #   events when scanning for mouse events.
    #
    # FIX LOCATION 3 — getKey() & getKeyWithTimeout() (illwill.nim,
    #   ~line 855-869 and ~line 872-886):
    #   Swapped the order: hasMouseInput() is now called BEFORE
    #   getKeyAsync(), so mouse events are captured before getchTimeout()
    #   has a chance to peek at (and skip) them.
    #
    # ⚠️  If illwill is updated, these three patches MUST be reapplied.
    #     Search for "FIX:" in the patched functions to locate them.
    # ----------------------------------------------------------------
    var key = getKey()
    if key != illwill.Key.None:
      if key == illwill.Key.Mouse:
        # Handle mouse wheel scrolling
        let mi = illwill.getMouse()
        # DEBUG: log all mouse event data to mouse_debug.txt
        try:
          let f = open("mouse_debug.txt", fmAppend)
          f.write("Time=" & $now() & " scroll=" & $mi.scroll & " dir=" & $mi.scrollDir & " btn=" & $mi.button & " act=" & $mi.action & " move=" & $mi.move & " x=" & $mi.x & " y=" & $mi.y & "\n")
          f.close()
        except: discard

        if mi.scroll:
          if state == SelectingModel:
            # Scroll the model selection menu
            if mi.scrollDir == sdUp:
              if selectedMenuIndex > 0: dec(selectedMenuIndex)
            elif mi.scrollDir == sdDown:
              if selectedMenuIndex < availableModels.len - 1: inc(selectedMenuIndex)
          else:
            # Scroll the chat history
            # Standard mouse wheel behavior:
            # sdUp (Away) -> Scroll UP (see older) -> Increase offset
            # sdDown (Towards) -> Scroll DOWN (see newer) -> Decrease offset
            if mi.scrollDir == sdUp:
              scrollOffset += 3  # Increase for faster wheel scrolling
            elif mi.scrollDir == sdDown:
              if scrollOffset >= 3: scrollOffset -= 3
              else: scrollOffset = 0
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
