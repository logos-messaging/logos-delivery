{.push raises: [].}

import std/[times, sequtils]
import chronos, results, stew/byteutils

import ./types, ./protocol_types, ./conversion_utils, ./group_manager, ./nonce_manager

import logos_delivery/waku/waku_core

proc calcEpoch*(rlnPeer: Rln, t: float64): Epoch =
  ## gets time `t` as `flaot64` with subseconds resolution in the fractional part
  ## and returns its corresponding rln `Epoch` value

  let e = uint64(t / rlnPeer.rlnEpochSizeSec.float64)
  return toEpoch(e)

proc nextEpoch*(rlnPeer: Rln, time: float64): float64 =
  let
    currentEpoch = uint64(time / rlnPeer.rlnEpochSizeSec.float64)
    nextEpochTime = float64(currentEpoch + 1) * rlnPeer.rlnEpochSizeSec.float64
    currentTime = epochTime()

  # Ensure we always return a future time
  if nextEpochTime > currentTime:
    return nextEpochTime
  else:
    return epochTime()

proc getCurrentEpoch*(rlnPeer: Rln): Epoch =
  return rlnPeer.calcEpoch(epochTime())

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
    rlnPeer: Rln, input: seq[byte], senderEpochTime: float64
): Future[RlnResult[seq[byte]]] {.async.} =
  let epoch = rlnPeer.calcEpoch(senderEpochTime)
  let nonce = rlnPeer.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  let proof = (await rlnPeer.groupManager.generateProof(input, epoch, nonce)).valueOr:
    return err("could not generate rln-v2 proof: " & $error)
  return ok(proof.encode().buffer)
