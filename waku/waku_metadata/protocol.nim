{.push raises: [].}

import
  std/[options, sequtils],
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/enr/enr
import ../common/nimchronos, ../waku_core, ./rpc, ../common/callbacks

from ../waku_core/codecs import WakuMetadataCodec
export WakuMetadataCodec

logScope:
  topics = "waku metadata"

const RpcResponseMaxBytes* = 1024

type WakuMetadata* = ref object of LPProtocol
  clusterId*: uint32
  getShards: GetShards

proc respond(
    m: WakuMetadata, conn: Connection
): Future[Result[void, string]] {.async, gcsafe.} =
  let response = WakuMetadataResponse(
    clusterId: some(m.clusterId.uint32), shards: m.getShards().mapIt(it.uint32)
  )

  let res = catch:
    await conn.writeLP(response.encode().buffer)
  res.isOkOr:
    return err(error.msg)

  return ok()

proc request*(
    m: WakuMetadata, conn: Connection
): Future[Result[WakuMetadataResponse, string]] {.async, gcsafe.} =
  let request = WakuMetadataRequest(
    clusterId: some(m.clusterId), shards: m.getShards().mapIt(it.uint32)
  )

  let writeRes = catch:
    await conn.writeLP(request.encode().buffer)
  let readRes = catch:
    await conn.readLp(RpcResponseMaxBytes)

  # close no matter what
  let closeRes = catch:
    await conn.closeWithEof()
  closeRes.isOkOr:
    return err("close failed: " & error.msg)

  writeRes.isOkOr:
    return err("write failed: " & error.msg)

  let buffer = readRes.valueOr:
    return err("read failed: " & error.msg)

  let response = WakuMetadataResponse.decode(buffer).valueOr:
    return err("decode failed: " & $error)

  return ok(response)

proc initProtocolHandler(m: WakuMetadata) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    defer:
      # close, no data is expected
      await conn.closeWithEof()

    let res = catch:
      await conn.readLp(RpcResponseMaxBytes)
    let buffer = res.valueOr:
      error "Connection reading error", error = error.msg
      return

    let response = WakuMetadataResponse.decode(buffer).valueOr:
      error "Response decoding error", error = error
      return

    info "Received WakuMetadata request",
      remoteClusterId = response.clusterId,
      remoteShards = response.shards,
      localClusterId = m.clusterId,
      localShards = m.getShards(),
      peer = conn.peerId

    try:
      discard await m.respond(conn)
    except CatchableError:
      error "Failed to respond to WakuMetadata request",
        error = getCurrentExceptionMsg()

  m.handler = handler
  m.codec = WakuMetadataCodec

proc new*(T: type WakuMetadata, clusterId: uint32, getShards: GetShards): T =
  let wm = WakuMetadata(clusterId: clusterId, getShards: getShards)

  wm.initProtocolHandler()

  info "Created WakuMetadata protocol",
    clusterId = wm.clusterId, shards = wm.getShards()

  return wm

proc start*(wm: WakuMetadata) =
  wm.started = true

proc stop*(wm: WakuMetadata) =
  wm.started = false
