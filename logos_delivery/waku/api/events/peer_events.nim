import brokers/event_broker
import libp2p/peerid

type WakuPeerEventKind* {.pure.} = enum
  EventConnected
  EventDisconnected
  EventIdentified
  EventMetadataUpdated

EventBroker:
  type WakuPeerEvent* = object
    peerId*: PeerId
    kind*: WakuPeerEventKind
