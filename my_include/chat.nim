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

import asyncdispatch, httpclient, json, strutils, times, math
import config
import tools

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



  # --- Determina se il modello è OpenCode ---
  var isOcModel = false
  if OpenCodeEnabled:
    for m in OpenCodeModelIds:
      if m == ModelName:
        isOcModel = true
        break


  # Costruisci URL e headers in base al tipo di modello
  let requestUrl = if isOcModel: OpenCodeBaseUrl else: APIUrl

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
    if isOcModel:
      client.headers = newHttpHeaders({
        "Content-Type": "application/json",
        "Authorization": "Bearer " & OpenCodeApiKey
      })
    else:
      client.headers = newHttpHeaders({"Content-Type": "application/json"})



    # Variables for SSE parsing
    var pendingLine = ""
    aiResponseBuffer = ""
    toolCallsCollected = @[]
    var tokenCount = 0

    # --- Chunk smoothing for remote models ---
    # Accumulates content text and flushes at most MaxOcLinesPerChunk lines
    # per network chunk, preventing bursty UI updates.
    var ocPendingBuffer = ""
    var ocResponseStarted = false
    const MaxOcLinesPerChunk = 3

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
              if jsonChunk.hasKey("choices") and jsonChunk["choices"].len > 0:
                let delta = jsonChunk["choices"][0].getOrDefault("delta")

                # --- 1. Handle content tokens (normal chat) ---
                if delta.hasKey("content"):
                  let content = delta["content"].getStr("")
                  if content.len > 0:
                    aiResponseBuffer &= content

                    if not isOcModel:
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

                      # Split accumulated buffer into lines
                      var allParts = ocPendingBuffer.splitLines()

                      # If stream still active and buffer doesn't end with newline,
                      # the last part is incomplete — save it for next chunk
                      if allParts.len > 0 and not ocPendingBuffer.endsWith('\n'):
                        ocPendingBuffer = allParts[^1]
                        if allParts.len > 1:
                          allParts = allParts[0 .. ^2]
                        else:
                          allParts = @[]
                      else:
                        ocPendingBuffer = ""

                      # Process at most MaxOcLinesPerChunk lines this round
                      let toProcess = min(allParts.len, MaxOcLinesPerChunk)
                      for i in 0 ..< toProcess:
                        let part = allParts[i]
                        if not ocResponseStarted:
                          outputLines.add("AI: " & part)
                          ocResponseStarted = true
                        else:
                          if part.len == 0:
                            if outputLines.len > 0 and outputLines[^1].len > 0:
                              outputLines.add("")
                          else:
                            outputLines.add(part)

                      # Save remaining unprocessed lines back to buffer
                      for i in toProcess ..< allParts.len:
                        if ocPendingBuffer.len > 0:
                          ocPendingBuffer &= "\n" & allParts[i]
                        else:
                          ocPendingBuffer = allParts[i]

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
    if isOcModel and ocPendingBuffer.len > 0:
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
        let result = tools.executeTool(toolName, parseJson(toolArgs))

        # Extract content from the tool's JSON result
        # The tool returns: {"content": "...", "exit_code": X}
        var content = result
        try:
          let parsed = parseJson(result)
          if parsed.hasKey("content"):
            content = parsed["content"].getStr()
            # Include exit_code if non-zero
            if parsed.hasKey("exit_code"):
              let exitCode = parsed["exit_code"].getInt()
              if exitCode != 0:
                content = "[Exit code: " & $exitCode & "]\n" & content
          elif parsed.hasKey("error"):
            content = "Error: " & parsed["error"].getStr()
        except:
          content = "[JSON PARSE ERROR: " & result & "]"



        conversationHistory.add(%*{
          "role": "tool",
          "tool_call_id": toolId,
          "name": toolName,
          "content": content
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
