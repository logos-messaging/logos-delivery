{.used.}

## A net transport that answers the op vocabulary from its own switch.

import std/[json, tables]
import results, chronos, libp2p/[multiaddress, peerid, switch]
import libp2p/protocols/protocol
import logos_delivery/waku/common/base64, logos_delivery/waku/net/net_transport

type SwitchTransport* = ref object of NetTransport
  switch: Switch
  streams: Table[uint64, Connection]
  inbound: Table[string, seq[uint64]]
  nextStreamId: uint64

func new*(T: type SwitchTransport, switch: Switch): T =
  SwitchTransport(switch: switch)

proc track(transport: SwitchTransport, conn: Connection): uint64 =
  inc(transport.nextStreamId)
  transport.streams[transport.nextStreamId] = conn

  return transport.nextStreamId

proc streamOf(transport: SwitchTransport, args: JsonNode): Result[Connection, string] =
  let streamId = uint64(args{"streamId"}.getBiggestInt())
  transport.streams.withValue(streamId, conn):
    return ok(conn[])

  return err("unknown stream")

proc addrsOf(args: JsonNode): seq[MultiAddress] =
  var addrs: seq[MultiAddress]
  for entry in args{"multiaddrs"}.getElems():
    let address = MultiAddress.init(entry.getStr())
    if address.isOk():
      addrs.add(address.get())

  return addrs

proc dialStream(
    transport: SwitchTransport, args: JsonNode
): Future[Result[uint64, string]] {.async: (raises: []).} =
  let peerId = PeerId.init(args{"peerId"}.getStr()).valueOr:
    return err("bad peer id")

  let addrs = addrsOf(args)

  let conn =
    try:
      if addrs.len > 0:
        await transport.switch.dial(peerId, addrs, args{"proto"}.getStr())
      else:
        await transport.switch.dial(peerId, args{"proto"}.getStr())
    except CatchableError as e:
      return err("dial failed: " & e.msg)

  return ok(transport.track(conn))

proc connectPeer(
    transport: SwitchTransport, args: JsonNode
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  let peerId = PeerId.init(args{"peerId"}.getStr()).valueOr:
    return err("bad peer id")

  try:
    await transport.switch.connect(peerId, addrsOf(args))
  except CatchableError as e:
    return err("connect failed: " & e.msg)

  return ok(newJObject())

proc protocolRequest(
    transport: SwitchTransport, args: JsonNode
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  let streamId = ?await transport.dialStream(args)
  let conn = transport.streams.getOrDefault(streamId)

  defer:
    transport.streams.del(streamId)
    await conn.closeWithEof()

  let payload = base64.decode(Base64String(args{"requestB64"}.getStr())).valueOr:
    return err("bad requestB64")

  try:
    await conn.writeLP(payload)
  except CatchableError as e:
    return err("write failed: " & e.msg)

  if not args{"expectResponse"}.getBool(true):
    return ok(newJObject())

  let response =
    try:
      await conn.readLp(int(args{"maxSize"}.getBiggestInt()))
    except CatchableError as e:
      return err("read failed: " & e.msg)

  return ok(%*{"responseB64": $base64.encode(response)})

proc mountProtocol(
    transport: SwitchTransport, proto: string
): Result[JsonNode, string] =
  proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    let streamId = transport.track(conn)
    transport.inbound.mgetOrPut(proto, @[]).add(streamId)
    await conn.join()

  let lp = LPProtocol.new(@[proto], handle)

  try:
    transport.switch.mount(lp)
  except LPError as e:
    return err("mount failed: " & e.msg)

  return ok(newJObject())

proc acceptStream(
    transport: SwitchTransport, args: JsonNode
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  let proto = args{"proto"}.getStr()
  let deadline = Moment.now() + chronos.milliseconds(args{"timeoutMs"}.getBiggestInt())

  while Moment.now() < deadline:
    var queue = transport.inbound.getOrDefault(proto)
    if queue.len > 0:
      let streamId = queue[0]
      queue.delete(0)
      transport.inbound[proto] = queue
      let conn = transport.streams.getOrDefault(streamId)

      return ok(%*{"streamId": streamId, "proto": proto, "peerId": $conn.peerId})

    try:
      await sleepAsync(chronos.milliseconds(10))
    except CancelledError:
      return err("cancelled")

  return err("timeout waiting for inbound stream")

method submit*(
    transport: SwitchTransport, op: string, args: JsonNode, timeout: Duration
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  case op
  of "getNodeInfo":
    return ok(%($transport.switch.peerInfo.peerId))
  of "connectPeer":
    return await transport.connectPeer(args)
  of "dial":
    return ok(%(?await transport.dialStream(args)))
  of "protocolRequest":
    return await transport.protocolRequest(args)
  of "mountProtocol":
    return transport.mountProtocol(args{"proto"}.getStr())
  of "protocolAcceptStream":
    return await transport.acceptStream(args)
  of "streamReadLp":
    let conn = ?transport.streamOf(args)
    let data =
      try:
        await conn.readLp(int(args{"maxSize"}.getBiggestInt()))
      except CatchableError as e:
        return err("read failed: " & e.msg)
    return ok(%*{"dataB64": $base64.encode(data)})
  of "streamWriteLp":
    let conn = ?transport.streamOf(args)
    let payload = base64.decode(Base64String(args{"dataB64"}.getStr())).valueOr:
      return err("bad dataB64")
    try:
      await conn.writeLP(payload)
    except CatchableError as e:
      return err("write failed: " & e.msg)
    return ok(newJObject())
  of "streamClose":
    let conn = ?transport.streamOf(args)
    await conn.close()
    return ok(newJObject())
  of "streamRelease":
    transport.streams.del(uint64(args{"streamId"}.getBiggestInt()))
    return ok(newJObject())
  else:
    return err("unknown libp2p op: " & op)
