{.push raises: [].}

import
  std/[options],
  chronos,
  chronicles,
  metrics,
  results,
  eth/keys,
  eth/enr/enr,
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
  ../../waku_store_legacy/protocol as legacy_store,
  ../../waku_store_legacy/client as legacy_store_client,
  ../../waku_store_legacy/common as legacy_store_common,
  ../../waku_store/protocol as store,
  ../../waku_store/client as store_client,
  ../../waku_store/common as store_common,
  ../../waku_store/resume,
  ../peer_manager,
  ../../common/rate_limit/setting,
  ../../waku_archive,
  ../../waku_archive_legacy

logScope:
  topics = "waku node store api"

## Waku archive
proc mountArchive*(
    node: WakuNode,
    driver: waku_archive.ArchiveDriver,
    retentionPolicy = none(waku_archive.RetentionPolicy),
): Result[void, string] =
  node.wakuArchive = waku_archive.WakuArchive.new(
    driver = driver, retentionPolicy = retentionPolicy
  ).valueOr:
    return err("error in mountArchive: " & error)

  node.wakuArchive.start()

  return ok()

proc mountLegacyArchive*(
    node: WakuNode, driver: waku_archive_legacy.ArchiveDriver
): Result[void, string] =
  node.wakuLegacyArchive = waku_archive_legacy.WakuArchive.new(driver = driver).valueOr:
    return err("error in mountLegacyArchive: " & error)

  return ok()

## Legacy Waku Store

# TODO: Review this mapping logic. Maybe, move it to the appplication code
proc toArchiveQuery(
    request: legacy_store_common.HistoryQuery
): waku_archive_legacy.ArchiveQuery =
  waku_archive_legacy.ArchiveQuery(
    pubsubTopic: request.pubsubTopic,
    contentTopics: request.contentTopics,
    cursor: request.cursor.map(
      proc(cursor: HistoryCursor): waku_archive_legacy.ArchiveCursor =
        waku_archive_legacy.ArchiveCursor(
          pubsubTopic: cursor.pubsubTopic,
          senderTime: cursor.senderTime,
          storeTime: cursor.storeTime,
          digest: cursor.digest,
        )
    ),
    startTime: request.startTime,
    endTime: request.endTime,
    pageSize: request.pageSize.uint,
    direction: request.direction,
    requestId: request.requestId,
  )

# TODO: Review this mapping logic. Maybe, move it to the appplication code
proc toHistoryResult*(
    res: waku_archive_legacy.ArchiveResult
): legacy_store_common.HistoryResult =
  let response = res.valueOr:
    case error.kind
    of waku_archive_legacy.ArchiveErrorKind.DRIVER_ERROR,
        waku_archive_legacy.ArchiveErrorKind.INVALID_QUERY:
      return err(HistoryError(kind: HistoryErrorKind.BAD_REQUEST, cause: error.cause))
    else:
      return err(HistoryError(kind: HistoryErrorKind.UNKNOWN))
  return ok(
    HistoryResponse(
      messages: response.messages,
      cursor: response.cursor.map(
        proc(cursor: waku_archive_legacy.ArchiveCursor): HistoryCursor =
          HistoryCursor(
            pubsubTopic: cursor.pubsubTopic,
            senderTime: cursor.senderTime,
            storeTime: cursor.storeTime,
            digest: cursor.digest,
          )
      ),
    )
  )

proc mountLegacyStore*(
    node: WakuNode, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
) {.async.} =
  info "mounting waku legacy store protocol"

  if node.wakuLegacyArchive.isNil():
    error "failed to mount waku legacy store protocol", error = "waku archive not set"
    return

  # TODO: Review this handler logic. Maybe, move it to the appplication code
  let queryHandler: HistoryQueryHandler = proc(
      request: HistoryQuery
  ): Future[legacy_store_common.HistoryResult] {.async.} =
    if request.cursor.isSome():
      ?request.cursor.get().checkHistCursor()

    let request = request.toArchiveQuery()
    let response = await node.wakuLegacyArchive.findMessagesV2(request)
    return response.toHistoryResult()

  node.wakuLegacyStore = legacy_store.WakuStore.new(
    node.peerManager, node.rng, queryHandler, some(rateLimit)
  )

  if node.started:
    # Node has started already. Let's start store too.
    await node.wakuLegacyStore.start()

  node.switch.mount(
    node.wakuLegacyStore, protocolMatcher(legacy_store_common.WakuLegacyStoreCodec)
  )

proc mountLegacyStoreClient*(node: WakuNode) =
  info "mounting legacy store client"

  node.wakuLegacyStoreClient =
    legacy_store_client.WakuStoreClient.new(node.peerManager, node.rng)

proc query*(
    node: WakuNode, query: legacy_store_common.HistoryQuery, peer: RemotePeerInfo
): Future[legacy_store_common.WakuStoreResult[legacy_store_common.HistoryResponse]] {.
    async, gcsafe
.} =
  ## Queries known nodes for historical messages
  if node.wakuLegacyStoreClient.isNil():
    return err("waku legacy store client is nil")

  let response = (await node.wakuLegacyStoreClient.query(query, peer)).valueOr:
    return err("legacy store client query error: " & $error)

  return ok(response)

# TODO: Move to application module (e.g., wakunode2.nim)
proc query*(
    node: WakuNode, query: legacy_store_common.HistoryQuery
): Future[legacy_store_common.WakuStoreResult[legacy_store_common.HistoryResponse]] {.
    async, gcsafe, deprecated: "Use 'node.query()' with peer destination instead"
.} =
  ## Queries known nodes for historical messages
  if node.wakuLegacyStoreClient.isNil():
    return err("waku legacy store client is nil")

  let peerOpt = node.peerManager.selectPeer(legacy_store_common.WakuLegacyStoreCodec)
  if peerOpt.isNone():
    error "no suitable remote peers"
    return err("peer_not_found_failure")

  return await node.query(query, peerOpt.get())

when defined(waku_exp_store_resume):
  # TODO: Move to application module (e.g., wakunode2.nim)
  proc resume*(
      node: WakuNode, peerList: Option[seq[RemotePeerInfo]] = none(seq[RemotePeerInfo])
  ) {.async, gcsafe.} =
    ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku node has been online
    ## for resume to work properly the waku node must have the store protocol mounted in the full mode (i.e., persisting messages)
    ## messages are stored in the wakuStore's messages field and in the message db
    ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message
    ## an offset of 20 second is added to the time window to count for nodes asynchrony
    ## peerList indicates the list of peers to query from. The history is fetched from the first available peer in this list. Such candidates should be found through a discovery method (to be developed).
    ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from.
    ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
    if node.wakuLegacyStoreClient.isNil():
      return

    let retrievedMessages = (await node.wakuLegacyStoreClient.resume(peerList)).valueOr:
      error "failed to resume store", error = error
      return

    info "the number of retrieved messages since the last online time: ",
      number = retrievedMessages.value

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
