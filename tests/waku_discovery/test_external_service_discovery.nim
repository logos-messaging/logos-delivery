{.used.}

import std/[atomics, strutils]
import chronos, results, testutils/unittests
import brokers/broker_context
import logos_delivery/waku/discovery/external_service_discovery

## A fake plugin written the way a real one would be: plain C entry points
## over shared state. The entry points run on the discovery worker thread, so
## the state must live in shared memory (no Nim GC types) for the assertions
## on the test thread to see it.

type FakeState = object
  started: Atomic[bool]
  failNext: Atomic[bool]
  freed: Atomic[int]
  bootstrapCount: Atomic[int]
  lastLimit: Atomic[int64]
  lastDataLen: Atomic[int]
  lastRecordLen: Atomic[int]
  lastKeyLen: Atomic[int]
  lastKey: array[128, char]
  lastData: array[32, uint8]
  lastRecord: array[32, uint8]

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

proc fakeStart(
    ctx: pointer, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  if fake.failNext.load():
    setErr(errBuf, errBufLen, "plugin refused to start")
    return LdDiscoError
  fake.started.store(true)
  LdDiscoOk

proc fakeStop(
    ctx: pointer, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  fake.started.store(false)
  LdDiscoOk

const FakePeersJson =
  """[{"peerId":"peer-from-plugin","seqNo":7,""" &
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
  setKey(key)
  let dn = min(dataLen.int, fake.lastData.len)
  for i in 0 ..< dn:
    fake.lastData[i] = data[i]
  fake.lastDataLen.store(dn)
  let rn = min(recordLen.int, fake.lastRecord.len)
  for i in 0 ..< rn:
    fake.lastRecord[i] = record[i]
  fake.lastRecordLen.store(rn)
  LdDiscoOk

proc fakeKeyOp(
    ctx: pointer, key: cstring, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  setKey(key)
  LdDiscoOk

proc fakeAddBootstrap(
    ctx: pointer,
    entries: ptr UncheckedArray[cstring],
    entriesLen: csize_t,
    errBuf: cstring,
    errBufLen: csize_t,
): cint {.cdecl, gcsafe, raises: [].} =
  fake.bootstrapCount.store(entriesLen.int)
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
    stopAdvertising: fakeKeyOp,
    registerInterest: fakeKeyOp,
    unregisterInterest: fakeKeyOp,
    addBootstrapEntries: fakeAddBootstrap,
  )

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
    let peers = (await iface.lookupServicePeers("svc:/mix/1.0.0", 5)).valueOr:
      raiseAssert error
    check:
      peers.len == 1
      peers[0].peerId == "peer-from-plugin"
      peers[0].addrs == @["/ip4/1.2.3.4/tcp/60000"]
      peers[0].seqNo == 7
      peers[0].services.len == 1
      peers[0].services[0].id == "/mix/1.0.0"
      peers[0].services[0].data == @[1'u8, 2, 3]
      lastKey() == "svc:/mix/1.0.0"
      fake.lastLimit.load() == 5
      fake.freed.load() == 1 # the plugin-owned JSON was handed back

    check (await iface.lookupRandom()).isOk()
    check fake.freed.load() == 2

    check (await iface.startAdvertising("svc:x", @[1'u8, 2], @[9'u8])).isOk()
    check:
      fake.lastDataLen.load() == 2
      fake.lastRecordLen.load() == 1
      fake.lastRecord[0] == 9'u8

    check (await iface.registerInterest("svc:y")).isOk()
    check lastKey() == "svc:y"

    check (await iface.addBootstrapEntries(@["/ip4/1.2.3.4/tcp/1/p2p/16Uxx"])).isOk()
    check fake.bootstrapCount.load() == 1

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

    let peers = (await backend.lookupServicePeers("svc:/mix/1.0.0", 3)).valueOr:
      raiseAssert error
    check peers.len == 1

    check (await backend.stopDiscovery()).isOk()

  asyncTest "configured without a valid plugin refuses to start":
    ## A node configured for external discovery but left without a usable
    ## plugin must fail to start, not come up believing it has discovery.
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    var bad = fakePlugin()
    bad.lookup = nil
    check storePlugin(ctx, bad).isOk() # bypasses the broker's validation

    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "missing entry point" in res.error
    dropPlugin(ctx)

  asyncTest "configured but unregistered: verbs refuse to run":
    ## Config alone is not enough — the plugin half must be there too.
    let backend = ExternalServiceDiscovery.create()
    check (await ClearServiceDiscoveryPlugin.request(globalBrokerContext())).isOk()

    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "no service discovery plugin registered" in res.error

  asyncTest "a plugin that loses an entry point is refused at use time":
    ## Registration validates, and so does every call: a vtable that went
    ## partial after the fact can never be invoked.
    let ctx = globalBrokerContext()
    let backend = ExternalServiceDiscovery.create()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    check (await backend.startDiscovery()).isOk()

    var partial = fakePlugin()
    partial.lookup = nil
    check storePlugin(ctx, partial).isOk() # bypasses the broker's validation

    let res = await backend.lookupRandom()
    check:
      res.isErr()
      "missing entry point" in res.error

    discard await backend.stopDiscovery()
    dropPlugin(ctx)

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
      ## Still registered, untouched by the stop.
      check loadPlugin(ctx).isSome()

    check (await ClearServiceDiscoveryPlugin.request(ctx)).isOk()
    check loadPlugin(ctx).isNone()
