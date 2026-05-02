# Plan: Slash Command Menu Popup

## Overview
When the user types `/` as the **first character** in the input bar, a popup menu appears below the input bar listing available commands. The menu filters dynamically as the user types and supports navigation with arrow keys.

---

## Changes Required in `main.nim`

### 1. New Data Structures (add near existing types)

```nim
type
  SlashCommand = object
    name: string        # e.g. "/quit", "/model", "/new"
    description: string # e.g. "Exit the application"
```

### 2. New State Variables (add to the global `var` block)

```nim
showingSlashMenu: bool = false    # True when the slash popup is visible
slashMenuIndex: int = 0           # Highlighted item index in the menu
slashMenuHeight: int = 8          # Max rows to display in the popup
```

### 3. Command Registry (constant)

```nim
const SlashCommands: array[3, SlashCommand] = [
  SlashCommand(name: "/quit",   description: "Exit the application (also /q)"),
  SlashCommand(name: "/model",  description: "Change the current model"),
  SlashCommand(name: "/new",    description: "Reset conversation and start new chat"),
]
```

### 4. Helper Proc: Filter Commands

```nim
proc filterCommands(query: string): seq[int] =
  ## Return indices of SlashCommands that match the query (text after "/").
  ## Returns all commands if query is empty.
  result = @[]
  let q = strutils.strip(query).toLowerAscii()
  for i, cmd in SlashCommands:
    if cmd.name[1..^1].startsWith(q) or cmd.name.toLowerAscii().contains(q):
      result.add(i)
```

### 5. Helper Proc: Show/Hide the Menu

```nim
proc updateSlashMenu() =
  ## Open or close the slash menu based on current input.
  if currentInput.startsWith("/") and currentInput.len >= 1:
    showingSlashMenu = true
    slashMenuIndex = 0
    # Reset index if it's out of bounds for the new filtered list
    let filtered = filterCommands(currentInput[1..^1])
    if slashMenuIndex >= filtered.len and filtered.len > 0:
      slashMenuIndex = 0
  else:
    showingSlashMenu = false
```

### 6. Modify `handleInput`

**Add a new case at the TOP of the `handleInput` proc** (before the existing `state == SelectingModel` check):

```nim
# If slash menu is open, handle navigation keys specially
if showingSlashMenu and state == Chatting:
  case key
  of Key.Escape:
    showingSlashMenu = false
    return false
  of Key.Up:
    let filtered = filterCommands(currentInput[1..^1])
    if filtered.len > 0 and slashMenuIndex > 0:
      dec(slashMenuIndex)
    return false
  of Key.Down:
    let filtered = filterCommands(currentInput[1..^1])
    if filtered.len > 0 and slashMenuIndex < filtered.len - 1:
      inc(slashMenuIndex)
    return false
  of Key.Tab:
    # Auto-complete the selected command
    let filtered = filterCommands(currentInput[1..^1])
    if filtered.len > 0:
      currentInput = SlashCommands[filtered[slashMenuIndex]].name
      # Don't close menu after Tab — let user keep navigating
    return false
  of Key.Enter:
    # Select the highlighted command and execute it
    let filtered = filterCommands(currentInput[1..^1])
    if filtered.len > 0:
      currentInput = SlashCommands[filtered[slashMenuIndex]].name
      showingSlashMenu = false
      # Fall through to normal Enter handling (which executes the command)
    else:
      showingSlashMenu = false
      return false
    # IMPORTANT: Let the code continue to the normal Enter handler below
  of Key.Backspace, Key.Delete:
    if currentInput.len > 0:
      currentInput.removeLastRune()
    updateSlashMenu()  # Update menu visibility after backspace
    return false
  else:
    # Any other printable key: keep typing in the input,
    # the menu will update via updateSlashMenu() call below
    updateSlashMenu()
    # Fall through to normal character handling
```

**In the existing Enter handler**, update the slash command check:

```nim
of Key.Enter:
  if currentInput.len > 0:
    let prompt = currentInput

    # If slash menu was open, close it
    if showingSlashMenu:
      showingSlashMenu = false

    # --- existing slash command checks ---
    let cmd = strutils.strip(prompt).toLowerAscii()
    if cmd == "/quit" or cmd == "/q":
      return true
    if cmd == "/model":
      asyncCheck fetchModels()
      state = SelectingModel
      return false
    if cmd == "/new":
      conversationHistory = @[ ... ]
      outputLines = @[]
      ...
      return false
    # ... rest of Enter handler unchanged ...
```

**In the existing `else` branch** (character input), add a call to update the menu:

After the key is processed and added to `currentInput`, call `updateSlashMenu()`.

Specifically, at the END of the `else` block (after all the `currentInput.add(...)` logic):

```nim
else:
  # ... existing code that adds characters to currentInput ...
  
  # Check if we should show the slash menu
  updateSlashMenu()
  return false
```

### 7. Modify Rendering in `main()` Loop

**After the input bar is drawn**, add the slash menu popup rendering:

```nim
# === Draw slash command menu (if active) ===
if showingSlashMenu and state == Chatting:
  let filtered = filterCommands(currentInput[1..^1])
  if filtered.len > 0:
    let menuY = inputY + 4  # One row below the bottom delimiter
    let maxItems = min(filtered.len, slashMenuHeight)
    
    # Calculate menu dimensions
    var maxNameLen = 0
    var maxDescLen = 0
    for idx in filtered:
      if SlashCommands[idx].name.len > maxNameLen:
        maxNameLen = SlashCommands[idx].name.len
      if SlashCommands[idx].description.len > maxDescLen:
        maxDescLen = SlashCommands[idx].description.len
    
    let menuWidth = min(w, maxNameLen + 3 + maxDescLen)
    
    # Draw menu background
    for row in 0 ..< maxItems:
      if menuY + row >= h: break
      tb.setBackgroundColor(if row == slashMenuIndex: bgBlue else: bgGray)
      tb.setForegroundColor(if row == slashMenuIndex: fgWhite else: fgWhite)
      tb.fill(0, menuY + row, menuWidth - 1, " ")
    
    # Draw menu items
    for row in 0 ..< maxItems:
      if menuY + row >= h: break
      let cmd = SlashCommands[filtered[row]]
      
      # Command name (bright, bold)
      if row == slashMenuIndex:
        tb.setForegroundColor(fgYellow, bright=true)
      else:
        tb.setForegroundColor(fgCyan, bright=true)
      tb.write(1, menuY + row, cmd.name)
      
      # Description
      tb.setForegroundColor(fgWhite)
      tb.write(maxNameLen + 3, menuY + row, cmd.description)
    
    # Draw menu border (top and bottom lines)
    if menuY > 0:
      tb.setForegroundColor(fgGray)
      tb.write(0, menuY - 1, strutils.repeat("─", menuWidth))
    if menuY + maxItems < h:
      tb.write(0, menuY + maxItems, strutils.repeat("─", menuWidth))
    
    tb.setBackgroundColor(bgBlack)  # Reset
    tb.setForegroundColor(fgWhite)
```

**Important**: When the menu is showing, the input bar positioning logic needs to account for the menu height:

In the section that calculates `inputY`, add consideration for the menu:

```nim
let menuActiveSpace = if showingSlashMenu: (min(filtered.len, slashMenuHeight) + 2) else: 0
```

And adjust:
```nim
if contentStartY + allDisplayLines.len + inputBarNeeded + menuActiveSpace <= h:
  # Content fits → input bar floats just below content
  inputY = contentStartY + allDisplayLines.len + InputGap
  ...
```

---

## Summary of File Changes

| Section | Change |
|---------|--------|
| **Types** | Add `SlashCommand` object type |
| **Globals** | Add `showingSlashMenu`, `slashMenuIndex`, `slashMenuHeight` |
| **Consts** | Add `SlashCommands` array |
| **New procs** | `filterCommands()`, `updateSlashMenu()` |
| **handleInput** | Add slash menu navigation handling (Up/Down/Tab/Enter/Esc/Backspace) |
| **handleInput** | Call `updateSlashMenu()` after character input |
| **main() render** | Draw the popup menu below the input bar |
| **main() render** | Adjust `inputY` calculation when menu is visible |

## Commands to Support

| Command | Description |
|---------|-------------|
| `/quit` or `/q` | Exit the application |
| `/model` | Change the current model |
| `/new` | Reset conversation |

*(Easily extensible — just add entries to `SlashCommands` array and a handler in `handleInput`)*

## Edge Cases Handled

1. **Menu closes** when user types anything that doesn't start with `/`
2. **Menu closes** when pressing Escape
3. **Auto-complete** via Tab key fills in the selected command name
4. **Filtering**: typing `/mo` only shows `/model`
5. **Navigation wraps**: Up on first item stays on first, Down on last stays on last
6. **Terminal too short**: menu clips gracefully at bottom of screen
7. **Tab with no matches**: does nothing
8. **Enter on empty filter**: does nothing
9. **Backspace** when input becomes empty or loses `/` prefix closes the menu
10. **While processing** or in model selection state: menu does not appear
