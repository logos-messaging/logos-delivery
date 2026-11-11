{.used.}

import std/[macros, net, strutils], results, chronos, testutils/unittests
import confutils/defs
import brokers/broker_context
import logos_delivery
import logos_delivery/api/conf/logos_delivery_conf_json
import logos_delivery/waku/factory/[waku_conf, networks_config]
import tools/confutils/cli_args
import logos_delivery/waku/common/logging
import ../testlib/wakunodeconf

proc kernelOf(
    mode = LogosDeliveryMode.Core,
    preset = "",
    kernelConf = Opt.none(KernelConf),
    entryLayer = EntryLayer.channels,
): WakuNodeConf =
  ## The kernel config the structured entry builds.
  let lc = LogosDeliveryConf.init(
    entryLayer = entryLayer,
    mode = mode,
    preset = preset,
    messagingOverrides = MessagingClientConf(),
    channelsOverrides = ReliableChannelManagerConf(),
    kernelConfArg = kernelConf,
  ).valueOr:
    raiseAssert error
  return WakuNodeConf(lc.kernelConf)

proc libraryKernel(): WakuNodeConf =
  return libraryKernelConf().valueOr:
    raiseAssert error

suite "LogosDeliveryConf - mode expansion":
  test "Core mode enables relay + service protocols":
    let kc = kernelOf(LogosDeliveryMode.Core)
    check:
      kc.relay == Opt.some(true)
      kc.filter == Opt.some(true)
      kc.lightpush == Opt.some(true)
      kc.discv5Discovery == Opt.some(true)
      kc.peerExchange == Opt.some(true)
      kc.rendezvous == Opt.some(true)

  test "Edge mode is client-only (no relay/filter/lightpush/store)":
    let kc = kernelOf(LogosDeliveryMode.Edge)
    check:
      kc.relay == Opt.some(false)
      kc.filter == Opt.some(false)
      kc.lightpush == Opt.some(false)
      kc.store == Opt.some(false)
      kc.peerExchange == Opt.some(true)
      kc.discv5Discovery == Opt.some(true)
        # discovery stays on; mode does not force it off

  test "an explicit discv5Discovery=false survives mode expansion":
    var kc = defaultKernelConf().valueOr:
      raiseAssert error
    kc.discv5Discovery = Opt.some(false)
    applyMode(kc, LogosDeliveryMode.Core)
    check kc.discv5Discovery == Opt.some(false)

  test "an explicit kernel field wins over the mode":
    var kernel = libraryKernel()
    kernel.store = Opt.some(true)
    let kc = kernelOf(LogosDeliveryMode.Edge, kernelConf = Opt.some(KernelConf(kernel)))
    check:
      kc.store == Opt.some(true) # Edge defaults store off; the explicit opt-in wins
      kc.relay == Opt.some(false) # unset, so the mode decides

suite "LogosDeliveryConf - library kernel defaults":
  test "ephemeral ports, websocket off, quic on":
    let kc = kernelOf()
    check:
      kc.tcpPort == Port(0)
      kc.discv5UdpPort == Port(0)
      kc.websocketSupport == false
      kc.quicSupport == true

  test "nat and storage defaults are the CLI defaults":
    let kc = kernelOf()
    let cli = defaultKernelConf().valueOr:
      raiseAssert error
    check:
      kc.nat == cli.nat
      kc.localStoragePath == cli.localStoragePath

  test "choosing the plugin-hosted kademlia turns the in-process one off":
    var kernel = libraryKernel()
    kernel.pluginKadDiscovery = Opt.some(true)
    check kernelOf(kernelConf = Opt.some(KernelConf(kernel))).enableKadDiscovery ==
      Opt.some(false)

  test "an RLN contract alone leaves rlnRelay unset, as on the CLI":
    var kernel = libraryKernel()
    kernel.rlnRelayEthContractAddress = "0x0000000000000000000000000000000000000001"
    check kernelOf(kernelConf = Opt.some(KernelConf(kernel))).rlnRelay.isNone()

  test "the kernel conf's preset applies to messaging when preset is empty":
    var kernel = libraryKernel()
    kernel.preset = "twn"
    let lc = LogosDeliveryConf.init(
      mode = LogosDeliveryMode.Core,
      preset = "",
      messagingOverrides = MessagingClientConf(),
      channelsOverrides = ReliableChannelManagerConf(),
      kernelConfArg = Opt.some(KernelConf(kernel)),
    ).valueOr:
      raiseAssert error
    check lc.messagingConf.get() ==
      merge(resolvePreset("twn").get(), MessagingClientConf())

suite "MessagingClientConf - preset resolution":
  test "resolvePreset lifts the messaging fields":
    let mc = resolvePreset("twn").valueOr:
      raiseAssert error
    check mc.reliabilityEnabled.isSome()

  test "empty preset resolves to an empty config":
    let mc = resolvePreset("").valueOr:
      raiseAssert error
    check mc == MessagingClientConf()

  test "a kernel field wins over the preset":
    let lc = parseLogosDeliveryConf(
      """{"preset": "logos.dev", "num-shards-in-network": 1}"""
    ).valueOr:
      raiseAssert error
    let wakuConf = WakuNodeConf(lc.kernelConf).toWakuConf().valueOr:
        raiseAssert error
    check:
      wakuConf.shardingConf.kind == AutoSharding
      wakuConf.shardingConf.numShards == 1

suite "MessagingClientConf - merge (override wins)":
  test "a set override field wins; unset keeps the base":
    let base = MessagingClientConf(
      reliabilityEnabled: Opt.some(true), backfillEnabled: Opt.some(true)
    )
    let overrides = MessagingClientConf(reliabilityEnabled: Opt.some(false))
    let mc = merge(base, overrides)
    check:
      mc.reliabilityEnabled == Opt.some(false) # override wins
      mc.backfillEnabled == Opt.some(true) # base preserved

  test "rate-limit fields override independently through merge":
    let base = MessagingClientConf(
      rateLimitEnabled: Opt.some(true),
      rateLimitEpochPeriodSec: Opt.some(30'u64),
      rateLimitMessagesPerEpoch: Opt.some(5'u64),
    )
    let overrides = MessagingClientConf(rateLimitMessagesPerEpoch: Opt.some(9'u64))
    let rl = merge(base, overrides).rateLimitConfig()
    check:
      rl.enabled # base preserved
      rl.epochPeriodSec == 30 # base preserved
      rl.messagesPerEpoch == 9 # override wins

suite "MessagingClientConf - rate-limit config":
  test "unset rate-limit fields fall back to DefaultRateLimitConfig":
    check MessagingClientConf().rateLimitConfig() == DefaultRateLimitConfig

  test "each set rate-limit field replaces only its default":
    let rl = MessagingClientConf(rateLimitEnabled: Opt.some(true)).rateLimitConfig()
    check:
      rl.enabled
      rl.epochPeriodSec == DefaultRateLimitConfig.epochPeriodSec
      rl.messagesPerEpoch == DefaultRateLimitConfig.messagesPerEpoch

proc warningsOf(lc: LogosDeliveryConf): seq[string] =
  let conf = WakuNodeConf(lc.kernelConf)
  let defaults = defaultKernelConf(ModeProtocolFlags()).get()
  let wakuConf = conf.toWakuConf().valueOr:
    raiseAssert error
  return ignoredFlagWarnings(conf, defaults, wakuConf)

suite "parseLogosDeliveryConf - JSON parsing":
  test "empty object resolves to a full Core node conf":
    let lc = parseLogosDeliveryConf("{}").valueOr:
      raiseAssert error
    check:
      lc.messagingConf.isSome() # full node: messaging + channels mounted
      lc.channelsConf.isSome()
      WakuNodeConf(lc.kernelConf).relay == Opt.some(true) # Core enables relay
      WakuNodeConf(lc.kernelConf).clusterId.isNone() # no cluster set

  test "mode + preset fold into the kernel conf":
    let lc = parseLogosDeliveryConf("""{"mode": "Edge", "preset": "logostest"}""").valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.preset == "logostest"
      kc.relay == Opt.some(false) # Edge disables relay

  test "kernel fields go to the kernel, messaging fields to the messaging conf":
    let lc = parseLogosDeliveryConf(
      """{"mode": "Core", "clusterId": 7, "reliabilityEnabled": true}"""
    ).valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    check:
      WakuNodeConf(lc.kernelConf).clusterId == Opt.some(7'u16) # kernel field
      lc.messagingConf.get().reliabilityEnabled == Opt.some(true) # messaging-only

  test "localStoragePath override maps to the kernel":
    let lc = parseLogosDeliveryConf(
      """{"mode": "Core", "localStoragePath": "/tmp/inst-1/data"}"""
    ).valueOr:
      raiseAssert error
    check WakuNodeConf(lc.kernelConf).localStoragePath == "/tmp/inst-1/data"

  test "nat override maps to the kernel":
    let lc = parseLogosDeliveryConf("""{"mode": "Core", "nat": "none"}""").valueOr:
      raiseAssert error
    check WakuNodeConf(lc.kernelConf).nat == "none"

  test "messaging fields are recorded verbatim, unset fields left none":
    let lc = parseLogosDeliveryConf("""{"reliability": true}""").valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    let mc = lc.messagingConf.get()
    check:
      mc.reliabilityEnabled == Opt.some(true) # the user's value, kept as given
      mc.anonymityLevel.isNone() # user didn't set it, so it stays none

  test "a preset resolves reliability into the messaging record":
    let lc = parseLogosDeliveryConf("""{"preset": "twn"}""").valueOr:
      raiseAssert error
    # the user set no reliability override, but the preset supplies one
    require lc.messagingConf.isSome()
    check lc.messagingConf.get().reliabilityEnabled.isSome()

  test "a clusterId override of 2 keeps the logos.test preset":
    let lc = parseLogosDeliveryConf("""{"preset": "logos.test", "clusterId": 2}""").valueOr:
      raiseAssert error
    let wakuConf = WakuNodeConf(lc.kernelConf).toWakuConf().valueOr:
        raiseAssert error
    check:
      wakuConf.clusterId == 2
      wakuConf.staticNodes == NetworkPresetConf.LogosTestConf().entryNodes

  test "an anonymity override reaches the messaging record and mounts mix":
    let lc = parseLogosDeliveryConf("""{"anonymityLevel": "Required"}""").valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    check:
      lc.messagingConf.get().anonymityLevel == Opt.some(AnonymityLevel.Required)
      WakuNodeConf(lc.kernelConf).mix == Opt.some(true)

  test "an anonymity level with mix disabled is rejected":
    check parseLogosDeliveryConf("""{"anonymityLevel": "Required", "mix": false}""")
      .isErr()

  test "channel fields go to the channel conf":
    let lc = parseLogosDeliveryConf(
      """{"rateLimitEnabled": true, "sdsMaxRetransmissions": 9}"""
    ).valueOr:
      raiseAssert error
    require:
      lc.channelsConf.isSome()
      lc.messagingConf.isSome()
    check:
      lc.channelsConf.get().sdsMaxRetransmissions == Opt.some(9)
      lc.messagingConf.get().rateLimitEnabled == Opt.some(true) # a messaging field

  test "rate-limit overrides are settable by field name":
    let lc = parseLogosDeliveryConf(
      """{"rateLimitEnabled": true, "rateLimitEpochPeriodSec": 30, "rateLimitMessagesPerEpoch": 5, "rateLimitApproachedThresholdPercent": 60}"""
    ).valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    check lc.messagingConf.get().rateLimitConfig() ==
      RateLimitConfig(
        enabled: true,
        epochPeriodSec: 30,
        messagesPerEpoch: 5,
        approachedThresholdPercent: 60,
      )

  test "rate-limit overrides are settable by CLI switch name":
    let lc = parseLogosDeliveryConf(
      """{"rate-limit-enabled": true, "rate-limit-epoch-sec": 30, "rate-limit-messages-per-epoch": 5, "rate-limit-approached-threshold-percent": 60}"""
    ).valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    let mc = lc.messagingConf.get()
    check:
      mc.rateLimitEnabled == Opt.some(true)
      mc.rateLimitEpochPeriodSec == Opt.some(30'u64)
      mc.rateLimitMessagesPerEpoch == Opt.some(5'u64)
      mc.rateLimitApproachedThresholdPercent == Opt.some(60'u64)

  test "a partial rate-limit override leaves the rest at the defaults":
    let lc = parseLogosDeliveryConf("""{"rate-limit-messages-per-epoch": 5}""").valueOr:
      raiseAssert error
    require lc.messagingConf.isSome()
    let rl = lc.messagingConf.get().rateLimitConfig()
    check:
      not rl.enabled
      rl.epochPeriodSec == DefaultRateLimitConfig.epochPeriodSec
      rl.messagesPerEpoch == 5
      rl.approachedThresholdPercent == DefaultRateLimitConfig.approachedThresholdPercent

  test "an invalid rate-limit value is rejected":
    check parseLogosDeliveryConf("""{"rate-limit-epoch-sec": "soon"}""").isErr()

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
      """{"cluster-id": 7, "reliability": true, "tcp-port": 1234}"""
    ).valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    require lc.messagingConf.isSome()
    check:
      kc.clusterId == Opt.some(7'u16)
      lc.messagingConf.get().reliabilityEnabled == Opt.some(true) # messaging-only
      kc.tcpPort == Port(1234)

  test "the anonymity-level switch name is accepted as an override key":
    let lc = parseLogosDeliveryConf("""{"anonymity-level": "Required"}""").valueOr:
      raiseAssert error
    check:
      lc.messagingConf.get(MessagingClientConf()).anonymityLevel ==
        Opt.some(AnonymityLevel.Required)
      WakuNodeConf(lc.kernelConf).mix == Opt.some(true)

  test "anonymityLevel set via both its name and its switch name is rejected":
    check "was set twice" in
      parseLogosDeliveryConf(
        """{"anonymityLevel": "Required", "anonymity-level": "Required"}"""
      )
      .errorOr("accepted")

  test "the per-layer sections of the old shape are rejected":
    check parseLogosDeliveryConf("""{"messagingOverrides": {}}""").isErr()
    check parseLogosDeliveryConf("""{"channelsOverrides": {}}""").isErr()
    check parseLogosDeliveryConf("""{"kernelConf": {}}""").isErr()

  test "a field set via both its name and its switch name is rejected":
    check parseLogosDeliveryConf("""{"clusterId": 5, "cluster-id": 5}""").isErr()

  test "logLevel and nodeKey parse via switch names and map to the kernel":
    let lc = parseLogosDeliveryConf(
      """{"log-level": "DEBUG", "log-format": "JSON", "nodekey": "0d714a1fada214dead6dc9c7274581ec20ff292451866e7d6d677dc818e8ccd2"}"""
    ).valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.logLevel == logging.LogLevel.DEBUG
      kc.logFormat == logging.LogFormat.JSON
      kc.nodekey.isSome()

  test "a null value leaves the field unset":
    let lc = parseLogosDeliveryConf("""{"store": null, "clusterId": 7}""").valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.clusterId == Opt.some(7'u16)
      kc.store == Opt.some(false) # null left store unset; Core does not enable it

  test "an invalid Ethereum RPC URL is rejected at parse time":
    check parseLogosDeliveryConf(
      """{"rln-relay-eth-client-address": ["ws://node:8546"]}"""
    )
      .isErr()
    let lc = parseLogosDeliveryConf(
      """{"rln-relay-eth-client-address": ["http://localhost:8540/"]}"""
    ).valueOr:
      raiseAssert error
    check WakuNodeConf(lc.kernelConf).ethClientUrls.len == 1

  test "the LEZ RLN options are not accepted from configuration":
    # The RLN plugin is installed over FFI and carries its own configuration.
    for key in ["rln-lez", "rln-registry-id", "rln-identifier", "rln-registry-options"]:
      check parseLogosDeliveryConf("{\"" & key & "\": \"x\"}").isErr()

  test "store backend fields fold into the kernel conf":
    let lc = parseLogosDeliveryConf(
      """{"store": true, "store-message-db-url": "sqlite://test.db", "store-message-retention-policy": "time:3600", "store-max-num-db-connections": 7}"""
    ).valueOr:
      raiseAssert error
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.store == Opt.some(true)
      kc.storeMessageDbUrl == "sqlite://test.db"
      kc.storeMessageRetentionPolicy == "time:3600"
      kc.storeMaxNumDbConnections == 7

  test "kernel entry layer takes kernel fields alone":
    let lc = parseLogosDeliveryConf(
      """{"entrylayer": "kernel", "relay": false, "maxMessageSize": "150KiB"}"""
    ).valueOr:
      raiseAssert error
    check:
      lc.messagingConf.isNone() # kernel-only: no upper layers
      lc.channelsConf.isNone()
    let kc = WakuNodeConf(lc.kernelConf)
    check:
      kc.relay == Opt.some(false)
      kc.maxMessageSize == "150KiB"

  test "kernel entry layer accepts a preset, as the CLI does":
    let lc = parseLogosDeliveryConf("""{"entrylayer": "kernel", "preset": "twn"}""").valueOr:
      raiseAssert error
    check WakuNodeConf(lc.kernelConf).preset == "twn"

  test "kernel entry layer rejects mode, messaging and channel options":
    check parseLogosDeliveryConf("""{"entrylayer": "kernel", "mode": "Edge"}""").isErr()
    check parseLogosDeliveryConf("""{"entrylayer": "kernel", "reliability": true}""")
      .isErr()
    check parseLogosDeliveryConf(
      """{"entrylayer": "kernel", "sdsMaxRetransmissions": 9}"""
    )
      .isErr()

  test "a wrong-layer option is named, and rejected before its value is parsed":
    let res = parseLogosDeliveryConf("""{"entrylayer": "kernel", "reliability": "x"}""")
    check res.isErr() and res.error.endsWith(": reliability")

  test "messaging entry layer rejects channel options":
    let res = parseLogosDeliveryConf(
      """{"entrylayer": "messaging", "sdsMaxRetransmissions": 9}"""
    )
    check res.isErr() and res.error.endsWith(": sdsMaxRetransmissions")

  test "an empty config warns about the websocket port":
    # TODO: logos-delivery#4553
    let lc = parseLogosDeliveryConf("{}").valueOr:
      raiseAssert error
    check warningsOf(lc) ==
      @["--websocket-port is ignored: --websocket-support is not enabled"]

suite "LogosDelivery.new - construction (the app-dev entry)":
  asyncTest "builds the full messaging stack from mode + overrides":
    var kernel = libraryKernel()
    kernel.clusterId = Opt.some(3'u16)
    kernel.numShardsInNetwork = 1
    kernel.listenAddress = parseIpAddress("0.0.0.0")
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          mode = LogosDeliveryMode.Core,
          preset = "",
          messagingOverrides = MessagingClientConf(reliabilityEnabled: Opt.some(true)),
          kernelConf = Opt.some(KernelConf(kernel)),
        )
      ).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      not node.messagingClient.isNil()
      not node.reliableChannelManager.isNil()
    (await node.stop()).expect("stop")

  asyncTest "builds from a network preset":
    var kernel = libraryKernel()
    kernel.listenAddress = parseIpAddress("0.0.0.0")
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          mode = LogosDeliveryMode.Core,
          preset = "logostest",
          kernelConf = Opt.some(KernelConf(kernel)),
        )
      ).valueOr:
        raiseAssert error
    check not node.waku.isNil()
    (await node.stop()).expect("stop")

proc kernelWithAnonymity(level: Opt[AnonymityLevel]): WakuNodeConf =
  ## The kernel config of a Messaging API node with this anonymity level.
  let conf = LogosDeliveryConf.init(
    KernelConf(defaultTestWakuNodeConf()),
    MessagingClientConf(anonymityLevel: level),
    Opt.none(ReliableChannelManagerConf),
  ).valueOr:
    raiseAssert error
  return WakuNodeConf(conf.kernelConf)

suite "LogosDeliveryConf - anonymity level":
  test "an anonymity level above None asks the kernel to mount mix":
    check kernelWithAnonymity(Opt.some(AnonymityLevel.Required)).mix == Opt.some(true)

  test "None leaves mix alone":
    check kernelWithAnonymity(Opt.some(AnonymityLevel.None)).mix.isNone()

  test "an unset anonymity level defaults to None and leaves mix alone":
    check kernelWithAnonymity(Opt.none(AnonymityLevel)).mix.isNone()

  test "an anonymity level above None with mix=false is an error":
    var kernel = defaultTestWakuNodeConf()
    kernel.mix = Opt.some(false)
    check LogosDeliveryConf
      .init(
        KernelConf(kernel),
        MessagingClientConf(anonymityLevel: Opt.some(AnonymityLevel.Preferred)),
        Opt.none(ReliableChannelManagerConf),
      )
      .isErr()

  test "the mix protocol config is built, not just the ENR capability bit":
    let wakuConf = kernelWithAnonymity(Opt.some(AnonymityLevel.Preferred))
      .toWakuConf().valueOr:
        raiseAssert error
    check wakuConf.mixConf.isSome()

suite "LogosDelivery.new - raw kernel construction":
  asyncTest "a kernel-only node mounts the kernel only; start/stop tolerate the nil layers":
    let kernel = defaultTestWakuNodeConf()
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

suite "parseLogosDeliveryConf - flat shape":
  test "kernel fields parse into a full stack":
    let lc = parseLogosDeliveryConf(
      """{"relay": true, "clusterId": 7, "store": true, "filter": false}"""
    ).valueOr:
      raiseAssert error
    check:
      WakuNodeConf(lc.kernelConf).relay == Opt.some(true)
      WakuNodeConf(lc.kernelConf).clusterId == Opt.some(7'u16)
      lc.messagingConf.isSome() # full stack
      lc.channelsConf.isSome()

  test "the messaging REST cache capacity parses by switch or field name":
    let bySwitch = parseLogosDeliveryConf(
      """{"rest": true, "rest-messaging-cache-capacity": 7}"""
    ).valueOr:
      raiseAssert error
    check WakuNodeConf(bySwitch.kernelConf).restMessagingCacheCapacity == 7'u32
    let byField = parseLogosDeliveryConf(
      """{"rest": true, "restMessagingCacheCapacity": 9}"""
    ).valueOr:
      raiseAssert error
    check WakuNodeConf(byField.kernelConf).restMessagingCacheCapacity == 9'u32

  test "mode expands to flags, explicit flags override":
    let lc = parseLogosDeliveryConf(
      """{"mode": "Edge", "relay": true, "clusterId": 7}"""
    ).valueOr:
      raiseAssert error
    check:
      WakuNodeConf(lc.kernelConf).relay == Opt.some(true)
        # explicit flat field overrides the Edge default
      WakuNodeConf(lc.kernelConf).filter == Opt.some(false)
        # Edge default, not set explicitly
      WakuNodeConf(lc.kernelConf).clusterId == Opt.some(7'u16)

  test "reliabilityEnabled routes to the messaging conf, not the kernel":
    let lc = parseLogosDeliveryConf("""{"relay": true, "reliabilityEnabled": true}""").valueOr:
      raiseAssert error
    check:
      lc.messagingConf.get().reliabilityEnabled == Opt.some(true)

  test "an unknown key is rejected":
    check parseLogosDeliveryConf("""{"relay": true, "bogusKey": 1}""").isErr()

  test "a preset lifts reliability into the messaging record":
    # twn defines a p2pReliability; the kernel no longer carries reliability.
    let lc = parseLogosDeliveryConf("""{"preset": "twn", "relay": true}""").valueOr:
      raiseAssert error
    let fromPreset = resolvePreset("twn").valueOr:
      raiseAssert error
    check lc.messagingConf.get().reliabilityEnabled == fromPreset.reliabilityEnabled

  test "port 0 (auto-allocate) is accepted":
    let lc = parseLogosDeliveryConf(
      """{"relay": true, "tcpPort": 0, "discv5UdpPort": 0}"""
    ).valueOr:
      raiseAssert error
    check:
      WakuNodeConf(lc.kernelConf).tcpPort == Port(0)
      WakuNodeConf(lc.kernelConf).discv5UdpPort == Port(0)

  test "port 0 is accepted by switch name":
    let lc = parseLogosDeliveryConf("""{"tcp-port": 0}""").valueOr:
      raiseAssert error
    check WakuNodeConf(lc.kernelConf).tcpPort == Port(0)

proc optionNames[T](conf: T): seq[string] =
  ## Every JSON key that sets a field of `conf`: field names and switch names.
  var names: seq[string]
  for field, value in fieldPairs(conf):
    names.add(field.toLowerAscii())
    when value.hasCustomPragma(defs.name):
      names.add(value.getCustomPragmaVal(defs.name).toLowerAscii())
  return names

suite "parseLogosDeliveryConf - one key, one layer":
  test "messaging, channel and kernel option names do not overlap":
    let kernel = optionNames(libraryKernel())
    let messaging = optionNames(MessagingClientConf())
    let channels = optionNames(ReliableChannelManagerConf())
    for name in messaging:
      check name notin kernel
      check name notin channels
    for name in channels:
      check name notin kernel
    for name in messaging & channels:
      check name notin ["entrylayer", "mode", "preset"]

suite "LogosDeliveryNodeConf - CLI frontend translation (resolveCliConf)":
  proc cliConf(
      entryLayer: EntryLayer, mode = Opt.none(LogosDeliveryMode)
  ): LogosDeliveryNodeConf =
    var conf = defaultLogosDeliveryNodeConf().expect("defaults")
    conf.entryLayer = entryLayer
    conf.mode = mode
    return conf

  test "kernel entry: no upper layers; no mode is applied":
    let plan = resolveCliConf(cliConf(EntryLayer.kernel)).expect("translate")
    check:
      plan.messagingConf.isNone()
      plan.channelsConf.isNone()
      WakuNodeConf(plan.kernelConf).relay == Opt.some(true)
        # no mode ran; `DefaultKernelModeFlags` applies

  test "kernel entry rejects an explicit mode":
    check resolveCliConf(cliConf(EntryLayer.kernel, Opt.some(LogosDeliveryMode.Edge)))
      .isErr()

  test "channels entry: both layer configs present; the mode runs":
    let plan = resolveCliConf(
        cliConf(EntryLayer.channels, Opt.some(LogosDeliveryMode.Edge))
      )
      .expect("translate")
    check:
      plan.messagingConf.isSome()
      plan.channelsConf.isSome()
      WakuNodeConf(plan.kernelConf).relay == Opt.some(false) # set by the Edge mode

  test "an unset mode resolves to Core":
    let plan = resolveCliConf(cliConf(EntryLayer.messaging)).expect("translate")
    check:
      plan.channelsConf.isNone()
      WakuNodeConf(plan.kernelConf).relay == Opt.some(true) # set by the Core mode

  test "an explicit flag has priority over the mode":
    var conf = cliConf(EntryLayer.channels)
    conf.kernel.relay = Opt.some(false)
    let plan = resolveCliConf(conf).expect("translate")
    check WakuNodeConf(plan.kernelConf).relay == Opt.some(false)
      # explicit wins over Core

  test "the preset's messaging fields reach the messaging layer":
    var conf = cliConf(EntryLayer.messaging)
    conf.kernel.preset = "twn"
    let plan = resolveCliConf(conf).expect("translate")
    check:
      # TWN sets p2pReliability off; the hard default is on. The flat-JSON and
      # library API paths resolve this too, so all doors agree.
      plan.messagingConf.get().reliabilityEnabled == Opt.some(false)

  test "the messaging flags override the preset's messaging fields":
    var conf = cliConf(EntryLayer.messaging)
    conf.kernel.preset = "twn"
    conf.messaging.reliabilityEnabled = Opt.some(true)
    let plan = resolveCliConf(conf).expect("translate")
    check plan.messagingConf.get().reliabilityEnabled == Opt.some(true) # TWN sets it off

  test "kernel entry rejects a messaging flag":
    var conf = cliConf(EntryLayer.kernel)
    conf.messaging.reliabilityEnabled = Opt.some(true)
    check resolveCliConf(conf).isErr()

  test "an anonymity level above None mounts mix":
    var conf = cliConf(EntryLayer.messaging)
    conf.messaging.anonymityLevel = Opt.some(AnonymityLevel.Required)
    let plan = resolveCliConf(conf).expect("translate")
    check:
      plan.messagingConf.get().anonymityLevel == Opt.some(AnonymityLevel.Required)
      WakuNodeConf(plan.kernelConf).toWakuConf().get().mixConf.isSome()
