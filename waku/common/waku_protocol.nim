{.push raises: [].}

type WakuProtocol* {.pure.} = enum
  RelayProtocol = "Relay"
  RlnRelayProtocol = "Rln Relay"
  StoreProtocol = "Store"
  LegacyStoreProtocol = "Legacy Store"
  FilterProtocol = "Filter"
  LightpushProtocol = "Lightpush"
  LegacyLightpushProtocol = "Legacy Lightpush"
  PeerExchangeProtocol = "Peer Exchange"
  RendezvousProtocol = "Rendezvous"
  MixProtocol = "Mix"
  StoreClientProtocol = "Store Client"
  LegacyStoreClientProtocol = "Legacy Store Client"
  FilterClientProtocol = "Filter Client"
  LightpushClientProtocol = "Lightpush Client"
  LegacyLightpushClientProtocol = "Legacy Lightpush Client"

const
  RelayProtocols* = {RelayProtocol}
  StoreClientProtocols* = {StoreClientProtocol, LegacyStoreClientProtocol}
  LightpushClientProtocols* = {LightpushClientProtocol, LegacyLightpushClientProtocol}
  FilterClientProtocols* = {FilterClientProtocol}
