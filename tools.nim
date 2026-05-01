import json, os, osproc, strutils

# FIX: Matches parameter names from demo.ts (e.g., file_path instead of path)
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
  }
]

proc readTool(args: JsonNode): string =
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
    let endIdx = if limit == -1: lines.len - 1 else: min(lines.len - 1, startIdx + limit - 1)
    
    let slice = lines[startIdx .. endIdx]
    # Return JSON format
    return $(%*{"content": slice.join("\n")})
  except Exception as e:
    return $(%*{"error": e.msg})

proc bashTool(args: JsonNode): string =
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

proc executeTool*(name: string, args: JsonNode): string =
  # Log tool call for debugging and visibility
  try:
    let logFile = "debug_tools.txt"
    let logMsg = "\n--- Tool Call: " & name & " ---\n" & "Args: " & $args & "\n"
    let f = open(logFile, fmAppend)
    f.write(logMsg)
    f.close()
  except: discard

  case name
  of "read": return readTool(args)
  of "bash": return bashTool(args)
  else: return $(%*{"error": "Unknown tool: " & name})
