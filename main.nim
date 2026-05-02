# Full-screen TUI chat client for llama.cpp server
# Connects to llama-server on port 8080 and displays streaming responses

import os, strformat, strutils, json, httpclient, asyncdispatch, uri, times
import illwill, unicode
import my_include/tools, my_include/map_key_tochar, my_include/system_prompt

const
  InputBarHeight = 5          # Height of the input bar area (2 blue delimiter lines + 3 content rows)
  StatusBarHeight = 1         # Height of the status bar
  InputGap = 2                 # Blank lines between last output and input bar
  MaxOutputLines = 1000        # Max lines to keep in output history
  PromptChar = "> "             # Prompt prefix for user input

var
  ServerBaseUrl = "http://localhost:8080"  # Base URL for llama-server (loaded from status.json)
  APIUrl = ServerBaseUrl & "/v1/chat/completions"  # Full API endpoint
  # Configurazione per avvio automatico del server
  LlamaServerPath = "C:\\down\\llama-latest\\llama-server.exe"  # Percorso al server
  LlamaServerArgs* = @["--host", "0.0.0.0", "--models-preset", "config.ini", "--models-max", "1", "--no-warmup", "--parallel", "1", "--jinja"]
  SlashMenuHeight = 8          # Max rows to display in the slash command popup

type
  AppState = enum
    Chatting,
    SelectingModel

  SlashCommand = object
    name: string
    description: string

var
  ModelName = "Qwen3.5_0.8b-text"  # Current model name (can be changed)
  maxHistoryMessages: int = 20    # Max messages to keep in conversation history (sliding window)
  state: AppState = Chatting      # Current application state
  availableModels: seq[string] = @[] # List of models from server
  selectedMenuIndex: int = 0      # Index for model selection menu

const SlashCommands: array[3, SlashCommand] = [
  SlashCommand(name: "/quit",   description: "Exit the application (also /q)"),
  SlashCommand(name: "/model",  description: "Change the current model"),
  SlashCommand(name: "/new",    description: "Reset conversation and start new chat"),
]

const StatusFile = "my_include/status.json"

# ============================================
# Server Management - Avvio automatico
# ============================================

proc checkServer*(): bool =
  ## Verifica se il server llama.cpp è attivo e pronto
  ## Restituisce true se il server è raggiungibile
  try:
    let client = newHttpClient()
    client.timeout = 5000  # 5 secondi timeout
    let response = client.get(ServerBaseUrl & "/v1/models")
    client.close()
    return response.status == "200"
  except:
    return false

proc loadModelStatus() =
  ## Load the previously selected model and settings from status.json
  if not fileExists(StatusFile): return
  try:
    let content = readFile(StatusFile)
    let j = parseJson(content)
    if j.hasKey("selected_model"):
      ModelName = j["selected_model"].getStr()
      echo "Modello caricato da status.json: ", ModelName
    if j.hasKey("max_history_messages"):
      maxHistoryMessages = j["max_history_messages"].getInt()
      echo "Max history messages caricato: ", maxHistoryMessages
    if j.hasKey("server_url"):
      ServerBaseUrl = j["server_url"].getStr()
      APIUrl = ServerBaseUrl & "/v1/chat/completions"
      echo "Server URL caricato da status.json: ", ServerBaseUrl
  except: discard

proc saveModelStatus() =
  ## Save the currently selected model and settings to status.json
  try:
    let j = %*{
      "selected_model": ModelName,
      "max_history_messages": maxHistoryMessages,
      "server_url": ServerBaseUrl
    }
    writeFile(StatusFile, $j)
  except: discard

proc exitProc() {.noconv.} =
  # FIX: To ensure the terminal doesn't stay orange/yellow after exit:
  # 1. Try to clear the current illwill buffer
  try:
    var tb = newTerminalBuffer(terminalWidth(), terminalHeight())
    tb.resetAttributes()
    tb.display()
  except: discard

  # 2. Deinitialize illwill (restores screen on some platforms)
  illwillDeinit()

  # 3. Explicitly send ANSI reset code to stdout.
  # \e[0m resets all attributes (colors, bold, etc.)
  # This is a fail-safe for modern terminals (Windows Terminal, CMD with ANSI enabled).
  stdout.write("\e[0m")
  stdout.flushFile()

  showCursor()
  quit(0)

proc fetchModels() {.async.} =
  ## Fetch available models from the server
  var client = newAsyncHttpClient()
  try:
    let response = await client.get(ServerBaseUrl & "/v1/models")
    let jsonNode = parseJson(await response.body())
    availableModels = @[]
    if jsonNode.hasKey("data"):
      for model in jsonNode["data"]:
        availableModels.add(model["id"].getStr())

    if availableModels.len == 0:
      availableModels.add(ModelName)

    # Find current model in the list to set default selection
    selectedMenuIndex = 0
    for i, m in availableModels:
      if m == ModelName:
        selectedMenuIndex = i
        break
  except:
    availableModels = @[ModelName]
    selectedMenuIndex = 0
  finally:
    client.close()

# Global state
var
  outputLines: seq[string] = @[]   # History of chat messages
  currentInput: string = ""        # Current input buffer
  scrollOffset: int = 0            # How many lines we've scrolled up
  isProcessing: bool = false       # True when waiting for AI response
  aiResponseBuffer: string = ""     # Buffer for streaming AI response
  serverAvailable: bool = false     # True when llama-server is reachable
  lastServerCheck: float = 0.0      # Timestamp of last server check
  showingSlashMenu: bool = false    # True when the slash popup is visible
  slashMenuIndex: int = 0           # Highlighted item index in the menu
  # FIX: Add system message to instruct LLM about tool usage
  conversationHistory: seq[JsonNode] = @[
    %*{
      "role": "system",
      "content": SYSTEM_PROMPT
    }
  ]  # Chat history for API

proc checkServerAsync() {.async.} =
  ## Async check if server is available (non-blocking)
  var client = newAsyncHttpClient()
  try:
    let response = await client.get(ServerBaseUrl & "/v1/models")
    serverAvailable = (response.code == Http200)
  except:
    serverAvailable = false
  finally:
    client.close()

proc filterCommands(query: string): seq[int] =
  ## Return indices of SlashCommands that match the query (text after "/").
  ## Returns all commands if query is empty.
  result = @[]
  let q = strutils.strip(query).toLowerAscii()
  for i, cmd in SlashCommands:
    if cmd.name[1 .. ^1].startsWith(q) or cmd.name.toLowerAscii().contains(q):
      result.add(i)

proc updateSlashMenu() =
  ## Open or close the slash menu based on current input.
  ## Disable menu if input contains spaces (has arguments)
  if currentInput.len > 0 and currentInput[0] == '/' and not currentInput.contains(' '):
    showingSlashMenu = true
    # Clamp index when filtered list shrinks
    let filtered = filterCommands(currentInput[1 .. ^1])
    if slashMenuIndex >= filtered.len and filtered.len > 0:
      slashMenuIndex = filtered.len - 1
    if filtered.len == 0:
      showingSlashMenu = false
  else:
    showingSlashMenu = false

proc runeLen(s: string): int =
  ## Returns the number of Unicode codepoints in s
  result = 0
  for _ in s.runes:
    inc(result)

proc removeLastRune(s: var string) =
  ## Remove last Unicode character from string (handles UTF-8 correctly)
  if s.len == 0: return
  var i = s.len - 1
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec(i)
  s.setLen(i)

proc trimConversationHistory() =
  ## Apply sliding window to conversationHistory
  ## Keeps system message + last N messages
  if conversationHistory.len <= maxHistoryMessages + 1:  # +1 for system prompt
    return
  
  # Always keep system message if present
  var newHistory: seq[JsonNode] = @[]
  if conversationHistory.len > 0 and conversationHistory[0].hasKey("role") and 
     conversationHistory[0]["role"].getStr() == "system":
    newHistory.add(conversationHistory[0])
  
  # Keep last maxHistoryMessages
  let startIndex = max(if newHistory.len > 0: 1 else: 0, 
                       conversationHistory.len - maxHistoryMessages)
  for i in startIndex..<conversationHistory.len:
    newHistory.add(conversationHistory[i])
  
  conversationHistory = newHistory
  echo "History trimmed to ", conversationHistory.len, " messages"

proc sendToLLM(prompt: string = "") {.async.} =
  ## Send prompt to llama.cpp server and handle streaming response and tool calls
  isProcessing = true

  if prompt.len > 0:
    aiResponseBuffer = ""
    # Add user message to history
    conversationHistory.add(%*{
      "role": "user",
      "content": prompt
    })
    # Apply sliding window after adding user message
    trimConversationHistory()

  var toolCallsCollected: seq[JsonNode] = @[]

  while true:
    let body = %*{
      "model": ModelName,
      "messages": conversationHistory,
      "stream": true,
      "tools": tools.ToolsSchema
    }
    try:
      let f = open("debug_tools.txt", fmAppend)
      f.write("\n--- MSG TO MODEL ---\n" & pretty(body) & "\n--- END ---\n")
      f.close()
    except: discard
    var client = newAsyncHttpClient()
    client.headers = newHttpHeaders({"Content-Type": "application/json"})

    # Track partial line for SSE parsing
    var pendingLine = ""
    aiResponseBuffer = "" # Clear for current round
    toolCallsCollected = @[]

    try:
      # Send POST request with streaming
      let response = await client.post(APIUrl, body = $body)

      # Read response in streaming mode
      while true:
        let (hasMore, chunk) = await response.bodyStream.read()
        if not hasMore or chunk.len == 0: break

        let data = pendingLine & chunk
        pendingLine = ""
        var lines = data.splitLines()

        if hasMore and not data.endsWith("\n"):
          pendingLine = lines[^1]
          lines = lines[0..^2]

        for line in lines:
          if line.startsWith("data: "):
            let jsonStr = strutils.strip(line[6..^1])
            if jsonStr == "[DONE]": break

            try:
              let jsonChunk = parseJson(jsonStr)
              if jsonChunk.hasKey("choices") and jsonChunk["choices"].len > 0:
                let delta = jsonChunk["choices"][0].getOrDefault("delta")

                # 1. Handle content tokens (standard chat)
                if delta.hasKey("content"):
                  let content = delta["content"].getStr("")
                  if content.len > 0:
                    let isFirstChunkOfResponse = aiResponseBuffer.len == 0 and toolCallsCollected.len == 0
                    aiResponseBuffer &= content

                    let parts = content.splitLines()
                    for i, part in parts:
                      if i == 0:
                        if isFirstChunkOfResponse:
                          outputLines.add("AI: " & part)
                        else:
                          outputLines[^1] &= part
                      else:
                        if part.len == 0:
                          if outputLines.len > 0 and outputLines[^1].len > 0:
                            outputLines.add("")
                        else:
                          outputLines.add(part)

                # 2. Handle tool call chunks
                if delta.hasKey("tool_calls"):
                  for tc in delta["tool_calls"]:
                    let idx = tc["index"].getInt()
                    while toolCallsCollected.len <= idx:
                      toolCallsCollected.add(%*{"id": newJNull(), "type": "function", "function": {"name": "", "arguments": ""}})

                    let target = toolCallsCollected[idx]
                    if tc.hasKey("id"): target["id"] = tc["id"]
                    if tc["function"].hasKey("name"): target["function"]["name"] = tc["function"]["name"]
                    if tc["function"].hasKey("arguments"):
                      target["function"]["arguments"] = %(target["function"]["arguments"].getStr() & tc["function"]["arguments"].getStr())

            except JsonParsingError: discard
            except CatchableError: discard

    except CatchableError as e:
      outputLines.add("❌ Error: " & e.msg)
      client.close()
      break
    finally:
      client.close()

    # After streaming round ends, check if we have tool calls to execute
    if toolCallsCollected.len > 0:
      # FIX: Assistant message must have placeholder TEXT content, not null!
      # Before: "content": null - This caused the model to keep making tool calls (infinite loop)
      # After: "content": "Then I will answer and show any content..." - Matches Python version format
      # The model needs this placeholder text to understand it should respond with final answer, not make more tool calls
      let assistantMsg = %*{"role": "assistant", "content": (if aiResponseBuffer.len > 0: %aiResponseBuffer else: %"Then I will answer and show any content..."), "tool_calls": toolCallsCollected}
      conversationHistory.add(assistantMsg)

      # Execute tools and add results to history
      for tc in toolCallsCollected:
        let toolName = tc["function"]["name"].getStr()
        let toolArgs = tc["function"]["arguments"].getStr()
        let toolId = tc["id"].getStr()

        outputLines.add("System: Tool Call -> " & toolName & "(" & toolArgs & ")")
        let result = tools.executeTool(toolName, parseJson(toolArgs))
        #outputLines.add("DEBUG result -> " & toolName & "(" & result & ")")

        # FIX: Parse JSON result and extract content (like Python frontend does)
        # The tool returns JSON: {"content": "...", "exit_code": X}
        # We need to extract the "content" field for the LLM
        # Also include exit_code if non-zero (like Python does)
        var content = result
        try:
          let parsed = parseJson(result)
          if parsed.hasKey("content"):
            content = parsed["content"].getStr()
            # Include exit_code if non-zero (like Python _format_tool_result does)
            if parsed.hasKey("exit_code"):
              let exitCode = parsed["exit_code"].getInt()
              if exitCode != 0:
                content = "[Exit code: " & $exitCode & "]\n" & content
          elif parsed.hasKey("error"):
            content = "Error: " & parsed["error"].getStr()
        except:
          content = "[JSON PARSE ERROR: " & result & "]"

        # DEBUG: Log extracted content
        try:
          let f = open("debug_tools.txt", fmAppend)
          f.write("\n=== EXTRACTED CONTENT ===\n" & content & "\n=== END ===\n")
          f.close()
        except: discard

        conversationHistory.add(%*{
          "role": "tool",
          "tool_call_id": toolId,
          "name": toolName,
          "content": content
        })

      # Round finished, loop back to send tool results to LLM
      continue
    else:
      # No tool calls, standard message finished
      if aiResponseBuffer.len > 0:
        conversationHistory.add(%*{
          "role": "assistant",
          "content": aiResponseBuffer
        })
      break

  isProcessing = false
  if outputLines.len > MaxOutputLines:
    outputLines = outputLines[outputLines.len - MaxOutputLines .. ^1]
  scrollOffset = 0
  # Apply sliding window after assistant response is added
  trimConversationHistory()

proc handleInput(key: Key): bool =
  ## Process a keypress. Returns true if we should quit.
  if (isProcessing or not serverAvailable) and state == Chatting:
    # Ignore input while processing chat
    return false

  # --- Slash command menu navigation ---
  if showingSlashMenu and state == Chatting:
    case key
    of Key.Escape:
      showingSlashMenu = false
      return false
    of Key.Tab:
      let filtered = filterCommands(currentInput[1 .. ^1])
      if filtered.len > 0:
        currentInput = SlashCommands[filtered[slashMenuIndex]].name
      return false
    of Key.Up:
      let filtered = filterCommands(currentInput[1 .. ^1])
      if filtered.len > 0 and slashMenuIndex > 0:
        dec(slashMenuIndex)
      return false
    of Key.Down:
      let filtered = filterCommands(currentInput[1 .. ^1])
      if filtered.len > 0 and slashMenuIndex < filtered.len - 1:
        inc(slashMenuIndex)
      return false
    of Key.Backspace, Key.Delete:
      if currentInput.len > 0:
        currentInput.removeLastRune()
      updateSlashMenu()
      return false
    of Key.Enter:
      # Execute highlighted command directly from menu
      let filtered = filterCommands(currentInput[1 .. ^1])
      if filtered.len > 0:
        currentInput = SlashCommands[filtered[slashMenuIndex]].name
        showingSlashMenu = false
        # Fall through to normal Enter handler below to execute
      else:
        showingSlashMenu = false
        return false
    else:
      # Any other key: close menu and let normal handling continue
      showingSlashMenu = false

  if state == SelectingModel:
    case key
    of Key.Escape:
      state = Chatting
      return false
    of Key.Up:
      if selectedMenuIndex > 0:
        dec(selectedMenuIndex)
      return false
    of Key.Down:
      if selectedMenuIndex < availableModels.len - 1:
        inc(selectedMenuIndex)
      return false
    of Key.Enter:
      if availableModels.len > 0:
        ModelName = availableModels[selectedMenuIndex]
        saveModelStatus()
        outputLines.add("System: Modello cambiato a " & ModelName)
      state = Chatting
      return false
    else: discard
    return false

  case key
  of Key.Escape:
    showingSlashMenu = false
    return true
  of Key.Enter:
    if currentInput.len > 0:
      let prompt = currentInput
      currentInput = ""

      # FIX: Add slash commands for exiting
      let cmd = strutils.strip(prompt).toLowerAscii()
      if cmd == "/quit" or cmd == "/q":
        return true

      if cmd == "/model":
        asyncCheck fetchModels()
        state = SelectingModel
        return false

      if cmd == "/new":
        conversationHistory = @[
          %*{
            "role": "system",
            "content": SYSTEM_PROMPT
          }
        ]
        outputLines = @[]
        aiResponseBuffer = ""
        scrollOffset = 0
        outputLines.add("System: Conversation reset. New chat started.")
        return false

      # Parse command with arguments properly
      let cmdParts = strutils.splitWhitespace(cmd)
      if cmdParts.len > 0:
        case cmdParts[0]
        of "/history":
          if cmdParts.len == 2:
            try:
              let newVal = cmdParts[1].parseInt()
              if newVal >= 1 and newVal <= 100:
                maxHistoryMessages = newVal
                saveModelStatus()
                outputLines.add("System: Max history messages set to " & $maxHistoryMessages)
              else:
                outputLines.add("System: Value must be between 1 and 100")
            except:
              outputLines.add("System: Invalid number. Usage: /history <number>")
          else:
            outputLines.add("System: Current max history: " & $maxHistoryMessages & ". Usage: /history <number>")
          return false
        else:
          discard

      # Add user message to output IMMEDIATELY (before streaming starts)
      outputLines.add("Tu: " & prompt)
      # Start async request (fire and forget)
      asyncCheck sendToLLM(prompt)
    return false
  of Key.Backspace, Key.Delete:
    if currentInput.len > 0:
      currentInput.removeLastRune()
    return false
  of Key.Up:
    if showingSlashMenu:
      # Already handled above, but just in case
      return false
    scrollOffset += 1
    return false
  of Key.Down:
    if showingSlashMenu:
      # Already handled above, but just in case
      return false
    if scrollOffset > 0: scrollOffset -= 1
    return false
  of Key.Left, Key.Right:
    # Arrow keys not used for navigation in input - ignore gracefully
    return false
  of Key.Slash:
    currentInput.add("/")
    updateSlashMenu()
    return false
  else:
    let ch = keyToChar(key)
    # DEBUG: log every key that reaches the else branch
    #try:
    #  let f = open("debug_keys.txt", fmAppend)
    #  f.write("KEY pressed: ord=" & $ord(key) & " key=" & $key & " keyToChar='" & ch & "'\n")
    #  f.close()
    #except: discard
    if ch.len > 0:
      currentInput.add(ch)
    # Fallback for slash on Windows - codes 47, 191 (OEM), 111 (Divide)
    elif ord(key) == 47 or ord(key) == 191 or ord(key) == 111:
      currentInput.add("/")
    # Fallback for other printable ASCII
    elif ord(key) >= 32 and ord(key) <= 126:
      currentInput.add(chr(ord(key)))
    # Fallback for backspace on Windows - 127 = Backspace (ASCII), 8 = Backspace (control char)
    elif ord(key) == 127 or ord(key) == 8:
      if currentInput.len > 0:
        currentInput.removeLastRune()
    # After any character input, check if we should show the slash menu
    updateSlashMenu()
    return false

proc wrapText(text: string, width: int): seq[string] =
  ## FIX: Rune-aware word wrapping.
  ## 1. Uses toRunes to avoid splitting multi-byte UTF-8 characters.
  ## 2. Searches for the last space to avoid breaking words in the middle.
  if text.len == 0: return @[""]
  let w = max(1, width)
  var lines: seq[string] = @[]
  let runes = toRunes(text)
  var i = 0
  while i < runes.len:
    if runes.len - i <= w:
      lines.add($runes[i .. ^1])
      break

    # Look for last space within width to perform word wrap
    var lastSpace = -1
    for j in 0 ..< w:
      if runes[i + j] == Rune(32):
        lastSpace = j

    if lastSpace != -1:
      # Found a space, wrap there
      lines.add($runes[i ..< i + lastSpace])
      i += lastSpace + 1 # Skip the space character
    else:
      # No space found, fallback to hard wrap at boundary
      lines.add($runes[i ..< i + w])
      i += w
  return lines

proc drawStatusBar(tb: var TerminalBuffer, y, w: int) =
  ## Draw a status bar at the bottom of the screen
  tb.setBackgroundColor(bgBlue)
  tb.setForegroundColor(fgWhite, bright=true)
  
  let serverStatus = if serverAvailable: "🟢" else: "🔴"
  let processStatus = if isProcessing: "⏳ Processing..." else: "✓ Ready"
  let modelShort = if ModelName.len > 15: ModelName[0..14] & "..." else: ModelName
  
  let statusText = fmt" {serverStatus} {processStatus} | Model: {modelShort} | Messages: {outputLines.len} "
  
  tb.write(0, y, strutils.repeat(" ", w))
  tb.write(0, y, statusText)
  tb.setBackgroundColor(bgNone)

proc main() =
  illwillInit(fullscreen=true)
  setControlCHook(exitProc)
  hideCursor()

  # Load previously selected model from status.json
  loadModelStatus()

  # Automatically fetch models on startup
  asyncCheck fetchModels()

  # Welcome message
  outputLines.add("Chat TUI - Connesso a llama.cpp su " & ServerBaseUrl)
  outputLines.add("   Premi Enter per inviare, Esc o /q per uscire")
  outputLines.add("   /model: cambia modello | /new: reset chat")
  outputLines.add("   /history <num>: memoria messaggi (attuale: " & $maxHistoryMessages & ")")


  while true:
    # Check server availability periodically (async, non-blocking)
    let now = epochTime()
    if not serverAvailable and (now - lastServerCheck > 3.0):
      asyncCheck checkServerAsync()
      lastServerCheck = now

    var tb = newTerminalBuffer(terminalWidth(), terminalHeight())
    let w = tb.width
    let h = tb.height

    if h <= InputBarHeight + StatusBarHeight + 2 or w < 20:
      tb.setForegroundColor(fgRed, bright=true)
      tb.write(0, 0, "Terminal too small! Resize to continue.")
      tb.display()
      sleep(50)
      var key = getKey()
      if key == Key.Escape or key == Key.Q: exitProc()
      continue

    # === Fill entire screen with black background ===
    tb.setBackgroundColor(bgBlack)
    tb.setForegroundColor(fgWhite)
    tb.fill(0, 0, w - 1, h - 1, " ")

    if state == SelectingModel:
      # === Draw Model Selection Menu ===
      tb.setForegroundColor(fgCyan, bright=true)
      let menuTitle = " SELEZIONA MODELLO "
      tb.write((w - menuTitle.len) div 2, 2, menuTitle)

      let startY = 5
      if availableModels.len == 0:
        tb.setForegroundColor(fgYellow)
        tb.write((w - 20) div 2, startY, "Caricamento modelli...")
      else:
        for i, m in availableModels:
          if startY + i >= h - 2: break
          if i == selectedMenuIndex:
            tb.setBackgroundColor(bgBlue)
            tb.setForegroundColor(fgWhite, bright=true)
            let line = "  ▶ " & m & "  "
            tb.write((w - line.len) div 2, startY + i, line)
            tb.setBackgroundColor(bgBlack)
          else:
            tb.setForegroundColor(fgWhite)
            # Mark currently active model with a check
            let prefix = if m == ModelName: "✓ " else: "  "
            tb.write((w - (prefix & m).len) div 2, startY + i, prefix & m)

      tb.setForegroundColor(fgWhite)
      let help = "↑/↓: Naviga, Enter: Conferma, Esc: Annulla"
      tb.write((w - help.len) div 2, h - StatusBarHeight - 1, help)
    else:
      # === Draw output area ===
      # MEMO: Borders (│, ─, ┌, etc.) have been removed to maximize horizontal space.
      # Title bar
      tb.setBackgroundColor(bgBlue)
      tb.setForegroundColor(fgWhite, bright=true)
      let title = fmt" CHAT 🤖 {ModelName} "
      tb.write(max(1, (w - title.len) div 2), 0, title)
      tb.setBackgroundColor(bgBlack)

      # Help text
      tb.setForegroundColor(fgWhite)
      tb.write(max(1, (w - title.len) div 2 + title.len + 2), 0, "Esc/Q=quit")

      # Reset background to black
      tb.setBackgroundColor(bgBlack)

      # Server unavailable banner
      let bannerOffset = if not serverAvailable: 1 else: 0
      if not serverAvailable:
        let banner = " ⚠ SERVER NON DISPONIBILE - Avvia llama-server.exe ⚠ "
        tb.setBackgroundColor(bgRed)
        tb.setForegroundColor(fgWhite, bright=true)
        tb.write(max(1, (w - banner.len) div 2), 1, banner)
        tb.setBackgroundColor(bgBlack)

      # Collect display lines with word wrapping
      # FIX: Using rune-aware wrapping to handle UTF-8 and spaces correctly.
      var allDisplayLines: seq[string] = @[]
      for line in outputLines:
        for wrapped in wrapText(line, w):
          allDisplayLines.add(wrapped)

      # Show processing indicator if waiting
      if isProcessing and aiResponseBuffer.len == 0:
        allDisplayLines.add("... Waiting for response...")

      # Position input bar: float below content, or pin to bottom if overflowing
      # Status bar is at the very bottom (h - StatusBarHeight)
      let contentStartY = 1 + bannerOffset
      let inputBarNeeded = InputGap + InputBarHeight
      # Calculate space needed for slash menu if visible
      let slashMenuSpace = block:
        if showingSlashMenu and state == Chatting:
          let filtered = filterCommands(currentInput[1 .. ^1])
          min(filtered.len, SlashMenuHeight) + 2  # +2 for border lines
        else:
          0
      var inputY: int
      var showFrom, showTo: int

      # Total space needed at bottom: input bar + slash menu + status bar
      let bottomSpaceNeeded = inputBarNeeded + slashMenuSpace + StatusBarHeight

      if contentStartY + allDisplayLines.len + bottomSpaceNeeded <= h:
        # Content fits → input bar floats just below content
        inputY = contentStartY + allDisplayLines.len + InputGap
        showFrom = 0
        showTo = allDisplayLines.len
      else:
        # Content too long → pin input bar above status bar, scroll output
        inputY = h - StatusBarHeight - InputBarHeight - slashMenuSpace
        if inputY < contentStartY + 2:
          inputY = h - StatusBarHeight - InputBarHeight  # Fallback if terminal too short
        let visibleRows = max(1, inputY - contentStartY)
        scrollOffset = max(0, min(scrollOffset, max(0, allDisplayLines.len - visibleRows)))
        showFrom = if allDisplayLines.len > visibleRows:
          max(0, allDisplayLines.len - visibleRows - scrollOffset)
        else:
          0
        showTo = min(showFrom + visibleRows, allDisplayLines.len)

      # Draw visible output lines
      var y = 1 + bannerOffset
      var inAIResponse = false
      for i in showFrom ..< showTo:
        if y >= inputY: break
        # Draw content with colors based on prefix
        let line = allDisplayLines[i]
        if line.startsWith("Tu:"):
          inAIResponse = false
          tb.setForegroundColor(fgWhite)
        elif line.startsWith("AI:"):
          inAIResponse = true
          tb.setForegroundColor(fgGreen, bright=true)
        elif line.startsWith("..."):
          tb.setForegroundColor(fgYellow, bright=true)
        elif inAIResponse:
          tb.setForegroundColor(fgGreen, bright=true)
        elif line.startsWith("Chat TUI") or line.startsWith("   Premi") or line.startsWith("   /model") or line.startsWith("   /history") or line.startsWith("System:"):
          tb.setForegroundColor(fgYellow, bright=true)
        else:
          tb.setForegroundColor(fgWhite)
        # Write at x=0
        tb.write(0, y, line)
        inc(y)

      # Redraw title over top area
      tb.setBackgroundColor(bgBlue)
      tb.setForegroundColor(fgWhite, bright=true)
      tb.write(max(1, (w - title.len) div 2), 0, title)
      tb.setBackgroundColor(bgNone)
      tb.setForegroundColor(fgWhite)
      tb.write(max(1, (w - title.len) div 2 + title.len + 2), 0, "Esc/Q")
      tb.setBackgroundColor(bgBlue)

      # === Draw input bar ===
      tb.setBackgroundColor(bgNone)
      # Top blue delimiter line (thin)
      tb.setForegroundColor(fgBlue, bright=true)
      tb.write(0, inputY, strutils.repeat("_", w))

      # Prompt label
      tb.setForegroundColor(fgCyan, bright=true)
      tb.write(0, inputY + 1, " INPUT ")
      tb.setBackgroundColor(bgNone)

      # Prompt character
      tb.setForegroundColor(fgWhite, bright=true)
      tb.write(0, inputY + 2, PromptChar)

      # Current input text
      if isProcessing:
        tb.setForegroundColor(fgWhite)
        tb.write(PromptChar.len, inputY + 2, "(processing...)")
      else:
        tb.setForegroundColor(fgWhite)
        tb.write(PromptChar.len, inputY + 2, currentInput)

      # Cursor block
      if not isProcessing:
        let cursorX = PromptChar.len + currentInput.runeLen
        if cursorX < w:
          tb.setBackgroundColor(bgYellow)
          tb.setForegroundColor(fgBlack)
          tb.write(cursorX, inputY + 2, " ")
          tb.setBackgroundColor(bgNone)

      # Bottom blue delimiter line (thin)
      tb.setForegroundColor(fgBlue, bright=true)
      tb.write(0, inputY + 3, strutils.repeat("_", w))

      # === Draw slash command menu (if active) ===
      if showingSlashMenu and state == Chatting:
        let filtered = filterCommands(currentInput[1 .. ^1])
        if filtered.len > 0:
          let menuY = inputY + 4  # One row below bottom delimiter
          let maxItems = min(filtered.len, SlashMenuHeight)

          # Calculate menu width based on longest command + description
          var maxCmdLen = 0
          for idx in filtered:
            let totalLen = SlashCommands[idx].name.len + 3 + SlashCommands[idx].description.len
            if totalLen > maxCmdLen: maxCmdLen = totalLen
          let menuWidth = min(w, max(w div 2, maxCmdLen + 4))

          # Draw each menu item with a ">" arrow for selection
          for row in 0 ..< maxItems:
            if menuY + row >= h: break
            let cmd = SlashCommands[filtered[row]]
            let arrow = if row == slashMenuIndex: ">" else: " "

            # Arrow indicator (yellow for selected)
            if row == slashMenuIndex:
              tb.setForegroundColor(fgYellow, bright=true)
            else:
              tb.setForegroundColor(fgWhite)
            tb.write(0, menuY + row, arrow)

            # Command name
            tb.setForegroundColor(fgCyan, bright=true)
            tb.write(2, menuY + row, cmd.name)

            # Description
            tb.setForegroundColor(fgWhite)
            tb.write(cmd.name.len + 3, menuY + row, cmd.description)

          # Draw a subtle bottom separator
          if menuY + maxItems < h:
            tb.setForegroundColor(fgWhite)
            tb.write(0, menuY + maxItems, strutils.repeat("─", menuWidth))

          # Reset attributes
          tb.setBackgroundColor(bgBlack)
          tb.setForegroundColor(fgWhite)

      # === Draw status bar at the bottom ===
      drawStatusBar(tb, h - StatusBarHeight, w)

    # Restore attributes
    tb.resetAttributes()
    tb.display()

    # Process input (non-blocking)
    var key = getKey()
    # DEBUG: log every key returned by getKey()
    #if key != Key.None:
    #  try:
    #    let f = open("debug_keys.txt", fmAppend)
    #    f.write("getKey returned: ord=" & $ord(key) & " key=" & $key & "\n")
    #    f.close()
    #  except: discard
    if key != Key.None:
      if handleInput(key):
        exitProc()

    # Poll async events
    try:
      poll()
    except:
      discard

    sleep(20)

main()
