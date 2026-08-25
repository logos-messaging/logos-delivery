## Abstracts the libp2p operations the Edge protocol clients need, so a node can
## run them over its own switch or over a libp2p node another process owns.

{.push raises: [].}

import results, chronicles, chronos, libp2p/[multiaddress, peerid, switch]

logScope:
  topics = "waku net backend"

const
  DefaultNetDialTimeout* = chronos.seconds(10)
  DefaultNetMaxResponseSize* = 1024 * 1024

type
  NetErrorKind* {.pure.} = enum
    Dial
    Write
    Read

  NetError* = object
    kind*: NetErrorKind
    cause*: string

  NetRequest* = object
    peerId*: PeerId
    addrs*: seq[MultiAddress]
    proto*: string
    payload*: seq[byte]
    maxSize*: int
    timeout*: Duration
    expectResponse*: bool

  NetBackend* = ref object of RootObj

  SwitchNetBackend* = ref object of NetBackend
    switch: Switch

func init*(
    T: type NetRequest,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    payload: seq[byte],
    maxSize = DefaultNetMaxResponseSize,
    timeout = DefaultNetDialTimeout,
    expectResponse = true,
): NetRequest =
  NetRequest(
    peerId: peerId,
    addrs: addrs,
    proto: proto,
    payload: payload,
    maxSize: maxSize,
    timeout: timeout,
    expectResponse: expectResponse,
  )

func dialError*(cause: string): NetError =
  NetError(kind: NetErrorKind.Dial, cause: cause)

func `$`*(err: NetError): string =
  $err.kind & " failed: " & err.cause

method dial*(
    backend: NetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    timeout: Duration,
): Future[Opt[Connection]] {.base, async: (raises: []).} =
  raiseAssert "[NetBackend.dial] abstract method not implemented"

method connect*(
    backend: NetBackend, peerId: PeerId, addrs: seq[MultiAddress], timeout: Duration
): Future[Result[void, string]] {.base, async: (raises: []).} =
  raiseAssert "[NetBackend.connect] abstract method not implemented"

method request*(
    backend: NetBackend, req: NetRequest
): Future[Result[seq[byte], NetError]] {.base, async: (raises: []).} =
  ## One length-prefixed frame out, one back, over a stream of its own.
  let connection = (await backend.dial(req.peerId, req.addrs, req.proto, req.timeout)).valueOr:
    return err(dialError($req.peerId))

  defer:
    await connection.closeWithEof()

  let writeRes = catch:
    await connection.writeLP(req.payload)
  if writeRes.isErr():
    return err(NetError(kind: NetErrorKind.Write, cause: writeRes.error.msg))

  if not req.expectResponse:
    return ok(newSeq[byte]())

  let readRes = catch:
    await connection.readLp(req.maxSize)

  let buffer = readRes.valueOr:
    return err(NetError(kind: NetErrorKind.Read, cause: error.msg))

  return ok(buffer)

func new*(T: type SwitchNetBackend, switch: Switch): T =
  SwitchNetBackend(switch: switch)

method connect*(
    backend: SwitchNetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    timeout: Duration,
): Future[Result[void, string]] {.async: (raises: []).} =
  let res = catch:
    await backend.switch.connect(peerId, addrs)

  if res.isErr():
    return err(res.error.msg)

  return ok()

method dial*(
    backend: SwitchNetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    timeout: Duration,
): Future[Opt[Connection]] {.async: (raises: []).} =
  let dialFut = backend.switch.dial(peerId, addrs, proto)

  let res = catch:
    if await dialFut.withTimeout(timeout):
      return Opt.some(dialFut.read())
    else:
      await cancelAndWait(dialFut)

  let reasonFailed = if res.isOk(): "timed out" else: res.error.msg

  trace "Dialing peer failed", peerId = peerId, reason = reasonFailed, proto = proto

  return Opt.none(Connection)

{.pop.}
