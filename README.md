# Nim LLaMA Server Chatbot

Nim chat client that connects to a [llama.cpp](https://github.com/ggerganov/llama.cpp) server with multi-provider support (OpenCode, Ollama, NVIDIA, Zaya), tool calling, web interface (with markdown rendering), native WebView2 window, MCP tool server, and web search.

## Binaries

| Command | File | Description |
|---------|------|-------------|
| `compila` | `webui_only.exe` | HTTP server only (browser) |
| `compila wv` | `webui_wv.exe` | HTTP server + native WebView2 window (no console) |
| `compila tui` | `chatbot_main.exe` | Full version with TUI (terminal UI) |
| `compila mcp` | `mcp_tools_server.exe` | Standalone MCP tool server (port 8001) |
| `compila both` | all | Build all four |


## Dependencies

- [Nim](https://nim-lang.org/) compiler
- [illwill](https://github.com/johnnovak/illwill) — `chatbot_main.exe` only
- [winim](https://github.com/khchen/winim) — `webui_wv.exe` only (`nimble install winim`)
- WebView2 Runtime — preinstalled on Windows 10/11 with Edge Chromium
- `llama-server` running on `localhost:8080` (for local models)

## Configuration

Configuration files (providers, API keys, state) are stored in `~/.nim_chatbot/`.

## Tool Calling

The chatbot supports OpenAI-compatible **function calling** (tool calling). The
model can request tool executions during a chat, and the system executes them
and returns results back to the model — enabling file reading, code search, and
live web queries.

### Active Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `read` | Read a file from the filesystem | `file_path` (req), `offset`, `limit`, `max_bytes`, `from_tail` |
| `file_glob_search` | Search files by glob pattern in a directory (top-level only) | `path` (req), `include`, `exclude` |
| `websearch` | Search the public web via Firecrawl API | `query` (req), `num_results` (1–20, default 8) |

### Architecture

1. The model responds with a `tool_calls` delta containing the tool name and
   JSON arguments.
2. The client collects all deltas into a complete tool call, then dispatches
   to `executeTool()` in `my_include/tools.nim`.
3. Each tool returns a JSON string with `{"content": "...", "error": null}` on
   success, or `{"error": "..."}` on failure.
4. The result is sent back to the model as a `tool`-role message with the
   matching `tool_call_id`, allowing the model to continue its response.

### Argument Parsing

Tool call arguments are parsed with a **multi-level fallback strategy** in
`safeParseToolArgs()` to handle malformed JSON from smaller models:
- **Level 1:** Direct `parseJson`
- **Level 2:** Repair (missing closing brace/bracket/quote, trailing colon)
- **Level 3:** Regex extraction of known parameter keys

### Suspended Tools

`get_file`, `bash`, and `readDelibera` are **suspended** (not registered in the
schema). Calling them returns an error message directing the model to use `read`
instead.

### Tool Schema

The single source of truth is the `ToolsSchemaJson` const in
`my_include/tools.nim`, exported as `ToolsSchema` (a `JsonNode`). Both the TUI
and WebUI use this same schema when advertising available tools to the model.

## Features

### WebUI
- **Markdown rendering** — messages rendered with `marked.js`, syntax
  highlighting via `highlight.js`, sanitized with `DOMPurify`. Supports headings,
  code blocks, tables, lists, inline formatting, and `==highlight==` syntax.
- **Launch llama.cpp** — toolbar button to start a local `llama-server`
  process directly from the WebUI (visible when a local provider is selected).
- **Kill llama.cpp** — toolbar button to terminate the running `llama-server`
  process. Shows server status and auto-toggles visibility.
- **Open Server** — button to open `http://localhost:8080` in the browser
  for direct llama.cpp server inspection.
- **Light/Dark theme toggle** — instant theme switching.
- **Provider selector** — dropdown to switch between local and remote providers
  (OpenCode, Ollama, NVIDIA, Zaya) with a "remote" badge for cloud endpoints.

### MCP (Model Context Protocol) Server

A standalone MCP server (`mcp_tools_server.exe`) runs on **port 8001** and exposes
the chatbot's tools via the [MCP protocol](https://modelcontextprotocol.io/)
(version 2025-03-26).

| Feature | Detail |
|---------|--------|
| Endpoint | `http://localhost:8001/mcp` |
| Exposed tools | `read`, `file_glob_search`, `websearch` |
| Protocol | JSON-RPC 2.0 over HTTP with session management |
| CORS | Full CORS support for cross-origin clients |
| Sessions | Automatic session creation and lifecycle management |
| Schema | OpenAI-compatible function-calling schema for each tool |
| Frameworks | Custom lightweight MCP framework in `my_include/mcpframework.nim` |

Build with: `compila mcp` (produces `mcp_tools_server.exe`).

This allows any MCP-compatible client (IDE plugins, AI assistants, custom
scripts) to invoke the same tools available in the chat interface.
