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
    rln/rln_evm/message_id_store,
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

proc ensureMessageIdsLoaded*(
    rlnEvm: RlnEvm
): Future[Result[void, RlnError]] {.async: (raises: [CancelledError]).} =
  ## Loads this identity's saved message id count on first use; no id may be
  ## drawn until this succeeds. Fails `Permanent` without a broker context,
  ## otherwise `NotReady`, and the next call retries.
  ##
  ## A count saved for an epoch ahead of the clock also sets `refusedUntil`:
  ## no ids are drawn until the clock reaches that epoch.
  if not rlnEvm.messageIdStore.isNil():
    return ok()

  let credentials = rlnEvm.groupManager.idCredentials.valueOr:
    return err(RlnError.notReady("no identity credential to key the message id store"))
  let brokerCtx = rlnEvm.brokerCtx.valueOr:
    return err(
      RlnError.permanent("mounted without a broker context, so no message id store")
    )
  let job = openMessageIdStore(brokerCtx).valueOr:
    debug "RLN message id store not available", error = error
    return err(RlnError.notReady("message id store not available: " & error))
  let key = messageIdKey(credentials.idSecretHash)
  let stored = (await job.loadMessageIds(key)).valueOr:
    debug "RLN message id store could not be read", error = error
    return err(RlnError.notReady("message id store could not be read: " & error))

  if stored.isSome():
    let row = stored.get()
    rlnEvm.nonceManager.restore(row.epochIndex, row.nextId)
    let now = epochTime()
    let currentEpoch = rlnEvm.epochIndexOf(now)
    if row.epochIndex > currentEpoch:
      rlnEvm.refusedUntil = row.epochIndex
      # Within the timestamp tolerance this is a message stamped early;
      # beyond it, the clock or the saved row is wrong.
      let rowEpochStart = float64(row.epochIndex) * float64(rlnEvm.rlnEpochSizeSec)
      if rowEpochStart - now > float64(rlnEvm.rlnMaxTimestampGap):
        warn "RLN message ids were last drawn in an epoch ahead of the clock; no ids are drawn until the clock reaches it. If the clock is right, deleting rln.db resets the counter",
          storedEpoch = row.epochIndex, currentEpoch = currentEpoch

  rlnEvm.messageIdStore = job
  rlnEvm.messageIdKey = key
  info "RLN message id store loaded"
  return ok()

proc reserveDurably(
    rlnEvm: RlnEvm, epochIndex: uint64
): Future[Result[Nonce, RlnError]] {.async: (raises: [CancelledError]).} =
  ## Draws a message id and saves the new count before returning it, so a
  ## restart never reissues an id already in a proof. Holds `reserveLock` so
  ## saves land in draw order. An unloaded store is `NotReady`; a failed save
  ## returns the id and is `Transient`.
  await rlnEvm.reserveLock.acquire()
  defer:
    try:
      rlnEvm.reserveLock.release()
    except AsyncLockError as e:
      error "RLN reserveLock released while not held", error = e.msg

  ?(await rlnEvm.ensureMessageIdsLoaded())
  let id = ?rlnEvm.nonceManager.reserve(epochIndex)
  (
    await rlnEvm.messageIdStore.saveMessageIds(
      rlnEvm.messageIdKey, epochIndex, rlnEvm.nonceManager.nextId
    )
  ).isOkOr:
    rlnEvm.nonceManager.release(epochIndex, id)
    return err(RlnError.transient("could not save the message id count: " & error))
  return ok(id)

proc releaseDurably(
    rlnEvm: RlnEvm, epochIndex: uint64, id: Nonce
) {.async: (raises: [CancelledError]).} =
  ## Returns `id` after a failed proof generation and saves the lowered count,
  ## unless another draw followed. A failed save is only logged: a higher
  ## stored count is safe, and at worst a restart skips the id.
  await rlnEvm.reserveLock.acquire()
  defer:
    try:
      rlnEvm.reserveLock.release()
    except AsyncLockError as e:
      error "RLN reserveLock released while not held", error = e.msg

  let before = rlnEvm.nonceManager.nextId
  rlnEvm.nonceManager.release(epochIndex, id)
  if rlnEvm.nonceManager.nextId == before:
    return
  (
    await rlnEvm.messageIdStore.saveMessageIds(
      rlnEvm.messageIdKey, epochIndex, rlnEvm.nonceManager.nextId
    )
  ).isOkOr:
    debug "RLN message id count not lowered in the store after a failed proof generation",
      error = error

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
): Future[Result[seq[byte], string]] {.async: (raises: [CancelledError]).} =
  ## Draws a message id for the epoch of `senderEpochTime`, saves the new
  ## count and builds the proof. A failed generation returns the id.
  rlnEvm.checkTimestampBounds(senderEpochTime).isOkOr:
    return err($error)
  let epochIndex = rlnEvm.epochIndexOf(senderEpochTime)
  let nonce = (await rlnEvm.reserveDurably(epochIndex)).valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  let proof = await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)
  if proof.isErr():
    await rlnEvm.releaseDurably(epochIndex, nonce)
  return proof

proc proveWithRootRefresh(
    rlnEvm: RlnEvm, input: seq[byte], senderEpochTime: float64, nonce: Nonce
): Future[Result[seq[byte], RlnError]] {.async.} =
  ## Generates a proof with `nonce`; if its merkle root is stale, refetches the
  ## merkle path and regenerates once. The retry reuses `nonce` so one message
  ## spends one id, matching what the rate limit manager counts.
  let proofBytes = (
    await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)
  ).valueOr:
    return err(RlnError.transient("failed to generate RLN proof: " & error))

  let rlnProof = RateLimitProof.init(proofBytes).valueOr:
    return err(RlnError.transient("could not decode proof for root check: " & $error))

  if await rlnEvm.groupManager.validateRoot(rlnProof.merkleRoot):
    return ok(proofBytes)

  debug "RLN: stale merkle root detected; refreshing merkle path and regenerating proof"
  rlnEvm.groupManager.scheduleMerkleProofRefresh()
  let refreshed = (
    await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)
  ).valueOr:
    return err(RlnError.transient("failed to regenerate RLN proof: " & error))
  return ok(refreshed)

proc generateRLNProofWithRootRefresh*(
    rlnEvm: RlnEvm, input: seq[byte], senderEpochTime: float64
): Future[Result[seq[byte], RlnError]] {.async.} =
  ## Generates an RLN proof with an acceptable merkle root (see
  ## `proveWithRootRefresh`), drawing and saving its message id first.
  ##
  ## Fails `Permanent` for a time out of bounds or an epoch already passed,
  ## `BudgetExhausted` when the epoch's ids are spent, `NotReady` when the store
  ## is not loaded, and `Transient` when the save or generation fails. A failed
  ## generation returns the id, so the retry reuses it.
  ?rlnEvm.checkTimestampBounds(senderEpochTime)
  let epochIndex = rlnEvm.epochIndexOf(senderEpochTime)
  let nonce = ?(await rlnEvm.reserveDurably(epochIndex))
  let proof = await rlnEvm.proveWithRootRefresh(input, senderEpochTime, nonce)
  if proof.isErr():
    await rlnEvm.releaseDurably(epochIndex, nonce)
  return proof
