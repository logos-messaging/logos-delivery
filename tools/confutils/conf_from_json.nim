import std/[json, macros, strutils, tables]
import confutils, confutils/defs, confutils/std/net, results
import ./cli_args

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
    # Match a field by its name or by its CLI name: pragma; case-insensitive.
    var matchKey = ""
    let lowerField = confField.toLowerAscii()
    if jsonFields.hasKey(lowerField):
      matchKey = lowerField
    when confValue.hasCustomPragma(defs.name):
      let lowerCliName = confValue.getCustomPragmaVal(defs.name).toLowerAscii()
      if lowerCliName != lowerField and jsonFields.hasKey(lowerCliName):
        if matchKey != "": # field-name form already present: set twice
          return err(
            "config option '" & confField & "' was set twice, via '" &
              jsonFields[matchKey][0] & "' and '" & jsonFields[lowerCliName][0] & "'"
          )
        matchKey = lowerCliName
    if matchKey != "":
      let (jsonKey, jsonValue) = jsonFields[matchKey]
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
      jsonFields.del(matchKey)
  if jsonFields.len > 0:
    return err(unknownKeysError(jsonFields, unknownErrPrefix))
  return ok()

proc assembleFullConf*(
    jsonFields: Table[string, (string, JsonNode)]
): Result[WakuNodeConf, string] =
  ## Build a WakuNodeConf from a flat JSON object whose keys are WakuNodeConf field
  ## names or their CLI `name:` pragma equivalents.
  var conf = ?defaultWakuNodeConf()
  var fields = jsonFields
  ?applyJsonFieldsToConf(
    conf, fields, "Failed to parse field", "Unrecognized configuration option(s) found"
  )
  return ok(conf)

proc parseNodeConfFromJson*(jsonStr: string): Result[WakuNodeConf, string] =
  ## Parse a flat JSON config whose keys are WakuNodeConf field names or their CLI
  ## `name:` pragma equivalents.
  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(jsonStr)
  except CatchableError as e:
    return err("Failed to parse config JSON: " & e.msg)

  let jsonFields = ?collectJsonFields(jsonNode)
  return assembleFullConf(jsonFields)
