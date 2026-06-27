{.push raises: [].}

import std/tables
import chronicles, results

import ./types, ./protocol_types, ./conversion_utils, ./proof

logScope:
  topics = "waku rln nullifier_log"

proc hasDuplicate*(
    rlnPeer: Rln, epoch: Epoch, proofMetadata: ProofMetadata
): RlnResult[bool] =
  ## returns true if there is another message in the  `nullifierLog` of the `rlnPeer` with the same
  ## epoch and nullifier as `proofMetadata`'s epoch and nullifier
  ## otherwise, returns false
  ## Returns an error if it cannot check for duplicates

  # check if the epoch exists
  let nullifier = proofMetadata.nullifier
  if not rlnPeer.nullifierLog.hasKey(epoch):
    return ok(false)
  try:
    if rlnPeer.nullifierLog[epoch].hasKey(nullifier):
      # there is an identical record, mark it as spam
      return ok(true)

    # there is no duplicate
    return ok(false)
  except KeyError:
    return err("the epoch was not found: " & getCurrentExceptionMsg())

proc updateLog*(
    rlnPeer: Rln, epoch: Epoch, proofMetadata: ProofMetadata
): RlnResult[void] =
  ## saves supplied proofMetadata `proofMetadata`
  ## in the `nullifierLog` of the `rlnPeer`
  ## Returns an error if it cannot update the log

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKeyOrPut(
    epoch, {proofMetadata.nullifier: proofMetadata}.toTable()
  ):
    return ok()

  try:
    # check if an identical record exists
    if rlnPeer.nullifierLog[epoch].hasKeyOrPut(proofMetadata.nullifier, proofMetadata):
      # the above condition could be `discarded` but it is kept for clarity, that slashing will
      # be implemented here
      # TODO: slashing logic
      return ok()
    return ok()
  except KeyError:
    return
      err("the epoch was not found: " & getCurrentExceptionMsg()) # should never happen

proc clearNullifierLog*(rlnPeer: Rln) =
  # clear the first MaxEpochGap epochs of the nullifer log
  # if more than MaxEpochGap epochs are in the log
  let currentEpoch = fromEpoch(rlnPeer.getCurrentEpoch())

  var epochsToRemove: seq[Epoch] = @[]
  for epoch in rlnPeer.nullifierLog.keys():
    let epochInt = fromEpoch(epoch)

    # clean all epochs that are +- rlnMaxEpochGap from the current epoch
    if (currentEpoch + rlnPeer.rlnMaxEpochGap) <= epochInt or
        epochInt <= (currentEpoch - rlnPeer.rlnMaxEpochGap):
      epochsToRemove.add(epoch)

  for epochRemove in epochsToRemove:
    trace "clearing epochs from the nullifier log",
      currentEpoch = currentEpoch, cleanedEpoch = fromEpoch(epochRemove)
    rlnPeer.nullifierLog.del(epochRemove)
