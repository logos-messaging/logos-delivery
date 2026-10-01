{.push raises: [].}

## Message ids for RLN proofs.
##
## Every proof spends one message id from the epoch's budget of `nonceLimit`
## ids. Ids must be unique within an epoch: a message id reused under the
## same epoch reveals a second share of the sender's identity secret. The
## manager counts ids per absolute epoch index (`unixTime div epochSize`, the
## epoch the proof carries) and never moves back to an earlier epoch, so an
## epoch that has already been drawn from cannot hand out an id twice.

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

proc spent*(n: NonceManager, epochIndex: uint64): Nonce =
  ## Message ids drawn in `epochIndex`: zero for any epoch other than the
  ## current one, since the counter only ever holds the current epoch.
  if epochIndex != n.epochIndex:
    return 0
  return n.nextId
