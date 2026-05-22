# ============================================================
# webui_only.nim - WebUI-only entry point (no TUI)
# ============================================================
# A standalone executable that starts only the HTTP server for
# browser-based interaction, without illwill / TUI dependency.
#
# Compile:
#   nim c --threads:on --path:"my_include" --path:"webui" --define:ssl webui_only.nim
# ============================================================

import os, asyncdispatch, strutils
import config_web
import webui/httpdserver

# ============================================================
# Exit handler
# ============================================================

proc exitProc() {.noconv.} =
  stdout.write("\e[0m")
  stdout.flushFile()
  quit(0)

# ============================================================
# Entry point
# ============================================================

proc main() =
  setControlCHook(exitProc)

  # --- Resolve ExeDir for PATH-independent resource lookup ---
  ExeDir = getAppFilename().parentDir()
  SessionDir = ExeDir

  # --- Start WebUI server ---
  startServer(Port(8000))

  # --- Welcome ---
  echo ""
  echo repeat("=", 55)
  echo "  Nim LlamaServer Chatbot - WebUI Only Mode"
  echo repeat("=", 55)
  echo ""
  echo "  WebUI: http://localhost:8000"
  echo "  API:   http://localhost:8000/v1/chat/completions"
  echo ""
  echo "  Press Ctrl+C to stop"
  echo repeat("=", 55)
  echo ""

  # --- Main loop (async poll only) ---
  while true:
    try:
      poll()
    except:
      discard
    when defined(windows):
      proc kbhit(): cint {.importc: "_kbhit", dynlib: "msvcrt".}
      proc getch(): cint {.importc: "_getch", dynlib: "msvcrt".}
      if kbhit() != 0 and getch() == 27:
        exitProc()
    sleep(100)

main()
