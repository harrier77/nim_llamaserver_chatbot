import std/[asynchttpserver, asyncdispatch, json, strutils, tables, random]

const
  MCP_PROTOCOL_VERSION* = "2025-03-26"
  SERVER_NAME* = "nim-mcp-server"
  SERVER_VERSION* = "1.0.0"

type
  ToolArg* = object
    name*: string
    description*: string
    jsonType*: string

  ToolHandler* = proc(args: JsonNode): JsonNode {.closure, gcsafe.}

  ToolDef* = object
    name*: string
    description*: string
    args*: seq[ToolArg]
    handler*: ToolHandler
    inputSchema*: JsonNode   # when non-nil, takes precedence over args

  McpSession* = ref object
    id*: string
    initialized*: bool

  McpServer* = ref object
    port*: int
    tools*: Table[string, ToolDef]
    sessions*: Table[string, McpSession]

proc initMcpServer*(port: int = 8000): McpServer =
  new(result)
  result.port = port
  result.tools = initTable[string, ToolDef]()
  result.sessions = initTable[string, McpSession]()

proc addTool*(server: McpServer; name, description: string;
              args: openArray[ToolArg]; handler: ToolHandler) =
  server.tools[name] = ToolDef(
    name: name, description: description,
    args: @args, handler: handler
  )

proc addOpenAITool*(server: McpServer, entry: JsonNode, handler: ToolHandler) =
  ## Register a tool from its OpenAI function-calling schema entry:
  ##   { "type": "function", "function": { "name": ..., "description": ..., "parameters": ... } }
  ## The `parameters` object is stored as the MCP `inputSchema` directly,
  ## preserving full JSON Schema fidelity.
  let fn = entry["function"]
  let name = fn["name"].getStr
  let description = fn["description"].getStr("")
  let inputSchema = if fn.hasKey("parameters"): fn["parameters"]
                    else: %*{"type": "object", "properties": %*{}}
  server.tools[name] = ToolDef(
    name: name,
    description: description,
    args: @[],
    handler: handler,
    inputSchema: inputSchema
  )

proc generateSessionId: string =
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  for _ in 0..31:
    result.add(chars[rand(chars.high)])

proc toolToJson(tool: ToolDef): JsonNode =
  result = %*{"name": tool.name, "description": tool.description}
  if not tool.inputSchema.isNil:
    # Use pre-rendered schema (from addOpenAITool)
    result["inputSchema"] = tool.inputSchema
  else:
    # Build schema from ToolArg definitions (legacy addTool path)
    let properties = %*{}
    let required = newJArray()
    for arg in tool.args:
      properties[arg.name] = %*{
        "type": arg.jsonType,
        "description": arg.description
      }
      required.add(%arg.name)
    result["inputSchema"] = %*{"type": "object", "properties": properties}
    if required.len > 0:
      result["inputSchema"]["required"] = required

proc jsonErr(id: JsonNode; code: int; msg: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": msg}}

proc jsonOk(id: JsonNode; data: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "result": data}

proc processMcpMessage(server: McpServer; body: string;
    sessionId: var string): tuple[status: int, contentType: string, respBody: string] =

  let ct = "application/json"

  var reqJson: JsonNode
  try:
    reqJson = parseJson(body)
  except JsonParsingError:
    return (400, ct, $jsonErr(newJNull(), -32700, "Parse error"))

  let msgId = reqJson{"id"}
  let mcpMeth = reqJson{"method"}.getStr("")
  let isRequest = mcpMeth.len > 0 and not msgId.isNil and msgId.kind != JNull

  if isRequest:
    case mcpMeth
    of "initialize":
      let newSid = generateSessionId()
      sessionId = newSid
      server.sessions[newSid] = McpSession(id: newSid, initialized: false)
      return (200, ct, $jsonOk(msgId, %*{
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}
      }))

    of "tools/list":
      let arr = newJArray()
      for t in server.tools.values:
        arr.add(toolToJson(t))
      return (200, ct, $jsonOk(msgId, %*{"tools": arr}))

    of "tools/call":
      let p = reqJson{"params"}
      if p.isNil:
        return (200, ct, $jsonErr(msgId, -32602, "Missing params"))

      let tn = p{"name"}.getStr("")
      if tn.len == 0:
        return (200, ct, $jsonErr(msgId, -32602, "Missing tool name"))

      if not server.tools.hasKey(tn):
        return (200, ct, $jsonErr(msgId, -32601, "Unknown tool: " & tn))

      try:
        let res = server.tools[tn].handler(p{"arguments"})
        return (200, ct, $jsonOk(msgId, res))
      except CatchableError as e:
        return (200, ct, $jsonErr(msgId, -32005, e.msg))

    of "resources/list":
      return (200, ct, $jsonOk(msgId, %*{"resources": []}))

    of "prompts/list":
      return (200, ct, $jsonOk(msgId, %*{"prompts": []}))

    of "ping":
      return (200, ct, $jsonOk(msgId, %*{}))

    else:
      return (200, ct, $jsonErr(msgId, -32601, "Method not found: " & mcpMeth))

  else:
    # Notification (no id) or JSON-RPC response
    if mcpMeth == "notifications/initialized":
      if sessionId.len > 0 and server.sessions.hasKey(sessionId):
        server.sessions[sessionId].initialized = true
    return (202, "", "")

proc getHeader(headers: HttpHeaders; key: string): string =
  for k, v in headers.pairs:
    if cmpIgnoreCase(k, key) == 0:
      return v
  result = ""

proc addCorsHeaders(headers: var HttpHeaders; reqHeaders: HttpHeaders) =
  let origin = getHeader(reqHeaders, "Origin")
  if origin.len > 0:
    headers.add("Access-Control-Allow-Origin", origin)
    headers.add("Vary", "Origin")
  else:
    headers.add("Access-Control-Allow-Origin", "*")
  headers.add("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
  headers.add("Access-Control-Allow-Headers", "Content-Type, Accept, Mcp-Session-Id, Last-Event-ID, MCP-Protocol-Version")
  headers.add("Access-Control-Max-Age", "86400")

proc handleRequest(server: McpServer; req: Request) {.async.} =
  let path = req.url.path

  if path != "/mcp":
    await req.respond(Http404, "Not found")
    return

  # Handle CORS preflight (OPTIONS)
  if req.reqMethod == HttpOptions:
    var headers = newHttpHeaders()
    headers.addCorsHeaders(req.headers)
    headers.add("Content-Length", "0")
    await req.respond(Http204, "", headers)
    return

  case req.reqMethod
  of HttpPost:
    let body = req.body
    if body.len == 0:
      var h = newHttpHeaders()
      h.addCorsHeaders(req.headers)
      await req.respond(Http400, "Empty request body", h)
      return

    var sessionId = getHeader(req.headers, "Mcp-Session-Id")
    let prevSessionId = sessionId

    let (status, ctype, respBody) = processMcpMessage(server, body, sessionId)

    var headers = newHttpHeaders()
    headers.addCorsHeaders(req.headers)
    if ctype.len > 0:
      headers.add("Content-Type", ctype)

    # If session was just created, return Mcp-Session-Id
    if sessionId.len > 0 and sessionId != prevSessionId:
      headers.add("Mcp-Session-Id", sessionId)

    await req.respond(cast[HttpCode](status), respBody, headers)

  of HttpGet:
    var headers = newHttpHeaders()
    headers.addCorsHeaders(req.headers)
    await req.respond(Http405, "Method Not Allowed", headers)

  of HttpDelete:
    let sid = getHeader(req.headers, "Mcp-Session-Id")
    if sid.len > 0:
      server.sessions.del(sid)
    var headers = newHttpHeaders()
    headers.addCorsHeaders(req.headers)
    await req.respond(Http202, "", headers)

  else:
    var headers = newHttpHeaders()
    headers.addCorsHeaders(req.headers)
    await req.respond(Http405, "Method Not Allowed", headers)

proc start*(server: McpServer) {.async.} =
  randomize()
  let srv = newAsyncHttpServer()

  echo ""
  echo "╔════════════════════════════════════════╗"
  echo "║        Nim MCP Server v" & SERVER_VERSION & "           ║"
  echo "╠════════════════════════════════════════╣"
  echo "║  Endpoint: http://localhost:" & align($server.port, 4) & "/mcp  ║"
  echo "║  Protocol: MCP " & MCP_PROTOCOL_VERSION & "             ║"
  echo "╚════════════════════════════════════════╝"
  echo ""

  proc cb(req: Request) {.async.} =
    await server.handleRequest(req)

  await srv.serve(Port(server.port), cb)
