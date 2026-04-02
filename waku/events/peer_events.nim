import waku/common/broker/event_broker
import libp2p/switch

type WakuPeerEventKind* {.pure.} = enum
  EventConnected
  EventDisconnected
  EventIdentified
  EventMetadataUpdated

EventBroker:
  type WakuPeerEvent* = object
    peerId*: PeerId
    kind*: WakuPeerEventKind
