{.used.}

import std/[strutils, typedthreads]
import results, stint, testutils/unittests
import
  logos_delivery/waku/factory/[preset_registry, waku_conf], tools/confutils/cli_args

const
  LocalEntryNode =
    "/ip4/172.18.0.2/tcp/60000/p2p/16Uiu2HAmQE7FXQc6iZHdBzYfw3qCSDa9dLc1wsBJKoP4aZvztq2d"
  LocalStoreNode =
    "/ip4/172.18.0.3/tcp/60000/p2p/16Uiu2HAm3xVDaz6SRJ6kErwC21zBJEZjavVXg7VSkoWzaV1aMA3F"
  LocalPreset =
    """{"clusterId": 16, "maxMessageSize": "1024KiB", "shardingConf": [32], """ &
    """"extraListenShards": [64], "discv5Discovery": true, "entryNodes": ["""" &
    LocalEntryNode & """"], "storeNodes": ["""" & LocalStoreNode & """"]}"""

proc lookup(name: string): NetworkPresetConf =
  let preset = lookupPreset(name).valueOr:
    raiseAssert error
  require preset.isSome()
  preset.get()

suite "Preset registry - built-in presets":
  test "a built-in preset resolves by its name and its alias":
    check:
      lookup("status.staging").clusterId == 16
      lookup("statusstaging").storeNodes ==
        NetworkPresetConf.StatusStagingConf().storeNodes
      lookup(" Logos.Dev ").clusterId == 3

  test "an empty name is no preset":
    let preset = lookupPreset("").valueOr:
      raiseAssert error
    check preset.isNone()

  test "an unknown name is an error":
    check lookupPreset("nonexistent").isErr()

suite "Preset registry - registered presets":
  test "a registered preset resolves by its name":
    ## When
    let res = registerPreset("Test.Local", LocalPreset)

    ## Then
    require res.isOk()
    let preset = lookup("test.local")
    check:
      preset.clusterId == 16
      preset.maxMessageSize == "1024KiB"
      preset.shardingConf.shards == @[32'u16]
      preset.extraListenShards == @[64'u16]
      preset.discv5Discovery
      preset.entryNodes == @[LocalEntryNode]
      preset.storeNodes == @[LocalStoreNode]
      preset.mixnodes.len == 0
      not preset.rlnRelay

  test "the node conf of a registered preset reaches only its own nodes":
    ## Given
    require registerPreset("test.local-conf", LocalPreset).isOk()
    var conf = defaultKernelConf().valueOr:
      raiseAssert error
    conf.preset = "test.local-conf"

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 16
      wakuConf.shardingConf.shards == @[32'u16]
      wakuConf.staticNodes == @[LocalEntryNode]
      wakuConf.dnsDiscoveryConf.isNone()
      wakuConf.presetStoreNodes == @[LocalStoreNode]

  test "registering a name again replaces the preset":
    require registerPreset("test.replaced", LocalPreset).isOk()
    require registerPreset(
      "test.replaced",
      """{"clusterId": 7, "maxMessageSize": "150KiB", "shardingConf": [0, 1]}""",
    )
      .isOk()

    let preset = lookup("test.replaced")
    check:
      preset.clusterId == 7
      preset.shardingConf.shards == @[0'u16, 1]
      preset.storeNodes.len == 0

  test "static sharding and the chain id":
    require registerPreset(
      "test.static",
      """{"clusterId": 5, "maxMessageSize": "150KiB", "shardingConf": "static", """ &
        """"rlnRelayChainId": 59141}""",
    )
      .isOk()

    let preset = lookup("test.static")
    check:
      preset.shardingConf.kind == StaticSharding
      preset.rlnRelayChainId == 59141.u256

  test "a built-in preset cannot be replaced":
    check:
      registerPreset("twn", LocalPreset).isErr()
      registerPreset("StatusProd", LocalPreset).isErr()
      lookup("twn").clusterId == 1

  test "an invalid preset is rejected and leaves the registry unchanged":
    ## Given
    require registerPreset("test.invalid", LocalPreset).isOk()

    ## When
    let rejected = [
      registerPreset("test.invalid", "not json"),
      registerPreset("test.invalid", "[]"),
      registerPreset("test.invalid", """{"clusterId": 1, "shardingConf": [0]}"""),
      registerPreset("test.invalid", """{"clusterId": 1, "maxMessageSize": "1KiB"}"""),
      registerPreset(
        "test.invalid",
        """{"clusterId": 1, "maxMessageSize": "big", "shardingConf": [0]}""",
      ),
      registerPreset(
        "test.invalid",
        """{"clusterId": 1, "maxMessageSize": "1KiB", "shardingConf": "dynamic"}""",
      ),
      registerPreset(
        "test.invalid",
        """{"clusterId": -1, "maxMessageSize": "1KiB", "shardingConf": [0]}""",
      ),
      registerPreset(
        "test.invalid",
        """{"clusterId": 70000, "maxMessageSize": "1KiB", "shardingConf": [0]}""",
      ),
      registerPreset(
        "test.invalid",
        """{"ClusterId": 1, "maxMessageSize": "1KiB", "shardingConf": [0]}""",
      ),
      registerPreset("", LocalPreset),
    ]

    ## Then
    for res in rejected:
      check res.isErr()
    check lookup("test.invalid").storeNodes == @[LocalStoreNode]

  test "an unknown field names itself in the error":
    let res = registerPreset(
      "test.typo",
      """{"clusterId": 1, "maxMessageSize": "1KiB", "shardingConf": [0], "entryNode": []}""",
    )
    check:
      res.isErr()
      "entryNode" in res.error

proc registerFromThread(name: string) {.thread.} =
  {.cast(gcsafe).}:
    discard registerPreset(name, LocalPreset)

suite "Preset registry - threads":
  test "a preset registered on another thread is visible here":
    ## Given
    var thread: Thread[string]

    ## When
    createThread(thread, registerFromThread, "test.from-thread")
    joinThread(thread)

    ## Then
    check lookup("test.from-thread").storeNodes == @[LocalStoreNode]
