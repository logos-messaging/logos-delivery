{.used.}

import std/[sequtils, strutils]
import chronos, results, testutils/unittests
import brokers/[broker_context, broker_implement]
import libp2p/[peerid, peerinfo, multiaddress, crypto/crypto, extended_peer_record]
import
  logos_delivery/waku/discovery/external_service_discovery,
  logos_delivery/waku/requests/node_state_requests,
  logos_delivery/waku/node/peer_manager/peer_manager,
  logos_delivery/waku/waku_core,
  ../testlib/wakucore

## A fake host, the Nim stand-in for the library's reverse-FFI one: it
## implements `IServiceDiscoveryHost` on the node's broker context and records
## what the backend asked of it. Everything runs on the test's own loop.

const FakePeerId = "16Uiu2HAm4gVVMqAzg2gT5cBii3qfaXykUJoB7jyHgAu71RuiELmz"

type FakeHost* = ref object of IServiceDiscoveryHost
  missing: string ## non-empty: `hostCheck` reports these verbs unimplemented
  started: bool
  failStart: bool
  refuseVerbs: int
    ## The next this many startAdvertising/registerInterest calls are refused,
    ## the way libp2p refuses them before its switch has started.
  advertDelay: Duration ## the next startAdvertising waits this long, once
  advertLive: bool
    ## Whether the host holds the advert. Like libp2p, it refuses to advertise
    ## a key it already holds.
  advertCalls: int ## every startAdvertising call, taken or not
  advertTaken: int
  advertRefusedAsHeld: int
  stopAdvertCalls: int
  interestTaken: int
  lookups: int
  lastKey: string
  lastLimit: int
  lastData: seq[byte]
  lastRecord: seq[byte]

proc fakePeers(): seq[DiscoveredPeer] =
  @[
    DiscoveredPeer(
      peerId: FakePeerId,
      seqNo: 7,
      addrs: @["/ip4/1.2.3.4/tcp/60000"],
      services: @[DiscoveredService(id: "/mix/1.0.0", data: @[1'u8, 2, 3])],
    )
  ]

proc refused(self: FakeHost): bool =
  if self.refuseVerbs <= 0:
    return false
  dec self.refuseVerbs
  true

BrokerImplement FakeHost of IServiceDiscoveryHost:
  method hostCheck(self: FakeHost): Future[Result[void, string]] {.async.} =
    if self.missing.len > 0:
      return err("the host has not implemented " & self.missing)
    ok()

  method hostStart(self: FakeHost): Future[Result[void, string]] {.async.} =
    if self.failStart:
      return err("host refused to start")
    self.started = true
    ok()

  method hostStop(self: FakeHost): Future[Result[void, string]] {.async.} =
    self.started = false
    ok()

  method hostLookup(
      self: FakeHost, key: string, limit: int
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    inc self.lookups
    self.lastKey = key
    self.lastLimit = limit
    ok(fakePeers())

  method hostRandomLookup(
      self: FakeHost
  ): Future[Result[seq[DiscoveredPeer], string]] {.async.} =
    inc self.lookups
    ok(fakePeers())

  method hostStartAdvertising(
      self: FakeHost, key: string, data: seq[byte], record: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    ## Recorded on entry, so a test can tell which advert a call in flight is for.
    self.lastKey = key
    inc self.advertCalls
    if self.refused():
      return err("switch not started; call libp2p_ctx_start first")
    if self.advertLive:
      inc self.advertRefusedAsHeld
      ## libp2p's own wording (`addProvidedService`), which the backend relies on.
      return err("service 'x' is already advertised, stop it first")
    let delay = self.advertDelay
    self.advertDelay = ZeroDuration
    if delay > ZeroDuration:
      try:
        await sleepAsync(delay)
      except CancelledError:
        return err("cancelled")
    self.lastData = data
    self.lastRecord = record
    self.advertLive = true
    inc self.advertTaken
    ok()

  method hostStopAdvertising(
      self: FakeHost, key: string
  ): Future[Result[void, string]] {.async.} =
    self.lastKey = key
    self.advertLive = false
    inc self.stopAdvertCalls
    ok()

  method hostRegisterInterest(
      self: FakeHost, key: string
  ): Future[Result[void, string]] {.async.} =
    if self.refused():
      return err("switch not started; call libp2p_ctx_start first")
    self.lastKey = key
    inc self.interestTaken
    ok()

  method hostUnregisterInterest(
      self: FakeHost, key: string
  ): Future[Result[void, string]] {.async.} =
    self.lastKey = key
    ok()

template eventually(cond: untyped, timeout = chronos.seconds(15)): bool =
  ## Adverts and interests reach the host from the announce loop, not from the
  ## verb call, so a test waits for their effect instead of reading it at once.
  block:
    let deadline = Moment.now() + timeout
    while not (cond) and Moment.now() < deadline:
      await sleepAsync(chronos.milliseconds(20))
    cond

proc provideNodeIdentity(ctx: BrokerContext): PeerInfo =
  ## What `startAdvertising` signs the record with.
  let nodeKey = generateSecp256k1Key()
  let peerInfo = PeerInfo.new(nodeKey)
  peerInfo.addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/44002").get()]
  discard GetNodePeerInfo.reprovideIt(ctx):
    ok(peerInfo)
  discard GetNodeKey.reprovideIt(ctx):
    ok(nodeKey)
  peerInfo

suite "ExternalServiceDiscovery":
  var fake {.threadvar.}: FakeHost

  setup:
    ## A context per test, as the library gives each node its own: `close`
    ## leaves the default context alone, so a fake installed there would
    ## outlive its test and answer the next one. The host goes on the context
    ## the backend resolves the node through, as the library installs it on
    ## the node's.
    setThreadBrokerContext(NewBrokerContext())
    fake = FakeHost.createUnderContext(globalBrokerContext())

  teardown:
    fake.close()
    fake = nil
    setThreadBrokerContext(DefaultBrokerContext)

  asyncTest "verbs reach the host":
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check fake.started

    let info = (await iface.backendInfo()).valueOr:
      raiseAssert error
    check:
      info.id == "service-ext"
      info.running

    let peers = (await iface.lookupServicePeers("service:/mix/1.0.0", 5)).valueOr:
      raiseAssert error
    check:
      peers.len == 1
      peers[0].peerId == FakePeerId
      peers[0].addrs == @["/ip4/1.2.3.4/tcp/60000"]
      peers[0].seqNo == 7
      peers[0].services.len == 1
      peers[0].services[0].id == "/mix/1.0.0"
      peers[0].services[0].data == @[1'u8, 2, 3]
      fake.lastKey == "service:/mix/1.0.0"
      fake.lastLimit == 5

    check (await iface.lookupRandom()).isOk()
    check fake.lookups == 2

    ## Advertising publishes a record the node signs; without the node's
    ## identity the backend refuses rather than letting the host publish its
    ## own.
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isErr()
    check fake.lastRecord.len == 0
    let peerInfo = provideNodeIdentity(ctx)
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken == 1)
    check:
      fake.lastKey == "service:x"
      fake.lastData == @[1'u8, 2]
      fake.lastRecord.len > 0
    ## What the host got is this node's record, listing exactly this service
    ## (service: prefix stripped) with the advertised payload.
    let record = SignedExtendedPeerRecord.decode(fake.lastRecord).expect("decodes")
    record.checkValid().expect("signed by the node")
    check:
      record.data.peerId == peerInfo.peerId
      record.data.addresses.len == 1
      record.data.services.len == 1
      record.data.services[0].id == "x"
      record.data.services[0].data == Opt.some(@[1'u8, 2])
    check (await iface.startAdvertising("topic:/waku/2/rs/0/0", @[])).isErr()

    check (await iface.registerInterest("service:y")).isOk()
    check eventually(fake.interestTaken == 1)
    check fake.lastKey == "service:y"

    ## A no-op that still succeeds: the provider took its bootstrap entries at
    ## init and exposes no call to add more.
    check (await iface.addBootstrapEntries(@["/ip4/1.2.3.4/tcp/1/p2p/16Uxx"])).isOk()

    check (await iface.stopDiscovery()).isOk()
    check not fake.started

  asyncTest "discovery can be restarted on the same node":
    let backend = ExternalServiceDiscovery.create()

    for _ in 0 .. 2:
      check (await backend.startDiscovery()).isOk()
      check fake.started
      let peers = (await backend.lookupServicePeers("service:/mix/1.0.0", 3)).valueOr:
        raiseAssert error
      check peers.len == 1
      check (await backend.stopDiscovery()).isOk()
      check not fake.started

  asyncTest "configured but no host installed: start refuses to run":
    ## Config alone is not enough — the host half must be there too.
    fake.close()
    let backend = ExternalServiceDiscovery.create()
    let res = await backend.startDiscovery()
    check res.isErr()

  asyncTest "a host missing verbs fails start and names them":
    fake.missing = "sd_lookup, sd_stop"
    let backend = ExternalServiceDiscovery.create()
    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "sd_lookup, sd_stop" in res.error
      not fake.started

  asyncTest "host error text is surfaced":
    let backend = ExternalServiceDiscovery.create()
    fake.failStart = true
    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "host refused to start" in res.error

  asyncTest "discovered peers are handed to the PeerManager":
    ## The host discovers on its own switch, so nothing else in the node sees
    ## what it found: the backend has to put the peers in the peer store
    ## itself, the way the in-process backend does in `processRecords`.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()

    let peerManager = PeerManager.new(switch = newTestSwitch(), storage = nil)
    discard GetNodePeerManager.reprovideIt(ctx):
      ok(peerManager)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.lookupServicePeers("service:/mix/1.0.0", 1)).isOk()

    let wanted = PeerId.init(FakePeerId).get()
    let stored = peerManager.switch.peerStore.getPeer(wanted)
    check:
      stored.peerId == wanted
      stored.addrs.mapIt($it) == @["/ip4/1.2.3.4/tcp/60000"]
      stored.origin == PeerOrigin.Kademlia
      "/mix/1.0.0" in stored.protocols

    ## The random walk feeds the node too, not just the service lookup.
    check (await iface.lookupRandom()).isOk()
    check (await iface.stopDiscovery()).isOk()

  asyncTest "the first service lookup does not wait a whole interval":
    ## The loop opens on the eager schedule and only then settles into the
    ## configured interval. With ten minutes configured, a lookup that lands
    ## within a few seconds can only have come from the eager phase.
    let backend =
      ExternalServiceDiscovery.create(serviceLookupInterval = chronos.minutes(10))

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.registerInterest("service:/logos/delivery")).isOk()
    check fake.lookups == 0

    await sleepAsync(chronos.seconds(4))
    check fake.lookups >= 1

    check (await iface.stopDiscovery()).isOk()

  asyncTest "refused adverts and interests are retried until the host takes them":
    ## The host is up but its libp2p switch is not: it refuses the verbs the
    ## node sends at start. They must not be lost -- the node has no other
    ## moment to send them.
    let backend = ExternalServiceDiscovery.create()
    discard provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.refuseVerbs = 3

    ## Taken on, not yet published: ok although the host refuses.
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check (await iface.registerInterest("service:y")).isOk()

    ## Taken once and left alone: with nothing pending the loop is parked, and
    ## calls the host again only when something wakes it.
    check eventually(backend.pendingAnnouncements() == 0)
    check:
      fake.refuseVerbs == 0
      fake.advertTaken == 1
      fake.interestTaken == 1
      fake.advertLive
      fake.advertRefusedAsHeld == 0

    check (await iface.stopDiscovery()).isOk()

  asyncTest "an advert the host already holds counts as taken":
    ## A call can time out on the node's side and still complete on the host's
    ## (the reverse call is abandoned, not interrupted). The retry is then
    ## refused as already advertised, which says the host holds it.
    let backend = ExternalServiceDiscovery.create()
    discard provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.advertLive = true

    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()

    ## Taken through "already advertised": no stop, no republish, and nothing
    ## left pending that could call again.
    check eventually(backend.pendingAnnouncements() == 0)
    check:
      fake.advertTaken == 0
      fake.advertRefusedAsHeld == 1
      fake.stopAdvertCalls == 0
      fake.advertLive

    check (await iface.stopDiscovery()).isOk()

  asyncTest "a new session replaces the record the host still holds":
    ## libp2p outlives the node's discovery session, so after a restart it may
    ## hold the last session's record, with the addresses of that time.
    let backend = ExternalServiceDiscovery.create()
    discard provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken == 1)
    check fake.stopAdvertCalls == 0

    check (await iface.stopDiscovery()).isOk()
    check fake.advertLive # the fake's host stop keeps it, as libp2p does
    check (await iface.startDiscovery()).isOk()

    check eventually(fake.advertTaken == 2)
    check:
      fake.stopAdvertCalls == 1
      fake.advertRefusedAsHeld == 0

    check (await iface.stopDiscovery()).isOk()

  asyncTest "new data replaces the advert; the same data sends nothing":
    let backend = ExternalServiceDiscovery.create()
    discard provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken == 1)

    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    ## The same data leaves the advert taken, so there is nothing to send.
    check:
      backend.pendingAnnouncements() == 0
      fake.advertTaken == 1
      fake.stopAdvertCalls == 0

    check (await iface.startAdvertising("service:x", @[7'u8])).isOk()
    check eventually(fake.advertTaken == 2)
    check:
      fake.stopAdvertCalls == 1
      fake.lastData == @[7'u8]
      fake.advertRefusedAsHeld == 0

    check (await iface.stopDiscovery()).isOk()

  asyncTest "an advert given up while still refused is never published":
    let backend = ExternalServiceDiscovery.create()
    discard provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.refuseVerbs = 1000

    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    ## Once it has been tried, the host may hold it, so it gets withdrawn.
    check eventually(fake.refuseVerbs < 1000)
    check (await iface.stopAdvertising("service:x")).isOk()
    ## Gone from what the node wants, so nothing can send it any more.
    check:
      backend.pendingAnnouncements() == 0
      fake.stopAdvertCalls == 1 # the best-effort stop

    fake.refuseVerbs = 0
    check:
      fake.advertTaken == 0
      not fake.advertLive

    check (await iface.stopDiscovery()).isOk()

  asyncTest "verbs before start are handed over once discovery starts":
    let backend = ExternalServiceDiscovery.create()
    discard provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check (await iface.registerInterest("service:y")).isOk()
    check:
      fake.advertTaken == 0
      fake.interestTaken == 0

    check (await iface.startDiscovery()).isOk()
    check eventually(fake.advertTaken == 1 and fake.interestTaken == 1)

    check (await iface.stopDiscovery()).isOk()

  asyncTest "an advert is re-signed when the node's addresses change":
    ## The host publishes the record it was handed and never refreshes it, so
    ## a record signed at start would advertise stale addresses for good.
    let backend = ExternalServiceDiscovery.create()
    let peerInfo = provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken == 1)

    proc publishedAddrs(): seq[string] =
      let record = SignedExtendedPeerRecord.decode(fake.lastRecord).expect("decodes")
      record.data.addresses.mapIt($it.address)

    check publishedAddrs() == @["/ip4/127.0.0.1/tcp/44002"]

    ## What `PeerInfo.update` does after a changed commit.
    peerInfo.addrs = @[MultiAddress.init("/ip4/203.0.113.7/tcp/44002").get()]
    peerInfo.notifyObservers()

    ## Taken back and published again, with the new address.
    check eventually(fake.advertTaken == 2)
    check:
      publishedAddrs() == @["/ip4/203.0.113.7/tcp/44002"]
      fake.stopAdvertCalls == 1
      fake.advertRefusedAsHeld == 0

    ## Once stopped, the node no longer follows its addresses. Observers run
    ## synchronously, so one still attached would have marked the advert
    ## pending by the time `notifyObservers` returns.
    check (await iface.stopDiscovery()).isOk()
    peerInfo.addrs = @[MultiAddress.init("/ip4/198.51.100.9/tcp/44002").get()]
    peerInfo.notifyObservers()
    check:
      backend.pendingAnnouncements() == 0
      fake.advertTaken == 2

  asyncTest "a key removed while a pass is out is not sent":
    ## A pass walks a snapshot of the keys. One removed during an earlier call
    ## of the same pass must be skipped, not sent as an empty default entry.
    let backend = ExternalServiceDiscovery.create()
    discard provideNodeIdentity(globalBrokerContext())

    let iface: IPeerDiscovery = backend
    ## Both wanted before start, so the first pass has both in its snapshot.
    check (await iface.startAdvertising("service:a", @[1'u8])).isOk()
    check (await iface.startAdvertising("service:b", @[2'u8])).isOk()
    fake.advertDelay = chronos.milliseconds(500)
    check (await iface.startDiscovery()).isOk()

    ## The first advert's call is inside the host (it consumed the delay);
    ## stop the other one meanwhile.
    check eventually(fake.advertDelay == ZeroDuration)
    let other = if fake.lastKey == "service:a": "service:b" else: "service:a"
    check (await iface.stopAdvertising(other)).isOk()

    check eventually(backend.pendingAnnouncements() == 0)
    check:
      fake.advertCalls == 1
      fake.advertTaken == 1
      fake.advertRefusedAsHeld == 0

    check (await iface.stopDiscovery()).isOk()

  asyncTest "an interest the host refuses is still looked up":
    ## A lookup does not depend on the interest, which only pre-warms the
    ## provider's table; a refused interest used to drop the key from the
    ## lookup loop for good.
    let backend =
      ExternalServiceDiscovery.create(serviceLookupInterval = chronos.minutes(10))

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.refuseVerbs = 1000
    check (await iface.registerInterest("service:/logos/delivery")).isOk()

    check eventually(fake.lookups >= 1)
    check fake.interestTaken == 0

    check (await iface.stopDiscovery()).isOk()
