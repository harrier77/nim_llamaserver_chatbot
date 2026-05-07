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

proc flushInputBuffer*() =
  ## Flushes inputBuffer to currentInput when buffer delay has elapsed
  ## OR when buffer has enough characters (handles paste / bulk input).
  ## Handles newlines as message separators (Enter between lines).
  if inputBuffer.len > 0:
    let now = epochTime()
    let elapsedMs = (now - lastInputCharTime) * 1000.0
    # Flush if: delay elapsed OR buffer has many chars (paste detected)
    if elapsedMs >= InputBufferDelay.float or inputBuffer.len >= InputBufferThreshold:
      # Check for newlines - if present, split and process each line
      if "\n" in inputBuffer:
        let lines = inputBuffer.split("\n")
        for i, line in lines:
          if line.len > 0:
            if currentInput.len > 0:
              # First flush any pending currentInput
              currentInput &= line
            else:
              currentInput = line
        inputBuffer = ""
        updateSlashMenu()
      else:
        # No newlines - normal append
        currentInput &= inputBuffer
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
  ##
  ## EDIT: to add a new slash command:
  ## 1. Add the command in config.nim (SlashCommands)
  ## 2. Add the logic below in the "Slash commands" section
  ## 3. If it takes arguments, add a handleXXXCommand proc above

  # Ignore input while processing (except scrolling and SelectingModel state)
  if (isProcessing or (not serverAvailable and not OpenCodeEnabled)) and state == Chatting:
    # Allow scrolling even while the LLM is generating
    case key
    of illwill.Key.Up:
      scrollOffset += 1
      return false
    of illwill.Key.Down:
      if scrollOffset > 0: scrollOffset -= 1
      return false
    else:
      # Allow slash commands even when server is unavailable
      # This enables /model to select online models (e.g., OpenCode)
      if currentInput.len > 0 and currentInput[0] == '/' or key == illwill.Key.Slash:
        discard  # Continue to rest of input handling
      else:
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
    # Build categories list (same as in ui.nim)
    var categories: seq[tuple[name, icon: string, models: seq[string]]] = @[]
    if llamaCppModels.len > 0:
      categories.add((name: "llamacpp", icon: "🖥", models: llamaCppModels))
    if openCodeModels.len > 0:
      categories.add((name: "opencode", icon: "☁", models: openCodeModels))
    if ollamaModels.len > 0:
      categories.add((name: "ollama", icon: "🐳", models: ollamaModels))
    if nvidiaModels.len > 0:
      categories.add((name: "nvidia", icon: "🔷", models: nvidiaModels))
    if zayaModels.len > 0:
      categories.add((name: "zaya", icon: "🔮", models: zayaModels))
    if categories.len == 0:
      categories.add((name: "all", icon: "📋", models: availableModels))

    # Clamp selectedCategoryIndex
    if selectedCategoryIndex >= categories.len:
      selectedCategoryIndex = max(0, categories.len - 1)

    case key
    of illwill.Key.Escape:
      state = Chatting
      return false
    of illwill.Key.Left:
      # Move to previous category
      if selectedCategoryIndex > 0:
        dec(selectedCategoryIndex)
        # Reset model index to first in new category
        selectedMenuIndex = 0
      return false
    of illwill.Key.Right:
      # Move to next category (also acts as Enter to expand)
      if selectedCategoryIndex < categories.len - 1:
        inc(selectedCategoryIndex)
        selectedMenuIndex = 0
      return false
    of illwill.Key.Up:
      # Find current category range
      var catStart = 0
      for i in 0 ..< selectedCategoryIndex:
        catStart += categories[i].models.len
      # Move up within current category
      if selectedMenuIndex > catStart:
        dec(selectedMenuIndex)
      else:
        # Wrap to previous category's last model
        if selectedCategoryIndex > 0:
          dec(selectedCategoryIndex)
          var prevCatStart = 0
          for i in 0 ..< selectedCategoryIndex:
            prevCatStart += categories[i].models.len
          selectedMenuIndex = prevCatStart + categories[selectedCategoryIndex].models.len - 1
      return false
    of illwill.Key.Down:
      # Find current category range
      var catStartDown = 0
      for i in 0 ..< selectedCategoryIndex:
        catStartDown += categories[i].models.len
      let catEnd = catStartDown + categories[selectedCategoryIndex].models.len - 1

      # Move down within current category
      if selectedMenuIndex < catEnd:
        inc(selectedMenuIndex)
      else:
        # Wrap to next category's first model
        if selectedCategoryIndex < categories.len - 1:
          inc(selectedCategoryIndex)
          selectedMenuIndex = catEnd + 1
      return false
    of illwill.Key.Enter:
      if availableModels.len > 0 and selectedMenuIndex < availableModels.len:
        ModelName = availableModels[selectedMenuIndex]
        server.saveModelStatus()
        outputLines.add("System: Model changed to " & ModelName)
        # If it's an OpenCode model, set serverAvailable true to skip localhost checks
        var isOpenCode = false
        for m in OpenCodeModelIds:
          if m == ModelName:
            isOpenCode = true
            break
        if isOpenCode:
          serverAvailable = true
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
        of "/history", "/h":
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
        of "/read":
          if cmdParts.len >= 2:
            let filename = cmdParts[1]
            if fileExists(filename):
              try:
                let content = readFile(filename)
                let header = "System: [File: " & filename & "]"
                outputLines.add(header)
                # Add file content line by line (limit to avoid huge files)
                var lineCount = 0
                const maxReadLines = 500
                for line in content.splitLines():
                  if lineCount >= maxReadLines:
                    outputLines.add("... (file truncated at " & $maxReadLines & " lines)")
                    break
                  outputLines.add(line)
                  inc(lineCount)
                outputLines.add("System: [End of file: " & $lineCount & " lines read]")
                # Reset scroll to bottom so user sees the end
                scrollOffset = 0
              except:
                outputLines.add("System: Error reading file: " & getCurrentExceptionMsg())
            else:
              outputLines.add("System: File not found: " & filename)
          else:
            outputLines.add("System: Usage: /read <filename>")
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
    # Printable characters → add to input buffer (not directly to currentInput)
    let ch = keyToChar(key)
    if ch.len > 0:
      inputBuffer.add(ch)
      lastInputCharTime = epochTime()
    # Fallback for slash on Windows
    elif ord(key) == 47 or ord(key) == 191 or ord(key) == 111:
      inputBuffer.add("/")
      lastInputCharTime = epochTime()
    # Fallback for other printable ASCII characters
    elif ord(key) >= 32 and ord(key) <= 126:
      inputBuffer.add(chr(ord(key)))
      lastInputCharTime = epochTime()
    # Fallback for backspace
    elif ord(key) == 127 or ord(key) == 8:
      if currentInput.len > 0:
        currentInput.removeLastRune()
    # Update the slash menu after any character input
    updateSlashMenu()
    return false
