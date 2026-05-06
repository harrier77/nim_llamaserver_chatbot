##
## WebUI HTTP Server Module
## Serves static files from the "static" directory
## Runs in a separate thread to avoid blocking the TUI
##

import std/[asynchttpserver, asyncnet, asyncdispatch, os, strutils, httpcore, threadpool, locks]

# Thread synchronization
var serverRunning*: bool = false
var serverThread*: Thread[void]
var serverPort*: Port

proc requestCallback(req: Request) {.async.} =
  ## Callback for handling HTTP requests
  var path = req.url.path
  echo "[WebUI] Request: ", path

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

proc serverWorker() {.thread.} =
  ## Worker proc that runs in a separate thread with its own event loop
  echo "[WebUI] Server thread started"
  
  # Create a new dispatcher for this thread
  var dispatcher = newDispatcher()
  
  # Create the server
  let server = newAsyncHttpServer()
  echo "[WebUI] Server starting on http://localhost:" & $serverPort.uint16
  
  # Run the server (this blocks until stopped)
  waitFor server.serve(serverPort, requestCallback)
  
  echo "[WebUI] Server thread exiting"

proc startServer*(port: Port = Port(8000)) =
  ## Start the web server on the specified port in a separate thread
  ## Default port is 8000
  if serverRunning:
    echo "[WebUI] Server already running"
    return
    
  serverPort = port
  serverRunning = true
  
  # Start the server in a new thread
  createThread(serverThread, serverWorker)
  echo "[WebUI] Server started in background thread"

proc stopServer*() =
  ## Stop the web server
  if not serverRunning:
    echo "[WebUI] Server not running"
    return
    
  serverRunning = false
  echo "[WebUI] Stopping server..."
  # Note: The thread will exit when the server is closed
  # In a more complete implementation, we'd join the thread