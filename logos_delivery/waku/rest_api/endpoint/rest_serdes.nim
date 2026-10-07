{.push raises: [].}

import
  std/typetraits,
  std/os,
  std/options,
  results,
  chronicles,
  serialization,
  json_serialization,
  json_serialization/pkg/results,
  json_serialization/std/net,
  json_serialization/std/sets,
  presto/common

import ./serdes, ./responses

logScope:
  topics = "waku node rest"

proc encodeBytesOf*[T](value: T, contentType: string): RestResult[seq[byte]] =
  let reqContentType = MediaType.init(contentType)

  if reqContentType != MIMETYPE_JSON:
    error "Unsupported contentType value",
      contentType = contentType, typ = value.type.name
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc decodeJsonBody*[T](contentBody: Option[ContentBody]): Result[T, string] =
  ## Decodes the request body, the error is the reason the body is rejected.
  if contentBody.isNone():
    return err("Missing content body")

  let reqBodyContentType = contentBody.get().contentType.mediaType

  if reqBodyContentType != MIMETYPE_JSON and reqBodyContentType != MIMETYPE_TEXT:
    return err("Wrong Content-Type, expected application/json or text/plain")

  let requestResult = decodeJsonBytesWithReason(T, contentBody.get().data).valueOr:
    debug "could not decode the request body", reason = error
    return err("Invalid content body, could not decode: " & error)

  return ok(requestResult)

proc decodeRequestBody*[T](
    contentBody: Option[ContentBody]
): Result[T, RestApiResponse] =
  let decoded = decodeJsonBody[T](contentBody).valueOr:
    return err(RestApiResponse.badRequest(error))

  return ok(decoded)

proc decodeBytes*(
    t: typedesc[string], value: openarray[byte], contentType: Opt[ContentTypeData]
): RestResult[string] =
  if MediaType.init($contentType) != MIMETYPE_TEXT:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  var res: string
  if len(value) > 0:
    res = newString(len(value))
    copyMem(addr res[0], unsafeAddr value[0], len(value))
  return ok(res)

proc decodeBytes*[T](
    t: typedesc[T], data: openArray[byte], contentType: Opt[ContentTypeData]
): RestResult[T] =
  let reqContentType = contentType.valueOr:
    error "Unsupported response, missing contentType value"
    return err("Unsupported response, missing contentType")

  if reqContentType.mediaType != MIMETYPE_JSON and
      reqContentType.mediaType != MIMETYPE_TEXT:
    error "Unsupported response contentType value", contentType = contentType
    return err("Unsupported response contentType")

  let decoded = ?decodeFromJsonBytes(T, data)
  return ok(decoded)
