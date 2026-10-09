{.used.}

import std/strutils, stew/byteutils
import results, testutils/unittests, chronos, metrics
import
  logos_delivery/waku/[
    common/paging,
    waku_core,
    waku_store/common,
    waku_store/protocol_metrics,
    waku_store/rpc_codec,
    common/protobuf,
  ],
  ../testlib/[wakucore, protobuf_errors]

proc keyValueOf(hashByte: byte, message: WakuMessage): WakuMessageKeyValue =
  ## A key-value with the hash `hashByte` 00 .. and the default pubsub topic.
  var hash: WakuMessageHash
  hash[0] = hashByte
  WakuMessageKeyValue(
    messageHash: hash,
    message: Opt.some(message),
    pubsubTopic: Opt.some(DefaultPubsubTopic),
  )

proc pageCursor(): WakuMessageHash =
  ## The cursor 03 00 .. of the test pages.
  result[0] = 3

proc pageOf(messages: varargs[WakuMessageKeyValue]): StoreQueryResponse =
  StoreQueryResponse(
    requestId: "r",
    statusCode: 200,
    statusDesc: "OK",
    messages: @messages,
    paginationCursor: Opt.some(pageCursor()),
  )

procSuite "Waku Store - RPC codec":
  test "StoreQueryRequest protobuf codec":
    ## Given
    let query = StoreQueryRequest(
      requestId: "0",
      includeData: true,
      pubsubTopic: Opt.some(DefaultPubsubTopic),
      contentTopics: @[DefaultContentTopic],
      startTime: Opt.some(Timestamp(10)),
      endTime: Opt.some(Timestamp(11)),
      messageHashes: @[],
      paginationCursor: Opt.none(WakuMessageHash),
      paginationForward: PagingDirection.FORWARD,
      paginationLimit: Opt.some(DefaultPageSize),
    )

    ## When
    let pb = query.encode()
    let decodedQuery = StoreQueryRequest.decode(pb)

    ## Then
    check:
      decodedQuery.isOk()

    check:
      # the fields of decoded query decodedQuery must be the same as the original query query
      decodedQuery.value == query

  test "StoreQueryRequest protobuf codec - empty history query":
    ## Given
    let emptyQuery = StoreQueryRequest(requestId: "r")

    ## When
    let pb = emptyQuery.encode()
    let decodedEmptyQuery = StoreQueryRequest.decode(pb)

    ## Then
    check:
      decodedEmptyQuery.isOk()

    check:
      # check the correctness of init and encode for an empty HistoryQueryRPC
      decodedEmptyQuery.value == emptyQuery

  test "StoreQueryRequest protobuf codec - unset pagination_forward is backward":
    ## Given a request as a proto3 client encodes it when paging backward:
    ## `pagination_forward = false` is the default and is left off the wire.
    ## The bytes are field 1 (`request_id`) with the value "req-1".
    let pb = @[byte 0x0a, 0x05, 0x72, 0x65, 0x71, 0x2d, 0x31]

    ## When
    let decoded = StoreQueryRequest.decode(pb)

    ## Then
    check:
      decoded.isOk()
      decoded.value.paginationForward == PagingDirection.BACKWARD

  test "StoreQueryRequest with all fields has the bytes of the minprotobuf codec":
    ## Given a request with all fields, and the bytes that the `minprotobuf`
    ## codec wrote for it
    var hash: WakuMessageHash
    hash[0] = 1
    let query = StoreQueryRequest(
      requestId: "r",
      includeData: true,
      pubsubTopic: Opt.some("/s"),
      contentTopics: @["/t"],
      startTime: Opt.some(Timestamp(1)),
      endTime: Opt.some(Timestamp(-1)),
      messageHashes: @[hash],
      paginationCursor: Opt.some(hash),
      paginationForward: PagingDirection.FORWARD,
      paginationLimit: Opt.some(uint64(2)),
    )
    let pb = hexToSeqByte(
      "0a0172100152022f735a022f7460026801a2012001" & "00".repeat(31) & "9a032001" &
        "00".repeat(31) & "a00301a80302"
    )

    ## When
    let decodedQuery = StoreQueryRequest.decode(pb)

    ## Then the decode gives the request, and the encode gives the bytes
    check:
      decodedQuery.isOk()
      decodedQuery.value == query
      query.encode() == pb

  test "StoreQueryResponse protobuf codec":
    ## Given
    let
      message = fakeWakuMessage()
      hash = computeMessageHash(DefaultPubsubTopic, message)
      keyValue = WakuMessageKeyValue(
        messageHash: hash,
        message: Opt.some(message),
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
      res = StoreQueryResponse(
        requestId: "1",
        statusCode: 200,
        statusDesc: "it's fine",
        messages: @[keyValue],
        paginationCursor: Opt.none(WakuMessageHash),
      )

    ## When
    let pb = res.encode()
    let decodedRes = StoreQueryResponse.decode(pb)

    ## Then
    check:
      decodedRes.isOk()

    check:
      # the fields of decoded response decodedRes must be the same as the original response res
      decodedRes.value == res

  test "StoreQueryResponse protobuf codec - empty history response":
    ## Given
    let emptyRes = StoreQueryResponse(requestId: "r", statusCode: 200)

    ## When
    let pb = emptyRes.encode()
    let decodedEmptyRes = StoreQueryResponse.decode(pb)

    ## Then
    check:
      decodedEmptyRes.isOk()

    check:
      # check the correctness of init and encode for an empty HistoryResponseRPC
      decodedEmptyRes.value == emptyRes

suite "Waku Store - request decode":
  test "a paging direction outside the enum decodes as backward":
    # Request id "r", and paging direction 2 in field 52.
    let res = StoreQueryRequest.decode(hexToSeqByte("0a0172a00302"))
    check:
      res.isOk()
      res.get(StoreQueryRequest()).paginationForward == PagingDirection.BACKWARD

suite "Waku Store - response page decode":
  test "a key-value without a message hash is not on the page":
    # Request id "r", status 200 "OK", and field 20 holds an empty key-value.
    let res = StoreQueryResponse.decode(hexToSeqByte("0a017250c8015a024f4ba20100"))
    check:
      res.isOk()
      res.get().messages.len == 0

  test "a key-value with a message and no pubsub topic keeps neither":
    let res = StoreQueryResponse.decode(
      hexToSeqByte(
        "0a017250c8015a024f4ba2012b0a2001" & "00".repeat(31) & "12070a010112022f74"
      )
    )
    check:
      res.isOk()
      res.get().messages.len == 1
      res.get().messages[0].message.isNone()
      res.get().messages[0].pubsubTopic.isNone()

  test "a key-value with a pubsub topic and no message keeps neither":
    let res = StoreQueryResponse.decode(
      hexToSeqByte("0a017250c8015a024f4ba201260a2001" & "00".repeat(31) & "1a022f74")
    )
    check:
      res.isOk()
      res.get().messages.len == 1
      res.get().messages[0].message.isNone()
      res.get().messages[0].pubsubTopic.isNone()

  test "a key-value with a message that the validator refuses is not on the page":
    let good = keyValueOf(1, fakeWakuMessage(contentTopic = "/a/1/b/c"))
    # A message without a content topic, which an older store node can hold.
    let bad = keyValueOf(2, WakuMessage(payload: @[byte 1]))
    let dropped = logos_delivery_store_errors.value([DroppedKeyValue])
    let res = StoreQueryResponse.decode(pageOf(good, bad).encode())
    check:
      res.isOk()
      res.get().messages == @[good]
      res.get().paginationCursor == Opt.some(pageCursor())
      logos_delivery_store_errors.value([DroppedKeyValue]) == dropped + 1

  test "a key-value with a content topic that is not valid UTF-8 is not on the page":
    let good = keyValueOf(1, fakeWakuMessage(contentTopic = "/a/1/b/c"))
    # A second key-value in field 20. It has the hash 02 00 .., a message with
    # the content topic bytes ff 74, and the pubsub topic "/t".
    let bad = "0a2002" & "00".repeat(31) & "12041202ff741a022f74"
    let res =
      StoreQueryResponse.decode(pageOf(good).encode() & hexToSeqByte("a2012c" & bad))
    check:
      res.isOk()
      res.get().messages == @[good]
      res.get().paginationCursor == Opt.some(pageCursor())

suite "Waku Store - required fields":
  test "a query without a request id is refused":
    let res = StoreQueryRequest.decode(StoreQueryRequest(includeData: true).encode())
    check:
      res.isErr()
      res.error == ProtobufError.missingRequiredField("request_id")

  test "a response without a request id or a status code is refused":
    let noId = StoreQueryResponse.decode(StoreQueryResponse(statusCode: 200).encode())
    let noCode = StoreQueryResponse.decode(StoreQueryResponse(requestId: "r").encode())
    check:
      noId.isErr()
      noId.error == ProtobufError.missingRequiredField("request_id")
      noCode.isErr()
      noCode.error == ProtobufError.missingRequiredField("status_code")
