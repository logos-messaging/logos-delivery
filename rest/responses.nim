{.push raises: [].}

import std/typetraits, results, chronicles, presto/common
import ./serdes

const MIMETYPE_JSON* = MediaType.init("application/json")
const MIMETYPE_TEXT* = MediaType.init("text/plain")

proc ok*(t: typedesc[RestApiResponse]): RestApiResponse =
  RestApiResponse.response("OK", Http200, $MIMETYPE_TEXT)

proc internalServerError*(
    t: typedesc[RestApiResponse], msg: string = ""
): RestApiResponse =
  RestApiResponse.error(Http500, msg, $MIMETYPE_TEXT)

proc serviceUnavailable*(
    t: typedesc[RestApiResponse], msg: string = ""
): RestApiResponse =
  RestApiResponse.error(Http503, msg, $MIMETYPE_TEXT)

proc badRequest*(t: typedesc[RestApiResponse], msg: string = ""): RestApiResponse =
  RestApiResponse.error(Http400, msg, $MIMETYPE_TEXT)

proc notFound*(t: typedesc[RestApiResponse], msg: string = ""): RestApiResponse =
  RestApiResponse.error(Http404, msg, $MIMETYPE_TEXT)

proc preconditionFailed*(
    t: typedesc[RestApiResponse], msg: string = ""
): RestApiResponse =
  RestApiResponse.error(Http412, msg, $MIMETYPE_TEXT)

proc tooManyRequests*(t: typedesc[RestApiResponse], msg: string = ""): RestApiResponse =
  RestApiResponse.error(Http429, msg, $MIMETYPE_TEXT)

proc jsonResponse*(
    t: typedesc[RestApiResponse], data: auto, status: HttpCode = Http200
): SerdesResult[RestApiResponse] =
  let encoded = ?encodeIntoJsonBytes(data)
  ok(RestApiResponse.response(encoded, status, $MIMETYPE_JSON))

proc textResponse*(
    t: typedesc[RestApiResponse], data: string, status: HttpCode = Http200
): RestApiResponse =
  RestApiResponse.response(data, status, $MIMETYPE_TEXT)
