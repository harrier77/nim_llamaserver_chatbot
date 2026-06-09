#!/usr/bin/env bash
# ============================================================
# compila.sh - Build script for Nim LlamaServer Chatbot (Linux)
# ============================================================
#
# Usage:
#   ./compila.sh            -> builds webui_only (browser only, no TUI)
#   ./compila.sh wv         -> prints info (WebView2 is Windows-only)
#   ./compila.sh tui        -> builds chatbot_main (full TUI version)
#   ./compila.sh mcp        -> builds mcp_tools_server (standalone MCP server, port 8001)
#   ./compila.sh both       -> builds all Linux-supported versions
#   ./compila.sh clean      -> removes all executables
#
# Common flags for all builds:
#   --threads:on       -> required by httpdserver (createThread)
#   --define:ssl       -> required for HTTPS remote providers
#   --path:"my_include" -> module search path
#   --path:"webui"     -> module search path
#
# The webui-only builds (webui_only) exclude illwill (TUI library),
# resulting in smaller binaries with no terminal UI dependency.
# ============================================================

set -euo pipefail

FLAGS="--threads:on --path:'my_include' --path:'webui' --define:ssl"
MCPFLAGS="$FLAGS"
# Note: --app:gui and WebView2 are Windows-only, so WVFLAGS is omitted.

print_banner() {
    echo ""
    echo "=== Building $1 ==="
    echo ""
}

build_webui() {
    print_banner "webui_only (browser only, no TUI)"
    nim c $FLAGS --out:"webui_only.exe" webui_only.nim
    echo ""
    echo "[OK] webui_only.exe created"
}

build_tui() {
    print_banner "chatbot_main (full TUI version)"
    nim c $FLAGS --out:"chatbot_main.exe" main.nim
    echo ""
    echo "[OK] chatbot_main.exe created"
}

build_wv() {
    echo ""
    echo "=== webui_wv (WebUI + WebView2) ==="
    echo ""
    echo "[INFO] WebView2 is Windows-only. Skipping build on Linux."
    echo ""
}

build_mcp() {
    print_banner "mcp_tools_server (MCP tool server, port 8001)"
    echo "[INFO] Requires mcp_nim/mcp_server/mcpframework.nim"
    echo ""
    nim c $MCPFLAGS --out:"mcp_tools_server.exe" mcp_tools_server.nim
    echo ""
    echo "[OK] mcp_tools_server.exe created"
}

clean_all() {
    echo ""
    echo "=== Cleaning executables ==="
    echo ""
    for exe in webui_only.exe chatbot_main.exe webui_wv.exe mcp_tools_server.exe; do
        if [ -f "$exe" ]; then
            rm "$exe"
            echo "[OK] $exe deleted"
        fi
    done
    echo ""
}

# --- Main dispatch ---

case "${1:-}" in
    mcp)
        build_mcp
        ;;
    wv)
        build_wv
        ;;
    tui)
        build_tui
        ;;
    both)
        echo ""
        echo "=== Building ALL Linux-supported versions ==="
        echo ""
        build_webui
        build_tui
        build_mcp
        echo ""
        echo "[OK] All executables built successfully"
        ;;
    clean)
        clean_all
        ;;
    *)
        # Default: build webui only
        build_webui
        ;;
esac
