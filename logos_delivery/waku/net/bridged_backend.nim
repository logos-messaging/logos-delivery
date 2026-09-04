## Runs the Edge protocols over a libp2p node another module owns. Every op
## crosses the process boundary as JSON, so a request/response exchange goes in
## one crossing and a stream costs one crossing per frame.

{.push raises: [].}

import std/[json, sequtils, strutils]
import results, chronicles, chronos
import libp2p/[multiaddress, peerid]
import libp2p/protocols/protocol
import libp2p/stream/connection
import ../common/base64, ./net_backend, ./net_transport

logScope:
  topics = "waku bridged backend"

const
  AcceptPollTimeout = chronos.seconds(10)
  PollRetryDelay = chronos.milliseconds(250)
  OpSlack = chronos.seconds(5)
  FramesOnly = "a bridged stream carries whole frames only"

type
  InboundProtocol = object
    proto: string
    handler: LPProtoHandler

  BridgedNetBackend* = ref object of NetBackend
    transport: NetTransport
    inbound: seq[InboundProtocol]
    acceptFuts: seq[Future[void]]
    running: bool

  BridgedConnection* = ref object of Connection
    transport: NetTransport
    streamId*: uint64

func new*(T: type BridgedNetBackend, transport: NetTransport): T =
  BridgedNetBackend(transport: transport)

proc streamIdOf(node: JsonNode): Opt[uint64] =
  if node.isNil():
    return Opt.none(uint64)

  case node.kind
  of JInt:
    Opt.some(uint64(node.getBiggestInt()))
  of JString:
    try:
      Opt.some(uint64(parseBiggestUInt(node.getStr())))
    except ValueError:
      Opt.none(uint64)
  else:
    Opt.none(uint64)

proc fieldStr(node: JsonNode, key: string): string =
  if node.isNil() or node.kind != JObject:
    return ""

  let field = node.getOrDefault(key)
  if field.isNil() or field.kind != JString:
    return ""

  return field.getStr()

proc bytesOf(node: JsonNode, key: string): Result[seq[byte], string] =
  let encoded = node.fieldStr(key)
  if encoded.len == 0:
    return ok(newSeq[byte]())

  return base64.decode(Base64String(encoded))

proc call(
    backend: BridgedNetBackend, op: string, args: JsonNode, timeout: Duration
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  return await backend.transport.submit(op, args, timeout + OpSlack)

proc newBridgedConnection(
    transport: NetTransport,
    streamId: uint64,
    peerId: PeerId,
    proto: string,
    dir: Direction,
): BridgedConnection =
  let conn = BridgedConnection(transport: transport, streamId: streamId, peerId: peerId)
  conn.protocol = proto
  conn.dir = dir
  conn.transportDir = dir
  conn.objName = "BridgedConnection"
  conn.initStream()

  return conn

proc isPollTimeout(error: string): bool =
  error.contains("timeout") or error.contains("timed out")

proc streamOp(
    conn: BridgedConnection, op: string, args: JsonNode, timeout: Duration
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  return await conn.transport.submit(op, args, timeout + OpSlack)

method readLp*(
    conn: BridgedConnection, maxSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  let args = %*{
    "streamId": conn.streamId,
    "maxSize": maxSize,
    "timeoutMs": DefaultConnectionTimeout.milliseconds,
  }

  while true:
    let answer = (await conn.streamOp("streamReadLp", args, DefaultConnectionTimeout)).valueOr:
      if not conn.isClosed and error.isPollTimeout():
        continue
      conn.isEof = true
      raise newException(LPStreamError, error)

    let data = answer.bytesOf("dataB64").valueOr:
      conn.isEof = true
      raise newException(LPStreamError, error)

    if data.len > maxSize:
      conn.isEof = true
      raise (ref MaxSizeError)(msg: "Message exceeds maximum length")

    conn.activity = true

    return data

proc writeFrame(
    conn: BridgedConnection, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  let args = %*{"streamId": conn.streamId, "dataB64": $base64.encode(msg)}

  discard (await conn.streamOp("streamWriteLp", args, DefaultConnectionTimeout)).valueOr:
    raise newException(LPStreamError, error)

  conn.activity = true

method writeLp*(
    conn: BridgedConnection, msg: openArray[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  conn.writeFrame(@msg)

method writeLp*(
    conn: BridgedConnection, msg: string
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  conn.writeFrame(toSeq(msg.toOpenArrayByte(0, msg.high)))

method write*(
    conn: BridgedConnection, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  let fut = Future[void].Raising([CancelledError, LPStreamError]).init(
      "bridgedconnection.write"
    )
  fut.fail(newException(LPStreamError, FramesOnly))

  return fut

method readOnce*(
    conn: BridgedConnection, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  let fut = Future[int].Raising([CancelledError, LPStreamError]).init(
      "bridgedconnection.readOnce"
    )
  fut.fail(newException(LPStreamError, FramesOnly))

  return fut

method closeImpl*(conn: BridgedConnection): Future[void] {.async: (raises: []).} =
  let args = %*{"streamId": conn.streamId}
  discard await conn.streamOp("streamClose", args, DefaultConnectionTimeout)
  discard await conn.streamOp("streamRelease", args, DefaultConnectionTimeout)

  conn.isEof = true

  await procCall Connection(conn).closeImpl()

method usesLocalSwitch*(backend: BridgedNetBackend): bool {.gcsafe.} =
  false

method dial*(
    backend: BridgedNetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    timeout: Duration,
): Future[Opt[Connection]] {.async: (raises: []).} =
  if addrs.len > 0:
    let connectArgs = %*{
      "peerId": $peerId,
      "multiaddrs": addrs.mapIt($it),
      "timeoutMs": timeout.milliseconds,
    }
    let connected = await backend.call("connectPeer", connectArgs, timeout)
    if connected.isErr():
      trace "Bridged connect failed",
        peerId = peerId, proto = proto, reason = connected.error
      return Opt.none(Connection)

  let answer = (
    await backend.call("dial", %*{"peerId": $peerId, "proto": proto}, timeout)
  ).valueOr:
    trace "Bridged dial failed", peerId = peerId, proto = proto, reason = error
    return Opt.none(Connection)

  let streamId = streamIdOf(answer).valueOr:
    trace "Bridged dial returned no stream", peerId = peerId, proto = proto
    return Opt.none(Connection)

  return Opt.some(
    Connection(
      newBridgedConnection(backend.transport, streamId, peerId, proto, Direction.Out)
    )
  )

proc requestErrorKind(cause: string): NetErrorKind =
  ## One crossing covers connect, dial, write and read, so only the error prefix tells the stages apart.
  if cause.contains("dial failed") or cause.contains("connect failed"):
    NetErrorKind.Dial
  elif cause.contains("write failed"):
    NetErrorKind.Write
  else:
    NetErrorKind.Read

method request*(
    backend: BridgedNetBackend, req: NetRequest
): Future[Result[seq[byte], NetError]] {.async: (raises: []).} =
  let args = %*{
    "peerId": $req.peerId,
    "proto": req.proto,
    "multiaddrs": req.addrs.mapIt($it),
    "requestB64": $base64.encode(req.payload),
    "timeoutMs": req.timeout.milliseconds,
    "maxSize": req.maxSize,
    "expectResponse": req.expectResponse,
  }

  let answer = (await backend.call("protocolRequest", args, req.timeout)).valueOr:
    return err(NetError(kind: requestErrorKind(error), cause: error))

  if not req.expectResponse:
    return ok(newSeq[byte]())

  let data = answer.bytesOf("responseB64").valueOr:
    return err(NetError(kind: NetErrorKind.Read, cause: error))

  if data.len > req.maxSize:
    return
      err(NetError(kind: NetErrorKind.Read, cause: "response exceeds maximum length"))

  return ok(data)

proc serveInbound(
    handler: LPProtoHandler, conn: Connection, proto: string
) {.async: (raises: []).} =
  try:
    await handler(conn, proto)
  except CancelledError:
    discard

  await conn.close()

proc acceptLoop(
    backend: BridgedNetBackend, entry: InboundProtocol
) {.async: (raises: []).} =
  let args = %*{"proto": entry.proto, "timeoutMs": AcceptPollTimeout.milliseconds}

  while backend.running:
    let answer = (await backend.call("protocolAcceptStream", args, AcceptPollTimeout)).valueOr:
      ## A poll that saw no stream is the ordinary outcome, so it goes straight
      ## back in. Anything else backs off and says so.
      if error.isPollTimeout():
        continue

      debug "Inbound accept poll failed", proto = entry.proto, reason = error

      try:
        await sleepAsync(PollRetryDelay)
      except CancelledError:
        return

      continue

    let streamId = streamIdOf(answer.getOrDefault("streamId")).valueOr:
      continue

    let peerId = PeerId.init(answer.fieldStr("peerId")).valueOr:
      trace "Inbound stream has no usable peer id", proto = entry.proto
      continue

    let conn = newBridgedConnection(
      backend.transport, streamId, peerId, entry.proto, Direction.In
    )

    asyncSpawn serveInbound(entry.handler, Connection(conn), entry.proto)

proc mountOne(
    backend: BridgedNetBackend, entry: InboundProtocol
) {.async: (raises: []).} =
  let mounted = await backend.call("mountProtocol", %*{"proto": entry.proto}, OpSlack)
  if mounted.isErr():
    error "failed to mount an inbound protocol on the net backend",
      proto = entry.proto, error = mounted.error
    return

  ## A stop can land while the mount op is still crossing, and a loop added
  ## after that one would never be cancelled by anybody.
  if not backend.running:
    return

  backend.acceptFuts.add(backend.acceptLoop(entry))

proc mountInboundProtocols(backend: BridgedNetBackend) {.async: (raises: []).} =
  for entry in backend.inbound:
    await backend.mountOne(entry)

method mountInbound*(
    backend: BridgedNetBackend, proto: string, handler: LPProtoHandler
) {.gcsafe.} =
  let entry = InboundProtocol(proto: proto, handler: handler)
  backend.inbound.add(entry)

  ## Mounted after the node started, so it needs its own loop now: nothing is
  ## going to walk `inbound` a second time.
  if backend.running:
    asyncSpawn backend.mountOne(entry)

method start*(backend: BridgedNetBackend) {.async: (raises: []).} =
  if backend.running:
    return

  backend.running = true

  ## Spawned rather than awaited: a backend that never answers `mountProtocol`
  ## would otherwise hold up the whole node start.
  asyncSpawn backend.mountInboundProtocols()

method stop*(backend: BridgedNetBackend) {.async: (raises: []).} =
  backend.running = false
  let futs = backend.acceptFuts
  backend.acceptFuts = @[]

  await allFutures(futs.mapIt(cancelAndWait(it)))

{.pop.}
