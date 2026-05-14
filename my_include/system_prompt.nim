## System prompt, loaded at runtime from system_prompt.yaml
## Uses `var` + a gcsafe helper proc to safely access in async callbacks.

import strutils, os

const YAML_PATH* = "my_include/system_prompt.yaml"

proc loadSystemPrompt(): string =
  ## Reads the system prompt from the YAML file at startup.
  ## Falls back to a minimal prompt if the file is missing or malformed.
  if not fileExists(YAML_PATH):
    stderr.writeLine("[WARN] system_prompt.yaml not found at " & YAML_PATH & ", using fallback prompt.")
    return "You are a helpful assistant."

  try:
    let content = readFile(YAML_PATH)
    let lines = content.splitLines()
    var started = false
    for line in lines:
      if not started:
        if line.startsWith("system_prompt:"):
          started = true
        continue
      # Strip 2-space indentation from content lines
      if line.len >= 2:
        result.add(line[2 .. ^1])
      else:
        result.add(line)
      result.add("\n")
    # Remove trailing newline
    if result.len > 0 and result[^1] == '\n':
      result.setLen(result.len - 1)
  except:
    stderr.writeLine("[WARN] Failed to read " & YAML_PATH & ", using fallback prompt.")
    return "You are a helpful assistant."

var SYSTEM_PROMPT*: string = loadSystemPrompt()

proc getSystemPrompt*(): string {.gcsafe.} =
  ## GC-safe accessor for SYSTEM_PROMPT.
  ## Use this inside async callbacks instead of accessing SYSTEM_PROMPT directly.
  {.cast(gcsafe).}:
    return SYSTEM_PROMPT
