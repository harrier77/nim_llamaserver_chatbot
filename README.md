# Nim LLaMA Server Chatbot

Full-screen TUI chat client in Nim that connects to a local [llama.cpp](https://github.com/ggerganov/llama.cpp) server (`llama-server` on port 8080). Displays streaming AI responses with colour-coded output, tool calling, and model management.

## Features

- **Streaming tokens** — AI replies appear character by character in real time
- **Multi-turn chat** — sliding-window conversation history (configurable with `/history <n>`)
- **Tool calling** — LLM can invoke tools (bash, file read, etc.) via the OpenAI-compatible API
- **Model switching** — `/model` opens an interactive menu to pick any model served by `llama-server`
- **Slash commands** — type `/` to see an auto-complete popup
- **Persistent state** — selected model, history limit, and server URL are saved to `my_include/status.json`
- **Editor integration** — `/edit <file>` opens the file in `micro`, suspending and restoring the TUI
- **Server monitoring** — status bar shows a green/red indicator; banner appears when the server is unreachable
- **Unicode-aware** — correct UTF-8 input, backspace, and word-wrapping
- **Scrollable output** — navigate history with ↑ / ↓

## Slash Commands

| Command | Description |
|---|---|
| `/quit` or `/q` | Exit the application |
| `/model` | Open the model selection menu |
| `/new` | Reset conversation and start a fresh chat |
| `/edit <file>` | Open a file in the `micro` editor |
| `/history <n>` | Set the maximum number of messages kept in context (1–100) |

## Dependencies

- [Nim](https://nim-lang.org/) compiler
- [illwill](https://github.com/johnnovak/illwill) — terminal rendering library
- A running `llama-server` instance on `localhost:8080`

## Usage

```bash
# 1. Start the llama.cpp server
./llama-server -m your-model.gguf --port 8080

# 2. Run the chat client
nim c -r main.nim
```

## Keybindings

| Key | Action |
|---|---|
| `Enter` | Send message / confirm selection |
| `Esc` | Quit (or cancel menu) |
| `↑` / `↓` | Scroll output / navigate menus |
| `Tab` | Auto-complete current slash command |
| `Backspace` | Delete last character |
