{.push raises: [].}

## How the parts of this node's advertised record meet.
##
## The record is the `/logos/delivery` advert with further services listed in
## it, such as the mix key. Each part has its own owner, and a part can change
## while the node runs. An owner provides its part and reports a change; the
## node collects the parts and advertises the record again. Neither side knows
## the other.

import chronos, results
import brokers/[event_broker, multi_request_broker]
import logos_delivery/waku/discovery/peer_discovery_interface

export event_broker, multi_request_broker, peer_discovery_interface

EventBroker:
  # Emitted when a part of this node's record changed, or is no longer
  # provided. The node then advertises the record again.
  type AdvertChangedEvent* = object
    reason*: string ## For the log: what changed.

MultiRequestBroker:
  # One service of this node's record, as its owner wants it advertised now.
  # The `/logos/delivery` service is the record's own; any other is listed in
  # it. An owner with nothing to advertise removes its provider.
  type GetSelfAdvert* = object
    service*: DiscoveredService

  proc signature(): Future[Result[GetSelfAdvert, string]] {.async: (raises: []).}
