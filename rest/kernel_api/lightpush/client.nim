{.push raises: [].}

import
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/pkg/results,
  presto/[route, client, common]
import rest/serdes, rest/rest_serdes, rest/kernel_api/lightpush/types

export types

proc encodeBytes*(value: PushRequest, contentType: string): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

proc sendPushRequest*(
  body: PushRequest
): RestResponse[PushResponse] {.
  rest, endpoint: "/lightpush/v3/message", meth: HttpMethod.MethodPost
.}
