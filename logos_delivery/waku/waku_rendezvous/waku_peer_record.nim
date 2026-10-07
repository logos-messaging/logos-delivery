import std/times, sugar

import
  libp2p/[
    protocols/rendezvous,
    signed_envelope,
    multicodec,
    multiaddress,
    peerid,
    utils/shortlog,
  ]
import ../common/protobuf

type WakuPeerRecord* {.proto3.} = object
  # Considering only mix as of now, but we can keep extending this to include all capabilities part of Waku ENR
  peerId* {.fieldNumber: 1, ext.}: PeerId
  seqNo* {.fieldNumber: 2, pint.}: uint64
  addresses* {.fieldNumber: 3, ext.}: seq[MultiAddress]
  mixKey* {.fieldNumber: 4.}: string

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

proc validateDecoded(record: WakuPeerRecord): ProtobufResult[void] =
  if record.peerId.data.len == 0:
    return err(ProtobufError.missingRequiredField("peer_id"))
  if record.addresses.len == 0:
    return err(ProtobufError.missingRequiredField("addresses"))
  ok()

protobufCodec(WakuPeerRecord, validateDecoded)

proc checkWakuPeerRecord*(
    _: WakuPeerRecord, spr: seq[byte], peerId: PeerId
): Result[void, string] {.gcsafe.} =
  if spr.len == 0:
    return err("Empty peer record")
  let signedEnv = ?SignedPayload[WakuPeerRecord].decode(spr).mapErr(x => $x)
  if signedEnv.data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()
