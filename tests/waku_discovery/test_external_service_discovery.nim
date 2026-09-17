{.used.}

import std/[base64, json, net, sequtils, strutils, tables]
import chronos, results, testutils/unittests
import brokers/broker_context
import libp2p/[peerid, peerinfo, multiaddress, crypto/crypto, extended_peer_record]
import
  logos_delivery/waku/discovery/external_service_discovery,
  logos_delivery/waku/requests/node_state_requests,
  logos_delivery/waku/node/[waku_node, peer_manager],
  logos_delivery/waku/waku_core,
  ../testlib/common,
  ../testlib/wakucore,
  ../testlib/wakunode

## A fake discovery host written the way the real one is: it listens for the
## node's `ServiceDiscoveryHostRequest` events and settles them through
## `CompleteServiceDiscoveryRequest`. Advertised records land in a registry
## that several hosts can share, so a lookup on one node can find another.

const AllVerbs = {ServiceDiscoveryVerb.low .. ServiceDiscoveryVerb.high}

type
  Registry = ref object
    entries: OrderedTable[string, seq[JsonNode]] ## criteria key -> peer JSON

  FakeHost = ref object
    ctx: BrokerContext
    registry: Registry
    requests: seq[ServiceDiscoveryHostRequest]
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

proc reply(host: FakeHost, req: ServiceDiscoveryHostRequest): (bool, string) =
  if host.failWith.len > 0:
    return (false, host.failWith)
  case req.verb
  of ServiceDiscoveryVerb.lookup:
    if host.lookupReply.len > 0:
      return (true, host.lookupReply)
    return (true, $(%host.registry.entries.getOrDefault(req.key)))
  of ServiceDiscoveryVerb.randomLookup:
    var all: seq[JsonNode]
    for peers in host.registry.entries.values:
      all.add(peers)
    return (true, $(%all))
  of ServiceDiscoveryVerb.startAdvertising:
    let record = SignedExtendedPeerRecord.decode(req.record).valueOr:
      return (false, "undecodable record")
    host.registry.entries.mgetOrPut(req.key, @[]).add(peerJson(record))
    return (true, "")
  else:
    return (true, "")

proc complete(
    host: FakeHost, requestId: uint64, success: bool, payload: string
): Future[Result[void, string]] {.async: (raises: []).} =
  try:
    return await CompleteServiceDiscoveryRequest.request(
      host.ctx, requestId, success, payload
    )
  except CatchableError:
    return err(getCurrentExceptionMsg())

proc newFakeHost(ctx: BrokerContext, registry = Registry()): FakeHost =
  let host = FakeHost(ctx: ctx, registry: registry, autoAnswer: AllVerbs)
  discard ServiceDiscoveryHostRequest.listen(
    ctx,
    proc(req: ServiceDiscoveryHostRequest) {.async: (raises: []).} =
      host.requests.add(req)
      if req.verb notin host.autoAnswer:
        return
      let (success, payload) = host.reply(req)
      discard await host.complete(req.requestId, success, payload),
  )
  host

proc lastRequest(host: FakeHost): ServiceDiscoveryHostRequest =
  host.requests[^1]

proc waitUntil(
    cond: proc(): bool {.gcsafe, raises: [].}, timeout = 3.seconds
) {.async.} =
  let deadline = Moment.now() + timeout
  while not cond() and Moment.now() < deadline:
    await sleepAsync(20.milliseconds)

proc provideNodeState(ctx: BrokerContext, node: WakuNode, key: crypto.PrivateKey) =
  discard GetNodePeerInfo.reprovideIt(ctx):
    ok(node.switch.peerInfo)
  discard GetNodeKey.reprovideIt(ctx):
    ok(key)
  discard GetNodePeerManager.reprovideIt(ctx):
    ok(node.peerManager)

suite "ExternalServiceDiscovery":
  var ctx: BrokerContext

  setup:
    ## One broker scope per test, as the library gives one per node.
    ctx = NewBrokerContext()
    setThreadBrokerContext(ctx)

  asyncTest "start fails when no host answers":
    let host = newFakeHost(ctx)
    host.autoAnswer = {}
    let backend = ExternalServiceDiscovery.create(requestTimeout = 100.milliseconds)

    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "did not answer start in time" in res.error
      host.requests.len == 1
      host.lastRequest.verb == ServiceDiscoveryVerb.start
      host.lastRequest.timeoutMs == 100
    let info = (await backend.backendInfo()).expect("info")
    check not info.running

  asyncTest "verbs reach the host and replies are parsed":
    let host = newFakeHost(ctx)
    let backend = ExternalServiceDiscovery.create()
    let iface: IPeerDiscovery = backend

    check (await iface.lookupServicePeers("svc:x", 1)).isErr() # not running
    check (await iface.startDiscovery()).isOk()
    check host.lastRequest.verb == ServiceDiscoveryVerb.start
    let info = (await iface.backendInfo()).expect("info")
    check:
      info.id == "service-ext"
      info.running

    ## Malformed entries are skipped; the valid one comes back typed, with the
    ## base64 service payload decoded.
    host.lookupReply = $(
      %*[
        {
          "peerId": "peer-from-host",
          "seqNo": 7,
          "addrs": ["/ip4/1.2.3.4/tcp/60000"],
          "services": [{"id": "/mix/1.0.0", "data": base64.encode(@[1'u8, 2, 3])}],
        },
        {"seqNo": 1},
        42,
      ]
    )
    let peers =
      (await iface.lookupServicePeers("svc:/mix/1.0.0", 5)).expect("lookup")
    check:
      host.lastRequest.verb == ServiceDiscoveryVerb.lookup
      host.lastRequest.key == "svc:/mix/1.0.0"
      host.lastRequest.limit == 5
      peers.len == 1
      peers[0].peerId == "peer-from-host"
      peers[0].addrs == @["/ip4/1.2.3.4/tcp/60000"]
      peers[0].seqNo == 7
      peers[0].services[0].id == "/mix/1.0.0"
      peers[0].services[0].data == @[1'u8, 2, 3]

    host.lookupReply = "not json"
    check (await iface.lookupServicePeers("svc:/mix/1.0.0", 5)).isErr()
    host.lookupReply = ""

    check (await iface.lookupRandom()).isOk()
    check host.lastRequest.verb == ServiceDiscoveryVerb.randomLookup

    ## Advertising publishes a record the node signs; without the node's
    ## identity the backend refuses rather than letting the host publish its
    ## own.
    let sent = host.requests.len
    check (await iface.startAdvertising("svc:x", @[1'u8, 2])).isErr()
    check host.requests.len == sent
    let nodeKey = generateSecp256k1Key()
    let peerInfo = PeerInfo.new(nodeKey)
    peerInfo.addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/44002").get()]
    discard GetNodePeerInfo.reprovideIt(ctx):
      ok(peerInfo)
    discard GetNodeKey.reprovideIt(ctx):
      ok(nodeKey)
    check (await iface.startAdvertising("svc:x", @[1'u8, 2])).isOk()
    let adv = host.lastRequest
    check:
      adv.verb == ServiceDiscoveryVerb.startAdvertising
      adv.key == "svc:x"
      adv.data == @[1'u8, 2]
    let record = SignedExtendedPeerRecord.decode(adv.record).expect("decodes")
    record.checkValid().expect("signed by the node")
    check:
      record.data.peerId == peerInfo.peerId
      record.data.services.len == 1
      record.data.services[0].id == "x"
      record.data.services[0].data == Opt.some(@[1'u8, 2])
    check (await iface.startAdvertising("shard:0", @[])).isErr()

    check (await iface.stopAdvertising("svc:x")).isOk()
    check:
      host.lastRequest.verb == ServiceDiscoveryVerb.stopAdvertising
      host.lastRequest.key == "svc:x"
    check (await iface.registerInterest("svc:y")).isOk()
    check:
      host.lastRequest.verb == ServiceDiscoveryVerb.registerInterest
      host.lastRequest.key == "svc:y"
    check (await iface.unregisterInterest("svc:y")).isOk()
    check:
      host.lastRequest.verb == ServiceDiscoveryVerb.unregisterInterest
      host.lastRequest.key == "svc:y"

    check (await iface.addBootstrapEntries(@["/ip4/1.2.3.4/tcp/1/p2p/16Uxx"])).isOk()

    check (await iface.stopDiscovery()).isOk()
    check host.lastRequest.verb == ServiceDiscoveryVerb.stop

  asyncTest "host errors are surfaced":
    let host = newFakeHost(ctx)
    let backend = ExternalServiceDiscovery.create()
    check (await backend.startDiscovery()).isOk()

    host.failWith = "dht not bootstrapped"
    let res = await backend.lookupServicePeers("svc:x", 0)
    check:
      res.isErr()
      res.error == "dht not bootstrapped"
    check (await backend.registerInterest("svc:x")).isErr()

    host.failWith = ""
    check (await backend.stopDiscovery()).isOk()

  asyncTest "late and unknown completions are rejected":
    let host = newFakeHost(ctx)
    let backend = ExternalServiceDiscovery.create(requestTimeout = 100.milliseconds)
    check (await backend.startDiscovery()).isOk()

    host.autoAnswer = {ServiceDiscoveryVerb.stop}
    let res = await backend.lookupServicePeers("svc:x", 0)
    check:
      res.isErr()
      "did not answer lookup in time" in res.error
    let late = host.lastRequest.requestId
    check (await host.complete(late, true, "[]")).isErr()
    check (await host.complete(late + 1000, true, "[]")).isErr()

    check (await backend.stopDiscovery()).isOk()

  asyncTest "overlapping requests are matched by id":
    let host = newFakeHost(ctx)
    let backend = ExternalServiceDiscovery.create()
    check (await backend.startDiscovery()).isOk()

    host.autoAnswer = {ServiceDiscoveryVerb.stop}
    let first = backend.lookupServicePeers("svc:a", 0)
    let second = backend.lookupServicePeers("svc:b", 0)
    await waitUntil(
      proc(): bool =
        host.requests.len >= 3
    )
    let reqA = host.requests[^2]
    let reqB = host.requests[^1]
    check:
      reqA.key == "svc:a"
      reqB.key == "svc:b"
      reqA.requestId != reqB.requestId

    ## Answered in reverse order: each caller still gets its own reply.
    check (await host.complete(reqB.requestId, true, $(%*[{"peerId": "b"}]))).isOk()
    check (await host.complete(reqA.requestId, true, $(%*[{"peerId": "a"}]))).isOk()
    let peersA = (await first).expect("a")
    let peersB = (await second).expect("b")
    check:
      peersA[0].peerId == "a"
      peersB[0].peerId == "b"

    check (await backend.stopDiscovery()).isOk()

  asyncTest "stopping releases pending requests":
    let host = newFakeHost(ctx)
    let backend = ExternalServiceDiscovery.create()
    check (await backend.startDiscovery()).isOk()

    host.autoAnswer = {ServiceDiscoveryVerb.stop}
    let pending = backend.lookupServicePeers("svc:a", 0)
    await waitUntil(
      proc(): bool =
        host.requests.len >= 2
    )
    check (await backend.stopDiscovery()).isOk()
    let res = await pending.wait(1.seconds)
    check:
      res.isErr()
      "discovery stopped" in res.error

  asyncTest "a stop racing a just-answered start wins":
    let host = newFakeHost(ctx)
    host.autoAnswer = {}
    let backend = ExternalServiceDiscovery.create()

    let starting = backend.startDiscovery()
    await waitUntil(
      proc(): bool =
        host.requests.len >= 1
    )
    ## The host's answer is in, but the start has not resumed yet when the
    ## stop runs.
    let answered = host.complete(host.lastRequest.requestId, true, "")
    check (await backend.stopDiscovery()).isOk()
    check (await answered).isOk()

    let res = await starting.wait(1.seconds)
    check:
      res.isErr()
      "stopped while starting" in res.error
    let info = (await backend.backendInfo()).expect("info")
    check not info.running

  asyncTest "discovery can be restarted":
    let host = newFakeHost(ctx)
    let backend = ExternalServiceDiscovery.create()
    for _ in 0 ..< 5:
      check (await backend.startDiscovery()).isOk()
      check (await backend.lookupRandom()).isOk()
      check (await backend.stopDiscovery()).isOk()
    check:
      host.requests.countIt(it.verb == ServiceDiscoveryVerb.start) == 5
      host.requests.countIt(it.verb == ServiceDiscoveryVerb.stop) == 5

  asyncTest "interest lookups feed the peer manager":
    let host = newFakeHost(ctx)
    let nodeKey = generateSecp256k1Key()
    let node = newTestWakuNode(nodeKey, parseIpAddress("127.0.0.1"), Port(0))
    provideNodeState(ctx, node, nodeKey)

    let remoteId = PeerId.init(generateSecp256k1Key()).expect("peer id")
    let mixKey = newSeq[byte](32)
    host.registry.entries["svc:/logos/delivery"] = @[
      %*{
        "peerId": $remoteId,
        "addrs": ["/ip4/127.0.0.1/tcp/61234"],
        "services": [
          {"id": "/logos/delivery", "data": ""},
          {"id": "/mix/1.0.0", "data": base64.encode(mixKey)},
        ],
      },
      %*{"peerId": "no-addresses", "addrs": []},
    ]

    let backend = ExternalServiceDiscovery.create(
      serviceLookupInterval = 50.milliseconds, randomLookupInterval = 1.hours
    )
    var observed: seq[PeersDiscovered]
    discard PeersDiscovered.listen(
      backend.brokerCtx,
      proc(ev: PeersDiscovered) {.async: (raises: []).} =
        observed.add(ev),
    )

    check (await backend.startDiscovery()).isOk()
    check (await backend.registerInterest("svc:/logos/delivery")).isOk()

    let peerStore = node.peerManager.switch.peerStore
    await waitUntil(
      proc(): bool =
        peerStore[SourceBook].book.hasKey(remoteId)
    )
    check:
      peerStore[SourceBook][remoteId] == PeerOrigin.External
      peerStore[AddressBook][remoteId] ==
        @[MultiAddress.init("/ip4/127.0.0.1/tcp/61234").get()]
      "/mix/1.0.0" in peerStore[ProtoBook][remoteId]
      observed.len > 0
      observed[0].origin == ExternalBackendId
      observed[0].key == "svc:/logos/delivery"

    check (await backend.stopDiscovery()).isOk()

  asyncTest "two nodes find each other through a shared host registry":
    let registry = Registry()

    ## Each node gets its own broker scope, as the library gives it.
    let ctxA = NewBrokerContext()
    setThreadBrokerContext(ctxA)
    let keyA = generateSecp256k1Key()
    let nodeA = newTestWakuNode(keyA, parseIpAddress("127.0.0.1"), Port(0))
    await nodeA.start()
    provideNodeState(ctxA, nodeA, keyA)
    discard newFakeHost(ctxA, registry)
    let backendA = ExternalServiceDiscovery.create()

    let ctxB = NewBrokerContext()
    setThreadBrokerContext(ctxB)
    let keyB = generateSecp256k1Key()
    let nodeB = newTestWakuNode(keyB, parseIpAddress("127.0.0.1"), Port(0))
    await nodeB.start()
    provideNodeState(ctxB, nodeB, keyB)
    discard newFakeHost(ctxB, registry)
    let backendB = ExternalServiceDiscovery.create(
      serviceLookupInterval = 50.milliseconds, randomLookupInterval = 1.hours
    )

    let svcKey = SvcKeyPrefix & LogosDeliveryServiceId
    check (await backendA.startDiscovery()).isOk()
    check (await backendA.startAdvertising(svcKey, @[1'u8])).isOk()
    check (await backendB.startDiscovery()).isOk()
    check (await backendB.registerInterest(svcKey)).isOk()

    let peerIdA = nodeA.switch.peerInfo.peerId
    let storeB = nodeB.peerManager.switch.peerStore
    await waitUntil(
      proc(): bool =
        storeB[SourceBook].book.hasKey(peerIdA)
    )
    check storeB[SourceBook][peerIdA] == PeerOrigin.External

    ## What B learned is enough to reach A.
    let infoA = storeB.getPeer(peerIdA)
    check await nodeB.peerManager.connectPeer(infoA)

    check (await backendB.stopDiscovery()).isOk()
    check (await backendA.stopDiscovery()).isOk()
    await allFutures(nodeA.stop(), nodeB.stop())
