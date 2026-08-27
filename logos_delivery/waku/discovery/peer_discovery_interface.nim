{.push raises: [].}

## IPeerDiscovery — abstract peer-discovery interface.
##
## Backends (discv5, kad service discovery, external service discovery)
## implement it with `BrokerImplement`; each instance gets its own
## BrokerContext, so multiple backends run isolated side by side.
##
## Peer flow stays internal to the backends: discovered peers are fed to the
## PeerManager by the wrapped entities themselves. The `PeersDiscovered` event
## is an observability hook (logging, user info, metrics); the lookup verbs
## serve on-demand consumers (e.g. the ServicePeersRequest provider).
##
## Criteria keys are opaque, convention-prefixed strings:
##   "svc:<serviceId>"          libp2p service id (kad backends)
##   "shard:<cluster>/<shard>"  relay shard
##   "cap:<capability>"         node capability
##   ""                         no criteria / random sample

import chronos, results
import brokers/[broker_interface, event_broker, request_broker]

export chronos, results, broker_interface, event_broker, request_broker

type DiscoveredService* = object
  id*: string ## service id / capability tag
  data*: seq[byte] ## advertised payload, byte-exact (e.g. mix pubkey)

type DiscoveredPeer* = object
  peerId*: string ## base58 peer id
  addrs*: seq[string] ## multiaddr strings
  enr*: string ## discv5 only, lossless ENR passthrough; "" otherwise
  seqNo*: uint64
  services*: seq[DiscoveredService]

type DiscoveryBackendInfo* = object
  id*: string ## "discv5" | "kad" | "kad-ext"
  running*: bool
  keyKinds*: seq[string] ## supported criteria key prefixes, e.g. @["svc", ""]
  boundPorts*: seq[uint16] ## e.g. discv5 UDP port after auto-port; empty if n/a

BrokerInterface(IPeerDiscovery):
  EventBroker:
    # Observability hook — peers already reached the PeerManager internally.
    type PeersDiscovered* = object
      origin*: string ## backend id
      key*: string ## criteria that produced them; "" for background/random
      peers*: seq[DiscoveredPeer]

  RequestBroker:
    proc backendInfo(): Future[Result[DiscoveryBackendInfo, string]] {.async.}

  RequestBroker:
    proc startDiscovery(): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc stopDiscovery(): Future[Result[void, string]] {.async.}

  RequestBroker:
    # One-shot pull for a criteria key; limit <= 0 lets the backend decide.
    # (WakuKademlia: lookupServicePeers; libp2p-module: discoLookup)
    proc lookupServicePeers(
      key: string, limit: int
    ): Future[Result[seq[DiscoveredPeer], string]] {.async.}

  RequestBroker:
    # Unfiltered random sample of the backend's peer space.
    # (libp2p ServiceDiscovery: lookupRandom; libp2p-module: discoRandomLookup)
    proc lookupRandom(): Future[Result[seq[DiscoveredPeer], string]] {.async.}
