{.push raises: [].}

import std/sequtils, results, stew/arrayops
import protobuf_serialization, protobuf_serialization/pkg/results
import ../common/[protobuf, paging], ../waku_core, ./common

const DefaultMaxRpcSize* = -1

type
  WakuMessageKeyValuePB {.proto2.} = object
    messageHash {.fieldNumber: 1, required.}: seq[byte]
    message {.fieldNumber: 2, ext.}: Opt[WakuMessage]
    pubsubTopic {.fieldNumber: 3.}: Opt[string]

  StoreQueryRequestPB {.proto2.} = object
    requestId {.fieldNumber: 1, required.}: string
    includeData {.fieldNumber: 2.}: Opt[bool]
    pubsubTopic {.fieldNumber: 10.}: Opt[string]
    contentTopics {.fieldNumber: 11.}: seq[string]
    startTime {.fieldNumber: 12, sint.}: Opt[int64]
    endTime {.fieldNumber: 13, sint.}: Opt[int64]
    messageHashes {.fieldNumber: 20.}: seq[seq[byte]]
    paginationCursor {.fieldNumber: 51.}: Opt[seq[byte]]
    paginationForward {.fieldNumber: 52, pint.}: Opt[uint32]
    paginationLimit {.fieldNumber: 53, pint.}: Opt[uint64]

  StoreQueryResponsePB {.proto2.} = object
    requestId {.fieldNumber: 1, required.}: string
    statusCode {.fieldNumber: 10, pint, required.}: uint32
    statusDesc {.fieldNumber: 11, required.}: string
    messages {.fieldNumber: 20.}: seq[WakuMessageKeyValuePB]
    paginationCursor {.fieldNumber: 51.}: Opt[seq[byte]]

proc toHash(s: seq[byte]): WakuMessageHash =
  var h: WakuMessageHash
  discard copyFrom[byte](h, s)
  h

### Request ###

proc encode*(req: StoreQueryRequest): seq[byte] =
  Protobuf.encode(
    StoreQueryRequestPB(
      requestId: req.requestId,
      includeData: Opt.some(req.includeData),
      pubsubTopic: req.pubsubTopic,
      contentTopics: req.contentTopics,
      startTime: req.startTime.map(
        proc(t: Timestamp): int64 =
          int64(t)
      ),
      endTime: req.endTime.map(
        proc(t: Timestamp): int64 =
          int64(t)
      ),
      messageHashes: req.messageHashes.mapIt(@it),
      paginationCursor: req.paginationCursor.map(
        proc(h: WakuMessageHash): seq[byte] =
          @h
      ),
      paginationForward: Opt.some(uint32(ord(req.paginationForward))),
      paginationLimit: req.paginationLimit,
    )
  )

proc decodeStoreQueryRequest(buffer: seq[byte]): ProtobufResult[StoreQueryRequest] =
  var pb: StoreQueryRequestPB
  try:
    pb = Protobuf.decode(buffer, StoreQueryRequestPB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  ok(
    StoreQueryRequest(
      requestId: pb.requestId,
      includeData: pb.includeData.get(false),
      pubsubTopic: pb.pubsubTopic,
      contentTopics: pb.contentTopics,
      startTime: pb.startTime.map(
        proc(t: int64): Timestamp =
          Timestamp(t)
      ),
      endTime: pb.endTime.map(
        proc(t: int64): Timestamp =
          Timestamp(t)
      ),
      messageHashes: pb.messageHashes.mapIt(toHash(it)),
      paginationCursor: pb.paginationCursor.map(
        proc(s: seq[byte]): WakuMessageHash =
          toHash(s)
      ),
      paginationForward: PagingDirection(pb.paginationForward.get(1'u32)),
      paginationLimit: pb.paginationLimit,
    )
  )

proc decode*(
    T: type StoreQueryRequest, buffer: seq[byte]
): ProtobufResult[StoreQueryRequest] =
  decodeStoreQueryRequest(buffer)

### Response ###

proc toPB(kv: WakuMessageKeyValue): WakuMessageKeyValuePB =
  # message + pubsubTopic: both or neither
  if kv.message.isSome() and kv.pubsubTopic.isSome():
    WakuMessageKeyValuePB(
      messageHash: @(kv.messageHash), message: kv.message, pubsubTopic: kv.pubsubTopic
    )
  else:
    WakuMessageKeyValuePB(messageHash: @(kv.messageHash))

proc encode*(keyValue: WakuMessageKeyValue): seq[byte] =
  Protobuf.encode(toPB(keyValue))

proc encode*(res: StoreQueryResponse): seq[byte] =
  Protobuf.encode(
    StoreQueryResponsePB(
      requestId: res.requestId,
      statusCode: res.statusCode,
      statusDesc: res.statusDesc,
      messages: res.messages.mapIt(toPB(it)),
      paginationCursor: res.paginationCursor.map(
        proc(h: WakuMessageHash): seq[byte] =
          @h
      ),
    )
  )

proc fromPB(pb: WakuMessageKeyValuePB): WakuMessageKeyValue =
  # message + pubsubTopic: both or neither
  if pb.message.isSome() and pb.pubsubTopic.isSome():
    WakuMessageKeyValue(
      messageHash: toHash(pb.messageHash),
      message: pb.message,
      pubsubTopic: pb.pubsubTopic,
    )
  else:
    WakuMessageKeyValue(messageHash: toHash(pb.messageHash))

proc decodeWakuMessageKeyValue(buffer: seq[byte]): ProtobufResult[WakuMessageKeyValue] =
  try:
    ok(fromPB(Protobuf.decode(buffer, WakuMessageKeyValuePB)))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decode*(
    T: type WakuMessageKeyValue, buffer: seq[byte]
): ProtobufResult[WakuMessageKeyValue] =
  decodeWakuMessageKeyValue(buffer)

proc decodeStoreQueryResponse(buffer: seq[byte]): ProtobufResult[StoreQueryResponse] =
  var pb: StoreQueryResponsePB
  try:
    pb = Protobuf.decode(buffer, StoreQueryResponsePB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  ok(
    StoreQueryResponse(
      requestId: pb.requestId,
      statusCode: pb.statusCode,
      statusDesc: pb.statusDesc,
      messages: pb.messages.mapIt(fromPB(it)),
      paginationCursor: pb.paginationCursor.map(
        proc(s: seq[byte]): WakuMessageHash =
          toHash(s)
      ),
    )
  )

proc decode*(
    T: type StoreQueryResponse, buffer: seq[byte]
): ProtobufResult[StoreQueryResponse] =
  decodeStoreQueryResponse(buffer)
