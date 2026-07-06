{.push raises: [].}

import std/[options, times, sequtils]
import chronos, chronicles, results, stew/byteutils

import ./types, ./protocol_types, ./conversion_utils, ./group_manager, ./nonce_manager

import logos_delivery/waku/waku_core

proc calcEpoch*(rln: Rln, t: float64): Epoch =
  ## gets time `t` as `flaot64` with subseconds resolution in the fractional part
  ## and returns its corresponding rln `Epoch` value

  let e = uint64(t / rln.rlnEpochSizeSec.float64)
  return toEpoch(e)

proc nextEpoch*(rln: Rln, time: float64): float64 =
  let
    currentEpoch = uint64(time / rln.rlnEpochSizeSec.float64)
    nextEpochTime = float64(currentEpoch + 1) * rln.rlnEpochSizeSec.float64
    currentTime = epochTime()

  # Ensure we always return a future time
  if nextEpochTime > currentTime:
    return nextEpochTime
  else:
    return epochTime()

proc getCurrentEpoch*(rln: Rln): Epoch =
  return rln.calcEpoch(epochTime())

proc absDiff*(e1, e2: Epoch): uint64 =
  ## returns the absolute difference between the two rln `Epoch`s `e1` and `e2`
  ## i.e., e1 - e2

  # convert epochs to their corresponding unsigned numerical values
  let
    epoch1 = fromEpoch(e1)
    epoch2 = fromEpoch(e2)

  # Manually perform an `abs` calculation
  if epoch1 > epoch2:
    return epoch1 - epoch2
  else:
    return epoch2 - epoch1

proc toRLNSignal*(wakumessage: WakuMessage): seq[byte] =
  ## it is a utility proc that prepares the `data` parameter of the proof generation procedure i.e., `proofGen`  that resides in the current module
  ## it extracts the `contentTopic`, `timestamp` and the `payload` of the supplied `wakumessage` and serializes them into a byte sequence

  let
    contentTopicBytes = toBytes(wakumessage.contentTopic)
    timestampBytes = toBytes(wakumessage.timestamp.uint64)
    output = concat(wakumessage.payload, contentTopicBytes, @(timestampBytes))
  return output

proc generateRLNProof*(
    rln: Rln,
    input: seq[byte],
    senderEpochTime: float64,
    forceMerkleProofRefresh: bool = false,
): Future[RlnResult[seq[byte]]] {.async.} =
  let epoch = rln.calcEpoch(senderEpochTime)
  let nonce = rln.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  let proof = (
    await rln.groupManager.generateProof(
      input, epoch, nonce, forceMerkleProofRefresh = forceMerkleProofRefresh
    )
  ).valueOr:
    return err("could not generate rln-v2 proof: " & $error)
  return ok(proof.encode().buffer)

proc checkAndGenerateRLNProof*(
    rln: Option[Rln],
    message: WakuMessage,
    forceMerkleProofRefresh: bool = false,
    reuseMessageId: Option[Nonce] = none(Nonce),
): Future[Result[tuple[msg: WakuMessage, messageId: Option[Nonce]], string]] {.async.} =
  ## Returns the message with an attached RLN proof and the message id drawn
  ## from the nonce manager (`messageId = none` when no id was consumed —
  ## message already had a valid proof, or RLN is not configured).
  ## Pass `messageId` back as `reuseMessageId` on a retry so the CAS rollback
  ## can reclaim it when no concurrent draw has advanced the counter.
  if message.proof.len > 0 and not forceMerkleProofRefresh:
    return ok((msg: message, messageId: none(Nonce)))

  if rln.isNone():
    notice "Publishing message without RLN proof"
    return ok((msg: message, messageId: none(Nonce)))

  let r = rln.get()
  if reuseMessageId.isSome():
    if not r.nonceManager.rollbackNonce(reuseMessageId.get()):
      # A concurrent draw advanced the counter past the rejected attempt's id;
      # the retry will consume a fresh message id instead of reusing the old one.
      debug "rln retry: concurrent draw prevented nonce reuse; consuming a fresh message id",
        attempted = reuseMessageId.get(), nextNonce = r.nonceManager.nextNonce

  let
    time = getTime().toUnix()
    senderEpochTime = float64(time)
    epoch = r.calcEpoch(senderEpochTime)
  let nonce = r.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  var msgWithProof = message
  let proof = (
    await r.groupManager.generateProof(
      msgWithProof.toRLNSignal(),
      epoch,
      nonce,
      forceMerkleProofRefresh = forceMerkleProofRefresh,
    )
  ).valueOr:
    return err("error in checkAndGenerateRLNProof: " & $error)
  msgWithProof.proof = proof.encode().buffer
  return ok((msg: msgWithProof, messageId: some(nonce)))
