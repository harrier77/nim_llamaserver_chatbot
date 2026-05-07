##
## WebUI HTTP Server Module
## Serves static files from the "static" directory
## Runs in a separate thread to avoid blocking the TUI
##

import std/[asynchttpserver, asyncdispatch, os, strutils, httpcore, json, osproc]

# Thread synchronization
var serverRunning*: bool = false
var serverThread*: Thread[void]
var serverPort*: Port

# Tool schema (embedded as JSON string to avoid GC-managed globals in async context)
const ToolsSchemaJson = """[
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
      "description": "Execute a bash command on the system. Use this for running shell commands.",
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
]"""

const MaxReadLines = 1000

proc requestCallback(req: Request) {.async, gcsafe.} =
  ## Callback for handling HTTP requests
  var path = req.url.path
  ##echo "[WebUI] Request: ", path

  if path == "/api/tools":
    # Return tools schema as JSON
    let headers = newHttpHeaders([("Content-Type", "application/json")])
    await req.respond(Http200, ToolsSchemaJson, headers)
    return

  if path == "/api/read":
    # Execute read tool
    let bodyStr = req.body
    let args = parseJson(bodyStr)
    let filePath = if args.hasKey("file_path"): args["file_path"].getStr() else: ""
    let offset = if args.hasKey("offset"): args["offset"].getInt() else: 1
    let limit = if args.hasKey("limit"): args["limit"].getInt() else: -1
    let headers = newHttpHeaders([("Content-Type", "application/json")])

    if filePath == "":
      await req.respond(Http200, ${"error": "Missing file_path parameter"}, headers)
      return

    var resolvedPath = filePath.replace("\\", "/")
    if not resolvedPath.startsWith("/") and not (resolvedPath.len >= 2 and resolvedPath[1] == ':'):
      resolvedPath = getCurrentDir() / resolvedPath

    if not fileExists(resolvedPath):
      await req.respond(Http200, ${"error": "File not found: " & resolvedPath}, headers)
      return

    try:
      let lines = readFile(resolvedPath).splitLines()
      let startIdx = max(0, offset - 1)
      let effectiveLimit = if limit == -1: MaxReadLines else: min(limit, MaxReadLines)
      let endIdx = min(lines.len - 1, startIdx + effectiveLimit - 1)
      let slice = lines[startIdx .. endIdx]
      var content = slice.join("\n")
      if endIdx + 1 < lines.len:
        content &= "\n[... truncated at " & $MaxReadLines & " lines]"
      await req.respond(Http200, ${"content": content}, headers)
    except Exception as e:
      await req.respond(Http200, ${"error": e.msg}, headers)
    return

  if path == "/api/bash":
    # Execute bash tool
    let bodyStr = req.body
    let args = parseJson(bodyStr)
    let command = if args.hasKey("command"): args["command"].getStr() else: ""
    let headers = newHttpHeaders([("Content-Type", "application/json")])

    if command == "":
      await req.respond(Http200, ${"error": "Missing command parameter"}, headers)
      return

    try:
      var res = ""
      var exitCode = 0
      when defined(windows):
        const gitBashPath = "C:\\Program Files\\git\\bin\\bash.exe"
        var cwd = getCurrentDir().replace("\\", "/")
        let fullCommand = "cd '" & cwd & "' && " & command
        (res, exitCode) = execCmdEx(quoteShell(gitBashPath) & " -c " & quoteShell(fullCommand))
      else:
        (res, exitCode) = execCmdEx(command)
      await req.respond(Http200, ${"content": res.strip(), "exit_code": $exitCode}, headers)
    except Exception as e:
      await req.respond(Http200, ${"error": e.msg}, headers)
    return

  if path == "/":
    path = "/index.html"

  # Use executable's directory to find static files (works from any directory)
  let staticDir = getAppDir() / "webui" / "static"
  let filePath = staticDir / path

  if fileExists(filePath):
    let content = readFile(filePath)
    let contentType = if path.endsWith(".html"): "text/html"
                      elif path.endsWith(".css"): "text/css"
                      elif path.endsWith(".js"): "application/javascript"
                      else: "text/plain"
    let headers = newHttpHeaders([("Content-Type", contentType)])
    await req.respond(Http200, content, headers)
  else:
    await req.respond(Http404, "Not Found")

proc serverWorker() {.thread, gcsafe.} =
  ## Worker proc that runs in a separate thread with its own event loop
  ##echo "[WebUI] Server thread started"
  
  # Create the server
  let server = newAsyncHttpServer()
  ##echo "[WebUI] Server starting on http://localhost:" & $serverPort.uint16
  
  # Run the server (this blocks until stopped)
  waitFor server.serve(serverPort, requestCallback)
  
  ##echo "[WebUI] Server thread exiting"

proc startServer*(port: Port = Port(8000)) =
  ## Start the web server on the specified port in a separate thread
  ## Default port is 8000
  if serverRunning:
    ##echo "[WebUI] Server already running"
    return
    
  serverPort = port
  serverRunning = true
  
  # Start the server in a new thread
  createThread(serverThread, serverWorker)
  ##echo "[WebUI] Server started in background thread"

proc stopServer*() =
  ## Stop the web server
  if not serverRunning:
    ##echo "[WebUI] Server not running"
    return
    
  serverRunning = false
  ##echo "[WebUI] Stopping server..."
  # Note: The thread will exit when the server is closed
  # In a more complete implementation, we'd join the thread