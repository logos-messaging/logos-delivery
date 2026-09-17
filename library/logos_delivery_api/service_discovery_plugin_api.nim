import std/json
import chronos, chronicles, results, ffi
import
  logos_delivery,
  logos_delivery/waku/discovery/external_discovery_host,
  logos_delivery/waku/requests/node_state_requests,
  ../declare_lib

## Host side of external service discovery. The node asks through the
## `onServiceDiscoveryRequest` event (see `registerFFIEventListeners`) and the
## host settles each request here, from any thread, by its `requestId`.

proc logosdelivery_get_discovery_requirements(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## What the host must set up before `start`: whether the node expects an
  ## external discovery host, and the DHT bootstrap peers the node's
  ## configuration resolves to, presets included. Reply JSON:
  ## {"externalServiceDiscovery": bool, "bootstrapNodes": ["/dns4/.../p2p/16Uiu..."]}
  let req = GetDiscoveryRequirements.request(self.waku.brokerCtx).valueOr:
    error "GET_DISCOVERY_REQUIREMENTS failed", err = error
    return err(error)
  return ok(
    $(
      %*{
        "externalServiceDiscovery": req.externalServiceDiscovery,
        "bootstrapNodes": req.bootstrapNodes,
      }
    )
  )

proc logosdelivery_complete_service_discovery_request(
    self: LogosDelivery, requestId: uint64, success: bool, payload: string
): Future[Result[string, string]] {.ffi.} =
  ## Answers one `onServiceDiscoveryRequest`. On success `payload` is the reply
  ## (the peer JSON array for lookup/randomLookup, ignored otherwise); on
  ## failure it is the error text. Rejected once the request timed out.
  (
    await CompleteServiceDiscoveryRequest.request(
      self.waku.brokerCtx, requestId, success, payload
    )
  ).isOkOr:
    debug "COMPLETE_SERVICE_DISCOVERY_REQUEST failed", err = error
    return err(error)
  return ok("")
