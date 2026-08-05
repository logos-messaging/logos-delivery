{.used.}

import testutils/unittests, chronos

import logos_delivery/waku/rln/api/rln_interface

proc stubStart(): Future[RlnApiResult[void]] {.async: (raises: [CancelledError]).} =
  return ok()

proc stubStop(): Future[RlnApiResult[void]] {.async: (raises: [CancelledError]).} =
  return ok()

proc stubRegister(
    scope: MembershipScope, options: RegistryOptions
): Future[RlnApiResult[MembershipState]] {.async: (raises: [CancelledError]).} =
  return ok(MembershipState(status: MembershipStatus.Pending))

proc stubMembershipState(
    scope: MembershipScope
): Future[RlnApiResult[MembershipState]] {.async: (raises: [CancelledError]).} =
  return ok(
    MembershipState(
      status: MembershipStatus.Active,
      membership: some(Membership(rateLimit: 100, leafIndex: 1)),
    )
  )

proc stubEpochQuota(
    scope: MembershipScope
): Future[RlnApiResult[EpochQuota]] {.async: (raises: [CancelledError]).} =
  return ok(EpochQuota(epochIndex: 42, rateLimit: 100, remaining: 99))

proc stubGenerateProof(
    scope: MembershipScope, signal: seq[byte], timestamp: uint64
): Future[RlnApiResult[RateLimitProof]] {.async: (raises: [CancelledError]).} =
  return ok(RateLimitProof())

proc stubVerifyProof(
    scope: MembershipScope, signal: seq[byte], proof: RateLimitProof
): Future[RlnApiResult[VerificationResult]] {.async: (raises: [CancelledError]).} =
  return ok(VerificationResult(verdict: ProofVerdict.Valid))

suite "RLN interface - types":
  test "constructs each client-surface type":
    var rlnId: RlnIdentifier
    rlnId[0] = 1'u8
    let scope = MembershipScope.init("eip155:1:0xabc", rlnId)
    let options = @[RegistryOption(key: "rate_limit", value: "100")]

    check:
      scope.registryId == "eip155:1:0xabc"
      scope.rlnIdentifier[0] == 1'u8
      options.len == 1

  test "error kinds round-trip":
    for kind in RlnErrorKind:
      let e = RlnError.init(kind, "msg")
      check:
        e.kind == kind
        ($e).len > 0

    check:
      RlnError.notReady().kind == RlnErrorKind.NotReady
      RlnError.transient().kind == RlnErrorKind.Transient
      RlnError.budgetExhausted().kind == RlnErrorKind.BudgetExhausted
      RlnError.permanent().kind == RlnErrorKind.Permanent

  test "verdicts and membership statuses cover the spec":
    check:
      ord(high(ProofVerdict)) == 3
      ord(high(MembershipStatus)) == 7

  test "interface vtable constructs and dispatches":
    let api = RlnInterface(
      start: stubStart,
      stop: stubStop,
      register: stubRegister,
      getMembershipState: stubMembershipState,
      getEpochQuota: stubEpochQuota,
      generateProof: stubGenerateProof,
      verifyProof: stubVerifyProof,
    )
    var rlnId: RlnIdentifier
    let scope = MembershipScope.init("logos:testnet:00", rlnId)

    let quota = (waitFor api.getEpochQuota(scope)).valueOr:
      raiseAssert $error
    let verification = (waitFor api.verifyProof(scope, @[1'u8, 2, 3], RateLimitProof())).valueOr:
      raiseAssert $error
    let state = (waitFor api.getMembershipState(scope)).valueOr:
      raiseAssert $error

    check:
      (waitFor api.start()).isOk()
      quota.remaining == 99
      verification.verdict == ProofVerdict.Valid
      state.membership.isSome()
      (waitFor api.stop()).isOk()
