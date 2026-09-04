{.used.}

import testutils/unittests, chronos

import logos_delivery/waku/rln/rln_api

type StubRlnModule = ref object
  quota: EpochQuota

proc start(
    m: StubRlnModule
): Future[Result[void, RlnError]] {.async: (raises: [CancelledError]).} =
  return ok()

proc stop(
    m: StubRlnModule
): Future[Result[void, RlnError]] {.async: (raises: [CancelledError]).} =
  return ok()

proc register(
    m: StubRlnModule, scope: MembershipScope, options: RegistryOptions
): Future[Result[MembershipState, RlnError]] {.async: (raises: [CancelledError]).} =
  return ok(MembershipState(status: MembershipStatus.Pending))

proc getMembershipState(
    m: StubRlnModule, scope: MembershipScope
): Future[Result[MembershipState, RlnError]] {.async: (raises: [CancelledError]).} =
  return ok(
    MembershipState(
      status: MembershipStatus.Active,
      membership: some(Membership(rateLimit: 100, leafIndex: 1)),
    )
  )

proc getEpochQuota(
    m: StubRlnModule, scope: MembershipScope, timestamp: uint64
): Future[Result[EpochQuota, RlnError]] {.async: (raises: [CancelledError]).} =
  return ok(m.quota)

proc generateProof(
    m: StubRlnModule, scope: MembershipScope, signal: seq[byte], timestamp: uint64
): Future[Result[RateLimitProof, RlnError]] {.async: (raises: [CancelledError]).} =
  return ok(RateLimitProof())

proc validateProof(
    m: StubRlnModule,
    scope: MembershipScope,
    signal: seq[byte],
    timestamp: uint64,
    proof: RateLimitProof,
): Future[Result[ValidationResult, RlnError]] {.async: (raises: [CancelledError]).} =
  return ok(ValidationResult(verdict: ProofVerdict.Valid))

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
      ord(high(MembershipStatus)) == 8

  test "stub backend satisfies the interface and dispatches":
    static:
      doAssert StubRlnModule is RlnInterface

    let m =
      StubRlnModule(quota: EpochQuota(epochIndex: 42, rateLimit: 100, remaining: 99))
    var rlnId: RlnIdentifier
    let scope = MembershipScope.init("logos:testnet:00", rlnId)
    let timestamp = 1_700_000_000'u64

    let quota = (waitFor m.getEpochQuota(scope, timestamp)).valueOr:
      raiseAssert $error
    let validation = (
      waitFor m.validateProof(scope, @[1'u8, 2, 3], timestamp, RateLimitProof())
    ).valueOr:
      raiseAssert $error
    let state = (waitFor m.getMembershipState(scope)).valueOr:
      raiseAssert $error

    check:
      (waitFor m.start()).isOk()
      quota.remaining == 99
      validation.verdict == ProofVerdict.Valid
      state.membership.isSome()
      (waitFor m.stop()).isOk()
