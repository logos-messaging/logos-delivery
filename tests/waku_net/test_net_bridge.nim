{.used.}

import std/[json, os, strutils]
import results, testutils/unittests, chronos

import logos_delivery/waku/net/[net_bridge, net_transport]

var worker {.threadvar.}: Thread[uint64]

proc submitNever(
    requestId: uint64, opJson: cstring, opLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

proc submitInline(
    requestId: uint64, opJson: cstring, opLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let op = $cast[cstring](opJson)
  let answer = "{\"echo\":" & escapeJson(op) & "}"
  discard netBackendRespond(requestId, true, cast[pointer](cstring(answer)), answer.len)

proc respondFromThread(requestId: uint64) {.thread.} =
  sleep(20)
  let answer = "{\"late\":true}"
  discard netBackendRespond(requestId, true, cast[pointer](cstring(answer)), answer.len)

proc submitThreaded(
    requestId: uint64, opJson: cstring, opLen: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  try:
    createThread(worker, respondFromThread, requestId)
  except ResourceExhaustedError:
    discard

const
  LongestName = "b".repeat(63)
  TooLongName = "b".repeat(64)

suite "Net backend ABI":
  test "a table of another ABI version is refused":
    var table = NetBackendTable(version: NetBackendAbiVersion + 1, submit: submitNever)

    check:
      registerNetBackend("wrong-version", addr table, nil) != 0
      registerNetBackend("no-table", nil, nil) != 0

  test "an unknown backend has no transport":
    check getNetTransport("nobody").isErr()

  asyncTest "a backend answers on the calling thread":
    var table = NetBackendTable(version: NetBackendAbiVersion, submit: submitInline)
    check registerNetBackend("inline", addr table, nil) == 0

    let transport = getNetTransport("inline").valueOr:
      raiseAssert "no transport: " & error

    let answer =
      await transport.submit("getNodeInfo", %*{"field": "PeerId"}, chronos.seconds(5))

    check:
      answer.isOk()
      answer.get(){"echo"}.getStr().contains("\"op\":\"getNodeInfo\"")

  asyncTest "a backend answers from a foreign thread":
    var table = NetBackendTable(version: NetBackendAbiVersion, submit: submitThreaded)
    check registerNetBackend("threaded", addr table, nil) == 0

    let transport = getNetTransport("threaded").valueOr:
      raiseAssert "no transport: " & error

    let answer =
      await transport.submit("pingPeer", %*{"peerId": "x"}, chronos.seconds(5))

    joinThread(worker)

    check:
      answer.isOk()
      answer.get(){"late"}.getBool()

  asyncTest "an op with no answer times out":
    var table = NetBackendTable(version: NetBackendAbiVersion, submit: submitNever)
    check registerNetBackend("silent", addr table, nil) == 0

    let transport = getNetTransport("silent").valueOr:
      raiseAssert "no transport: " & error

    let answer =
      await transport.submit("dial", %*{"peerId": "x"}, chronos.milliseconds(200))

    check:
      answer.isErr()
      answer.error.contains("timed out")

  test "a name is kept whole up to the length limit":
    var table = NetBackendTable(version: NetBackendAbiVersion, submit: submitInline)

    check:
      registerNetBackend(cstring(LongestName), addr table, nil) == 0
      registerNetBackend(cstring(TooLongName), addr table, nil) != 0
      getNetTransport(LongestName).isOk()
      getNetTransport(TooLongName).isErr()

  asyncTest "an answer nobody waits for does not wedge the drain":
    var table = NetBackendTable(version: NetBackendAbiVersion, submit: submitInline)
    check registerNetBackend("inline", addr table, nil) == 0

    let transport = getNetTransport("inline").valueOr:
      raiseAssert "no transport: " & error

    let stray = "{}"
    check netBackendRespond(
      high(uint64), true, cast[pointer](cstring(stray)), stray.len
    ) == 0

    let answer =
      await transport.submit("getNodeInfo", %*{"field": "PeerId"}, chronos.seconds(5))

    check answer.isOk()
