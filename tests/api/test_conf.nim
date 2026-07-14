{.used.}

import std/net, results, chronos, testutils/unittests
import brokers/broker_context
import logos_delivery
import logos_delivery/api/conf/logos_delivery_conf_json
import logos_delivery/waku/factory/[waku_conf, networks_config]
import logos_delivery/waku/common/logging

suite "MessagingClientConf - mode expansion (toWakuNodeConf)":
  test "Core mode enables relay + service protocols":
    let kc = MessagingClientConf().toWakuNodeConf(LogosDeliveryMode.Core).valueOr:
        raiseAssert error
    check:
      kc.relay == true
      kc.filter == true
      kc.lightpush == true
      kc.discv5Discovery == Opt.some(true)
      kc.peerExchange == true
      kc.rendezvous == true

  test "Edge mode is client-only (no relay/filter/lightpush/store)":
    let kc = MessagingClientConf().toWakuNodeConf(LogosDeliveryMode.Edge).valueOr:
        raiseAssert error
    check:
      kc.relay == false
      kc.filter == false
      kc.lightpush == false
      kc.store == false
      kc.peerExchange == true
      kc.discv5Discovery == Opt.some(true)
        # discovery stays on; mode does not force it off

suite "MessagingClientConf - field mapping + transport policy":
  test "set fields are written to their kernel counterparts":
    let mc = MessagingClientConf(
      clusterId: Opt.some(3'u16),
      numShardsInCluster: Opt.some(4'u16),
      maxMessageSize: Opt.some("150KiB"),
    )
    let kc = mc.toWakuNodeConf(LogosDeliveryMode.Core).valueOr:
      raiseAssert error
    check:
      kc.clusterId == Opt.some(3'u16)
      kc.numShardsInNetwork == 4
      kc.maxMessageSize == "150KiB"

  test "messaging transport defaults: ephemeral ports, websocket off, quic on":
    let kc = MessagingClientConf().toWakuNodeConf(LogosDeliveryMode.Core).valueOr:
        raiseAssert error
    check:
      kc.tcpPort == Port(0)
      kc.discv5UdpPort == Port(0)
      kc.websocketSupport == false
      kc.quicSupport == true

  test "explicit transport overrides win":
    let mc = MessagingClientConf(
      p2pTcpPort: Opt.some(Port(1234)),
      websocketSupport: Opt.some(true),
      quicSupport: Opt.some(false),
    )
    let kc = mc.toWakuNodeConf(LogosDeliveryMode.Core).valueOr:
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
    let merged =
      merge(presetConf, MessagingClientConf(numShardsInCluster: Opt.some(1'u16)))
    var kernelConf = toWakuNodeConf(merged, LogosDeliveryMode.Core).valueOr:
      raiseAssert error
    kernelConf.preset = "logos.dev"
    let wakuConf = kernelConf.toWakuConf().valueOr:
      raiseAssert error
    check:
      wakuConf.shardingConf.kind == AutoSharding
      wakuConf.shardingConf.numShardsInCluster == 1

suite "MessagingClientConf - merge (override wins)":
  test "a set override field wins; unset keeps the base":
    let base =
      MessagingClientConf(clusterId: Opt.some(1'u16), maxMessageSize: Opt.some("1MB"))
    let overrides = MessagingClientConf(clusterId: Opt.some(2'u16))
    let mc = merge(base, overrides)
    check:
      mc.clusterId == Opt.some(2'u16) # override wins
      mc.maxMessageSize == Opt.some("1MB") # base preserved

suite "parseLogosDeliveryConf - JSON parsing":
  test "empty object resolves to a full Core node conf":
    let lc = parseLogosDeliveryConf("{}").valueOr:
      raiseAssert error
    check:
      lc.messagingConf.isSome() # full node: messaging + channels mounted
      lc.channelsConf.isSome()
      WakuNodeConf(lc.kernelConf).relay == true # Core enables relay
      WakuNodeConf(lc.kernelConf).clusterId.isNone() # no cluster set

  test "mode + preset fold into the kernel conf":
    let lc = parseLogosDeliveryConf("""{"mode": "Edge", "preset": "logostest"}""").valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.preset == "logostest"
      kc.relay == false # Edge disables relay

  test "messaging overrides split: kernel fields to the kernel, reliability to the record":
    let lc = parseLogosDeliveryConf(
      """{"mode": "Core", "messagingOverrides": {"clusterId": 7, "reliabilityEnabled": true}}"""
    ).valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    check:
      WakuNodeConf(lc.kernelConf).clusterId == Opt.some(7'u16) # kernel field
      lc.messagingConf.get().reliabilityEnabled == Opt.some(true) # messaging-only

  test "messaging overrides are recorded verbatim, unset fields left none":
    let lc = parseLogosDeliveryConf("""{"messagingOverrides": {"clusterId": 7}}""").valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    let overrides = lc.messagingConf.get()
    check:
      overrides.clusterId == Opt.some(7'u16) # the user's override, kept as given
      overrides.reliabilityEnabled.isNone() # user didn't set it, so it stays none

  test "a preset resolves reliability into the messaging record":
    let lc = parseLogosDeliveryConf("""{"preset": "twn"}""").valueOr:
      raiseAssert error
    # the user set no reliability override, but the preset supplies one
    require lc.messagingConf.isSome()
    check lc.messagingConf.get().reliabilityEnabled.isSome()

  test "channelsOverrides fold into the channel conf":
    let lc = parseLogosDeliveryConf(
      """{"channelsOverrides": {"rateLimitEnabled": true, "sdsMaxRetransmissions": 9}}"""
    ).valueOr:
      raiseAssert error
    require lc.channelsConf.isSome()
    let channels = lc.channelsConf.get()
    check:
      channels.rateLimitEnabled == Opt.some(true)
      channels.sdsMaxRetransmissions == Opt.some(9)

  test "invalid mode is rejected (Core or Edge only)":
    check parseLogosDeliveryConf("""{"mode": "bogus"}""").isErr()
    check parseLogosDeliveryConf("""{"mode": "noMode"}""").isErr()
    check parseLogosDeliveryConf("""{"mode": ""}""").isErr()

  test "invalid JSON is rejected":
    check parseLogosDeliveryConf("{ not json }").isErr()

  test "a truly unknown top-level key is rejected (flat walker rejects the field)":
    # NB: a *known* WakuNodeConf field at top level (e.g. logLevel) is now accepted
    # as a flat blob; only a field that is not a WakuNodeConf field is rejected.
    check parseLogosDeliveryConf("""{"totallyBogusField": "x", "mode": "Core"}""").isErr()

  test "override keys accept CLI switch names":
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"cluster-id": 7, "reliability": true, "tcp-port": 1234}}"""
    ).valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    require lc.messagingConf.isSome()
    check:
      kc.clusterId == Opt.some(7'u16)
      lc.messagingConf.get().reliabilityEnabled == Opt.some(true) # messaging-only
      kc.tcpPort == Port(1234)

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
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.logLevel == logging.LogLevel.DEBUG
      kc.logFormat == logging.LogFormat.JSON
      kc.nodekey.isSome()

  test "a null value leaves the field unset":
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"store": null, "clusterId": 7}}"""
    ).valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.clusterId == Opt.some(7'u16)
      kc.store == false # null left store unset; Core does not enable it

  test "an invalid Ethereum RPC URL is rejected at parse time":
    check parseLogosDeliveryConf(
      """{"messagingOverrides": {"rln-relay-eth-client-address": ["ws://node:8546"]}}"""
    )
      .isErr()
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"rln-relay-eth-client-address": ["http://localhost:8540/"]}}"""
    ).valueOr:
      raiseAssert error
    check WakuNodeConf(lc.kernelConf).ethClientUrls.len == 1

  test "store backend fields fold into the kernel conf":
    let lc = parseLogosDeliveryConf(
      """{"messagingOverrides": {"store": true, "store-message-db-url": "sqlite://test.db", "store-message-retention-policy": "time:3600", "store-max-num-db-connections": 7}}"""
    ).valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.store == true
      kc.storeMessageDbUrl == "sqlite://test.db"
      kc.storeMessageRetentionPolicy == "time:3600"
      kc.storeMaxNumDbConnections == 7

  test "kernel entry layer parses a raw kernelConf":
    let lc = parseLogosDeliveryConf(
      """{"entrylayer": "kernel", "kernelConf": {"relay": false, "maxMessageSize": "150KiB"}}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.messagingConf.isNone() # kernel-only: no upper layers
      lc.channelsConf.isNone()
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.relay == false
      kc.maxMessageSize == "150KiB"

  test "kernel entry layer requires a kernelConf":
    check parseLogosDeliveryConf("""{"entrylayer": "kernel"}""").isErr()

  test "kernel entry layer rejects anything besides kernelConf":
    check parseLogosDeliveryConf(
      """{"entrylayer": "kernel", "kernelConf": {}, "messagingOverrides": {"clusterId": 1}}"""
    )
      .isErr()
    # a preset for a kernel node goes inside kernelConf (WakuNodeConf.preset); the
    # kernel entry layer treats kernelConf as a finished object and overlays nothing
    check parseLogosDeliveryConf(
      """{"entrylayer": "kernel", "kernelConf": {}, "preset": "twn"}"""
    )
      .isErr()

  test "kernelConf is rejected outside the kernel entry layer":
    # kernelConf is a kernel-entry-layer wrapper. Under messaging/channels it is
    # neither consumed by the structured path nor a flat kernel field, so it must
    # surface as an unknown key.
    check parseLogosDeliveryConf("""{"mode": "core", "kernelConf": {}}""").isErr()

suite "LogosDelivery.new - construction (the app-dev entry)":
  asyncTest "builds the full messaging stack from mode + overrides":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          mode = LogosDeliveryMode.Core,
          preset = "",
          messagingOverrides = MessagingClientConf(
            clusterId: Opt.some(3'u16),
            numShardsInCluster: Opt.some(1'u16),
            listenIpv4: Opt.some(parseIpAddress("0.0.0.0")),
            reliabilityEnabled: Opt.some(true),
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
          mode = LogosDeliveryMode.Core,
          preset = "logostest",
          messagingOverrides =
            MessagingClientConf(listenIpv4: Opt.some(parseIpAddress("0.0.0.0"))),
        )
      ).valueOr:
        raiseAssert error
    check not node.waku.isNil()
    (await node.stop()).expect("stop")

suite "MessagingClientConf - store override":
  test "store opt-in overrides the mode default; protocol flags follow the mode":
    let kc = MessagingClientConf(store: Opt.some(true)).toWakuNodeConf(
      LogosDeliveryMode.Edge
    ).valueOr:
      raiseAssert error
    check:
      kc.store == true # Edge defaults store off; the explicit opt-in wins
      kc.relay == false # protocols are owned by the mode, not overridable

suite "LogosDelivery.new - raw kernel construction":
  asyncTest "a kernel-only node mounts the kernel only; start/stop tolerate the nil layers":
    let kernel = MessagingClientConf(listenIpv4: Opt.some(parseIpAddress("0.0.0.0"))).toWakuNodeConf(
      LogosDeliveryMode.Core
    ).valueOr:
      raiseAssert error
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(KernelConf(kernel))).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      node.messagingClient.isNil() # no messaging client on a fleet node
      node.reliableChannelManager.isNil() # no channel manager either
    # start()/stop() must skip the nil messaging + channel layers, not deref them
    (await node.start()).expect("start")
    (await node.stop()).expect("stop")

# [Legacy flat JSON config] These suites cover the legacy flat shape; delete them
# together with parseFlatConf when flat-shape support is dropped.
suite "parseLogosDeliveryConf - flat WakuNodeConf shape (interop compatibility)":
  test "a flat blob of kernel fields is detected and parsed as a full stack":
    let lc = parseLogosDeliveryConf(
      """{"relay": true, "clusterId": 7, "store": true, "filter": false}"""
    ).valueOr:
      raiseAssert error
    check:
      WakuNodeConf(lc.kernelConf).relay == true
      WakuNodeConf(lc.kernelConf).clusterId == Opt.some(7'u16)
      lc.messagingConf.isSome() # full stack
      lc.channelsConf.isSome()

  test "flat blob carrying mode: mode expands to flags, explicit flags override":
    let lc = parseLogosDeliveryConf(
      """{"mode": "Edge", "relay": true, "clusterId": 7}"""
    ).valueOr:
      raiseAssert error
    check:
      WakuNodeConf(lc.kernelConf).relay == true
        # explicit flat field overrides the Edge default
      WakuNodeConf(lc.kernelConf).filter == false # Edge default, not set explicitly
      WakuNodeConf(lc.kernelConf).clusterId == Opt.some(7'u16)

  test "flat blob's reliabilityEnabled routes to the messaging conf, not the kernel":
    let lc = parseLogosDeliveryConf("""{"relay": true, "reliabilityEnabled": true}""").valueOr:
      raiseAssert error
    check:
      lc.messagingConf.get().reliabilityEnabled == Opt.some(true)

  test "an unknown key in a flat blob is rejected":
    check parseLogosDeliveryConf("""{"relay": true, "bogusKey": 1}""").isErr()

  test "a flat blob's preset lifts reliability into the messaging record":
    # twn defines a p2pReliability; the flat path must resolve it into the messaging
    # conf (the kernel no longer carries reliability), matching master.
    let lc = parseLogosDeliveryConf("""{"preset": "twn", "relay": true}""").valueOr:
      raiseAssert error
    let fromPreset = resolvePreset("twn").valueOr:
      raiseAssert error
    check lc.messagingConf.get().reliabilityEnabled == fromPreset.reliabilityEnabled

  test "port 0 (auto-allocate) is accepted in a flat blob":
    let lc = parseLogosDeliveryConf(
      """{"relay": true, "tcpPort": 0, "discv5UdpPort": 0}"""
    ).valueOr:
      raiseAssert error
    check:
      WakuNodeConf(lc.kernelConf).tcpPort == Port(0)
      WakuNodeConf(lc.kernelConf).discv5UdpPort == Port(0)

  test "port 0 is accepted in structured messagingOverrides":
    let lc = parseLogosDeliveryConf("""{"messagingOverrides": {"tcp-port": 0}}""").valueOr:
      raiseAssert error
    check lc.messagingConf.get().p2pTcpPort == Opt.some(Port(0))

  test "mode/preset with no bare field stays structured; a bare field flips it to flat":
    # No bare kernel field -> structured: mode owns relay, no per-flag override.
    let structured = parseLogosDeliveryConf(
      """{"mode": "Edge", "preset": "logostest"}"""
    ).valueOr:
      raiseAssert error
    check WakuNodeConf(structured.kernelConf).relay == false # Edge, structured
    # Adding a bare kernel field (relay) flips to flat, where the explicit flag wins;
    # relay == true is only reachable via the flat path, so it proves the routing.
    let flat = parseLogosDeliveryConf(
      """{"mode": "Edge", "preset": "logostest", "relay": true}"""
    ).valueOr:
      raiseAssert error
    check:
      WakuNodeConf(flat.kernelConf).relay == true
      WakuNodeConf(flat.kernelConf).preset == "logostest"

  test "a wrapper key alongside a bare kernel field is rejected, not split":
    # A wrapper key (messagingOverrides) marks the structured shape, so the blob does
    # not flip to flat; the leftover bare field (relay) then has no structured home and
    # is rejected. Guards against the discriminator silently splitting a mixed object.
    check parseLogosDeliveryConf("""{"messagingOverrides": {}, "relay": true}""").isErr()
