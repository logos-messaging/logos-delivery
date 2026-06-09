{.push raises: [].}

import std/options, stew/arrayops
import ../common/[protobuf, paging], ../waku_core, ./common

const DefaultMaxRpcSize* = -1

### Request ###

proc encode*(req: StoreQueryRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, req.requestId)
  pb.write3(2, uint32(req.includeData))

  pb.write3(10, req.pubsubTopic)

  for contentTopic in req.contentTopics:
    pb.write3(11, contentTopic)

  pb.write3(
    12,
    req.startTime.map(
      proc(time: int64): zint64 =
        zint64(time)
    ),
  )
  pb.write3(
    13,
    req.endTime.map(
      proc(time: int64): zint64 =
        zint64(time)
    ),
  )

  for hash in req.messagehashes:
    pb.write3(20, hash)

  pb.write3(51, req.paginationCursor)
  pb.write3(52, uint32(req.paginationForward))
  pb.write3(53, req.paginationLimit)

  pb.finish3()

  return pb

proc decode*(
    T: type StoreQueryRequest, buffer: seq[byte]
): ProtobufResult[StoreQueryRequest] =
  var req = StoreQueryRequest()
  let pb = initProtoBuffer(buffer)

  if not ?pb.getField(1, req.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  var inclData: uint32
  if not ?pb.getField(2, inclData):
    req.includeData = false
  else:
    req.includeData = inclData > 0

  var pubsubTopic: string
  if not ?pb.getField(10, pubsubTopic):
    req.pubsubTopic = none(string)
  else:
    req.pubsubTopic = some(pubsubTopic)

  var topics: seq[string]
  if not ?pb.getRepeatedField(11, topics):
    req.contentTopics = @[]
  else:
    req.contentTopics = topics

  var start: zint64
  if not ?pb.getField(12, start):
    req.startTime = none(Timestamp)
  else:
    req.startTime = some(Timestamp(int64(start)))

  var endTime: zint64
  if not ?pb.getField(13, endTime):
    req.endTime = none(Timestamp)
  else:
    req.endTime = some(Timestamp(int64(endTime)))

  var buffer: seq[seq[byte]]
  if not ?pb.getRepeatedField(20, buffer):
    req.messageHashes = @[]
  else:
    req.messageHashes = newSeqOfCap[WakuMessageHash](buffer.len)
    for buf in buffer:
      var hash: WakuMessageHash
      discard copyFrom[byte](hash, buf)
      req.messageHashes.add(hash)

  var cursor: seq[byte]
  if not ?pb.getField(51, cursor):
    req.paginationCursor = none(WakuMessageHash)
  else:
    var hash: WakuMessageHash
    discard copyFrom[byte](hash, cursor)
    req.paginationCursor = some(hash)

  var paging: uint32
  if not ?pb.getField(52, paging):
    req.paginationForward = PagingDirection.default()
  else:
    req.paginationForward = PagingDirection(paging)

  var limit: uint64
  if not ?pb.getField(53, limit):
    req.paginationLimit = none(uint64)
  else:
    req.paginationLimit = some(limit)

  return ok(req)

### Response ###

proc encode*(keyValue: WakuMessageKeyValue): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, keyValue.messageHash)

  if keyValue.message.isSome() and keyValue.pubsubTopic.isSome():
    pb.write3(2, keyValue.message.get().encode())
    pb.write3(3, keyValue.pubsubTopic.get())

  pb.finish3()

  return pb

proc encode*(res: StoreQueryResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, res.requestId)

  pb.write3(10, res.statusCode)
  pb.write3(11, res.statusDesc)

  for msg in res.messages:
    pb.write3(20, msg.encode())

  pb.write3(51, res.paginationCursor)

  pb.finish3()

  return pb

proc decode*(
    T: type WakuMessageKeyValue, buffer: seq[byte]
): ProtobufResult[WakuMessageKeyValue] =
  var keyValue = WakuMessageKeyValue()
  let pb = initProtoBuffer(buffer)

  var buf: seq[byte]
  if not ?pb.getField(1, buf):
    return err(ProtobufError.missingRequiredField("message_hash"))
  else:
    var hash: WakuMessageHash
    discard copyFrom[byte](hash, buf)
    keyValue.messagehash = hash

  var proto: ProtoBuffer
  var topic: string
  if ?pb.getField(2, proto) and ?pb.getField(3, topic):
    keyValue.message = some(?WakuMessage.decode(proto.buffer))
    keyValue.pubsubTopic = some(topic)
  else:
    keyValue.message = none(WakuMessage)
    keyValue.pubsubTopic = none(string)

  return ok(keyValue)

proc decode*(
    T: type StoreQueryResponse, buffer: seq[byte]
): ProtobufResult[StoreQueryResponse] =
  var res = StoreQueryResponse()
  let pb = initProtoBuffer(buffer)

  if not ?pb.getField(1, res.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  var code: uint32
  if not ?pb.getField(10, code):
    return err(ProtobufError.missingRequiredField("status_code"))
  else:
    res.statusCode = code

  var desc: string
  if not ?pb.getField(11, desc):
    return err(ProtobufError.missingRequiredField("status_desc"))
  else:
    res.statusDesc = desc

  var buffer: seq[seq[byte]]
  if not ?pb.getRepeatedField(20, buffer):
    res.messages = @[]
  else:
    res.messages = newSeqOfCap[WakuMessageKeyValue](buffer.len)
    for buf in buffer:
      let msg = ?WakuMessageKeyValue.decode(buf)
      res.messages.add(msg)

  var cursor: seq[byte]
  if not ?pb.getField(51, cursor):
    res.paginationCursor = none(WakuMessageHash)
  else:
    var hash: WakuMessageHash
    discard copyFrom[byte](hash, cursor)
    res.paginationCursor = some(hash)

  return ok(res)
