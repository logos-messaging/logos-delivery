import std/[json, strutils, tables]
import confutils, confutils/std/net, results
import ./cli_args
import ./messaging_conf

const
  KeyMode = "mode"
  KeyPreset = "preset"
  KeyOverrides = "overrides"
  KeyAdditions = "additions"

const CreateNodeWithOverridesExplicitKeys = [KeyMode, KeyPreset]
  ## Keys that map to explicit parameters of `createNode(preset, mode, ...)`,
  ## hence parsed at the messaging shape's top level and rejected inside
  ## `overrides`/`additions` to avoid ambiguity.

proc collectJsonFields*(
    jsonNode: JsonNode
): Result[Table[string, (string, JsonNode)], string] =
  ## Walk the top-level JSON object and key it by lowercased names.
  if jsonNode.kind != JObject:
    return err("config JSON must be a JSON object, got " & $jsonNode.kind)
  var jsonFields: Table[string, (string, JsonNode)]
  for key, value in jsonNode:
    let lowerKey = key.toLowerAscii()
    if jsonFields.hasKey(lowerKey):
      let firstKey = jsonFields[lowerKey][0]
      return err(
        "Duplicate configuration option (case-insensitive): '" & firstKey & "' and '" &
          key & "'"
      )
    jsonFields[lowerKey] = (key, value)
  return ok(jsonFields)

proc unknownKeysError(
    jsonFields: Table[string, (string, JsonNode)], prefix: string
): string =
  ## Format leftover JSON keys as an error message.
  var keys = newSeq[string]()
  for _, (jsonKey, _) in pairs(jsonFields):
    keys.add(jsonKey)
  return prefix & ": " & $keys

proc rejectOverridesExplicitKeys(
    node: JsonNode, blockName: string
): Result[void, string] =
  ## Error if `node` contains any key from `CreateNodeWithOverridesExplicitKeys`.
  for k, _ in node:
    if k.toLowerAscii() in CreateNodeWithOverridesExplicitKeys:
      return err("'" & k & "' must be a top-level key, not inside '" & blockName & "'")
  return ok()

proc rejectOverlayExcludes(node: JsonNode): Result[void, string] =
  ## Error if `node` contains any key from `WakuNodeConfOverlayExcludes`.
  for k, _ in node:
    if k.toLowerAscii() in WakuNodeConfOverlayExcludes:
      return err("'" & k & "' is not settable via JSON configuration")
  return ok()

proc jsonScalarToString(node: JsonNode): Result[string, string] =
  ## Convert a scalar JSON value to its string form.
  case node.kind
  of JString:
    return ok(node.getStr())
  of JInt:
    return ok($node.getInt())
  of JFloat:
    return ok($node.getFloat())
  of JBool:
    return ok($node.getBool())
  of JNull:
    return ok("")
  else:
    return err("expected scalar JSON value, got " & $node.kind)

proc applyJsonFieldsToConf(
    conf: var WakuNodeConf,
    jsonFields: var Table[string, (string, JsonNode)],
    parseErrPrefix: string,
    unknownErrPrefix: string,
): Result[void, string] =
  ## Walk `conf`'s fields and write each one matched (case-insensitive) by
  ## `jsonFields`. seq fields take a JArray (full replace); scalar fields
  ## take any scalar JSON kind. Errors on leftover unknown keys.
  for confField, confValue in fieldPairs(conf):
    let lowerField = confField.toLowerAscii()
    if jsonFields.hasKey(lowerField):
      let (jsonKey, jsonValue) = jsonFields[lowerField]
      when confValue is seq:
        if jsonValue.kind != JArray:
          return err(
            parseErrPrefix & " '" & confField & "' from JSON key '" & jsonKey &
              "' must be a JSON array"
          )
        var newSeq: typeof(confValue) = @[]
        for item in jsonValue:
          let formattedItem = jsonScalarToString(item).valueOr:
            return err(
              parseErrPrefix & " '" & confField & "' from JSON key '" & jsonKey & "': " &
                error
            )
          try:
            type ElemType = typeof(confValue[0])
            newSeq.add(parseCmdArg(ElemType, formattedItem))
          except CatchableError as e:
            return err(
              parseErrPrefix & " '" & confField & "' from JSON key '" & jsonKey & "': " &
                e.msg & ". Value: " & formattedItem
            )
        confValue = newSeq
      else:
        let formattedString = jsonScalarToString(jsonValue).valueOr:
          return err(
            parseErrPrefix & " '" & confField & "' from JSON key '" & jsonKey & "': " &
              error
          )
        try:
          confValue = parseCmdArg(typeof(confValue), formattedString)
        except CatchableError as e:
          return err(
            parseErrPrefix & " '" & confField & "' from JSON key '" & jsonKey & "': " &
              e.msg & ". Value: " & formattedString
          )
      jsonFields.del(lowerField)
  if jsonFields.len > 0:
    return err(unknownKeysError(jsonFields, unknownErrPrefix))
  return ok()

proc applyJsonAsOverride*(
    conf: var WakuNodeConf, overrides: JsonNode
): Result[void, string] =
  ## Apply `overrides` JSON onto `conf` with replace semantics for both scalars and lists.
  var jsonFields = ?collectJsonFields(overrides)
  return applyJsonFieldsToConf(
    conf, jsonFields, "Failed to parse override field",
    "Unrecognized override field(s) found",
  )

proc applyJsonAsAddition*(
    conf: var WakuNodeConf, additions: JsonNode
): Result[void, string] =
  ## Append JSON array in `additions` to `conf` seq fields.
  var jsonFields = ?collectJsonFields(additions)
  for confField, confValue in fieldPairs(conf):
    let lowerField = confField.toLowerAscii()
    if jsonFields.hasKey(lowerField):
      let (jsonKey, jsonValue) = jsonFields[lowerField]
      when confValue is seq:
        if jsonValue.kind != JArray:
          return err(
            "Addition field '" & confField & "' from JSON key '" & jsonKey &
              "' must be a JSON array"
          )
        for item in jsonValue:
          let formattedItem = jsonScalarToString(item).valueOr:
            return err(
              "Failed to parse addition item for field '" & confField & "': " & error
            )
          try:
            type ElemType = typeof(confValue[0])
            confValue.add(parseCmdArg(ElemType, formattedItem))
          except CatchableError as e:
            return err(
              "Failed to parse addition item for field '" & confField & "': " & e.msg &
                ". Value: " & formattedItem
            )
      else:
        return err(
          "Field '" & confField & "' from JSON key '" & jsonKey &
            "' is not a list and cannot be in additions"
        )
      jsonFields.del(lowerField)
  if jsonFields.len > 0:
    return err(unknownKeysError(jsonFields, "Unrecognized addition field(s) found"))
  return ok()

proc assembleMessagingConf*(
    jsonFields: Table[string, (string, JsonNode)]
): Result[WakuNodeConf, string] =
  ## Build a WakuNodeConf from the messaging shape
  ## `{mode, overrides, preset?, additions?}`. `mode` and `overrides` are
  ## required. Order: overrides applied first, then additions concat.
  var conf = ?defaultWakuNodeConf()
  var fields = jsonFields

  if not fields.hasKey(KeyMode):
    return err("messaging shape requires '" & KeyMode & "' key")
  if not fields.hasKey(KeyOverrides):
    return err("messaging shape requires '" & KeyOverrides & "' key")

  let modeStr = jsonScalarToString(fields[KeyMode][1]).valueOr:
    return err("Failed to parse '" & KeyMode & "': " & error)
  try:
    conf.mode = parseCmdArg(WakuMode, modeStr)
  except CatchableError as e:
    return err("Failed to parse '" & KeyMode & "': " & e.msg & ". Value: " & modeStr)
  fields.del(KeyMode)

  if fields.hasKey(KeyPreset):
    let presetStr = jsonScalarToString(fields[KeyPreset][1]).valueOr:
      return err("Failed to parse '" & KeyPreset & "': " & error)
    conf.preset = presetStr
    fields.del(KeyPreset)

  let overridesNode = fields[KeyOverrides][1]
  if overridesNode.kind != JObject:
    return err("'" & KeyOverrides & "' must be a JSON object")
  ?rejectOverlayExcludes(overridesNode)
  ?rejectOverridesExplicitKeys(overridesNode, KeyOverrides)
  ?applyJsonAsOverride(conf, overridesNode)
  fields.del(KeyOverrides)

  if fields.hasKey(KeyAdditions):
    let additionsNode = fields[KeyAdditions][1]
    if additionsNode.kind != JObject:
      return err("'" & KeyAdditions & "' must be a JSON object")
    ?rejectOverlayExcludes(additionsNode)
    ?rejectOverridesExplicitKeys(additionsNode, KeyAdditions)
    ?applyJsonAsAddition(conf, additionsNode)
    fields.del(KeyAdditions)

  if fields.len > 0:
    return
      err(unknownKeysError(fields, "Unrecognized top-level key(s) in messaging shape"))

  return ok(conf)

proc assembleFullConf*(
    jsonFields: Table[string, (string, JsonNode)]
): Result[WakuNodeConf, string] =
  ## Build a WakuNodeConf from a flat JSON object whose keys are WakuNodeConf field names.
  var conf = ?defaultWakuNodeConf()
  var fields = jsonFields
  ?applyJsonFieldsToConf(
    conf, fields, "Failed to parse field", "Unrecognized configuration option(s) found"
  )
  return ok(conf)

proc parseConfJson*(jsonStr: string): Result[WakuNodeConf, string] =
  ## Parse a JSON config, route to messaging or full-config shape based on
  ## whether `overrides` or `additions` fields are in the config object top-level.
  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(jsonStr)
  except CatchableError as e:
    return err("Failed to parse config JSON: " & e.msg)

  if jsonNode.kind == JObject:
    ?rejectOverlayExcludes(jsonNode)

  let jsonFields = ?collectJsonFields(jsonNode)
  let isMessagingShape =
    jsonFields.hasKey(KeyOverrides) or jsonFields.hasKey(KeyAdditions)
  if isMessagingShape:
    return assembleMessagingConf(jsonFields)
  else:
    return assembleFullConf(jsonFields)
