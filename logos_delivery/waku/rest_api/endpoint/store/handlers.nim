{.push raises: [].}

import std/options, std/[strformat, sugar], results

import chronicles, uri, json_serialization, presto/route
import
  logos_delivery/waku/[
    waku_core,
    waku_store/common,
    waku_store/self_req_handler,
    waku_node,
    node/peer_manager,
    common/paging,
    rest_api/handlers,
    rest_api/endpoint/responses,
    rest_api/endpoint/serdes,
    rest_api/endpoint/store/types,
  ]

export types

logScope:
  topics = "waku node rest store_api"

const futTimeout* = 5.seconds # Max time to wait for futures

const NoPeerNoDiscError* =
  RestApiResponse.preconditionFailed("No suitable service peer & no discovery method")

# Queries the store-node with the query parameters and
# returns a RestApiResponse that is sent back to the api client.
proc performStoreQuery(
    selfNode: WakuNode, storeQuery: StoreQueryRequest, storePeer: RemotePeerInfo
): Future[RestApiResponse] {.async.} =
  let queryFut = selfNode.query(storeQuery, storePeer)

  if not await queryFut.withTimeout(futTimeout):
    const msg = "No history response received (timeout)"
    error msg
    return RestApiResponse.internalServerError(msg)

  let res = queryFut.read().map(val => val.toHex()).valueOr:
      const msg = "Error occurred in queryFut.read()"
      error msg, error = error
      return RestApiResponse.internalServerError(fmt("{msg} [{error}]"))

  if res.statusCode == uint32(ErrorCode.TOO_MANY_REQUESTS):
    info "Request rate limit reached on peer ", storePeer
    return RestApiResponse.tooManyRequests("Request rate limit reached")

  let resp = RestApiResponse.jsonResponse(res, status = Http200).valueOr:
    const msg = "Error building the json respose"
    let e = $error
    error msg, error = e
    return RestApiResponse.internalServerError(fmt("{msg} [{e}]"))

  return resp

# Converts a string time representation into an Opt[Timestamp].
# Only positive time is considered a valid Timestamp in the request
proc parseTime(input: Opt[string]): Result[Opt[Timestamp], string] =
  if input.isSome() and input.get() != "":
    try:
      let time = parseInt(input.get())
      if time > 0:
        return ok(Opt.some(Timestamp(time)))
    except ValueError:
      return err("time parsing error: " & getCurrentExceptionMsg())

  return ok(Opt.none(Timestamp))

proc parseIncludeData(input: Opt[string]): Result[bool, string] =
  var includeData = false
  if input.isSome() and input.get() != "":
    try:
      includeData = parseBool(input.get())
    except ValueError:
      return err("include data parsing error: " & getCurrentExceptionMsg())

  return ok(includeData)

# Creates a HistoryQuery from the given params
proc createStoreQuery(
    includeData: Opt[string],
    pubsubTopic: Opt[string],
    contentTopics: Opt[string],
    startTime: Opt[string],
    endTime: Opt[string],
    hashes: Opt[string],
    cursor: Opt[string],
    direction: Opt[string],
    pageSize: Opt[string],
): Result[StoreQueryRequest, string] =
  var parsedIncludeData = ?parseIncludeData(includeData)

  # Parse pubsubTopic parameter
  var parsedPubsubTopic = Opt.none(string)
  if pubsubTopic.isSome():
    let decodedPubsubTopic = decodeUrl(pubsubTopic.get())
    if decodedPubsubTopic != "":
      parsedPubsubTopic = Opt.some(decodedPubsubTopic)

  # Parse the content topics
  var parsedContentTopics = newSeq[ContentTopic](0)
  if contentTopics.isSome():
    let ctList = decodeUrl(contentTopics.get())
    if ctList != "":
      for ct in ctList.split(','):
        parsedContentTopics.add(ct)

  # Parse start time
  let parsedStartTime = ?parseTime(startTime)

  # Parse end time
  let parsedEndTime = ?parseTime(endTime)

  var parsedHashes = ?parseHashes(hashes)

  # Parse cursor information
  let parsedCursor = ?parseHash(cursor)

  # Parse ascending field
  var parsedDirection = default()
  if direction.isSome() and direction.get() != "":
    parsedDirection = direction.get().into()

  # Parse page size field
  var parsedPagedSize = Opt.none(uint64)
  if pageSize.isSome() and pageSize.get() != "":
    try:
      parsedPagedSize = Opt.some(uint64(parseInt(pageSize.get())))
    except CatchableError:
      return err("page size parsing error: " & getCurrentExceptionMsg())

  # Enforce default value of page_size to 20
  if parsedPagedSize.isNone():
    parsedPagedSize = Opt.some(20.uint64)

  # Enforce max value of page_size to 100
  if parsedPagedSize.get() > 100:
    parsedPagedSize = Opt.some(100.uint64)

  return ok(
    StoreQueryRequest(
      includeData: parsedIncludeData,
      pubsubTopic: parsedPubsubTopic,
      contentTopics: parsedContentTopics,
      startTime: parsedStartTime,
      endTime: parsedEndTime,
      messageHashes: parsedHashes,
      paginationCursor: parsedCursor,
      paginationForward: parsedDirection,
      paginationLimit: parsedPagedSize,
    )
  )

proc toOpt(self: Option[Result[string, cstring]]): Opt[string] =
  if not self.isSome() or self.get().value == "":
    return Opt.none(string)
  if self.isSome() and self.get().value != "":
    return Opt.some(self.get().value)

proc retrieveMsgsFromSelfNode(
    self: WakuNode, storeQuery: StoreQueryRequest
): Future[RestApiResponse] {.async.} =
  ## Performs a "store" request to the local node (self node.)
  ## Notice that this doesn't follow the regular store libp2p channel because a node
  ## it is not allowed to libp2p-dial a node to itself, by default.
  ##

  let storeResp = (await self.wakuStore.handleSelfStoreRequest(storeQuery)).valueOr:
    return RestApiResponse.internalServerError($error)

  let resp = RestApiResponse.jsonResponse(storeResp.toHex(), status = Http200).valueOr:
    const msg = "Error building the json respose"
    let e = $error
    error msg, error = e
    return RestApiResponse.internalServerError(fmt("{msg} [{e}]"))

  return resp

proc retrieveMsgsFromArchive(
    self: WakuNode, storeQuery: StoreQueryRequest
): Future[RestApiResponse] {.async.} =
  ## Serves a local store query from the node's archive when the store
  ## protocol is not mounted (e.g. store-sync standalone full nodes).

  let storeResp = (await self.queryArchive(storeQuery)).valueOr:
    return RestApiResponse.internalServerError($error)

  let resp = RestApiResponse.jsonResponse(storeResp.toHex(), status = Http200).valueOr:
    const msg = "Error building the json respose"
    let e = $error
    error msg, error = e
    return RestApiResponse.internalServerError(fmt("{msg} [{e}]"))

  return resp

# Subscribes the rest handler to attend "/store/v1/messages" requests
proc installStoreApiHandlers*(
    router: var RestRouter,
    node: WakuNode,
    discHandler: Opt[DiscoveryHandler] = Opt.none(DiscoveryHandler),
) =
  # Handles the store-query request according to the passed parameters
  router.api(MethodGet, "/store/v3/messages") do(
    peerAddr: Option[string],
    includeData: Option[string],
    pubsubTopic: Option[string],
    contentTopics: Option[string],
    startTime: Option[string],
    endTime: Option[string],
    hashes: Option[string],
    cursor: Option[string],
    ascending: Option[string],
    pageSize: Option[string]
  ) -> RestApiResponse:
    let peer = peerAddr.toOpt()

    info "REST-GET /store/v3/messages ", peer_addr = $peer

    # All the GET parameters are URL-encoded (https://en.wikipedia.org/wiki/URL_encoding)
    # Example:
    # /store/v1/messages?peerAddr=%2Fip4%2F127.0.0.1%2Ftcp%2F60001%2Fp2p%2F16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\&pubsubTopic=my-waku-topic

    # Parse the rest of the parameters and create a HistoryQuery
    let storeQuery = createStoreQuery(
      includeData.toOpt(),
      pubsubTopic.toOpt(),
      contentTopics.toOpt(),
      startTime.toOpt(),
      endTime.toOpt(),
      hashes.toOpt(),
      cursor.toOpt(),
      ascending.toOpt(),
      pageSize.toOpt(),
    ).valueOr:
      return RestApiResponse.badRequest(error)

    if peer.isNone() and not node.wakuStore.isNil():
      ## The user didn't specify a peer address and self-node is configured as a store node.
      ## In this case we assume that the user is willing to retrieve the messages stored by
      ## the local/self store node.
      return await node.retrieveMsgsFromSelfNode(storeQuery)

    if peer.isNone() and not node.wakuArchive.isNil():
      ## No peer given and no store protocol, but the node carries an archive
      ## (store-sync standalone): serve the query from the local archive, like
      ## a store node serving its own. Only the archive's retention window is
      ## returned; pass peerAddr to query a remote store for deeper history.
      return await node.retrieveMsgsFromArchive(storeQuery)

    # Parse the peer address parameter
    let parsedPeerAddr = parseUrlPeerAddr(peer).valueOr:
      return RestApiResponse.badRequest(error)

    let peerInfo = parsedPeerAddr.valueOr:
      node.peerManager.selectPeer(WakuStoreCodec).valueOr:
        let handler = discHandler.valueOr:
          return NoPeerNoDiscError

        let peerOp = (await handler()).valueOr:
          return RestApiResponse.internalServerError($error)

        peerOp.valueOr:
          return RestApiResponse.preconditionFailed(
            "No suitable service peer & none discovered"
          )

    return await node.performStoreQuery(storeQuery, peerInfo)
