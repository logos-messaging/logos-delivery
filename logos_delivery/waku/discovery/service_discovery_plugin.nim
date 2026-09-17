{.push raises: [].}

## Service discovery hosted outside the node (today the logos-delivery-module
## on top of the libp2p module), reached through the node's broker context:
##
##   node  --ServiceDiscoveryPluginRequest-->  host   (FFI event in the library)
##   node  <--CompleteServiceDiscoveryRequest--  host (FFI call in the library)
##
## Requests carry an id and are settled by it; the node owns the timeouts.
## Both halves run on the node's event loop, so nothing is shared across
## threads and nothing blocks.

import std/[base64, json, sequtils, tables]
import chronos, chronicles, results
import brokers/[broker_context, event_broker, request_broker]
import
  libp2p/[peerid, peerinfo, multiaddress, extended_peer_record, signed_envelope],
  libp2p/protocols/service_discovery/types
import logos_delivery/waku/discovery/service_discovery_driver

logScope:
  topics = "waku discovery plugin"

const
  DefaultPluginRequestTimeout* = chronos.seconds(30)
  PluginStopTimeout = chronos.seconds(2)
    ## `stop` also runs from the library's destructor, which nim-ffi cancels
    ## after 10 s; a host that is gone must not hold it that long.

type ServiceDiscoveryVerb* {.pure.} = enum
  start = "start"
  stop = "stop"
  lookup = "lookup"
  randomLookup = "randomLookup"
  startAdvertising = "startAdvertising"
  stopAdvertising = "stopAdvertising"
  registerInterest = "registerInterest"
  unregisterInterest = "unregisterInterest"

EventBroker:
  type ServiceDiscoveryPluginRequest* = object
    requestId*: uint64
    verb*: ServiceDiscoveryVerb
    serviceId*: string ## "" for start, stop and randomLookup
    data*: seq[byte] ## startAdvertising only: the advertised service data
    record*: seq[byte]
      ## startAdvertising only: this node's signed extended peer record, to be
      ## published as-is (the host's switch is not this node)
    timeoutMs*: int64 ## how long the node waits; a later completion is rejected

# Settles a pending request. On success `payload` is the verb's reply (a peer
# JSON array for lookups, ignored otherwise); on failure it is the error text.
RequestBroker:
  proc completeServiceDiscoveryRequest(
    requestId: uint64, success: bool, payload: string
  ): Future[Result[void, string]] {.async.}

type
  PluginReply = Future[Result[string, string]]

  ServiceDiscoveryPlugin* = ref object
    brokerCtx: BrokerContext
    requestTimeout: Duration
    nextRequestId: uint64
    pending: Table[uint64, PluginReply]

proc parseRecords*(payload: string): Result[seq[ExtendedPeerRecord], string] =
  ## A lookup reply: [{peerId, seqNo, addrs, services:[{id, data}]}], service
  ## `data` in base64. Entries that are not a valid peer are skipped.
  let parsed =
    try:
      parseJson(payload)
    except CatchableError:
      return err("invalid JSON from discovery plugin: " & getCurrentExceptionMsg())
  if parsed.kind != JArray:
    return err("expected a JSON array from discovery plugin, got " & $parsed.kind)

  var records: seq[ExtendedPeerRecord]
  for node in parsed:
    try:
      let peerId = PeerId.init(node{"peerId"}.getStr()).valueOr:
        continue
      var addrs: seq[MultiAddress]
      for a in node{"addrs"}.getElems():
        let ma = MultiAddress.init(a.getStr()).valueOr:
          continue
        addrs.add(ma)
      var services: seq[ServiceInfo]
      for s in node{"services"}.getElems():
        let data = s{"data"}.getStr()
        services.add(
          ServiceInfo(
            id: s{"id"}.getStr(),
            data:
              if data.len > 0:
                Opt.some(cast[seq[byte]](base64.decode(data)))
              else:
                Opt.none(seq[byte]),
          )
        )
      records.add(
        ExtendedPeerRecord.init(
          peerId, addrs, uint64(node{"seqNo"}.getBiggestInt()), services
        )
      )
    except CatchableError:
      debug "skipping malformed peer record", error = getCurrentExceptionMsg()
  ok(records)

proc new*(
    T: type ServiceDiscoveryPlugin,
    brokerCtx: BrokerContext,
    requestTimeout = DefaultPluginRequestTimeout,
): ServiceDiscoveryPlugin =
  let self =
    ServiceDiscoveryPlugin(brokerCtx: brokerCtx, requestTimeout: requestTimeout)
  discard CompleteServiceDiscoveryRequest.reprovideIt(brokerCtx):
    let reply = self.pending.getOrDefault(requestId)
    if reply.isNil() or reply.finished():
      return err("discovery plugin: unknown or expired request " & $requestId)
    if success:
      reply.complete(Result[string, string].ok(payload))
    else:
      reply.complete(Result[string, string].err(payload))
    ok()
  self

proc request(
    self: ServiceDiscoveryPlugin,
    verb: ServiceDiscoveryVerb,
    serviceId = "",
    data: seq[byte] = @[],
    record: seq[byte] = @[],
    timeout = ZeroDuration,
): Future[Result[string, string]] {.async: (raises: []).} =
  let timeout = if timeout == ZeroDuration: self.requestTimeout else: timeout
  inc self.nextRequestId
  let id = self.nextRequestId
  let reply = PluginReply.init("service discovery plugin request")
  self.pending[id] = reply
  defer:
    self.pending.del(id)

  ServiceDiscoveryPluginRequest.emit(
    self.brokerCtx,
    ServiceDiscoveryPluginRequest(
      requestId: id,
      verb: verb,
      serviceId: serviceId,
      data: data,
      record: record,
      timeoutMs: timeout.milliseconds,
    ),
  )

  let answered =
    try:
      await reply.withTimeout(timeout)
    except CancelledError:
      return err("discovery plugin: " & $verb & " cancelled")
  if not answered:
    return err("discovery plugin: " & $verb & " not answered in time")
  try:
    return reply.read()
  except CatchableError:
    return err("discovery plugin: " & $verb & " failed: " & getCurrentExceptionMsg())

proc failPending(self: ServiceDiscoveryPlugin, reason: string) =
  for reply in toSeq(self.pending.values):
    if not reply.finished():
      reply.complete(Result[string, string].err(reason))

proc signedRecord(peerInfo: PeerInfo, service: ServiceInfo): Result[seq[byte], string] =
  ## This node's record listing exactly the advertised service, signed with
  ## this node's key, for the host to publish under our identity.
  if peerInfo.addrs.len == 0:
    return err("discovery plugin: node has no addresses to advertise")
  let record =
    ExtendedPeerRecord.init(peerInfo.peerId, peerInfo.addrs, services = @[service])
  let signed = SignedExtendedPeerRecord.init(peerInfo.privateKey, record).valueOr:
    return err("discovery plugin: cannot sign record: " & $error)
  ok(signed.encode())

proc driver*(self: ServiceDiscoveryPlugin, peerInfo: PeerInfo): ServiceDiscoveryDriver =
  template settled(fut: untyped): untyped =
    discard ?(await fut)
    ok()

  ServiceDiscoveryDriver(
    start: proc(): Future[Result[void, string]] {.async: (raises: []).} =
      settled(self.request(ServiceDiscoveryVerb.start)),
    stop: proc(): Future[Result[void, string]] {.async: (raises: []).} =
      ## Nobody waits for answers once discovery stops.
      self.failPending("discovery plugin: stopped")
      settled(self.request(ServiceDiscoveryVerb.stop, timeout = PluginStopTimeout)),
    lookup: proc(
        serviceId: string
    ): Future[Result[seq[ExtendedPeerRecord], string]] {.async: (raises: []).} =
      parseRecords(?(await self.request(ServiceDiscoveryVerb.lookup, serviceId))),
    lookupRandom: proc(): Future[Result[seq[ExtendedPeerRecord], string]] {.
        async: (raises: [])
    .} =
      parseRecords(?(await self.request(ServiceDiscoveryVerb.randomLookup))),
    startAdvertising: proc(
        service: ServiceInfo
    ): Future[Result[void, string]] {.async: (raises: []).} =
      let record = ?signedRecord(peerInfo, service)
      settled(
        self.request(
          ServiceDiscoveryVerb.startAdvertising,
          service.id,
          data = service.data.get(@[]),
          record = record,
        )
      ),
    stopAdvertising: proc(
        serviceId: string
    ): Future[Result[void, string]] {.async: (raises: []).} =
      settled(self.request(ServiceDiscoveryVerb.stopAdvertising, serviceId)),
    registerInterest: proc(
        serviceId: string
    ): Future[Result[void, string]] {.async: (raises: []).} =
      settled(self.request(ServiceDiscoveryVerb.registerInterest, serviceId)),
    unregisterInterest: proc(
        serviceId: string
    ): Future[Result[void, string]] {.async: (raises: []).} =
      settled(self.request(ServiceDiscoveryVerb.unregisterInterest, serviceId)),
  )
