import std/[json, sequtils, strutils, tables]
import chronos, chronicles, results, ffi
import brokers/broker_implement
import
  logos_delivery,
  logos_delivery/waku/discovery/service_discovery_host,
  logos_delivery/waku/requests/node_state_requests,
  ../declare_lib

## The external service-discovery host, implemented by the process that embeds
## the library (logos-delivery-module) through nim-ffi reverse calls.
##
## Each `{.ffiReverse.}` proc below is a C entry point the host registers with
## `logosdelivery_ctx_set_<wire>_impl` after `create_node` and before
## `start_node`. The library calls it on a reverse worker thread; the host
## answers now or later, from any thread, with `logosdelivery_reverse_reply_<wire>`
## (or `_reverse_reply_err`). `FfiServiceDiscoveryHost` adapts them to the
## core's `IServiceDiscoveryHost`, installed on the node's broker context, so
## `ExternalServiceDiscovery` calls the host like any other request.
##
## `get_discovery_requirements` lists the wires under `requiredHostImpls`; a
## node configured for external discovery refuses to start until every one is
## registered.

type
  SdService* {.ffi.} = object
    id*: string
    data*: seq[byte]

  SdPeerRecord* {.ffi.} = object
    ## One extended peer record, as libp2p's service discovery returns it.
    peerId*: string
    seqNo*: uint64
    addrs*: seq[string]
    services*: seq[SdService]

  SdPeerRecords* {.ffi.} = object
    peers*: seq[SdPeerRecord]

proc sdStart(): Future[Result[void, string]] {.
    ffiReverse("sd_start", timeout = 20_000)
.} =
  ## Brings the host's discovery provider up. Sized for a bring-up, not a verb:
  ## libp2p's calls are capped at 10 s, which the kademlia bootstrap inside its
  ## switch start regularly reaches; roughly twice the worst bring-up measured
  ## on a 37-node fleet.

proc sdStop(): Future[Result[void, string]] {.ffiReverse("sd_stop", timeout = 15_000).} =
  ## Ends this node's discovery session; the provider may outlive it.

proc sdLookup(
    key: string, limit: int64
): Future[Result[SdPeerRecords, string]] {.ffiReverse("sd_lookup", timeout = 15_000).} =
  ## Peers advertising `key` (`service:<id>`); limit <= 0 lets the host decide.

proc sdRandomLookup(): Future[Result[SdPeerRecords, string]] {.
    ffiReverse("sd_random_lookup", timeout = 15_000)
.} =
  ## An unfiltered sample of the provider's peer space.

proc sdStartAdvertising(
    key: string, data: seq[byte], record: seq[byte]
): Future[Result[void, string]] {.ffiReverse("sd_start_advertising", timeout = 15_000).} =
  ## Publishes `record`, this node's SignedExtendedPeerRecord for the service,
  ## verbatim under `key`.

proc sdStopAdvertising(
    key: string
): Future[Result[void, string]] {.ffiReverse("sd_stop_advertising", timeout = 15_000).} =
  ## Withdraws what `sd_start_advertising` published under `key`.

proc sdRegisterInterest(
    key: string
): Future[Result[void, string]] {.ffiReverse("sd_register_interest", timeout = 15_000).} =
  ## Pre-warms the provider for later lookups of `key`.

proc sdUnregisterInterest(
    key: string
): Future[Result[void, string]] {.
    ffiReverse("sd_unregister_interest", timeout = 15_000)
.} =
  ## Drops the interest `sd_register_interest` took.

const SdWires = [
  "sd_start", "sd_stop", "sd_lookup", "sd_random_lookup", "sd_start_advertising",
  "sd_stop_advertising", "sd_register_interest", "sd_unregister_interest",
]

func toDiscoveredPeers(records: SdPeerRecords): seq[DiscoveredPeer] =
  ## Records without a peer id are dropped, as the JSON path did.
  return records.peers.filterIt(it.peerId.len > 0).mapIt(
      DiscoveredPeer(
        peerId: it.peerId,
        seqNo: it.seqNo,
        addrs: it.addrs,
        services: it.services.mapIt(DiscoveredService(id: it.id, data: it.data)),
      )
    )

proc noRaise[T](
    call: Future[Result[T, string]]
): Future[Result[T, string]] {.async: (raises: []).} =
  ## The generated reverse stubs are plain `{.async.}`; the interface's verbs
  ## raise nothing, so a raise (a cancelled call) becomes the error it means.
  try:
    return await call
  except CatchableError as e:
    return err("service discovery host call failed: " & e.msg)

type FfiServiceDiscoveryHost* = ref object of IServiceDiscoveryHost

BrokerImplement FfiServiceDiscoveryHost of IServiceDiscoveryHost:
  method hostCheck(
      self: FfiServiceDiscoveryHost
  ): Future[Result[void, string]] {.async.} =
    let missing = ffiReverseMissing(SdWires)
    if missing.len > 0:
      return err(
        "the host has not implemented " & missing.join(", ") &
          "; register them with logosdelivery_ctx_set_<wire>_impl before start_node"
      )
    return ok()

  method hostStart(
      self: FfiServiceDiscoveryHost
  ): Future[Result[void, string]] {.async.} =
    return await noRaise(sdStart())

  method hostStop(
      self: FfiServiceDiscoveryHost
  ): Future[Result[void, string]] {.async.} =
    return await noRaise(sdStop())

  method hostLookup(
      self: FfiServiceDiscoveryHost, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    let records = ?(await noRaise(sdLookup(key, int64(limit))))
    return ok(records.toDiscoveredPeers())

  method hostRandomLookup(
      self: FfiServiceDiscoveryHost
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    let records = ?(await noRaise(sdRandomLookup()))
    return ok(records.toDiscoveredPeers())

  method hostStartAdvertising(
      self: FfiServiceDiscoveryHost, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    return await noRaise(sdStartAdvertising(key, data, record))

  method hostStopAdvertising(
      self: FfiServiceDiscoveryHost, key: string
  ): Future[Result[void, string]] {.async.} =
    return await noRaise(sdStopAdvertising(key))

  method hostRegisterInterest(
      self: FfiServiceDiscoveryHost, key: string
  ): Future[Result[void, string]] {.async.} =
    return await noRaise(sdRegisterInterest(key))

  method hostUnregisterInterest(
      self: FfiServiceDiscoveryHost, key: string
  ): Future[Result[void, string]] {.async.} =
    return await noRaise(sdUnregisterInterest(key))

var discoveryHosts {.threadvar.}: Table[string, FfiServiceDiscoveryHost]
  ## Per node, keyed like `restServices`: the FFI thread may serve several.

proc installServiceDiscoveryHost(self: LogosDelivery) =
  ## Create-time: only a node configured for external discovery gets a host,
  ## so the others keep failing such requests with "no provider".
  if self.waku.externalDiscovery.isNil():
    return
  discoveryHosts[$self.waku.brokerCtx] =
    FfiServiceDiscoveryHost.createUnderContext(self.waku.brokerCtx)

proc removeServiceDiscoveryHost(self: LogosDelivery) =
  ## Destroy-time: the node's broker scope dies with the node.
  var host: FfiServiceDiscoveryHost
  if discoveryHosts.pop($self.waku.brokerCtx, host):
    host.close()

proc logosdelivery_get_discovery_requirements(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## What the host must set up before `start`: whether service discovery is
  ## expected from the host, the reverse entry points it must then register,
  ## and the DHT bootstrap peers the node's configuration resolves to, presets
  ## included. Reply JSON:
  ## {"externalServiceDiscovery": bool, "requiredHostImpls": ["sd_start", ...],
  ##  "bootstrapNodes": ["/dns4/.../p2p/16Uiu..."]}
  let req = GetDiscoveryRequirements.request(self.waku.brokerCtx).valueOr:
    error "GET_DISCOVERY_REQUIREMENTS failed", err = error
    return err(error)
  let required =
    if req.isExternalServiceDiscoveryProvided:
      @SdWires
    else:
      @[]
  return ok(
    $(
      %*{
        "externalServiceDiscovery": req.isExternalServiceDiscoveryProvided,
        "requiredHostImpls": required,
        "bootstrapNodes": req.bootstrapNodes,
      }
    )
  )
