{.used.}

import std/options, testutils/unittests, chronos
import
  waku/[
    common/protobuf,
    common/paging,
    waku_core,
    waku_store_legacy/rpc,
    waku_store_legacy/rpc_codec,
  ],
  ../testlib/wakucore

procSuite "Waku Store - RPC codec":
  test "PagingIndexRPC protobuf codec":
    ## Given
    let index = PagingIndexRPC.compute(
      fakeWakuMessage(), receivedTime = ts(), pubsubTopic = DefaultPubsubTopic
    )

    ## When
    let encodedIndex = index.encode()
    let decodedIndexRes = PagingIndexRPC.decode(encodedIndex.buffer)

    ## Then
    check:
      decodedIndexRes.isOk()

    let decodedIndex = decodedIndexRes.tryGet()
    check:
      # The fields of decodedIndex must be the same as the original index
      decodedIndex == index

  test "PagingIndexRPC protobuf codec - empty index":
    ## Given
    let emptyIndex = PagingIndexRPC()

    let encodedIndex = emptyIndex.encode()
    let decodedIndexRes = PagingIndexRPC.decode(encodedIndex.buffer)

    ## Then
    check:
      decodedIndexRes.isOk()

    let decodedIndex = decodedIndexRes.tryGet()
    check:
      # Check the correctness of init and encode for an empty PagingIndexRPC
      decodedIndex == emptyIndex

  test "PagingInfoRPC protobuf codec":
    ## Given
    let
      index = PagingIndexRPC.compute(
        fakeWakuMessage(), receivedTime = ts(), pubsubTopic = DefaultPubsubTopic
      )
      pagingInfo = PagingInfoRPC(
        pageSize: some(1'u64),
        cursor: some(index),
        direction: some(PagingDirection.FORWARD),
      )

    ## When
    let pb = pagingInfo.encode()
    let decodedPagingInfo = PagingInfoRPC.decode(pb.buffer)

    ## Then
    check:
      decodedPagingInfo.isOk()

    check:
      # The fields of decodedPagingInfo must be the same as the original pagingInfo
      decodedPagingInfo.value == pagingInfo
      decodedPagingInfo.value.direction == pagingInfo.direction

  test "PagingInfoRPC protobuf codec - empty paging info":
    ## Given
    let emptyPagingInfo = PagingInfoRPC()

    ## When
    let pb = emptyPagingInfo.encode()
    let decodedEmptyPagingInfo = PagingInfoRPC.decode(pb.buffer)

    ## Then
    check:
      decodedEmptyPagingInfo.isOk()

    check:
      # check the correctness of init and encode for an empty PagingInfoRPC
      decodedEmptyPagingInfo.value == emptyPagingInfo

  test "HistoryQueryRPC protobuf codec":
    ## Given
    let
      index = PagingIndexRPC.compute(
        fakeWakuMessage(), receivedTime = ts(), pubsubTopic = DefaultPubsubTopic
      )
      pagingInfo = PagingInfoRPC(
        pageSize: some(1'u64),
        cursor: some(index),
        direction: some(PagingDirection.BACKWARD),
      )
      query = HistoryQueryRPC(
        contentFilters: @[
          HistoryContentFilterRPC(contentTopic: DefaultContentTopic),
          HistoryContentFilterRPC(contentTopic: DefaultContentTopic),
        ],
        pagingInfo: some(pagingInfo),
        startTime: some(Timestamp(10)),
        endTime: some(Timestamp(11)),
      )

    ## When
    let pb = query.encode()
    let decodedQuery = HistoryQueryRPC.decode(pb.buffer)

    ## Then
    check:
      decodedQuery.isOk()

    check:
      # the fields of decoded query decodedQuery must be the same as the original query query
      decodedQuery.value == query

  test "HistoryQueryRPC protobuf codec - empty history query":
    ## Given
    let emptyQuery = HistoryQueryRPC()

    ## When
    let pb = emptyQuery.encode()
    let decodedEmptyQuery = HistoryQueryRPC.decode(pb.buffer)

    ## Then
    check:
      decodedEmptyQuery.isOk()

    check:
      # check the correctness of init and encode for an empty HistoryQueryRPC
      decodedEmptyQuery.value == emptyQuery

  test "HistoryResponseRPC protobuf codec":
    ## Given
    let
      message = fakeWakuMessage()
      index = PagingIndexRPC.compute(
        message, receivedTime = ts(), pubsubTopic = DefaultPubsubTopic
      )
      pagingInfo = PagingInfoRPC(
        pageSize: some(1'u64),
        cursor: some(index),
        direction: some(PagingDirection.BACKWARD),
      )
      res = HistoryResponseRPC(
        messages: @[message],
        pagingInfo: some(pagingInfo),
        error: HistoryResponseErrorRPC.INVALID_CURSOR,
      )

    ## When
    let pb = res.encode()
    let decodedRes = HistoryResponseRPC.decode(pb.buffer)

    ## Then
    check:
      decodedRes.isOk()

    check:
      # the fields of decoded response decodedRes must be the same as the original response res
      decodedRes.value == res

  test "HistoryResponseRPC protobuf codec - empty history response":
    ## Given
    let emptyRes = HistoryResponseRPC()

    ## When
    let pb = emptyRes.encode()
    let decodedEmptyRes = HistoryResponseRPC.decode(pb.buffer)

    ## Then
    check:
      decodedEmptyRes.isOk()

    check:
      # check the correctness of init and encode for an empty HistoryResponseRPC
      decodedEmptyRes.value == emptyRes
