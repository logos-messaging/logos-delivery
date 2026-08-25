{.push raises: [].}

## Node-state getter brokers.
##
## Discovery backends (and other loosely-coupled components) resolve node
## state through these instead of constructor injection, so their wiring does
## not depend on initialization order. Providers are installed by the `Waku`
## factory object as each piece of state becomes available.
##
## Sync brokers: these are plain state reads, no suspension needed.
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

RequestBroker(sync):
  proc getNodeSwitch(): Result[Switch, string]

RequestBroker(sync):
  proc getNodePeerManager(): Result[PeerManager, string]

RequestBroker(sync):
  # The node's current ENR (final after setupNode; refreshed on updateEnr).
  proc getNodeEnr(): Result[enr.Record, string]

RequestBroker(sync):
  # The node's libp2p private key (discv5 signs its ENR with it).
  proc getNodeKey(): Result[crypto.PrivateKey, string]

RequestBroker(sync):
  # DNS-discovery (or otherwise dynamically obtained) bootstrap peers;
  # empty until retrieval succeeded.
  proc getDynamicBootstrapNodes(): Result[seq[RemotePeerInfo], string]

RequestBroker(sync):
  # Relay/filter shard subscription change feed (consumed by discv5 for
  # ENR shard updates).
  proc getTopicSubscriptionQueue(): Result[AsyncEventQueue[SubscriptionEvent], string]
