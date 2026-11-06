import system, std/json, libp2p/peerid

import
  ../../logos_delivery/waku/common/base64,
  ../../logos_delivery/waku/libp2p_iface/host,
  ./json_base_event

type JsonConnectionChangeEvent* = ref object of JsonEvent
  peerId*: string
  peerEvent*: HostPeerEventKind

proc new*(
    T: type JsonConnectionChangeEvent, peerId: string, peerEvent: HostPeerEventKind
): T =
  return JsonConnectionChangeEvent(
    eventType: "connection_change", peerId: peerId, peerEvent: peerEvent
  )

method `$`*(jsonConnectionChangeEvent: JsonConnectionChangeEvent): string =
  $(%*jsonConnectionChangeEvent)
