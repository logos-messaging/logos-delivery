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

proc takeString(
    fields: var Table[string, (string, JsonNode)], key: string
): Result[Opt[string], string] =
  ## Removes `key` from `fields` and returns its string value, if it is there.
  if not fields.hasKey(key):
    return ok(Opt.none(string))
  let (jsonKey, v) = fields.getOrDefault(key)
  if v.kind != JString:
    return err("config option must be a string: " & jsonKey)
  fields.del(key)
  return ok(Opt.some(v.getStr().strip()))

proc parseLogosDeliveryConf*(jsonStr: string): ConfResult[LogosDeliveryConf] =
  ## One flat object, with the keys of the `logosdeliverynode` CLI flags. Each
  ## key belongs to one layer: `entryLayer`, `mode` and `preset` select and shape
  ## the stack, messaging and channel fields go to those layers, and every other
  ## key is a kernel field. An explicit kernel field wins over the mode and the
  ## preset.
  var node: JsonNode
  try:
    node = parseJson(jsonStr)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("configuration JSON must be an object")

  var fields = ?collectJsonFields(node)

  let entryLayerStr = ?takeString(fields, KeyEntryLayer)
  let entryLayer =
    if entryLayerStr.isSome():
      ?parseEntryLayer(entryLayerStr.get())
    else:
      EntryLayer.channels
  let modeStr = ?takeString(fields, KeyMode)
  let mode =
    if modeStr.isSome():
      ?parseMode(modeStr.get())
    else:
      LogosDeliveryMode.Core
  let preset = (?takeString(fields, KeyPreset)).get("")

  let fieldCount = fields.len
  var messaging = MessagingClientConf()
  ?takeJsonFieldsIntoConf(messaging, fields, "Failed to parse messaging field")
  var channels = ReliableChannelManagerConf()
  ?takeJsonFieldsIntoConf(channels, fields, "Failed to parse channels field")

  if entryLayer == EntryLayer.kernel:
    if modeStr.isSome():
      return err("kernel entry layer takes no mode: mode is a messaging option")
    if fields.len != fieldCount:
      return err(
        "messaging and channel options need the 'messaging' or 'channels' entry layer"
      )
    var kernel = ?defaultKernelConf()
    kernel.preset = preset
    ?applyJsonFieldsToConf(
      kernel, fields, "Failed to parse config field",
      "Unrecognized configuration option(s) found",
    )
    return ok(LogosDeliveryConf.init(KernelConf(kernel)))

  var kernel = ?libraryKernelConf()
  ?applyJsonFieldsToConf(
    kernel, fields, "Failed to parse config field",
    "Unrecognized configuration option(s) found",
  )
  return LogosDeliveryConf.init(
    entryLayer = entryLayer,
    mode = mode,
    preset = preset,
    messagingOverrides = messaging,
    channelsOverrides = channels,
    kernelConf = Opt.some(KernelConf(kernel)),
  )

{.pop.}
