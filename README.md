# fullscreen.nim

A full-screen **terminal UI (TUI) chat client** written in Nim that connects to a local [llama.cpp](https://github.com/ggerganov/llama.cpp) server (`llama-server` on port 8080) and displays streaming AI responses in real time.

## Features

- **Streaming responses** — tokens appear as they are generated, no waiting for the full reply.
- **Multi-turn conversation** — maintains chat history across turns.
- **Tool calling** — supports `read` and `bash` tools via the OpenAI-compatible API; the LLM can execute commands and read files mid-conversation.
- **Model switching** — press `/model` to select from available models served by the running `llama-server`.
- **Scrollable output** — navigate history with ↑/↓ keys.
- **Slash commands** — `/quit` or `/q` to exit, `/model` to change model.
- **Unicode-aware** — handles UTF-8 input and display correctly (backspace, wrapping, cursor positioning).

## Dependencies

- [Nim](https://nim-lang.org/) compiler
- [illwill](https://github.com/johnnovak/illwill) — terminal rendering library
- A running `llama-server` instance on `localhost:8080`

## Usage

```bash
# Make sure llama-server is running first
./llama-server -m your-model.gguf --port 8080

# Run the chat client
nim c -r fullscreen.nim
```

## Keybindings

| Key | Action |
|---|---|
| `Enter` | Send message |
| `Esc` / `q` | Quit |
| `↑` / `↓` | Scroll output |
| `Backspace` | Delete last character |
| `/model` | Open model selection menu |
| `/quit` or `/q` | Exit |
