# ============================================================
# mcp_tools_server.nim - Standalone MCP server exposing the
# active tools from my_include/tools.nim on port 8001.
# Independent from the httpd server (port 8000).
# ============================================================
# Compile:
#   nim c --threads:on --path:"my_include" --path:"webui" \
#         --path:"../mcp_nim/mcp_server" --define:ssl \
#         --out:"mcp_tools_server.exe" mcp_tools_server.nim
# ============================================================

import std/[os, asyncdispatch, strutils, json]
import config_web
import mcpframework
import tools


# -----------------------------------------------------------
# Adapter: tools.*Tool procs return a JSON string with shape
#   {"content": "...", "error": null} | {"error": "..."}
# MCP requires a JsonNode with shape
#   {"content": [{"type": "text", "text": "..."}], "isError": bool}
# -----------------------------------------------------------

proc adaptToolResult(raw: string): JsonNode =
  try:
    let parsed = parseJson(raw)
    if parsed.hasKey("error") and not parsed["error"].isNil:
      result = %*{
        "content": [{"type": "text", "text": parsed["error"].getStr("Unknown error")}],
        "isError": true
      }
    else:
      result = %*{
        "content": [{"type": "text", "text": parsed{"content"}.getStr("")}]
      }
  except:
    result = %*{
      "content": [{"type": "text", "text": raw}],
      "isError": true
    }

proc makeHandler(toolName: string): ToolHandler =
  result = proc(args: JsonNode): JsonNode =
    let raw = tools.executeTool(toolName, args)
    adaptToolResult(raw)


# -----------------------------------------------------------
# Register the 3 active tools from ToolsSchemaJson
# -----------------------------------------------------------

proc registerChatbotTools(server: McpServer) =
  let schemaArr = parseJson(tools.ToolsSchemaJson)
  for entry in schemaArr:
    let fn = entry["function"]
    let name = fn["name"].getStr
    # Expose only the ACTIVE tools (read, file_glob_search, websearch);
    # suspended tools (get_file, bash, readDelibera) are not registered.
    case name
    of "read", "file_glob_search", "websearch":
      server.addOpenAITool(entry, makeHandler(name))
    else:
      discard  # suspended tools not exposed on MCP


# -----------------------------------------------------------
# Entry point
# -----------------------------------------------------------

proc exitProc() {.noconv.} =
  quit(0)

proc main() =
  setControlCHook(exitProc)

  # Resolve paths the same way as webui_only / webui_wv
  ExeDir = getAppFilename().parentDir()
  SessionDir = ExeDir

  # Load Firecrawl API key (needed by websearchTool, same as WebUI)
  config_web.loadFirecrawlApiKey()

  let port = if paramCount() > 0: parseInt(paramStr(1)) else: 8001
  let server = initMcpServer(port)
  registerChatbotTools(server)

  echo ""
  echo repeat("=", 60)
  echo "  Nim LlamaServer Chatbot - MCP Tools Server"
  echo repeat("=", 60)
  echo "  Endpoint: http://localhost:" & $port & "/mcp"
  echo "  Tools:    read, file_glob_search, websearch"
  echo "  Press Ctrl+C to stop"
  echo repeat("=", 60)
  echo ""

  waitFor server.start()

main()
