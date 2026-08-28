{.push raises: [].}

## IPeerDiscovery backed by an external service-discovery provider (today:
## logos-libp2p-module, driven by glue code in logos-delivery-module).
##
## This implementation deliberately has no libp2p dependency: every verb is a
## request-id correlated round trip to a host that owns the actual discovery
## node. Outbound commands are handed to an injected sink; the host answers
## with `onHostReply` and may push spontaneous results with `onHostPush`.
##
## The transport is *not* part of this module — the library layer marshals
## `DiscoveryBackendCommand` out (as a JSON event) and feeds replies back in.

import std/tables
import chronos, chronicles, results
import brokers/broker_implement
import logos_delivery/waku/discovery/peer_discovery_interface

export peer_discovery_interface

logScope:
  topics = "waku discovery external"

const
  ExternalBackendId* = "service-ext"
  DefaultHostRequestTimeout* = chronos.seconds(10)

type DiscoveryBackendOp* {.pure.} = enum
  ## Mirrors the libp2p-module RPC surface.
  DiscoStart = "discoStart"
  DiscoStop = "discoStop"
  DiscoLookup = "discoLookup"
  DiscoRandomLookup = "discoRandomLookup"
  DiscoStartAdvertising = "discoStartAdvertising"
  DiscoStopAdvertising = "discoStopAdvertising"
  DiscoRegisterInterest = "discoRegisterInterest"
  DiscoUnregisterInterest = "discoUnregisterInterest"
  ConnectPeer = "connectPeer"

type DiscoveryBackendCommand* = object
  requestId*: uint64
  op*: DiscoveryBackendOp
  key*: string ## service id / criteria key; "" when not applicable
  data*: seq[byte] ## advertised payload
  record*: seq[byte] ## pre-signed advertisement (proxy-XPR path)
  limit*: int ## lookup cap; <= 0 means backend default
  entries*: seq[string] ## bootstrap entries

type DiscoveryBackendReply* = object
  requestId*: uint64
  success*: bool
  error*: string ## set when success is false
  peers*: seq[DiscoveredPeer] ## set for lookup ops

type HostCommandSink* = proc(cmd: DiscoveryBackendCommand) {.gcsafe, raises: [].}
  ## Hands a command to whoever owns the external discovery node.

type PendingReply = Future[DiscoveryBackendReply]

type ExternalServiceDiscovery* = ref object of IPeerDiscovery
  sendToHost: HostCommandSink
  pending: Table[uint64, PendingReply]
  nextRequestId: uint64
  requestTimeout: Duration
  running: bool
  nodeCtx: BrokerContext

proc installHostSink*(self: ExternalServiceDiscovery, sink: HostCommandSink) =
  ## Installs (or replaces) the transport that carries commands to the host.
  ## Until one is installed every verb fails cleanly rather than hanging.
  self.sendToHost = sink

proc onHostReply*(self: ExternalServiceDiscovery, reply: DiscoveryBackendReply) =
  ## Completes the round trip the host was answering. Unknown ids are dropped
  ## (a reply that arrived after its request timed out).
  let fut = self.pending.getOrDefault(reply.requestId, nil)
  if fut.isNil():
    debug "no pending request for reply", requestId = reply.requestId
    return
  self.pending.del(reply.requestId)
  if not fut.finished():
    fut.complete(reply)

proc onHostPush*(
    self: ExternalServiceDiscovery, key: string, peers: seq[DiscoveredPeer]
) =
  ## Spontaneous results from the host's own discovery cadence.
  if peers.len == 0:
    return
  PeersDiscovered.emit(
    self.brokerCtx, PeersDiscovered(origin: ExternalBackendId, key: key, peers: peers)
  )

proc roundtrip(
    self: ExternalServiceDiscovery, cmd: sink DiscoveryBackendCommand
): Future[Result[DiscoveryBackendReply, string]] {.async: (raises: []).} =
  if self.sendToHost.isNil():
    return err("external backend: no host sink installed")

  var command = cmd
  command.requestId = self.nextRequestId
  inc self.nextRequestId

  let fut = newFuture[DiscoveryBackendReply]("externalDiscovery.roundtrip")
  self.pending[command.requestId] = fut

  self.sendToHost(command)

  let completed =
    try:
      await fut.withTimeout(self.requestTimeout)
    except CancelledError:
      self.pending.del(command.requestId)
      return err("external backend: request cancelled")

  if not completed:
    self.pending.del(command.requestId)
    return err("external backend: host did not answer " & $command.op)

  let reply =
    try:
      fut.read()
    except CatchableError:
      return err("external backend: reply read failed: " & getCurrentExceptionMsg())

  if not reply.success:
    return err("external backend: " & $command.op & " failed: " & reply.error)

  ok(reply)

BrokerImplement ExternalServiceDiscovery of IPeerDiscovery:
  proc new(
      T: typedesc[ExternalServiceDiscovery],
      sendToHost: HostCommandSink,
      requestTimeout: Duration = DefaultHostRequestTimeout,
  ): ExternalServiceDiscovery =
    ExternalServiceDiscovery(
      sendToHost: sendToHost,
      pending: initTable[uint64, PendingReply](),
      nextRequestId: 1,
      requestTimeout: requestTimeout,
      nodeCtx: globalBrokerContext(),
    )

  method backendInfo(
      self: ExternalServiceDiscovery
  ): Future[Result[DiscoveryBackendInfo, string]] {.async.} =
    ok(
      DiscoveryBackendInfo(
        id: ExternalBackendId,
        running: self.running,
        keyKinds: @["svc", "shard", "cap"],
        boundPorts: @[],
      )
    )

  method startDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if self.running:
      return ok()
    discard ?await self.roundtrip(DiscoveryBackendCommand(op: DiscoStart))
    self.running = true
    ok()

  method stopDiscovery(
      self: ExternalServiceDiscovery
  ): Future[Result[void, string]] {.async.} =
    if not self.running:
      return ok()
    self.running = false
    discard ?await self.roundtrip(DiscoveryBackendCommand(op: DiscoStop))
    ok()

  method lookupServicePeers(
      self: ExternalServiceDiscovery, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    let reply = ?await self.roundtrip(
      DiscoveryBackendCommand(op: DiscoLookup, key: key, limit: limit)
    )
    ok(reply.peers)

  method lookupRandom(
      self: ExternalServiceDiscovery
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    if not self.running:
      return err("external backend: not running")
    let reply = ?await self.roundtrip(DiscoveryBackendCommand(op: DiscoRandomLookup))
    ok(reply.peers)

  method startAdvertising(
      self: ExternalServiceDiscovery, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    ## `record` carries a pre-signed advertisement so the host can publish this
    ## node's identity from its own (different) discovery node.
    discard ?await self.roundtrip(
      DiscoveryBackendCommand(
        op: DiscoStartAdvertising, key: key, data: data, record: record
      )
    )
    ok()

  method stopAdvertising(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    discard
      ?await self.roundtrip(DiscoveryBackendCommand(op: DiscoStopAdvertising, key: key))
    ok()

  method registerInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    discard ?await self.roundtrip(
      DiscoveryBackendCommand(op: DiscoRegisterInterest, key: key)
    )
    ok()

  method unregisterInterest(
      self: ExternalServiceDiscovery, key: string
  ): Future[Result[void, string]] {.async.} =
    discard ?await self.roundtrip(
      DiscoveryBackendCommand(op: DiscoUnregisterInterest, key: key)
    )
    ok()

  method addBootstrapEntries(
      self: ExternalServiceDiscovery, entries: seq[string]
  ): Future[Result[void, string]] {.async.} =
    if entries.len == 0:
      return ok()
    discard
      ?await self.roundtrip(DiscoveryBackendCommand(op: ConnectPeer, entries: entries))
    ok()
