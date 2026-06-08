{.push raises: [].}

import chronos, std/[options, sequtils], results
import ../discovery/waku_discv5, ../waku_relay, ../waku_core, ./message_cache

### Discovery

type DiscoveryHandler* =
  proc(): Future[Result[Option[RemotePeerInfo], string]] {.async, closure.}

proc defaultDiscoveryHandler*(
    discv5: WakuDiscoveryV5, cap: Capabilities
): DiscoveryHandler =
  proc(): Future[Result[Option[RemotePeerInfo], string]] {.async, closure.} =
    #Discv5 is already filtering peers by shards no need to pass a predicate.
    let findPeers = discv5.findRandomPeers()

    if not await findPeers.withTimeout(60.seconds):
      return err("discovery process timed out!")

    var peers = findPeers.read()

    peers.keepItIf(it.supportsCapability(cap))

    if peers.len == 0:
      return ok(none(RemotePeerInfo))

    let remotePeerInfo = peers[0].toRemotePeerInfo().valueOr:
      return err($error)

    return ok(some(remotePeerInfo))

### Message Cache

proc messageCacheHandler*(cache: MessageCache): WakuRelayHandler =
  return proc(pubsubTopic: string, msg: WakuMessage): Future[void] {.async, closure.} =
    cache.addMessage(pubsubTopic, msg)
