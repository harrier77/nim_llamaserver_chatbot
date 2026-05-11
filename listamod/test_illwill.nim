import illwill, os, strutils, json

type
  AppState = enum
    Input, ModelList

  Model = object
    name: string

var
  state = Input
  inputBuf = ""
  modelBuf = ""
  selectedModel = -1
  exitApp = false
  Models: seq[Model]

let jsonStr = readFile(expandTilde("~/.nim_chatbot/models.json"))
let jsonRoot = parseJson(jsonStr)
for provName, provVal in jsonRoot["providers"]:
  for m in provVal["models"]:
    Models.add(Model(name: provName & ":" & m.getStr()))

proc exitProc() {.noconv.} =
  illwillDeinit()
  showCursor()
  quit(0)

setControlCHook(exitProc)
illwillInit(fullScreen=false)

var tw = terminalWidth()
var th = terminalHeight()
if tw < 80: tw = 80
if th < 24: th = 24

var tb = newTerminalBuffer(tw, th)

while not exitApp:
  tb.clear()
  let h = tb.height
  var y = 0

  tb.setForegroundColor(fgYellow, bright=true)
  tb.write(0, y, "Illwill Test - Type /model to select a model")
  y += 2

  tb.setForegroundColor(fgWhite)
  tb.write(0, y, "> " & inputBuf)
  inc(y)

  if state == ModelList:
    y += 1
    tb.setForegroundColor(fgCyan, bright=true)
    tb.write(0, y, "Select a model (1-" & $Models.len & ") or ESC to cancel:")
    inc(y)
    for i, m in Models:
      tb.setForegroundColor(fgWhite)
      tb.write(0, y, $(i + 1) & ": " & m.name)
      inc(y)
    y += 1
    tb.setForegroundColor(fgYellow)
    tb.write(0, y, "Number: " & modelBuf)

  if selectedModel >= 0:
    y += 1
    tb.setForegroundColor(fgGreen, bright=true)
    tb.write(0, y, "Selected: " & Models[selectedModel].name)

  tb.setForegroundColor(fgGreen)
  tb.write(0, h-1, "Press Ctrl+C to exit")

  tb.display()

  let key = getKey()
  if key == Key.None:
    sleep(30)
    continue

  case state
  of Input:
    case key
    of Key.Enter:
      let cmd = strutils.strip(inputBuf)
      if cmd == "/model":
        state = ModelList
      inputBuf = ""
    of Key.Backspace:
      if inputBuf.len > 0:
        inputBuf.setLen(inputBuf.len - 1)
    of Key.Escape:
      tb.setForegroundColor(fgWhite)
      exitApp = true
    else:
      let val = ord(key)
      if val >= 32 and val <= 126:
        inputBuf &= chr(val)
  of ModelList:
    case key
    of Key.Zero, Key.One, Key.Two, Key.Three, Key.Four, Key.Five, Key.Six,
       Key.Seven, Key.Eight, Key.Nine:
      modelBuf &= chr(ord(key))
    of Key.Enter:
      if modelBuf.len > 0:
        let idx = parseInt(modelBuf) - 1
        if idx >= 0 and idx < Models.len:
          selectedModel = idx
          state = Input
        modelBuf = ""
    of Key.Backspace:
      if modelBuf.len > 0:
        modelBuf.setLen(modelBuf.len - 1)
    of Key.Escape:
      modelBuf = ""
      state = Input
    else:
      discard

illwillDeinit()
showCursor()
