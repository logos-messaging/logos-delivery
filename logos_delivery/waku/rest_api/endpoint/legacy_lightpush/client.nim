{.push raises: [].}

import chronicles, json_serialization, presto/[route, client, common]
import ../serdes, ../rest_serdes, ./types

export types

proc encodeBytes*(value: PushRequest, contentType: string): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc sendPushRequest*(
  body: PushRequest
): RestResponse[string] {.
  rest, endpoint: "/lightpush/v1/message", meth: HttpMethod.MethodPost
.}
