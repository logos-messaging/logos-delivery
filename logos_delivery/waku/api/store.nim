## Waku layer API — store (historical query) operations.
{.push raises: [].}

import std/options
import results, chronos, chronicles

import logos_delivery/waku/waku
import
  logos_delivery/waku/
    [waku_core, node/waku_node, node/peer_manager, waku_store/common, waku_store/client]

proc isStoreMounted*(self: Waku): bool =
  ## True if a store client is mounted (the node can run store queries).
  return not self.node.wakuStoreClient.isNil()

proc hasStorePeer*(self: Waku): bool =
  ## True if at least one store service peer is available to query.
  return self.node.peerManager.selectPeer(WakuStoreCodec).isSome()

proc storeQueryToAny*(
    self: Waku, request: StoreQueryRequest
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Runs a store query against any available store peer (retries across peers).
  try:
    if self.node.wakuStoreClient.isNil():
      return err("wakuStoreClient is not mounted")

    let queryResponse = (await self.node.wakuStoreClient.queryToAny(request)).valueOr:
      return err($error)

    return ok(queryResponse)
  except CatchableError as e:
    return err(e.msg)

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
