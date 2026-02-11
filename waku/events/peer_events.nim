import waku/common/broker/event_broker
import libp2p/switch

type
  WakuPeerEventKind* = enum
    EventConnected
    EventDisconnected
    EventIdentified
    EventMetadataUpdated

EventBroker:
  type EventWakuPeer* = object
    peerId*: PeerId
    kind*: WakuPeerEventKind
