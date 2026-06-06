{.used.}

import std/[options, sequtils, tables], testutils/unittests, chronos, chronicles
import
  logos_delivery/waku/waku_metadata,
  logos_delivery/waku/waku_metadata/rpc,
  ./testlib/wakucore,
  ./testlib/wakunode

procSuite "Waku Protobufs":
  # TODO: Missing test coverage in many encode/decode protobuf functions

  test "WakuMetadataResponse":
    let res = WakuMetadataResponse(clusterId: some(7), shards: @[10, 23, 33])

    let buffer = res.encode()

    let decodedBuff = WakuMetadataResponse.decode(buffer.buffer)
    check:
      decodedBuff.isOk()
      decodedBuff.get().clusterId.get() == res.clusterId.get()
      decodedBuff.get().shards == res.shards

  test "WakuMetadataRequest":
    let req = WakuMetadataRequest(clusterId: some(5), shards: @[100, 2, 0])

    let buffer = req.encode()

    let decodedBuff = WakuMetadataRequest.decode(buffer.buffer)
    check:
      decodedBuff.isOk()
      decodedBuff.get().clusterId.get() == req.clusterId.get()
      decodedBuff.get().shards == req.shards
