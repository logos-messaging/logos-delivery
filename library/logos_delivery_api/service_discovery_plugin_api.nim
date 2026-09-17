import std/[json, sequtils]
import chronos, chronicles, results, ffi
import
  logos_delivery,
  logos_delivery/waku/discovery/[waku_kademlia, service_discovery_plugin],
  ../declare_lib

## Plugin side of kademlia discovery. The node asks through the
## `onServiceDiscoveryRequest` event (see `registerFFIEventListeners`) and the
## plugin settles each request here, from any thread, by its `requestId`.

proc logosdelivery_get_discovery_requirements(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## What the plugin must set up before `start`: whether the node expects one,
  ## and the DHT bootstrap peers its configuration resolves to. Reply JSON:
  ## {"pluginKadDiscovery": bool, "bootstrapNodes": ["/ip4/.../p2p/16Uiu..."]}
  let kad = self.waku.conf.kademliaDiscoveryConf
  let pluginHosted = kad.isSome() and kad.get().pluginHosted
  var bootstrapNodes: seq[string]
  if pluginHosted:
    for (peerId, addrs) in kad.get().bootstrapNodes:
      bootstrapNodes.add(addrs.mapIt($it & "/p2p/" & $peerId))
  return ok($(%*{"pluginKadDiscovery": pluginHosted, "bootstrapNodes": bootstrapNodes}))

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
