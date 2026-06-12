import std/[json, options, strutils]
import results

proc getProtoInt64*(node: JsonNode, key: string): Result[Option[int64], string] =
  try:
    let (value, ok) =
      if node.hasKey(key):
        if node[key].kind == JString:
          (parseBiggestInt(node[key].getStr()), true)
        else:
          (node[key].getBiggestInt(), true)
      else:
        (0, false)

    if ok:
      return ok(some(value))

    return ok(none(int64))
  except CatchableError:
    return err("Invalid int64 value in `" & key & "`")
