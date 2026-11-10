## Waku layer API — store (historical query) operations.
{.push raises: [].}

import results, chronos

import logos_delivery/waku/waku
import
  logos_delivery/waku/
    [waku_core, node/waku_node, node/peer_manager, waku_store/common, waku_store/client]

proc isStoreMounted*(self: Waku): bool =
  ## True if a store client is mounted (the node can run store queries).
  return not self.node.wakuStoreClient.isNil()

proc hasStorePeer*(self: Waku): bool =
  ## True if at least one store service peer is available to query.
  return self.node.peerManager.hasPeers(WakuStoreCodec)

proc groupStorePubsubTopics*(
    self: Waku, pubsubTopics: seq[PubsubTopic]
): seq[seq[PubsubTopic]] =
  ## Splits `pubsubTopics` into groups, one Store query per group. One Store
  ## peer can serve every topic of a group (see `groupShardsByStorePeer`).
  ## Example: Store peer A serves shards 0 and 1, and Store peer B serves
  ## shard 2. Then
  ##   @["/waku/2/rs/1/0", "/waku/2/rs/1/1", "/waku/2/rs/1/2"]
  ## gives
  ##   @[@["/waku/2/rs/1/0", "/waku/2/rs/1/1"], @["/waku/2/rs/1/2"]]
  ## With no Store client mounted, or a topic that is not a shard topic, all
  ## topics go in one group.
  if self.node.wakuStoreClient.isNil():
    return @[pubsubTopics]
  return self.node.wakuStoreClient.groupShardsByStorePeer(pubsubTopics)

proc storeQueryToAny*(
    self: Waku, request: StoreQueryRequest, shards: seq[PubsubTopic] = @[]
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Runs a store query against any available store peer (retries across peers).
  ## `shards` are the shards of the query. The pubsub topic of the request is
  ## the default.
  try:
    if self.node.wakuStoreClient.isNil():
      return err("wakuStoreClient is not mounted")

    let queryResponse = (
      await self.node.wakuStoreClient.queryToAny(request, shards = shards)
    ).valueOr:
      return err($error)

    return ok(queryResponse)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    return err(e.msg)

proc storeQuery*(
    self: Waku, request: StoreQueryRequest, peer: string, timeoutMs: int
): Future[Result[StoreQueryResponse, string]] {.async.} =
  ## Runs a store query against one store peer. `peer` is one fully qualified
  ## multiaddress, or several for the same peer separated by commas.
  try:
    if self.node.wakuStoreClient.isNil():
      return err("wakuStoreClient is not mounted")

    let remotePeer = parsePeerAddrList(peer).valueOr:
      return err("storeQuery failed to parse peer addr: " & $error)

    let queryFut = self.node.wakuStoreClient.query(request, remotePeer)
    if not await queryFut.withTimeout(timeoutMs.milliseconds):
      return err("storeQuery timed out")

    let queryResponse = queryFut.read().valueOr:
      return err("storeQuery failed: " & $error)

    return ok(queryResponse)
  except CatchableError as e:
    return err(e.msg)
