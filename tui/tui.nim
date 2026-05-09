# ============================================================
# tui.nim - Minimal TUI Editor (pi TUI-inspired)
# ============================================================
# A minimal terminal text editor inspired by the pi-coding-agent
# TUI architecture (https://github.com/earendil-works/pi).
#
# Features:
#   - Multi-line text buffer with word-wrapped visual lines
#   - Arrow key navigation (up/down/left/right) with sticky column
#   - Text insertion and deletion (backspace, delete, enter)
#   - Scrolling for long content
#   - Status bar with position info
#
# Dependencies:
#   - illwill (https://github.com/johnnovak/illwill)
#   - Nim standard library
#
# Usage:
#   nim c -r tui.nim
#   - or -
#   nimble build
#
# Keybindings:
#   Arrow keys   – navigate
#   Type         – insert text
#   Backspace    – delete character before cursor
#   Delete       – delete character at cursor
#   Enter        – new line
#   Home         – start of line (Ctrl+A)
#   End          – end of line (Ctrl+E)
#   Escape       – quit
#   Ctrl+C       – quit
# ============================================================

import illwill, strutils, os
import editor

# ============================================================
# Exit procedure
# ============================================================

proc exitProc() {.noconv.} =
  ## Cleans up the terminal and exits.
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
# Main entry point
# ============================================================

when isMainModule:
  # --- Initialise illwill ---
  illwillInit(fullScreen = true, mouse = false)
  setControlCHook(exitProc)

  # --- Create editor ---
  var ed = initEditor()

  # If a filename was provided as argument, load it
  if paramCount() > 0:
    let filename = paramStr(1)
    if fileExists(filename):
      try:
        let content = readFile(filename)
        ed.setText(content)
      except:
        discard  # Start with empty editor on error

  var running = true
  var frameCount = 0

  # --- Main loop ---
  while running:
    # (a) Get terminal dimensions
    let w = terminalWidth()
    let h = terminalHeight()

    # (b) Check minimum size
    if h < 4 or w < 10:
      var tb = newTerminalBuffer(w, h)
      tb.setForegroundColor(fgRed, bright = true)
      tb.write(0, 0, "Terminal too small! Resize to continue.")
      tb.display()
      sleep(50)
      let key = getKey()
      if key == illwill.Key.Escape or key == illwill.Key.CtrlC:
        exitProc()
      continue

    # (c) Create terminal buffer and draw
    var tb = newTerminalBuffer(w, h)
    tb.resetAttributes()

    # Draw the editor
    ed.drawEditor(tb)

    # (d) Display to terminal (double-buffered)
    tb.display()

    # (e) Process input (non-blocking)
    let key = getKey()

    if key != illwill.Key.None:
      case key
      of illwill.Key.Escape, illwill.Key.CtrlC:
        running = false

      of illwill.Key.Up:
        ed.moveCursor(-1, 0, w - 2)

      of illwill.Key.Down:
        ed.moveCursor(1, 0, w - 2)

      of illwill.Key.Left:
        ed.moveCursor(0, -1, w - 2)

      of illwill.Key.Right:
        ed.moveCursor(0, 1, w - 2)

      of illwill.Key.Home:
        ed.moveToLineStart()

      of illwill.Key.End:
        ed.moveToLineEnd()

      of illwill.Key.Backspace, illwill.Key.CtrlH:
        ed.handleBackspace()

      of illwill.Key.Delete:
        ed.handleDelete()

      of illwill.Key.Enter:
        ed.addNewLine()

      of illwill.Key.Tab:
        ed.insertChar("  ")  # 2-space tab

      of illwill.Key.CtrlA:
        ed.moveToLineStart()

      of illwill.Key.CtrlE:
        ed.moveToLineEnd()

      else:
        # Printable characters
        let code = ord(key)
        if code >= 32 and code <= 126:
          ed.insertChar($chr(code))

    # (f) Yield to avoid busy-waiting
    sleep(16)

  # --- Clean exit ---
  exitProc()
