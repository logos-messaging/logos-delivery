## RLN presets: which network turns RLN on, and with what. Mirrors the
## delivery module's `rln_presets.cpp`: three built-ins (all off) plus a table
## from `$LOGOS_DELIVERY_RLN_PRESETS` (a JSON file mapping preset name to
## `{"enabled", "registry-id", "rln-identifier", "epoch-size-sec",
## "max-epoch-gap", "enable-validation"}`), which overrides by name.

import std/[json, os, tables]
import results

const
  RlnPresetsEnvVar* = "LOGOS_DELIVERY_RLN_PRESETS"
  LogosDeliveryRlnIdentifier* =
    "5e269b6a19fce081f5808b13442dcbc3522197638dd38df5a28bc4e55236b977"

type RlnPreset* = object
  enabled*: bool
  enableValidation*: bool
  registryId*: string
  rlnIdentifier*: string
  epochSizeSec*: uint64
  maxEpochGap*: uint64

proc builtin(): Table[string, RlnPreset] =
  let off = RlnPreset(enabled: false, enableValidation: true, rlnIdentifier: LogosDeliveryRlnIdentifier)
  return {"": off, "logos.dev": off, "logos.test": off}.toTable()

proc parseTable*(doc: string): Result[Table[string, RlnPreset], string] =
  var root: JsonNode
  try:
    root = parseJson(doc)
  except CatchableError:
    return err("not valid JSON")
  if root.kind != JObject:
    return err("not a JSON object")
  var table = initTable[string, RlnPreset]()
  for name, value in root.pairs:
    if value.kind != JObject:
      return err("preset \"" & name & "\" is not an object")
    var e = RlnPreset(enableValidation: true, rlnIdentifier: LogosDeliveryRlnIdentifier)
    e.enabled = value.getOrDefault("enabled").getBool(false)
    if value.hasKey("enable-validation"):
      e.enableValidation = value["enable-validation"].getBool(true)
    e.registryId = value.getOrDefault("registry-id").getStr("")
    let ident = value.getOrDefault("rln-identifier").getStr("")
    if ident.len > 0:
      e.rlnIdentifier = ident
    e.epochSizeSec = uint64(value.getOrDefault("epoch-size-sec").getBiggestInt(0))
    e.maxEpochGap = uint64(value.getOrDefault("max-epoch-gap").getBiggestInt(0))
    if e.enabled:
      if e.registryId.len == 0:
        return err("preset \"" & name & "\" needs registry-id")
      if e.epochSizeSec == 0:
        return err("preset \"" & name & "\" needs a positive epoch-size-sec")
    table[name] = e
  return ok(table)

proc resolveRlnPreset*(name: string): Result[RlnPreset, string] =
  ## The preset for `name`: a built-in, or an entry of the table the
  ## environment names. An unknown name is RLN off.
  var table = builtin()
  let path = getEnv(RlnPresetsEnvVar)
  if path.len > 0:
    var doc: string
    try:
      doc = readFile(path)
    except CatchableError as e:
      return err(RlnPresetsEnvVar & ": cannot open " & path & ": " & e.msg)
    let extra = parseTable(doc).valueOr:
      return err(RlnPresetsEnvVar & " (" & path & "): " & error)
    for k, v in extra.pairs:
      table[k] = v
  return ok(table.getOrDefault(name, RlnPreset(enableValidation: true)))
