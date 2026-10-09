import results, chronos
import logos_delivery/logos_delivery
import ../../rest/rest_service

export rest_service

proc startWithRest*(
    node: LogosDelivery
): Future[Result[RestService, string]] {.async.} =
  ## What the node app does: the REST service brings the server up before the
  ## node boots and mounts the routes once the node runs.
  let rest = RestService.new(node)
  ?rest.start()
  (await node.start()).isOkOr:
    return err("could not start the node: " & error)
  ?rest.mount()
  return ok(rest)
