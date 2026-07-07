{.push raises: [].}

import std/[json, options, strutils, tables]
import results

import tools/confutils/conf_from_json
import logos_delivery/api/logos_delivery_conf

const
  # Lowercased, since `collectJsonFields` keys the object case-insensitively.
  KeyMode = "mode"
  KeyPreset = "preset"
  KeyKernelConf = "kernelconf"
  KeyMessagingOverrides = "messagingoverrides"
  KeyChannelsOverrides = "channelsoverrides"

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
