# ============================================================
# ui.nim - TUI rendering and terminal management
# ============================================================
# Responsibilities:
# - Draw the complete interface (output, input, status bar, menus)
# - Unicode-aware word wrapping
# - Suspend/resume the TUI for external editors (openInMicro)
#
# Dependencies: config.nim, illwill, unicode, strutils, strformat, osproc
# IMPORTANT: do not import input.nim, chat.nim, server.nim, main.nim
# ============================================================

import illwill, unicode, strutils, strformat, osproc, os
import config

# ============================================================
# Callback for exitProc (set by main.nim at startup)
# ============================================================
# openInMicro needs exitProc for setControlCHook after
# resuming the TUI. Since exitProc is defined in main.nim,
# we use this callback mechanism to avoid circular dependencies.

var gExitProc: proc () {.noconv.} = nil

proc setOpenInMicroExit*(p: proc () {.noconv.}) =
  ## Sets the exit proc used by openInMicro.
  ## Call from main.nim after defining exitProc.
  gExitProc = p

# ============================================================
# External editor launcher (micro)
# ============================================================

proc openInMicro*(filename: string) =
  ## Opens a file in the micro editor, temporarily suspending the TUI.
  ##
  ## FLOW:
  ## 1. Suspend the TUI (illwillDeinit, show cursor)
  ## 2. Run micro and wait for it to close
  ## 3. Resume the TUI (illwillInit, hide cursor)
  ##
  ## EDIT: if you need to use a different editor, modify
  ## the execCmd call below.
  try:
    # Suspend the TUI
    illwillDeinit()
    showCursor()
    # Execute micro and wait for it to close
    discard execCmd("micro " & quoteShell(filename))
  except:
    outputLines.add("System: Error opening file in micro editor")
  finally:
    # Resume the TUI
    illwillInit(fullscreen = true)
    hideCursor()
    if gExitProc != nil:
      setControlCHook(gExitProc)

# ============================================================
# Unicode-aware word wrapping
# ============================================================

proc wrapText*(text: string, width: int): seq[string] =
  ## Word wrapping that correctly handles Unicode characters.
  ## 1. Uses toRunes to avoid splitting multi-byte UTF-8 characters.
  ## 2. Searches for the last space to avoid breaking words.
  ##
  ## EDIT: to change the maximum width or wrapping behavior,
  ## modify here.
  if text.len == 0: return @[""]
  let w = max(1, width)
  var lines: seq[string] = @[]
  let runes = toRunes(text)
  var i = 0
  while i < runes.len:
    if runes.len - i <= w:
      lines.add($runes[i .. ^1])
      break

    # Look for the last space within width for word wrapping
    var lastSpace = -1
    for j in 0 ..< w:
      if runes[i + j] == Rune(32):
        lastSpace = j

    if lastSpace != -1:
      # Found a space, wrap there
      lines.add($runes[i ..< i + lastSpace])
      i += lastSpace + 1  # Skip the space character
    else:
      # No space found, hard wrap at the boundary
      lines.add($runes[i ..< i + w])
      i += w
  return lines

# ============================================================
# Status bar (bottom of screen)
# ============================================================

proc drawStatusBar*(tb: var TerminalBuffer, y, w: int) =
  ## Draws the status bar at the bottom of the screen.
  ## Shows: server status, processing status, model, message count.
  ##
  ## EDIT: to add more info to the status bar, modify
  ## statusText below.
  tb.setBackgroundColor(bgBlue)
  tb.setForegroundColor(fgWhite, bright = true)

  let serverStatus = if serverAvailable: "🟢" else: "🔴"
  let processStatus = if isProcessing: "⏳ Processing..." else: "✓ Ready"
  let modelShort = if ModelName.len > 15: ModelName[0 .. 14] & "..." else: ModelName

  let statusText = fmt" {serverStatus} {processStatus} | Model: {modelShort} | Messages: {outputLines.len} "

  tb.write(0, y, strutils.repeat(" ", w))
  tb.write(0, y, statusText)
  tb.setBackgroundColor(bgNone)

# ============================================================
# Model selection menu
# ============================================================

proc drawModelSelectionMenu*(tb: var TerminalBuffer, w, h: int) =
  ## Draws the model selection menu (SelectingModel state).
  ## Shows the list of available models with navigation.
  ##
  ## EDIT: to change the menu layout, modify here.
  tb.setForegroundColor(fgCyan, bright = true)
  let menuTitle = " SELECT MODEL "
  tb.write((w - menuTitle.len) div 2, 2, menuTitle)

  let startY = 5
  if availableModels.len == 0:
    tb.setForegroundColor(fgYellow)
    tb.write((w - 20) div 2, startY, "Loading models...")
  else:
    for i, m in availableModels:
      if startY + i >= h - 2: break
      if i == selectedMenuIndex:
        tb.setBackgroundColor(bgBlue)
        tb.setForegroundColor(fgWhite, bright = true)
        let line = "  ▶ " & m & "  "
        tb.write((w - line.len) div 2, startY + i, line)
        tb.setBackgroundColor(bgBlack)
      else:
        tb.setForegroundColor(fgWhite)
        # Mark the currently active model with a checkmark
        let prefix = if m == ModelName: "✓ " else: "  "
        tb.write((w - (prefix & m).len) div 2, startY + i, prefix & m)

  tb.setForegroundColor(fgWhite)
  let help = "↑/↓: Navigate, Enter: Confirm, Esc: Cancel"
  tb.write((w - help.len) div 2, h - StatusBarHeight - 1, help)

# ============================================================
# Full chat screen rendering
# ============================================================
## drawChatScreen is the main proc for rendering the chat.
## Draws: title, server banner, word-wrapped output,
## input bar, slash menu, status bar.
##
## This proc replaces the entire "else" block (chat mode)
## that was inline in the original main loop.

# Forward declaration (drawSlashMenu is defined further below)
proc drawSlashMenu*(tb: var TerminalBuffer, w, h, inputY: int)

proc drawChatScreen*(tb: var TerminalBuffer, w, h: int) =
  ## Draws the entire chat screen.
  ##
  ## EDIT: to change the chat layout (positions, colors, borders),
  ## modify here. Individual components are commented for easy
  ## navigation.

  # --- Fill the screen with black background ---
  tb.setBackgroundColor(bgBlack)
  tb.setForegroundColor(fgWhite)
  tb.fill(0, 0, w - 1, h - 1, " ")

  # --- Title ---
  tb.setBackgroundColor(bgBlue)
  tb.setForegroundColor(fgWhite, bright = true)
  let title = fmt" CHAT 🤖 {ModelName} "
  let titleX = max(1, (w - title.len) div 2)
  tb.write(titleX, 0, title)

  # Help text next to the title
  tb.setForegroundColor(fgWhite)
  tb.write(titleX + title.len + 2, 0, "Esc/Q=quit")
  tb.setBackgroundColor(bgNone)

  # --- Server unavailable banner ---
  let bannerOffset = if not serverAvailable: 1 else: 0
  if not serverAvailable:
    let banner = " ⚠ SERVER UNAVAILABLE - Start llama-server.exe ⚠ "
    tb.setBackgroundColor(bgRed)
    tb.setForegroundColor(fgWhite, bright = true)
    tb.write(max(1, (w - banner.len) div 2), 1, banner)
    tb.setBackgroundColor(bgBlack)

  # --- Collect output lines with word wrapping ---
  var allDisplayLines: seq[string] = @[]
  for line in outputLines:
    for wrapped in wrapText(line, w):
      allDisplayLines.add(wrapped)

  # Processing indicator if waiting
  if isProcessing and aiResponseBuffer.len == 0:
    allDisplayLines.add("... Waiting for response...")

  # --- Calculate input bar position ---
  let contentStartY = 1 + bannerOffset
  let inputBarNeeded = InputGap + InputBarHeight

  # Space needed for the slash menu if visible
  let slashMenuSpace = block:
    if showingSlashMenu and state == Chatting:
      let filtered = filterSlashCommands(currentInput[1 .. ^1])
      min(filtered.len, SlashMenuHeight) + 2  # +2 for border lines
    else:
      0

  var inputY: int
  var showFrom, showTo: int

  # Total space needed at the bottom: input + slash menu + status bar
  let bottomSpaceNeeded = inputBarNeeded + slashMenuSpace + StatusBarHeight

  if contentStartY + allDisplayLines.len + bottomSpaceNeeded <= h:
    # Content fits → input bar floats below content
    inputY = contentStartY + allDisplayLines.len + InputGap
    showFrom = 0
    showTo = allDisplayLines.len
  else:
    # Content too long → pin input bar above status bar, scroll output
    inputY = h - StatusBarHeight - InputBarHeight - slashMenuSpace
    if inputY < contentStartY + 2:
      inputY = h - StatusBarHeight - InputBarHeight  # Fallback
    let visibleRows = max(1, inputY - contentStartY)
    scrollOffset = max(0, min(scrollOffset, max(0, allDisplayLines.len - visibleRows)))
    showFrom = if allDisplayLines.len > visibleRows:
      max(0, allDisplayLines.len - visibleRows - scrollOffset)
    else:
      0
    showTo = min(showFrom + visibleRows, allDisplayLines.len)

  # --- Draw visible output lines ---
  var y = 1 + bannerOffset
  var inAIResponse = false
  for i in showFrom ..< showTo:
    if y >= inputY: break
    let line = allDisplayLines[i]
    if line.startsWith("Tu:"):
      inAIResponse = false
      tb.setForegroundColor(fgWhite)
    elif line.startsWith("AI:"):
      inAIResponse = true
      tb.setForegroundColor(fgGreen, bright = true)
    elif line.startsWith("..."):
      tb.setForegroundColor(fgYellow, bright = true)
    elif inAIResponse:
      tb.setForegroundColor(fgGreen, bright = true)
    elif line.startsWith("Chat TUI") or line.startsWith("   Premi") or
         line.startsWith("   /model") or line.startsWith("   /history") or
         line.startsWith("System:"):
      tb.setForegroundColor(fgYellow, bright = true)
    else:
      tb.setForegroundColor(fgWhite)
    tb.write(0, y, line)
    inc(y)

  # --- Redraw the title over the output area ---
  tb.setBackgroundColor(bgBlue)
  tb.setForegroundColor(fgWhite, bright = true)
  tb.write(titleX, 0, title)
  tb.setBackgroundColor(bgNone)
  tb.setForegroundColor(fgWhite)
  tb.write(titleX + title.len + 2, 0, "Esc/Q")
  tb.setBackgroundColor(bgBlue)

  # --- Input bar ---
  tb.setBackgroundColor(bgNone)
  # Top delimiter line (thin blue)
  tb.setForegroundColor(fgBlue, bright = true)
  tb.write(0, inputY, strutils.repeat("_", w))

  # "INPUT" label
  tb.setForegroundColor(fgCyan, bright = true)
  tb.write(0, inputY + 1, " INPUT ")
  tb.setBackgroundColor(bgNone)

  # Prompt character
  tb.setForegroundColor(fgWhite, bright = true)
  tb.write(0, inputY + 2, PromptChar)

  # Current input text
  if isProcessing:
    tb.setForegroundColor(fgWhite)
    tb.write(PromptChar.len, inputY + 2, "(processing...)")
  else:
    tb.setForegroundColor(fgWhite)
    tb.write(PromptChar.len, inputY + 2, currentInput)

  # Block cursor
  if not isProcessing:
    let cursorX = PromptChar.len + countRunes(currentInput)
    if cursorX < w:
      tb.setBackgroundColor(bgYellow)
      tb.setForegroundColor(fgBlack)
      tb.write(cursorX, inputY + 2, " ")
      tb.setBackgroundColor(bgNone)

  # Bottom delimiter line
  tb.setForegroundColor(fgBlue, bright = true)
  tb.write(0, inputY + 3, strutils.repeat("_", w))

  # --- Slash command menu (if active) ---
  if showingSlashMenu and state == Chatting:
    drawSlashMenu(tb, w, h, inputY)

  # --- Status bar ---
  drawStatusBar(tb, h - StatusBarHeight, w)

  # --- Reset attributes ---
  tb.resetAttributes()

# ============================================================
# Slash command menu (popup)
# ============================================================

proc drawSlashMenu*(tb: var TerminalBuffer, w, h, inputY: int) =
  ## Draws the slash command popup below the input bar.
  ## Shows filtered commands with navigation arrows.
  ##
  ## EDIT: to change the slash menu layout, modify here.
  let filtered = filterSlashCommands(currentInput[1 .. ^1])
  if filtered.len == 0: return

  let menuY = inputY + 4  # One row below the bottom delimiter
  let maxItems = min(filtered.len, SlashMenuHeight)

  # Calculate menu width based on the longest command + description
  var maxCmdLen = 0
  for idx in filtered:
    let totalLen = SlashCommands[idx].name.len + 3 + SlashCommands[idx].description.len
    if totalLen > maxCmdLen:
      maxCmdLen = totalLen
  let menuWidth = min(w, max(w div 2, maxCmdLen + 4))

  # Draw each menu item with ">" arrow for selection
  for row in 0 ..< maxItems:
    if menuY + row >= h: break
    let cmd = SlashCommands[filtered[row]]
    let arrow = if row == slashMenuIndex: ">" else: " "

    # Arrow (yellow for selected)
    if row == slashMenuIndex:
      tb.setForegroundColor(fgYellow, bright = true)
    else:
      tb.setForegroundColor(fgWhite)
    tb.write(0, menuY + row, arrow)

    # Command name
    tb.setForegroundColor(fgCyan, bright = true)
    tb.write(2, menuY + row, cmd.name)

    # Description
    tb.setForegroundColor(fgWhite)
    tb.write(cmd.name.len + 3, menuY + row, cmd.description)

  # Subtle bottom separator
  if menuY + maxItems < h:
    tb.setForegroundColor(fgWhite)
    tb.write(0, menuY + maxItems, strutils.repeat("─", menuWidth))

  # Reset attributes
  tb.setBackgroundColor(bgBlack)
  tb.setForegroundColor(fgWhite)
