import std/times
import confutils, chronicles, chronos, results
import protobuf_serialization, protobuf_serialization/pkg/results

import logos_delivery/waku/[waku_core, common/protobuf]

export times, confutils, chronicles, chronos, results, waku_core, protobuf

type SerializedKey* = seq[byte]

type WakuStealthCommitmentMsg* = object
  request*: bool
  spendingPubKey*: Opt[SerializedKey]
  viewingPubKey*: Opt[SerializedKey]
  ephemeralPubKey*: Opt[SerializedKey]
  stealthCommitment*: Opt[SerializedKey]
  viewTag*: Opt[uint64]

type WakuStealthCommitmentMsgPB {.proto2.} = object
  request {.fieldNumber: 1, pint.}: Opt[uint64]
  spendingPubKey {.fieldNumber: 2.}: Opt[seq[byte]]
  viewingPubKey {.fieldNumber: 3.}: Opt[seq[byte]]
  stealthCommitment {.fieldNumber: 4.}: Opt[seq[byte]]
  ephemeralPubKey {.fieldNumber: 5.}: Opt[seq[byte]]
  viewTag {.fieldNumber: 6, pint.}: Opt[uint64]

proc nonEmptyKey(o: Opt[seq[byte]]): Opt[SerializedKey] =
  if o.isSome() and o.get().len > 0:
    o
  else:
    Opt.none(SerializedKey)

proc decode*(T: type WakuStealthCommitmentMsg, buffer: seq[byte]): ProtobufResult[T] =
  var pb: WakuStealthCommitmentMsgPB
  try:
    pb = Protobuf.decode(buffer, WakuStealthCommitmentMsgPB)
  except SerializationError:
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  var msg = WakuStealthCommitmentMsg()
  msg.request = pb.request.get(0'u64) == 1
  msg.spendingPubKey = nonEmptyKey(pb.spendingPubKey)
  msg.viewingPubKey = nonEmptyKey(pb.viewingPubKey)

  if msg.spendingPubKey.isSome() and msg.viewingPubKey.isSome():
    msg.stealthCommitment = Opt.none(SerializedKey)
    msg.viewTag = Opt.none(uint64)
    return ok(msg)
  if msg.spendingPubKey.isSome() and msg.viewingPubKey.isNone():
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))
  if msg.spendingPubKey.isNone() and msg.viewingPubKey.isSome():
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))
  if msg.request == true and msg.spendingPubKey.isNone() and msg.viewingPubKey.isNone():
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  msg.stealthCommitment = nonEmptyKey(pb.stealthCommitment)
  msg.ephemeralPubKey = nonEmptyKey(pb.ephemeralPubKey)

  let viewTag = pb.viewTag.get(0'u64)
  msg.viewTag =
    if viewTag != 0:
      Opt.some(viewTag)
    else:
      Opt.none(uint64)

  if msg.stealthCommitment.isNone() and msg.viewTag.isNone() and
      msg.ephemeralPubKey.isNone():
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  if msg.stealthCommitment.isSome() and msg.viewTag.isNone():
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  if msg.stealthCommitment.isNone() and msg.viewTag.isSome():
    return err(protobuf.ProtobufError(kind: ProtobufErrorKind.DecodeFailure))

  if msg.stealthCommitment.isSome() and msg.viewTag.isSome():
    msg.spendingPubKey = Opt.none(SerializedKey)
    msg.viewingPubKey = Opt.none(SerializedKey)

  ok(msg)

proc encode*(msg: WakuStealthCommitmentMsg): seq[byte] =
  Protobuf.encode(
    WakuStealthCommitmentMsgPB(
      request: Opt.some(uint64(msg.request)),
      spendingPubKey: msg.spendingPubKey,
      viewingPubKey: msg.viewingPubKey,
      stealthCommitment: msg.stealthCommitment,
      ephemeralPubKey: msg.ephemeralPubKey,
      viewTag: msg.viewTag,
    )
  )

func toByteSeq*(str: string): seq[byte] {.inline.} =
  ## Converts a string to the corresponding byte sequence.
  @(str.toOpenArrayByte(0, str.high))

proc constructRequest*(
    spendingPubKey: SerializedKey, viewingPubKey: SerializedKey
): WakuStealthCommitmentMsg =
  WakuStealthCommitmentMsg(
    request: true,
    spendingPubKey: Opt.some(spendingPubKey),
    viewingPubKey: Opt.some(viewingPubKey),
  )

proc constructResponse*(
    stealthCommitment: SerializedKey, ephemeralPubKey: SerializedKey, viewTag: uint64
): WakuStealthCommitmentMsg =
  WakuStealthCommitmentMsg(
    request: false,
    stealthCommitment: Opt.some(stealthCommitment),
    ephemeralPubKey: Opt.some(ephemeralPubKey),
    viewTag: Opt.some(viewTag),
  )
