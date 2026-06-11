import libp2p/peerinfo, brokers/[event_broker, request_broker]
import logos_delivery/waku/waku_core

EventBroker:
  # Event emitted when peers are discovered via random or service lookup
  type PeersDiscoveredEvent* = object
    peers*: seq[RemotePeerInfo]

RequestBroker:
  # Request broker for on-demand service peer lookup
  type ServicePeersRequest* = object
    serviceId*: string
    peers*: seq[RemotePeerInfo]

  proc signature*(serviceId: string): Future[Result[ServicePeersRequest, string]]
