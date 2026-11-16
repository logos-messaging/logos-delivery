{.push raises: [].}

import
  std/json,
  results,
  chronicles,
  chronicles/topics_registry,
  chronos,
  presto/[client, common]

type NodeLocation* = object
  country*: string
  countryCode*: string
  city*: string
  lat*: string
  long*: string
  isp*: string

proc flatten*[T](a: seq[seq[T]]): seq[T] =
  var aFlat = newSeq[T](0)
  for subseq in a:
    aFlat &= subseq
  return aFlat

proc decodeBytes*(
    t: typedesc[NodeLocation], value: openArray[byte], contentType: Opt[ContentTypeData]
): RestResult[NodeLocation] =
  var res: string
  if len(value) > 0:
    res = newString(len(value))
    copyMem(addr res[0], unsafeAddr value[0], len(value))
    try:
      let jsonContent = parseJson(res)
      if $jsonContent["status"].getStr() != "success":
        error "query failed", result = $jsonContent
        return err("query failed")
      return ok(
        NodeLocation(
          country: jsonContent["country"].getStr(),
          countryCode: jsonContent{"countryCode"}.getStr(),
          city: jsonContent["city"].getStr(),
          lat: $jsonContent["lat"].getFloat(),
          long: $jsonContent["lon"].getFloat(),
          isp: jsonContent["isp"].getStr(),
        )
      )
    except Exception:
      return err("failed to get the location: " & getCurrentExceptionMsg())

func countryLabel*(countryCode: string): string =
  ## ISO 3166-1 alpha-2: two uppercase ASCII letters.
  if countryCode.len == 2 and countryCode[0] in {'A' .. 'Z'} and
      countryCode[1] in {'A' .. 'Z'}:
    return countryCode
  return "other"

proc encodeString*(value: string): RestResult[string] =
  ok(value)

proc ipToLocation*(
  ip: string
): RestResponse[NodeLocation] {.rest, endpoint: "json/{ip}", meth: MethodGet.}
