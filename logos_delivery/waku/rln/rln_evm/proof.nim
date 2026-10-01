{.push raises: [].}

import std/times
import chronos, chronicles, results

import
  logos_delivery/waku/[
    rln/rln_evm/types,
    rln/rln_evm/protocol_types,
    rln/rln_evm/conversion_utils,
    rln/rln_evm/group_manager,
    rln/rln_evm/nonce_manager,
  ]
import logos_delivery/waku/rln/types as rln_api_types
import ../signal

export signal

proc epochIndexOf*(rlnEvm: RlnEvm, t: float64): uint64 =
  ## Absolute epoch index of time `t` (Unix seconds, fractional part holds
  ## sub-seconds): `t div epochSize`.
  uint64(t / rlnEvm.rlnEpochSizeSec.float64)

proc calcEpoch*(rlnEvm: RlnEvm, t: float64): Epoch =
  ## The rln `Epoch` value of time `t`, see `epochIndexOf`.
  toEpoch(rlnEvm.epochIndexOf(t))

proc checkTimestampBounds(
    rlnEvm: RlnEvm, senderEpochTime: float64
): Result[void, RlnError] =
  ## The bound validators apply (`validateMessage`): every receiver rejects
  ## a proof for a time more than `rlnMaxTimestampGap` from its clock, and
  ## reserving an id for such a time would move the counter into an epoch
  ## that has not arrived. Caller-supplied timestamps reach the generators
  ## over REST and lightpush.
  let gap = uint64(abs(epochTime() - senderEpochTime))
  if gap > rlnEvm.rlnMaxTimestampGap:
    return err(
      RlnError.permanent(
        "timestamp is " & $gap & " s from now, beyond the accepted " &
          $rlnEvm.rlnMaxTimestampGap & " s"
      )
    )
  return ok()

proc nextEpoch*(rlnEvm: RlnEvm, time: float64): float64 =
  let
    currentEpoch = uint64(time / rlnEvm.rlnEpochSizeSec.float64)
    nextEpochTime = float64(currentEpoch + 1) * rlnEvm.rlnEpochSizeSec.float64
    currentTime = epochTime()

  # Ensure we always return a future time
  if nextEpochTime > currentTime:
    return nextEpochTime
  else:
    return epochTime()

proc getCurrentEpoch*(rlnEvm: RlnEvm): Epoch =
  return rlnEvm.calcEpoch(epochTime())

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

proc generateRLNProofWithNonce(
    rlnEvm: RlnEvm, input: seq[byte], senderEpochTime: float64, nonce: Nonce
): Future[Result[seq[byte], string]] {.async: (raises: []).} =
  ## Generates a proof against an already drawn `nonce`. Regenerating for an
  ## unchanged (input, epoch, nonce) is safe: the revealed share is a function
  ## of those three, so a regenerated proof reveals the same share and cannot
  ## read as double-signalling.
  let epoch = rlnEvm.calcEpoch(senderEpochTime)
  try:
    let proof = (await rlnEvm.groupManager.generateProof(input, epoch, nonce)).valueOr:
      return err("could not generate rln-v2 proof: " & $error)
    return ok(proof.encode().buffer)
  except CatchableError as e:
    return err("exception generating rln proof: " & e.msg)

proc generateRLNProof*(
    rlnEvm: RlnEvm, input: seq[byte], senderEpochTime: float64
): Future[Result[seq[byte], string]] {.async: (raises: []).} =
  ## Draws a message id from the epoch of `senderEpochTime`, the epoch the
  ## proof carries, and builds the proof.
  rlnEvm.checkTimestampBounds(senderEpochTime).isOkOr:
    return err($error)
  let nonce = rlnEvm.nonceManager.reserve(rlnEvm.epochIndexOf(senderEpochTime)).valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  return await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)

proc generateRLNProofWithRootRefresh*(
    rlnEvm: RlnEvm, input: seq[byte], senderEpochTime: float64
): Future[Result[seq[byte], RlnError]] {.async.} =
  ## Generates an RLN proof and checks its merkle root against the
  ## acceptable-root window. If the root is stale, invalidates the cache and
  ## regenerates once against a refetched path. Returns the proof bytes.
  ##
  ## The message id is drawn from the epoch of `senderEpochTime`, the epoch
  ## the proof carries, once the time is within the validators' bound. A
  ## spent epoch budget is `BudgetExhausted`; a time out of bounds or an
  ## epoch the manager has already moved past is `Permanent`, since no later
  ## retry can prove it.
  ##
  ## The regeneration reuses the nonce drawn for the first attempt: only the
  ## merkle path differs between the two, so drawing again would spend two
  ## message ids from the epoch budget on a message that is sent once. That
  ## would drift the budget the rate limit manager accounts for away from the
  ## one the nonce manager enforces.
  ?rlnEvm.checkTimestampBounds(senderEpochTime)
  let nonce = ?rlnEvm.nonceManager.reserve(rlnEvm.epochIndexOf(senderEpochTime))

  let proofBytes = (
    await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)
  ).valueOr:
    return err(RlnError.transient("failed to generate RLN proof: " & error))

  let rlnProof = RateLimitProof.init(proofBytes).valueOr:
    return err(RlnError.transient("could not decode proof for root check: " & $error))

  if await rlnEvm.groupManager.validateRoot(rlnProof.merkleRoot):
    return ok(proofBytes)

  debug "RLN: stale merkle root detected; refreshing merkle path and regenerating proof"
  rlnEvm.groupManager.invalidateMerkleProofCache()
  let refreshed = (
    await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)
  ).valueOr:
    return err(RlnError.transient("failed to regenerate RLN proof: " & error))
  return ok(refreshed)
