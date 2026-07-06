{.push raises: [].}

import std/[json, options, strutils, tables]
import results

import tools/confutils/conf_from_json
import logos_delivery/api/messaging_conf
import logos_delivery/channels/reliable_channel_manager

type MessagingConfJson* = object
  mode*: WakuMode
  preset*: string
  messagingOverrides*: MessagingClientConf
  channelsOverrides*: ReliableChannelManagerConf

const
  # Lowercased, since `collectJsonFields` keys the object case-insensitively.
  KeyMode = "mode"
  KeyPreset = "preset"
  KeyMessagingOverrides = "messagingoverrides"
  KeyChannelsOverrides = "channelsoverrides"

proc parseMode(s: string): Result[WakuMode, string] =
  case s.strip().toLowerAscii()
  of "core":
    return ok(WakuMode.Core)
  of "edge":
    return ok(WakuMode.Edge)
  else:
    return err("invalid mode: '" & s & "' (expected 'Core' or 'Edge')")

proc parseOverrides[T](node: JsonNode, label: string): Result[T, string] =
  if node.kind != JObject:
    return err(label & " must be a JSON object")
  var fields = ?collectJsonFields(node)
  var conf = T()
  ?applyJsonFieldsToConf(
    conf,
    fields,
    "Failed to parse " & label & " field",
    "Unrecognized " & label & " option(s) found",
  )
  return ok(conf)

proc parseMessagingConf*(jsonStr: string): Result[MessagingConfJson, string] =
  var node: JsonNode
  try:
    node = parseJson(jsonStr)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("configuration JSON must be an object")

  var top = ?collectJsonFields(node)
  var conf = MessagingConfJson(mode: WakuMode.Core, preset: "")

  if top.hasKey(KeyMode):
    let (_, v) = top.getOrDefault(KeyMode)
    if v.kind != JString:
      return err("mode must be a string")
    conf.mode = ?parseMode(v.getStr())
    top.del(KeyMode)

  if top.hasKey(KeyPreset):
    let (_, v) = top.getOrDefault(KeyPreset)
    if v.kind != JString:
      return err("preset must be a string")
    conf.preset = v.getStr().strip()
    top.del(KeyPreset)

  if top.hasKey(KeyMessagingOverrides):
    let (_, v) = top.getOrDefault(KeyMessagingOverrides)
    conf.messagingOverrides =
      ?parseOverrides[MessagingClientConf](v, "messagingOverrides")
    top.del(KeyMessagingOverrides)

  if top.hasKey(KeyChannelsOverrides):
    let (_, v) = top.getOrDefault(KeyChannelsOverrides)
    conf.channelsOverrides =
      ?parseOverrides[ReliableChannelManagerConf](v, "channelsOverrides")
    top.del(KeyChannelsOverrides)

  if top.len > 0:
    var keys: seq[string]
    for _, (k, _) in pairs(top):
      keys.add(k)
    return err("Unrecognized configuration option(s) found: " & keys.join(", "))

  return ok(conf)

{.pop.}
