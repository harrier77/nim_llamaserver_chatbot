import os, json, strutils
import config

proc loadProvidersConfig*() =
  providerList = @[]

  var foundLlamacppInJson = false

  if fileExists(ExternalModelsFile) and fileExists(AuthFile):
    try:
      let modelsContent = readFile(ExternalModelsFile)
      let modelsJson = parseJson(modelsContent)
      let authContent = readFile(AuthFile)
      let authJson = parseJson(authContent)

      if modelsJson.hasKey("providers"):
        for provName, provVal in modelsJson["providers"]:
          let baseUrl = provVal{"baseUrl"}.getStr("")
          if baseUrl.len == 0: continue

          if provName == "llamacpp":
            foundLlamacppInJson = true

          let apiKey = authJson{provName}{"key"}.getStr(provVal{"apiKey"}.getStr(""))

          var chatUrl = baseUrl
          if not chatUrl.endsWith("/chat/completions"):
            if chatUrl.endsWith("/v1"):
              chatUrl &= "/chat/completions"
            elif chatUrl.endsWith("/"):
              chatUrl &= "chat/completions"
            else:
              chatUrl &= "/chat/completions"

          var modelIds: seq[string] = @[]
          if provVal.hasKey("models"):
            for m in provVal["models"]:
              modelIds.add(m.getStr())

          providerList.add(Provider(
            name: provName,
            baseUrl: chatUrl,
            modelsUrl: baseUrl,
            apiKey: apiKey,
            enabled: apiKey.len > 0,
            modelIds: modelIds,
            linesPerChunk: if provName == "opencode": 3 else: 1,
            isRemote: true
          ))
    except:
      discard

  # Fallback: add hardcoded llamacpp only if not defined in models.json
  if not foundLlamacppInJson:
    providerList.add(Provider(
      name: "llamacpp",
      baseUrl: APIUrl,
      modelsUrl: ServerBaseUrl,
      apiKey: "",
      enabled: true,
      modelIds: @[],
      linesPerChunk: 0,
      isRemote: false
    ))
