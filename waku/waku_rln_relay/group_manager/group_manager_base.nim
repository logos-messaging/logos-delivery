import ../../common/error_handling, ../protocol_types, ../protocol_metrics, ../constants

import options, chronos, results, std/[deques]

export options, chronos, results, protocol_types, protocol_metrics, deques

# This module contains the GroupManager interface
# The GroupManager is responsible for managing the group state
# It should be used to register new members, and withdraw existing members
# It should also be used to sync the group state with the rest of the group members

type Membership* = object
  index*: MembershipIndex
  rateCommitment*: RawRateCommitment

type OnRegisterCallback* = proc(registrations: seq[Membership]): Future[void] {.gcsafe.}
type OnWithdrawCallback* = proc(withdrawals: seq[Membership]): Future[void] {.gcsafe.}

type GroupManagerResult*[T] = Result[T, string]

type GroupManager* = ref object of RootObj
  idCredentials*: Option[IdentityCredential]
  membershipIndex*: Option[MembershipIndex]
  registerCb*: Option[OnRegisterCallback]
  withdrawCb*: Option[OnWithdrawCallback]
  rlnInstance*: ptr RLN
  initialized*: bool
  latestIndex*: MembershipIndex
  validRoots*: Deque[MerkleNode]
  onFatalErrorAction*: OnFatalErrorHandler
  userMessageLimit*: Option[UserMessageLimit]
  rlnRelayMaxMessageLimit*: uint64

# This proc is used to initialize the group manager
# Any initialization logic should be implemented here
method init*(g: GroupManager): Future[GroupManagerResult[void]] {.base, async.} =
  return err("init proc for " & $g.type & " is not implemented yet")

# This proc is used to start the group sync process
# It should be used to sync the group state with the rest of the group members
method startGroupSync*(
    g: GroupManager
): Future[GroupManagerResult[void]] {.base, async.} =
  return err("startGroupSync proc for " & $g.type & " is not implemented yet")

# This proc is used to register a new identity commitment into the merkle tree
# The user may or may not have the identity secret to this commitment
# It should be used when detecting new members in the group, and syncing the group state
method register*(
    g: GroupManager, rateCommitment: RateCommitment
): Future[void] {.base, async: (raises: [Exception]).} =
  raise newException(
    CatchableError, "register proc for " & $g.type & " is not implemented yet"
  )

# This proc is used to register a new identity commitment into the merkle tree
# The user should have the identity secret to this commitment
# It should be used when the user wants to join the group
method register*(
    g: GroupManager, credentials: IdentityCredential, userMessageLimit: UserMessageLimit
): Future[void] {.base, async: (raises: [Exception]).} =
  raise newException(
    CatchableError, "register proc for " & $g.type & " is not implemented yet"
  )

# This proc is used to register a batch of new identity commitments into the merkle tree
# The user may or may not have the identity secret to these commitments
# It should be used when detecting a batch of new members in the group, and syncing the group state
method registerBatch*(
    g: GroupManager, rateCommitments: seq[RawRateCommitment]
): Future[void] {.base, async: (raises: [Exception]).} =
  raise newException(
    CatchableError, "registerBatch proc for " & $g.type & " is not implemented yet"
  )

# This proc is used to set a callback that will be called when a new identity commitment is registered
# The callback may be called multiple times, and should be used to for any post processing
method onRegister*(g: GroupManager, cb: OnRegisterCallback) {.base, gcsafe.} =
  g.registerCb = some(cb)

# This proc is used to withdraw/remove an identity commitment from the merkle tree
# The user should have the identity secret hash to this commitment, by either deriving it, or owning it
method withdraw*(
    g: GroupManager, identitySecretHash: IdentitySecretHash
): Future[void] {.base, async: (raises: [Exception]).} =
  raise newException(
    CatchableError, "withdraw proc for " & $g.type & " is not implemented yet"
  )

# This proc is used to withdraw/remove a batch of identity commitments from the merkle tree
# The user should have the identity secret hash to these commitments, by either deriving them, or owning them
method withdrawBatch*(
    g: GroupManager, identitySecretHashes: seq[IdentitySecretHash]
): Future[void] {.base, async: (raises: [Exception]).} =
  raise newException(
    CatchableError, "withdrawBatch proc for " & $g.type & " is not implemented yet"
  )

# This proc is used to insert and remove a set of commitments from the merkle tree
method atomicBatch*(
    g: GroupManager,
    rateCommitments: seq[RateCommitment],
    toRemoveIndices: seq[MembershipIndex],
): Future[void] {.base, async: (raises: [Exception]).} =
  raise newException(
    CatchableError, "atomicBatch proc for " & $g.type & " is not implemented yet"
  )

method stop*(g: GroupManager): Future[void] {.base, async.} =
  raise
    newException(CatchableError, "stop proc for " & $g.type & " is not implemented yet")

# This proc is used to set a callback that will be called when an identity commitment is withdrawn
# The callback may be called multiple times, and should be used to for any post processing
method onWithdraw*(g: GroupManager, cb: OnWithdrawCallback) {.base, gcsafe.} =
  g.withdrawCb = some(cb)

method indexOfRoot*(
    g: GroupManager, root: MerkleNode
): int {.base, gcsafe, raises: [].} =
  ## returns the index of the root in the merkle tree and returns -1 if the root is not found
  return g.validRoots.find(root)

method validateRoot*(
    g: GroupManager, root: MerkleNode
): bool {.base, gcsafe, raises: [].} =
  ## validates the root against the valid roots queue
  return g.indexOfRoot(root) >= 0

method verifyProof*(
    g: GroupManager, input: seq[byte], proof: RateLimitProof
): GroupManagerResult[bool] {.base, gcsafe, raises: [].} =
  ## Dummy implementation for verifyProof
  return err("verifyProof is not implemented")

method generateProof*(
    g: GroupManager,
    data: seq[byte],
    epoch: Epoch,
    messageId: MessageId,
    rlnIdentifier = DefaultRlnIdentifier,
): GroupManagerResult[RateLimitProof] {.base, gcsafe, raises: [].} =
  ## Dummy implementation for generateProof
  return err("generateProof is not implemented")

method isReady*(g: GroupManager): Future[bool] {.base, async.} =
  return true
