{.used.}

import std/strutils
import chronos, results, testutils/unittests
import
  logos_delivery/api/conf/logos_delivery_conf_json,
  logos_delivery/api/conf/logos_delivery_conf,
  tools/confutils/cli_args,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/factory/conf_builder/external_discovery_conf_builder,
  logos_delivery/waku/factory/conf_builder/kademlia_discovery_conf_builder,
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
    conf.pluginKadDiscovery = Opt.some(true)
    conf.kadServiceLookupIntervalSec = 15
    conf.kadRandomLookupIntervalSec = 25

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then
    require wakuConf.externalDiscoveryConf.isSome()
    let extConf = wakuConf.externalDiscoveryConf.get()
    check:
      extConf.serviceLookupInterval == chronos.seconds(15)
      extConf.randomLookupInterval == chronos.seconds(25)

  test "enabling it without intervals falls back to the defaults":
    ## Given
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.pluginKadDiscovery = Opt.some(true)

    ## When
    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error

    ## Then
    require wakuConf.externalDiscoveryConf.isSome()
    let extConf = wakuConf.externalDiscoveryConf.get()
    check:
      extConf.serviceLookupInterval == DefaultServiceLookupInterval
      extConf.randomLookupInterval == DefaultRandomLookupInterval

suite "WakuNodeConf - service discovery exclusivity":
  test "internal and external together are refused":
    ## The same libp2p protocol from two hosts, each with its own switch and
    ## peer store: the node would join the DHT twice under two identities.
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.enableKadDiscovery = Opt.some(true)
    conf.pluginKadDiscovery = Opt.some(true)

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
    conf.pluginKadDiscovery = Opt.some(true)

    let res = conf.toWakuConf()
    check:
      res.isErr()
      "enable-kad-discovery=false" in res.error

  test "turning kademlia off lets external run under a preset":
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.preset = "logosdev"
    conf.pluginKadDiscovery = Opt.some(true)
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
    externalOnly.pluginKadDiscovery = Opt.some(true)
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
    conf.pluginKadDiscovery = Opt.some(true)

    let wakuConf = conf.toWakuConf().valueOr:
      raiseAssert error
    check:
      wakuConf.discv5Conf.isSome()
      wakuConf.externalDiscoveryConf.isSome()

suite "MessagingClientConf - discovery overrides":
  ## The structured entry layers (messaging / channels) build their kernel conf
  ## from mode + MessagingClientConf + preset, so a discovery setting is only
  ## reachable there if it has a field here.

  proc kernelOf(js: string): WakuConf =
    let parsed = parseLogosDeliveryConf(js).valueOr:
      raiseAssert error
    WakuNodeConf(parsed.kernelConf).toWakuConf().valueOr:
      raiseAssert error

  test "channels layer can enable plugin-hosted kademlia":
    let c = kernelOf(
      """{"entryLayer":"channels","messagingOverrides":{"pluginKadDiscovery":true}}"""
    )
    check:
      c.externalDiscoveryConf.isSome()
      c.kademliaDiscoveryConf.isNone()

  test "choosing the plugin switches the in-process backend off under a preset":
    ## The preset enables in-process kademlia. Without the switch in `merge`
    ## this would trip the mutual-exclusion check instead of building.
    let c = kernelOf(
      """{"entryLayer":"channels","preset":"logosdev",
         "messagingOverrides":{"pluginKadDiscovery":true}}"""
    )
    check:
      c.externalDiscoveryConf.isSome()
      c.kademliaDiscoveryConf.isNone()

  test "channels layer can enable the in-process backend":
    let c = kernelOf(
      """{"entryLayer":"channels","messagingOverrides":{"enableKadDiscovery":true}}"""
    )
    check:
      c.kademliaDiscoveryConf.isSome()
      c.externalDiscoveryConf.isNone()

  test "channels layer can turn discv5 off":
    ## Discv5 is on by default and was previously unreachable from this layer.
    let on = kernelOf("""{"entryLayer":"channels"}""")
    let off = kernelOf(
      """{"entryLayer":"channels","messagingOverrides":{"discv5Discovery":false}}"""
    )
    check:
      on.discv5Conf.isSome()
      off.discv5Conf.isNone()

  test "one pair of interval knobs serves whichever kademlia host runs":
    let overrides =
      """"kadServiceLookupIntervalSec":11,"kadRandomLookupIntervalSec":22"""
    let plugin = kernelOf(
      """{"entryLayer":"channels","messagingOverrides":{"pluginKadDiscovery":true,""" &
        overrides & "}}"
    )
    let inProcess = kernelOf(
      """{"entryLayer":"channels","messagingOverrides":{"enableKadDiscovery":true,""" &
        overrides & "}}"
    )
    check:
      plugin.externalDiscoveryConf.get().serviceLookupInterval == chronos.seconds(11)
      plugin.externalDiscoveryConf.get().randomLookupInterval == chronos.seconds(22)
      inProcess.kademliaDiscoveryConf.get().serviceLookupInterval == chronos.seconds(11)
      inProcess.kademliaDiscoveryConf.get().randomLookupInterval == chronos.seconds(22)

  test "kebab-case switch names work alongside field names":
    let c = kernelOf(
      """{"entryLayer":"channels","messagingOverrides":{"plugin-kad-discovery":true,
         "kad-service-lookup-interval":33}}"""
    )
    check:
      c.externalDiscoveryConf.isSome()
      c.externalDiscoveryConf.get().serviceLookupInterval == chronos.seconds(33)

  test "messaging layer reaches them too, with bootstrap nodes":
    let c = kernelOf(
      """{"entryLayer":"messaging","preset":"logosdev",
         "messagingOverrides":{"enableKadDiscovery":true,
         "kadBootstrapNodes":["/ip4/1.2.3.4/tcp/60000/p2p/16Uiu2HAm7r91vZXfGsVMLva87nLhEk3Cpnv7VhXqp7mA4MKhC3bu"]}}"""
    )
    require c.kademliaDiscoveryConf.isSome()
    check c.kademliaDiscoveryConf.get().bootstrapNodes.len > 0

suite "WakuNodeConf - edge nodes and kademlia client mode":
  test "a node that serves nothing runs kademlia in client mode":
    ## An edge node consumes discovery rather than providing it, so it should
    ## not hold routing state for others.
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.enableKadDiscovery = Opt.some(true)
    conf.relay = false
    conf.filter = false
    conf.lightpush = false
    conf.store = false

    let c = conf.toWakuConf().valueOr:
      raiseAssert error
    require c.kademliaDiscoveryConf.isSome()
    check:
      not c.wakuFlags.isServiceNode()
      c.kademliaDiscoveryConf.get().clientMode

  test "a serving node stays a full kademlia participant":
    var conf = defaultWakuNodeConf().valueOr:
      raiseAssert error
    conf.enableKadDiscovery = Opt.some(true)
    conf.relay = true

    let c = conf.toWakuConf().valueOr:
      raiseAssert error
    require c.kademliaDiscoveryConf.isSome()
    check:
      c.wakuFlags.isServiceNode()
      not c.kademliaDiscoveryConf.get().clientMode
