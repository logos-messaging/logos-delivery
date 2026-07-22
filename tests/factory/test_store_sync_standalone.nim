{.used.}

import results, testutils/unittests, chronos, libp2p/protocols/connectivity/relay/relay

import
  tests/testlib/[wakunode, wakucore],
  logos_delivery/waku/[waku_node, waku_enr],
  logos_delivery/waku/factory/[node_factory, conf_builder/conf_builder]

suite "Store Sync standalone (no store service)":
  asynctest "store-sync without store service mounts sync backed by a small archive":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.storeSyncConf.withEnabled(true)
    confBuilder.storeSyncConf.withRangeSec(1800)
    confBuilder.storeSyncConf.withIntervalSec(60)
    confBuilder.storeSyncConf.withRelayJitterSec(20)
    let conf = confBuilder.build().value

    check:
      conf.storeSyncConf.isSome()
      conf.storeServiceConf.isNone()
      conf.wakuFlags.supportsCapability(Capabilities.Sync)

    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    check:
      not node.isNil()
      not node.wakuArchive.isNil()
      not node.wakuStoreReconciliation.isNil()
      not node.wakuStoreTransfer.isNil()
      node.wakuStore.isNil()

  asynctest "store service with store-sync keeps the store-node shape":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.storeServiceConf.withEnabled(true)
    confBuilder.storeServiceConf.withDbUrl("sqlite://:memory:")
    confBuilder.storeSyncConf.withEnabled(true)
    confBuilder.storeSyncConf.withRangeSec(3600)
    confBuilder.storeSyncConf.withIntervalSec(300)
    confBuilder.storeSyncConf.withRelayJitterSec(20)
    let conf = confBuilder.build().value

    check:
      conf.storeServiceConf.isSome()
      conf.storeSyncConf.isSome()
      conf.wakuFlags.supportsCapability(Capabilities.Sync)
      conf.wakuFlags.supportsCapability(Capabilities.Store)

    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    check:
      not node.isNil()
      not node.wakuStore.isNil()
      not node.wakuArchive.isNil()
      not node.wakuStoreReconciliation.isNil()
      not node.wakuStoreTransfer.isNil()

  test "store-sync disabled leaves conf empty and Sync capability unset":
    let conf = defaultTestWakuConf()

    check:
      conf.storeSyncConf.isNone()
      not conf.wakuFlags.supportsCapability(Capabilities.Sync)

  test "store-sync rejects a zero sync range":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.storeSyncConf.withEnabled(true)
    confBuilder.storeSyncConf.withRangeSec(0)
    confBuilder.storeSyncConf.withIntervalSec(60)
    confBuilder.storeSyncConf.withRelayJitterSec(20)

    check confBuilder.build().isErr()

  test "store-sync rejects an unsupported db engine":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.storeSyncConf.withEnabled(true)
    confBuilder.storeSyncConf.withRangeSec(1800)
    confBuilder.storeSyncConf.withIntervalSec(60)
    confBuilder.storeSyncConf.withRelayJitterSec(20)
    confBuilder.storeSyncConf.withDbUrl("bogus://nope")

    check confBuilder.build().isErr()
