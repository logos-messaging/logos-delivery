{.push raises: [].}

import chronicles, json_serialization, presto/[route, client]
import ./types, ../serdes, ../rest_serdes, waku/node/health_monitor

logScope:
  topics = "waku node rest health_api"

proc healthCheck*(): RestResponse[HealthReport] {.
  rest, endpoint: "/health", meth: HttpMethod.MethodGet
.}
