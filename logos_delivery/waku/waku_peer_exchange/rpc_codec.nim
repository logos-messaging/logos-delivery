{.push raises: [].}

import std/options
import ../common/protobuf, ./rpc

proc encode*(rpc: PeerExchangeRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.numPeers)
  pb.finish3()

  pb

proc decode*(T: type PeerExchangeRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeRequest(numPeers: 0)

  var numPeers: uint64
  if ?pb.getField(1, numPeers):
    rpc.numPeers = numPeers

  ok(rpc)

proc encode*(rpc: PeerExchangePeerInfo): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.enr)
  pb.finish3()

  pb

proc decode*(T: type PeerExchangePeerInfo, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangePeerInfo(enr: @[])

  var peerInfoBuffer: seq[byte]
  if ?pb.getField(1, peerInfoBuffer):
    rpc.enr = peerInfoBuffer

  ok(rpc)

proc parse*(T: type PeerExchangeResponseStatusCode, status: uint32): T =
  case status
  of 200, 400, 429, 503:
    cast[PeerExchangeResponseStatusCode](status)
  else:
    PeerExchangeResponseStatusCode.UNKNOWN

proc encode*(rpc: PeerExchangeResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  for pi in rpc.peerInfos:
    pb.write3(1, pi.encode())
  pb.write3(10, rpc.status_code.uint32)
  pb.write3(11, rpc.status_desc)

  pb.finish3()

  pb

proc decode*(T: type PeerExchangeResponse, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeResponse(peerInfos: @[])

  var peerInfoBuffers: seq[seq[byte]]
  if ?pb.getRepeatedField(1, peerInfoBuffers):
    for pib in peerInfoBuffers:
      rpc.peerInfos.add(?PeerExchangePeerInfo.decode(pib))

  var status_code: uint32
  if ?pb.getField(10, status_code):
    rpc.status_code = PeerExchangeResponseStatusCode.parse(status_code)
  else:
    # older peers may not support status_code field yet
    if rpc.peerInfos.len() > 0:
      rpc.status_code = PeerExchangeResponseStatusCode.SUCCESS
    else:
      rpc.status_code = PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE

  var status_desc: string
  if ?pb.getField(11, status_desc):
    rpc.status_desc = some(status_desc)
  else:
    rpc.status_desc = none(string)

  ok(rpc)

proc encode*(rpc: PeerExchangeRpc): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.request.encode())
  pb.write3(2, rpc.response.encode())

  pb.finish3()

  pb

proc decode*(T: type PeerExchangeRpc, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PeerExchangeRpc()

  var requestBuffer: seq[byte]
  if not ?pb.getField(1, requestBuffer):
    return err(ProtobufError.missingRequiredField("request"))

  rpc.request = ?PeerExchangeRequest.decode(requestBuffer)

  var responseBuffer: seq[byte]
  if not ?pb.getField(2, responseBuffer):
    rpc.response =
      PeerExchangeResponse(status_code: PeerExchangeResponseStatusCode.UNKNOWN)
  else:
    rpc.response = ?PeerExchangeResponse.decode(responseBuffer)

  ok(rpc)
