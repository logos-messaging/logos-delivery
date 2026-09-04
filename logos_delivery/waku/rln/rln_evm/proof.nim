{.push raises: [].}

import std/[times, sequtils]
import chronos, chronicles, results, stew/byteutils

import
  logos_delivery/waku/[
    rln/rln_evm/types,
    rln/rln_evm/protocol_types,
    rln/rln_evm/conversion_utils,
    rln/rln_evm/group_manager,
    rln/rln_evm/nonce_manager,
    waku_core,
  ]

proc calcEpoch*(rlnEvm: RlnEvm, t: float64): Epoch =
  ## gets time `t` as `flaot64` with subseconds resolution in the fractional part
  ## and returns its corresponding rln `Epoch` value

  let e = uint64(t / rlnEvm.rlnEpochSizeSec.float64)
  return toEpoch(e)

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

proc toRLNSignal*(wakumessage: WakuMessage): seq[byte] =
  ## it is a utility proc that prepares the `data` parameter of the proof generation procedure i.e., `proofGen`  that resides in the current module
  ## it extracts the `contentTopic`, `timestamp` and the `payload` of the supplied `wakumessage` and serializes them into a byte sequence

  let
    contentTopicBytes = toBytes(wakumessage.contentTopic)
    timestampBytes = toBytes(wakumessage.timestamp.uint64)
    output = concat(wakumessage.payload, contentTopicBytes, @(timestampBytes))
  return output

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
  let nonce = rlnEvm.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  return await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)

proc generateRLNProofWithRootRefresh*(
    rlnEvm: RlnEvm, input: seq[byte], senderEpochTime: float64
): Future[Result[seq[byte], string]] {.async.} =
  ## Generates an RLN proof and checks its merkle root against the
  ## acceptable-root window. If the root is stale, invalidates the cache and
  ## regenerates once against a refetched path. Returns the proof bytes.
  ##
  ## The regeneration reuses the nonce drawn for the first attempt: only the
  ## merkle path differs between the two, so drawing again would spend two
  ## message ids from the epoch budget on a message that is sent once. That
  ## would drift the budget the rate limit manager accounts for away from the
  ## one the nonce manager enforces.
  let nonce = rlnEvm.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)

  let proofBytes = (
    await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)
  ).valueOr:
    return err("failed to generate RLN proof: " & $error)

  let rlnProof = RateLimitProof.init(proofBytes).valueOr:
    return err("could not decode proof for root check: " & $error)

  if await rlnEvm.groupManager.validateRoot(rlnProof.merkleRoot):
    return ok(proofBytes)

  debug "RLN: stale merkle root detected; refreshing merkle path and regenerating proof"
  rlnEvm.groupManager.invalidateMerkleProofCache()
  return await rlnEvm.generateRLNProofWithNonce(input, senderEpochTime, nonce)

proc attachRLNProof*(
    rlnEvm: RlnEvm, message: WakuMessage
): Future[Result[WakuMessage, string]] {.async.} =
  ## Returns the message with a freshly generated RLN proof, replacing any
  ## existing one and drawing a new message id. Retry paths suspecting a stale
  ## path should call `invalidateMerkleProofCache` first.
  var msgWithProof = message
  msgWithProof.proof = (
    await rlnEvm.generateRLNProof(message.toRLNSignal(), float64(getTime().toUnix()))
  ).valueOr:
    return err("error in attachRLNProof: " & error)
  return ok(msgWithProof)

proc checkAndGenerateRLNProof*(
    rlnEvm: Opt[RlnEvm], message: WakuMessage
): Future[Result[WakuMessage, string]] {.async.} =
  ## Returns the message with an attached RLN proof, or unchanged when it
  ## already carries a proof or RLN is not configured.
  if message.proof.len > 0:
    return ok(message)

  if rlnEvm.isNone():
    debug "Publishing message without RLN proof"
    return ok(message)

  return await attachRLNProof(rlnEvm.get(), message)
