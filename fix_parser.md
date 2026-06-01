# Fix: Robust tool-call argument parsing for LFM2.5 / small models

## Problem

The LFM2.5 model family (and other small function-calling models) frequently
emits **malformed JSON** for tool-call arguments. The most common pattern is:

```json
{"file_path": "delibera_0005_2026.txt", "limit":}
```

A `"limit":` (or any other key) is emitted **with no value** — leaving the
JSON syntactically invalid.

### Observed failure chain (WebUI)

```
LLM stream → JS concatenates tool_call.arguments
           → JSON.parse("{\"file_path\":\"x\",\"limit\":}") throws
           → catch → toolArgs = {} (silent fallback)
           → POST /api/execute-tool with arguments = {}
           → server: tools.executeTool("read", {})
           → readTool: if path == "" → "Missing file_path parameter"
```

The misleading `"Missing file_path parameter"` error made debugging difficult
because `file_path` was actually correctly set in the original LLM output —
it was just being dropped by the JSON parse failure.

The TUI path had a partial workaround (`safeParseToolArgs` with 3-level
fallback) but the WebUI path had **zero** error recovery.

---

## Solution overview

Four layers of defense, from upstream (prevention) to downstream (recovery):

| # | Layer | File | Purpose |
|---|-------|------|---------|
| 1 | **LLM prompt** | `my_include/system_prompt.yaml` | Prevent the model from emitting empty values |
| 2 | **Browser JS** | `webui/static/index.html` | 3-level repair of LLM output before sending to server |
| 3 | **Server (Nim)** | `webui/httpdserver.nim` | Defense in depth: re-parse if browser failed |
| 4 | **Tool error** | `my_include/tools.nim` | Diagnostic error message instead of misleading "Missing file_path" |

---

## Changes

### 1. `my_include/tools.nim`

- **Added** `import re` (moved from `chat.nim`).
- **Added** `safeParseToolArgs*(raw: string): JsonNode` — 3-level JSON repair:
  - **Level 1**: direct `parseJson`
  - **Level 2**: repair — normalize Python booleans (`True`/`False`/`None`),
    strip trailing comma, then **loop** to remove orphan keys (`"key":` with
    no value) from the tail of the object
  - **Level 3**: regex extraction of known parameter keys as last resort
- **Updated** `readTool` and `getFileTool` to distinguish between
  "arguments could not be parsed" (raw args empty/non-object) and
  "missing file_path parameter" (args parsed but key absent).

Key fragment of the new orphan-key repair (handles the LFM2.5 case):

```nim
# Loop because multiple orphan keys can appear in sequence
# e.g. {"file_path":"x","limit":, "offset":}
var changed = true
while changed:
  changed = false
  let lastColon = fixed.rfind(':')
  if lastColon >= 0:
    let afterColon = fixed[lastColon+1..^1].strip()
    if afterColon.len == 0 or afterColon == "\"" or afterColon == "'" or
       afterColon == "}" or afterColon == "]" or afterColon == ",":
      # drop from last colon, then walk back through the key and separator
      fixed = fixed[0..<lastColon]
      ...
      changed = true
```

### 2. `my_include/chat.nim`

- **Removed** the local duplicate of `safeParseToolArgs` (it was here before
  this fix).
- **Removed** the `re` import (no longer needed locally).
- The function is now imported from `tools` (which already exports it with `*`).

### 3. `webui/httpdserver.nim`

- **Updated** the `/api/execute-tool` handler. When `arguments` arrives as a
  string (LLM-streamed tool call) instead of a pre-parsed object, run it
  through `tools.safeParseToolArgs` before dispatching to `executeTool`.

```nim
var toolArgs: JsonNode
if args.hasKey("arguments"):
  let rawArgs = args["arguments"]
  if rawArgs.kind == JString:
    toolArgs = tools.safeParseToolArgs(rawArgs.getStr())  # ★ repair
  else:
    toolArgs = rawArgs
else:
  toolArgs = %*{}
```

### 4. `webui/static/index.html`

- **Added** a JS port of `safeParseToolArgs` (3-level fallback) defined
  alongside `executeTool`.
- **Replaced** the fragile `try { JSON.parse(normalizedArgs) } catch { {} }`
  block with a single call:

```javascript
// Old: try { toolArgs = JSON.parse(normalizedArgs) } catch(e) { toolArgs = {}; }
// New: 3-level fallback
const toolArgs = safeParseToolArgs(tc.function.arguments);
```

The JS function is a faithful port of the Nim version: Python boolean
normalization, comma cleanup, loop-based orphan-key removal, brace closure,
then regex extraction as last resort.

### 5. `my_include/system_prompt.yaml`

- **Added** an explicit `CRITICAL JSON FORMATTING RULE` at the top of the
  system prompt:

```
CRITICAL JSON FORMATTING RULE — every parameter MUST have a value.
  WRONG:  {"file_path": "x.txt", "limit":}
  WRONG:  {"file_path": "x.txt", "limit": , "from_tail": true}
  WRONG:  {"file_path": "x.txt", "limit",}
  RIGHT:  {"file_path": "x.txt", "limit": 4096}
  RIGHT:  {"file_path": "x.txt"}    (omit the key entirely if no value)
If you don't know a value, OMIT the key — never emit an empty value.
```

---

## Verification

A test suite was run against both the Nim and JS implementations. All
10 cases pass in both:

| # | Input | Expected | Nim | JS |
|---|-------|----------|-----|----|
| 1 | `{"file_path":"x","limit":}` | `file_path` present | PASS | PASS |
| 2 | `{"file_path":"x","limit_bytes":4096}` | `file_path` present | PASS | PASS |
| 3 | `{"file_path":"x","limit_bytes":4096` (truncated) | repaired | PASS | PASS |
| 4 | `{"file_path":"x","from_tail":True}` | Python bool normalized | PASS | PASS |
| 5 | `{"file_path":"x","limit":100,}` (trailing comma) | repaired | PASS | PASS |
| 6 | `{"limit":}` (key only, no file_path) | `{}` | PASS | PASS |
| 7 | `{"file_path":"x","limit":, "offset":}` (double empty) | `{"file_path":"x"}` | PASS | PASS |
| 8 | `{"file_path":"x","limit":null}` | `limit` = null | PASS | PASS |
| 9 | `""` (empty) | `{}` | PASS | PASS |
| 10 | `"totally not json"` (garbage) | `{}` | PASS | PASS |

All three modified Nim modules compile cleanly:

```
tools.nim          rc=0
chat.nim           rc=0
httpdserver.nim    rc=0
```

---

## Files modified

- `my_include/tools.nim` (+169 lines, exports `safeParseToolArgs`)
- `my_include/chat.nim` (-97 lines, removed duplicate)
- `my_include/system_prompt.yaml` (+8 lines, formatting rule)
- `webui/httpdserver.nim` (+15 lines, defensive re-parse)
- `webui/static/index.html` (+120 lines, JS parser + integration)

---

## Additional fix: parameter name disambiguation (root cause)

After deploying the multi-layer defense described above, the symptom
(`"limit":` emitted with no value) reappeared for multi-parameter tool
calls. The defensive layers masked the symptom but did not address the
**root cause**: the LLM was getting confused between two similarly-named
parameters in the same tool schema.

### Root cause

LFM2.5-8B-A1B is a sparse MoE model with **8.3B total parameters but only
1.5B active per token**. When the tool schema contained two parameters
with overlapping name prefixes:

```json
"limit":       <parameter A: max number of lines to return>
"limit_bytes": <parameter B: max number of bytes to read>
```

the model consistently confused the two. Empirical observation from
`nimlog.txt` (request `read "./colosseo.txt" limit_bytes 4096`):

```json
// BAD — model output
{"name": "read", "arguments": "{\"file_path\":\"./colosseo.txt\",\"limit\":"}
```

The model selected `"limit"` (the wrong key) and started writing its
value, but the stream was closed by `finish_reason: tool_calls` before
the value could be emitted, producing the `"limit":` orphan documented
in the problem statement above.

### Fix: rename the parameter

Rename the byte-cap parameter from `limit_bytes` to `max_bytes` so that
the two parameter names in the `read` tool schema share **no lexical
overlap**:

```json
"limit":     <parameter A: max number of lines to return>
"max_bytes": <parameter B: max number of bytes to read>
```

After the rename, the same query produces:

```json
// GOOD — model output (confirmed in nimlog.txt)
{"name": "read", "arguments": "{\"file_path\":\"./colosseo.txt\",\"max_bytes\":4096}"}
```

The value is present, the JSON is well-formed, no defensive layer needs
to fire.

### Why this works

Small / MoE models with low active-parameter count are sensitive to
**lexical similarity** between schema fields. When two field names share
a prefix (`limit` / `limit_bytes`), the attention mechanism is more
likely to confuse them during decoding. Picking **maximally distinct
names** — even at the cost of mild verbosity — is the simplest,
cheapest, and most robust preventive measure.

General principle: when designing tool schemas for small function-calling
models, prefer names that differ in **the first 3-4 characters**, not
just the suffix. Examples:

- `limit` vs `max_bytes` ✓ (distinct roots)
- `limit` vs `limit_bytes` ✗ (prefix collision)
- `path` vs `glob` ✓
- `path` vs `path_filter` ✗

### Scope of the rename

The rename applies **only to the `read` tool**. The `get_file` tool
keeps its `limit_bytes` and `offset_bytes` parameters because it has
no `limit` field to collide with. The `file_glob_search` tool is
unaffected.

### Files changed in this follow-up

- `my_include/tools.nim` — schema field `limit_bytes` → `max_bytes`,
  internal variable `limitBytes` → `maxBytes`, all `args.hasKey` checks
  and truncation messages updated. `safeParseToolArgs.knownKeys` array
  reordered (`max_bytes` before `limit`). `get_file` tool untouched.
- `my_include/system_prompt.yaml` — `Tool: read` description, JSON
  parameter list, and the "Read with byte cap" example updated to use
  `max_bytes`. `Tool: get_file` untouched.
- `webui/static/index.html` — JS `knownKeys` array updated to look for
  `max_bytes` in malformed-JSON fallback (must precede `limit` in the
  array to avoid prefix-substring matches).
