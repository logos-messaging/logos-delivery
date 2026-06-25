## The query/response are complex types, so this keeps the JSON bridge: the
## request carries the query as a JSON string, the response is returned as JSON.
import std/[json, sugar, options]
import logos_delivery/waku/waku_core/message/digest
import logos_delivery/waku/waku_store/common
import logos_delivery/waku/common/paging
import library/utils

func storeQueryFromJson(jsonContent: JsonNode): Result[StoreQueryRequest, string] =
  var contentTopics: seq[string]
  if jsonContent.contains("contentTopics"):
    contentTopics = collect(newSeq):
      for cTopic in jsonContent["contentTopics"].getElems():
        cTopic.getStr()

  var msgHashes: seq[WakuMessageHash]
  if jsonContent.contains("messageHashes"):
    for hashJsonObj in jsonContent["messageHashes"].getElems():
      let hash = hashJsonObj.getStr().hexToHash().valueOr:
          return err("Failed converting message hash hex string to bytes: " & error)
      msgHashes.add(hash)

  let pubsubTopic =
    if jsonContent.contains("pubsubTopic"):
      some(jsonContent["pubsubTopic"].getStr())
    else:
      none(string)

  let paginationCursor =
    if jsonContent.contains("paginationCursor"):
      let hash = jsonContent["paginationCursor"].getStr().hexToHash().valueOr:
          return err("Failed converting paginationCursor hex string to bytes: " & error)
      some(hash)
    else:
      none(WakuMessageHash)

  let paginationForwardBool = jsonContent["paginationForward"].getBool()
  let paginationForward =
    if paginationForwardBool: PagingDirection.FORWARD else: PagingDirection.BACKWARD

  let paginationLimit =
    if jsonContent.contains("paginationLimit"):
      some(uint64(jsonContent["paginationLimit"].getInt()))
    else:
      none(uint64)

  let startTime = ?jsonContent.getProtoInt64("timeStart")
  let endTime = ?jsonContent.getProtoInt64("timeEnd")

  return ok(
    StoreQueryRequest(
      requestId: jsonContent["requestId"].getStr(),
      includeData: jsonContent["includeData"].getBool(),
      pubsubTopic: pubsubTopic,
      contentTopics: contentTopics,
      startTime: startTime,
      endTime: endTime,
      messageHashes: msgHashes,
      paginationCursor: paginationCursor,
      paginationForward: paginationForward,
      paginationLimit: paginationLimit,
    )
  )

proc store_query*(
    self: LogosDelivery, queryJson: string, peer: string, timeoutMs: int
): Future[Result[string, string]] {.ffi.} =
  let jsonContent =
    try:
      parseJson(queryJson)
    except CatchableError as e:
      return err("StoreRequest failed parsing store request: " & e.msg)

  let storeQueryRequest = storeQueryFromJson(jsonContent).valueOr:
    return err(error)

  let queryResponse = (await self.waku.storeQuery(storeQueryRequest, peer, timeoutMs)).valueOr:
    return err("StoreRequest failed store query: " & error)

  return ok($(%*(queryResponse.toHex()))) ## response in json format
