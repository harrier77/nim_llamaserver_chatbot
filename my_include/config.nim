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

type AppState* = enum
  Chatting,       ## Normal conversation mode
  SelectingModel  ## Model selection menu active

## Available slash commands
## EDIT: add here for new commands, then handle in input.nim
type SlashCommand* = object
  name*: string
  description*: string

const SlashCommands*: array[5, SlashCommand] = [
  SlashCommand(name: "/quit",   description: "Exit the application (also /q)"),
  SlashCommand(name: "/model",  description: "Change the current model"),
  SlashCommand(name: "/new",    description: "Reset conversation and start new chat"),
  SlashCommand(name: "/edit",   description: "Open file in micro editor"),
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

  # --- OpenCode remote server ---
  OpenCodeBaseUrl*: string = ""     # full URL from models.json (…/chat/completions)
  OpenCodeModelsUrl*: string = ""  # base URL for model listing (…/v1)
  OpenCodeApiKey*: string = ""
  OpenCodeEnabled*: bool = false
  OpenCodeModelIds*: seq[string] = @[]  # lista dei modelli OpenCode fetchati

  # --- Ollama remote server ---
  OllamaBaseUrl*: string = ""      # full URL from models.json (…/chat/completions)
  OllamaModelsUrl*: string = ""   # base URL for model listing (…/v1)
  OllamaApiKey*: string = ""
  OllamaEnabled*: bool = false
  OllamaModelIds*: seq[string] = @[]  # lista dei modelli Ollama

  # --- Model and history ---
  ModelName*: string = "Qwen3.5_0.8b-text"
  maxHistoryMessages*: int = 20

  # --- App state ---
  state*: AppState = Chatting
  availableModels*: seq[string] = @[]
  selectedMenuIndex*: int = 0

  # --- TUI output ---
  outputLines*: seq[string] = @[]

  # --- Input ---
  currentInput*: string = ""
  scrollOffset*: int = 0
  isProcessing*: bool = false
  aiResponseBuffer*: string = ""
  serverAvailable*: bool = true
  lastServerCheck*: float = 0.0
  showingSlashMenu*: bool = false
  slashMenuIndex*: int = 0

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
