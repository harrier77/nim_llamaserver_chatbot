import json, os, osproc, re, strutils, httpclient
import config_web

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
          },
          "max_bytes": {
            "type": "number",
            "description": "Maximum bytes to read before splitting into lines (default: 2048, -1 to disable)"
          },
          "from_tail": {
            "type": "boolean",
            "description": "When true, offset is counted from the end of the file (1 = last line). Useful for reading log files tail-first."
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
          "include": {
            "type": "string",
            "description": "Glob pattern: only files matching this pattern are shown. Example: '*.txt' shows only .txt files. Default: all files."
          },
          "exclude": {
            "type": "string",
            "description": "Glob pattern for files to EXCLUDE (skip) from results. Use this only to narrow down after include."
          }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "websearch",
      "description": "Search the public web for current information via Firecrawl API. Returns up to N Markdown results with title, URL, and snippet. Requires a free API key configured in auth.json under \"firecrawl\".",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "The search query. Be specific; quote exact phrases when needed."
          },
          "num_results": {
            "type": "number",
            "description": "Number of results to return (1-20, default 8)"
          }
        },
        "required": ["query"]
      }
    }
  }
]"""

# Export ToolsSchema for use by other modules (e.g., chat.nim)
let ToolsSchema* = parseJson(ToolsSchemaJson)


# ============================================================
# Tool call args parsing with fallback for malformed JSON
# (small models often output truncated or slightly malformed JSON,
#  e.g. LFM2.5 emits `"limit":` with no value → JSON.parse fails)
# ============================================================

proc safeParseToolArgs*(raw: string): JsonNode =
  ## Parse tool call arguments with multi-level fallback.
  ## 1. Try parseJson directly
  ## 2. Try repair (missing closing brace/bracket/quote, trailing colon)
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

    # Normalize Python-style booleans (common with llama.cpp/python-finetuned models)
    fixed = fixed.replace(": True", ": true")
    fixed = fixed.replace(": False", ": false")
    fixed = fixed.replace(": None", ": null")

    # Remove trailing comma before closing
    fixed = fixed.replace(",}", "}").replace(",]", "]")

    # Remove trailing incomplete value(s) after last colon.
    # Handles LFM2.5 cases:
    #   {"file_path":"x","limit":}
    #   {"file_path":"x","limit":, "offset":}
    # If after the last colon we only have a closing brace/bracket/comma
    # (or nothing), the model emitted an empty value — drop the value AND
    # the key that owned it, otherwise the JSON is still invalid
    # (e.g. {"file_path":"x","limit"} — key without value).
    # Loop because multiple orphan keys can appear in sequence.
    var changed = true
    while changed:
      changed = false
      let lastColon = fixed.rfind(':')
      if lastColon >= 0:
        let afterColon = fixed[lastColon+1..^1].strip()
        if afterColon.len == 0 or afterColon == "\"" or afterColon == "'" or
           afterColon == "}" or afterColon == "]" or afterColon == ",":
          # Drop from the last colon, then walk back through whitespace and
          # the key identifier (and optional leading comma) to fully remove
          # the orphan entry.
          fixed = fixed[0..<lastColon]
          # Strip trailing whitespace
          while fixed.len > 0 and fixed[^1] in {' ', '\t', '\n'}:
            fixed.setLen(fixed.len - 1)
          # Walk back through the key (which is a quoted string)
          if fixed.len > 0 and fixed[^1] == '"':
            fixed.setLen(fixed.len - 1)
            # Walk back through the key body
            while fixed.len > 0 and fixed[^1] != '"':
              fixed.setLen(fixed.len - 1)
            if fixed.len > 0 and fixed[^1] == '"':
              fixed.setLen(fixed.len - 1)
          # Strip whitespace and optional leading comma
          while fixed.len > 0 and fixed[^1] in {' ', '\t', '\n'}:
            fixed.setLen(fixed.len - 1)
          if fixed.len > 0 and fixed[^1] == ',':
            fixed.setLen(fixed.len - 1)
          changed = true

    # Count brace depth and close any unclosed braces
    var depth = 0
    var inStr = false
    var esc = false
    for c in fixed:
      if esc:
        esc = false
        continue
      if c == '\\':
        esc = true
        continue
      if c == '"' :
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

  # Try to extract known keys (JSON-style "key": val)
  # Order matters: more specific keys first (max_bytes before limit)
  let knownKeys = @["max_bytes", "offset_bytes", "limit", "offset",
                    "file_path", "from_tail", "path", "include", "exclude"]

  for key in knownKeys:
    # Pattern 1: "key": "string value"
    var captures: seq[string] = @[]
    if re.match(raw, re("\"" & key & "\"\\s*:\\s*\"([^\"]*)\""), captures):
      if captures.len > 0:
        result[key] = %captures[0]
        continue

    # Pattern 2: "key": number
    captures = @[]
    if re.match(raw, re("\"" & key & "\"\\s*:\\s*(-?\\d+\\.?\\d*)"), captures):
      if captures.len > 0:
        try:
          result[key] = %parseInt(captures[0])
        except:
          try:
            result[key] = %parseFloat(captures[0])
          except:
            result[key] = %captures[0]
        continue

    # Pattern 3: "key": true/false
    captures = @[]
    if re.match(raw, re("\"" & key & "\"\\s*:\\s*(true|false)"), captures):
      if captures.len > 0:
        result[key] = %(captures[0] == "true")
        continue

    # Pattern 4: plain-text key=value
    captures = @[]
    if re.match(raw, re(key & "\\s*[=:]\\s*\"?([^\\s,\"]+)\"?"), captures):
      if captures.len > 0:
        result[key] = %captures[0]
        continue


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
  const MaxReadBytes = 2048
  const MaxReadBytesTail = 4096

  let path = if args.hasKey("file_path") and args["file_path"].kind == JString:
               args["file_path"].getStr()
             else: ""
  if path == "":
    if args.kind != JObject or args.len == 0:
      return $(%*{"error": "Tool arguments could not be parsed. " &
                       "The model emitted malformed JSON. " &
                       "Please retry the request. (raw args: " & $args & ")"})
    return $(%*{"error": "Missing file_path parameter"})

  let offset = if args.hasKey("offset"): args["offset"].getInt() else: 1
  let limit = if args.hasKey("limit"): args["limit"].getInt() else: -1
  let fromTail = if args.hasKey("from_tail"): args["from_tail"].getBool() else: false
  var maxBytes = if args.hasKey("max_bytes"): args["max_bytes"].getInt() else: MaxReadBytes
  # When reading from tail, raise byte limit to 4KB unless explicitly overridden
  if fromTail and not args.hasKey("max_bytes"):
    maxBytes = MaxReadBytesTail

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
    var content = readFile(resolvedPath)

    # Skip page markers (PDF-derived text files like delibere documents)
    var markerPos = content.find("Pagina 1 di")
    if markerPos < 0:
      markerPos = content.find("Pag 1 di")
    if markerPos >= 0:
      content = content[markerPos..<content.len]

    # Byte truncation (before splitting into lines)
    let totalBytes = content.len
    var truncatedByBytes = false
    if maxBytes >= 0 and totalBytes > maxBytes:
      content = content[0..<maxBytes]
      truncatedByBytes = true

    let lines = content.splitLines()
    if offset > lines.len:
      return $(%*{"error": "Offset beyond file length"})

    let effectiveLimit = if limit == -1: MaxReadLines else: limit
    var startIdx: int
    var endIdx: int
    var truncatedBefore = false

    if fromTail:
      # offset counts from end: 1 = last line
      # endIdx is the line at `offset` from end; startIdx goes backward by effectiveLimit
      endIdx = max(0, lines.len - offset)
      startIdx = max(0, endIdx - effectiveLimit + 1)
      # Check if there are more lines before startIdx
      if startIdx > 0:
        truncatedBefore = true
    else:
      startIdx = max(0, offset - 1)
      endIdx = min(lines.len - 1, startIdx + effectiveLimit - 1)

    let slice = lines[startIdx .. endIdx]
    var resultContent = slice.join("\n")

    # Add truncation notices
    let totalLines = lines.len
    if fromTail:
      if truncatedBefore:
        resultContent = "[... truncated, use offset/limit to read earlier lines]\n" & resultContent
    else:
      let lastLineReturned = endIdx + 1
      if lastLineReturned < totalLines:
        resultContent &= "\n[... truncated at " & $effectiveLimit & " lines, use offset/limit to read more]"
    if truncatedByBytes:
      resultContent &= "\n[... truncated at " & $maxBytes & " bytes, use max_bytes to read more]"

    return $(%*{"content": resultContent})
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

  let path = if args.hasKey("file_path") and args["file_path"].kind == JString:
               args["file_path"].getStr()
             else: ""
  if path == "":
    if args.kind != JObject or args.len == 0:
      return $(%*{"error": "Tool arguments could not be parsed. " &
                       "The model emitted malformed JSON. " &
                       "Please retry the request. (raw args: " & $args & ")"})
    return $(%*{"error": "Missing file_path parameter"})

  # Resolve path relative to cwd (same logic as readTool)
  var resolvedPath = path.replace("\\", "/")
  if not resolvedPath.startsWith("/") and not (resolvedPath.len >= 2 and resolvedPath[1] == ':'):
    resolvedPath = getCurrentDir() / resolvedPath

  if not fileExists(resolvedPath):
    return $(%*{"error": "File not found: " & resolvedPath})

  let offsetBytes = if args.hasKey("offset_bytes"): args["offset_bytes"].getInt() else: 0
  let limitBytes = if args.hasKey("limit_bytes"): args["limit_bytes"].getInt() else: MaxReadBytes

  # ── Debug ──────────────────────────────────────────────────────────────────
  var dbg: seq[string] = @[]
  dbg.add "=== getFileTool ==="
  dbg.add "args: " & $args
  dbg.add "path: " & path
  dbg.add "resolvedPath: " & resolvedPath
  dbg.add "offsetBytes: " & $offsetBytes
  dbg.add "limitBytes: " & $limitBytes
  # ───────────────────────────────────────────────────────────────────────────

  try:
    var content = readFile(resolvedPath)
    dbg.add "fileSize (raw): " & $content.len

    # Clean text: skip everything before page marker if present
    # (common in PDF-derived text files like delibere documents).
    # Checks both "Pagina 1 di" and "Pag 1 di".
    var markerPos = content.find("Pagina 1 di")
    if markerPos < 0:
      markerPos = content.find("Pag 1 di")
    if markerPos >= 0:
      content = content[markerPos..<content.len]
      dbg.add "markerPos: " & $markerPos
      dbg.add "fileSize after marker-cleanup: " & $content.len
    else:
      dbg.add "no page marker found"

    # Apply byte offset
    if offsetBytes > 0 and offsetBytes < content.len:
      content = content[offsetBytes..<content.len]
      dbg.add "applied offsetBytes=" & $offsetBytes
    elif offsetBytes >= content.len:
      content = ""
      dbg.add "offsetBytes >= content.len, content emptied"
    dbg.add "fileSize after offset: " & $content.len

    # Truncate to limit bytes (always attempted, guarded by try)
    try:
      content = content[0..<limitBytes] & "\n[... truncated to " & $limitBytes & " bytes]"
    except:
      discard
    dbg.add "final content length: " & $content.len

    # ── Write debug log (with rotation) ───────────────────────────────────────
    var logDir: string
    {.cast(gcsafe).}:
      logDir = config_web.ExeDir
    for line in dbg:
      config_web.writeLog(logDir, line)
    # ──────────────────────────────────────────────────────────────────────────

    return $(%*{"content": content})
  except Exception as e:
    dbg.add "EXCEPTION: " & e.msg
    var logDir: string
    {.cast(gcsafe).}:
      logDir = config_web.ExeDir
    for line in dbg:
      config_web.writeLog(logDir, line)
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

  # Include filter: default to all files, model can override
  let includeGlob = if args.hasKey("include"): args["include"].getStr() else: "**"

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


# ============================================================
# Web search tool — Firecrawl v2 Search API (POST JSON)
# ============================================================

const
  WebSearchDefaultResults = 8
  WebSearchMaxResults     = 20
  WebSearchTimeoutMs      = 10_000

proc websearchTool*(args: JsonNode): string {.gcsafe.} =
  ## Web search via Firecrawl v2 Search API (requires API key in auth.json).
  var logDir: string
  var apiKey: string
  {.cast(gcsafe).}:
    logDir = config_web.ExeDir
    apiKey = config_web.FirecrawlApiKey

  let query = if args.hasKey("query") and args["query"].kind == JString:
                args["query"].getStr() else: ""
  config_web.writeLog(logDir, "[WEBSEARCH] ENTER query=\"" & query & "\" args=" & $args)
  if query.len == 0:
    config_web.writeLog(logDir, "[WEBSEARCH] ERROR: missing query")
    return $(%*{"error": "Missing query parameter"})

  let n = if args.hasKey("num_results"):
            let r = args["num_results"].getInt()
            if r < 1: 1 elif r > WebSearchMaxResults: WebSearchMaxResults else: r
          else: WebSearchDefaultResults

  if apiKey.len == 0:
    config_web.writeLog(logDir, "[WEBSEARCH] ERROR: Firecrawl API key not configured")
    return $(%*{"error": "Firecrawl API key not configured. " &
                     "Add {\"firecrawler\": {\"key\": \"YOUR_KEY\"}} to ~/.nim_chatbot/auth.json"})

  var client = newHttpClient()
  try:
    client.timeout = WebSearchTimeoutMs

    let payload = %*{
      "query": query,
      "sources": ["web"],
      "categories": [],
      "limit": n,
      "scrapeOptions": {
        "onlyMainContent": true,
        "maxAge": 172800000,
        "parsers": ["pdf"],
        "formats": []
      }
    }
    client.headers["Authorization"] = "Bearer " & apiKey
    client.headers["Content-Type"] = "application/json"

    let url = "https://api.firecrawl.dev/v2/search"
    config_web.writeLog(logDir, "[WEBSEARCH] POST " & url)
    let resp = client.post(url, $payload)

    if not resp.status.startsWith("2"):
      config_web.writeLog(logDir, "[WEBSEARCH] HTTP " & resp.status)
      return $(%*{"error": "Firecrawl API HTTP " & resp.status})

    let body = resp.body
    if body.len == 0:
      return $(%*{"content": "No results."})

    let j = parseJson(body)
    # Expected response: {"success": true, "data": {"web": [{"title": ..., "url": ..., "description": ...}, ...]}}
    var md = newStringOfCap(4096)
    var count = 0

    if j.hasKey("data") and j["data"].kind == JObject:
      let data = j["data"]
      # Results are in data.web (and optionally data.news, data.images)
      if data.hasKey("web") and data["web"].kind == JArray:
        for item in data["web"]:
          if count >= n: break
          let title = item{"title"}.getStr("")
          let url   = item{"url"}.getStr("")
          let desc  = item{"description"}.getStr(item{"snippet"}.getStr(""))
          if title.len == 0 and url.len == 0 and desc.len == 0:
            continue
          md.add "## " & title & "\n" & url & "\n" & desc & "\n\n"
          inc count

    if md.len == 0:
      md = "No results found. Try a different query."

    config_web.writeLog(logDir,
      "[WEBSEARCH] OK q=\"" & query & "\" n=" & $n & " results=" & $count)
    return $(%*{"content": md})

  except HttpRequestError as e:
    config_web.writeLog(logDir, "[WEBSEARCH] HttpRequestError: " & e.msg)
    return $(%*{"error": "Search failed: " & e.msg})
  except Exception as e:
    config_web.writeLog(logDir, "[WEBSEARCH] Exception: " & e.msg)
    return $(%*{"error": e.msg})
  finally:
    client.close()


proc executeTool*(name: string, args: JsonNode): string =
  ## Dispatch tool calls to the appropriate implementation.
  case name
  of "read": return readTool(args)
  of "get_file":
    return $(%*{"error": "Tool suspended: " & name & " is not available (use 'read' with max_bytes instead)"})
  of "file_glob_search": return fileGlobSearchTool(args)
  of "websearch": return websearchTool(args)
  of "bash", "readDelibera":
    return $(%*{"error": "Tool suspended: " & name & " is not available (only 'read', 'file_glob_search', and 'websearch' are active)"})
  else: return $(%*{"error": "Unknown tool: " & name})
