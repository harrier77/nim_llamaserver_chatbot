import json, os, osproc, strutils

# FIX: Matches parameter names from demo.ts (e.g., file_path instead of path)
# Export ToolsSchema for use by other modules (e.g., webui server)
let ToolsSchema* = %*[
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
      "name": "bash",
      "description": "Execute a bash command on the system. Use this for running shell commands, listing files, etc. IMPORTANT: Only call this tool ONCE per task. Do not make multiple calls to get the same information (e.g., don't call 'ls -la' then 'ls' then 'find' for the same directory - one call is enough).",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The bash command to execute"
          }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "readDelibera",
      "description": "Read a delibera file from the summary directory. Automatically composes filename as delibera_XXXX_YYYY.txt where XXXX is 4-digit zero-padded number and YYYY is the year.",
      "parameters": {
        "type": "object",
        "properties": {
          "number": {
            "type": "string",
            "description": "The delibera number (e.g., '1' becomes '0001')"
          },
          "year": {
            "type": "string",
            "description": "The year of the delibera (e.g., '2026')"
          }
        },
        "required": ["number", "year"]
      }
    }
  }
]

proc readTool*(args: JsonNode): string =
  const MaxReadLines = 1000

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
    let effectiveLimit = if limit == -1: MaxReadLines else: min(limit, MaxReadLines)
    let endIdx = min(lines.len - 1, startIdx + effectiveLimit - 1)

    let slice = lines[startIdx .. endIdx]
    var content = slice.join("\n")

    # Add truncation notice if the file has more content beyond what was returned
    let totalLines = lines.len
    let lastLineReturned = endIdx + 1
    if lastLineReturned < totalLines:
      content &= "\n[... truncated at " & $MaxReadLines & " lines, use offset/limit to read more]"

    # Return JSON format
    return $(%*{"content": content})
  except Exception as e:
    return $(%*{"error": e.msg})

proc bashTool*(args: JsonNode): string =
  let command = if args.hasKey("command"): args["command"].getStr() else: ""
  if command == "": return $(%*{"error": "Missing command parameter"})

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

    # Return JSON format (like Python _bash_impl)
    # The frontend will parse this and extract the content
    return $(%*{
      "content": res.strip(),
      "exit_code": exitCode
    })
  except Exception as e:
    return $(%*{"error": e.msg})

proc cleanDeliberaText*(text: string): string =
  # If "Pag 1 di" is found in the text, remove everything before it
  let searchStr = "Pag 1 di"
  let pos = text.find(searchStr)
  if pos >= 0:
    # Return text starting from "Pag 1 di"
    return text[pos..<text.len]
  return text

proc readDelibera*(args: JsonNode): string =
    var path_for_summary="C:/Users/pr30565/Desktop/python/flask_root/principale/pareri/delibere/testi"
    
    # Get number and year parameters
    let numberNode = args{"number"}
    let yearNode = args{"year"}
    
    if numberNode.isNil or yearNode.isNil:
        return $(%*{"error": "Missing number or year parameter"})
    
    # Extract number as string (handle both JSON int and string)
    let numberStr = case numberNode.kind
      of JInt: $(numberNode.getInt())
      of JString: numberNode.getStr()
      else: ""
    
    # Extract year as string (handle both JSON int and string)
    let yearStr = case yearNode.kind
      of JInt: $(yearNode.getInt())
      of JString: yearNode.getStr()
      else: ""
    
    if numberStr == "" or yearStr == "":
        return $(%*{"error": "Invalid number or year parameter"})
    
    # Pad number to 4 digits with leading zeros
    var paddedNumber = numberStr
    while paddedNumber.len < 4:
      paddedNumber = "0" & paddedNumber
    
    # Compose filename: delibera_0001_2026.txt
    let filename = "delibera_" & paddedNumber & "_" & yearStr & ".txt"
    
    # Construct full path
    let fullPath = path_for_summary / filename
    
    # Use readTool to read the file
    let readArgs = %*{"file_path": fullPath}
    let resultJson = readTool(readArgs)
    
    # Parse the result
    try:
      let parsed = parseJson(resultJson)
      if parsed.hasKey("error"):
        return resultJson
      
      var content = parsed["content"].getStr()
      
      # Clean the text: remove everything before "Pag 1 di" if present
      content = cleanDeliberaText(content)
      
      # Truncate to max 1KB (1024 bytes)
      const MaxBytes = 2048
      if content.len > MaxBytes:
        content = content[0..<MaxBytes] & "\n[... truncated to 1KB]"
      
      # Return JSON format
      return $(%*{"content": content})
    except Exception as e:
      return $(%*{"error": e.msg})

proc executeTool*(name: string, args: JsonNode): string =
  case name
  of "read": return readTool(args)
  of "bash": return bashTool(args)
  of "readDelibera": return readDelibera(args)
  else: return $(%*{"error": "Unknown tool: " & name})
