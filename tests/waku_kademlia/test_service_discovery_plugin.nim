{.used.}

import std/[base64, json, net, sequtils, sets, strutils, tables]
import chronos, results, testutils/unittests
import brokers/broker_context
import
  libp2p/[peerid, peerinfo, multiaddress, crypto/crypto, extended_peer_record],
  libp2p/protocols/service_discovery/types
import
  logos_delivery/waku/discovery/[waku_kademlia, service_discovery_plugin],
  logos_delivery/waku/factory/conf_builder/kademlia_discovery_conf_builder,
  logos_delivery/waku/node/[waku_node, peer_manager],
  logos_delivery/waku/waku_core,
  ../testlib/[common, wakucore, wakunode]

## A fake plugin written the way the real host is: it listens for the node's
## `ServiceDiscoveryPluginRequest` events and settles them through
## `CompleteServiceDiscoveryRequest`. Advertised records land in a registry
## that several plugins can share, so one node can find another.

const AllVerbs = {ServiceDiscoveryVerb.low .. ServiceDiscoveryVerb.high}

type
  Registry = ref object
    entries: OrderedTable[string, seq[JsonNode]] ## service id -> peer JSON

  FakePlugin = ref object
    ctx: BrokerContext
    registry: Registry
    requests: seq[ServiceDiscoveryPluginRequest]
    autoAnswer: set[ServiceDiscoveryVerb] ## verbs answered on arrival
    failWith: string ## when set, answered verbs fail with this text
    lookupReply: string ## when set, returned by lookups instead of the registry

proc peerJson(record: SignedExtendedPeerRecord): JsonNode =
  %*{
    "peerId": $record.data.peerId,
    "seqNo": record.data.seqNo,
    "addrs": record.data.addresses.mapIt($it.address),
    "services": record.data.services.mapIt(
      %*{"id": it.id, "data": base64.encode(it.data.get(@[]))}
    ),
  }

proc reply(plugin: FakePlugin, req: ServiceDiscoveryPluginRequest): (bool, string) =
  if plugin.failWith.len > 0:
    return (false, plugin.failWith)
  case req.verb
  of ServiceDiscoveryVerb.lookup:
    if plugin.lookupReply.len > 0:
      return (true, plugin.lookupReply)
    return (true, $(%plugin.registry.entries.getOrDefault(req.serviceId)))
  of ServiceDiscoveryVerb.randomLookup:
    var all: seq[JsonNode]
    for peers in plugin.registry.entries.values:
      all.add(peers)
    return (true, $(%all))
  of ServiceDiscoveryVerb.startAdvertising:
    let record = SignedExtendedPeerRecord.decode(req.record).valueOr:
      return (false, "undecodable record")
    plugin.registry.entries.mgetOrPut(req.serviceId, @[]).add(peerJson(record))
    return (true, "")
  else:
    return (true, "")

proc complete(
    plugin: FakePlugin, requestId: uint64, success: bool, payload: string
): Future[Result[void, string]] {.async: (raises: []).} =
  try:
    return await CompleteServiceDiscoveryRequest.request(
      plugin.ctx, requestId, success, payload
    )
  except CatchableError:
    return err(getCurrentExceptionMsg())

proc newFakePlugin(ctx: BrokerContext, registry = Registry()): FakePlugin =
  let plugin = FakePlugin(ctx: ctx, registry: registry, autoAnswer: AllVerbs)
  discard ServiceDiscoveryPluginRequest.listen(
    ctx,
    proc(req: ServiceDiscoveryPluginRequest) {.async: (raises: []).} =
      plugin.requests.add(req)
      if req.verb notin plugin.autoAnswer:
        return
      let (success, payload) = plugin.reply(req)
      discard await plugin.complete(req.requestId, success, payload),
  )
  plugin

proc lastRequest(plugin: FakePlugin): ServiceDiscoveryPluginRequest =
  plugin.requests[^1]

proc waitUntil(
    cond: proc(): bool {.gcsafe, raises: [].}, timeout = 3.seconds
) {.async.} =
  let deadline = Moment.now() + timeout
  while not cond() and Moment.now() < deadline:
    await sleepAsync(20.milliseconds)

proc testPeerInfo(): PeerInfo =
  let peerInfo = PeerInfo.new(generateSecp256k1Key())
  peerInfo.addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/44002").get()]
  peerInfo

suite "Kademlia discovery conf: plugin hosting":
  test "the plugin flag alone enables discovery, hosted by the plugin":
    var builder = KademliaDiscoveryConfBuilder.init()
    builder.withPluginHosted(true)
    let conf = builder.build().expect("builds")
    check:
      conf.isSome()
      conf.get().pluginHosted

  test "in-process discovery stays the default":
    var builder = KademliaDiscoveryConfBuilder.init()
    builder.withEnabled(true)
    let conf = builder.build().expect("builds")
    check:
      conf.isSome()
      not conf.get().pluginHosted

  test "an explicit disable wins over the plugin flag":
    var builder = KademliaDiscoveryConfBuilder.init()
    builder.withEnabled(false)
    builder.withPluginHosted(true)
    check builder.build().expect("builds").isNone()

suite "Kademlia discovery hosted by a plugin":
  var ctx: BrokerContext

  setup:
    ## One broker scope per test, as the library gives one per node.
    ctx = NewBrokerContext()
    setThreadBrokerContext(ctx)

  asyncTest "start fails when no plugin answers":
    let plugin = newFakePlugin(ctx)
    plugin.autoAnswer = {}
    let driver =
      ServiceDiscoveryPlugin.new(ctx, 100.milliseconds).driver(testPeerInfo())

    let res = await driver.start()
    check:
      res.isErr()
      "start not answered in time" in res.error
      plugin.lastRequest.verb == ServiceDiscoveryVerb.start
      plugin.lastRequest.timeoutMs == 100

  asyncTest "verbs reach the plugin and replies are parsed":
    let plugin = newFakePlugin(ctx)
    let peerInfo = testPeerInfo()
    let driver = ServiceDiscoveryPlugin.new(ctx).driver(peerInfo)

    check (await driver.start()).isOk()

    let remote = PeerId.init(generateSecp256k1Key()).expect("peer id")
    plugin.lookupReply = $(
      %*[
        {
          "peerId": $remote,
          "seqNo": 7,
          "addrs": ["/ip4/1.2.3.4/tcp/60000"],
          "services": [{"id": "/mix/1.0.0", "data": base64.encode(@[1'u8, 2, 3])}],
        },
        {"peerId": "not-a-peer-id"},
        42,
      ]
    )
    let records = (await driver.lookup("/mix/1.0.0")).expect("lookup")
    check:
      plugin.lastRequest.verb == ServiceDiscoveryVerb.lookup
      plugin.lastRequest.serviceId == "/mix/1.0.0"
      records.len == 1
      records[0].peerId == remote
      records[0].seqNo == 7
      records[0].addresses.mapIt(it.address) ==
        @[MultiAddress.init("/ip4/1.2.3.4/tcp/60000").get()]
      records[0].services[0].data == Opt.some(@[1'u8, 2, 3])

    plugin.lookupReply = "not json"
    check (await driver.lookup("/mix/1.0.0")).isErr()
    plugin.lookupReply = ""

    check (await driver.lookupRandom()).isOk()
    check plugin.lastRequest.verb == ServiceDiscoveryVerb.randomLookup

    ## The plugin publishes a record signed by this node, listing exactly the
    ## advertised service.
    let service = ServiceInfo(id: "/test/1.0.0", data: Opt.some(@[9'u8]))
    check (await driver.startAdvertising(service)).isOk()
    let adv = plugin.lastRequest
    check:
      adv.verb == ServiceDiscoveryVerb.startAdvertising
      adv.serviceId == "/test/1.0.0"
      adv.data == @[9'u8]
    let record = SignedExtendedPeerRecord.decode(adv.record).expect("decodes")
    record.checkValid().expect("signed by the node")
    check:
      record.data.peerId == peerInfo.peerId
      record.data.services == @[service]

    check (await driver.stopAdvertising("/test/1.0.0")).isOk()
    check plugin.lastRequest.verb == ServiceDiscoveryVerb.stopAdvertising
    check (await driver.registerInterest("/test/1.0.0")).isOk()
    check plugin.lastRequest.verb == ServiceDiscoveryVerb.registerInterest
    check (await driver.unregisterInterest("/test/1.0.0")).isOk()
    check plugin.lastRequest.verb == ServiceDiscoveryVerb.unregisterInterest

    check (await driver.stop()).isOk()
    check plugin.lastRequest.verb == ServiceDiscoveryVerb.stop

  asyncTest "plugin errors are surfaced":
    let plugin = newFakePlugin(ctx)
    let driver = ServiceDiscoveryPlugin.new(ctx).driver(testPeerInfo())
    plugin.failWith = "dht not bootstrapped"
    let res = await driver.lookup("/test/1.0.0")
    check:
      res.isErr()
      res.error == "dht not bootstrapped"

  asyncTest "late and unknown completions are rejected":
    let plugin = newFakePlugin(ctx)
    plugin.autoAnswer = {}
    let driver =
      ServiceDiscoveryPlugin.new(ctx, 100.milliseconds).driver(testPeerInfo())

    check (await driver.lookup("/test/1.0.0")).isErr()
    let late = plugin.lastRequest.requestId
    check (await plugin.complete(late, true, "[]")).isErr()
    check (await plugin.complete(late + 1000, true, "[]")).isErr()

  asyncTest "overlapping requests are matched by id":
    let plugin = newFakePlugin(ctx)
    plugin.autoAnswer = {}
    let driver = ServiceDiscoveryPlugin.new(ctx).driver(testPeerInfo())

    let first = driver.lookup("/a/1.0.0")
    let second = driver.lookup("/b/1.0.0")
    await waitUntil(
      proc(): bool =
        plugin.requests.len >= 2
    )
    let reqA = plugin.requests[0]
    let reqB = plugin.requests[1]
    check reqA.requestId != reqB.requestId

    let idA = PeerId.init(generateSecp256k1Key()).expect("a")
    let idB = PeerId.init(generateSecp256k1Key()).expect("b")
    ## Answered in reverse order: each caller still gets its own reply.
    check (await plugin.complete(reqB.requestId, true, $(%*[{"peerId": $idB}]))).isOk()
    check (await plugin.complete(reqA.requestId, true, $(%*[{"peerId": $idA}]))).isOk()
    let recordsA = (await first).expect("a")
    let recordsB = (await second).expect("b")
    check:
      recordsA[0].peerId == idA
      recordsB[0].peerId == idB

  asyncTest "stopping releases pending requests":
    let plugin = newFakePlugin(ctx)
    plugin.autoAnswer = {ServiceDiscoveryVerb.stop}
    let driver = ServiceDiscoveryPlugin.new(ctx).driver(testPeerInfo())

    let pending = driver.lookup("/a/1.0.0")
    await waitUntil(
      proc(): bool =
        plugin.requests.len >= 1
    )
    check (await driver.stop()).isOk()
    let res = await pending.wait(1.seconds)
    check:
      res.isErr()
      "stopped" in res.error

  asyncTest "two nodes find each other through a shared plugin registry":
    let registry = Registry()
    let service = ServiceInfo(id: "/test/delivery/1.0.0", data: Opt.some(@[1'u8]))

    let ctxA = NewBrokerContext()
    setThreadBrokerContext(ctxA)
    let nodeA =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    let pluginA = newFakePlugin(ctxA, registry)
    check nodeA
      .mountKademlia(
        KademliaDiscoveryConf(
          pluginHosted: true,
          servicesToAdvertise: toHashSet([service]),
          randomLookupInterval: 1.hours,
          serviceLookupInterval: 1.hours,
        )
      )
      .isOk()
    await nodeA.start()

    let ctxB = NewBrokerContext()
    setThreadBrokerContext(ctxB)
    let nodeB =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    discard newFakePlugin(ctxB, registry)
    check nodeB
      .mountKademlia(
        KademliaDiscoveryConf(
          pluginHosted: true,
          servicesToDiscover: toHashSet([service.id]),
          randomLookupInterval: 1.hours,
          serviceLookupInterval: 50.milliseconds,
        )
      )
      .isOk()
    await nodeB.start()

    check:
      nodeA.wakuKademlia.isRunning()
      nodeB.wakuKademlia.isRunning()
      pluginA.requests.anyIt(it.verb == ServiceDiscoveryVerb.startAdvertising)

    let peerIdA = nodeA.switch.peerInfo.peerId
    let storeB = nodeB.peerManager.switch.peerStore
    await waitUntil(
      proc(): bool =
        storeB[SourceBook].book.hasKey(peerIdA)
    )
    check:
      storeB[SourceBook][peerIdA] == PeerOrigin.Kademlia
      service.id in storeB[ProtoBook][peerIdA]

    ## What B learned is enough to reach A.
    check await nodeB.peerManager.connectPeer(storeB.getPeer(peerIdA))

    await allFutures(nodeA.stop(), nodeB.stop())
    check pluginA.lastRequest.verb == ServiceDiscoveryVerb.stop
