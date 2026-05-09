# Package

version       = "0.1.0"
author        = "Nim TUI Editor"
description   = "A minimal TUI text editor inspired by pi-coding-agent"
license       = "MIT"

# Dependencies

requires "nim >= 2.0.0"
requires "illwill >= 0.4.1"

# Build

bin = @["tui"]

task run, "Run the TUI editor":
  exec "nim c -r tui.nim"

task build, "Build the TUI editor":
  exec "nim c -d:release tui.nim"
