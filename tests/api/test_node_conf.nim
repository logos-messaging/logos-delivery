{.used.}

import std/[options, strutils], results, stint, testutils/unittests, chronos
import
  waku/api/api_conf,
  waku/factory/waku_conf,
  waku/factory/networks_config,
  waku/factory/conf_builder/conf_builder
import std/[options, json, strutils], results, stint, testutils/unittests
import json_serialization
import confutils, confutils/std/net
import tools/confutils/cli_args
import waku/factory/waku_conf, waku/factory/networks_config
import waku/common/logging

# Helper: parse JSON into WakuNodeConf using fieldPairs (same as liblogosdelivery)
proc parseWakuNodeConfFromJson(jsonStr: string): Result[WakuNodeConf, string] =
  var conf = defaultWakuNodeConf().valueOr:
    return err(error)
  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(jsonStr)
  except Exception:
    return err("JSON parse error: " & getCurrentExceptionMsg())
  for confField, confValue in fieldPairs(conf):
    if jsonNode.contains(confField):
      let formattedString = ($jsonNode[confField]).strip(chars = {'\"'})
      try:
        confValue = parseCmdArg(typeof(confValue), formattedString)
      except Exception:
        return err(
          "Field '" & confField & "' parse error: " & getCurrentExceptionMsg() &
            ". Value: " & formattedString
        )
  return ok(conf)

suite "WakuNodeConf - mode-driven toWakuConf":
  test "Core mode enables service protocols":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.mode = Core
    conf.clusterId = 1

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == true
      wakuConf.lightPush == true
      wakuConf.peerExchangeService == true
      wakuConf.rendezvous == true
      wakuConf.clusterId == 1

  test "Edge mode disables service protocols":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.mode = Edge
    conf.clusterId = 1

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == false
      wakuConf.lightPush == false
      wakuConf.filterServiceConf.isSome() == false
      wakuConf.storeServiceConf.isSome() == false
      wakuConf.peerExchangeService == true

  test "noMode uses explicit CLI flags as-is":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.mode = WakuMode.noMode
    conf.relay = true
    conf.lightpush = false
    conf.clusterId = 5

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == true
      wakuConf.lightPush == false
      wakuConf.clusterId == 5

  test "Core mode overrides individual protocol flags":
    ## Given - user sets relay=false but mode=Core should override
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.mode = Core
    conf.relay = false # will be overridden by Core mode

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == true # mode overrides

suite "WakuNodeConf - JSON parsing with fieldPairs":
  test "Empty JSON produces valid default conf":
    ## Given / When
    let confRes = parseWakuNodeConfFromJson("{}")

    ## Then
    require confRes.isOk()
    let conf = confRes.get()
    check:
      conf.mode == WakuMode.noMode
      conf.clusterId == 0
      conf.logLevel == logging.LogLevel.INFO

  test "JSON with mode and clusterId":
    ## Given / When
    let confRes = parseWakuNodeConfFromJson("""{"mode": "Core", "clusterId": 42}""")

    ## Then
    require confRes.isOk()
    let conf = confRes.get()
    check:
      conf.mode == Core
      conf.clusterId == 42

  test "JSON with Edge mode":
    ## Given / When
    let confRes = parseWakuNodeConfFromJson("""{"mode": "Edge"}""")

    ## Then
    require confRes.isOk()
    let conf = confRes.get()
    check:
      conf.mode == Edge

  test "JSON with logLevel":
    ## Given / When
    let confRes = parseWakuNodeConfFromJson("""{"logLevel": "DEBUG"}""")

    ## Then
    require confRes.isOk()
    let conf = confRes.get()
    check:
      conf.logLevel == logging.LogLevel.DEBUG

  test "JSON with sharding config":
    ## Given / When
    let confRes =
      parseWakuNodeConfFromJson("""{"clusterId": 99, "numShardsInNetwork": 16}""")

    ## Then
    require confRes.isOk()
    let conf = confRes.get()
    check:
      conf.clusterId == 99
      conf.numShardsInNetwork == 16

  test "JSON with unknown fields is silently ignored":
    ## Given / When
    let confRes =
      parseWakuNodeConfFromJson("""{"unknownField": true, "clusterId": 5}""")

    ## Then - unknown fields are just ignored (not in fieldPairs)
    require confRes.isOk()
    let conf = confRes.get()
    check:
      conf.clusterId == 5

  test "Invalid JSON syntax returns error":
    ## Given / When
    let confRes = parseWakuNodeConfFromJson("{ not valid json }")

    ## Then
    check confRes.isErr()

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

  test "Invalid preset returns error":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "nonexistent"

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    check wakuConfRes.isErr()

suite "WakuNodeConf JSON -> WakuConf integration":
  test "Core mode JSON config produces valid WakuConf":
    ## Given
    let confRes = parseWakuNodeConfFromJson(
      """{"mode": "Core", "clusterId": 55, "numShardsInNetwork": 6}"""
    )
    require confRes.isOk()
    let conf = confRes.get()

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == true
      wakuConf.lightPush == true
      wakuConf.peerExchangeService == true
      wakuConf.clusterId == 55
      wakuConf.shardingConf.numShardsInCluster == 6

  test "Edge mode JSON config produces valid WakuConf":
    ## Given
    let confRes = parseWakuNodeConfFromJson("""{"mode": "Edge", "clusterId": 1}""")
    require confRes.isOk()
    let conf = confRes.get()

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.relay == false
      wakuConf.lightPush == false
      wakuConf.peerExchangeService == true

  test "JSON with preset produces valid WakuConf":
    ## Given
    let confRes =
      parseWakuNodeConfFromJson("""{"mode": "Core", "preset": "logosdev"}""")
    require confRes.isOk()
    let conf = confRes.get()

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 2
      wakuConf.relay == true

  test "JSON with static nodes":
    ## Given
    let confRes = parseWakuNodeConfFromJson(
      """{"mode": "Core", "clusterId": 42, "staticnodes": ["/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"]}"""
    )
    require confRes.isOk()
    let conf = confRes.get()

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.staticNodes.len == 1

  test "JSON with max message size":
    ## Given
    let confRes =
      parseWakuNodeConfFromJson("""{"clusterId": 42, "maxMessageSize": "100KiB"}""")
    require confRes.isOk()
    let conf = confRes.get()

    ## When
    let wakuConfRes = conf.toWakuConf()

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.maxMessageSizeBytes == 100'u64 * 1024'u64

# ---- Deprecated NodeConfig tests (kept for backward compatibility) ----

{.push warning[Deprecated]: off.}

import waku/api/api_conf

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

suite "WakuConfBuilder - store retention policies":
  test "Multiple retention policies":
    ## Given
    var b = WakuConfBuilder.init()
    b.storeServiceConf.withEnabled(true)
    b.storeServiceConf.withDbUrl("sqlite://test.db")
    b.storeServiceConf.withRetentionPolicies(@["time:86400", "capacity:10000"])

    ## When
    let wakuConf = b.build().valueOr:
      raiseAssert error

    ## Then
    require wakuConf.storeServiceConf.isSome()
    let storeConf = wakuConf.storeServiceConf.get()
    check storeConf.retentionPolicies == @["time:86400", "capacity:10000"]

  test "Duplicated retention policies returns error":
    ## Given
    var b = WakuConfBuilder.init()
    b.storeServiceConf.withEnabled(true)
    b.storeServiceConf.withDbUrl("sqlite://test.db")
    b.storeServiceConf.withRetentionPolicies(@["time:86400", "time:800", "capacity:10000"])

    ## When
    let wakuConfRes = b.build()
    check wakuConfRes.isErr()
    check wakuConfRes.error.contains("duplicated retention policy type")

  test "Incorrect retention policy type returns error":
    ## Given
    var b = WakuConfBuilder.init()
    b.storeServiceConf.withEnabled(true)
    b.storeServiceConf.withDbUrl("sqlite://test.db")
    b.storeServiceConf.withRetentionPolicies(@["capaity:10000"])

    ## When
    let wakuConfRes = b.build()

    ## Then
    check wakuConfRes.isErr()
    check wakuConfRes.error.contains("unknown retention policy type")

  test "Store disabled - no retention policy applied":
    ## Given
    var b = WakuConfBuilder.init()
    # storeServiceConf not enabled

    ## When
    let wakuConf = b.build().valueOr:
      raiseAssert error

    ## Then
    check wakuConf.storeServiceConf.isNone()
