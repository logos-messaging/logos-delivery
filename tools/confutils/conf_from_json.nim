import std/[json, macros, options, strutils, tables]
import confutils, confutils/defs, confutils/std/net, results

# The shared JSON walker is `raises: []` so the messaging FFI parser (also
# `raises: []`) can build on it.
{.push raises: [].}

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
      let firstKey = jsonFields.getOrDefault(lowerKey)[0]
      return err(
        "Duplicate configuration option (case-insensitive): '" & firstKey & "' and '" &
          key & "'"
      )
    jsonFields[lowerKey] = (key, value)
  return ok(jsonFields)

proc unknownKeysError*(
    jsonFields: Table[string, (string, JsonNode)], prefix: string
): string =
  ## Format leftover JSON keys as an error message.
  var keys = newSeq[string]()
  for _, (jsonKey, _) in pairs(jsonFields):
    keys.add(jsonKey)
  return prefix & ": " & keys.join(", ")

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
  else:
    return err("expected scalar JSON value, got " & $node.kind)

proc parseScalarInto[U](
    jsonValue: JsonNode, confField, jsonKey, prefix: string
): Result[U, string] =
  ## Parse a scalar JSON value into `U` via confutils `parseCmdArg`, same as the CLI.
  let s = jsonScalarToString(jsonValue).valueOr:
    return
      err(prefix & " '" & confField & "' from JSON key '" & jsonKey & "': " & error)
  when U is Port:
    # `Port(0)` means "auto-allocate an ephemeral port" and is a valid value (see
    # PR #3828). confutils' `parseCmdArg(Port)` enforces the CLI range 1-65535 and
    # rejects "0", but the JSON config API must accept it, so handle 0 explicitly and
    # delegate every other value to confutils.
    if s == "0":
      return ok(Port(0))
  try:
    ok(parseCmdArg(U, s))
  except CatchableError as e:
    err(
      prefix & " '" & confField & "' from JSON key '" & jsonKey & "': " & e.msg &
        ". Value: " & s
    )

proc parseSeqInto[U](
    jsonValue: JsonNode, confField, jsonKey, prefix: string
): Result[seq[U], string] =
  ## Parse a JSON array into `seq[U]`, each element via `parseCmdArg`.
  if jsonValue.kind != JArray:
    return err(
      prefix & " '" & confField & "' from JSON key '" & jsonKey &
        "' must be a JSON array"
    )
  var res: seq[U]
  for item in jsonValue:
    let s = jsonScalarToString(item).valueOr:
      return
        err(prefix & " '" & confField & "' from JSON key '" & jsonKey & "': " & error)
    try:
      res.add(parseCmdArg(U, s))
    except CatchableError as e:
      return err(
        prefix & " '" & confField & "' from JSON key '" & jsonKey & "': " & e.msg &
          ". Value: " & s
      )
  ok(res)

proc applyJsonFieldsToConf*[T](
    conf: var T,
    jsonFields: var Table[string, (string, JsonNode)],
    parseErrPrefix: string,
    unknownErrPrefix: string,
): Result[void, string] =
  ## Write each conf field matched (case-insensitive) by name or CLI `name:` pragma.
  ## JSON `null` leaves the field unset; unknown or non-`parseCmdArg` keys error.
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
              jsonFields.getOrDefault(matchKey)[0] & "' and '" &
              jsonFields.getOrDefault(lowerCliName)[0] & "'"
          )
        matchKey = lowerCliName
    if matchKey != "":
      let (jsonKey, jsonValue) = jsonFields.getOrDefault(matchKey)
      if jsonValue.kind == JNull:
        # JSON null leaves the field unset; it keeps its default.
        jsonFields.del(matchKey)
      else:
        when confValue is Option:
          type Inner = typeof(confValue.get())
          when Inner is seq:
            type Elem = typeof(confValue.get()[0])
            when compiles(parseCmdArg(Elem, "")):
              confValue =
                some(?parseSeqInto[Elem](jsonValue, confField, jsonKey, parseErrPrefix))
              jsonFields.del(matchKey)
            else:
              return err("config option '" & jsonKey & "' cannot be set via JSON")
          else:
            when compiles(parseCmdArg(Inner, "")):
              confValue = some(
                ?parseScalarInto[Inner](jsonValue, confField, jsonKey, parseErrPrefix)
              )
              jsonFields.del(matchKey)
            else:
              return err("config option '" & jsonKey & "' cannot be set via JSON")
        elif confValue is seq:
          type Elem = typeof(confValue[0])
          when compiles(parseCmdArg(Elem, "")):
            confValue =
              ?parseSeqInto[Elem](jsonValue, confField, jsonKey, parseErrPrefix)
            jsonFields.del(matchKey)
          else:
            return err("config option '" & jsonKey & "' cannot be set via JSON")
        else:
          when compiles(parseCmdArg(typeof(confValue), "")):
            confValue = ?parseScalarInto[typeof(confValue)](
              jsonValue, confField, jsonKey, parseErrPrefix
            )
            jsonFields.del(matchKey)
          else:
            return err("config option '" & jsonKey & "' cannot be set via JSON")
  if jsonFields.len > 0:
    return err(unknownKeysError(jsonFields, unknownErrPrefix))
  ok()

{.pop.}
