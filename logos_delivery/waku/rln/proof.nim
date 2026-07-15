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
    rln: Rln, input: seq[byte], senderEpochTime: float64
): Future[Result[seq[byte], string]] {.async.} =
  let epoch = rln.calcEpoch(senderEpochTime)
  let nonce = rln.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  let proof = (await rln.groupManager.generateProof(input, epoch, nonce)).valueOr:
    return err("could not generate rln-v2 proof: " & $error)
  return ok(proof.encode().buffer)

proc generateRLNProofWithRootRefresh*(
    rln: Rln, input: seq[byte], senderEpochTime: float64
): Future[Result[seq[byte], string]] {.async.} =
  ## Generates an RLN proof and checks its merkle root against the
  ## acceptable-root window. If the root is stale, invalidates the cache and
  ## regenerates once against a refetched path. Returns the proof bytes.
  let proofBytes = (await rln.generateRLNProof(input, senderEpochTime)).valueOr:
    return err("failed to generate RLN proof: " & $error)

  let rlnProof = RateLimitProof.init(proofBytes).valueOr:
    return err("could not decode proof for root check: " & $error)

  if await rln.groupManager.validateRoot(rlnProof.merkleRoot):
    return ok(proofBytes)

  info "RLN: stale merkle root detected; refreshing merkle path and regenerating proof"
  rln.groupManager.invalidateMerkleProofCache()
  return await rln.generateRLNProof(input, senderEpochTime)

proc attachRLNProof*(
    r: Rln, message: WakuMessage
): Future[Result[WakuMessage, string]] {.async.} =
  ## Returns the message with a freshly generated RLN proof, replacing any
  ## existing one and drawing a new message id. Retry paths suspecting a stale
  ## path should call `invalidateMerkleProofCache` first.
  let msgWithProof = message.clone()
  msgWithProof.proof = (
    await r.generateRLNProof(message.toRLNSignal(), float64(getTime().toUnix()))
  ).valueOr:
    return err("error in attachRLNProof: " & error)
  return ok(msgWithProof)

proc checkAndGenerateRLNProof*(
    rln: Option[Rln], message: WakuMessage
): Future[Result[WakuMessage, string]] {.async.} =
  ## Returns the message with an attached RLN proof, or unchanged when it
  ## already carries a proof or RLN is not configured.
  if message.proof.len > 0:
    return ok(message)

  if rln.isNone():
    notice "Publishing message without RLN proof"
    return ok(message)

  return await attachRLNProof(rln.get(), message)
