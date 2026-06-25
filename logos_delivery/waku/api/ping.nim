## Waku layer API — ping operation.
{.push raises: [].}

import results, chronos, chronicles
import libp2p/protocols/ping
import libp2p/switch

import logos_delivery/waku/waku
import logos_delivery/waku/[waku_core, node/waku_node, node/waku_node/ping]

proc pingPeer*(
    self: Waku, peerAddr: string, timeoutMs: int
): Future[Result[int64, string]] {.async.} =
  ## Pings the peer; `timeoutMs <= 0` means no timeout. Returns RTT in nanos.
  try:
    let peerInfo = parsePeerInfo(peerAddr).valueOr:
      return err("pingPeer failed to parse peer addr: " & $error)

    proc doPing(): Future[Result[Duration, string]] {.async.} =
      try:
        let conn =
          await self.node.switch.dial(peerInfo.peerId, peerInfo.addrs, PingCodec)
        defer:
          await conn.close()
        let rtt = await self.node.libp2pPing.ping(conn)
        if rtt == 0.nanos:
          return err("could not ping peer: rtt-0")
        return ok(rtt)
      except CatchableError as e:
        return err("could not ping peer: " & e.msg)

    let pingFut = doPing()
    let rtt: Duration =
      if timeoutMs <= 0:
        (await pingFut).valueOr:
          return err(error)
      else:
        if not await pingFut.withTimeout(chronos.milliseconds(timeoutMs)):
          return err("ping timed out")
        pingFut.read().valueOr:
          return err(error)

    return ok(rtt.nanos)
  except CatchableError as e:
    return err(e.msg)
