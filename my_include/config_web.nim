# ============================================================
# config_web.nim - Minimal config for webui-only builds
# ============================================================
# Provides only the symbols that httpdserver.nim actually needs
# from config.nim, WITHOUT pulling in editor.nim / illwill.
# ============================================================

import os, strutils, times,  json
when not defined(windows):
  import osproc

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

proc setExeDir*(dir: string) =
  ExeDir = dir
  SessionDir = dir

# ============================================================
# Firecrawl API key — loaded from ~/.nim_chatbot/auth.json
# ============================================================

var FirecrawlApiKey*: string = ""

proc loadFirecrawlApiKey*() =
  ## Reads auth.json and extracts the "firecrawler" -> "key" entry.
  ## Called once at app startup (from main.nim).
  let authPath = getHomeDir() / ".nim_chatbot" / "auth.json"
  writeLog(ExeDir, "[FIRECRAWL] authPath: " & authPath)
  if not fileExists(authPath):
    writeLog(ExeDir, "[FIRECRAWL] auth.json not found")
    return
  try:
    let content = readFile(authPath)
    writeLog(ExeDir, "[FIRECRAWL] file read OK, len=" & $content.len)
    let j = parseJson(content)
    var ks: seq[string] = @[]; for k in j.keys: ks.add(k)
    writeLog(ExeDir, "[FIRECRAWL] JSON parsed OK, keys: " & $ks)
    if j.hasKey("firecrawler"):
      writeLog(ExeDir, "[FIRECRAWL] 'firecrawler' key FOUND")
      if j["firecrawler"].hasKey("key"):
        FirecrawlApiKey = j["firecrawler"]["key"].getStr("")
        writeLog(ExeDir, "[FIRECRAWL] key loaded, len=" & $FirecrawlApiKey.len)
      else:
        writeLog(ExeDir, "[FIRECRAWL] 'firecrawler' has no 'key' subkey")
    else:
      writeLog(ExeDir, "[FIRECRAWL] 'firecrawler' NOT FOUND in JSON")
  except Exception as e:
    writeLog(ExeDir, "[FIRECRAWL] EXCEPTION: " & e.msg)

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
    discard execProcess("xdg-open", args = [target])
