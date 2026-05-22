{.push raises: [].}

import tools/confutils/cli_args
import waku/[common/logging, factory/[waku, networks_config]]
import
  std/[options, strutils, os, sequtils],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  libp2p/crypto/crypto

export
  networks_config, waku, logging, options, strutils, os, sequtils, stewNet, chronicles,
  chronos, metrics, libbacktrace, crypto

proc setup*(): Waku =
  const versionString = "version / git commit hash: " & waku.git_version
  let rng = crypto.newRng()

  let conf = WakuNodeConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = $error
    quit(QuitFailure)

  let twnNetworkConf = NetworkConf.TheWakuNetworkConf()
  if len(conf.shards) != 0:
    conf.pubsubTopics = conf.shards.mapIt(twnNetworkConf.pubsubTopics[it.uint16])
  else:
    conf.pubsubTopics = twnNetworkConf.pubsubTopics

  # Override configuration
  conf.maxMessageSize = twnNetworkConf.maxMessageSize
  conf.clusterId = twnNetworkConf.clusterId
  conf.rlnRelayEthContractAddress = twnNetworkConf.rlnRelayEthContractAddress
  conf.rlnRelayDynamic = twnNetworkConf.rlnRelayDynamic
  conf.discv5Discovery = twnNetworkConf.discv5Discovery
  conf.discv5BootstrapNodes =
    conf.discv5BootstrapNodes & twnNetworkConf.discv5BootstrapNodes
  conf.rlnEpochSizeSec = twnNetworkConf.rlnEpochSizeSec
  conf.rlnRelayUserMessageLimit = twnNetworkConf.rlnRelayUserMessageLimit

  # Only set rlnRelay to true if relay is configured
  if conf.relay:
    conf.rlnRelay = twnNetworkConf.rlnRelay

  info "Starting node"
  var waku = (waitFor Waku.new(conf)).valueOr:
    error "Waku initialization failed", error = error
    quit(QuitFailure)

  (waitFor startWaku(addr waku)).isOkOr:
    error "Starting waku failed", error = error
    quit(QuitFailure)

  # set triggerSelf to false, we don't want to process our own stealthCommitments
  waku.node.wakuRelay.triggerSelf = false

  info "Node setup complete"
  return waku
