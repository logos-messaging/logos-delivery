{.push raises: [].}

import std/sequtils, results
import protobuf_serialization, protobuf_serialization/pkg/results
import ../common/protobuf, ./rpc

type
  PeerExchangePeerInfoPB {.proto2.} = object
    enr {.fieldNumber: 1.}: Opt[seq[byte]]

  PeerExchangeRequestPB {.proto2.} = object
    numPeers {.fieldNumber: 1, pint.}: Opt[uint64]

  PeerExchangeResponsePB {.proto2.} = object
    peerInfos {.fieldNumber: 1.}: seq[PeerExchangePeerInfoPB]
    statusCode {.fieldNumber: 10, pint.}: Opt[uint32]
    statusDesc {.fieldNumber: 11.}: Opt[string]

  PeerExchangeRpcPB {.proto2.} = object
    request {.fieldNumber: 1, required.}: PeerExchangeRequestPB
    response {.fieldNumber: 2.}: Opt[PeerExchangeResponsePB]

proc parse*(T: type PeerExchangeResponseStatusCode, status: uint32): T =
  case status
  of 200, 400, 429, 503:
    cast[PeerExchangeResponseStatusCode](status)
  else:
    PeerExchangeResponseStatusCode.UNKNOWN

proc toPB(pi: PeerExchangePeerInfo): PeerExchangePeerInfoPB =
  PeerExchangePeerInfoPB(enr: Opt.some(pi.enr))

proc fromPB(pb: PeerExchangePeerInfoPB): PeerExchangePeerInfo =
  PeerExchangePeerInfo(enr: pb.enr.get(@[]))

proc toPB(req: PeerExchangeRequest): PeerExchangeRequestPB =
  PeerExchangeRequestPB(numPeers: Opt.some(req.numPeers))

proc fromPB(pb: PeerExchangeRequestPB): PeerExchangeRequest =
  PeerExchangeRequest(numPeers: pb.numPeers.get(0'u64))

proc toPB(res: PeerExchangeResponse): PeerExchangeResponsePB =
  PeerExchangeResponsePB(
    peerInfos: res.peerInfos.mapIt(toPB(it)),
    statusCode: Opt.some(uint32(ord(res.status_code))),
    statusDesc: res.status_desc,
  )

proc fromPB(pb: PeerExchangeResponsePB): PeerExchangeResponse =
  let peerInfos = pb.peerInfos.mapIt(fromPB(it))
  let statusCode =
    if pb.statusCode.isSome():
      PeerExchangeResponseStatusCode.parse(pb.statusCode.get())
    elif peerInfos.len() > 0:
      # older peers may not support the status_code field yet
      PeerExchangeResponseStatusCode.SUCCESS
    else:
      PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE
  PeerExchangeResponse(
    peerInfos: peerInfos, status_code: statusCode, status_desc: pb.statusDesc
  )

proc encode*(rpc: PeerExchangeRequest): seq[byte] =
  Protobuf.encode(toPB(rpc))

proc encode*(rpc: PeerExchangePeerInfo): seq[byte] =
  Protobuf.encode(toPB(rpc))

proc encode*(rpc: PeerExchangeResponse): seq[byte] =
  Protobuf.encode(toPB(rpc))

proc encode*(rpc: PeerExchangeRpc): seq[byte] =
  Protobuf.encode(
    PeerExchangeRpcPB(
      request: toPB(rpc.request), response: Opt.some(toPB(rpc.response))
    )
  )

proc decodePeerExchangeRequest(buffer: seq[byte]): ProtobufResult[PeerExchangeRequest] =
  try:
    ok(fromPB(Protobuf.decode(buffer, PeerExchangeRequestPB)))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decodePeerExchangePeerInfo(
    buffer: seq[byte]
): ProtobufResult[PeerExchangePeerInfo] =
  try:
    ok(fromPB(Protobuf.decode(buffer, PeerExchangePeerInfoPB)))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decodePeerExchangeResponse(
    buffer: seq[byte]
): ProtobufResult[PeerExchangeResponse] =
  try:
    ok(fromPB(Protobuf.decode(buffer, PeerExchangeResponsePB)))
  except SerializationError:
    err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

proc decodePeerExchangeRpc(buffer: seq[byte]): ProtobufResult[PeerExchangeRpc] =
  var pb: PeerExchangeRpcPB
  try:
    pb = Protobuf.decode(buffer, PeerExchangeRpcPB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))
  let response =
    if pb.response.isSome():
      fromPB(pb.response.get())
    else:
      PeerExchangeResponse(status_code: PeerExchangeResponseStatusCode.UNKNOWN)
  ok(PeerExchangeRpc(request: fromPB(pb.request), response: response))

proc decode*(T: type PeerExchangeRequest, buffer: seq[byte]): ProtobufResult[T] =
  decodePeerExchangeRequest(buffer)

proc decode*(T: type PeerExchangePeerInfo, buffer: seq[byte]): ProtobufResult[T] =
  decodePeerExchangePeerInfo(buffer)

proc decode*(T: type PeerExchangeResponse, buffer: seq[byte]): ProtobufResult[T] =
  decodePeerExchangeResponse(buffer)

proc decode*(T: type PeerExchangeRpc, buffer: seq[byte]): ProtobufResult[T] =
  decodePeerExchangeRpc(buffer)
