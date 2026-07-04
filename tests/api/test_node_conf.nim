{.used.}

import std/options, results, testutils/unittests
import
  tools/confutils/cli_args,
  logos_delivery/waku/factory/waku_conf,
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
      wakuConf.clusterId == 2

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

# ---- Deprecated NodeConfig tests (kept for backward compatibility) ----

{.push warning[Deprecated]: off.}

import logos_delivery/api/api_conf

suite "NodeConfig (deprecated) - toWakuConf":
  test "Minimal configuration":
    let nodeConfig = NodeConfig.init(ethRpcEndpoints = @["http://someaddress"])
    let wakuConfRes = api_conf.toWakuConf(nodeConfig)
    let wakuConf = wakuConfRes.valueOr:
      raiseAssert error
    wakuConf.validate().isOkOr:
      raiseAssert error
    check:
      wakuConf.clusterId == 1
      wakuConf.shardingConf.numShardsInCluster == 8
      wakuConf.staticNodes.len == 0

  test "Edge mode configuration":
    let protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 1)
    let nodeConfig =
      NodeConfig.init(mode = api_conf.WakuMode.Edge, protocolsConfig = protocolsConfig)
    let wakuConfRes = api_conf.toWakuConf(nodeConfig)
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == false
      wakuConf.lightPush == false
      wakuConf.peerExchangeService == true

  test "Core mode configuration":
    let protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 1)
    let nodeConfig =
      NodeConfig.init(mode = api_conf.WakuMode.Core, protocolsConfig = protocolsConfig)
    let wakuConfRes = api_conf.toWakuConf(nodeConfig)
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == true
      wakuConf.lightPush == true
      wakuConf.peerExchangeService == true

{.pop.}
