import std/tempfiles
import results

import
  logos_delivery/waku/rln,
  logos_delivery/waku/rln/[
    rln_evm/group_manager,
    rln_evm/bindings,
    rln_evm/conversion_utils,
    rln_evm/constants,
    rln_evm/protocol_types,
    rln_evm/protocol_metrics,
    rln_evm/nonce_manager,
  ]

proc createRLNInstanceWrapper*(): Result[ptr RlnRaw, string] =
  return createRlnInstance()

proc unsafeAppendRLNProof*(
    rlnPeer: RlnEvm, msg: var WakuMessage, epoch: Epoch, messageId: MessageId
): Result[void, string] =
  ## Test helper derived from the publish-path proof flow.
  ## - Skips nonce validation to intentionally allow generating "bad" message IDs for tests.
  ## - Forces a real-time on-chain Merkle root refresh via `updateRoots()` and fetches Merkle
  ##   proof elements, updating `merkleProofCache` (bypasses `trackRootsChanges`).
  ## WARNING: For testing only

  let manager = cast[RlnEvmGroupManager](rlnPeer.groupManager)
  let rootUpdated = waitFor manager.updateRoots()

  # Fetch Merkle proof either when a new root was detected *or* when the cache is empty.
  if rootUpdated or manager.merkleProofCache.len == 0:
    let proofResult = waitFor manager.fetchMerkleProofElements()
    if proofResult.isErr():
      error "Failed to fetch Merkle proof", error = proofResult.error
    manager.merkleProofCache = proofResult.get()

  let proof = (waitFor manager.generateProof(msg.toRLNSignal(), epoch, messageId)).valueOr:
    return err("could not generate rln-v2 proof: " & $error)

  msg.proof = proof.encode().buffer
  return ok()

proc getWakuRlnConfig*(
    manager: RlnEvmGroupManager,
    userMessageLimit: uint64 = 1,
    epochSizeSec: uint64 = 1,
    index: MembershipIndex = MembershipIndex(0),
): WakuRlnConfig =
  let wakuRlnConfig = WakuRlnConfig(
    dynamic: true,
    ethClientUrls: @[EthClient],
    ethContractAddress: manager.ethContractAddress,
    chainId: manager.chainId,
    credIndex: Opt.some(index),
    userMessageLimit: userMessageLimit,
    epochSizeSec: epochSizeSec,
    ethPrivateKey: Opt.some(manager.ethPrivateKey.get()),
    onFatalErrorAction: proc(errStr: string) =
      warn "non-fatal onchain test error", errStr
    ,
  )
  return wakuRlnConfig
