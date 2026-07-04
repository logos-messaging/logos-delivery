{.used.}

import std/[options, net], results, chronos, testutils/unittests
import brokers/broker_context
import logos_delivery
import logos_delivery/api/messaging_conf_json
import logos_delivery/waku/factory/[waku_conf, networks_config]
import logos_delivery/waku/common/logging

suite "MessagingClientConf - mode expansion (toKernelConf)":
  test "Core mode enables relay + service protocols":
    let conf = MessagingClientConf().toKernelConf(WakuMode.Core).valueOr:
        raiseAssert error
    check:
      conf.relay == true
      conf.filter == true
      conf.lightpush == true
      conf.discv5Discovery == some(true)
      conf.peerExchange == true
      conf.rendezvous == true

  test "Edge mode is client-only (no relay/filter/lightpush/store)":
    let conf = MessagingClientConf().toKernelConf(WakuMode.Edge).valueOr:
        raiseAssert error
    check:
      conf.relay == false
      conf.filter == false
      conf.lightpush == false
      conf.store == false
      conf.peerExchange == true
      conf.discv5Discovery == some(true) # discovery stays on; mode does not force it off

suite "MessagingClientConf - field mapping + transport policy":
  test "set fields are written to their kernel counterparts":
    let m = MessagingClientConf(
      clusterId: some(3'u16),
      numShardsInCluster: some(4'u16),
      maxMessageSize: some("150KiB"),
    )
    let conf = m.toKernelConf(WakuMode.Core).valueOr:
      raiseAssert error
    check:
      conf.clusterId == some(3'u16)
      conf.numShardsInNetwork == 4
      conf.maxMessageSize == "150KiB"

  test "messaging transport defaults: ephemeral ports, websocket off, quic on":
    let conf = MessagingClientConf().toKernelConf(WakuMode.Core).valueOr:
        raiseAssert error
    check:
      conf.tcpPort == Port(0)
      conf.discv5UdpPort == Port(0)
      conf.websocketSupport == false
      conf.quicSupport == true

  test "explicit transport overrides win":
    let m = MessagingClientConf(
      p2pTcpPort: some(Port(1234)),
      websocketSupport: some(true),
      quicSupport: some(false),
    )
    let conf = m.toKernelConf(WakuMode.Core).valueOr:
      raiseAssert error
    check:
      conf.tcpPort == Port(1234)
      conf.websocketSupport == true
      conf.quicSupport == false

suite "MessagingClientConf - preset resolution":
  test "resolvePreset lifts only messaging-exclusive fields, not kernel-mirrored ones":
    let m = resolvePreset("twn").valueOr:
      raiseAssert error
    check:
      m.reliabilityEnabled.isSome()
      m.clusterId.isNone()
      m.maxMessageSize.isNone()

  test "resolvePreset does not lift entryNodes":
    let m = resolvePreset("logostest").valueOr:
      raiseAssert error
    check m.entryNodes.isNone()

  test "empty preset resolves to an empty config":
    let m = resolvePreset("").valueOr:
      raiseAssert error
    check:
      m.clusterId.isNone()
      m.maxMessageSize.isNone()

  test "a messaging override of a kernel-mirrored field wins over the preset":
    let presetConf = resolvePreset("logos.dev").valueOr:
      raiseAssert error
    let merged = merge(presetConf, MessagingClientConf(numShardsInCluster: some(1'u16)))
    var kernelConf = toKernelConf(merged, WakuMode.Core).valueOr:
      raiseAssert error
    kernelConf.preset = "logos.dev"
    let wakuConf = kernelConf.toWakuConf().valueOr:
      raiseAssert error
    check:
      wakuConf.shardingConf.kind == AutoSharding
      wakuConf.shardingConf.numShardsInCluster == 1

suite "MessagingClientConf - merge (override wins)":
  test "a set override field wins; unset keeps the base":
    let base = MessagingClientConf(clusterId: some(1'u16), maxMessageSize: some("1MB"))
    let overrides = MessagingClientConf(clusterId: some(2'u16))
    let m = merge(base, overrides)
    check:
      m.clusterId == some(2'u16) # override wins
      m.maxMessageSize == some("1MB") # base preserved

suite "MessagingConfJson - JSON parsing":
  test "empty object -> Core (default), empty preset, empty overrides":
    let mc = parseMessagingConf("{}").valueOr:
      raiseAssert error
    check:
      mc.mode == WakuMode.Core
      mc.preset == ""
      mc.messaging.clusterId.isNone()

  test "mode + preset are parsed":
    let mc = parseMessagingConf("""{"mode": "Edge", "preset": "logostest"}""").valueOr:
      raiseAssert error
    check:
      mc.mode == WakuMode.Edge
      mc.preset == "logostest"

  test "messagingOverrides parsed into the partial":
    let mc = parseMessagingConf(
      """{"mode": "Core", "messagingOverrides": {"clusterId": 7, "reliabilityEnabled": true}}"""
    ).valueOr:
      raiseAssert error
    check:
      mc.mode == WakuMode.Core
      mc.messaging.clusterId == some(7'u16)
      mc.messaging.reliabilityEnabled == some(true)

  test "channelsOverrides parsed into the partial":
    let mc = parseMessagingConf(
      """{"channelsOverrides": {"rateLimitEnabled": true, "sdsMaxRetransmissions": 9}}"""
    ).valueOr:
      raiseAssert error
    check:
      mc.channels.rateLimitEnabled == some(true)
      mc.channels.sdsMaxRetransmissions == some(9)

  test "invalid mode is rejected (Core or Edge only)":
    check parseMessagingConf("""{"mode": "bogus"}""").isErr()
    check parseMessagingConf("""{"mode": "noMode"}""").isErr()
    check parseMessagingConf("""{"mode": ""}""").isErr()

  test "invalid JSON is rejected":
    check parseMessagingConf("{ not json }").isErr()

  test "unknown top-level keys are rejected":
    check parseMessagingConf("""{"logLevel": "INFO", "mode": "Core"}""").isErr()

  test "override keys accept CLI switch names":
    let mc = parseMessagingConf(
      """{"messagingOverrides": {"cluster-id": 7, "reliability": true, "tcp-port": 1234}}"""
    ).valueOr:
      raiseAssert error
    check:
      mc.messaging.clusterId == some(7'u16)
      mc.messaging.reliabilityEnabled == some(true)
      mc.messaging.p2pTcpPort == some(Port(1234))

  test "unknown keys inside an overrides body are rejected":
    check parseMessagingConf("""{"messagingOverrides": {"bogusKey": 1}}""").isErr()
    check parseMessagingConf("""{"channelsOverrides": {"bogusKey": 1}}""").isErr()

  test "a field set via both its name and its switch name is rejected":
    check parseMessagingConf(
      """{"messagingOverrides": {"clusterId": 5, "cluster-id": 5}}"""
    )
      .isErr()

  test "logLevel and nodeKey parse via switch names and map to the kernel":
    let mc = parseMessagingConf(
      """{"messagingOverrides": {"log-level": "DEBUG", "log-format": "JSON", "nodekey": "0d714a1fada214dead6dc9c7274581ec20ff292451866e7d6d677dc818e8ccd2"}}"""
    ).valueOr:
      raiseAssert error
    check:
      mc.messaging.logLevel == some(logging.LogLevel.DEBUG)
      mc.messaging.logFormat == some(logging.LogFormat.JSON)
      mc.messaging.nodeKey.isSome()
    let conf = mc.messaging.toKernelConf(WakuMode.Core).valueOr:
      raiseAssert error
    check:
      conf.logLevel == logging.LogLevel.DEBUG
      conf.logFormat == logging.LogFormat.JSON
      conf.nodekey.isSome()

  test "a null value leaves the field unset":
    let mc = parseMessagingConf(
      """{"messagingOverrides": {"store": null, "clusterId": 7}}"""
    ).valueOr:
      raiseAssert error
    check:
      mc.messaging.store.isNone()
      mc.messaging.clusterId == some(7'u16)

  test "an invalid Ethereum RPC URL is rejected at parse time":
    check parseMessagingConf(
      """{"messagingOverrides": {"rln-relay-eth-client-address": ["ws://node:8546"]}}"""
    )
      .isErr()
    let mc = parseMessagingConf(
      """{"messagingOverrides": {"rln-relay-eth-client-address": ["http://localhost:8540/"]}}"""
    ).valueOr:
      raiseAssert error
    check mc.messaging.ethRpcEndpoints.isSome()

  test "store backend fields parse and map to the kernel":
    let mc = parseMessagingConf(
      """{"messagingOverrides": {"store": true, "store-message-db-url": "sqlite://test.db", "store-message-retention-policy": "time:3600", "store-max-num-db-connections": 7}}"""
    ).valueOr:
      raiseAssert error
    let conf = mc.messaging.toKernelConf(WakuMode.Core).valueOr:
      raiseAssert error
    check:
      conf.store == true
      conf.storeMessageDbUrl == "sqlite://test.db"
      conf.storeMessageRetentionPolicy == "time:3600"
      conf.storeMaxNumDbConnections == 7

  test "a not-JSON-settable field is rejected":
    check parseMessagingConf("""{"channelsOverrides": {"sdsPersistence": 1}}""").isErr()

suite "LogosDelivery.newMessaging - construction (the app-dev entry)":
  asyncTest "builds the full messaging stack from mode + overrides":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.newMessaging(
          WakuMode.Core,
          "",
          MessagingClientConf(
            clusterId: some(3'u16),
            numShardsInCluster: some(1'u16),
            listenIpv4: some(parseIpAddress("0.0.0.0")),
            reliabilityEnabled: some(true),
          ),
        )
      ).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      not node.messagingClient.isNil()
      not node.reliableChannelManager.isNil()
    (await node.stop()).expect("stop")

  asyncTest "builds from a network preset":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.newMessaging(
          WakuMode.Core,
          "logostest",
          MessagingClientConf(listenIpv4: some(parseIpAddress("0.0.0.0"))),
        )
      ).valueOr:
        raiseAssert error
    check not node.waku.isNil()
    (await node.stop()).expect("stop")

suite "MessagingClientConf - store override":
  test "store opt-in overrides the mode default; protocol flags follow the mode":
    let conf = MessagingClientConf(store: some(true)).toKernelConf(WakuMode.Edge).valueOr:
      raiseAssert error
    check:
      conf.store == true # Edge defaults store off; the explicit opt-in wins
      conf.relay == false # protocols are owned by the mode, not overridable
