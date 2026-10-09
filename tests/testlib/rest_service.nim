import results, chronos
import logos_delivery/logos_delivery
import rest/rest_service

export rest_service

proc startWithRest*(
    node: LogosDelivery
): Future[Result[RestService, string]] {.async.} =
  let rest = RestService.new(node)
  ?(await rest.startNode())
  return ok(rest)
