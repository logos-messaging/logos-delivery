import std/[times, options]
import confutils, chronicles, chronos, results

import logos_delivery/waku/[waku_core, common/protobuf]
import libp2p/protobuf/minprotobuf

export
  times, options, confutils, chronicles, chronos, results, waku_core, protobuf,
  minprotobuf

type SerializedKey* = seq[byte]

type WakuStealthCommitmentMsg* = object
  request*: bool
  spendingPubKey*: Option[SerializedKey]
  viewingPubKey*: Option[SerializedKey]
  ephemeralPubKey*: Option[SerializedKey]
  stealthCommitment*: Option[SerializedKey]
  viewTag*: Option[uint64]

proc decode*(T: type WakuStealthCommitmentMsg, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuStealthCommitmentMsg()
  let pb = initProtoBuffer(buffer)

  var request: uint64
  discard ?pb.getField(1, request)
  msg.request = request == 1
  var spendingPubKey = newSeq[byte]()
  discard ?pb.getField(2, spendingPubKey)
  msg.spendingPubKey =
    if spendingPubKey.len > 0:
      some(spendingPubKey)
    else:
      none(SerializedKey)
  var viewingPubKey = newSeq[byte]()
  discard ?pb.getField(3, viewingPubKey)
  msg.viewingPubKey =
    if viewingPubKey.len > 0:
      some(viewingPubKey)
    else:
      none(SerializedKey)

  if msg.spendingPubKey.isSome() and msg.viewingPubKey.isSome():
    msg.stealthCommitment = none(SerializedKey)
    msg.viewTag = none(uint64)
    return ok(msg)
  if msg.spendingPubKey.isSome() and msg.viewingPubKey.isNone():
    return err(ProtoError.RequiredFieldMissing)
  if msg.spendingPubKey.isNone() and msg.viewingPubKey.isSome():
    return err(ProtoError.RequiredFieldMissing)
  if msg.request == true and msg.spendingPubKey.isNone() and msg.viewingPubKey.isNone():
    return err(ProtoError.RequiredFieldMissing)

  var stealthCommitment = newSeq[byte]()
  discard ?pb.getField(4, stealthCommitment)
  msg.stealthCommitment =
    if stealthCommitment.len > 0:
      some(stealthCommitment)
    else:
      none(SerializedKey)

  var ephemeralPubKey = newSeq[byte]()
  discard ?pb.getField(5, ephemeralPubKey)
  msg.ephemeralPubKey =
    if ephemeralPubKey.len > 0:
      some(ephemeralPubKey)
    else:
      none(SerializedKey)

  var viewTag: uint64
  discard ?pb.getField(6, viewTag)
  msg.viewTag =
    if viewTag != 0:
      some(viewTag)
    else:
      none(uint64)

  if msg.stealthCommitment.isNone() and msg.viewTag.isNone() and
      msg.ephemeralPubKey.isNone():
    return err(ProtoError.RequiredFieldMissing)

  if msg.stealthCommitment.isSome() and msg.viewTag.isNone():
    return err(ProtoError.RequiredFieldMissing)

  if msg.stealthCommitment.isNone() and msg.viewTag.isSome():
    return err(ProtoError.RequiredFieldMissing)

  if msg.stealthCommitment.isSome() and msg.viewTag.isSome():
    msg.spendingPubKey = none(SerializedKey)
    msg.viewingPubKey = none(SerializedKey)

  ok(msg)

proc encode*(msg: WakuStealthCommitmentMsg): ProtoBuffer =
  var serialised = initProtoBuffer()

  serialised.write(1, uint64(msg.request))

  if msg.spendingPubKey.isSome():
    serialised.write(2, msg.spendingPubKey.get())
  if msg.viewingPubKey.isSome():
    serialised.write(3, msg.viewingPubKey.get())
  if msg.stealthCommitment.isSome():
    serialised.write(4, msg.stealthCommitment.get())
  if msg.ephemeralPubKey.isSome():
    serialised.write(5, msg.ephemeralPubKey.get())
  if msg.viewTag.isSome():
    serialised.write(6, msg.viewTag.get())

  return serialised

func toByteSeq*(str: string): seq[byte] {.inline.} =
  ## Converts a string to the corresponding byte sequence.
  @(str.toOpenArrayByte(0, str.high))

proc constructRequest*(
    spendingPubKey: SerializedKey, viewingPubKey: SerializedKey
): WakuStealthCommitmentMsg =
  WakuStealthCommitmentMsg(
    request: true,
    spendingPubKey: some(spendingPubKey),
    viewingPubKey: some(viewingPubKey),
  )

proc constructResponse*(
    stealthCommitment: SerializedKey, ephemeralPubKey: SerializedKey, viewTag: uint64
): WakuStealthCommitmentMsg =
  WakuStealthCommitmentMsg(
    request: false,
    stealthCommitment: some(stealthCommitment),
    ephemeralPubKey: some(ephemeralPubKey),
    viewTag: some(viewTag),
  )
