{.used.}

import std/strutils
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

suite "WakuNodeConf - service discovery exclusivity":
  test "internal and external together are refused":
    ## The same libp2p protocol from two hosts, each with its own switch and
    ## peer store: the node would join the DHT twice under two identities.
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.enableKadDiscovery = Opt.some(true)
    conf.enableExternalDiscovery = Opt.some(true)

    let res = conf.toWakuConf()
    check:
      res.isErr()
      "mutually exclusive" in res.error

  test "a preset enabling kademlia also collides with external":
    ## The accidental path: the operator names only --enable-external-discovery
    ## and the preset supplies kademlia underneath.
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "logosdev"
    conf.enableExternalDiscovery = Opt.some(true)

    let res = conf.toWakuConf()
    check:
      res.isErr()
      "enable-kad-discovery=false" in res.error

  test "turning kademlia off lets external run under a preset":
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "logosdev"
    conf.enableExternalDiscovery = Opt.some(true)
    conf.enableKadDiscovery = Opt.some(false)

    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error
    check:
      wakuConf.kademliaDiscoveryConf.isNone()
      wakuConf.externalDiscoveryConf.isSome()

  test "either alone, and neither, are all fine":
    ## Both off is a valid node: discv5 or static peers may be doing the work.
    var internalOnly = defaultWakuNodeConf().valueOr:
      raiseAssert error
    internalOnly.enableKadDiscovery = Opt.some(true)
    let a = internalOnly.toWakuConf().valueOr:
      raiseAssert error

    var externalOnly = defaultWakuNodeConf().valueOr:
      raiseAssert error
    externalOnly.enableExternalDiscovery = Opt.some(true)
    let b = externalOnly.toWakuConf().valueOr:
      raiseAssert error

    let c = defaultWakuNodeConf().valueOr(raiseAssert "defaults").toWakuConf().valueOr:
        raiseAssert error

    check:
      a.kademliaDiscoveryConf.isSome() and a.externalDiscoveryConf.isNone()
      b.kademliaDiscoveryConf.isNone() and b.externalDiscoveryConf.isSome()
      c.kademliaDiscoveryConf.isNone() and c.externalDiscoveryConf.isNone()

  test "discv5 stays independent of both":
    ## Discv5 is a different protocol over a different peer set; the exclusion
    ## rule must not touch it.
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.discv5Discovery = Opt.some(true)
    conf.enableExternalDiscovery = Opt.some(true)

    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error
    check:
      wakuConf.discv5Conf.isSome()
      wakuConf.externalDiscoveryConf.isSome()
