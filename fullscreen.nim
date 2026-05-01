# Full-screen TUI chat client for llama.cpp server
# Connects to llama-server on port 8080 and displays streaming responses

import os, strformat, strutils, json, httpclient, asyncdispatch, uri
import illwill, unicode
import tools

const
  InputBarHeight = 3          # Height of the input bar area
  MaxOutputLines = 1000        # Max lines to keep in output history
  PromptChar = "> "             # Prompt prefix for user input
  APIUrl = "http://localhost:8080/v1/chat/completions"

type
  AppState = enum
    Chatting,
    SelectingModel

var
  ModelName = "Qwen3.5_0.8b-text"  # Current model name (can be changed)
  state: AppState = Chatting      # Current application state
  availableModels: seq[string] = @[] # List of models from server
  selectedMenuIndex: int = 0      # Index for model selection menu

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
    let response = await client.get("http://localhost:8080/v1/models")
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
  # FIX: Add system message to instruct LLM about tool usage
  conversationHistory: seq[JsonNode] = @[
    %*{
      "role": "system",
      "content": "You have access to tools: read and bash. IMPORTANT: When using the bash tool, only call it ONCE per task. Do NOT make multiple bash calls to get the same information. For example, if you need to list directory contents, use 'ls -la' once - do not follow up with additional calls like 'find' or 'ls' again. One bash call is sufficient for most tasks."
    }
  ]  # Chat history for API

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

proc keyToChar(key: Key): string =
  ## Convert a printable key to its character representation
  case key
  of Key.Space: result = " "
  of Key.ExclamationMark: result = "!"
  of Key.DoubleQuote: result = "\""
  of Key.Hash: result = "#"
  of Key.Dollar: result = "$"
  of Key.Percent: result = "%"
  of Key.Ampersand: result = "&"
  of Key.SingleQuote: result = "'"
  of Key.LeftParen: result = "("
  of Key.RightParen: result = ")"
  of Key.Asterisk: result = "*"
  of Key.Plus: result = "+"
  of Key.Comma: result = ","
  of Key.Minus: result = "-"
  of Key.Dot: result = "."
  of Key.Slash: result = "/"
  of Key.Zero: result = "0"
  of Key.One: result = "1"
  of Key.Two: result = "2"
  of Key.Three: result = "3"
  of Key.Four: result = "4"
  of Key.Five: result = "5"
  of Key.Six: result = "6"
  of Key.Seven: result = "7"
  of Key.Eight: result = "8"
  of Key.Nine: result = "9"
  of Key.Colon: result = ":"
  of Key.Semicolon: result = ";"
  of Key.LessThan: result = "<"
  of Key.Equals: result = "="
  of Key.GreaterThan: result = ">"
  of Key.QuestionMark: result = "?"
  of Key.At: result = "@"
  of Key.LeftBracket: result = "["
  of Key.Backslash: result = "\\"
  of Key.RightBracket: result = "]"
  of Key.Caret: result = "^"
  of Key.Underscore: result = "_"
  of Key.GraveAccent: result = "`"
  of Key.LeftBrace: result = "{"
  of Key.Pipe: result = "|"
  of Key.RightBrace: result = "}"
  of Key.Tilde: result = "~"
  of Key.A: result = "a"
  of Key.B: result = "b"
  of Key.C: result = "c"
  of Key.D: result = "d"
  of Key.E: result = "e"
  of Key.F: result = "f"
  of Key.G: result = "g"
  of Key.H: result = "h"
  of Key.I: result = "i"
  of Key.J: result = "j"
  of Key.K: result = "k"
  of Key.L: result = "l"
  of Key.M: result = "m"
  of Key.N: result = "n"
  of Key.O: result = "o"
  of Key.P: result = "p"
  of Key.Q: result = "q"
  of Key.R: result = "r"
  of Key.S: result = "s"
  of Key.T: result = "t"
  of Key.U: result = "u"
  of Key.V: result = "v"
  of Key.W: result = "w"
  of Key.X: result = "x"
  of Key.Y: result = "y"
  of Key.Z: result = "z"
  of Key.ShiftA: result = "A"
  of Key.ShiftB: result = "B"
  of Key.ShiftC: result = "C"
  of Key.ShiftD: result = "D"
  of Key.ShiftE: result = "E"
  of Key.ShiftF: result = "F"
  of Key.ShiftG: result = "G"
  of Key.ShiftH: result = "H"
  of Key.ShiftI: result = "I"
  of Key.ShiftJ: result = "J"
  of Key.ShiftK: result = "K"
  of Key.ShiftL: result = "L"
  of Key.ShiftM: result = "M"
  of Key.ShiftN: result = "N"
  of Key.ShiftO: result = "O"
  of Key.ShiftP: result = "P"
  of Key.ShiftQ: result = "Q"
  of Key.ShiftR: result = "R"
  of Key.ShiftS: result = "S"
  of Key.ShiftT: result = "T"
  of Key.ShiftU: result = "U"
  of Key.ShiftV: result = "V"
  of Key.ShiftW: result = "W"
  of Key.ShiftX: result = "X"
  of Key.ShiftY: result = "Y"
  of Key.ShiftZ: result = "Z"
  else: result = ""

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

  var toolCallsCollected: seq[JsonNode] = @[]
  
  # Recursive-like loop to handle potential multiple tool call rounds
  while true:
    # Prepare request body with streaming enabled and tools schema
    # Create messages without system prompt to avoid model confusion
    # The system prompt is only needed in the first request
    var messagesWithoutSystem: seq[JsonNode] = @[]
    for msg in conversationHistory:
      if msg{"role"}.getStr() != "system":
        messagesWithoutSystem.add(msg)
    
    # FIX: Only include tools in FIRST request (when there's only user message)
    # After tool calls, don't repeat tool definitions - model already knows them
    # To always include tools: uncomment the tools line below
    var body: JsonNode
    if messagesWithoutSystem.len == 1 and messagesWithoutSystem[0]["role"].getStr() == "user":
      # First request - include tools
      body = %*{
        "model": ModelName,
        "messages": messagesWithoutSystem,
        "stream": true,
        "tools": tools.ToolsSchema
      }
    else:
      # Subsequent requests (after tool calls) - don't include tools
      body = %*{
        "model": ModelName,
        "messages": messagesWithoutSystem,
        "stream": true
      }
    try:
      let f = open("debug_tools.txt", fmAppend)
      f.write("\n--- MSG TO MODEL ---\n" & $body & "\n--- END ---\n")
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
      # After: "content": "Then I will answer and tell you any content..." - Matches Python version format
      # The model needs this placeholder text to understand it should respond with final answer, not make more tool calls
      let assistantMsg = %*{"role": "assistant", "content": (if aiResponseBuffer.len > 0: %aiResponseBuffer else: %"Then I will answer and tell you any content..."), "tool_calls": toolCallsCollected}
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
          f.write("\n--- EXTRACTED CONTENT: " & content & " ---\n")
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

proc handleInput(key: Key): bool =
  ## Process a keypress. Returns true if we should quit.
  if isProcessing and state == Chatting:
    # Ignore input while processing chat
    return false

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
        outputLines.add("System: Modello cambiato a " & ModelName)
      state = Chatting
      return false
    else: discard
    return false

  case key
  of Key.Escape: return true
  of Key.Q:
    if currentInput.len == 0: return true
    else:
      currentInput.add(keyToChar(key))
      return false
  of Key.Enter:
    if currentInput.len > 0:
      let prompt = currentInput
      currentInput = ""
      
      # FIX: Add slash commands for exiting
      let cmd = strutils.strip(prompt).toLowerAscii()
      if cmd == "/quit" or cmd == "/q":
        return true
      
      if cmd == "/model":
        # Trigger model selection
        asyncCheck fetchModels()
        state = SelectingModel
        return false
      
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
    scrollOffset += 1
    return false
  of Key.Down:
    if scrollOffset > 0: scrollOffset -= 1
    return false
  else:
    let ch = keyToChar(key)
    if ch.len > 0:
      currentInput.add(ch)
    # Fallback for backspace on Windows - illwill doesn't always map
    # backspace to Key.Backspace/Key.Delete, so we check raw key codes
    # 127 = Backspace (ASCII), 8 = Backspace (control char)
    elif ord(key) == 127 or ord(key) == 8:
      if currentInput.len > 0:
        currentInput.removeLastRune()
    else:
      echo "Unknown key: ", ord(key), " ", key
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

proc main() =
  illwillInit(fullscreen=true)
  setControlCHook(exitProc)
  hideCursor()

  # Welcome message
  outputLines.add("Chat TUI - Connesso a llama.cpp su " & APIUrl)
  outputLines.add("   Modello: " & ModelName)
  outputLines.add("   Premi Enter per inviare, Esc o /q per uscire, /model per cambiare")


  while true:
    var tb = newTerminalBuffer(terminalWidth(), terminalHeight())
    let w = tb.width
    let h = tb.height

    if h <= InputBarHeight + 2 or w < 20:
      tb.setForegroundColor(fgRed, bright=true)
      tb.write(0, 0, "Terminal too small! Resize to continue.")
      tb.display()
      sleep(50)
      var key = getKey()
      if key == Key.Escape or key == Key.Q: exitProc()
      continue

    let outputHeight = h - InputBarHeight
    let inputY = outputHeight

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
            let line = "> " & m & " <"
            tb.write((w - line.len) div 2, startY + i, line)
            tb.setBackgroundColor(bgBlack)
          else:
            tb.setForegroundColor(fgWhite)
            tb.write((w - m.len) div 2, startY + i, m)
      
      tb.setForegroundColor(fgWhite)
      let help = "↑/↓: Naviga, Enter: Conferma, Esc: Annulla"
      tb.write((w - help.len) div 2, h - 2, help)
    else:
      # === Draw output area ===
      # MEMO: Borders (│, ─, ┌, etc.) have been removed to maximize horizontal space.
      # Title bar
      tb.setBackgroundColor(bgBlue)
      tb.setForegroundColor(fgWhite, bright=true)
      let statusIcon = if isProcessing: "..." else: "OK"
      let title = fmt" CHAT [{outputLines.len} msg] {statusIcon} "
      tb.write(max(1, (w - title.len) div 2), 0, title)
      tb.setBackgroundColor(bgBlack)

      # Help text
      tb.setForegroundColor(fgWhite)
      tb.write(max(1, (w - title.len) div 2 + title.len + 2), 0, "Esc/Q=quit")

      # Reset background to black
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

      # Determine which lines to show (always show from bottom)
      let visibleRows = max(1, outputHeight - 1)
      scrollOffset = max(0, min(scrollOffset, max(0, allDisplayLines.len - visibleRows)))
      let showFrom = if allDisplayLines.len > visibleRows:
        max(0, allDisplayLines.len - visibleRows - scrollOffset)
      else:
        0
      let showTo = min(showFrom + visibleRows, allDisplayLines.len)

      # Draw visible output lines
      var y = 1
      var inAIResponse = false
      for i in showFrom ..< showTo:
        if y >= outputHeight: break
        # Draw content with colors based on prefix
        let line = allDisplayLines[i]
        if line.startsWith("Tu:"):
          inAIResponse = false
          tb.setForegroundColor(fgCyan, bright=true)
        elif line.startsWith("AI:"):
          inAIResponse = true
          tb.setForegroundColor(fgGreen, bright=true)
        elif line.startsWith("..."):
          tb.setForegroundColor(fgYellow, bright=true)
        elif inAIResponse:
          tb.setForegroundColor(fgGreen, bright=true)
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
      tb.setForegroundColor(fgBlack)
      tb.write(max(1, (w - title.len) div 2 + title.len + 2), 0, "Esc/Q")
      tb.setBackgroundColor(bgBlue)

      # === Draw input bar ===
      # Prompt label
      tb.setForegroundColor(fgCyan, bright=true)
      tb.write(0, inputY, " INPUT ")
      tb.setBackgroundColor(bgNone)

      # Prompt character
      tb.setForegroundColor(fgWhite, bright=true)
      tb.write(0, inputY + 1, PromptChar)

      # Current input text
      if isProcessing:
        tb.setForegroundColor(fgYellow)
        tb.write(PromptChar.len, inputY + 1, "(processing...)")
      else:
        tb.setForegroundColor(fgYellow, bright=true)
        tb.write(PromptChar.len, inputY + 1, currentInput)

      # Cursor block
      if not isProcessing:
        let cursorX = PromptChar.len + currentInput.runeLen
        if cursorX < w:
          tb.setBackgroundColor(bgYellow)
          tb.setForegroundColor(fgBlack)
          tb.write(cursorX, inputY + 1, " ")
          tb.setBackgroundColor(bgNone)

    # Restore attributes
    tb.resetAttributes()
    tb.display()

    # Process input (non-blocking)
    var key = getKey()
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
