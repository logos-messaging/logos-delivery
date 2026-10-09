{.push raises: [].}

import chronicles, json_serialization, presto/[route, client]
import ./types, rest/serdes, rest/rest_serdes, logos_delivery/waku/node/health_monitor

logScope:
  topics = "waku node rest health_api"

proc healthCheck*(): RestResponse[HealthReport] {.
  rest, endpoint: "/health", meth: HttpMethod.MethodGet
.}
