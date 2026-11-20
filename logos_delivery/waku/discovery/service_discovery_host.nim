{.push raises: [].}

## IServiceDiscoveryHost — what the external service-discovery backend needs
## from the process hosting the node.
##
## `ExternalServiceDiscovery` keeps the discovery logic (adverts, interests,
## lookups, record signing) and delegates the DHT work to a host, today the
## logos-delivery-module driving logos-libp2p-module. This interface is that
## delegation, nothing more. The library implements it on top of nim-ffi
## reverse calls (`library/logos_delivery_api/service_discovery_host_api.nim`);
## tests implement it in Nim.
##
## An implementation is installed on the node's own broker context, the one
## `ExternalServiceDiscovery` resolves the node through, so the backend calls
## `HostLookup.request(nodeCtx, ...)` and needs no reference to it. No
## implementation installed means "no provider": the backend's start fails,
## because configured external discovery with no host is a node without
## discovery.
##
## Keys are the backend's criteria keys (`service:<id>`); the host strips the
## prefix it does not use.

import chronos, results
import brokers/[broker_interface, request_broker]
import logos_delivery/waku/discovery/peer_discovery_interface

export chronos, results, broker_interface, request_broker, peer_discovery_interface

# BrokerInterface derives a proc from each broker's verb, so a Capitalized
# verb collides with the broker type and the naming warning cannot be
# silenced the way RequestBroker suggests.
{.push warning[User]: off.}
BrokerInterface(IServiceDiscoveryHost):
  RequestBroker:
    # Ok when the host implements every verb below; otherwise an error that
    # names what is missing. Asked once at start, before anything else.
    proc hostCheck(): Future[Result[void, string]] {.async.}

  RequestBroker:
    # Bring the host's discovery provider up. Idempotent on the host side: the
    # provider may outlive this node's discovery session.
    proc hostStart(): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc hostStop(): Future[Result[void, string]] {.async.}

  RequestBroker:
    # limit <= 0 lets the host decide.
    proc hostLookup(
      key: string, limit: int
    ): Future[Result[seq[DiscoveredPeer], string]] {.async.}

  RequestBroker:
    proc hostRandomLookup(): Future[Result[seq[DiscoveredPeer], string]] {.async.}

  RequestBroker:
    # `record` is this node's SignedExtendedPeerRecord for the service, signed
    # here: the host's discovery node is not this node, so it publishes the
    # record verbatim instead of its own.
    proc hostStartAdvertising(
      key: string, data: seq[byte], record: seq[byte]
    ): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc hostStopAdvertising(key: string): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc hostRegisterInterest(key: string): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc hostUnregisterInterest(key: string): Future[Result[void, string]] {.async.}
{.pop.}
