# Nim LLaMA Server Chatbot

Chat client in Nim che si collega a un server [llama.cpp](https://github.com/ggerganov/llama.cpp) con supporto multi-provider (OpenCode, Ollama, NVIDIA, Zaya), tool calling, interfaccia web e finestra nativa WebView2.

## Eseguibili

| Comando | File | Descrizione |
|---------|------|-------------|
| `compila` | `webui_only.exe` | Solo server HTTP (browser) |
| `compila wv` | `webui_wv.exe` | Server HTTP + finestra WebView2 nativa (no console) |
| `compila tui` | `chatbot_main.exe` | Versione completa con TUI (terminal UI) |
| `compila both` | tutti | Compila tutti e tre |

## Quick Start

```bash
# Server + finestra WebView2 nativa
compila wv
webui_wv.exe

# Solo server HTTP, apri http://localhost:8000 nel browser
compila
webui_only.exe

# Versione completa con TUI
compila tui
chatbot_main.exe --chat
```

## Build Flags

Tutte le build usano: `--threads:on --define:ssl --path:"my_include" --path:"webui"`.  
La build `wv` aggiunge `--path:"webview2_nim" --app:gui`.

## Dipendenze

- [Nim](https://nim-lang.org/) compiler
- [illwill](https://github.com/johnnovak/illwill) — solo per `chatbot_main.exe`
- [winim](https://github.com/khchen/winim) — solo per `webui_wv.exe` (`nimble install winim`)
- WebView2 Runtime — preinstallato su Windows 10/11 con Edge Chromium
- `llama-server` in esecuzione su `localhost:8080` (per modelli locali)

## Configurazione

I file di configurazione (provider, API key, stato) sono in `~/.nim_chatbot/`.
