{.push raises: [].}

import std/json, results
import logos_delivery/api/types, ./utils

proc readTime(node: JsonNode, key: string): Result[Opt[Timestamp], string] =
  ## A time is a JSON integer, or a string that holds one, and a null is no value.
  let value = node.getOrDefault(key)
  if not value.isNil() and value.kind notin {JInt, JString, JNull}:
    return err("`" & key & "` must be an integer or a string")
  return node.getProtoInt64(key)

proc parseHistoryQuery*(queryJson: string): Result[HistoryQuery, string] =
  ## Reads `{"contentTopic": "...", "startTime": <ns>, "endTime": <ns>}`.
  ## `endTime` is optional.
  let parsed = catch:
    parseJson(queryJson)
  let node = parsed.valueOr:
    return err("Failed to parse query JSON: " & error.msg)
  if node.kind != JObject:
    return err("The query JSON must be an object")
  let topic = node.getOrDefault("contentTopic")
  if topic.isNil() or topic.kind != JString:
    return err("Missing contentTopic field")
  let startTime = (?node.readTime("startTime")).valueOr:
    return err("Missing startTime field")
  let endTime = ?node.readTime("endTime")
  return ok(HistoryQuery.init(ContentTopic(topic.getStr()), startTime, endTime))

{.pop.}
