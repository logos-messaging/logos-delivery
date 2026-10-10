import std/times
import confutils, chronicles, chronos, results

import logos_delivery/waku/[waku_core, common/protobuf]

export times, confutils, chronicles, chronos, results, waku_core, protobuf

type SerializedKey* = seq[byte]

type WakuStealthCommitmentMsg* {.proto3.} = object
  request* {.fieldNumber: 1.}: bool
  spendingPubKey* {.fieldNumber: 2.}: Opt[SerializedKey]
  viewingPubKey* {.fieldNumber: 3.}: Opt[SerializedKey]
  stealthCommitment* {.fieldNumber: 4.}: Opt[SerializedKey]
  ephemeralPubKey* {.fieldNumber: 5.}: Opt[SerializedKey]
  viewTag* {.fieldNumber: 6, pint.}: Opt[uint64]

proc validateDecoded(msg: WakuStealthCommitmentMsg): ProtobufResult[void] =
  let hasRequestKeys = msg.spendingPubKey.isSome() and msg.viewingPubKey.isSome()
  let hasResponseFields =
    msg.stealthCommitment.isSome() and msg.viewTag.isSome() and
    msg.ephemeralPubKey.isSome()
  if msg.request and not hasRequestKeys:
    return err(ProtobufError.missingRequiredField("spending_pub_key, viewing_pub_key"))
  if not msg.request and not hasResponseFields:
    return err(
      ProtobufError.missingRequiredField(
        "stealth_commitment, ephemeral_pub_key, view_tag"
      )
    )
  ok()

protobufCodec(WakuStealthCommitmentMsg, validateDecoded)

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
