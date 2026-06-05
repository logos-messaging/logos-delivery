{.push raises: [].}

import
  std/[options],
  chronos,
  chronicles,
  metrics,
  results,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/utility

import
  ../waku_node,
  ../../waku_core,
  ../../waku_store/protocol as store,
  ../../waku_store/client as store_client,
  ../../waku_store/common as store_common,
  ../../waku_store/resume,
  ../peer_manager,
  ../../common/rate_limit/setting,
  ../../waku_archive

logScope:
  topics = "waku node store api"

## Waku archive
proc mountArchive*(
    node: WakuNode,
    driver: waku_archive.ArchiveDriver,
    retentionPolicies = newSeq[waku_archive.RetentionPolicy](),
): Result[void, string] =
  node.wakuArchive = waku_archive.WakuArchive.new(
    driver = driver, retentionPolicies = retentionPolicies
  ).valueOr:
    return err("error in mountArchive: " & error)

  node.wakuArchive.start()

  return ok()

## Waku Store

proc toArchiveQuery(request: StoreQueryRequest): waku_archive.ArchiveQuery =
  var query = waku_archive.ArchiveQuery()

  query.includeData = request.includeData
  query.pubsubTopic = request.pubsubTopic
  query.contentTopics = request.contentTopics
  query.startTime = request.startTime
  query.endTime = request.endTime
  query.hashes = request.messageHashes
  query.cursor = request.paginationCursor
  query.direction = request.paginationForward
  query.requestId = request.requestId

  if request.paginationLimit.isSome():
    query.pageSize = uint(request.paginationLimit.get())

  return query

proc toStoreResult(res: waku_archive.ArchiveResult): StoreQueryResult =
  let response = res.valueOr:
    return err(StoreError.new(300, "archive error: " & $error))

  var res = StoreQueryResponse()

  res.statusCode = 200
  res.statusDesc = "OK"

  for i in 0 ..< response.hashes.len:
    let hash = response.hashes[i]

    let kv = store_common.WakuMessageKeyValue(messageHash: hash)

    res.messages.add(kv)

  for i in 0 ..< response.messages.len:
    res.messages[i].message = some(response.messages[i])
    res.messages[i].pubsubTopic = some(response.topics[i])

  res.paginationCursor = response.cursor

  return ok(res)

proc mountStore*(
    node: WakuNode, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
) {.async.} =
  if node.wakuArchive.isNil():
    error "failed to mount waku store protocol", error = "waku archive not set"
    return

  info "mounting waku store protocol"

  let requestHandler: StoreQueryRequestHandler = proc(
      request: StoreQueryRequest
  ): Future[StoreQueryResult] {.async.} =
    let request = request.toArchiveQuery()
    let response = await node.wakuArchive.findMessages(request)

    return response.toStoreResult()

  node.wakuStore =
    store.WakuStore.new(node.peerManager, node.rng, requestHandler, some(rateLimit))

  if node.started:
    await node.wakuStore.start()

  node.switch.mount(node.wakuStore, protocolMatcher(store_common.WakuStoreCodec))

proc mountStoreClient*(node: WakuNode) =
  info "mounting store client"

  node.wakuStoreClient = store_client.WakuStoreClient.new(node.peerManager, node.rng)

proc query*(
    node: WakuNode, request: store_common.StoreQueryRequest, peer: RemotePeerInfo
): Future[store_common.WakuStoreResult[store_common.StoreQueryResponse]] {.
    async, gcsafe
.} =
  ## Queries known nodes for historical messages
  if node.wakuStoreClient.isNil():
    return err("waku store v3 client is nil")

  let response = (await node.wakuStoreClient.query(request, peer)).valueOr:
    var res = StoreQueryResponse()
    res.statusCode = uint32(error.kind)
    res.statusDesc = $error

    return ok(res)

  return ok(response)

proc setupStoreResume*(node: WakuNode) =
  node.wakuStoreResume = StoreResume.new(
    node.peerManager, node.wakuArchive, node.wakuStoreClient
  ).valueOr:
    error "Failed to setup Store Resume", error = $error
    return
