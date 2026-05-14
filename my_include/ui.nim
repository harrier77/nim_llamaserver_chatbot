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
#
# ⚠ ILLWILL PATCHES REQUIRED ⚠
# If illwill is updated (e.g. via nimble update), the following patches
# MUST be reapplied to the installed illwill.nim file:
#   1. Patches 1-3: Mouse wheel fix (see main.nim for details)
#   2. Patch 4: MOUSE_MOVED check in fillGlobalMouseInfo() — prevents
#      mouse move events from being misinterpreted as clicks on some
#      Windows terminal configurations. Without this, the model selection
#      menu exits on any mouse movement.
# Search for "FIX:" in the patched functions to locate all patches.
# See: https://github.com/earendil/wind/mouse-illwill
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

proc openSystemPromptInNewConsole*() =
  ## Opens system_prompt.yaml in micro in a SEPARATE console window.
  ## Unlike openInMicro, this does NOT suspend the TUI — micro runs
  ## in its own window and the chat continues normally.
  try:
    let filepath = "my_include/system_prompt.yaml"
    when defined(windows):
      var p = startProcess("cmd.exe", args = @["/c", "start", "micro", filepath])
      p.close()
    else:
      discard execCmd("micro " & quoteShell(filepath))
    outputLines.add("System: Opened system_prompt.yaml in new console")
  except CatchableError as e:
    outputLines.add("System: Error opening system prompt: " & e.msg)

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

  let statusText = fmt" {serverStatus} {processStatus} | Model: {modelShort} | Hist: {maxHistoryMessages} | Msgs: {conversationHistory.len - 1} "

  tb.write(0, y, strutils.repeat(" ", w))
  tb.write(0, y, statusText)
  tb.setBackgroundColor(bgNone)

# ============================================================
# Model selection menu
# ============================================================

proc drawModelSelectionMenu*(tb: var TerminalBuffer, w, h: int) =
  ## Draws the model selection menu (SelectingModel state) with scroll support.
  ## Builds a flat list of items (headers + models) and renders only the
  ## visible portion based on modelSelectionScroll.
  tb.setForegroundColor(fgCyan, bright = true)
  let menuTitle = " SELEZIONE MODELLO "
  tb.write((w - menuTitle.len) div 2, 2, menuTitle)

  let startY = 5
  if availableModels.len == 0:
    tb.setForegroundColor(fgYellow)
    tb.write((w - 30) div 2, startY, "Loading models... (wait) or /model again")
    return

  # Build flat list of all display lines
  var allLines: seq[string] = @[]
  var lineTypes: seq[string] = @[]  # "header" or "model"
  var lineNums: seq[int] = @[]      # model number (1-based, 0 for headers)
  var lineModels: seq[string] = @[] # model id string ("" for headers)
  var counter = 0

  for p in providerList:
    if not p.enabled or p.modelIds.len == 0: continue
    let icon = if p.name == "llamacpp": "🖥" elif p.name == "opencode": "☁" elif p.name == "ollama": "🐳" elif p.name == "nvidia": "🔷" elif p.name == "zaya": "🔮" else: "📋"
    allLines.add("  " & icon & " " & p.name.toUpperAscii())
    lineTypes.add("header")
    lineNums.add(0)
    lineModels.add("")

    for mId in p.modelIds:
      counter.inc
      let check = if mId == ModelName: " ⬅" else: ""
      allLines.add("    " & $counter & ". " & mId & check)
      lineTypes.add("model")
      lineNums.add(counter)
      lineModels.add(mId)

  # Calculate visible area
  let bottomReserved = 4  # input line + help + status bar + padding
  let maxVisible = max(1, h - startY - bottomReserved)

  # Auto-scroll to show the model matching the typed number
  if modelSelectionBuffer.len > 0:
    try:
      let targetNum = parseInt(modelSelectionBuffer)
      for i, n in lineNums:
        if n == targetNum:
          modelSelectionScroll = max(0, i - maxVisible div 2)
          break
    except: discard

  # Clamp scroll offset
  if allLines.len > maxVisible:
    modelSelectionScroll = min(modelSelectionScroll, allLines.len - maxVisible)
  else:
    modelSelectionScroll = 0

  # Draw visible lines
  config.modelMenuClickAreas = @[]
  var y = startY
  for i in modelSelectionScroll ..< min(modelSelectionScroll + maxVisible, allLines.len):
    if y >= h - StatusBarHeight - 2: break
    if lineTypes[i] == "header":
      tb.setForegroundColor(fgCyan, bright = true)
    else:
      if lineNums[i] > 0 and lineModels[i] == ModelName:
        tb.setForegroundColor(fgYellow)
      else:
        tb.setForegroundColor(fgWhite)
    # Visualizzazione allineata a sinistra con un margine fisso per evitare troncamenti
    tb.write(max(2, (w - 40) div 2), y, allLines[i])
    if lineTypes[i] == "model" and lineNums[i] > 0:
      config.modelMenuClickAreas.add((y: y, modelName: lineModels[i]))
    inc(y)

  # Scroll indicators
  if modelSelectionScroll > 0:
    tb.setForegroundColor(fgWhite)
    tb.write(2, startY, "▲")
  if modelSelectionScroll + maxVisible < allLines.len:
    tb.setForegroundColor(fgWhite)
    tb.write(2, h - StatusBarHeight - 2, "▼")

  # Input line
  let inputY = min(h - StatusBarHeight - 2, y + 1)
  if inputY < h - StatusBarHeight:
    tb.setForegroundColor(fgYellow, bright = true)
    let promptLine = "  Numero: " & modelSelectionBuffer & "_"
    tb.write((w - promptLine.len) div 2, inputY, promptLine)

  # Help
  tb.setForegroundColor(fgWhite)
  let help = "Numero + Enter: conferma | ↑↓: scroll | Esc: annulla"
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

  # --- Title / Toolbar ---
  let titleModel = fmt"CHAT 🤖 {ModelName} "
  let newTag = "[new] "
  let modelliTag = "[Modelli] "
  let webuiTag = "[WebUI] "
  let quitText = "[Esc/Q=quit]"

  # Model name on the far left
  let modelNameX = 1

  # Buttons centered as a group
  let buttonsStr = newTag & modelliTag & webuiTag & quitText
  let buttonsX = max(1, (w - buttonsStr.len) div 2)

  # Model name (left-aligned) with highlighted background
  tb.setBackgroundColor(bgGreen)
  tb.setForegroundColor(fgWhite, bright = true)
  tb.write(modelNameX, 0, titleModel)
  tb.setBackgroundColor(bgBlack)

  # [new] button
  if hoveredButton == "new":
    tb.setBackgroundColor(bgWhite)
    tb.setForegroundColor(fgBlack)
    tb.write(buttonsX, 0, newTag)
    tb.setBackgroundColor(bgBlack)
  else:
    tb.setForegroundColor(fgWhite, bright = true)
    tb.write(buttonsX, 0, newTag)

  # [Modelli] button
  if hoveredButton == "modelli":
    tb.setBackgroundColor(bgWhite)
    tb.setForegroundColor(fgBlack)
    tb.write(buttonsX + newTag.len, 0, modelliTag)
    tb.setBackgroundColor(bgBlack)
  else:
    tb.setForegroundColor(fgWhite, bright = true)
    tb.write(buttonsX + newTag.len, 0, modelliTag)

  # [WebUI] button
  if hoveredButton == "webui":
    tb.setBackgroundColor(bgWhite)
    tb.setForegroundColor(fgBlack)
    tb.write(buttonsX + newTag.len + modelliTag.len, 0, webuiTag)
    tb.setBackgroundColor(bgBlack)
  else:
    tb.setForegroundColor(fgWhite, bright = true)
    tb.write(buttonsX + newTag.len + modelliTag.len, 0, webuiTag)

  # [Esc/Q=quit] button
  if hoveredButton == "quit":
    tb.setBackgroundColor(bgWhite)
    tb.setForegroundColor(fgBlack)
    tb.write(buttonsX + newTag.len + modelliTag.len + webuiTag.len, 0, quitText)
    tb.setBackgroundColor(bgBlack)
  else:
    tb.setForegroundColor(fgWhite, bright = true)
    tb.write(buttonsX + newTag.len + modelliTag.len + webuiTag.len, 0, quitText)

  # --- Server unavailable banner ---
  let bannerOffset = if not serverAvailable: 1 else: 0
  if not serverAvailable:
    let banner = " ⚠ SERVER UNAVAILABLE - Start llama-server.exe ⚠ "
    tb.setBackgroundColor(bgRed)
    tb.setForegroundColor(fgWhite, bright = true)
    tb.write(max(1, (w - banner.len) div 2), 2, banner)
    tb.setBackgroundColor(bgBlack)

  # --- Collect output lines with word wrapping ---
  var allDisplayLines: seq[string] = @[]
  var prevType = ""  # "Tu", "AI", or ""
  for line in outputLines:
    var curType = ""
    if line.startsWith("Tu:"):
      curType = "Tu"
    elif line.startsWith("AI:"):
      curType = "AI"

    # Insert blank line between Tu and AI transitions
    if prevType != "" and curType != "" and prevType != curType:
      allDisplayLines.add("")

    for wrapped in wrapText(line, w):
      allDisplayLines.add(wrapped)

    if curType != "":
      prevType = curType

  # Processing indicator if waiting
  if isProcessing and aiResponseBuffer.len == 0:
    allDisplayLines.add("... Waiting for response...")

  # --- Calculate input bar position ---
  let inputBarActualRows = 4  # delimiter + label + prompt + delimiter
  let contentStartY = 2 + bannerOffset
  let inputBarNeeded = InputGap + inputBarActualRows

  # Space needed for the slash menu if visible
  let slashMenuSpace = block:
    if showingSlashMenu and state == Chatting:
      let text = inputEditor.getText()
      let filtered = filterSlashCommands(if text.len > 0: text[1 .. ^1] else: "")
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
    let inputBarActualRows = 4  # delimiter + label + prompt + delimiter
    inputY = h - StatusBarHeight - inputBarActualRows - slashMenuSpace
    if inputY < contentStartY + 2:
      inputY = h - StatusBarHeight - inputBarActualRows  # Fallback
    let visibleRows = max(1, inputY - contentStartY)
    scrollOffset = max(0, min(scrollOffset, max(0, allDisplayLines.len - visibleRows)))
    showFrom = if allDisplayLines.len > visibleRows:
      max(0, allDisplayLines.len - visibleRows - scrollOffset)
    else:
      0
    showTo = min(showFrom + visibleRows, allDisplayLines.len)

  # --- Draw visible output lines ---
  var y = 2 + bannerOffset

  # FIX: determine inAIResponse state before showFrom so scrolled-in
  # continuation lines keep the correct green AI color
  var inAIResponse = false
  for j in 0 ..< showFrom:
    if allDisplayLines[j].startsWith("AI:"):
      inAIResponse = true
    elif allDisplayLines[j].startsWith("Tu:"):
      inAIResponse = false

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

  # Current input text using inputEditor
  if isProcessing:
    tb.setForegroundColor(fgWhite)
    tb.write(PromptChar.len, inputY + 2, "(processing...)")
  else:
    # Use the new drawEditorArea from editor.nim
    # Width is w - PromptChar.len, height is InputBarHeight - 2
    inputEditor.drawEditorArea(tb, PromptChar.len, inputY + 2,
                               w - PromptChar.len - 1, InputBarHeight - 2,
                               focused = not isProcessing, drawBorder = false)

  # Bottom delimiter line
  tb.setForegroundColor(fgBlue, bright = true)
  tb.write(0, inputY + InputBarHeight - 1, strutils.repeat("_", w))

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
  let text = inputEditor.getText()
  let filtered = filterSlashCommands(if text.len > 0: text[1 .. ^1] else: "")
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
