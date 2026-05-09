# ============================================================
# editor.nim - Text editor component (pi TUI-inspired)
# ============================================================
# Responsibilities:
# - Editor state management (lines, cursor, scroll)
# - Text manipulation (insert, delete, newline)
# - Arrow key navigation with word-wrap awareness
# - Rendering to an illwill TerminalBuffer
#
# Inspired by pi-coding-agent's editor-component.ts / editor.ts
#   https://github.com/earendil-works/pi
#
# Dependencies: illwill, strutils, unicode
# ============================================================

import illwill, strutils, unicode, strformat

# ============================================================
# Editor state
# ============================================================

type
  Editor* = ref object
    ## Core text editor state.
    ##
    ## lines:     The logical lines of text.
    ## cursorLine: Index into `lines` (0-based).
    ## cursorCol:  Byte offset in the logical line (0-based).
    ## preferredCol: Sticky column for vertical navigation
    ##               (nil = no sticky column).
    ## scrollOffset: How many visual lines are scrolled off the top.
    lines*: seq[string]
    cursorLine*: int
    cursorCol*: int
    preferredCol*: int

# ============================================================
# Initialisation
# ============================================================

proc initEditor*(): Editor =
  ## Creates a new editor with a single empty line.
  result = Editor()
  result.lines = @[""]
  result.cursorLine = 0
  result.cursorCol = 0
  result.preferredCol = -1  # -1 = not set

# ============================================================
# Line management
# ============================================================

proc currentLine*(ed: Editor): string =
  ## Returns the line at the cursor position.
  if ed.cursorLine < ed.lines.len:
    ed.lines[ed.cursorLine]
  else:
    ""

# ============================================================
# Text insertion
# ============================================================

proc insertChar*(ed: Editor, ch: string) =
  ## Inserts a single character (or string) at the cursor position.
  let line = ed.currentLine()
  if ed.cursorLine >= ed.lines.len: return

  let before = line[0 ..< ed.cursorCol]
  let after = line[ed.cursorCol .. ^1]
  ed.lines[ed.cursorLine] = before & ch & after
  ed.cursorCol += ch.len
  ed.preferredCol = -1  # Reset sticky column

# ============================================================
# Backspace
# ============================================================

proc handleBackspace*(ed: Editor) =
  ## Deletes the character before the cursor.
  ## If at the start of a line, merges with the previous line.
  if ed.cursorCol > 0:
    # Delete grapheme before cursor (simple byte-based)
    let line = ed.currentLine()
    let before = line[0 ..< ed.cursorCol]
    # Find last grapheme boundary (use Rune for Unicode awareness)
    let runesBefore = toRunes(before)
    let lastRuneLen = if runesBefore.len > 0:
      $runesBefore[^1]
    else:
      ""
    if lastRuneLen.len > 0:
      let deleteLen = lastRuneLen.len
      ed.lines[ed.cursorLine] = line[0 ..< ed.cursorCol - deleteLen] &
                                 line[ed.cursorCol .. ^1]
      ed.cursorCol -= deleteLen
  elif ed.cursorLine > 0:
    # Merge with previous line
    let current = ed.currentLine()
    let prev = ed.lines[ed.cursorLine - 1]
    ed.lines[ed.cursorLine - 1] = prev & current
    ed.lines.delete(ed.cursorLine)
    ed.cursorLine -= 1
    ed.cursorCol = prev.len
  ed.preferredCol = -1

# ============================================================
# Delete forward
# ============================================================

proc handleDelete*(ed: Editor) =
  ## Deletes the character at the cursor position.
  let line = ed.currentLine()
  if ed.cursorCol < line.len:
    # Delete grapheme at cursor
    let after = line[ed.cursorCol .. ^1]
    let runesAfter = toRunes(after)
    let firstRuneLen = if runesAfter.len > 0:
      $runesAfter[0]
    else:
      ""
    if firstRuneLen.len > 0:
      ed.lines[ed.cursorLine] = line[0 ..< ed.cursorCol] &
                                 after[firstRuneLen.len .. ^1]
  elif ed.cursorLine < ed.lines.len - 1:
    # Merge with next line
    let next = ed.lines[ed.cursorLine + 1]
    ed.lines[ed.cursorLine] = line & next
    ed.lines.delete(ed.cursorLine + 1)
  ed.preferredCol = -1

# ============================================================
# New line (Enter)
# ============================================================

proc addNewLine*(ed: Editor) =
  ## Splits the current line at the cursor position.
  let line = ed.currentLine()
  let before = line[0 ..< ed.cursorCol]
  let after = line[ed.cursorCol .. ^1]
  ed.lines[ed.cursorLine] = before
  ed.lines.insert(after, ed.cursorLine + 1)
  ed.cursorLine += 1
  ed.cursorCol = 0
  ed.preferredCol = -1

# ============================================================
# Word-wrapping utilities
# ============================================================

type
  TextChunk* = object
    ## A chunk of a logical line after word-wrapping.
    text*: string        # The visible text of this chunk
    startIndex*: int     # Byte offset in original logical line
    endIndex*: int       # Byte offset past the end

proc wrapLine*(line: string, width: int): seq[TextChunk] =
  ## Word-wraps a single logical line into visual chunks.
  ## Uses rune-aware iteration for Unicode support.
  if line.len == 0 or width <= 0:
    return @[TextChunk(text: "", startIndex: 0, endIndex: 0)]

  let runes = toRunes(line)
  if runes.len <= width:
    return @[TextChunk(text: line, startIndex: 0, endIndex: line.len)]

  # Helper: compute byte offset in original string from rune index
  proc byteOffset(runes: seq[Rune], runeIdx: int): int =
    if runeIdx <= 0: return 0
    if runeIdx >= runes.len: return line.len
    # Convert runes up to runeIdx back to string and get byte length
    var s = ""
    for j in 0 ..< runeIdx:
      s.add($runes[j])
    s.len

  result = @[]
  var i = 0
  while i < runes.len:
    let remaining = runes.len - i
    if remaining <= width:
      result.add(TextChunk(
        text: $runes[i .. ^1],
        startIndex: byteOffset(runes, i),
        endIndex: line.len
      ))
      break

    # Find last space within width for word wrap
    var lastSpace = -1
    for j in 0 ..< width:
      if runes[i + j] == Rune(32):
        lastSpace = j

    if lastSpace != -1:
      let chunkText = $runes[i ..< i + lastSpace]
      result.add(TextChunk(
        text: chunkText,
        startIndex: byteOffset(runes, i),
        endIndex: byteOffset(runes, i + lastSpace)
      ))
      i += lastSpace + 1  # Skip the space
    else:
      # Hard wrap
      let chunkText = $runes[i ..< i + width]
      result.add(TextChunk(
        text: chunkText,
        startIndex: byteOffset(runes, i),
        endIndex: byteOffset(runes, i + width)
      ))
      i += width

# ============================================================
# Visual line map (pi TUI-inspired)
# ============================================================

type
  VisualLine* = object
    ## Maps a visual (display) line to a logical line.
    logicalLine*: int    # Index into Editor.lines
    startCol*: int       # Byte offset start in logical line
    length*: int         # Byte length of this visual segment

proc buildVisualLineMap*(ed: Editor, width: int): seq[VisualLine] =
  ## Builds a map from visual lines to logical lines.
  ## This is the core navigation structure, inspired by
  ## pi's editor.ts → buildVisualLineMap().
  result = @[]
  for li, line in ed.lines:
    let runes = toRunes(line)
    if runes.len == 0:
      result.add(VisualLine(logicalLine: li, startCol: 0, length: 0))
    elif runes.len <= width:
      result.add(VisualLine(logicalLine: li, startCol: 0, length: line.len))
    else:
      let chunks = wrapLine(line, width)
      for chunk in chunks:
        result.add(VisualLine(
          logicalLine: li,
          startCol: chunk.startIndex,
          length: chunk.endIndex - chunk.startIndex
        ))

# ============================================================
# Find visual line at cursor position
# ============================================================

proc findVisualLineAt*(visualLines: seq[VisualLine],
                        line: int, col: int): int =
  ## Returns the visual line index containing the logical position
  ## (line, col). Falls back to the last visual line.
  for i, vl in visualLines:
    if vl.logicalLine != line: continue
    let offset = col - vl.startCol
    let isLast = i == visualLines.len - 1 or
                 visualLines[i + 1].logicalLine != line
    if offset >= 0 and (offset < vl.length or (isLast and offset == vl.length)):
      return i
  result = visualLines.len - 1

proc findCurrentVisualLine*(ed: Editor,
                            visualLines: seq[VisualLine]): int =
  ## Returns the visual line index at the current cursor position.
  findVisualLineAt(visualLines, ed.cursorLine, ed.cursorCol)

# ============================================================
# Vertical cursor movement (pi TUI-inspired sticky column)
# ============================================================

proc moveToVisualLine*(ed: Editor, visualLines: seq[VisualLine],
                        targetVisualLine: int) =
  ## Moves cursor to a target visual line, preserving the
  ## visual column when possible (sticky column behaviour).
  ## Inspired by pi's editor.ts → moveToVisualLine().
  let currentVL = ed.findCurrentVisualLine(visualLines)
  if targetVisualLine < 0 or targetVisualLine >= visualLines.len: return

  let srcVL = visualLines[currentVL]
  let dstVL = visualLines[targetVisualLine]

  # Compute the visual column in the source visual line
  let currentVisualCol = ed.cursorCol - srcVL.startCol

  # Determine max visual col for source and target
  let srcMax = if currentVL == visualLines.len - 1 or
                  visualLines[currentVL + 1].logicalLine != srcVL.logicalLine:
    srcVL.length  # last segment → allow cursor at end
  else:
    max(0, srcVL.length - 1)

  let dstMax = if targetVisualLine == visualLines.len - 1 or
                  visualLines[targetVisualLine + 1].logicalLine != dstVL.logicalLine:
    dstVL.length
  else:
    max(0, dstVL.length - 1)

  # Determine target visual column with sticky column logic
  var targetVisualCol: int
  if ed.preferredCol >= 0:
    # We have a preferred (sticky) column
    targetVisualCol = min(ed.preferredCol, dstMax)
  elif currentVisualCol >= srcMax:
    # Cursor was at end → store as preferred
    ed.preferredCol = currentVisualCol
    targetVisualCol = dstMax
  else:
    targetVisualCol = min(currentVisualCol, dstMax)

  # Apply new position
  ed.cursorLine = dstVL.logicalLine
  ed.cursorCol = dstVL.startCol + targetVisualCol
  # Clamp to line length
  let logicalLine = ed.currentLine()
  if ed.cursorCol > logicalLine.len:
    ed.cursorCol = logicalLine.len

# ============================================================
# Combined cursor movement
# ============================================================

proc moveCursor*(ed: Editor, deltaLine: int, deltaCol: int, width: int) =
  ## Moves the cursor by the given delta.
  ## deltaLine: vertical movement (+1 = down, -1 = up)
  ## deltaCol:  horizontal movement (+1 = right, -1 = left)
  ## width:     terminal content width (for visual line calculation)
  let visualLines = ed.buildVisualLineMap(width)
  let currentVL = ed.findCurrentVisualLine(visualLines)

  if deltaLine != 0:
    let targetVL = currentVL + deltaLine
    if targetVL >= 0 and targetVL < visualLines.len:
      ed.moveToVisualLine(visualLines, targetVL)
    return  # Vertical movement takes priority

  if deltaCol != 0:
    let line = ed.currentLine()

    if deltaCol > 0:
      # Move right by one grapheme
      if ed.cursorCol < line.len:
        let after = line[ed.cursorCol .. ^1]
        let runesAfter = toRunes(after)
        if runesAfter.len > 0:
          ed.cursorCol += ($runesAfter[0]).len
      elif ed.cursorLine < ed.lines.len - 1:
        # Wrap to next line
        ed.cursorLine += 1
        ed.cursorCol = 0
    else:
      # Move left by one grapheme
      if ed.cursorCol > 0:
        let before = line[0 ..< ed.cursorCol]
        let runesBefore = toRunes(before)
        if runesBefore.len > 0:
          ed.cursorCol -= ($runesBefore[^1]).len
      elif ed.cursorLine > 0:
        # Wrap to previous line
        ed.cursorLine -= 1
        ed.cursorCol = ed.lines[ed.cursorLine].len

    ed.preferredCol = -1

# ============================================================
# Navigation shortcuts
# ============================================================

proc moveToLineStart*(ed: Editor) =
  ed.cursorCol = 0
  ed.preferredCol = -1

proc moveToLineEnd*(ed: Editor) =
  ed.cursorCol = ed.currentLine().len
  ed.preferredCol = -1

# ============================================================
# Rendering (to illwill TerminalBuffer)
# ============================================================

proc drawEditor*(ed: Editor, tb: var TerminalBuffer) =
  ## Renders the editor content into the illwill terminal buffer.
  ##
  ## Layout:
  ##   ┌─────────────────────────────────┐  ← top border
  ##   │ line 1                          │
  ##   │ line 2                          │
  ##   │ line 3 with cur│sor             │
  ##   └─────────────────────────────────┘  ← bottom border
  ##   │ status bar                       │
  ##
  ## The cursor is shown as reverse video on the character
  ## at the cursor position, or as a highlighted space if
  ## at the end of the line.

  let w = tb.width
  let h = tb.height
  let contentArea = h - 2  # Reserve 1 for bottom border, 1 for status bar

  # --- Build visual lines ---
  let contentWidth = max(1, w - 2)  # Leave 1 col padding on each side
  let visualLines = ed.buildVisualLineMap(contentWidth)

  if visualLines.len == 0:
    return

  # --- Compute scroll offset to keep cursor visible ---
  var scrollOffset = 0
  let cursorVL = ed.findCurrentVisualLine(visualLines)
  if cursorVL < scrollOffset:
    scrollOffset = cursorVL
  elif cursorVL >= scrollOffset + contentArea:
    scrollOffset = cursorVL - contentArea + 1
  # Clamp
  if scrollOffset > max(0, visualLines.len - contentArea):
    scrollOffset = max(0, visualLines.len - contentArea)

  # --- Draw top border ---
  tb.setForegroundColor(fgCyan)
  tb.write(0, 0, "┌" & repeat("─", w - 2) & "┐")

  # --- Draw content lines ---
  for i in 0 ..< contentArea:
    let y = i + 1
    let vi = scrollOffset + i

    if vi < visualLines.len:
      let vl = visualLines[vi]
      let logicalLine = ed.lines[vl.logicalLine]
      let segment = if vl.length > 0:
        logicalLine[vl.startCol ..< vl.startCol + vl.length]
      else:
        ""

      let hasCursor = vl.logicalLine == ed.cursorLine and
                       ed.cursorCol >= vl.startCol and
                       ed.cursorCol <= vl.startCol + vl.length

      tb.setForegroundColor(fgWhite)

      if hasCursor:
        # Calculate cursor position within this visual line (character-based)
        let segmentBeforeCursor = logicalLine[vl.startCol ..< ed.cursorCol]
        let localCol = toRunes(segmentBeforeCursor).len

        # Full line content: segment padded to contentWidth (character-based padding)
        let segmentLen = toRunes(segment).len
        let fullLine = segment & repeat(" ", max(0, contentWidth - segmentLen))

        tb.write(0, y, "│")
        tb.write(1, y, fullLine)

        # Overlay cursor character in reverse video at the correct position
        if ed.cursorCol < vl.startCol + vl.length:
          # Cursor is on a character
          let after = logicalLine[ed.cursorCol .. ^1]
          let runesAfter = toRunes(after)
          let cursorChar = if runesAfter.len > 0: $runesAfter[0] else: " "
          tb.setStyle({styleReverse})
          tb.write(1 + localCol, y, cursorChar)
          tb.setStyle({})
        else:
          # Cursor at the end of line → highlighted space
          tb.setStyle({styleReverse})
          tb.write(1 + localCol, y, " ")
          tb.setStyle({})

        tb.write(w - 1, y, "│")
      else:
        # Normal line (no cursor)
        let segmentLen = toRunes(segment).len
        let display = segment & repeat(" ", max(0, contentWidth - segmentLen))
        tb.write(0, y, "│")
        tb.write(1, y, display)
        tb.write(w - 1, y, "│")
    else:
      # Empty line
      tb.write(0, y, "│")
      tb.write(1, y, repeat(" ", contentWidth))
      tb.write(w - 1, y, "│")

  # --- Draw bottom border ---
  let bottomY = contentArea + 1
  tb.write(0, bottomY, "└" & repeat("─", w - 2) & "┘")

  # --- Draw status bar ---
  let statusY = contentArea + 2
  if statusY < h:
    tb.setForegroundColor(fgBlack)
    tb.setBackgroundColor(bgWhite)
    let totalLines = ed.lines.len
    let totalVisualLines = visualLines.len
    let col = ed.cursorCol
    let line = ed.cursorLine
    let scrollIndicator = if scrollOffset > 0:
      " ↑" & $scrollOffset
    else:
      ""
    let statusText = " Ln " & $(line+1) & "/" & $totalLines & " Col " & $col & scrollIndicator & " │ Ctrl+Q:quit │ Type to edit, Arrows to move "
    let status = statusText & repeat(" ", max(0, w - statusText.len - 1))
    tb.write(0, statusY, status[0 ..< min(status.len, w)])
    tb.resetAttributes()

# ============================================================
# Get full text
# ============================================================

proc getText*(ed: Editor): string =
  ## Returns the entire editor content as a single string.
  ed.lines.join("\n")

proc setText*(ed: Editor, text: string) =
  ## Sets the editor content from a string.
  ed.lines = text.splitLines()
  if ed.lines.len == 0:
    ed.lines = @[""]
  ed.cursorLine = min(ed.cursorLine, ed.lines.len - 1)
  let lineLen = ed.currentLine().len
  ed.cursorCol = min(ed.cursorCol, lineLen)
  ed.preferredCol = -1
