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
  ## Generates an RLN proof and self-validates its merkle root against the
  ## acceptable-root window. If the cached path has slid out of that window
  ## (typical after a long inactivity or on-chain group churn), invalidates
  ## the local cache and regenerates the proof once — the next proof-gen
  ## sees an empty cache and refetches from chain. Returns the proof bytes
  ## the caller can attach to the message.
  let proofBytes = (await rln.generateRLNProof(input, senderEpochTime)).valueOr:
    return err("failed to generate RLN proof: " & $error)

  let rlnProof = RateLimitProof.init(proofBytes).valueOr:
    return err("could not decode proof for root check: " & $error)

  if await rln.groupManager.validateRoot(rlnProof.merkleRoot):
    return ok(proofBytes)

  info "RLN: stale merkle root detected; refreshing merkle path and regenerating proof"
  rln.groupManager.invalidateMerkleProofCache()
  return await rln.generateRLNProof(input, senderEpochTime)

proc checkAndGenerateRLNProof*(
    rln: Option[Rln], message: WakuMessage, regenerate: bool = false
): Future[Result[WakuMessage, string]] {.async.} =
  ## Returns the message with an attached RLN proof.
  ## Set `regenerate = true` to bypass the "already has proof" short-circuit
  ## and always generate a fresh proof — used by the retry path after a stale
  ## proof was rejected; the caller should first `invalidateMerkleProofCache`
  ## so the fresh proof is generated against a refetched merkle path.
  if message.proof.len > 0 and not regenerate:
    return ok(message)

  if rln.isNone():
    notice "Publishing message without RLN proof"
    return ok(message)

  let r = rln.get()
  let
    time = getTime().toUnix()
    senderEpochTime = float64(time)
    epoch = r.calcEpoch(senderEpochTime)
  let nonce = r.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  var msgWithProof = message
  let proof = (
    await r.groupManager.generateProof(msgWithProof.toRLNSignal(), epoch, nonce)
  ).valueOr:
    return err("error in checkAndGenerateRLNProof: " & $error)
  msgWithProof.proof = proof.encode().buffer
  return ok(msgWithProof)
