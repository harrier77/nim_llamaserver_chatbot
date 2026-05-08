# Nim LLaMA Server Chatbot

Full-screen TUI chat client in Nim that connects to a local [llama.cpp](https://github.com/ggerganov/llama.cpp) server (`llama-server` on port 8080). Displays streaming AI responses with colour-coded output, tool calling, and model management.

## Features

- **Streaming tokens** — AI replies appear character by character in real time
- **Multi-turn chat** — sliding-window conversation history (configurable with `/history <n>`)
- **Multi-provider architecture** — Connect to local llama.cpp or remote providers (OpenCode, Ollama, NVIDIA, Zaya)
- **Tool calling** — LLM can invoke tools (bash, file read, etc.) via the OpenAI-compatible API
- **Model switching** — `/model` opens an interactive tree menu to pick from categorized models
- **Slash commands** — type `/` to see an auto-complete popup
- **Persistent state** — selected model, history limit, and server URL are saved to `~/.nim_chatbot/status.json`
- **Editor integration** — `/edit <file>` opens the file in `micro`, suspending and restoring the TUI
- **Server monitoring** — status bar shows a green/red indicator; banner appears when the server is unreachable
- **Unicode-aware** — correct UTF-8 input, backspace, and word-wrapping
- **Scrollable output** — navigate history with ↑ / ↓
- **Web Interface** — Modern web UI available at http://localhost:8000 with theme support, file uploads, and model selection

## Keybindings

| Key | Action |
|---|---|
| `Enter` | Send message / confirm selection |
| `Esc` | Quit (or cancel menu) |
| `↑` / `↓` | Scroll output / navigate menus |
| `←` / `→` | Switch categories in model menu |
| `Tab` | Auto-complete current slash command |
| `Backspace` | Delete last character |

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

## Multi-Provider Architecture

The chatbot supports a sophisticated multi-provider system that allows you to connect to different AI backends simultaneously:

### Supported Providers

| Provider | Type | Description |
|---|---|---|
| **llama.cpp** | Local | Run GGUF models locally via `llama-server` |
| **OpenCode** | Remote | Cloud API at opencode.ai (OpenAI-compatible) |
| **Ollama** | Remote | Local or cloud Ollama instances |
| **NVIDIA NIM** | Remote | NVIDIA's API for Llama, Mistral, and other models |
| **Zaya** | Remote | Zyphra's API for their model variants |

### How It Works

When you select a model via `/model`, the chatbot automatically routes requests to the appropriate provider:

1. **Local llama.cpp** (`🖥 LLAMACPP`): Connects to `localhost:8080`
2. **OpenCode** (`☁ OPENCODE`): Uses the base URL and API key from your config
3. **Ollama** (`🐳 OLLAMA`): Connects to your Ollama instance or ollama.com
4. **NVIDIA** (`🎮 NVIDIA`): Uses NVIDIA's NIM API
5. **Zaya** (`🌐 ZAYA`): Uses Zyphra's cloud API

The model selection menu displays models organized by source. Use **←/→** to switch categories, **↑/↓** to navigate models, and **Enter** to select.

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

## Configuration Directory (`~/.nim_chatbot`)

On first run, the application creates a configuration directory at `~/.nim_chatbot/` containing:

```
~/.nim_chatbot/
├── models.json    # Provider endpoints and available models
├── auth.json      # API keys for remote providers
└── status.json    # Persisted app state (selected model, history, server URL)
```

### models.json

Defines provider endpoints and available models:

```json
{
  "providers": {
    "opencode": {
      "baseUrl": "https://opencode.ai/zen/v1/chat/completions",
      "models": ["DeepSeek-Coder-7B-Instruct"]
    },
    "ollama": {
      "baseUrl": "https://ollama.com/v1",
      "models": ["llama3:8b", "codellama:7b"]
    },
    "nvidia": {
      "baseUrl": "https://integrate.api.nvidia.com/v1/chat/completions",
      "models": ["nvidia/llama-3.1-nemotron-70b-instruct"]
    },
    "zaya": {
      "baseUrl": "https://api.zyphracloud.com/api/v1",
      "models": ["Z7-Channel"]
    }
  }
}
```

### auth.json

Stores API keys for remote providers:

```json
{
  "opencode": { "key": "your-opencode-api-key" },
  "ollama": { "key": "your-ollama-api-key" },
  "nvidia": { "key": "your-nvidia-api-key" },
  "zaya": { "key": "your-zaya-api-key" }
}
```

### status.json

Contains persisted application state:

```json
{
  "selected_model": "qwen3-coder:480b",
  "max_history_messages": 10,
  "server_url": "http://localhost:8080"
}
```

**Note**: For local llama.cpp models, the available models are discovered dynamically by querying the server's `/v1/models` endpoint. For remote providers, models are loaded from `models.json`.

## Authentication for Remote Providers

Remote providers authenticate via API keys stored in `~/.nim_chatbot/auth.json`. Each provider entry contains:

- **key**: The API key used for authentication

When making requests to remote providers, the chatbot automatically includes the API key in the `Authorization` header:

```
Authorization: Bearer <your-api-key>
```

For providers that require it, the key is also passed in the `api-key` header for NVIDIA's API.

## Model Selection Menu

When you type `/model`, a tree-view menu appears showing models categorized by source:

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
- A running `llama-server` instance on `localhost:8080` (for local models)
- Configuration files in `~/.nim_chatbot/` (for remote providers)

## Usage

```bash
# 1. Start the llama.cpp server (for local models)
./llama-server -m your-model.gguf --port 8080

# 2. Run the chat client
nim c -r main.nim

# 3. Access the Web UI (optional)
# Open http://localhost:8000 in your browser
```

## Web Interface Features

The chatbot includes a modern web interface accessible at http://localhost:8000:

### Capabilities

- **Full Chat Functionality**: Send messages and receive streaming AI responses
- **Tool Calling**: The web interface shows tool invocations and their results
  - **read**: Read files from the filesystem
  - **bash**: Execute shell commands
- **Real-time Streaming**: See AI responses as they generate
- **Model Selection**: Choose from available models via dropdown
- **Theme Support**: Toggle between dark/light themes with persistent preferences
- **Mobile Support**: Responsive design works on desktop and mobile browsers

### Tool Integration in Web UI

When the LLM triggers a tool call:

1. A tool call block appears in the chat showing the function name and arguments
2. The execution runs server-side
3. The result is displayed below the tool call
4. The LLM then generates its final response incorporating the tool result

### File Upload

The web interface supports uploading files (up to 1MB) that are included in prompt context, useful for analyzing code or documents.

## Example Configuration

To use remote providers, create the configuration files:

```bash
# Create the config directory
mkdir -p ~/.nim_chatbot

# Create models.json
cat > ~/.nim_chatbot/models.json << 'EOF'
{
  "providers": {
    "opencode": {
      "baseUrl": "https://opencode.ai/zen/v1/chat/completions",
      "models": ["DeepSeek-Coder-7B-Instruct"]
    }
  }
}
EOF

# Create auth.json
cat > ~/.nim_chatbot/auth.json << 'EOF'
{
  "opencode": { "key": "your-api-key-here" }
}
EOF
```

Replace `your-api-key-here` with your actual API key from the provider.