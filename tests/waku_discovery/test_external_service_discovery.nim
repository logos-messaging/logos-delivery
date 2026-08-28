{.used.}

import std/strutils
import chronos, results, testutils/unittests
import brokers/broker_context
import logos_delivery/waku/discovery/external_service_discovery

## A fake plugin written the way a real one would be: plain C entry points
## over a plugin context. Counters let the tests assert what was invoked.
## State is threadvar so the `{.cdecl, gcsafe.}` entry points may touch it.
type FakePluginState = object
  started: bool
  lastKey: string
  lastLimit: int64
  lastData: seq[byte]
  lastRecord: seq[byte]
  bootstrapCount: int
  freed: int
  failNext: bool

var fakeState {.threadvar.}: FakePluginState
var fakePeerId {.threadvar.}: string
var fakeAddr {.threadvar.}: string
var fakePeers {.threadvar.}: seq[LdDiscoPeer]
var fakeAddrs {.threadvar.}: seq[cstring]

proc setErr(errBuf: cstring, errBufLen: csize_t, msg: string) =
  let buf = cast[ptr UncheckedArray[char]](errBuf)
  let n = min(msg.len, errBufLen.int - 1)
  for i in 0 ..< n:
    buf[i] = msg[i]
  buf[n] = '\0'

proc fakeStart(
    ctx: pointer, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  if fakeState.failNext:
    setErr(errBuf, errBufLen, "plugin refused to start")
    return LdDiscoError
  fakeState.started = true
  LdDiscoOk

proc fakeStop(
    ctx: pointer, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  fakeState.started = false
  LdDiscoOk

proc fillPeers(outPeers: ptr LdDiscoPeerList) =
  fakePeerId = "peer-from-plugin"
  fakeAddr = "/ip4/1.2.3.4/tcp/60000"
  fakeAddrs = @[fakeAddr.cstring]
  fakePeers = @[
    LdDiscoPeer(
      peerId: fakePeerId.cstring,
      addrs: cast[ptr UncheckedArray[cstring]](addr fakeAddrs[0]),
      addrsLen: 1,
      enr: nil,
      seqNo: 7,
      services: nil,
      servicesLen: 0,
    )
  ]
  outPeers[] = LdDiscoPeerList(
    peers: cast[ptr UncheckedArray[LdDiscoPeer]](addr fakePeers[0]),
    peersLen: 1,
    owner: nil,
  )

proc fakeLookup(
    ctx: pointer,
    key: cstring,
    limit: int64,
    outPeers: ptr LdDiscoPeerList,
    errBuf: cstring,
    errBufLen: csize_t,
): cint {.cdecl, gcsafe, raises: [].} =
  if fakeState.failNext:
    setErr(errBuf, errBufLen, "lookup exploded")
    return LdDiscoError
  fakeState.lastKey = $key
  fakeState.lastLimit = limit
  fillPeers(outPeers)
  LdDiscoOk

proc fakeRandomLookup(
    ctx: pointer, outPeers: ptr LdDiscoPeerList, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  fillPeers(outPeers)
  LdDiscoOk

proc fakeFreePeerList(
    ctx: pointer, list: ptr LdDiscoPeerList
) {.cdecl, gcsafe, raises: [].} =
  inc fakeState.freed

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
  fakeState.lastKey = $key
  fakeState.lastData = @[]
  for i in 0 ..< dataLen.int:
    fakeState.lastData.add(data[i])
  fakeState.lastRecord = @[]
  for i in 0 ..< recordLen.int:
    fakeState.lastRecord.add(record[i])
  LdDiscoOk

proc fakeKeyOp(
    ctx: pointer, key: cstring, errBuf: cstring, errBufLen: csize_t
): cint {.cdecl, gcsafe, raises: [].} =
  fakeState.lastKey = $key
  LdDiscoOk

proc fakeAddBootstrap(
    ctx: pointer,
    entries: ptr UncheckedArray[cstring],
    entriesLen: csize_t,
    errBuf: cstring,
    errBufLen: csize_t,
): cint {.cdecl, gcsafe, raises: [].} =
  fakeState.bootstrapCount = entriesLen.int
  LdDiscoOk

proc fakePlugin(): ServiceDiscoveryPlugin =
  ServiceDiscoveryPlugin(
    abiVersion: LdDiscoAbiVersion,
    pluginCtx: nil,
    start: fakeStart,
    stop: fakeStop,
    lookup: fakeLookup,
    randomLookup: fakeRandomLookup,
    freePeerList: fakeFreePeerList,
    startAdvertising: fakeStartAdvertising,
    stopAdvertising: fakeKeyOp,
    registerInterest: fakeKeyOp,
    unregisterInterest: fakeKeyOp,
    addBootstrapEntries: fakeAddBootstrap,
  )

suite "ExternalServiceDiscovery":
  setup:
    fakeState = FakePluginState()

  asyncTest "verbs call through to the installed plugin":
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()

    let iface: IPeerDiscovery = backend
    check (await iface.startDiscovery()).isOk()
    check fakeState.started

    let info = (await iface.backendInfo()).valueOr:
      raiseAssert error
    check:
      info.id == "service-ext"
      info.running

    let peers = (await iface.lookupServicePeers("svc:/mix/1.0.0", 5)).valueOr:
      raiseAssert error
    check:
      peers.len == 1
      peers[0].peerId == "peer-from-plugin"
      peers[0].addrs == @["/ip4/1.2.3.4/tcp/60000"]
      peers[0].seqNo == 7
      fakeState.lastKey == "svc:/mix/1.0.0"
      fakeState.lastLimit == 5
      fakeState.freed == 1 # the plugin-owned list was handed back

    check (await iface.lookupRandom()).isOk()
    check fakeState.freed == 2

    check (await iface.startAdvertising("svc:x", @[1'u8, 2], @[9'u8])).isOk()
    check:
      fakeState.lastData == @[1'u8, 2]
      fakeState.lastRecord == @[9'u8]

    check (await iface.registerInterest("svc:y")).isOk()
    check fakeState.lastKey == "svc:y"

    check (await iface.addBootstrapEntries(@["/ip4/1.2.3.4/tcp/1/p2p/16Uxx"])).isOk()
    check fakeState.bootstrapCount == 1

    check (await iface.stopDiscovery()).isOk()
    check not fakeState.started

  asyncTest "verbs fail cleanly with no plugin installed":
    let backend = ExternalServiceDiscovery.create()
    discard await ClearServiceDiscoveryPlugin.request(globalBrokerContext())

    let res = await backend.startDiscovery()
    check:
      res.isErr()
      "no service discovery plugin" in res.error

  asyncTest "plugin error text is surfaced":
    let backend = ExternalServiceDiscovery.create()
    check (await SetServiceDiscoveryPlugin.request(globalBrokerContext(), fakePlugin())).isOk()

    fakeState.failNext = true
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

  asyncTest "clearing the plugin disables the verbs again":
    let backend = ExternalServiceDiscovery.create()
    let ctx = globalBrokerContext()
    check (await SetServiceDiscoveryPlugin.request(ctx, fakePlugin())).isOk()
    check (await backend.startDiscovery()).isOk()

    check (await ClearServiceDiscoveryPlugin.request(ctx)).isOk()
    let res = await backend.lookupRandom()
    check:
      res.isErr()
      "no service discovery plugin" in res.error
