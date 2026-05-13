import libp2p/peerinfo, waku/common/broker/[event_broker, request_broker]

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
