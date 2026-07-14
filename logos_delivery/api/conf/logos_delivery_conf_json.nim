{.push raises: [].}

import std/[json, strutils, tables]
import results

import tools/confutils/conf_from_json
import logos_delivery/api/conf/logos_delivery_conf

const
  # Lowercased, since `collectJsonFields` keys the object case-insensitively.
  KeyMode = "mode"
  KeyPreset = "preset"
  KeyKernelConf = "kernelconf"
  KeyMessagingOverrides = "messagingoverrides"
  KeyChannelsOverrides = "channelsoverrides"
  # [Legacy flat JSON config] Keys that left the kernel and so must be lifted out of
  # a flat blob before the WakuNodeConf walker sees them (it would reject them).
  KeyReliabilityEnabled = "reliabilityenabled"
  KeyReliability = "reliability"

proc parseMode(s: string): Result[LogosDeliveryMode, string] =
  case s.strip().toLowerAscii()
  of "core":
    return ok(LogosDeliveryMode.Core)
  of "edge":
    return ok(LogosDeliveryMode.Edge)
  of "fleet":
    return ok(LogosDeliveryMode.Fleet)
  else:
    return err("invalid mode: '" & s & "' (expected 'Core', 'Edge' or 'Fleet')")

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
  var reliabilityFields: Table[string, (string, JsonNode)]
  for key in [KeyReliabilityEnabled, KeyReliability]:
    if topJsonNode.hasKey(key):
      reliabilityFields[key] = topJsonNode.getOrDefault(key)
      topJsonNode.del(key)
  if reliabilityFields.len > 0:
    ?applyJsonFieldsToConf(
      messaging, reliabilityFields, "Failed to parse reliability field",
      "Unrecognized reliability option(s) found",
    )

  # [Legacy flat JSON config] The blob is a raw WakuNodeConf, exactly as the
  # pre-refactor flat create_node parsed it: start from the kernel defaults and apply
  # the mode's protocol flags (the kernel no longer owns `mode`, so we expand it here,
  # like the old kernel builder did), then let explicit fields override.
  var kernel = ?defaultWakuNodeConf()
  ?applyMode(kernel, mode)
  ?applyJsonFieldsToConf(
    kernel, topJsonNode, "Failed to parse config field",
    "Unrecognized configuration option(s) found",
  )

  # [Legacy flat JSON config] Reliability is resolved from the preset by the messaging
  # layer (the kernel no longer carries it), so a flat blob's `preset` must lift it
  # here to stay faithful to master. An explicit reliability in the blob still wins.
  if kernel.preset.len > 0:
    messaging = merge(?resolvePreset(kernel.preset), messaging)

  return ok(
    LogosDeliveryConf(
      kernelConf: KernelConf(kernel),
      messagingConf: Opt.some(messaging),
      channelsConf: Opt.some(ReliableChannelManagerConf()),
    )
  )

proc parseLogosDeliveryConf*(jsonStr: string): ConfResult[LogosDeliveryConf] =
  var node: JsonNode
  try:
    node = parseJson(jsonStr)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("configuration JSON must be an object")

  var top = ?collectJsonFields(node)

  var mode = LogosDeliveryMode.Core
  if top.hasKey(KeyMode):
    let (_, v) = top.getOrDefault(KeyMode)
    if v.kind != JString:
      return err("mode must be a string")
    mode = ?parseMode(v.getStr())
    top.del(KeyMode)

  if mode == LogosDeliveryMode.Fleet:
    # Kernel-only: a raw kernelConf and no upper layers.
    if not top.hasKey(KeyKernelConf):
      return err("fleet mode requires a 'kernelConf' object")
    let (_, v) = top.getOrDefault(KeyKernelConf)
    let kernel = ?parseOverrides(?defaultWakuNodeConf(), v, "kernelConf")
    top.del(KeyKernelConf)
    if top.len > 0:
      return
        err(unknownKeysError(top, "fleet mode takes only 'kernelConf'; unexpected"))
    return ok(LogosDeliveryConf.init(KernelConf(kernel)))

  # [Legacy flat JSON config] A wrapper key marks our structured shape. Otherwise any
  # leftover top-level key besides `preset` (mode is already consumed) is a bare
  # kernel field -> flat blob. Delete this block to drop flat-shape support.
  let hasWrapper =
    top.hasKey(KeyMessagingOverrides) or top.hasKey(KeyChannelsOverrides) or
    top.hasKey(KeyKernelConf)
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

  return LogosDeliveryConf.init(mode, preset, messagingOverrides, channelsOverrides)

{.pop.}
