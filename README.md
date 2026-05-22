# Nim LLaMA Server Chatbot

Nim chat client that connects to a [llama.cpp](https://github.com/ggerganov/llama.cpp) server with multi-provider support (OpenCode, Ollama, NVIDIA, Zaya), tool calling, web interface, and native WebView2 window.

## Binaries

| Command | File | Description |
|---------|------|-------------|
| `compila` | `webui_only.exe` | HTTP server only (browser) |
| `compila wv` | `webui_wv.exe` | HTTP server + native WebView2 window (no console) |
| `compila tui` | `chatbot_main.exe` | Full version with TUI (terminal UI) |
| `compila both` | all | Build all three |

## Quick Start

```bash
# Server + native WebView2 window
compila wv
webui_wv.exe

# HTTP server only, open http://localhost:8000 in browser
compila
webui_only.exe

# Full TUI version
compila tui
chatbot_main.exe --chat
```

## Build Flags

All builds use: `--threads:on --define:ssl --path:"my_include" --path:"webui"`.  
The `wv` build adds `--path:"webview2_nim" --app:gui`.

## Dependencies

- [Nim](https://nim-lang.org/) compiler
- [illwill](https://github.com/johnnovak/illwill) — `chatbot_main.exe` only
- [winim](https://github.com/khchen/winim) — `webui_wv.exe` only (`nimble install winim`)
- WebView2 Runtime — preinstalled on Windows 10/11 with Edge Chromium
- `llama-server` running on `localhost:8080` (for local models)

## Configuration

Configuration files (providers, API keys, state) are stored in `~/.nim_chatbot/`.
