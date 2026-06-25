## Waku layer API — store (historical query) operations.
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/waku/waku
import
  logos_delivery/waku/[waku_core, node/waku_node, waku_store/common, waku_store/client]

proc storeQuery*(
    self: Waku, request: StoreQueryRequest, peer: string, timeoutMs: int
): Future[Result[StoreQueryResponse, string]] {.async.} =
  try:
    if self.node.wakuStoreClient.isNil():
      return err("wakuStoreClient is not mounted")

    let remotePeer = parsePeerInfo(peer).valueOr:
      return err("storeQuery failed to parse peer addr: " & $error)

    let queryFut = self.node.wakuStoreClient.query(request, remotePeer)
    if not await queryFut.withTimeout(timeoutMs.milliseconds):
      return err("storeQuery timed out")

    let queryResponse = queryFut.read().valueOr:
      return err("storeQuery failed: " & $error)

    return ok(queryResponse)
  except CatchableError as e:
    return err(e.msg)
