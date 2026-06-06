import std/options, testutils/unittests, chronos, web3

import
  logos_delivery/waku/incentivization/reputation_manager,
  logos_delivery/waku/waku_lightpush_legacy/rpc

suite "Waku Incentivization PoC Reputation":
  var manager {.threadvar.}: ReputationManager

  setup:
    manager = ReputationManager.init()

  test "incentivization PoC: reputation: reputation table is empty after initialization":
    check manager.reputationOf.len == 0

  test "incentivization PoC: reputation: set and get reputation":
    manager.setReputation("peer1", some(true)) # Encodes GoodRep
    check manager.getReputation("peer1") == some(true)

  test "incentivization PoC: reputation: evaluate PushResponse valid":
    let validLightpushResponse =
      PushResponse(isSuccess: true, info: some("Everything is OK"))
    # We expect evaluateResponse to return GoodResponse if isSuccess is true
    check evaluateResponse(validLightpushResponse) == GoodResponse

  test "incentivization PoC: reputation: evaluate PushResponse invalid":
    let invalidLightpushResponse = PushResponse(isSuccess: false, info: none(string))
    check evaluateResponse(invalidLightpushResponse) == BadResponse

  test "incentivization PoC: reputation: updateReputationFromResponse valid":
    let peerId = "peerWithValidResponse"
    let validResp = PushResponse(isSuccess: true, info: some("All good"))
    manager.updateReputationFromResponse(peerId, validResp)
    check manager.getReputation(peerId) == some(true)

  test "incentivization PoC: reputation: updateReputationFromResponse invalid":
    let peerId = "peerWithInvalidResponse"
    let invalidResp = PushResponse(isSuccess: false, info: none(string))
    manager.updateReputationFromResponse(peerId, invalidResp)
    check manager.getReputation(peerId) == some(false)

  test "incentivization PoC: reputation: default is None":
    let unknownPeerId = "unknown_peer"
    # The peer is not in the table yet
    check manager.getReputation(unknownPeerId) == none(bool)
