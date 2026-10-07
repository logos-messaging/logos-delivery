{.used.}

import stew/byteutils
import results, testutils/unittests, chronos
import logos_delivery/waku/waku_metadata/rpc, ./testlib/wakucore

procSuite "Waku Protobufs":
  # TODO: Missing test coverage in many encode/decode protobuf functions

  test "WakuMetadataResponse":
    let res = WakuMetadataResponse(clusterId: Opt.some(7'u32), shards: @[10, 23, 33])

    let buffer = res.encode()

    let decodedBuff = WakuMetadataResponse.decode(buffer)
    check:
      decodedBuff.isOk()
      decodedBuff.get().clusterId.get() == res.clusterId.get()
      decodedBuff.get().shards == res.shards

  test "WakuMetadataRequest":
    let req = WakuMetadataRequest(clusterId: Opt.some(5'u32), shards: @[100, 2, 0])

    let buffer = req.encode()

    let decodedBuff = WakuMetadataRequest.decode(buffer)
    check:
      decodedBuff.isOk()
      decodedBuff.get().clusterId.get() == req.clusterId.get()
      decodedBuff.get().shards == req.shards

  test "Metadata encodes the shards once, packed, in field 2":
    let req = WakuMetadataRequest(clusterId: Opt.some(1'u32), shards: @[0'u32, 1, 2])
    let res = WakuMetadataResponse(clusterId: Opt.some(1'u32), shards: @[0'u32, 1, 2])
    check:
      req.encode() == hexToSeqByte("08011203000102")
      res.encode() == hexToSeqByte("08011203000102")

  test "Metadata reads unpacked shards in field 2 and ignores field 3":
    # Cluster 1, the shards 0, 1 and 2 unpacked in field 2, and the shard 7
    # packed in field 3.
    let bytes = hexToSeqByte("08011000100110021a0107")
    let req = WakuMetadataRequest.decode(bytes)
    let res = WakuMetadataResponse.decode(bytes)
    check:
      req.isOk()
      req.get().clusterId == Opt.some(1'u32)
      req.get().shards == @[0'u32, 1, 2]
      res.isOk()
      res.get().clusterId == Opt.some(1'u32)
      res.get().shards == @[0'u32, 1, 2]
