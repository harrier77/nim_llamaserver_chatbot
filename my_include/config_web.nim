# ============================================================
# config_web.nim - Minimal config for webui-only builds
# ============================================================
# Provides only the symbols that httpdserver.nim actually needs
# from config.nim, WITHOUT pulling in editor.nim / illwill.
# ============================================================

import os, strutils

var ExeDir*: string = ""
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
