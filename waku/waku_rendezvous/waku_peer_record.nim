import std/times, sugar

import
  libp2p/[
    protocols/rendezvous,
    signed_envelope,
    multicodec,
    multiaddress,
    protobuf/minprotobuf,
    peerid,
  ]

type WakuPeerRecord* = object
  # Considering only mix as of now, but we can keep extending this to include all capabilities part of Waku ENR
  peerId*: PeerId
  seqNo*: uint64
  addresses*: seq[MultiAddress]
  mixKey*: string

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

proc decode*(
    T: typedesc[WakuPeerRecord], buffer: seq[byte]
): Result[WakuPeerRecord, ProtoError] =
  let pb = initProtoBuffer(buffer)
  var record = WakuPeerRecord()

  ?pb.getRequiredField(1, record.peerId)
  ?pb.getRequiredField(2, record.seqNo)
  discard ?pb.getRepeatedField(3, record.addresses)

  if record.addresses.len == 0:
    return err(ProtoError.RequiredFieldMissing)

  ?pb.getRequiredField(4, record.mixKey)

  return ok(record)

proc encode*(record: WakuPeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    pb.write(3, address)

  pb.write(4, record.mixKey)

  pb.finish()
  return pb.buffer

proc checkWakuPeerRecord*(
    _: WakuPeerRecord, spr: seq[byte], peerId: PeerId
): Result[void, string] {.gcsafe.} =
  if spr.len == 0:
    return err("Empty peer record")
  let signedEnv = ?SignedPayload[WakuPeerRecord].decode(spr).mapErr(x => $x)
  if signedEnv.data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()
