{.push raises: [].}

import chronicles, json_serialization, presto/route
import ../../../waku_node, ../responses, ../serdes, ./types

logScope:
  topics = "waku node rest health_api"

const ROUTE_HEALTH* = "/health"

const FutHealthReportTimeout = 5.seconds

proc installHealthApiHandler*(
    router: var RestRouter, nodeHealthMonitor: NodeHealthMonitor
) =
  router.api(MethodGet, ROUTE_HEALTH) do() -> RestApiResponse:
    let healthReportFut = nodeHealthMonitor.getNodeHealthReport()
    if not await healthReportFut.withTimeout(FutHealthReportTimeout):
      return RestApiResponse.internalServerError("Health check timed out")

    var msg = ""
    var status = Http200

    try:
      if healthReportFut.completed():
        let healthReport = healthReportFut.read()
        return RestApiResponse.jsonResponse(healthReport, Http200).valueOr:
          info "An error ocurred while building the json healthReport response",
            error = error
          return
            RestApiResponse.internalServerError("Failed to serialize health report")
      else:
        msg = "Health check failed"
        status = Http503
    except:
      msg = "exception reading state: " & getCurrentExceptionMsg()
      status = Http500

    return RestApiResponse.textResponse(msg, status)
