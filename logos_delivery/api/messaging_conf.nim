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

proc toKernelConf*(m: MessagingClientConf, mode: WakuMode): ConfResult[KernelConf] =
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

  if m.store.isSome():
    conf.store = m.store.get()
  if m.storeMessageDbUrl.isSome():
    conf.storeMessageDbUrl = m.storeMessageDbUrl.get()
  if m.storeMessageRetentionPolicy.isSome():
    conf.storeMessageRetentionPolicy = m.storeMessageRetentionPolicy.get()
  if m.storeMaxNumDbConnections.isSome():
    conf.storeMaxNumDbConnections = m.storeMaxNumDbConnections.get()
  if m.storenode.isSome():
    conf.storenode = m.storenode.get()

  if m.clusterId.isSome():
    conf.clusterId = m.clusterId
  if m.numShardsInCluster.isSome():
    conf.numShardsInNetwork = m.numShardsInCluster.get()
  if m.listenIpv4.isSome():
    conf.listenAddress = m.listenIpv4.get()
  if m.maxMessageSize.isSome():
    conf.maxMessageSize = m.maxMessageSize.get()
  if m.entryNodes.isSome():
    conf.entryNodes = m.entryNodes.get()
  if m.ethRpcEndpoints.isSome():
    conf.ethClientUrls = m.ethRpcEndpoints.get()
  if m.rlnContractAddress.isSome():
    conf.rlnRelayEthContractAddress = m.rlnContractAddress.get()
    conf.rlnRelay = some(true)
  if m.rlnChainId.isSome():
    conf.rlnRelayChainId = m.rlnChainId.get()
  if m.rlnEpochSizeSec.isSome():
    conf.rlnEpochSizeSec = some(m.rlnEpochSizeSec.get().uint64)
  if m.reliabilityEnabled.isSome():
    conf.reliabilityEnabled = m.reliabilityEnabled
  if m.logLevel.isSome():
    conf.logLevel = m.logLevel.get()
  if m.logFormat.isSome():
    conf.logFormat = m.logFormat.get()
  if m.nodeKey.isSome():
    conf.nodekey = m.nodeKey

  conf.tcpPort = m.p2pTcpPort.get(Port(0))
  conf.discv5UdpPort = m.discv5UdpPort.get(Port(0))
  conf.websocketPort = m.websocketPort.get(Port(0))
  conf.quicPort = m.quicPort.get(Port(0))
  conf.websocketSupport = m.websocketSupport.get(false)
  conf.quicSupport = m.quicSupport.get(true)

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
