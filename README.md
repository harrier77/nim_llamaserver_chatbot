# Nim LLaMA Server Chatbot

Full-screen TUI chat client in Nim that connects to a local [llama.cpp](https://github.com/ggerganov/llama.cpp) server (`llama-server` on port 8080). Displays streaming AI responses with colour-coded output, tool calling, and model management.

## Features

- **Streaming tokens** — AI replies appear character by character in real time
- **Multi-turn chat** — sliding-window conversation history (configurable with `/history <n>`)
- **Tool calling** — LLM can invoke tools (bash, file read, etc.) via the OpenAI-compatible API
- **Model switching** — `/model` opens an interactive tree menu to pick from categorized models (llamacpp, OpenCode, Ollama)
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
| `/history <n>` or `/h <n>` | Set the maximum number of messages kept in context (1–100) |
| `/history` or `/h` | Show current history limit |
| `/edit <file>` | Open a file in the `micro` editor |
| `/read <file>` | Read a file into the chat output |

## Model Selection Menu

When you type `/model`, a tree-view menu appears showing models categorized by source:

```
  SELECT MODEL
        🖥 LLAMACPP
          ▶ Qwen3.5_0.8b
            Phi-4-mini
        ☁ OPENCODE
          (5 models)
        🐳 OLLAMA
          (3 models)
```

- **←/→** — expand/collapse categories or switch between them
- **↑/↓** — navigate models within the selected category
- **Enter** — confirm selection
- **Esc** — cancel

## Status Bar

The bottom bar shows: server status, processing indicator, selected model, history limit, and message count:

```
🟢 ✓ Ready | Model: Qwen3.5 | Hist: 20 | Msgs: 15
```

- **Hist**: maximum messages to keep in context (set with `/h`)
- **Msgs**: actual messages in current conversation (excluding system prompt)

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
| `←` / `→` | Switch categories in model menu |
| `Tab` | Auto-complete current slash command |
| `Backspace` | Delete last character |