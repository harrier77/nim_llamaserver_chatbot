# ============================================================
# config.nim - Configuration, constants, types, global variables
# ============================================================
# BASE MODULE: does not import other local modules (only stdlib + my_include).
# All other modules import this one.
#
# WHEN TO EDIT:
# - New constant? → add in the "Constants" section
# - New global variable? → add in the "Global variables" section
# - New type? → add in the "Types" section
# - New slash command? → add to SlashCommands AND handle in input.nim
# ============================================================

import os, strutils, json, unicode
import system_prompt
import editor
export editor

# ============================================================
# 1. Layout and UI constants
# ============================================================

const
  InputBarHeight* = 5           ## Height of the input bar
  StatusBarHeight* = 1          ## Height of the status bar
  InputGap* = 2                 ## Blank lines between output and input bar
  MaxOutputLines* = 1000        ## Max lines kept in output history
  PromptChar* = "> "            ## Prompt prefix
  SlashMenuHeight* = 10         ## Max rows in slash command popup
  InputBufferDelay* = 30      ## ms to wait before flushing input buffer
  InputBufferThreshold* = 10   ## min chars to force flush (paste detection)

# ============================================================
# 2. File path constants
# ============================================================

const
  StatusFile* = "my_include/status.json"  ## State persistence file

# --- External config paths (~/.nim_chatbot/) ---
const
  NimChatbotDir*      = getHomeDir() / ".nim_chatbot"
  ExternalModelsFile* = NimChatbotDir / "models.json"
  AuthFile*           = NimChatbotDir / "auth.json"

# ============================================================
# 3. Default arguments for the llama.cpp server
#    EDIT: change here to modify startup parameters
# ============================================================

var LlamaServerArgs* = @[
  "--host", "0.0.0.0",
  "--models-preset", "config.ini",
  "--models-max", "1",
  "--no-warmup",
  "--parallel", "1",
  "--jinja"
]

# ============================================================
# 4. Types
# ============================================================

type
  AppState* = enum
    Chatting,       ## Normal conversation mode
    SelectingModel  ## Model selection menu active

  Provider* = object
    name*: string
    baseUrl*: string
    modelsUrl*: string
    apiKey*: string
    enabled*: bool
    modelIds*: seq[string]
    linesPerChunk*: int
    isRemote*: bool

## Available slash commands
## EDIT: add here for new commands, then handle in input.nim
type SlashCommand* = object
  name*: string
  description*: string

const SlashCommands*: array[7, SlashCommand] = [
  SlashCommand(name: "/quit",   description: "Exit the application (also /q)"),
  SlashCommand(name: "/model",  description: "Change the current model"),
  SlashCommand(name: "/new",    description: "Reset conversation and start new chat"),
  SlashCommand(name: "/history", description: "Set history length (also /h)"),
  SlashCommand(name: "/edit",   description: "Open file in micro editor"),
  SlashCommand(name: "/system", description: "Open system prompt in micro editor"),
  SlashCommand(name: "/read",   description: "Read a file into the chat output"),
]

# ============================================================
# 5. Global state variables (app-wide)
# ============================================================
# All variables shared across modules go HERE.
# Suffix * = exported (accessible from other modules).

var
  # --- Server ---
  ServerBaseUrl*: string = "http://localhost:8080"
  APIUrl*: string = "http://localhost:8080/v1/chat/completions"

  # --- Remote provider configs (loaded from ~/.nim_chatbot/) ---

  # --- Model and history ---
  ModelName*: string = "Qwen3.5_0.8b-text"
  maxHistoryMessages*: int = 20

  # --- App state ---
  state*: AppState = Chatting
  availableModels*: seq[string] = @[]

  # --- Unified providers ---
  providerList*: seq[Provider] = @[]

  # --- Model selection ---
  modelSelectionBuffer*: string = ""
  modelSelectionScroll*: int = 0
  modelMenuClickAreas*: seq[tuple[y: int, modelName: string]] = @[]

  # --- TUI output ---
  outputLines*: seq[string] = @[]

  # --- Input ---
  inputEditor*: Editor = initEditor()
  inputBuffer*: string = ""            ## Temporary buffer for incoming characters (paste support)
  lastInputCharTime*: float = 0.0       ## Timestamp of last character received
  scrollOffset*: int = 0
  isProcessing*: bool = false
  aiResponseBuffer*: string = ""
  serverAvailable*: bool = true
  lastServerCheck*: float = 0.0
  showingSlashMenu*: bool = false
  slashMenuIndex*: int = 0
  hoveredButton*: string = ""  # "new", "modelli", "quit", or "" for toolbar hover effect

  # --- Conversation ---
  conversationHistory*: seq[JsonNode] = @[
    %*{
      "role": "system",
      "content": SYSTEM_PROMPT
    }
  ]

# ============================================================
# 6. Helper procs
# ============================================================

proc updateServerUrl*(newUrl: string) =
  ## Updates ServerBaseUrl and recalculates APIUrl.
  ## IMPORTANT: use this proc instead of assigning ServerBaseUrl
  ## directly, so that APIUrl is updated automatically.
  ServerBaseUrl = newUrl
  APIUrl = ServerBaseUrl & "/v1/chat/completions"

proc resetConversation*() =
  ## Resets conversation history and output lines.
  ## EDIT: if anything else needs to be reset, add it here.
  conversationHistory = @[
    %*{
      "role": "system",
      "content": SYSTEM_PROMPT
    }
  ]
  outputLines = @[]
  aiResponseBuffer = ""
  scrollOffset = 0
  isProcessing = false
  inputEditor.setText("")

proc countRunes*(s: string): int =
  ## Returns the number of Unicode codepoints in s.
  result = 0
  for _ in s.runes:
    inc(result)

proc removeLastRune*(s: var string) =
  ## Removes the last Unicode character from s (handles UTF-8 correctly).
  if s.len == 0: return
  var i = s.len - 1
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec(i)
  s.setLen(i)

proc filterSlashCommands*(query: string): seq[int] =
  ## Returns the indices of SlashCommands that match the query.
  ## Used by input.nim (menu navigation) and ui.nim (menu rendering).
  result = @[]
  let q = strutils.strip(query).toLowerAscii()
  for i, cmd in SlashCommands:
    if cmd.name[1 .. ^1].startsWith(q) or cmd.name.toLowerAscii().contains(q):
      result.add(i)

proc wrapText*(text: string, maxWidth: int): seq[string] =
  ## Wraps text to fit within maxWidth columns.
  ## Handles UTF-8 correctly using runes.
  result = @[]
  if text.len == 0 or maxWidth <= 0:
    result.add("")
    return
  var currentLine = ""
  for rune in text.runes:
    let runeLen = if ord(rune) < 128: 1 else: 1  # Simple width estimate
    if countRunes(currentLine) + runeLen > maxWidth:
      if currentLine.len > 0:
        result.add(currentLine)
        currentLine = ""
    currentLine.add($rune)
  if currentLine.len > 0:
    result.add(currentLine)

proc findProviderForModel*(modelName: string): Provider =
  ## Returns the provider that owns the given model name.
  if providerList.len == 0:
    return Provider(name: "llamacpp", baseUrl: APIUrl, modelsUrl: ServerBaseUrl, isRemote: false, enabled: true, linesPerChunk: 0)
  for p in providerList:
    if p.enabled:
      for mId in p.modelIds:
        if mId == modelName:
          return p
  for p in providerList:
    if p.enabled:
      return p
  return providerList[0]

proc hasRemoteProvider*(): bool =
  for p in providerList:
    if p.enabled and p.isRemote:
      return true
