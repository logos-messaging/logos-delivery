{.push raises: [].}

type WakuProtocol* {.pure.} = enum
  RelayProtocol = "Relay"
  RlnRelayProtocol = "Rln Relay"
  StoreProtocol = "Store"
  FilterProtocol = "Filter"
  LightpushProtocol = "Lightpush"
  LegacyLightpushProtocol = "Legacy Lightpush"
  PeerExchangeProtocol = "Peer Exchange"
  RendezvousProtocol = "Rendezvous"
  MixProtocol = "Mix"
  StoreClientProtocol = "Store Client"
  FilterClientProtocol = "Filter Client"
  LightpushClientProtocol = "Lightpush Client"
  LegacyLightpushClientProtocol = "Legacy Lightpush Client"

const
  RelayProtocols* = {RelayProtocol}
  StoreClientProtocols* = {StoreClientProtocol}
  LightpushClientProtocols* = {LightpushClientProtocol, LegacyLightpushClientProtocol}
  FilterClientProtocols* = {FilterClientProtocol}
