{.push raises: [].}

import
  results,
  json_serialization,
  protobuf_serialization,
  protobuf_serialization/pkg/results,
  protobuf_serialization/std/enums
import ../waku_core

type
  FilterSubscribeType* {.pure.} = enum
    # Indicates the type of request from client to service node
    SUBSCRIBER_PING = uint32(0)
    SUBSCRIBE = uint32(1)
    UNSUBSCRIBE = uint32(2)
    UNSUBSCRIBE_ALL = uint32(3)

  FilterSubscribeRequest* = object
    # Request from client to service node
    # serialized via DTO in rpc_codec.nim; absent filterSubscribeType -> ping
    requestId*: string
    filterSubscribeType*: FilterSubscribeType
    pubsubTopic*: Opt[PubsubTopic]
    contentTopics*: seq[ContentTopic]

  FilterSubscribeResponse* {.proto2.} = object # Response from service node to client
    requestId* {.fieldNumber: 1, required.}: string
    statusCode* {.fieldNumber: 10, pint, required.}: uint32
    statusDesc* {.fieldNumber: 11.}: Opt[string]

  MessagePush* {.proto2.} = object # Message pushed from service node to client
    wakuMessage* {.fieldNumber: 1, ext, required.}: WakuMessage
    pubsubTopic* {.fieldNumber: 2, required.}: string

# Convenience functions

proc ping*(T: type FilterSubscribeRequest, requestId: string): T =
  FilterSubscribeRequest(requestId: requestId, filterSubscribeType: SUBSCRIBER_PING)

proc subscribe*(
    T: type FilterSubscribeRequest,
    requestId: string,
    pubsubTopic: PubsubTopic,
    contentTopics: seq[ContentTopic],
): T =
  FilterSubscribeRequest(
    requestId: requestId,
    filterSubscribeType: SUBSCRIBE,
    pubsubTopic: Opt.some(pubsubTopic),
    contentTopics: contentTopics,
  )

proc unsubscribe*(
    T: type FilterSubscribeRequest,
    requestId: string,
    pubsubTopic: PubsubTopic,
    contentTopics: seq[ContentTopic],
): T =
  FilterSubscribeRequest(
    requestId: requestId,
    filterSubscribeType: UNSUBSCRIBE,
    pubsubTopic: Opt.some(pubsubTopic),
    contentTopics: contentTopics,
  )

proc unsubscribeAll*(T: type FilterSubscribeRequest, requestId: string): T =
  FilterSubscribeRequest(requestId: requestId, filterSubscribeType: UNSUBSCRIBE_ALL)

proc ok*(T: type FilterSubscribeResponse, requestId: string, desc = "OK"): T =
  FilterSubscribeResponse(
    requestId: requestId, statusCode: 200, statusDesc: Opt.some(desc)
  )

proc `$`*(err: FilterSubscribeResponse): string =
  "FilterSubscribeResponse of req:" & err.requestId & " [" & $err.statusCode & "] " &
    err.statusDesc.get("")

proc `$`*(req: FilterSubscribeRequest): string =
  "FilterSubscribeRequest of req:" & req.requestId & " [" & $req.filterSubscribeType &
    "] pubsubTopic:" & $req.pubsubTopic & " contentTopics:" & $req.contentTopics

proc `$`*(t: FilterSubscribeType): string =
  result =
    case t
    of SUBSCRIBER_PING: "SUBSCRIBER_PING"
    of SUBSCRIBE: "SUBSCRIBE"
    of UNSUBSCRIBE: "UNSUBSCRIBE"
    of UNSUBSCRIBE_ALL: "UNSUBSCRIBE_ALL"

proc writeValue*(
    writer: var JsonWriter, value: FilterSubscribeRequest
) {.inline, raises: [IOError].} =
  writer.beginRecord()
  writer.writeField("requestId", value.requestId)
  writer.writeField("type", value.filterSubscribeType)
  if value.pubsubTopic.isSome:
    writer.writeField("pubsubTopic", value.pubsubTopic)
  if value.contentTopics.len > 0:
    writer.writeField("contentTopics", value.contentTopics)
  writer.endRecord()

proc `$`*(self: MessagePush): string =
  let msg_hash = computeMessageHash(self.pubsubTopic, self.wakuMessage)
  return "msg_hash: " & shortLog(msg_hash) & " pubsubTopic: " & self.pubsubTopic
