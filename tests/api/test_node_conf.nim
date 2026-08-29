{.used.}

import results, testutils/unittests
import
  tools/confutils/cli_args,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/factory/conf_builder/external_discovery_conf_builder,
  logos_delivery/waku/factory/networks_config

suite "WakuNodeConf - preset integration":
  test "TWN preset applies TheWakuNetworkConf":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "twn"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 1

  test "LogosDev preset applies LogosDevConf":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "logosdev"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 3

  test "LogosDev preset routes multiaddr entry nodes into kad bootstrap":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "logosdev"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.kademliaDiscoveryConf.isSome()
    let presetEntryNodes = NetworkPresetConf.LogosDevConf().entryNodes
    check:
      wakuConf.kademliaDiscoveryConf.get().bootstrapNodes.len == presetEntryNodes.len

  test "LogosTest preset applies LogosTestConf":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "logostest"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 2

  test "StatusProd preset applies StatusProdConf":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "status.prod"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 16
      wakuConf.shardingConf.kind == AutoSharding
      wakuConf.shardingConf.numShardsInCluster == 1
      wakuConf.rlnRelayConf.isNone()

  test "Invalid preset returns error":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "status.prod"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 16
      wakuConf.shardingConf.kind == AutoSharding
      wakuConf.shardingConf.numShardsInCluster == 1
      wakuConf.rlnRelayConf.isNone()

  test "Invalid preset returns error":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "nonexistent"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    check wakuConfRes.isErr()

suite "WakuNodeConf - external discovery":
  test "off by default":
    ## Given
    let conf = defaultWakuNodeConf().valueOr:
      raiseAssert error

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then
    ## Nothing can imply intent: the plugin arrives at runtime and carries no
    ## config, so only the explicit flag builds the backend.
    check wakuConf.externalDiscoveryConf.isNone()

  test "enabling it builds the conf with the given intervals":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.enableExternalDiscovery = Opt.some(true)
    conf.externalDiscoveryServiceLookupIntervalMs = 1500
    conf.externalDiscoveryRandomLookupIntervalMs = 2500

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then
    require wakuConf.externalDiscoveryConf.isSome()
    let extConf = wakuConf.externalDiscoveryConf.get()
    check:
      extConf.serviceLookupIntervalMs == 1500
      extConf.randomLookupIntervalMs == 2500

  test "enabling it without intervals falls back to the defaults":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.enableExternalDiscovery = Opt.some(true)

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then
    require wakuConf.externalDiscoveryConf.isSome()
    let extConf = wakuConf.externalDiscoveryConf.get()
    check:
      extConf.serviceLookupIntervalMs == DefaultExternalServiceLookupIntervalMs
      extConf.randomLookupIntervalMs == DefaultExternalRandomLookupIntervalMs
