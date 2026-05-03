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

import strutils, illwill, asyncdispatch
import config
import server   # for fetchModels
import chat     # for sendToLLM
import ui       # for openInMicro
import my_include/map_key_tochar

# ============================================================
# Slash command menu
# ============================================================

proc updateSlashMenu*() =
  ## Opens or closes the slash menu based on current input.
  ## Disables the menu if input contains spaces (has arguments).
  ## EDIT: to change when the menu appears, modify here.
  if currentInput.len > 0 and currentInput[0] == '/' and not currentInput.contains(' '):
    showingSlashMenu = true
    # Clamp index when the filtered list shrinks
    let filtered = filterSlashCommands(currentInput[1 .. ^1])
    if slashMenuIndex >= filtered.len and filtered.len > 0:
      slashMenuIndex = filtered.len - 1
    if filtered.len == 0:
      showingSlashMenu = false
  else:
    showingSlashMenu = false

# ============================================================
# Slash commands with arguments
# ============================================================
# Simple commands (/quit, /model, /new) are handled in handleInput.
# Commands with arguments (/history, /edit) are handled here to
# keep handleInput more readable.

proc handleHistoryCommand*(cmdParts: seq[string]) =
  ## Handles the /history <num> command.
  ## Modifies maxHistoryMessages (sliding window).
  if cmdParts.len == 2:
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
  ##
  ## EDIT: to add a new slash command:
  ## 1. Add the command in config.nim (SlashCommands)
  ## 2. Add the logic below in the "Slash commands" section
  ## 3. If it takes arguments, add a handleXXXCommand proc above

  # Ignore input while processing (except in SelectingModel state)
  if (isProcessing or not serverAvailable) and state == Chatting:
    return false

  # --- Slash menu navigation ---
  if showingSlashMenu and state == Chatting:
    case key
    of illwill.Key.Escape:
      showingSlashMenu = false
      return false
    of illwill.Key.Tab:
      let filtered = filterSlashCommands(currentInput[1 .. ^1])
      if filtered.len > 0:
        currentInput = SlashCommands[filtered[slashMenuIndex]].name
      return false
    of illwill.Key.Up:
      let filtered = filterSlashCommands(currentInput[1 .. ^1])
      if filtered.len > 0 and slashMenuIndex > 0:
        dec(slashMenuIndex)
      return false
    of illwill.Key.Down:
      let filtered = filterSlashCommands(currentInput[1 .. ^1])
      if filtered.len > 0 and slashMenuIndex < filtered.len - 1:
        inc(slashMenuIndex)
      return false
    of illwill.Key.Backspace, illwill.Key.Delete:
      if currentInput.len > 0:
        currentInput.removeLastRune()
      updateSlashMenu()
      return false
    of illwill.Key.Enter:
      # Execute the highlighted command from the menu
      let filtered = filterSlashCommands(currentInput[1 .. ^1])
      if filtered.len > 0:
        currentInput = SlashCommands[filtered[slashMenuIndex]].name
        showingSlashMenu = false
        # Fall-through to the Enter handler below for execution
      else:
        showingSlashMenu = false
        return false
    else:
      # Any other key: close the menu and continue with normal handling
      showingSlashMenu = false

  # --- Model selection ---
  if state == SelectingModel:
    case key
    of illwill.Key.Escape:
      state = Chatting
      return false
    of illwill.Key.Up:
      if selectedMenuIndex > 0:
        dec(selectedMenuIndex)
      return false
    of illwill.Key.Down:
      if selectedMenuIndex < availableModels.len - 1:
        inc(selectedMenuIndex)
      return false
    of illwill.Key.Enter:
      if availableModels.len > 0:
        ModelName = availableModels[selectedMenuIndex]
        server.saveModelStatus()
        outputLines.add("System: Model changed to " & ModelName)
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
    if currentInput.len > 0:
      let prompt = currentInput
      currentInput = ""

      # --- Simple slash commands ---
      let cmd = strutils.strip(prompt).toLowerAscii()
      if cmd == "/quit" or cmd == "/q":
        return true

      if cmd == "/model":
        asyncCheck server.fetchModels()
        state = SelectingModel
        return false

      if cmd == "/new":
        config.resetConversation()
        outputLines.add("System: Conversation reset. New chat started.")
        return false

      # --- Slash commands with arguments ---
      let cmdParts = strutils.splitWhitespace(cmd)
      if cmdParts.len > 0:
        case cmdParts[0]
        of "/history":
          handleHistoryCommand(cmdParts)
          return false
        of "/edit":
          if cmdParts.len == 2:
            let filename = cmdParts[1]
            outputLines.add("System: Opening " & filename & " in micro editor...")
            ui.openInMicro(filename)
          else:
            outputLines.add("System: Usage: /edit <filename>")
          return false
        else:
          discard

      # --- Normal message: send to LLM ---
      outputLines.add("Tu: " & prompt)
      asyncCheck chat.sendToLLM(prompt)
    return false

  of illwill.Key.Backspace, illwill.Key.Delete:
    if currentInput.len > 0:
      currentInput.removeLastRune()
    return false

  of illwill.Key.Up:
    if showingSlashMenu:
      return false  # Already handled above
    scrollOffset += 1
    return false

  of illwill.Key.Down:
    if showingSlashMenu:
      return false  # Already handled above
    if scrollOffset > 0: scrollOffset -= 1
    return false

  of illwill.Key.Left, illwill.Key.Right:
    # Arrow keys not used for navigation - ignore
    return false

  of illwill.Key.Slash:
    currentInput.add("/")
    updateSlashMenu()
    return false

  else:
    # Printable characters
    let ch = keyToChar(key)
    if ch.len > 0:
      currentInput.add(ch)
    # Fallback for slash on Windows
    elif ord(key) == 47 or ord(key) == 191 or ord(key) == 111:
      currentInput.add("/")
    # Fallback for other printable ASCII characters
    elif ord(key) >= 32 and ord(key) <= 126:
      currentInput.add(chr(ord(key)))
    # Fallback for backspace
    elif ord(key) == 127 or ord(key) == 8:
      if currentInput.len > 0:
        currentInput.removeLastRune()
    # Update the slash menu after any character input
    updateSlashMenu()
    return false
