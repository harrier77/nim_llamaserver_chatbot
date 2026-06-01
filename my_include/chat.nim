# ============================================================
# chat.nim - LLM communication and conversation management
# ============================================================
# Responsibilities:
# - Sending messages to the LLM server (streaming)
# - Handling tool calls (function calling)
# - Applying the sliding window on conversation history
#
# Dependencies: config.nim, my_include/tools
# IMPORTANT: do not import input.nim, ui.nim, main.nim
# ============================================================

import asyncdispatch, httpclient, json, re, strutils
import config
import tools

# ============================================================

# ============================================================
# Tool call args parsing with fallback for malformed JSON
# (small models often output truncated or slightly malformed JSON)
# ============================================================

proc safeParseToolArgs*(raw: string): JsonNode =
  ## Parse tool call arguments with multi-level fallback.
  ## 1. Try parseJson directly
  ## 2. Try repair (missing closing brace/bracket/quote)
  ## 3. Try regex extraction of known parameter keys

  # --- Level 1: direct parse ---
  try:
    return parseJson(raw)
  except JsonParsingError:
    discard

  # --- Level 2: repair truncated JSON ---
  block repair:
    var fixed = raw.strip()
    # Strip leading/trailing garbage
    let braceStart = fixed.find('{')
    if braceStart < 0: break repair  # no JSON object at all
    if braceStart > 0: fixed = fixed[braceStart..^1]

    # Remove trailing comma before closing
    fixed = fixed.replace(",}", "}").replace(",]", "]")

    # Remove trailing incomplete value after last colon
    let lastColon = fixed.rfind(':')
    if lastColon >= 0:
      let afterColon = fixed[lastColon+1..^1].strip()
      if afterColon.len == 0 or afterColon == "\"" or afterColon == "'":
        fixed = fixed[0..<lastColon]

    # Count brace depth and close any unclosed braces
    var depth = 0
    var inStr = false
    for c in fixed:
      if c == '"' and (depth == 0 or fixed[depth-1] != '\\'):
        inStr = not inStr
      elif not inStr:
        if c == '{': inc depth
        elif c == '}': dec depth
    if fixed.len > 0 and fixed[^1] != '}':
      for _ in 1..depth:
        fixed &= "}"
    # Also close unclosed strings (replace last unterminated quoted value)
    if raw.count('"') mod 2 != 0:
      fixed &= "\""

    try:
      return parseJson(fixed)
    except JsonParsingError:
      discard

  # --- Level 3: regex extraction from raw text ---
  result = %*{}

  # Try to extract known keys (both JSON-style "key": val and plain-text key: val)
  # Order matters: more specific keys first (limit_bytes before limit)
  let knownKeys = @["limit_bytes", "offset_bytes", "limit", "offset",
                    "file_path", "from_tail", "path", "exclude"]

  for key in knownKeys:
    # Pattern 1: "key": "string value"
    var matches: seq[string] = @[]
    if raw.find(re("\"" & key & "\"\\s*:\\s*\"([^\"]*)\""), matches) != -1:
      result[key] = %matches[0]
      continue

    # Pattern 2: "key": number
    matches = @[]
    if raw.find(re("\"" & key & "\"\\s*:\\s*(-?\\d+\\.?\\d*)"), matches) != -1:
      try:
        result[key] = %parseInt(matches[0])
      except:
        try:
          result[key] = %parseFloat(matches[0])
        except:
          result[key] = %matches[0]
      continue

    # Pattern 3: "key": true/false
    matches = @[]
    if raw.find(re("\"" & key & "\"\\s*:\\s*(true|false)"), matches) != -1:
      result[key] = %(matches[0] == "true")
      continue

    # Pattern 4: plain-text key=value
    matches = @[]
    if raw.find(re(key & "\\s*[=:]\\s*\"?([^\\s,\"]+)\"?"), matches) != -1:
      result[key] = %matches[0]
      continue

# ============================================================
# Conversation history management (sliding window)
# ============================================================

proc trimConversationHistory*() =
  ## Applies the sliding window to conversationHistory.
  ## Keeps the system message + the last N messages
  ## (where N = maxHistoryMessages).
  ##
  ## EDIT: if you need to change the trimming logic (e.g. always
  ## keep the last 2 user messages), modify here.
  if conversationHistory.len <= maxHistoryMessages + 1:
    return

  # Always keep the system message if present
  var newHistory: seq[JsonNode] = @[]
  if conversationHistory.len > 0 and conversationHistory[0].hasKey("role") and
     conversationHistory[0]["role"].getStr() == "system":
    newHistory.add(conversationHistory[0])

  # Keep the last maxHistoryMessages messages
  let startIndex = max(
    if newHistory.len > 0: 1 else: 0,
    conversationHistory.len - maxHistoryMessages
  )
  for i in startIndex ..< conversationHistory.len:
    newHistory.add(conversationHistory[i])

  conversationHistory = newHistory

# ============================================================
# Sending messages to the LLM (streaming + tool calls)
# ============================================================

proc sendToLLM*(prompt: string = "") {.async.} =
  ## Sends a prompt to the llama.cpp server and handles the streaming response.
  ## Supports tool calls (function calling) in a loop.
  ##
  ## FLOW:
  ## 1. Adds the user message to history
  ## 2. Applies the sliding window
  ## 3. Sends the POST request with streaming enabled
  ## 4. Parses SSE (Server-Sent Events) for streaming tokens
  ## 5. If the model requests tool calls → executes tools → repeats the loop
  ## 6. If normal response → adds to history → exits
  ##
  ## EDIT:
  ## - To change request parameters (e.g. temperature, top_p),
  ##   modify the JSON body before the POST.
  ## - To add new tools, modify them in my_include/tools.nim.
  ## - To add new tools, modify them in my_include/tools.nim.



  # --- Risolvi il provider per il modello corrente ---
  let currentProvider = findProviderForModel(ModelName)
  let requestUrl = currentProvider.baseUrl

  isProcessing = true

  if prompt.len > 0:
    aiResponseBuffer = ""
    # Add the user message to history
    conversationHistory.add(%*{
      "role": "user",
      "content": prompt
    })
    # Apply the sliding window after adding the message
    trimConversationHistory()

  var toolCallsCollected: seq[JsonNode] = @[]

  # Main loop: continues until there are no more tool calls
  while true:
    # Build the request body
    let body = %*{
      "model": ModelName,
      "messages": conversationHistory,
      "stream": true,
      "tools": tools.ToolsSchema
    }



    var client = newAsyncHttpClient()
    if currentProvider.apiKey.len > 0:
      client.headers = newHttpHeaders({
        "Content-Type": "application/json",
        "Authorization": "Bearer " & currentProvider.apiKey
      })
    else:
      client.headers = newHttpHeaders({"Content-Type": "application/json"})

    # OpenCode Zen headers: see applyOpenCodeHeaders() in httpdserver.nim for
    # the full explanation of why each header is required and what breaks if
    # any of them is missing (free-tier 429 regression).
    if currentProvider.name == "opencode":
      let reqId = nextOpenCodeRequestId()
      for h in currentProvider.extraHeaders:
        var val = h.value
        if h.key == "x-opencode-session" and val.startsWith("ses_"):
          val = opencodeSessionId
        elif h.key == "x-opencode-request" and val.startsWith("req_"):
          val = reqId
        client.headers[h.key] = val
      client.headers["User-Agent"] = "opencode/latest/1.3.15/cli"
    else:
      for h in currentProvider.extraHeaders:
        client.headers[h.key] = h.value



    # Variables for SSE parsing
    var pendingLine = ""
    aiResponseBuffer = ""
    toolCallsCollected = @[]
    var tokenCount = 0

    # --- Chunk smoothing for remote models ---
    # Accumulates content text and flushes at most currentProvider.linesPerChunk lines
    # per network chunk, preventing bursty UI updates.
    var ocPendingBuffer = ""
    var ocResponseStarted = false
    var modelDisplayed = false

    try:
      # Send POST request with streaming

      let response = await client.post(requestUrl, body = $body)


      # Read the response in streaming mode
      while true:
        let (hasMore, chunk) = await response.bodyStream.read()
        if not hasMore or chunk.len == 0: break
        inc(tokenCount)


        let data = pendingLine & chunk
        pendingLine = ""
        var lines = data.splitLines()

        # If the chunk does not end with newline, the last line is incomplete
        if hasMore and not data.endsWith("\n"):
          pendingLine = lines[^1]
          lines = lines[0..^2]

        for line in lines:
          if line.startsWith("data: "):
            let jsonStr = strutils.strip(line[6..^1])
            if jsonStr == "[DONE]": break

            try:
              let jsonChunk = parseJson(jsonStr)
              if not modelDisplayed and jsonChunk.hasKey("model"):
                outputLines.add("System: → " & jsonChunk["model"].getStr())
                modelDisplayed = true
              if jsonChunk.hasKey("choices") and jsonChunk["choices"].len > 0:
                let delta = jsonChunk["choices"][0].getOrDefault("delta")

                # --- 1. Handle content tokens (normal chat) ---
                if delta.hasKey("content"):
                  let content = delta["content"].getStr("")
                  if content.len > 0:
                    aiResponseBuffer &= content

                    if not currentProvider.isRemote:
                      # --- Local server: immediate output (existing behavior) ---
                      let isFirstChunkOfResponse =
                        aiResponseBuffer.len == content.len and toolCallsCollected.len == 0
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
                    else:
                      # --- Remote model: chunk smoothing ---
                      ocPendingBuffer &= content

                      # Find lines manually to avoid empty strings from splitLines
                      var allParts: seq[string] = @[]
                      var start = 0
                      var p = ocPendingBuffer.find('\n', start)
                      while p != -1:
                        allParts.add(ocPendingBuffer.substr(start, p - 1))
                        start = p + 1
                        p = ocPendingBuffer.find('\n', start)
                      
                      # Remaining part
                      let remaining = ocPendingBuffer.substr(start)

                      # If the buffer does not end with newline, keep it for next time
                      if not ocPendingBuffer.endsWith('\n'):
                        ocPendingBuffer = remaining
                      else:
                        ocPendingBuffer = ""

                      # Process completed lines
                      let maxLines = currentProvider.linesPerChunk
                      let toProcess = min(allParts.len, maxLines)
                      for i in 0 ..< toProcess:
                        let part = allParts[i]
                        if not ocResponseStarted:
                          outputLines.add("AI: " & part)
                          ocResponseStarted = true
                        else:
                          outputLines.add(part)
                      
                      # If we had more lines than allowed per chunk, put them back
                      # in the buffer to be processed in next iteration
                      if allParts.len > maxLines:
                        for i in maxLines ..< allParts.len:
                          ocPendingBuffer = (if ocPendingBuffer.len > 0: ocPendingBuffer & "\n" else: "") & allParts[i]
                        if remaining.len > 0:
                          ocPendingBuffer &= "\n" & remaining

                # --- 2. Handle tool call chunks ---
                if delta.hasKey("tool_calls"):
                  for tc in delta["tool_calls"]:
                    let idx = tc["index"].getInt()
                    # Ensure there is space for this index
                    while toolCallsCollected.len <= idx:
                      toolCallsCollected.add(%*{
                        "id": newJNull(),
                        "type": "function",
                        "function": {"name": "", "arguments": ""}
                      })

                    let target = toolCallsCollected[idx]
                    if tc.hasKey("id"): target["id"] = tc["id"]
                    if tc["function"].hasKey("name"):
                      target["function"]["name"] = tc["function"]["name"]
                    if tc["function"].hasKey("arguments"):
                      target["function"]["arguments"] = %(
                        target["function"]["arguments"].getStr() &
                        tc["function"]["arguments"].getStr()
                      )

            except JsonParsingError: discard
            except CatchableError: discard

    except CatchableError as e:

      outputLines.add("❌ Error: " & e.msg)
      client.close()
      break
    finally:
      client.close()



    # Flush remaining smoothed buffer (remote models only)
    if currentProvider.isRemote and ocPendingBuffer.len > 0:
      let remainingParts = ocPendingBuffer.splitLines()
      for part in remainingParts:
        if not ocResponseStarted:
          outputLines.add("AI: " & part)
          ocResponseStarted = true
        else:
          if part.len == 0:
            if outputLines.len > 0 and outputLines[^1].len > 0:
              outputLines.add("")
          else:
            outputLines.add(part)
      ocPendingBuffer = ""


    # After streaming ends, check if there are tool calls to execute
    if toolCallsCollected.len > 0:
      # IMPORTANT NOTE: the assistant message MUST have non-null content,
      # otherwise the model keeps making tool calls in an infinite loop.
      let assistantMsg = %*{
        "role": "assistant",
        "content": (
          if aiResponseBuffer.len > 0:
            %aiResponseBuffer
          else:
            %"Then I will answer and show any content..."
        ),
        "tool_calls": toolCallsCollected
      }
      conversationHistory.add(assistantMsg)

      # Execute each tool and add results to history
      for tc in toolCallsCollected:
        let toolName = tc["function"]["name"].getStr()
        let toolArgs = tc["function"]["arguments"].getStr()
        let toolId = tc["id"].getStr()

        outputLines.add("System: Tool Call -> " & toolName & "(" & toolArgs & ")")
        let result = tools.executeTool(toolName, safeParseToolArgs(toolArgs))

        # Extract content and summary from the tool's JSON result
        # The tool returns: {"content": "...", "summary": "...", "exit_code": X}
        # - content: full output (shown in UI)
        # - summary: brief execution report (for the model)
        var displayContent = ""
        var modelContent = result
        try:
          let parsed = parseJson(result)

          # Extract display content (full output shown to user)
          if parsed.hasKey("error"):
            displayContent = "Error: " & parsed["error"].getStr()
          elif parsed.hasKey("content"):
            displayContent = parsed["content"].getStr()
            # Prepend exit_code for display when non-zero
            if parsed.hasKey("exit_code"):
              let ec = parsed["exit_code"].getInt()
              if ec != 0:
                displayContent = "[Exit code: " & $ec & "]\n" & displayContent

          # Extract model content (summary when available)
          if parsed.hasKey("summary"):
            modelContent = parsed["summary"].getStr()
          elif parsed.hasKey("content"):
            modelContent = parsed["content"].getStr()
            if parsed.hasKey("exit_code"):
              let ec = parsed["exit_code"].getInt()
              if ec != 0:
                modelContent = "[Exit code: " & $ec & "]\n" & modelContent
          elif parsed.hasKey("error"):
            modelContent = "Error: " & parsed["error"].getStr()
        except:
          displayContent = result
          modelContent = "[JSON PARSE ERROR: " & result & "]"

        # Show tool result in TUI (like WebUI does)
        if displayContent.len > 0:
          outputLines.add("---")
          outputLines.add("***" & toolName & "***:")
          for line in displayContent.splitLines():
            outputLines.add("  " & line)

        conversationHistory.add(%*{
          "role": "tool",
          "tool_call_id": toolId,
          "name": toolName,
          "content": modelContent
        })

      # Round complete, go back to the top of the loop to send
      # tool results back to the model
      continue
    else:
      # No tool calls, normal response complete
      if aiResponseBuffer.len > 0:
        conversationHistory.add(%*{
          "role": "assistant",
          "content": aiResponseBuffer
        })
      break

  # Post-response cleanup
  isProcessing = false
  if outputLines.len > MaxOutputLines:
    outputLines = outputLines[outputLines.len - MaxOutputLines .. ^1]
  # Don't reset scrollOffset: let the user keep their scroll position.
  # If they were at the bottom (scrollOffset=0), new content auto-scrolls
  # into view because the renderer always shows the last visibleRows.
  # Apply the sliding window after adding the assistant response
  trimConversationHistory()
