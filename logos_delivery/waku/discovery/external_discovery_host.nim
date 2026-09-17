{.push raises: [].}

## The contract between `ExternalServiceDiscovery` and whoever hosts the
## discovery work (today the logos-delivery-module, on top of the libp2p
## module).
##
## Every discovery verb goes out as a `ServiceDiscoveryHostRequest` event and
## is settled by the host through `CompleteServiceDiscoveryRequest`, keyed by
## `requestId`. Both halves live on the node's event loop: the library bridges
## the event onto an FFI event and the completion onto an FFI call, both of
## which run on the node's thread, so nothing here is shared across threads.

import std/[json, base64]
import chronos, chronicles, results
import brokers/[event_broker, request_broker]
import logos_delivery/waku/discovery/peer_discovery_interface

logScope:
  topics = "waku discovery external host"

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
  type ServiceDiscoveryHostRequest* = object
    requestId*: uint64
    verb*: ServiceDiscoveryVerb
    key*: string ## criteria key, e.g. "svc:/logos/delivery"; "" if n/a
    limit*: int ## lookup only; <= 0 means the host's default
    data*: seq[byte] ## startAdvertising only: the advertised service data
    record*: seq[byte]
      ## startAdvertising only: this node's signed peer record, to be
      ## published as-is
    timeoutMs*: int64 ## how long the node waits; a later completion is rejected

# Settles a pending request. On success `payload` is the verb's reply (a peer
# JSON array for lookups, ignored otherwise); on failure it is the error text.
RequestBroker:
  proc completeServiceDiscoveryRequest(
    requestId: uint64, success: bool, payload: string
  ): Future[Result[void, string]] {.async.}

proc parsePeers*(payload: string): Result[seq[DiscoveredPeer], string] =
  ## Parses a lookup reply, shaped like the libp2p module's extended peer
  ## records: [{peerId, seqNo, addrs, services:[{id, data}]}] where each
  ## service `data` is base64. Malformed entries are skipped.
  let parsed =
    try:
      parseJson(payload)
    except CatchableError:
      return err("invalid JSON from discovery host: " & getCurrentExceptionMsg())

  if parsed.kind != JArray:
    return err("expected a JSON array from discovery host, got " & $parsed.kind)

  var peers: seq[DiscoveredPeer]
  for node in parsed:
    if node.kind != JObject:
      continue
    var peer = DiscoveredPeer()
    try:
      if node.hasKey("peerId") and node["peerId"].kind == JString:
        peer.peerId = node["peerId"].getStr()
      if node.hasKey("seqNo") and node["seqNo"].kind == JInt:
        peer.seqNo = uint64(node["seqNo"].getBiggestInt())
      if node.hasKey("addrs") and node["addrs"].kind == JArray:
        for a in node["addrs"]:
          if a.kind == JString:
            peer.addrs.add(a.getStr())
      if node.hasKey("services") and node["services"].kind == JArray:
        for s in node["services"]:
          if s.kind != JObject:
            continue
          var svc = DiscoveredService()
          if s.hasKey("id") and s["id"].kind == JString:
            svc.id = s["id"].getStr()
          if s.hasKey("data") and s["data"].kind == JString:
            svc.data = cast[seq[byte]](base64.decode(s["data"].getStr()))
          peer.services.add(svc)
    except CatchableError:
      debug "skipping malformed peer record", error = getCurrentExceptionMsg()
      continue

    if peer.peerId.len > 0:
      peers.add(peer)

  ok(peers)
