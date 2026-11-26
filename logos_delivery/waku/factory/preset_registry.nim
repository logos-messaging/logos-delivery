## Network preset registry: the built-in presets plus the ones a host registers
## at runtime with `registerPreset`.
##
## A registered preset is a `NetworkPresetConf` in JSON, keyed by its field
## names. `shardingConf` is a list of shard ids for auto-sharding, or "static";
## `rlnRelayChainId` is an integer. A built-in preset cannot be replaced.
##
## The registry is process-wide and safe to use from any thread. A preset takes
## effect for nodes created after it is registered.

{.push raises: [].}

import std/[locks, strutils, tables]
import results, stint, json_serialization
import json_serialization/std/tables as json_tables
import
  logos_delivery/waku/factory/networks_config,
  logos_delivery/waku/common/utils/parse_size_units

export networks_config

type
  Registry = Table[string, string]

  PresetCtor = proc(): NetworkPresetConf {.nimcall, gcsafe, raises: [].}

proc twn(): NetworkPresetConf =
  NetworkPresetConf.TheWakuNetworkConf()

proc logosDev(): NetworkPresetConf =
  NetworkPresetConf.LogosDevConf()

proc logosTest(): NetworkPresetConf =
  NetworkPresetConf.LogosTestConf()

proc statusProd(): NetworkPresetConf =
  NetworkPresetConf.StatusProdConf()

proc statusStaging(): NetworkPresetConf =
  NetworkPresetConf.StatusStagingConf()

const
  BuiltinPresets: array[5, (string, PresetCtor)] = [
    ("twn", twn),
    ("logos.dev", logosDev),
    ("logos.test", logosTest),
    ("status.prod", statusProd),
    ("status.staging", statusStaging),
  ]

  PresetAliases = [
    ("logosdev", "logos.dev"),
    ("logostest", "logos.test"),
    ("statusprod", "status.prod"),
    ("statusstaging", "status.staging"),
  ]

var
  registryLock: Lock
  registryBuf: ptr UncheckedArray[char]
  registryLen: int

initLock(registryLock)

proc readValue*(
    r: var JsonReader, value: var UInt256
) {.raises: [IOError, SerializationError].} =
  value = r.readValue(uint64).u256

proc readValue*(
    r: var JsonReader, value: var ShardingConf
) {.raises: [IOError, SerializationError].} =
  if r.tokKind == JsonValueKind.String:
    if r.readValue(string) != "static":
      r.raiseUnexpectedValue("shardingConf must be a list of shard ids or \"static\"")
    value = ShardingConf(kind: StaticSharding)
  else:
    value = ShardingConf.autoSharding(r.readValue(seq[uint16]))

proc canonicalPresetName*(name: string): string =
  ## Lower-cased, trimmed, with an alias resolved to the name it stands for.
  let lc = name.strip().toLowerAscii()
  for (alias, canonical) in PresetAliases:
    if lc == alias:
      return canonical
  return lc

proc builtinPreset(name: string): Opt[PresetCtor] =
  for (builtinName, ctor) in BuiltinPresets:
    if name == builtinName:
      return Opt.some(ctor)
  return Opt.none(PresetCtor)

proc decodeJson(T: type, raw, what: string): Result[T, string] =
  try:
    return ok(Json.decode(raw, T))
  except SerializationError as e:
    return err(e.formatMsg(what))

proc decodePreset(name, presetJson: string): Result[NetworkPresetConf, string] =
  let conf = ?decodeJson(NetworkPresetConf, presetJson, "preset '" & name & "'")
  discard ?parseMsgSize(conf.maxMessageSize)
  if conf.shardingConf.kind == AutoSharding and conf.shardingConf.shards.len == 0:
    return err("preset '" & name & "' must set shardingConf")
  return ok(conf)

proc readRegistry(): Result[Registry, string] =
  ## Must be called with `registryLock` held.
  if registryLen == 0:
    return ok(Registry())
  var raw = newString(registryLen)
  copyMem(addr raw[0], registryBuf, registryLen)
  return decodeJson(Registry, raw, "preset registry")

proc writeRegistry(registry: Registry): Result[void, string] =
  ## Must be called with `registryLock` held.
  let raw =
    try:
      Json.encode(registry)
    except SerializationError as e:
      return err("cannot encode the preset registry: " & e.msg)
  if not registryBuf.isNil():
    deallocShared(registryBuf)
  registryBuf = cast[ptr UncheckedArray[char]](allocShared(raw.len))
  copyMem(registryBuf, unsafeAddr raw[0], raw.len)
  registryLen = raw.len
  return ok()

template withRegistry(body: untyped) =
  acquire(registryLock)
  try:
    body
  finally:
    release(registryLock)

proc registerPreset*(name: string, presetJson: string): Result[void, string] =
  ## Adds the preset `name`, or replaces a preset registered under that name.
  ## `presetJson` is a complete `NetworkPresetConf`; a field it leaves out is
  ## zero or empty, except `maxMessageSize` and `shardingConf`, which it must
  ## set. Fails, leaving the registry unchanged, on an invalid preset or on the
  ## name of a built-in preset.
  let canonical = canonicalPresetName(name)
  if canonical.len == 0:
    return err("preset name must not be empty")
  if builtinPreset(canonical).isSome():
    return err("'" & canonical & "' is a built-in preset; register it under a new name")
  discard ?decodePreset(canonical, presetJson)

  withRegistry:
    var registry = ?readRegistry()
    registry[canonical] = presetJson
    ?writeRegistry(registry)
  return ok()

proc lookupPreset*(name: string): Result[Opt[NetworkPresetConf], string] =
  ## The preset `name` resolves to, built-in or registered. An empty name is no
  ## preset.
  let canonical = canonicalPresetName(name)
  if canonical.len == 0:
    return ok(Opt.none(NetworkPresetConf))
  let ctor = builtinPreset(canonical)
  if ctor.isSome():
    return ok(Opt.some(ctor.get()()))

  var presetJson = Opt.none(string)
  withRegistry:
    let registry = ?readRegistry()
    if registry.hasKey(canonical):
      presetJson = Opt.some(registry.getOrDefault(canonical))
  if presetJson.isNone():
    return err("Invalid --preset value passed: " & canonical)
  return ok(Opt.some(?decodePreset(canonical, presetJson.get())))

{.pop.}
