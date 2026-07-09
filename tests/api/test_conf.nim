{.used.}

import std/[options, net], results, chronos, testutils/unittests
import brokers/broker_context
import logos_delivery
import logos_delivery/api/logos_delivery_conf_json
import logos_delivery/waku/factory/[waku_conf, networks_config]
import logos_delivery/waku/common/logging

suite "MessagingClientConf - mode expansion (toKernelConf)":
  test "Core mode enables relay + service protocols":
    let kc = MessagingClientConf().toKernelConf(WakuMode.Core).valueOr:
        raiseAssert error
    check:
      kc.relay == true
      kc.filter == true
      kc.lightpush == true
      kc.discv5Discovery == some(true)
      kc.peerExchange == true
      kc.rendezvous == true

  test "Edge mode is client-only (no relay/filter/lightpush/store)":
    let kc = MessagingClientConf().toKernelConf(WakuMode.Edge).valueOr:
        raiseAssert error
    check:
      kc.relay == false
      kc.filter == false
      kc.lightpush == false
      kc.store == false
      kc.peerExchange == true
      kc.discv5Discovery == some(true) # discovery stays on; mode does not force it off

suite "MessagingClientConf - field mapping + transport policy":
  test "set fields are written to their kernel counterparts":
    let mc = MessagingClientConf(
      clusterId: some(3'u16),
      numShardsInCluster: some(4'u16),
      maxMessageSize: some("150KiB"),
    )
    let kc = mc.toKernelConf(WakuMode.Core).valueOr:
      raiseAssert error
    check:
      kc.clusterId == some(3'u16)
      kc.numShardsInNetwork == 4
      kc.maxMessageSize == "150KiB"

  test "messaging transport defaults: ephemeral ports, websocket off, quic on":
    let kc = MessagingClientConf().toKernelConf(WakuMode.Core).valueOr:
        raiseAssert error
    check:
      kc.tcpPort == Port(0)
      kc.discv5UdpPort == Port(0)
      kc.websocketSupport == false
      kc.quicSupport == true

  test "explicit transport overrides win":
    let mc = MessagingClientConf(
      p2pTcpPort: some(Port(1234)),
      websocketSupport: some(true),
      quicSupport: some(false),
    )
    let kc = mc.toKernelConf(WakuMode.Core).valueOr:
      raiseAssert error
    check:
      kc.tcpPort == Port(1234)
      kc.websocketSupport == true
      kc.quicSupport == false

suite "MessagingClientConf - preset resolution":
  test "resolvePreset lifts only messaging-exclusive fields, not kernel-mirrored ones":
    let mc = resolvePreset("twn").valueOr:
      raiseAssert error
    check:
      mc.reliabilityEnabled.isSome()
      mc.clusterId.isNone()
      mc.maxMessageSize.isNone()

  test "resolvePreset does not lift entryNodes":
    let mc = resolvePreset("logostest").valueOr:
      raiseAssert error
    check mc.entryNodes.isNone()

  test "empty preset resolves to an empty config":
    let mc = resolvePreset("").valueOr:
      raiseAssert error
    check:
      mc.clusterId.isNone()
      mc.maxMessageSize.isNone()

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
    let mc = merge(base, overrides)
    check:
      mc.clusterId == some(2'u16) # override wins
      mc.maxMessageSize == some("1MB") # base preserved

suite "parseLogosDeliveryConf - JSON parsing":
  test "empty object -> Core (default), empty preset, empty overrides":
    let lc = parseLogosDeliveryConf("{}").valueOr:
      raiseAssert error
    check:
      lc.kernelConf.relay == true # Core enables relay
      lc.kernelConf.preset == ""
      lc.messagingConf.clusterId.isNone()

  test "mode + preset are parsed":
    let lc = parseLogosDeliveryConf("""{"mode": "Edge", "preset": "logostest"}""").valueOr:
      raiseAssert error
    check:
      lc.kernelConf.preset == "logostest"
      lc.kernelConf.relay == false # Edge disables relay

  test "messagingOverrides parsed into the partial":
    let lc = parseLogosDeliveryConf(
      """{"mode": "Core", "messagingOverrides": {"clusterId": 7, "reliabilityEnabled": true}}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.messagingConf.clusterId == some(7'u16)
      lc.messagingConf.reliabilityEnabled == some(true)

  test "channelsOverrides parsed into the partial":
    let lc = parseLogosDeliveryConf(
      """{"channelsOverrides": {"rateLimitEnabled": true, "sdsMaxRetransmissions": 9}}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.channelsConf.rateLimitEnabled == some(true)
      lc.channelsConf.sdsMaxRetransmissions == some(9)

  test "invalid mode is rejected (Core or Edge only)":
    check parseLogosDeliveryConf("""{"mode": "bogus"}""").isErr()
    check parseLogosDeliveryConf("""{"mode": "noMode"}""").isErr()
    check parseLogosDeliveryConf("""{"mode": ""}""").isErr()

  test "invalid JSON is rejected":
    check parseLogosDeliveryConf("{ not json }").isErr()

  test "unknown top-level keys are rejected":
    check parseLogosDeliveryConf("""{"logLevel": "INFO", "mode": "Core"}""").isErr()

  test "override keys accept CLI switch names":
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"cluster-id": 7, "reliability": true, "tcp-port": 1234}}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.messagingConf.clusterId == some(7'u16)
      lc.messagingConf.reliabilityEnabled == some(true)
      lc.messagingConf.p2pTcpPort == some(Port(1234))

  test "unknown keys inside an overrides body are rejected":
    check parseLogosDeliveryConf("""{"messagingOverrides": {"bogusKey": 1}}""").isErr()
    check parseLogosDeliveryConf("""{"channelsOverrides": {"bogusKey": 1}}""").isErr()

  test "a field set via both its name and its switch name is rejected":
    check parseLogosDeliveryConf(
      """{"messagingOverrides": {"clusterId": 5, "cluster-id": 5}}"""
    )
      .isErr()

  test "logLevel and nodeKey parse via switch names and map to the kernel":
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"log-level": "DEBUG", "log-format": "JSON", "nodekey": "0d714a1fada214dead6dc9c7274581ec20ff292451866e7d6d677dc818e8ccd2"}}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.kernelConf.logLevel == logging.LogLevel.DEBUG
      lc.kernelConf.logFormat == logging.LogFormat.JSON
      lc.kernelConf.nodekey.isSome()

  test "a null value leaves the field unset":
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"store": null, "clusterId": 7}}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.messagingConf.store.isNone()
      lc.messagingConf.clusterId == some(7'u16)

  test "an invalid Ethereum RPC URL is rejected at parse time":
    check parseLogosDeliveryConf(
      """{"messagingOverrides": {"rln-relay-eth-client-address": ["ws://node:8546"]}}"""
    )
      .isErr()
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"rln-relay-eth-client-address": ["http://localhost:8540/"]}}"""
    ).valueOr:
      raiseAssert error
    check lc.kernelConf.ethClientUrls.len == 1

  test "store backend fields parse and map to the kernel":
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"store": true, "store-message-db-url": "sqlite://test.db", "store-message-retention-policy": "time:3600", "store-max-num-db-connections": 7}}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.kernelConf.store == true
      lc.kernelConf.storeMessageDbUrl == "sqlite://test.db"
      lc.kernelConf.storeMessageRetentionPolicy == "time:3600"
      lc.kernelConf.storeMaxNumDbConnections == 7

suite "LogosDelivery.new - construction (the app-dev entry)":
  asyncTest "builds the full messaging stack from mode + overrides":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
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
        await LogosDelivery.new(
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
    let kc = MessagingClientConf(store: some(true)).toKernelConf(WakuMode.Edge).valueOr:
      raiseAssert error
    check:
      kc.store == true # Edge defaults store off; the explicit opt-in wins
      kc.relay == false # protocols are owned by the mode, not overridable
