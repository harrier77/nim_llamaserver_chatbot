# ============================================================
# input.nim - Keyboard input handling and slash commands
# ============================================================
# Responsibilities:
# - Process keypresses from the user (handleInput)
# - Manage the slash command menu (updateSlashMenu)
# - Execute slash commands (/quit, /model, /new, /edit, /history)
#
# Dependencies: config.nim, server.nim, chat.nim, ui.nim
#   - server.nim: for fetchModels (/model command)
#   - chat.nim:   for sendToLLM (sending messages)
#   - ui.nim:     for openInMicro (/edit command)
# IMPORTANT: do not import main.nim
# ============================================================

import strutils, illwill, asyncdispatch, os, times
import config
import server   # for fetchModels
import chat     # for sendToLLM
import ui       # for openInMicro
import map_key_tochar

# ============================================================
# Slash command menu
# ============================================================

proc updateSlashMenu*() =
  ## Opens or closes the slash menu based on current input.
  ## Disables the menu if input contains spaces (has arguments).
  ## EDIT: to change when the menu appears, modify here.
  let text = inputEditor.getText()
  if text.len > 0 and text[0] == '/' and not text.contains(' '):
    showingSlashMenu = true
    # Clamp index when the filtered list shrinks
    let filtered = filterSlashCommands(text[1 .. ^1])
    if slashMenuIndex >= filtered.len and filtered.len > 0:
      slashMenuIndex = filtered.len - 1
    if filtered.len == 0:
      showingSlashMenu = false
  else:
    showingSlashMenu = false

proc flushInputBuffer*() =
  ## Flushes inputBuffer to inputEditor when buffer delay has elapsed
  ## OR when buffer has enough characters (handles paste / bulk input).
  if inputBuffer.len > 0:
    let now = epochTime()
    let elapsedMs = (now - lastInputCharTime) * 1000.0
    # Flush if: delay elapsed OR buffer has many chars (paste detected)
    if elapsedMs >= InputBufferDelay.float or inputBuffer.len >= InputBufferThreshold:
      # Insert buffer into editor
      inputEditor.insertChar(inputBuffer)
      inputBuffer = ""
      updateSlashMenu()

# ============================================================
# Slash commands with arguments
# ============================================================
# Simple commands (/quit, /model, /new) are handled in handleInput.
# Commands with arguments (/history, /edit) are handled here to
# keep handleInput more readable.

proc handleHistoryCommand*(cmdParts: seq[string], showOnly: bool = false) =
  ## Handles the /history <num> command.
  ## If showOnly is true, just displays the current value.
  ## If showOnly is false, tries to set a new value.
  if showOnly or cmdParts.len == 1:
    # Just show current value
    outputLines.add("System: Current history: " & $maxHistoryMessages & " messages")
    outputLines.add("System: Usage: /history <number> (1-100)")
  elif cmdParts.len == 2:
    try:
      let newVal = cmdParts[1].parseInt()
      if newVal >= 1 and newVal <= 100:
        maxHistoryMessages = newVal
        # Also save to status.json for persistence
        server.saveModelStatus()
        outputLines.add("System: Max history messages set to " & $maxHistoryMessages)
      else:
        outputLines.add("System: Value must be between 1 and 100")
    except:
      outputLines.add("System: Invalid number. Usage: /history <number>")
  else:
    outputLines.add("System: Current max history: " & $maxHistoryMessages &
                     ". Usage: /history <number>")

# ============================================================
# Keypress handling (main input handler)
# ============================================================
## handleInput is the most complex proc in this module.
## It handles:
##   - Slash menu navigation (Tab, Up, Down, Escape)
##   - Model selection (Up, Down, Enter, Escape)
##   - Slash commands (/quit, /model, /new, /history, /edit)
##   - Normal input (characters, backspace, Enter)
##   - Output scrolling (Up, Down)
##
## RETURN VALUE: true = exit the app, false = continue

proc handleInput*(key: illwill.Key): bool =
  ## Processes a keypress. Returns true if the app should exit.
  ## Uses inputEditor for all text operations.
  let w = terminalWidth()

  # Ignore input while processing (except scrolling and SelectingModel state)
  if (isProcessing or (not serverAvailable and not hasRemoteProvider())) and state == Chatting:
    case key
    of illwill.Key.Up:
      scrollOffset += 1
      return false
    of illwill.Key.Down:
      if scrollOffset > 0: scrollOffset -= 1
      return false
    else:
      let text = inputEditor.getText()
      if text.len > 0 and text[0] == '/' or key == illwill.Key.Slash:
        discard
      else:
        return false

  # --- Slash menu navigation ---
  if showingSlashMenu and state == Chatting:
    let text = inputEditor.getText()
    case key
    of illwill.Key.Escape:
      showingSlashMenu = false
      return false
    of illwill.Key.Tab:
      let filtered = filterSlashCommands(text[1 .. ^1])
      if filtered.len > 0:
        inputEditor.setText(SlashCommands[filtered[slashMenuIndex]].name)
        inputEditor.moveToLineEnd()
      return false
    of illwill.Key.Up:
      let filtered = filterSlashCommands(text[1 .. ^1])
      if filtered.len > 0 and slashMenuIndex > 0:
        dec(slashMenuIndex)
      return false
    of illwill.Key.Down:
      let filtered = filterSlashCommands(text[1 .. ^1])
      if filtered.len > 0 and slashMenuIndex < filtered.len - 1:
        inc(slashMenuIndex)
      return false
    of illwill.Key.Backspace, illwill.Key.CtrlH:
      inputEditor.handleBackspace()
      updateSlashMenu()
      return false
    of illwill.Key.Enter:
      let filtered = filterSlashCommands(text[1 .. ^1])
      if filtered.len > 0:
        inputEditor.setText(SlashCommands[filtered[slashMenuIndex]].name)
        inputEditor.moveToLineEnd()
        showingSlashMenu = false
        # Continue to execute
      else:
        showingSlashMenu = false
        return false
    else:
      showingSlashMenu = false

  # --- Model selection (number-based) ---
  if state == SelectingModel:
    case key
    of illwill.Key.Zero, illwill.Key.One, illwill.Key.Two, illwill.Key.Three,
       illwill.Key.Four, illwill.Key.Five, illwill.Key.Six, illwill.Key.Seven,
       illwill.Key.Eight, illwill.Key.Nine:
      modelSelectionBuffer &= $chr(ord(key))
      return false
    of illwill.Key.Enter:
      if modelSelectionBuffer.len > 0:
        try:
          let idx = parseInt(modelSelectionBuffer) - 1
          if idx >= 0 and idx < availableModels.len:
            ModelName = availableModels[idx]
            server.saveModelStatus()
            outputLines.add("System: Model changed to " & ModelName)
        except: discard
      modelSelectionBuffer = ""
      state = Chatting
      return false
    of illwill.Key.Backspace, illwill.Key.CtrlH:
      if modelSelectionBuffer.len > 0:
        modelSelectionBuffer.setLen(modelSelectionBuffer.len - 1)
      return false
    of illwill.Key.Escape:
      modelSelectionBuffer = ""
      state = Chatting
      return false
    else: discard
    return false

  # --- Main key handling (Chatting state) ---
  case key
  of illwill.Key.Escape:
    showingSlashMenu = false
    return true

  of illwill.Key.Enter:
    let prompt = inputEditor.getText()
    if prompt.len > 0:
      # --- Slash commands ---
      let cmd = strutils.strip(prompt).toLowerAscii()
      if cmd == "/quit" or cmd == "/q": return true
      if cmd == "/model":
        asyncCheck server.fetchModels()
        state = SelectingModel
        inputEditor.setText("")
        return false
      if cmd == "/new":
        config.resetConversation()
        outputLines.add("System: Conversation reset. New chat started.")
        inputEditor.setText("")
        return false

      let cmdParts = strutils.splitWhitespace(cmd)
      if cmdParts.len > 0 and cmdParts[0].startsWith("/"):
        case cmdParts[0]
        of "/history", "/h":
          handleHistoryCommand(cmdParts)
          inputEditor.setText("")
          return false
        of "/edit":
          if cmdParts.len == 2:
            ui.openInMicro(cmdParts[1])
          else:
            outputLines.add("System: Usage: /edit <filename>")
          inputEditor.setText("")
          return false
        of "/read":
          if cmdParts.len >= 2:
            let filename = cmdParts[1]
            if fileExists(filename):
              try:
                let content = readFile(filename)
                outputLines.add("System: [File: " & filename & "]")
                var lineCount = 0
                for line in content.splitLines():
                  if lineCount >= 500: outputLines.add("... (truncated)"); break
                  outputLines.add(line)
                  inc(lineCount)
                outputLines.add("System: [End of file]")
                scrollOffset = 0
              except:
                outputLines.add("System: Error: " & getCurrentExceptionMsg())
            else:
              outputLines.add("System: File not found")
          else:
            outputLines.add("System: Usage: /read <filename>")
          inputEditor.setText("")
          return false
        else: discard

      # --- Normal message ---
      outputLines.add("Tu: " & prompt)
      inputEditor.setText("")
      asyncCheck chat.sendToLLM(prompt)
    return false

  of illwill.Key.Backspace, illwill.Key.CtrlH:
    inputEditor.handleBackspace()
    updateSlashMenu()
    return false

  of illwill.Key.Delete:
    inputEditor.handleDelete()
    updateSlashMenu()
    return false

  of illwill.Key.Up:
    if showingSlashMenu: return false
    # If the editor has multiple visual lines and we are not on the first one,
    # let the editor handle it. Otherwise, scroll chat.
    let contentWidth = w - PromptChar.len - 2
    let visualLines = inputEditor.buildVisualLineMap(contentWidth)
    let currentVL = inputEditor.findCurrentVisualLine(visualLines)
    if currentVL > 0:
      inputEditor.moveCursor(-1, 0, contentWidth)
    else:
      scrollOffset += 1
    return false

  of illwill.Key.Down:
    if showingSlashMenu: return false
    let contentWidth = w - PromptChar.len - 2
    let visualLines = inputEditor.buildVisualLineMap(contentWidth)
    let currentVL = inputEditor.findCurrentVisualLine(visualLines)
    if currentVL < visualLines.len - 1:
      inputEditor.moveCursor(1, 0, contentWidth)
    else:
      if scrollOffset > 0: scrollOffset -= 1
    return false

  of illwill.Key.Left:
    let contentWidth = w - PromptChar.len - 2
    inputEditor.moveCursor(0, -1, contentWidth)
    return false

  of illwill.Key.Right:
    let contentWidth = w - PromptChar.len - 2
    inputEditor.moveCursor(0, 1, contentWidth)
    return false

  of illwill.Key.Home, illwill.Key.CtrlA:
    inputEditor.moveToLineStart()
    return false

  of illwill.Key.End, illwill.Key.CtrlE:
    inputEditor.moveToLineEnd()
    return false

  of illwill.Key.Slash:
    inputEditor.insertChar("/")
    updateSlashMenu()
    return false

  else:
    # Use existing keyToChar logic
    let ch = keyToChar(key)
    if ch.len > 0:
      inputEditor.insertChar(ch)
    elif ord(key) >= 32 and ord(key) <= 126:
      inputEditor.insertChar($chr(ord(key)))
    
    updateSlashMenu()
    return false
