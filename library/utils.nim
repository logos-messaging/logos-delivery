import std/[json, strutils]
import results

proc getProtoInt64*(node: JsonNode, key: string): Result[Opt[int64], string] =
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
      return ok(Opt.some(value))

    return ok(Opt.none(int64))
  except CatchableError:
    return err("Invalid int64 value in `" & key & "`")
