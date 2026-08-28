{.used.}

import std/[tables, sequtils, strutils]
import chronos, results, testutils/unittests
import logos_delivery/waku/discovery/external_service_discovery

## A fake host: records the commands it receives and answers them on demand,
## standing in for the logos-delivery-module glue.
type FakeHost = ref object
  received: seq[DiscoveryBackendCommand]
  autoAnswer: bool
  backend: ExternalServiceDiscovery

proc newFakeHost(autoAnswer = true): FakeHost =
  FakeHost(autoAnswer: autoAnswer)

proc answer(
    host: FakeHost, cmd: DiscoveryBackendCommand, peers: seq[DiscoveredPeer] = @[]
) =
  host.backend.onHostReply(
    DiscoveryBackendReply(requestId: cmd.requestId, success: true, peers: peers)
  )

proc install(host: FakeHost, peers: seq[DiscoveredPeer] = @[]) =
  let sink = proc(cmd: DiscoveryBackendCommand) {.gcsafe, raises: [].} =
    host.received.add(cmd)
    if host.autoAnswer:
      host.answer(cmd, peers)
  host.backend = ExternalServiceDiscovery.create(sink)

proc lastOp(host: FakeHost): DiscoveryBackendOp =
  host.received[^1].op

suite "ExternalServiceDiscovery":
  asyncTest "verbs round-trip through the host sink":
    let host = newFakeHost()
    host.install(@[DiscoveredPeer(peerId: "p1")])
    let iface: IPeerDiscovery = host.backend

    check (await iface.startDiscovery()).isOk()
    check host.lastOp == DiscoStart

    let info = (await iface.backendInfo()).valueOr:
      raiseAssert error
    check:
      info.id == "service-ext"
      info.running

    let peers = (await iface.lookupServicePeers("svc:/mix/1.0.0", 5)).valueOr:
      raiseAssert error
    check:
      peers.len == 1
      peers[0].peerId == "p1"
      host.lastOp == DiscoLookup
      host.received[^1].key == "svc:/mix/1.0.0"
      host.received[^1].limit == 5

    check (await iface.lookupRandom()).isOk()
    check host.lastOp == DiscoRandomLookup

    check (await iface.startAdvertising("svc:/mix/1.0.0", @[1'u8], @[9'u8])).isOk()
    check:
      host.lastOp == DiscoStartAdvertising
      host.received[^1].data == @[1'u8]
      host.received[^1].record == @[9'u8] # proxy-XPR passthrough

    check (await iface.stopAdvertising("svc:/mix/1.0.0")).isOk()
    check host.lastOp == DiscoStopAdvertising

    check (await iface.registerInterest("svc:x")).isOk()
    check host.lastOp == DiscoRegisterInterest
    check (await iface.unregisterInterest("svc:x")).isOk()
    check host.lastOp == DiscoUnregisterInterest

    check (await iface.addBootstrapEntries(@["/ip4/1.2.3.4/tcp/1/p2p/16Uxx"])).isOk()
    check:
      host.lastOp == ConnectPeer
      host.received[^1].entries.len == 1

    check (await iface.stopDiscovery()).isOk()
    check host.lastOp == DiscoStop
    check not (await iface.backendInfo()).get().running

  asyncTest "request ids are unique and correlate replies":
    let host = newFakeHost()
    host.install()
    discard await host.backend.startDiscovery()

    discard await host.backend.lookupRandom()
    discard await host.backend.lookupRandom()

    let ids = host.received.mapIt(it.requestId)
    check:
      ids.len == 3
      ids.deduplicate().len == 3

  asyncTest "empty bootstrap list does not reach the host":
    let host = newFakeHost()
    host.install()
    check (await host.backend.addBootstrapEntries(@[])).isOk()
    check host.received.len == 0

  asyncTest "host failure is surfaced as an error":
    let host = newFakeHost(autoAnswer = false)
    host.install()
    let sinkFut = host.backend.startDiscovery()

    await sleepAsync(chronos.milliseconds(10))
    host.backend.onHostReply(
      DiscoveryBackendReply(
        requestId: host.received[^1].requestId, success: false, error: "boom"
      )
    )

    let res = await sinkFut
    check:
      res.isErr()
      "boom" in res.error

  asyncTest "unanswered request times out":
    let host = newFakeHost(autoAnswer = false)
    let sink = proc(cmd: DiscoveryBackendCommand) {.gcsafe, raises: [].} =
      host.received.add(cmd)
    host.backend = ExternalServiceDiscovery.create(sink, chronos.milliseconds(30))

    let res = await host.backend.startDiscovery()
    check:
      res.isErr()
      "did not answer" in res.error

  asyncTest "pushed peers reach the interface event":
    let host = newFakeHost()
    host.install()

    var received: seq[DiscoveredPeer]
    let onPeers = proc(
        ev: PeersDiscovered
    ): Future[void] {.async: (raises: []), gcsafe.} =
      received = ev.peers
    discard host.backend.listen(PeersDiscovered, onPeers)

    host.backend.onHostPush("svc:/mix/1.0.0", @[DiscoveredPeer(peerId: "pushed")])
    await sleepAsync(chronos.milliseconds(10))

    check:
      received.len == 1
      received[0].peerId == "pushed"

  asyncTest "a late reply for a timed-out request is dropped":
    let host = newFakeHost(autoAnswer = false)
    let sink = proc(cmd: DiscoveryBackendCommand) {.gcsafe, raises: [].} =
      host.received.add(cmd)
    host.backend = ExternalServiceDiscovery.create(sink, chronos.milliseconds(20))

    check (await host.backend.startDiscovery()).isErr()

    # The host answers anyway; must not raise or resurrect the request.
    host.backend.onHostReply(
      DiscoveryBackendReply(requestId: host.received[^1].requestId, success: true)
    )
    await sleepAsync(chronos.milliseconds(10))
    check not (await host.backend.backendInfo()).get().running
