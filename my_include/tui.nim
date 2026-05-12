# ============================================================
# tui.nim — Minimal TUI framework with differential rendering
# ============================================================
# Inspired by pi-coding-agent's tui.ts
#   https://github.com/earendil-works/pi
#
# Architecture:
# - Components return seq[string] via render()
# - Tui compares new lines with previous lines (string equality)
# - Only changed ranges are written to stdout via ANSI escapes
# - CURSOR_MARKER is extracted for hardware cursor positioning
#
# Dependencies: os, strutils
# ============================================================

import os, strutils, unicode, math

# ============================================================
# Constants
# ============================================================

const CURSOR_MARKER* = "\x1b_pi:c\x07"
  ## Zero-width marker emitted by components at cursor position.
  ## TUI strips this and positions the hardware cursor there.

# ============================================================
# TUI state (differential rendering context)
# ============================================================

type Tui* = ref object
  previousLines*: seq[string]
  previousWidth*: int
  previousHeight*: int
  previousKittyImageIds*: seq[int]  # reserved for future use
  cursorRow*: int          # logical cursor row (end of content)
  hardwareCursorRow*: int  # actual terminal cursor row
  maxLinesRendered*: int   # high-water mark of rendered lines
  fullRedraws*: int
  clearOnShrink*: bool

proc initTui*(): Tui =
  ## Creates a new TUI state with empty previous state.
  result = Tui()
  result.previousLines = @[]
  result.previousWidth = -1
  result.previousHeight = -1
  result.previousKittyImageIds = @[]
  result.cursorRow = 0
  result.hardwareCursorRow = 0
  result.maxLinesRendered = 0
  result.fullRedraws = 0
  result.clearOnShrink = false

# ============================================================
# Utility: visible width of a string (strips ANSI escapes)
# ============================================================

proc isWideRune(cp: int): bool =
  ## Returns true for East Asian wide chars and emoji (terminal width = 2).
  cp >= 0x1100 and cp <= 0x115F or
  cp >= 0x2E80 and cp <= 0x303E or
  cp >= 0x3040 and cp <= 0x9FFF or
  cp >= 0xAC00 and cp <= 0xD7AF or
  cp >= 0xF900 and cp <= 0xFAFF or
  cp >= 0xFE10 and cp <= 0xFE19 or
  cp >= 0xFE30 and cp <= 0xFE6F or
  cp >= 0xFF01 and cp <= 0xFF60 or
  cp >= 0xFFE0 and cp <= 0xFFE6 or
  cp >= 0x1B000 and cp <= 0x1B12F or
  cp >= 0x1F100 and cp <= 0x1F2FF or
  cp >= 0x1F300 and cp <= 0x1F9FF or
  cp >= 0x20000 and cp <= 0x2FFFF

proc visibleWidth*(s: string): int =
  ## Returns the visible width of a string, ignoring ANSI escapes.
  ## Emoji and CJK characters count as 2 columns.
  result = 0
  var i = 0
  while i < s.len:
    if s[i] == '\x1b':
      if i + 1 < s.len and s[i+1] == '[':
        i += 2
        while i < s.len and s[i] != 'm':
          i += 1
        if i < s.len: i += 1
        continue
      else:
        i += 1
        while i < s.len and s[i] != '\x07':
          i += 1
        if i < s.len: i += 1
        continue
    elif s[i] == '\r' or s[i] == '\n':
      i += 1
      continue
    else:
      let r = toRunes($s[i])
      if r.len > 0 and r[0].int > 0x1F:
        result += 1
        if isWideRune(r[0].int):
          result += 1
      i += 1

# ============================================================
# ANSI helpers
# ============================================================

proc ansiSet*(code: int): string =
  ## Returns ANSI SGR sequence: ESC [ code m
  "\x1b[" & $code & "m"

proc cursorUp*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "A"

proc cursorDown*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "B"

proc cursorCol*(n: int): string =
  ## Move to absolute column (1-indexed)
  "\x1b[" & $(n + 1) & "G"

proc clearLine*: string =
  "\x1b[2K"

proc syncBegin*: string =
  "\x1b[?2026h"

proc syncEnd*: string =
  "\x1b[?2026l"

proc clearScreen*: string =
  "\x1b[2J\x1b[H\x1b[3J"

proc showCursor*: string =
  "\x1b[?25h"

proc hideCursor*: string =
  "\x1b[?25l"

# ============================================================
# Differential rendering
# ============================================================

proc findChangedRange*(newLines, oldLines: seq[string]): (int, int) =
  ## Finds the first and last index where newLines differ from oldLines.
  ## Returns (-1, -1) if no changes.
  result = (-1, -1)

  let maxLen = max(newLines.len, oldLines.len)

  for i in 0 ..< maxLen:
    let oldLine = if i < oldLines.len: oldLines[i] else: ""
    let newLine = if i < newLines.len: newLines[i] else: ""

    if oldLine != newLine:
      if result[0] == -1:
        result[0] = i
      result[1] = i

  # Appended lines
  if newLines.len > oldLines.len:
    if result[0] == -1:
      result[0] = oldLines.len
    result[1] = newLines.len - 1

proc extractCursorPosition*(lines: var seq[string]): (int, int) =
  ## Finds CURSOR_MARKER in the rendered lines, computes its visual
  ## position, strips the marker, and returns (row, col) or (-1, -1).
  ## Only scans the visible viewport (bottom 'height' lines).
  for row in countdown(lines.len - 1, 0):
    let idx = lines[row].find(CURSOR_MARKER)
    if idx >= 0:
      # Compute visual column (width of text before marker)
      let before = lines[row][0 ..< idx]
      let col = visibleWidth(before)
      # Strip marker
      lines[row] = lines[row][0 ..< idx] & lines[row][idx + CURSOR_MARKER.len .. ^1]
      return (row, col)
  result = (-1, -1)

proc removeAnsiReset*(lines: var seq[string]) =
  ## Appends ANSI reset at the end of each non-image line.
  ## Equivalent to TS applyLineResets().
  const RESET = "\x1b[0m\x1b]8;;\x07"
  for i in 0 ..< lines.len:
    lines[i] = lines[i] & RESET

# ============================================================
# Main render loop (like TS Tui.doRender)
# ============================================================

proc write*(buf: string) =
  ## Write raw string to stdout (terminal).
  stdout.write(buf)
  flushFile(stdout)

proc differentialRender*(tui: var Tui, newLines: seq[string],
                         termWidth, termHeight: int) =
  ## Compares newLines with previousLines and outputs only the
  ## changed lines to stdout, using ANSI escape sequences.
  ## Like TS Tui.doRender().
  if newLines.len == 0: return

  let widthChanged = tui.previousWidth >= 0 and tui.previousWidth != termWidth
  let heightChanged = tui.previousHeight >= 0 and tui.previousHeight != termHeight

  # Shrink check
  if tui.clearOnShrink and newLines.len < tui.maxLinesRendered:
    tui.fullRedraws += 1
    var buf = syncBegin()
    buf &= clearScreen()
    for i, line in newLines:
      if i > 0: buf &= "\r\n"
      buf &= line
    buf &= syncEnd()
    write(buf)
    tui.previousLines = newLines
    tui.previousWidth = termWidth
    tui.previousHeight = termHeight
    tui.maxLinesRendered = newLines.len
    tui.cursorRow = newLines.len - 1
    tui.hardwareCursorRow = tui.cursorRow
    return

  # Full render on first call or width/height change (like TS)
  if tui.previousLines.len == 0 or widthChanged or heightChanged:
    tui.fullRedraws += 1
    var buf = syncBegin()
    if widthChanged or heightChanged:
      buf &= clearScreen()
    for i, line in newLines:
      if i > 0: buf &= "\r\n"
      buf &= line
    buf &= syncEnd()
    write(buf)
    tui.previousLines = newLines
    tui.previousWidth = termWidth
    tui.previousHeight = termHeight
    tui.maxLinesRendered = max(tui.maxLinesRendered, newLines.len)
    tui.cursorRow = max(0, newLines.len - 1)
    tui.hardwareCursorRow = tui.cursorRow
    return

  # --- Find changed range ---
  let (firstChanged, lastChanged) = findChangedRange(newLines, tui.previousLines)

  # No changes → just update hardware cursor if needed
  if firstChanged == -1:
    return

  let appended = newLines.len > tui.previousLines.len

  # All changes are deletions (nothing to render, just clear)
  if firstChanged >= newLines.len:
    if tui.previousLines.len > newLines.len:
      let targetRow = max(0, newLines.len - 1)
      var buf = syncBegin()
      # Move to target row
      let lineDiff = targetRow - tui.hardwareCursorRow
      if lineDiff > 0: buf &= cursorDown(lineDiff)
      elif lineDiff < 0: buf &= cursorUp(-lineDiff)
      buf &= "\r"
      # Clear extra lines
      let extraLines = tui.previousLines.len - newLines.len
      if extraLines > 0:
        buf &= cursorDown(1)
      for i in 0 ..< extraLines:
        buf &= "\r" & clearLine()
        if i < extraLines - 1: buf &= cursorDown(1)
      if extraLines > 0:
        buf &= cursorUp(extraLines)
      buf &= syncEnd()
      write(buf)
      tui.cursorRow = targetRow
      tui.hardwareCursorRow = targetRow
    tui.previousLines = newLines
    tui.previousWidth = termWidth
    tui.previousHeight = termHeight
    return

  # --- Differential update: render only changed lines ---
  var buf = syncBegin()

  let moveTargetRow = firstChanged
  let lineDiff = moveTargetRow - tui.hardwareCursorRow
  if lineDiff > 0: buf &= cursorDown(lineDiff)
  elif lineDiff < 0: buf &= cursorUp(-lineDiff)

  # Render from firstChanged to lastChanged
  let renderEnd = min(lastChanged, newLines.len - 1)
  for i in firstChanged .. renderEnd:
    if i > firstChanged: buf &= "\r\n"
    buf &= clearLine()
    let line = newLines[i]
    buf &= line

  # Track final cursor row
  let finalCursorRow = renderEnd

  # If previous was longer, clear extra lines
  if tui.previousLines.len > newLines.len:
    if renderEnd < newLines.len - 1:
      buf &= cursorDown(newLines.len - 1 - renderEnd)
    let extraLines = tui.previousLines.len - newLines.len
    for i in 0 ..< extraLines:
      buf &= "\r\n" & clearLine()
    buf &= cursorUp(extraLines)

  buf &= syncEnd()
  write(buf)

  # Update state
  tui.cursorRow = max(0, newLines.len - 1)
  tui.hardwareCursorRow = finalCursorRow
  tui.maxLinesRendered = max(tui.maxLinesRendered, newLines.len)
  tui.previousLines = newLines
  tui.previousWidth = termWidth
  tui.previousHeight = termHeight

# ============================================================
# Component interface (concept)
# ============================================================

type Component* = ref object of RootObj
  ## Base type for TUI components.
  ## Subtypes must implement `render(width, height): seq[string]`.

method render*(c: Component, width, height: int): seq[string] {.base.} =
  ## Render component to ANSI-formatted lines.
  ## Override in subclasses.
  discard
