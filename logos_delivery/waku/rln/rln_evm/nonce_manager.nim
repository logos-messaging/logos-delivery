{.push raises: [].}

## Message ids for RLN proofs.
##
## Each epoch allows `nonceLimit` ids. Reusing an id in one epoch for a
## different message reveals the sender's identity secret, so ids are handed
## out in order, epochs only move forward, and an id is reissued only after
## `release`

import results
import logos_delivery/waku/rln/types

type
  Nonce* = uint64

  NonceManager* = ref object
    epochIndex*: uint64 ## Current epoch.
    nextId*: Nonce ##  Next id to hand out; also the count drawn this epoch.
    nonceLimit*: Nonce ## Message ids available per epoch.

proc init*(T: type NonceManager, nonceLimit: Nonce): T =
  NonceManager(epochIndex: 0, nextId: 0, nonceLimit: nonceLimit)

proc restore*(n: NonceManager, epochIndex: uint64, nextId: Nonce) =
  ## Loads a counter read back from storage, never moving the counter back.
  ## A count above `nonceLimit` is clamped, so a corrupt row reads as a spent epoch.
  if epochIndex > n.epochIndex or (epochIndex == n.epochIndex and nextId > n.nextId):
    n.epochIndex = epochIndex
    n.nextId = min(nextId, n.nonceLimit)

proc reserve*(n: NonceManager, epochIndex: uint64): Result[Nonce, RlnError] =
  ## Draws the next id for `epochIndex`. Fails `Permanent` for an earlier
  ## epoch (its used ids are unknown), `BudgetExhausted` when all are drawn.
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
  ## Returns `id` for reuse when no proof will carry it. Only the latest
  ## drawn id can be returned; otherwise this does nothing.
  if epochIndex == n.epochIndex and id + 1 == n.nextId:
    n.nextId = id

proc spent*(n: NonceManager, epochIndex: uint64): Nonce =
  ## Ids drawn in `epochIndex`; zero for any epoch but the current one.
  if epochIndex != n.epochIndex:
    return 0
  return n.nextId
