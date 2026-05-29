import json, os, osproc, strutils

# ============================================================
# Tools schema (single source of truth)
# ============================================================
# ToolsSchemaJson is a const string (safe for thread access via gcsafe procs).
# ToolsSchema is the JsonNode for use by the TUI (chat.nim).
# ============================================================

const ToolsSchemaJson* = """[
  {
    "type": "function",
    "function": {
      "name": "read",
      "description": "Read a file from the filesystem. Use this to read file contents.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_path": {
            "type": "string",
            "description": "Path to the file to read"
          },
          "offset": {
            "type": "number",
            "description": "Line number to start reading from (1-indexed)"
          },
          "limit": {
            "type": "number",
            "description": "Maximum number of lines to read"
          }
        },
        "required": ["file_path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "get_file",
      "description": "Read a text file with byte-based offset/limit. Use this to read specific portions of a file when byte position is known.",
      "parameters": {
        "type": "object",
        "properties": {
          "file_path": {
            "type": "string",
            "description": "Path to the file to read"
          },
          "offset_bytes": {
            "type": "number",
            "description": "Byte offset to start reading from (default: 0)"
          },
          "limit_bytes": {
            "type": "number",
            "description": "Maximum bytes to read (default: 2048)"
          }
        },
        "required": ["file_path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "file_glob_search",
      "description": "Search for files matching a glob pattern in a directory (non-recursive, top-level only).",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Base directory to search in"
          },
          "exclude": {
            "type": "string",
            "description": "Glob pattern for files to exclude"
          }
        },
        "required": ["path"]
      }
    }
  }
]"""

# Export ToolsSchema for use by other modules (e.g., chat.nim)
let ToolsSchema* = parseJson(ToolsSchemaJson)


proc globMatch(pattern: string, str: string): bool =
  ## Simple glob matching.
  ## - * matches any characters except /
  ## - ** matches any characters including /
  ## - ? matches a single character except /
  ## - [abc] / [!abc] character class with ranges support
  ##
  ## Inspired by llama.cpp's glob_match in common/common.cpp

  proc rec(pi: int, si: int): bool =
    if pi >= pattern.len:
      return si >= str.len

    # ** matches anything including /
    if pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*':
      if rec(pi + 2, si): return true
      if si < str.len: return rec(pi, si + 1)
      return false

    # * matches any characters except /
    if pattern[pi] == '*':
      var i = si
      while i < str.len and str[i] != '/':
        if rec(pi + 1, i): return true
        i += 1
      return rec(pi + 1, i)

    # ? matches a single character except /
    if pattern[pi] == '?' and si < str.len and str[si] != '/':
      return rec(pi + 1, si + 1)

    # [abc] character class
    if pattern[pi] == '[':
      let closePos = pattern.find(']', pi + 1)
      if closePos >= 0:
        if si >= str.len: return false
        var negated = false
        var classStart = pi + 1
        if classStart < closePos and pattern[classStart] == '!':
          negated = true
          classStart += 1
        # Skip leading ] or - as literal
        if classStart < closePos and (pattern[classStart] == ']' or pattern[classStart] == '-'):
          if str[si] == pattern[classStart]:
            if negated: return false
            return rec(closePos + 1, si + 1)
          classStart += 1
        var matched = false
        var j = classStart
        while j < closePos:
          if j + 2 < closePos and pattern[j + 1] == '-':
            let startChar = pattern[j]
            let endChar = pattern[j + 2]
            if str[si] >= startChar and str[si] <= endChar:
              matched = true
              break
            j += 3
          else:
            if pattern[j] == str[si]:
              matched = true
              break
            j += 1
        if negated: matched = not matched
        if matched:
          return rec(closePos + 1, si + 1)
        else:
          return false
      else:
        # No closing bracket, treat [ as literal
        if si < str.len and str[si] == '[':
          return rec(pi + 1, si + 1)
        return false

    # Literal character match (must check si < str.len first)
    if si < str.len and pattern[pi] == str[si]:
      return rec(pi + 1, si + 1)

    return false

  return rec(0, 0)


proc readTool*(args: JsonNode): string =
  const MaxReadLines = 25

  let path = if args.hasKey("file_path"): args["file_path"].getStr() else: ""
  if path == "": return $(%*{"error": "Missing file_path parameter"})

  let offset = if args.hasKey("offset"): args["offset"].getInt() else: 1
  let limit = if args.hasKey("limit"): args["limit"].getInt() else: -1

  # FIX: File path must be resolved relative to program's current working directory (not user home or other path)
  # Before: path was used directly without resolution, so relative paths like "colosseo.txt" failed
  # After: normalize path and resolve relative to cwd, matching Python version behavior
  # Example: "colosseo.txt" -> "C:/Users/pr30565/Nim_code/tui/colosseo.txt"
  var resolvedPath = path.replace("\\", "/")
  if not resolvedPath.startsWith("/") and not (resolvedPath.len >= 2 and resolvedPath[1] == ':'):
    # Relative path - resolve relative to current working directory
    resolvedPath = getCurrentDir() / resolvedPath

  if not fileExists(resolvedPath):
    return $(%*{"error": "File not found: " & resolvedPath})

  try:
    let lines = readFile(resolvedPath).splitLines()
    if offset > lines.len:
      return $(%*{"error": "Offset beyond file length"})

    let startIdx = max(0, offset - 1)
    let effectiveLimit = if limit == -1: MaxReadLines else: limit
    let endIdx = min(lines.len - 1, startIdx + effectiveLimit - 1)

    let slice = lines[startIdx .. endIdx]
    var content = slice.join("\n")

    # Add truncation notice if the file has more content beyond what was returned
    let totalLines = lines.len
    let lastLineReturned = endIdx + 1
    if lastLineReturned < totalLines:
      content &= "\n[... truncated at " & $effectiveLimit & " lines, use offset/limit to read more]"

    return $(%*{"content": content})
  except Exception as e:
    return $(%*{"error": e.msg})

proc bashTool*(args: JsonNode): string =
  const MaxBashOutputLines = 20

  let command = if args.hasKey("command"): args["command"].getStr() else: ""
  if command == "": return $(%*{"error": "Missing command parameter"})

  let offset = if args.hasKey("offset"): args["offset"].getInt() else: 1
  let limit = if args.hasKey("limit"): args["limit"].getInt() else: -1

  try:
    var res = ""
    var exitCode = 0
    when defined(windows):
      const gitBashPath = "C:\\Program Files\\git\\bin\\bash.exe"
      # Use Git Bash and change to current working directory
      var cwd = getCurrentDir().replace("\\", "/")
      let fullCommand = "cd '" & cwd & "' && " & command
      (res, exitCode) = execCmdEx(quoteShell(gitBashPath) & " -c " & quoteShell(fullCommand))
    else:
      (res, exitCode) = execCmdEx(command)

    var output = res.strip()
    let lines = output.splitLines()

    if offset > lines.len:
      return $(%*{"error": "Offset beyond output length", "exit_code": exitCode})

    let startIdx = max(0, offset - 1)
    let effectiveLimit = if limit == -1: MaxBashOutputLines else: min(limit, MaxBashOutputLines)
    let endIdx = min(lines.len - 1, startIdx + effectiveLimit - 1)

    let slice = lines[startIdx .. endIdx]
    var content = slice.join("\n")

    # Add truncation notice if there's more output beyond what was returned
    let totalLines = lines.len
    let lastLineReturned = endIdx + 1
    if lastLineReturned < totalLines:
      content &= "\n[... truncated at " & $effectiveLimit & " lines, use offset/limit to read more]"

    return $(%*{
      "content": content,
      "exit_code": exitCode
    })
  except Exception as e:
    return $(%*{"error": e.msg})

proc getFileTool*(args: JsonNode): string =
  ## Read a text file with byte-based offset/limit.
  ## Default limit is 2048 bytes, offset defaults to 0 (start of file).
  const MaxReadBytes = 2048

  let path = if args.hasKey("file_path"): args["file_path"].getStr() else: ""
  if path == "": return $(%*{"error": "Missing file_path parameter"})

  # Resolve path relative to cwd (same logic as readTool)
  var resolvedPath = path.replace("\\", "/")
  if not resolvedPath.startsWith("/") and not (resolvedPath.len >= 2 and resolvedPath[1] == ':'):
    resolvedPath = getCurrentDir() / resolvedPath

  if not fileExists(resolvedPath):
    return $(%*{"error": "File not found: " & resolvedPath})

  let offsetBytes = if args.hasKey("offset_bytes"): args["offset_bytes"].getInt() else: 0
  let limitBytes = if args.hasKey("limit_bytes"): args["limit_bytes"].getInt() else: MaxReadBytes

  try:
    var content = readFile(resolvedPath)

    # Clean text: skip everything before page marker if present
    # (common in PDF-derived text files like delibere documents).
    # Checks both "Pagina 1 di" and "Pag 1 di".
    var markerPos = content.find("Pagina 1 di")
    if markerPos < 0:
      markerPos = content.find("Pag 1 di")
    if markerPos >= 0:
      content = content[markerPos..<content.len]

    # Apply byte offset
    if offsetBytes > 0 and offsetBytes < content.len:
      content = content[offsetBytes..<content.len]
    elif offsetBytes >= content.len:
      content = ""

    # Truncate to limit bytes
    let wasTruncated = content.len > limitBytes
    if wasTruncated:
      content = content[0..<limitBytes] & "\n[... truncated to " & $limitBytes & " bytes]"

    return $(%*{"content": content})
  except Exception as e:
    return $(%*{"error": e.msg})

proc fileGlobSearchTool*(args: JsonNode): string =
  ## Search for files matching a glob pattern in a directory (non-recursive, top-level only).
  ## Inspired by llama.cpp's file_glob_search tool (server-tools.cpp).
  const MaxResults = 100

  let basePath = if args.hasKey("path"): args["path"].getStr() else: ""
  if basePath == "":
    return $(%*{"error": "Missing path parameter"})

  # Resolve relative paths
  var resolvedBase = basePath.replace("\\", "/")
  if not resolvedBase.startsWith("/") and not (resolvedBase.len >= 2 and resolvedBase[1] == ':'):
    resolvedBase = getCurrentDir() / resolvedBase

  if not dirExists(resolvedBase):
    return $(%*{"error": "Directory not found: " & resolvedBase})

  # Fixed: always search all files. The model (0.8B) cannot be trusted with an include parameter
  # — it keeps forcing *.nim regardless of the user's request.
  const includeGlob = "**"

  # Collect exclude glob patterns
  var excludePatterns: seq[string] = @[]
  if args.hasKey("exclude"):
    let e = args["exclude"].getStr()
    if e.len > 0: excludePatterns.add(e)

  var results: seq[string] = @[]
  var totalCount = 0
  var truncated = false

  try:
    for (kind, path) in walkDir(resolvedBase, relative = false):

      # Compute relative path and normalize separators for glob matching
      var relPath = relativePath(path, resolvedBase).replace("\\", "/")

      # Check include pattern
      if not globMatch(includeGlob, relPath):
        continue

      # Check exclude patterns
      var excluded = false
      for ep in excludePatterns:
        if globMatch(ep, relPath):
          excluded = true
          break
      if excluded: continue

      results.add(relPath)
      totalCount += 1
      if totalCount >= MaxResults:
        truncated = true
        break
  except Exception as e:
    return $(%*{"error": e.msg})

  let content = resolvedBase & "\n" & results.join("\n")

  return $(%*{
    "content": content,
    "total_matches": totalCount
  })


proc executeTool*(name: string, args: JsonNode): string =
  ## Dispatch tool calls to the appropriate implementation.
  case name
  of "read": return readTool(args)
  of "get_file": return getFileTool(args)
  of "file_glob_search": return fileGlobSearchTool(args)
  of "bash", "readDelibera":
    return $(%*{"error": "Tool suspended: " & name & " is not available (only 'read', 'get_file', and 'file_glob_search' are active)"})
  else: return $(%*{"error": "Unknown tool: " & name})
