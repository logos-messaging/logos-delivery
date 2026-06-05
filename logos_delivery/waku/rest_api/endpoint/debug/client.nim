{.push raises: [].}

import
  chronicles, json_serialization, json_serialization/std/options, presto/[route, client]
import ../serdes, ../rest_serdes, ./types

export types

logScope:
  topics = "waku node rest debug_api"

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc debugInfoV1*(): RestResponse[DebugWakuInfo] {.
  rest, endpoint: "/info", meth: HttpMethod.MethodGet
.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc debugVersionV1*(): RestResponse[string] {.
  rest, endpoint: "/version", meth: HttpMethod.MethodGet
.}
