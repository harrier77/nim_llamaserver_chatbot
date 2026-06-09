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

import asyncdispatch, httpclient, json, strutils, os, strformat
import config
import tools
import config_web

# ============================================================

# ============================================================
# safeParseToolArgs is defined in tools.nim (exported with *)
# so both chat.nim and httpdserver.nim can share the same robust
# multi-level JSON repair for LFM2.5 / Qwen / etc. malformed tool args.
# ============================================================

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

  # Reset cancel flag for this new request
  cancelRequested = false

  isProcessing = true

  if prompt.len > 0:
    aiResponseBuffer = ""
    currentTokensPerSec = 0.0
    # Add the user message to history
    conversationHistory.add(%*{
      "role": "user",
      "content": prompt
    })
    # Apply the sliding window after adding the message
    trimConversationHistory()
    config_web.writeLog(getCurrentDir(), "[CHAT] ▶ QUERY: " & prompt)

  var toolCallsCollected: seq[JsonNode] = @[]

  # Main loop: continues until there are no more tool calls
  while true:
    # Check if a /new (or other reset) was requested while we were running
    if cancelRequested:
      break
    # Build the request body
    let body = %*{
      "model": ModelName,
      "messages": conversationHistory,
      "stream": true,
      "timings_per_token": true,
      "return_progress": true,
      "tools": tools.ToolsSchema
    }
    config_web.writeLog(getCurrentDir(), "[CHAT] ▶ REQUEST: " & $body)


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
        # Check if the conversation was reset while streaming
        if cancelRequested:
          break
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
              if jsonChunk.hasKey("timings"):
                let t = jsonChunk["timings"]
                let predictedN = t{"predicted_n"}.getFloat(0.0)
                let predictedMs = max(t{"predicted_ms"}.getFloat(1.0), 1.0)
                if predictedN > 0:
                  currentTokensPerSec = (predictedN / predictedMs) * 1000.0
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
                  config_web.writeLog(getCurrentDir(), "[CHAT] ◀ TC_DELTA: " & $delta)
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
      config_web.writeLog(getCurrentDir(), "[CHAT] ❌ ERROR: " & e.msg)
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
      config_web.writeLog(getCurrentDir(), "[CHAT] ◀ TC_COLLECTED: " & $toolCallsCollected)
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

        config_web.writeLog(getCurrentDir(), "[CHAT] ▶ TC_EXEC: " & toolName & " args_raw=" & toolArgs & " args_parsed=" & $(safeParseToolArgs(toolArgs)))
        outputLines.add("System: Tool Call -> " & toolName & "(" & toolArgs & ")")
        let result = tools.executeTool(toolName, safeParseToolArgs(toolArgs))
        config_web.writeLog(getCurrentDir(), "[CHAT] ◀ TC_RESULT: " & toolName & " -> " & result)

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
      config_web.writeLog(getCurrentDir(), "[CHAT] ◀ NO_TOOL_CALLS (content_len=" & $aiResponseBuffer.len & ")")
      # No tool calls, normal response complete
      if aiResponseBuffer.len > 0:
        conversationHistory.add(%*{
          "role": "assistant",
          "content": aiResponseBuffer
        })
      if currentTokensPerSec > 0 and outputLines.len > 0:
        outputLines[^1] &= fmt"  ⚡ {currentTokensPerSec:.1f} t/s"
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
  config_web.writeLog(getCurrentDir(), "[CHAT] ✓ DONE")
