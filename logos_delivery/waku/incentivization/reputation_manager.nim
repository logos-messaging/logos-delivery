import tables, std/options
import ../waku_lightpush_legacy/rpc

type
  PeerId = string

  ResponseQuality* = enum
    BadResponse
    GoodResponse

  # Encode reputation indicator as Option[bool]:
  #   some(true)  => GoodRep
  #   some(false) => BadRep
  #   none(bool)  => unknown / not set
  ReputationManager* = ref object
    reputationOf*: Table[PeerId, Option[bool]]

proc init*(T: type ReputationManager): ReputationManager =
  return ReputationManager(reputationOf: initTable[PeerId, Option[bool]]())

proc setReputation*(
    manager: var ReputationManager, peer: PeerId, repValue: Option[bool]
) =
  manager.reputationOf[peer] = repValue

proc getReputation*(manager: ReputationManager, peer: PeerId): Option[bool] =
  if peer in manager.reputationOf:
    result = manager.reputationOf[peer]
  else:
    result = none(bool)

# Evaluate the quality of a PushResponse by checking its isSuccess field
proc evaluateResponse*(response: PushResponse): ResponseQuality =
  if response.isSuccess:
    return GoodResponse
  else:
    return BadResponse

# Update reputation of the peer based on the quality of the response
proc updateReputationFromResponse*(
    manager: var ReputationManager, peer: PeerId, response: PushResponse
) =
  let respQuality = evaluateResponse(response)
  case respQuality
  of BadResponse:
    manager.setReputation(peer, some(false)) # false => BadRep
  of GoodResponse:
    manager.setReputation(peer, some(true)) # true  => GoodRep
