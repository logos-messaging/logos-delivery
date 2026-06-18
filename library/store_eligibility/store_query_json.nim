import std/[json, options, strutils, sugar]
import results
import
  logos_delivery/waku/waku_core/message/digest,
  logos_delivery/waku/waku_store/common,
  logos_delivery/waku/common/paging,
  ../utils

func storeQueryRequestFromJson*(
    jsonContent: JsonNode
): Result[StoreQueryRequest, string] =
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

  var eligibilityProof = none(seq[byte])
  if jsonContent.contains("eligibilityProofHex"):
    let proofHex = jsonContent["eligibilityProofHex"].getStr()
    eligibilityProof = try:
      some(proofHex.hexToSeqByte())
    except ValueError:
      return err("Failed converting eligibilityProofHex to bytes")

  let startTime = ?jsonContent.getProtoInt64("timeStart")
  let endTime = ?jsonContent.getProtoInt64("timeEnd")

  ok(
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
      eligibilityProof: eligibilityProof,
    )
  )
