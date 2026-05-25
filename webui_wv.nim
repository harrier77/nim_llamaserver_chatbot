# ============================================================
# webui_wv.nim - WebUI + WebView2 entry point (no TUI)
# ============================================================
# A standalone executable that starts the HTTP server and opens
# a native WebView2 window pointing to http://localhost:8000.
#
# Compile:
#   nim c --threads:on --path:"my_include" --path:"webui" --path:"webview2_nim" --define:ssl webui_wv.nim
# ============================================================

import os, strutils, asyncdispatch
import config_web
import webui/httpdserver
import miowv           # from webview2_nim (added via --path)

# ============================================================
# Entry point
# ============================================================

proc main() =
  # --- Resolve ExeDir for PATH-independent resource lookup ---
  ExeDir = getAppFilename().parentDir()
  SessionDir = ExeDir

  # --- Start WebUI server in a separate thread ---
  startServer(Port(8000))

  # --- Welcome ---
  echo ""
  echo repeat("=", 55)
  echo "  Nim LlamaServer Chatbot - WebView2 Mode"
  echo repeat("=", 55)
  echo ""
  echo "  Server:  http://localhost:8000"
  echo "  API:     http://localhost:8000/v1/chat/completions"
  echo "  WebView2 window opening..."
  echo ""
  echo "  Close the window or press Ctrl+C to stop"
  echo repeat("=", 55)
  echo ""

  # --- Create WebView2 window ---
  var w = mio_new_webview(
    path = "http://localhost:8000",
    title = "Nim LlamaServer Chatbot",
    width = 1200,
    height = 800,
    resizable = true,
    debug = defined(release),  # true unless -d:release
    miotop = 0                # 0 = disable native WebView2 toolbar (Back/Forward/Refresh)
  )

  if w == nil:
    echo "[ERROR] Failed to create WebView2 window"
    quit(1)

  # --- Enter Windows message loop (blocks until window closes) ---
  w.run()

  # --- Cleanup after window closes ---
  stopServer()
  echo ""
  echo "Server stopped. Goodbye."

main()
