## Abstracts the libp2p operations the Edge protocol clients need, so a node can
## run them over its own switch or over a libp2p node another process owns.

{.push raises: [].}

import results, chronicles, chronos, libp2p/[multiaddress, peerid, switch]
import libp2p/protocols/protocol

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
): NetRequest =
  NetRequest(
    peerId: peerId,
    addrs: addrs,
    proto: proto,
    payload: payload,
    maxSize: maxSize,
    timeout: timeout,
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
  error "backend serves no streams", proto = proto
  return Opt.none(Connection)

method connect*(
    backend: NetBackend, peerId: PeerId, addrs: seq[MultiAddress], timeout: Duration
): Future[Result[void, string]] {.base, async: (raises: []).} =
  return err("backend opens no connections")

method mountInbound*(
    backend: NetBackend, proto: string, handler: LPProtoHandler
) {.base, gcsafe.} =
  ## A switch dispatches an inbound stream to the mounted protocol on its own.
  discard

method start*(backend: NetBackend) {.base, async: (raises: []).} =
  discard

method stop*(backend: NetBackend) {.base, async: (raises: []).} =
  discard

method request*(
    backend: NetBackend, req: NetRequest
): Future[Result[seq[byte], NetError]] {.base, async: (raises: []).} =
  ## One length-prefixed frame out, one back, over a stream of its own.
  let connection = (await backend.dial(req.peerId, req.addrs, req.proto, req.timeout)).valueOr:
    return err(dialError($req.peerId & " on " & req.proto))

  defer:
    await connection.closeWithEof()

  let writeRes = catch:
    await connection.writeLP(req.payload)
  if writeRes.isErr():
    return err(NetError(kind: NetErrorKind.Write, cause: writeRes.error.msg))

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
  let connectFut = backend.switch.connect(peerId, addrs)

  let res = catch:
    if await connectFut.withTimeout(timeout):
      connectFut.read()
      return ok()

  if not connectFut.finished():
    await noCancel cancelAndWait(connectFut)

  if res.isErr():
    return err(res.error.msg)

  return err("timed out")

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

  if not dialFut.finished():
    await noCancel cancelAndWait(dialFut)

  let reasonFailed = if res.isOk(): "timed out" else: res.error.msg

  trace "Dialing peer failed", peerId = peerId, reason = reasonFailed, proto = proto

  return Opt.none(Connection)

{.pop.}
