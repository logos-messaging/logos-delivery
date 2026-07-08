import std/options
import std/net
import results

import logos_delivery/api/kernel_conf
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/factory/networks_config

export kernel_conf, messaging_client

type WakuMode* {.pure.} = enum
  Edge # client-only node
  Core # full service node

proc toKernelConf*(self: MessagingClientConf, mode: WakuMode): ConfResult[KernelConf] =
  ## Mode sets the protocol flags; set fields map to their kernel counterpart.
  var conf = ?defaultWakuNodeConf()

  case mode
  of WakuMode.Core:
    conf.relay = true
    conf.filter = true
    conf.lightpush = true
    conf.discv5Discovery = some(true)
    conf.peerExchange = true
    conf.rendezvous = true
  of WakuMode.Edge:
    conf.peerExchange = true
    conf.relay = false
    conf.filter = false
    conf.lightpush = false
    conf.store = false

  if self.store.isSome():
    conf.store = self.store.get()
  if self.storeMessageDbUrl.isSome():
    conf.storeMessageDbUrl = self.storeMessageDbUrl.get()
  if self.storeMessageRetentionPolicy.isSome():
    conf.storeMessageRetentionPolicy = self.storeMessageRetentionPolicy.get()
  if self.storeMaxNumDbConnections.isSome():
    conf.storeMaxNumDbConnections = self.storeMaxNumDbConnections.get()
  if self.storenode.isSome():
    conf.storenode = self.storenode.get()

  if self.clusterId.isSome():
    conf.clusterId = self.clusterId
  if self.numShardsInCluster.isSome():
    conf.numShardsInNetwork = self.numShardsInCluster.get()
  if self.listenIpv4.isSome():
    conf.listenAddress = self.listenIpv4.get()
  if self.maxMessageSize.isSome():
    conf.maxMessageSize = self.maxMessageSize.get()
  if self.entryNodes.isSome():
    conf.entryNodes = self.entryNodes.get()
  if self.ethRpcEndpoints.isSome():
    conf.ethClientUrls = self.ethRpcEndpoints.get()
  if self.rlnContractAddress.isSome():
    conf.rlnRelayEthContractAddress = self.rlnContractAddress.get()
    conf.rlnRelay = some(true)
  if self.rlnChainId.isSome():
    conf.rlnRelayChainId = self.rlnChainId.get()
  if self.rlnEpochSizeSec.isSome():
    conf.rlnEpochSizeSec = some(self.rlnEpochSizeSec.get().uint64)
  if self.logLevel.isSome():
    conf.logLevel = self.logLevel.get()
  if self.logFormat.isSome():
    conf.logFormat = self.logFormat.get()
  if self.nodeKey.isSome():
    conf.nodekey = self.nodeKey

  conf.tcpPort = self.p2pTcpPort.get(Port(0))
  conf.discv5UdpPort = self.discv5UdpPort.get(Port(0))
  conf.websocketPort = self.websocketPort.get(Port(0))
  conf.quicPort = self.quicPort.get(Port(0))
  conf.websocketSupport = self.websocketSupport.get(false)
  conf.quicSupport = self.quicSupport.get(true)

  return ok(conf)

proc merge*(base, overrides: MessagingClientConf): MessagingClientConf =
  var m = base
  for _, mField, oField in fieldPairs(m, overrides):
    when oField is Option:
      if oField.isSome():
        mField = oField
  return m

proc resolvePreset*(preset: string): ConfResult[MessagingClientConf] =
  ## Preset to messaging-only fields. Kernel-mirrored fields stay unset; the
  ## kernel resolves those from `conf.preset`.
  let npcOpt = ?toNetworkPresetConf(preset, none(uint16))
  if npcOpt.isNone():
    return ok(MessagingClientConf())
  let npc = npcOpt.get()
  return ok(MessagingClientConf(reliabilityEnabled: some(npc.p2pReliability)))
