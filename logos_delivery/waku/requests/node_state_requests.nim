{.push raises: [].}

## Node-state getter brokers.
##
## Discovery backends (and other loosely-coupled components) resolve node
## state through these instead of constructor injection, so their wiring does
## not depend on initialization order. Providers are installed by the `Waku`
## factory object as each piece of state becomes available.
##
## In-process, single-thread lane only — several getters return `ref` types
## (Switch, PeerManager); this pattern is deliberately NOT extended to the
## FFI/MT lanes.

import chronos, results
import libp2p/[switch, crypto/crypto]
import brokers/request_broker
import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_enr,
  logos_delivery/waku/node/peer_manager/peer_manager

export request_broker

RequestBroker:
  proc getNodeSwitch(): Future[Result[Switch, string]] {.async.}

RequestBroker:
  proc getNodePeerManager(): Future[Result[PeerManager, string]] {.async.}

RequestBroker:
  # The node's current ENR (final after setupNode; refreshed on updateEnr).
  proc getNodeEnr(): Future[Result[enr.Record, string]] {.async.}

RequestBroker:
  # The node's libp2p private key (discv5 signs its ENR with it).
  proc getNodeKey(): Future[Result[crypto.PrivateKey, string]] {.async.}

RequestBroker:
  # DNS-discovery (or otherwise dynamically obtained) bootstrap peers;
  # empty until retrieval succeeded.
  proc getDynamicBootstrapNodes(): Future[Result[seq[RemotePeerInfo], string]] {.async.}

RequestBroker:
  # Relay/filter shard subscription change feed (consumed by discv5 for
  # ENR shard updates).
  proc getTopicSubscriptionQueue(): Future[
    Result[AsyncEventQueue[SubscriptionEvent], string]
  ] {.async.}
