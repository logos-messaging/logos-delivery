import std/net
import results, libp2p/crypto/crypto

import logos_delivery/api/conf/kernel_conf
import logos_delivery/waku/common/logging
import logos_delivery/waku/factory/networks_config
import logos_delivery/messaging/rate_limit_manager/rate_limit_config

export kernel_conf, rate_limit_config

# `LogosDeliveryMode` and `EntryLayer` are defined at the leaf (`cli_args`) so
# they can appear on `WakuNodeConf`; re-exported here via `kernel_conf`.

type MessagingClientConf* = object
  clusterId* {.name: "cluster-id".}: Opt[uint16] ## Network cluster id.
  numShardsInCluster* {.name: "num-shards-in-network".}: Opt[uint16]
    ## Number of shards in the cluster.
  p2pTcpPort* {.name: "tcp-port".}: Opt[Port] ## TCP listening port.
  discv5UdpPort* {.name: "discv5-udp-port".}: Opt[Port] ## discv5 UDP port.
  websocketSupport* {.name: "websocket-support".}: Opt[bool]
    ## Enable the websocket transport.
  websocketPort* {.name: "websocket-port".}: Opt[Port] ## Websocket listening port.
  quicSupport* {.name: "quic-support".}: Opt[bool] ## Enable the QUIC transport.
  quicPort* {.name: "quic-port".}: Opt[Port] ## QUIC (UDP) listening port.
  listenIpv4* {.name: "listen-address".}: Opt[IpAddress] ## Inbound bind address.
  maxMessageSize* {.name: "max-msg-size".}: Opt[string]
    ## Maximum accepted message size (e.g. "150 KiB").
  entryNodes* {.name: "entry-node".}: Opt[seq[string]]
    ## Bootstrap / connectivity nodes (enrtree or multiaddr).
  ethRpcEndpoints* {.name: "rln-relay-eth-client-address".}: Opt[seq[EthRpcUrl]]
    ## Ethereum RPC endpoints (required for RLN validation); multiple for fail-over.
  rlnContractAddress* {.name: "rln-relay-eth-contract-address".}: Opt[string]
    ## RLN contract address; when set, RLN validation is enabled.
  rlnChainId* {.name: "rln-relay-chain-id".}: Opt[uint]
    ## Chain id the RLN contract is deployed on.
  rlnEpochSizeSec* {.name: "rln-relay-epoch-sec".}: Opt[uint]
    ## RLN epoch size, in seconds.
  reliabilityEnabled* {.name: "reliability".}: Opt[bool]
    ## Enable store-based send reliability.
  store*: Opt[bool] ## Enable the store protocol.
  storenode* {.name: "storenode".}: Opt[string]
  storeMessageDbUrl* {.name: "store-message-db-url".}: Opt[string]
    ## Database connection URL for the store service's persistent storage.
  storeMessageRetentionPolicy* {.name: "store-message-retention-policy".}: Opt[string]
    ## Store retention policy (e.g. "time:3600;size:1GB").
  storeMaxNumDbConnections* {.name: "store-max-num-db-connections".}: Opt[int]
    ## Maximum number of simultaneous store database connections.
  logLevel* {.name: "log-level".}: Opt[logging.LogLevel]
    ## Process log level (TRACE..FATAL); applied by the kernel on node creation.
  logFormat* {.name: "log-format".}: Opt[logging.LogFormat]
    ## Process log format (TEXT or JSON); applied by the kernel on node creation.
  nodeKey* {.name: "nodekey".}: Opt[crypto.PrivateKey]
    ## P2P node private key (64-char hex): stable identity / peerId across restarts.
  rateLimit*: Opt[RateLimitConfig]
    ## Per-epoch message rate limit enforced by the send service. `Opt` like
    ## every other field so `merge` propagates a caller's override; unset falls
    ## back to `DefaultRateLimitConfig` (rate limiting disabled).

proc applyMode*(conf: var WakuNodeConf, mode: LogosDeliveryMode): ConfResult[void] =
  ## Sets the protocol flags implied by the mode.
  case mode
  of LogosDeliveryMode.Core:
    conf.relay = true
    conf.filter = true
    conf.lightpush = true
    conf.discv5Discovery = Opt.some(true)
    conf.peerExchange = true
    conf.rendezvous = true
  of LogosDeliveryMode.Edge:
    conf.peerExchange = true
    conf.relay = false
    conf.filter = false
    conf.lightpush = false
    conf.store = false
  return ok()

proc toWakuNodeConf*(
    self: MessagingClientConf, mode: LogosDeliveryMode
): ConfResult[WakuNodeConf] =
  ## Mode sets the protocol flags; set fields map to their kernel counterpart.
  var conf = ?defaultWakuNodeConf()
  ?applyMode(conf, mode)
  # Keep the `mode` field consistent with the applied flags so a later
  # `LogosDelivery.new(WakuNodeConf)` re-application is idempotent instead of
  # clobbering these flags with the field's default (`Core`).
  conf.mode = mode

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
    conf.rlnRelay = Opt.some(true)
  if self.rlnChainId.isSome():
    conf.rlnRelayChainId = self.rlnChainId.get()
  if self.rlnEpochSizeSec.isSome():
    conf.rlnEpochSizeSec = Opt.some(self.rlnEpochSizeSec.get().uint64)
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
    when oField is Opt:
      if oField.isSome():
        mField = oField
  return m

proc resolvePreset*(preset: string): ConfResult[MessagingClientConf] =
  ## Preset to messaging-only fields. Kernel-mirrored fields stay unset; the
  ## kernel resolves those from `conf.preset`.
  let npcOpt = ?toNetworkPresetConf(preset, Opt.none(uint16))
  if npcOpt.isNone():
    return ok(MessagingClientConf())
  let npc = npcOpt.get()
  return ok(MessagingClientConf(reliabilityEnabled: Opt.some(npc.p2pReliability)))
