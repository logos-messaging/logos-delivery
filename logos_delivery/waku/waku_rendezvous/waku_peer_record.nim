import std/times, sugar

import protobuf_serialization, protobuf_serialization/pkg/results
import libp2p/[protocols/rendezvous, signed_envelope, multicodec, multiaddress, peerid]
import ../common/protobuf

type WakuPeerRecord* = object
  # Considering only mix as of now, but we can keep extending this to include all capabilities part of Waku ENR
  peerId*: PeerId
  seqNo*: uint64
  addresses*: seq[MultiAddress]
  mixKey*: string

type WakuPeerRecordPB {.proto2.} = object
  peerId {.fieldNumber: 1, ext, required.}: PeerId
  seqNo {.fieldNumber: 2, pint, required.}: uint64
  addresses {.fieldNumber: 3, ext.}: seq[MultiAddress]
  mixKey {.fieldNumber: 4, required.}: string

proc payloadDomain*(T: typedesc[WakuPeerRecord]): string =
  $multiCodec("libp2p-custom-peer-record")

proc payloadType*(T: typedesc[WakuPeerRecord]): seq[byte] =
  @[(byte) 0x30, (byte) 0x00, (byte) 0x00]

proc init*(
    T: typedesc[WakuPeerRecord],
    peerId: PeerId,
    seqNo = getTime().toUnix().uint64,
    addresses: seq[MultiAddress],
    mixKey: string,
): T =
  WakuPeerRecord(peerId: peerId, seqNo: seqNo, addresses: addresses, mixKey: mixKey)

proc decodeWakuPeerRecord(buffer: seq[byte]): ProtobufResult[WakuPeerRecord] =
  var pb: WakuPeerRecordPB
  try:
    pb = Protobuf.decode(buffer, WakuPeerRecordPB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  if pb.addresses.len == 0:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  ok(
    WakuPeerRecord(
      peerId: pb.peerId, seqNo: pb.seqNo, addresses: pb.addresses, mixKey: pb.mixKey
    )
  )

proc decode*(
    T: typedesc[WakuPeerRecord], buffer: seq[byte]
): ProtobufResult[WakuPeerRecord] =
  decodeWakuPeerRecord(buffer)

proc encode*(record: WakuPeerRecord): seq[byte] =
  Protobuf.encode(
    WakuPeerRecordPB(
      peerId: record.peerId,
      seqNo: record.seqNo,
      addresses: record.addresses,
      mixKey: record.mixKey,
    )
  )

proc checkWakuPeerRecord*(
    _: WakuPeerRecord, spr: seq[byte], peerId: PeerId
): Result[void, string] {.gcsafe.} =
  if spr.len == 0:
    return err("Empty peer record")
  let signedEnv = ?SignedPayload[WakuPeerRecord].decode(spr).mapErr(x => $x)
  if signedEnv.data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()
