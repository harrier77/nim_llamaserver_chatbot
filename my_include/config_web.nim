# ============================================================
# config_web.nim - Minimal config for webui-only builds
# ============================================================
# Provides only the symbols that httpdserver.nim actually needs
# from config.nim, WITHOUT pulling in editor.nim / illwill.
# ============================================================

import os, strutils, times, osproc

var ExeDir*: string = ""

proc writeLog*(exeDir: string, msg: string) {.gcsafe.} =
  ## Writes a timestamped message to nimlog.txt with automatic rotation.
  ## If nimlog.txt exceeds 1 MB, it is renamed to nimlog.bak (overwriting
  ## any existing backup) so the new log starts fresh.
  let logDir = if exeDir.len > 0: exeDir else: getCurrentDir()
  let logPath = logDir / "nimlog.txt"
  let bakPath = logDir / "nimlog.bak"
  let timestamp = now().format("HH:mm:ss")
  try:
    if fileExists(logPath) and getFileSize(logPath) > 10_000:
      # Rotate: rename current log -> .bak (overwrites old .bak)
      removeFile(bakPath)
      moveFile(logPath, bakPath)
    var f = open(logPath, fmAppend)
    f.writeLine(timestamp & " " & msg)
    f.close()
  except:
    discard
var SessionDir*: string = ""

when defined(windows):
  proc ShellExecuteA(hwnd: int, operation: cstring, file: cstring,
                     parameters: cstring, directory: cstring, showCmd: int): int
                     {.stdcall, dynlib: "shell32.dll", importc.}

proc launchDetached*(target: string) =
  ## Opens a file/URL/batch script in a separate process independent
  ## of the calling terminal.
  when defined(windows):
    if target.endsWith(".bat") or target.endsWith(".cmd"):
      let dir = target.parentDir()
      discard ShellExecuteA(0, "open", target, nil, cstring(dir), 1)
    else:
      discard ShellExecuteA(0, "open", target, nil, nil, 1)
  else:
    discard execCmd("xdg-open " & target)
