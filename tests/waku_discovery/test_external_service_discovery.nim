{.used.}

import std/[atomics, os, sequtils, strutils]
import chronos, chronos/threadsync, results, testutils/unittests
import brokers/broker_context
import libp2p/[peerid, peerinfo, multiaddress, crypto/crypto, extended_peer_record]
import
  logos_delivery/waku/discovery/external_service_discovery,
  logos_delivery/waku/requests/node_state_requests,
  logos_delivery/waku/node/peer_manager/peer_manager,
  logos_delivery/waku/waku_core,
  ../testlib/common,
  ../testlib/wakucore

## A fake plugin written the way a real one would be: plain C entry points
## over shared state. The entry points run on the discovery worker thread, so
## the state must live in shared memory (no Nim GC types) for the assertions
## on the test thread to see it.

type FakeState = object
  started: Atomic[bool]
  failNext: Atomic[bool]
  blockLookup: Atomic[bool] ## lookup spins until cleared, like a wedged provider
  startDelayMs: Atomic[int] ## start sleeps this long, like a real bring-up
  freed: Atomic[int]
  lastLimit: Atomic[int64]
  lastDataLen: Atomic[int]
  lastRecordLen: Atomic[int]
  lastKeyLen: Atomic[int]
  refuseVerbs: Atomic[int]
    ## The next this many startAdvertising/registerInterest calls are refused,
    ## the way libp2p refuses them before its switch has started.
  advertDelayMs: Atomic[int] ## the next startAdvertising sleeps this long, once
  advertLive: Atomic[bool]
    ## Whether the plugin holds the advert. Like libp2p, it refuses to
    ## advertise a key it already holds.
  advertTaken: Atomic[int]
  advertRefusedAsHeld: Atomic[int]
  stopAdvertCalls: Atomic[int]
  interestTaken: Atomic[int]
  lookupStuck: ThreadSignalPtr ## fired when a lookup starts to block
  stuckThreadExited: ThreadSignalPtr ## fired after the thread stuck in lookup exits
  lastKey: array[128, char]
  lastData: array[32, uint8]
  lastRecord: array[512, uint8]

var fake: ptr FakeState

proc setKey(s: cstring) =
  var n = 0
  while n < fake.lastKey.high and s[n] != '\0':
    fake.lastKey[n] = s[n]
    inc n
  fake.lastKeyLen.store(n)

proc lastKey(): string =
  let n = fake.lastKeyLen.load()
  result = newString(n)
  for i in 0 ..< n:
    result[i] = fake.lastKey[i]

proc setErr(errBuf: cstring, errBufLen: csize_t, msg: string) =
  let buf = cast[ptr UncheckedArray[char]](errBuf)
  let n = min(msg.len, errBufLen.int - 1)
  for i in 0 ..< n:
    buf[i] = msg[i]
  buf[n] = '\0'

proc refused(errBuf: cstring, errBufLen: csize_t): bool =
  if fake.refuseVerbs.load() <= 0:
    return false
  discard fake.refuseVerbs.fetchSub(1)
  setErr(errBuf, errBufLen, "switch not started; call libp2p_ctx_start first")
  true

proc fakeStart(
    ctx: pointer, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  if fake.failNext.load():
    setErr(errBuf, errBufLen, "plugin refused to start")
    return LdDiscoError
  let delay = fake.startDelayMs.load()
  if delay > 0:
    sleep(delay)
  fake.started.store(true)
  LdDiscoOk

proc fakeStop(
    ctx: pointer, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  fake.started.store(false)
  LdDiscoOk

const FakePeerId = "16Uiu2HAm4gVVMqAzg2gT5cBii3qfaXykUJoB7jyHgAu71RuiELmz"

const FakePeersJson =
  """[{"peerId":"""" & FakePeerId & """","seqNo":7,""" &
  """"addrs":["/ip4/1.2.3.4/tcp/60000"],""" &
  """"services":[{"id":"/mix/1.0.0","data":"AQID"}]}]"""

proc emitJson(outJson: ptr cstring) =
  ## Hands out a heap copy the way a real plugin would; freed via freeString.
  let n = FakePeersJson.len
  let buf = cast[cstring](allocShared0(n + 1))
  copyMem(buf, FakePeersJson.cstring, n)
  outJson[] = buf

proc fakeLookup(
    ctx: pointer,
    key: cstring,
    limit: int64,
    outJson: ptr cstring,
    errBuf: cstring,
    errBufLen: csize_t,
): cint {.cdecl, gcsafe, raises: [].} =
  if fake.failNext.load():
    setErr(errBuf, errBufLen, "lookup exploded")
    return LdDiscoError
  if fake.blockLookup.load():
    ## Fire on thread exit, after `workerMain` returns and sets `done`.
    let exited = fake.stuckThreadExited
    onThreadDestruction(
      proc() {.closure, gcsafe, raises: [].} =
        discard exited.fireSync()
    )
    ## Tell the test that this lookup is inside the plugin.
    discard fake.lookupStuck.fireSync()
  while fake.blockLookup.load():
    sleep(10)
  setKey(key)
  fake.lastLimit.store(limit)
  emitJson(outJson)
  LdDiscoOk

proc fakeRandomLookup(
    ctx: pointer, outJson: ptr cstring, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  emitJson(outJson)
  LdDiscoOk

proc fakeFreeString(ctx: pointer, s: cstring) {.cdecl, gcsafe, raises: [].} =
  if not s.isNil():
    deallocShared(s)
  fake.freed.atomicInc()

proc fakeStartAdvertising(
    ctx: pointer,
    key: cstring,
    data: ptr UncheckedArray[uint8],
    dataLen: csize_t,
    record: ptr UncheckedArray[uint8],
    recordLen: csize_t,
    errBuf: cstring,
    errBufLen: csize_t,
): cint {.cdecl, gcsafe, raises: [].} =
  if refused(errBuf, errBufLen):
    return LdDiscoError
  if fake.advertLive.load():
    discard fake.advertRefusedAsHeld.fetchAdd(1)
    ## libp2p's own wording (`addProvidedService`), which the backend relies on.
    setErr(errBuf, errBufLen, "service 'x' is already advertised, stop it first")
    return LdDiscoError
  let delay = fake.advertDelayMs.exchange(0)
  if delay > 0:
    sleep(delay)
  setKey(key)
  let dn = min(dataLen.int, fake.lastData.len)
  for i in 0 ..< dn:
    fake.lastData[i] = data[i]
  fake.lastDataLen.store(dn)
  let rn = min(recordLen.int, fake.lastRecord.len)
  for i in 0 ..< rn:
    fake.lastRecord[i] = record[i]
  fake.lastRecordLen.store(rn)
  fake.advertLive.store(true)
  discard fake.advertTaken.fetchAdd(1)
  LdDiscoOk

proc fakeStopAdvertising(
    ctx: pointer, key: cstring, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  setKey(key)
  fake.advertLive.store(false)
  discard fake.stopAdvertCalls.fetchAdd(1)
  LdDiscoOk

proc fakeRegisterInterest(
    ctx: pointer, key: cstring, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  if refused(errBuf, errBufLen):
    return LdDiscoError
  setKey(key)
  discard fake.interestTaken.fetchAdd(1)
  LdDiscoOk

proc fakeKeyOp(
    ctx: pointer, key: cstring, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  setKey(key)
  LdDiscoOk

proc fakePlugin(): ServiceDiscoveryPlugin =
  ServiceDiscoveryPlugin(
    abiVersion: LdDiscoAbiVersion,
    pluginCtx: nil,
    requestTimeoutMs: 2000,
    start: fakeStart,
    stop: fakeStop,
    lookup: fakeLookup,
    randomLookup: fakeRandomLookup,
    freeString: fakeFreeString,
    startAdvertising: fakeStartAdvertising,
    stopAdvertising: fakeStopAdvertising,
    registerInterest: fakeRegisterInterest,
    unregisterInterest: fakeKeyOp,
  )

template eventually(cond: untyped, timeout = chronos.seconds(15)): bool =
  ## Adverts and interests reach the plugin from the reconciler, not from the
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
  setup:
    fake = cast[ptr FakeState](allocShared0(sizeof(FakeState)))

  teardown:
    deallocShared(fake)
    fake = nil

  asyncTest "verbs reach the plugin on the worker thread":
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check fake.started.load()

    let info = (await iface.backendInfo()).valueOr:
      raiseAssert error
    check:
      info.id == "service-ext"
      info.running

    ## JSON from the plugin is parsed on the worker and returned as typed
    ## peers, including the base64 service payload.
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
      lastKey() == "service:/mix/1.0.0"
      fake.lastLimit.load() == 5
      fake.freed.load() == 1 # the plugin-owned JSON was handed back

    check (await iface.lookupRandom()).isOk()
    check fake.freed.load() == 2

    ## Advertising publishes a record the node signs; without the node's
    ## identity the backend refuses rather than letting the plugin publish
    ## its own.
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isErr()
    check fake.lastRecordLen.load() == 0
    let nodeKey = generateSecp256k1Key()
    let peerInfo = PeerInfo.new(nodeKey)
    peerInfo.addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/44002").get()]
    discard GetNodePeerInfo.reprovideIt(ctx):
      ok(peerInfo)
    discard GetNodeKey.reprovideIt(ctx):
      ok(nodeKey)
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken.load() == 1)
    check:
      lastKey() == "service:x"
      fake.lastDataLen.load() == 2
      fake.lastRecordLen.load() > 0
    ## What the plugin got is this node's record, listing exactly this
    ## service (service: prefix stripped) with the advertised payload.
    let recordBytes = @(fake.lastRecord)[0 ..< fake.lastRecordLen.load()]
    let record = SignedExtendedPeerRecord.decode(recordBytes).expect("decodes")
    record.checkValid().expect("signed by the node")
    check:
      record.data.peerId == peerInfo.peerId
      record.data.addresses.len == 1
      record.data.services.len == 1
      record.data.services[0].id == "x"
      record.data.services[0].data == Opt.some(@[1'u8, 2])
    check (await iface.startAdvertising("topic:/waku/2/rs/0/0", @[])).isErr()

    check (await iface.registerInterest("service:y")).isOk()
    check eventually(fake.interestTaken.load() == 1)
    check lastKey() == "service:y"

    ## A no-op that still succeeds: the provider took its bootstrap entries at
    ## init and exposes no call to add more.
    check (await iface.addBootstrapEntries(@["/ip4/1.2.3.4/tcp/1/p2p/16Uxx"])).isOk()

    check (await iface.stopDiscovery()).isOk()
    check not fake.started.load()

  asyncTest "discovery can be restarted on the same node":
    ## The worker is joined when discovery stops, so a restart has to spawn a
    ## fresh one on the same broker context. That only works because the
    ## exiting thread hands its (mt) buckets back.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

    check (await backend.startDiscovery()).isOk()
    check fake.started.load()
    check (await backend.stopDiscovery()).isOk()
    check not fake.started.load()

    ## Second session: a new worker, same context.
    check (await backend.startDiscovery()).isOk()
    check fake.started.load()

    let peers = (await backend.lookupServicePeers("service:/mix/1.0.0", 3)).valueOr:
      raiseAssert error
    check peers.len == 1

    check (await backend.stopDiscovery()).isOk()

  asyncTest "configured but unregistered: verbs refuse to run":
    ## Config alone is not enough — the plugin half must be there too.
    let backend = ExternalServiceDiscovery.create()
    check (await ClearServiceDiscoveryPlugin.request(globalBrokerContext())).isOk()

    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "no service discovery plugin registered" in res.error

  asyncTest "plugin error text is surfaced":
    let backend = ExternalServiceDiscovery.create()
    check (await SetServiceDiscoveryPlugin.request(globalBrokerContext(), fakePlugin())).isOk()

    fake.failNext.store(true)
    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "plugin refused to start" in res.error

  asyncTest "a plugin with a bad ABI version is rejected":
    let backend = ExternalServiceDiscovery.create()
    var bad = fakePlugin()
    bad.abiVersion = 999
    let res = await SetServiceDiscoveryPlugin.request(globalBrokerContext(), bad)
    check:
      res.isErr()
      "ABI version mismatch" in res.error

  asyncTest "a plugin with a missing entry point is rejected":
    let backend = ExternalServiceDiscovery.create()
    var bad = fakePlugin()
    bad.lookup = nil
    let res = await SetServiceDiscoveryPlugin.request(globalBrokerContext(), bad)
    check:
      res.isErr()
      "missing entry point" in res.error

  asyncTest "registration is refused while discovery is running":
    ## The worker is calling into the vtable, so swapping or removing it now
    ## would change which plugin serves calls already in flight.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    check (await backend.startDiscovery()).isOk()

    let setRes = await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())
    check:
      setRes.isErr()
      "while discovery is running" in setRes.error

    let clearRes = await ClearServiceDiscoveryPlugin.request(ctx)
    check:
      clearRes.isErr()
      "while discovery is running" in clearRes.error

    ## Both become legal again once stopped.
    check (await backend.stopDiscovery()).isOk()
    check (await ClearServiceDiscoveryPlugin.request(ctx)).isOk()

  asyncTest "one registration serves many start/stop cycles":
    ## The plugin is registered once and must survive every cycle; only the
    ## worker thread comes and goes with it.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

    for _ in 0 .. 2:
      check (await backend.startDiscovery()).isOk()
      check fake.started.load()
      check (await backend.lookupRandom()).isOk()
      check (await backend.stopDiscovery()).isOk()
      check not fake.started.load()

    ## Observable proof the registration survived every cycle: once it is
    ## finally cleared, starting is refused again.
    check (await ClearServiceDiscoveryPlugin.request(ctx)).isOk()
    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "no service discovery plugin registered" in res.error

  asyncTest "stop gives up on a worker stuck in a plugin call; a restart works":
    ## The fake fires this when the lookup below starts to block.
    fake.lookupStuck = ThreadSignalPtr.new().expect("thread signal")
    ## The fake fires this when the thread stuck in that lookup exits.
    fake.stuckThreadExited = ThreadSignalPtr.new().expect("thread signal")
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()

    ## The verb never returns, so the caller times out (requestTimeoutMs)...
    fake.blockLookup.store(true)
    let stuck = iface.lookupServicePeers("service:/mix/1.0.0", 1)
    ## Stop only after the lookup is inside the plugin.
    check await fake.lookupStuck.wait().withTimeout(chronos.seconds(30))
    ## ...and stop must not hang the loop behind the join: it reports the
    ## abandoned worker after the grace period instead.
    let t0 = Moment.now()
    let stopped = await iface.stopDiscovery()
    check:
      stopped.isErr()
      Moment.now() - t0 < chronos.seconds(60)
      (await stuck).isErr()

    ## The restart happens while the old thread is STILL inside the plugin --
    ## which is the case that matters, and the one this test used to skip by
    ## releasing the lookup first. It is allowed: the abandoned thread takes no
    ## further work, and the ABI documents that its call may overlap a later
    ## `start`. The successor registers on a fresh context, so it does not
    ## inherit the old registrations.
    check backend.abandonedWorkerCount() == 1
    check (await iface.startDiscovery()).isOk()

    ## Only now release the old thread -- the fake blocks every lookup, so a
    ## verb issued before this would wedge the new worker too.
    fake.blockLookup.store(false)
    let peers = (await iface.lookupServicePeers("service:/mix/1.0.0", 1)).valueOr:
      raiseAssert error
    check peers.len == 1
    ## Restart only after the stuck thread exits, so `reapAbandoned` can join it.
    let stuckThreadGone =
      await fake.stuckThreadExited.wait().withTimeout(chronos.seconds(30))
    check stuckThreadGone

    ## The old thread has left the plugin by now, so the next restart joins it
    ## and forgets it rather than leaking its handle and flags.
    check (await iface.stopDiscovery()).isOk()
    check (await iface.startDiscovery()).isOk()
    check backend.abandonedWorkerCount() == 0
    check (await iface.stopDiscovery()).isOk()

    ## Close the signals only after the stuck thread exits, because its exit
    ## handler uses one.
    if stuckThreadGone:
      discard fake.lookupStuck.close()
      discard fake.stuckThreadExited.close()

  asyncTest "discovered peers are handed to the PeerManager":
    ## The plugin discovers on its own switch, so nothing else in the node
    ## sees what it found: the backend has to put the peers in the peer store
    ## itself, the way the in-process backend does in `processRecords`.
    ## Without this the lookups would succeed and the node would still never
    ## dial anyone.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

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
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.registerInterest("service:/logos/delivery")).isOk()

    ## `freed` counts the plugin-owned JSON handed back, so it rises once per
    ## lookup and not at all for registering an interest.
    check fake.freed.load() == 0

    await sleepAsync(chronos.seconds(4))
    check fake.freed.load() >= 1

    check (await iface.stopDiscovery()).isOk()

  asyncTest "a bring-up slower than the per-verb contract still starts":
    ## `start` brings a whole backend up, so it gets `PluginStartTimeout`
    ## rather than the plugin's per-verb timeout -- and, more to the point,
    ## rather than nim-brokers' 5 s default for the (mt) lane, which is what
    ## the node would otherwise be held to. A plugin that takes 7 s here is
    ## standing in for libp2p's own bring-up, which reaches its fixed 10 s
    ## call budget whenever kademlia bootstraps inside the switch start.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

    fake.startDelayMs.store(7000)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check fake.started.load()

    fake.startDelayMs.store(0)
    check (await iface.stopDiscovery()).isOk()

  asyncTest "refused adverts and interests are retried until the plugin takes them":
    ## The plugin is up but its libp2p switch is not: it refuses the verbs the
    ## node sends at start. They must not be lost -- the node has no other
    ## moment to send them.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    discard provideNodeIdentity(ctx)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.refuseVerbs.store(3)

    ## Taken on, not yet published: ok although the plugin refuses.
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check (await iface.registerInterest("service:y")).isOk()

    ## Taken once and left alone: with nothing pending the loop is parked, and
    ## calls the plugin again only when something wakes it.
    check eventually(backend.pendingAnnouncements() == 0)
    check:
      fake.refuseVerbs.load() == 0
      fake.advertTaken.load() == 1
      fake.interestTaken.load() == 1
      fake.advertLive.load()
      fake.advertRefusedAsHeld.load() == 0

    check (await iface.stopDiscovery()).isOk()

  asyncTest "a call that timed out on our side but completed counts as taken":
    ## The worker is not interrupted on timeout: the plugin may complete a call
    ## the node already gave up on. The retry is then refused as already
    ## advertised, which says the plugin holds it.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    discard provideNodeIdentity(ctx)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.advertDelayMs.store(2500) # past the fake's 2 s requestTimeoutMs

    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()

    ## Taken through "already advertised": no stop, no republish, and nothing
    ## left pending that could call again.
    check eventually(backend.pendingAnnouncements() == 0)
    check:
      fake.advertTaken.load() == 1
      fake.advertRefusedAsHeld.load() == 1
      fake.stopAdvertCalls.load() == 0
      fake.advertLive.load()

    check (await iface.stopDiscovery()).isOk()

  asyncTest "a new session replaces the record the plugin still holds":
    ## libp2p outlives the node's discovery session, so after a restart it may
    ## hold the last session's record, with the addresses of that time.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    discard provideNodeIdentity(ctx)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken.load() == 1)
    check fake.stopAdvertCalls.load() == 0

    check (await iface.stopDiscovery()).isOk()
    check fake.advertLive.load() # the fake's plugin stop keeps it, as libp2p does
    check (await iface.startDiscovery()).isOk()

    check eventually(fake.advertTaken.load() == 2)
    check:
      fake.stopAdvertCalls.load() == 1
      fake.advertRefusedAsHeld.load() == 0

    check (await iface.stopDiscovery()).isOk()

  asyncTest "new data replaces the advert; the same data sends nothing":
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    discard provideNodeIdentity(ctx)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken.load() == 1)

    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    ## The same data leaves the advert taken, so there is nothing to send.
    check:
      backend.pendingAnnouncements() == 0
      fake.advertTaken.load() == 1
      fake.stopAdvertCalls.load() == 0

    check (await iface.startAdvertising("service:x", @[7'u8])).isOk()
    check eventually(fake.advertTaken.load() == 2)
    check:
      fake.stopAdvertCalls.load() == 1
      fake.lastDataLen.load() == 1
      fake.lastData[0] == 7'u8
      fake.advertRefusedAsHeld.load() == 0

    check (await iface.stopDiscovery()).isOk()

  asyncTest "an advert given up while still refused is never published":
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    discard provideNodeIdentity(ctx)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.refuseVerbs.store(1000)

    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    ## Once it has been tried, the plugin may hold it, so it gets withdrawn.
    check eventually(fake.refuseVerbs.load() < 1000)
    check (await iface.stopAdvertising("service:x")).isOk()
    ## Gone from what the node wants, so nothing can send it any more.
    check:
      backend.pendingAnnouncements() == 0
      fake.stopAdvertCalls.load() == 1 # the best-effort stop

    fake.refuseVerbs.store(0)
    check:
      fake.advertTaken.load() == 0
      not fake.advertLive.load()

    check (await iface.stopDiscovery()).isOk()

  asyncTest "verbs before start are handed over once discovery starts":
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    discard provideNodeIdentity(ctx)

    let iface: IPeerDiscovery = backend
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check (await iface.registerInterest("service:y")).isOk()
    check:
      fake.advertTaken.load() == 0
      fake.interestTaken.load() == 0

    check (await iface.startDiscovery()).isOk()
    check eventually(fake.advertTaken.load() == 1 and fake.interestTaken.load() == 1)

    check (await iface.stopDiscovery()).isOk()

  asyncTest "an advert is re-signed when the node's addresses change":
    ## The plugin publishes the record it was handed and never refreshes it,
    ## so a record signed at start would advertise stale addresses for good.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    let peerInfo = provideNodeIdentity(ctx)

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check (await iface.startAdvertising("service:x", @[1'u8, 2])).isOk()
    check eventually(fake.advertTaken.load() == 1)

    proc publishedAddrs(): seq[string] =
      let bytes = @(fake.lastRecord)[0 ..< fake.lastRecordLen.load()]
      let record = SignedExtendedPeerRecord.decode(bytes).expect("decodes")
      record.data.addresses.mapIt($it.address)

    check publishedAddrs() == @["/ip4/127.0.0.1/tcp/44002"]

    ## What `PeerInfo.update` does after a changed commit.
    peerInfo.addrs = @[MultiAddress.init("/ip4/203.0.113.7/tcp/44002").get()]
    peerInfo.notifyObservers()

    ## Taken back and published again, with the new address.
    check eventually(fake.advertTaken.load() == 2)
    check:
      publishedAddrs() == @["/ip4/203.0.113.7/tcp/44002"]
      fake.stopAdvertCalls.load() == 1
      fake.advertRefusedAsHeld.load() == 0

    ## Once stopped, the node no longer follows its addresses. Observers run
    ## synchronously, so one still attached would have marked the advert
    ## pending by the time `notifyObservers` returns.
    check (await iface.stopDiscovery()).isOk()
    peerInfo.addrs = @[MultiAddress.init("/ip4/198.51.100.9/tcp/44002").get()]
    peerInfo.notifyObservers()
    check:
      backend.pendingAnnouncements() == 0
      fake.advertTaken.load() == 2

  asyncTest "an interest the plugin refuses is still looked up":
    ## A lookup does not depend on the interest, which only pre-warms the
    ## provider's table; a refused interest used to drop the key from the
    ## lookup loop for good.
    let backend =
      ExternalServiceDiscovery.create(serviceLookupInterval = chronos.minutes(10))
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    fake.refuseVerbs.store(1000)
    check (await iface.registerInterest("service:/logos/delivery")).isOk()

    check eventually(fake.freed.load() >= 1)
    check fake.interestTaken.load() == 0

    check (await iface.stopDiscovery()).isOk()
