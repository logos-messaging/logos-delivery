{.push raises: [].}

import std/[json, strutils, tables]
import results

import tools/confutils/conf_from_json
import logos_delivery/api/conf/[logos_delivery_conf, modes]

const
  # Lowercased, since `collectJsonFields` keys the object case-insensitively.
  KeyEntryLayer = "entrylayer"
  KeyMode = "mode"
  KeyPreset = "preset"
  KeyKernelConf = "kernelconf"
  KeyMessagingOverrides = "messagingoverrides"
  KeyChannelsOverrides = "channelsoverrides"
  # [Legacy flat JSON config] Keys that left the kernel and so must be lifted out of
  # a flat blob before the WakuNodeConf walker sees them (it would reject them).
  KeyReliabilityEnabled = "reliabilityenabled"
  KeyReliability = "reliability"
  KeyAnonymityLevel = "anonymitylevel"
  KeyAnonymityLevelSwitch = "anonymity-level"

proc parseMode(s: string): Result[LogosDeliveryMode, string] =
  case s.strip().toLowerAscii()
  of "core":
    return ok(LogosDeliveryMode.Core)
  of "edge":
    return ok(LogosDeliveryMode.Edge)
  else:
    return err("invalid mode: '" & s & "' (expected 'Core' or 'Edge')")

proc parseEntryLayer(s: string): Result[EntryLayer, string] =
  case s.strip().toLowerAscii()
  of "kernel":
    return ok(EntryLayer.kernel)
  of "messaging":
    return ok(EntryLayer.messaging)
  of "channels":
    return ok(EntryLayer.channels)
  else:
    return err(
      "invalid entryLayer: '" & s & "' (expected 'kernel', 'messaging' or 'channels')"
    )

proc parseOverrides[T](defaults: T, node: JsonNode, label: string): Result[T, string] =
  ## Parse the JSON object `node` as overrides on top of `defaults`.
  if node.kind != JObject:
    return err(label & " must be a JSON object")
  var fields = ?collectJsonFields(node)
  var conf = defaults
  ?applyJsonFieldsToConf(
    conf,
    fields,
    "Failed to parse " & label & " field",
    "Unrecognized " & label & " option(s) found",
  )
  return ok(conf)

proc parseFlatConf(
    mode: LogosDeliveryMode, topJsonNode: var Table[string, (string, JsonNode)]
): ConfResult[LogosDeliveryConf] =
  ## [Legacy flat JSON config] Flat shape: a blob of `WakuNodeConf` fields. `mode`
  ## expands to protocol flags over raw kernel defaults, `reliabilityEnabled` routes
  ## to the messaging conf (it left the kernel), and the rest parses as a
  ## `WakuNodeConf`. Full stack. Delete this proc and its call site to drop support.
  var messaging = MessagingClientConf()
  var messagingFields: Table[string, (string, JsonNode)]
  for key in [
    KeyReliabilityEnabled, KeyReliability, KeyAnonymityLevel, KeyAnonymityLevelSwitch
  ]:
    if topJsonNode.hasKey(key):
      messagingFields[key] = topJsonNode.getOrDefault(key)
      topJsonNode.del(key)
  if messagingFields.len > 0:
    ?applyJsonFieldsToConf(
      messaging, messagingFields, "Failed to parse messaging field",
      "Unrecognized messaging option(s) found",
    )

  # [Legacy flat JSON config] The blob is a raw WakuNodeConf, exactly as the
  # pre-refactor flat create_node parsed it: start from the kernel defaults and apply
  # the mode's protocol flags (the kernel no longer owns `mode`, so we expand it here,
  # like the old kernel builder did), then let explicit fields override.
  var kernel = ?defaultKernelConf(modeFlags = ModeProtocolFlags())
  applyMode(kernel, mode)
  ?applyJsonFieldsToConf(
    kernel, topJsonNode, "Failed to parse config field",
    "Unrecognized configuration option(s) found",
  )
  applyModeFlags(kernel, DefaultKernelModeFlags)

  # [Legacy flat JSON config] Reliability is resolved from the preset by the messaging
  # layer (the kernel no longer carries it), so a flat blob's `preset` must lift it
  # here to stay faithful to master. An explicit reliability in the blob still wins.
  if kernel.preset.len > 0:
    messaging = merge(?resolvePreset(kernel.preset), messaging)

  return LogosDeliveryConf.init(
    KernelConf(kernel), messaging, Opt.some(ReliableChannelManagerConf())
  )

proc parseLogosDeliveryConf*(jsonStr: string): ConfResult[LogosDeliveryConf] =
  ## Top-level keys configure the layers above the kernel: `entryLayer`, `mode`,
  ## `preset`, `messagingOverrides` and `channelsOverrides`. `kernelConf` is a
  ## flat object of kernel fields; they win over what the mode, the preset and
  ## the messaging overrides set in the kernel.
  var node: JsonNode
  try:
    node = parseJson(jsonStr)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("configuration JSON must be an object")

  var top = ?collectJsonFields(node)

  var kernelFields: Table[string, (string, JsonNode)]
  let hasKernelConf = top.hasKey(KeyKernelConf)
  if hasKernelConf:
    let (_, v) = top.getOrDefault(KeyKernelConf)
    if v.kind != JObject:
      return err("kernelConf must be a JSON object")
    kernelFields = ?collectJsonFields(v)
    top.del(KeyKernelConf)

  if kernelFields.hasKey(KeyPreset):
    return err("preset is a top-level option, not a kernelConf field")

  var mode = LogosDeliveryMode.Core
  let modeSet = top.hasKey(KeyMode)
  if modeSet:
    let (_, v) = top.getOrDefault(KeyMode)
    if v.kind != JString:
      return err("mode must be a string")
    mode = ?parseMode(v.getStr())
    top.del(KeyMode)

  var entryLayer = EntryLayer.channels
  if top.hasKey(KeyEntryLayer):
    let (_, v) = top.getOrDefault(KeyEntryLayer)
    if v.kind != JString:
      return err("entryLayer must be a string")
    entryLayer = ?parseEntryLayer(v.getStr())
    top.del(KeyEntryLayer)

  if entryLayer == EntryLayer.kernel:
    # Kernel-only: kernelConf alone, no upper layers.
    if modeSet:
      return err("kernel entry layer takes no mode: mode is a messaging option")
    if top.len > 0:
      return err(
        unknownKeysError(top, "kernel entry layer takes only 'kernelConf'; unexpected")
      )
    var kernel = ?defaultKernelConf()
    ?applyJsonFieldsToConf(
      kernel, kernelFields, "Failed to parse kernelConf field",
      "Unrecognized kernelConf option(s) found",
    )
    return ok(LogosDeliveryConf.init(KernelConf(kernel)))

  # [Legacy flat JSON config] A wrapper key marks our structured shape. Otherwise any
  # leftover top-level key besides `preset` (mode is already consumed) is a bare
  # kernel field -> flat blob. Delete this block to drop flat-shape support.
  let hasWrapper =
    top.hasKey(KeyMessagingOverrides) or top.hasKey(KeyChannelsOverrides) or
    hasKernelConf
  if not hasWrapper:
    var bareField = false
    for k in top.keys:
      if k != KeyPreset:
        bareField = true
        break
    if bareField:
      return parseFlatConf(mode, top)

  var preset = ""
  var messagingOverrides = MessagingClientConf()
  var channelsOverrides = ReliableChannelManagerConf()

  if top.hasKey(KeyPreset):
    let (_, v) = top.getOrDefault(KeyPreset)
    if v.kind != JString:
      return err("preset must be a string")
    preset = v.getStr().strip()
    top.del(KeyPreset)

  if top.hasKey(KeyMessagingOverrides):
    let (_, v) = top.getOrDefault(KeyMessagingOverrides)
    messagingOverrides = ?parseOverrides(MessagingClientConf(), v, "messagingOverrides")
    top.del(KeyMessagingOverrides)

  if top.hasKey(KeyChannelsOverrides):
    let (_, v) = top.getOrDefault(KeyChannelsOverrides)
    channelsOverrides =
      ?parseOverrides(ReliableChannelManagerConf(), v, "channelsOverrides")
    top.del(KeyChannelsOverrides)

  if top.len > 0:
    return err(unknownKeysError(top, "Unrecognized configuration option(s) found"))

  let messaging = merge(?resolvePreset(preset), messagingOverrides)
  var kernel = ?toWakuNodeConf(messaging, mode)
  kernel.preset = preset
  ?applyJsonFieldsToConf(
    kernel, kernelFields, "Failed to parse kernelConf field",
    "Unrecognized kernelConf option(s) found",
  )

  return LogosDeliveryConf.init(
    KernelConf(kernel),
    messaging,
    if entryLayer == EntryLayer.channels:
      Opt.some(channelsOverrides)
    else:
      Opt.none(ReliableChannelManagerConf),
  )

{.pop.}
