{.push raises: [].}

## Message ids for RLN proofs.
##
## Every proof spends one message id from the epoch's budget of `nonceLimit`
## ids. Ids must be unique among the proofs sent in an epoch: two sent proofs
## with the same message id in one epoch reveal two shares of the sender's
## identity secret, enough to recover it. The manager counts ids per absolute
## epoch index (`unixTime div epochSize`, the epoch the proof carries) and
## never moves back to an earlier epoch. An id is handed out a second time
## only after `release`, which the caller uses when the generation that drew
## the id built no proof.

import results
import logos_delivery/waku/rln/types

type
  Nonce* = uint64

  NonceManager* = ref object
    epochIndex*: uint64 ## Epoch the counter belongs to.
    nextId*: Nonce ## Next unused message id in `epochIndex`.
    nonceLimit*: Nonce ## Message ids available per epoch.

proc init*(T: type NonceManager, nonceLimit: Nonce): T =
  NonceManager(epochIndex: 0, nextId: 0, nonceLimit: nonceLimit)

proc restore*(n: NonceManager, epochIndex: uint64, nextId: Nonce) =
  ## Moves the counter to a state read back from storage: `nextId` ids already
  ## drawn in `epochIndex`. Applied only when that state is ahead of the
  ## counter (a later epoch, or more ids in the same epoch), so the counter
  ## never moves back over an id that may already be in a proof. A count
  ## above `nonceLimit` is clamped to it, so a corrupted row reads as a spent
  ## epoch, never as unused ids.
  if epochIndex > n.epochIndex or (epochIndex == n.epochIndex and nextId > n.nextId):
    n.epochIndex = epochIndex
    n.nextId = min(nextId, n.nonceLimit)

proc reserve*(n: NonceManager, epochIndex: uint64): Result[Nonce, RlnError] =
  ## Draws the next message id for `epochIndex`, the epoch the proof will carry.
  ## An epoch earlier than the latest one drawn from fails `Permanent`: only the
  ## latest epoch's count is kept, so ids already used in the earlier epoch are
  ## unknown. `BudgetExhausted` means all `nonceLimit` ids of the epoch are drawn.
  if epochIndex < n.epochIndex:
    return err(
      RlnError.permanent(
        "requested epoch " & $epochIndex & " is before the current epoch " &
          $n.epochIndex
      )
    )
  if epochIndex > n.epochIndex:
    n.epochIndex = epochIndex
    n.nextId = 0
  if n.nextId >= n.nonceLimit:
    return err(
      RlnError.budgetExhausted(
        "message ids for epoch " & $epochIndex & " are spent; limit: " & $n.nonceLimit
      )
    )
  let id = n.nextId
  n.nextId.inc()
  return ok(id)

proc release*(n: NonceManager, epochIndex: uint64, id: Nonce) =
  ## Returns `id` to the budget of `epochIndex` after the proof generation that
  ## drew it failed. The next `reserve` hands `id` out again, so the caller must
  ## not send any proof already built with it. Only the latest id drawn can be
  ## returned: once another reservation followed, or the counter moved to a
  ## later epoch, `id` stays spent.
  if epochIndex == n.epochIndex and id + 1 == n.nextId:
    n.nextId = id

proc spent*(n: NonceManager, epochIndex: uint64): Nonce =
  ## Message ids drawn in `epochIndex`: zero for any epoch other than the
  ## current one, since the counter only ever holds the current epoch.
  if epochIndex != n.epochIndex:
    return 0
  return n.nextId
