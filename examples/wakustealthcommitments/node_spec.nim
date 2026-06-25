{.push raises: [].}

import tools/confutils/cli_args
import logos_delivery/waku/[common/logging, waku, factory/networks_config]
import
  std/[options, strutils, os, sequtils],
  chronicles,
  chronos,
  metrics,
  libp2p/crypto/crypto

export
  networks_config, waku, logging, options, strutils, os, sequtils, stewNet, chronicles,
  chronos, metrics, crypto

proc setup*(): Waku =
  const versionString = "version / git commit hash: " & waku.git_version
  let rng = crypto.newRng()

  let conf = WakuNodeConf.load(version = versionString).valueOr:
    error "failure while loading the configuration", error = $error
    quit(QuitFailure)

  let twnNetworkConf = NetworkPresetConf.TheWakuNetworkConf()
  if len(conf.shards) != 0:
    conf.pubsubTopics = conf.shards.mapIt(twnNetworkConf.pubsubTopics[it.uint16])
  else:
    conf.pubsubTopics = twnNetworkConf.pubsubTopics

  # Override configuration
  conf.maxMessageSize = twnNetworkConf.maxMessageSize
  conf.clusterId = some(twnNetworkConf.clusterId)
  conf.rlnRelayEthContractAddress = twnNetworkConf.rlnRelayEthContractAddress
  conf.rlnRelayDynamic = some(twnNetworkConf.rlnRelayDynamic)
  conf.discv5Discovery = some(twnNetworkConf.discv5Discovery)
  conf.discv5BootstrapNodes =
    conf.discv5BootstrapNodes & twnNetworkConf.discv5BootstrapNodes
  conf.rlnEpochSizeSec = some(twnNetworkConf.rlnEpochSizeSec)
  conf.rlnRelayUserMessageLimit = some(twnNetworkConf.rlnRelayUserMessageLimit)

  # Only set rlnRelay to true if relay is configured
  if conf.relay:
    conf.rlnRelay = some(twnNetworkConf.rlnRelay)

  info "Starting node"
  var waku = (waitFor Waku.new(conf)).valueOr:
    error "Waku initialization failed", error = error
    quit(QuitFailure)

  (waitFor waku.start()).isOkOr:
    error "Starting waku failed", error = error
    quit(QuitFailure)

  # set triggerSelf to false, we don't want to process our own stealthCommitments
  waku.node.wakuRelay.triggerSelf = false

  info "Node setup complete"
  return waku
