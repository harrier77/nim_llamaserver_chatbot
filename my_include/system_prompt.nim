## System prompt, loaded at runtime from system_prompt.yaml
## Uses `var` + a gcsafe helper proc to safely access in async callbacks.

import strutils, os

# --- PATH-INDEPENDENT RESOURCE LOOKUP FIX ---
#
# This module is imported by config.nim (and thus loaded before main() runs).
# At module load time, SystemPromptPath still has its fallback default
# (CWD-relative), so SYSTEM_PROMPT is initially populated with whatever
# the YAML file says — or the built-in fallback if launched from a
# different directory.
#
# Once main() sets ExeDir and calls initSystemPrompt(), the prompt is
# reloaded from the correct absolute path.  config.resetConversation()
# (called immediately after) replaces the conversation history so the
# first system message uses the properly-loaded prompt.
#
# This is the same pattern used for StatusFile in config.nim.
# =============================================================

const YAML_PATH_DEFAULT* = "my_include/system_prompt.yaml"
  ## Fallback default used only before main() overrides SystemPromptPath.
  ## When the exe is launched via PATH from a different directory,
  ## this relative path will NOT be found — but initSystemPrompt()
  ## fixes that at startup.

var SystemPromptPath*: string = YAML_PATH_DEFAULT
  ## Absolute path to system_prompt.yaml, set by main.nim at startup.
  ## Uses ExeDir so resource lookups work regardless of the directory
  ## from which the exe was launched (PATH-independent deployment).

proc loadSystemPrompt(path: string): string =
  ## Reads the system prompt from the given YAML file.
  ## Falls back to a minimal prompt if the file is missing or malformed.
  if not fileExists(path):
    stderr.writeLine("[WARN] system_prompt.yaml not found at " & path & ", using fallback prompt.")
    return "You are a helpful assistant."

  try:
    let content = readFile(path)
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
    stderr.writeLine("[WARN] Failed to read " & path & ", using fallback prompt.")
    return "You are a helpful assistant."

var SYSTEM_PROMPT*: string = loadSystemPrompt(SystemPromptPath)
  ## NOTE: at module load time this uses the CWD-relative fallback
  ## (YAML_PATH_DEFAULT).  main() calls initSystemPrompt() after setting
  ## ExeDir, and then config.resetConversation() to replace the initial
  ## conversation history with the correctly-loaded prompt.

proc initSystemPrompt*() =
  ## Reloads SYSTEM_PROMPT from SystemPromptPath.
  ## Called by main.nim after setting the correct ExeDir-relative path,
  ## so that resource lookups work even when launched from a different directory.
  SYSTEM_PROMPT = loadSystemPrompt(SystemPromptPath)

proc getSystemPrompt*(): string {.gcsafe.} =
  ## GC-safe accessor for SYSTEM_PROMPT.
  ## Use this inside async callbacks instead of accessing SYSTEM_PROMPT directly.
  {.cast(gcsafe).}:
    return SYSTEM_PROMPT
