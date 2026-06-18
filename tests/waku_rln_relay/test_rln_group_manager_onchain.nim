{.used.}

{.push raises: [].}

import
  std/[options, sequtils, deques, random, locks, osproc, algorithm, exitprocs],
  results,
  stew/byteutils,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  web3,
  libp2p/crypto/crypto,
  eth/keys,
  tests/testlib/testasync,
  tests/testlib/testutils

import
  logos_delivery/waku/[
    waku_rln_relay,
    waku_rln_relay/protocol_types,
    waku_rln_relay/protocol_metrics,
    waku_rln_relay/constants,
    waku_rln_relay/rln,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain/group_manager,
  ],
  ../testlib/wakucore,
  ./utils_onchain

# Anvil is started once for the whole suite. The first test runs the full
# `setupOnchainGroupManager` flow (fund a fresh account + mint tokens + approve
# allowance) and then takes a baseline snapshot capturing that post-setup chain
# state. Subsequent tests revert to the baseline (restoring the funded account)
# and build a bare manager pointing at the same key. evm_revert consumes the snapshot
# ID, so we re-snapshot after every revert. Cleanup is registered via
# addExitProc so anvil is terminated when the test binary exits.
var sharedAnvilProc: Process
var anvilStarted: bool = false
var baselineSnapshotId: string
var fundedPrivateKey: string

suite "Onchain group manager":
  var manager {.threadVar.}: OnchainGroupManager

  setup:
    if not anvilStarted:
      sharedAnvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
      anvilStarted = true
      addExitProc(
        proc() =
          if not sharedAnvilProc.isNil:
            stopAnvil(sharedAnvilProc)
      )
      manager = waitFor setupOnchainGroupManager(deployContracts = false)
      fundedPrivateKey = manager.ethPrivateKey.get()
      baselineSnapshotId = waitFor takeEvmSnapshot()
    else:
      discard waitFor revertEvmSnapshot(baselineSnapshotId)
      baselineSnapshotId = waitFor takeEvmSnapshot()
      manager = buildOnchainGroupManager(fundedPrivateKey)

  test "should initialize successfully":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    check:
      manager.ethRpc.isSome()
      manager.wakuRlnContract.isSome()
      manager.initialized
      manager.rlnRelayMaxMessageLimit == 600

  test "should error on initialization when chainId does not match":
    manager.chainId = utils_onchain.CHAIN_ID + 1

    (waitFor manager.init()).isErrOr:
      raiseAssert "Expected error when chainId does not match"

  test "should initialize when chainId is set to 0":
    manager.chainId = 0x0'u256
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

  test "should error if contract does not exist":
    manager.ethContractAddress = "0x0000000000000000000000000000000000000000"

    (waitFor manager.init()).isErrOr:
      raiseAssert "Expected error when contract address doesn't exist"

  test "should error when keystore path and password are provided but file doesn't exist":
    manager.keystorePath = some("/inexistent/file")
    manager.keystorePassword = some("password")

    (waitFor manager.init()).isErrOr:
      raiseAssert "Expected error when keystore file doesn't exist"

  test "updateMemberCount: reflects on-chain registered member count":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    # No members registered yet; metric should reflect nextFreeIndex == 0.
    (waitFor manager.updateMemberCount()).isOkOr:
      raiseAssert "updateMemberCount failed (initial): " & error
    check waku_rln_number_registered_memberships.value() == 0.0

    const credentialCount = 1
    let credentials = generateCredentials(credentialCount)
    for i in 0 ..< credentials.len:
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "register failed for credential " & $i & ": " & error

    (waitFor manager.updateMemberCount()).isOkOr:
      raiseAssert "updateMemberCount failed (after registrations): " & error
    check waku_rln_number_registered_memberships.value() == float64(credentialCount)

  test "updateRoots: appends new on-chain root to validRoots after registration":
    # basic check for the soon to be deprecated root contract function, is replaced by getRecentRoots()
    const credentialCount = 2
    let credentials = generateCredentials(credentialCount)
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = (waitFor manager.fetchMerkleRoot()).valueOr:
      raiseAssert "Failed to fetch merkle root before: " & error

    for i in 0 ..< credentials.len:
      info "Registering credential", index = i, credential = credentials[i]
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "Failed to register credential " & $i & ": " & error
      discard waitFor manager.updateRoots()

    let merkleRootAfter = (waitFor manager.fetchMerkleRoot()).valueOr:
      raiseAssert "Failed to fetch merkle root after: " & error

    check:
      merkleRootBefore != merkleRootAfter
      manager.validRoots.len == credentialCount

  test "updateRecentRoots: appends new on-chain roots from contract cache":
    # Verify that the group_manager list of valid roots is updated correctly from the recent roots
    # cache as new credentials are registered.

    const credentialCount = RlnContractRootCacheSize
    let credentials = generateCredentials(credentialCount)
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootCacheBefore = (waitFor manager.fetchMerkleRootsCache()).valueOr:
      raiseAssert "Failed to fetch merkle root cache before: " & error

    check:
      merkleRootCacheBefore.len == RlnContractRootCacheSize * 32
      merkleRootCacheBefore.allIt(it == 0'u8)
      manager.validRoots.len == 0

    for i in 0 ..< credentials.len:
      info "Registering credential", index = i, credential = credentials[i]
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "Failed to register credential " & $i & ": " & error
      discard waitFor manager.updateRecentRoots()

    let merkleRootCacheAfter = (waitFor manager.fetchMerkleRootsCache()).valueOr:
      raiseAssert "Failed to fetch merkle root cache after: " & error

    check:
      merkleRootCacheAfter.len == RlnContractRootCacheSize * 32
      not merkleRootCacheAfter.allIt(it == 0'u8)
      manager.validRoots.len == credentialCount
      manager.validRoots.items().toSeq().allIt(it != default(MerkleNode))

  test "register: should guard against uninitialized state":
    let dummyCommitment = default(IDCommitment)

    let res = waitFor manager.register(
      RateCommitment(
        idCommitment: dummyCommitment, userMessageLimit: UserMessageLimit(20)
      )
    )

    check:
      res.isErr()
      res.error == "OnchainGroupManager is not initialized"

  test "register: should register successfully":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let idCredentials = generateCredentials()
    let merkleRootBefore = waitFor manager.fetchMerkleRoot()

    (waitFor manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "error returned when calling register: " & error

    let merkleRootAfter = waitFor manager.fetchMerkleRoot()

    check:
      merkleRootAfter != merkleRootBefore
      manager.latestIndex == 1

  test "register: callback is called":
    let idCredentials = generateCredentials()
    let idCommitment = idCredentials.idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      let rateCommitment = getRateCommitment(idCredentials, UserMessageLimit(20)).get()
      check:
        registrations.len == 1
        registrations[0].rateCommitment == rateCommitment
        registrations[0].index == 0
      fut.complete()

    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    manager.onRegister(callback)

    (
      waitFor manager.register(
        RateCommitment(
          idCommitment: idCommitment, userMessageLimit: UserMessageLimit(20)
        )
      )
    ).isOkOr:
      assert false, "error returned when calling register: " & error

    waitFor fut

  test "withdraw: should guard against uninitialized state":
    let idSecretHash = generateCredentials().idSecretHash

    let res = waitFor manager.withdraw(idSecretHash)

    check:
      res.isErr()
      res.error == "OnchainGroupManager is not initialized"

  test "validateRoot: should validate good root":
    let idCredentials = generateCredentials()
    let idCommitment = idCredentials.idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
          registrations[0].rateCommitment ==
          getRateCommitment(idCredentials, UserMessageLimit(20)).get() and
          registrations[0].index == 0:
        manager.idCredentials = some(idCredentials)
        fut.complete()

    manager.onRegister(callback)

    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    (waitFor manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "error returned : " & getCurrentExceptionMsg()

    waitFor fut

    let rootUpdated = waitFor manager.updateRecentRoots()

    if rootUpdated:
      let proofResult = waitFor manager.fetchMerkleProofElements()
      if proofResult.isErr():
        error "Failed to fetch Merkle proof", error = proofResult.error
      manager.merkleProofCache = proofResult.get()
    let messageBytes = "Hello".toBytes()

    let epoch = default(Epoch)
    info "epoch in bytes", epochHex = epoch.inHex()

    let validProofRes = waitFor manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(1)
    )

    check:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    let validated = waitFor manager.validateRoot(validProof.merkleRoot)

    check:
      validated

  test "validateRoot: should reject bad root":
    let idCredentials = generateCredentials()
    let idCommitment = idCredentials.idCommitment

    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    manager.userMessageLimit = some(UserMessageLimit(20))
    manager.membershipIndex = some(MembershipIndex(0))
    manager.idCredentials = some(idCredentials)

    manager.merkleProofCache = newSeq[byte](640)
    for i in 0 ..< 640:
      manager.merkleProofCache[i] = byte(rand(255))
    # chunk[0] becomes the MSB after reversal in group_manager; must be < 0x30
    for i in 0 ..< 20:
      manager.merkleProofCache[i * 32] = 0
    # Pin the freshness throttle so ensureFreshMerkleProofPath does NOT refetch
    # and overwrite the intentionally-corrupted cache we just planted.
    manager.lastMerklePathCheckMoment = Moment.now()

    let messageBytes = "Hello".toBytes()

    let epoch = default(Epoch)
    info "epoch in bytes", epochHex = epoch.inHex()

    let validProofRes = waitFor manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(1)
    )

    check:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    let validated = waitFor manager.validateRoot(validProof.merkleRoot)

    check:
      validated == false

  test "validateRoot: fast-paths without refresh when root is in window":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    discard waitFor manager.updateRecentRoots()
    check manager.validRoots.len > 0

    let knownRoot = manager.validRoots[0]
    let preRefreshTs = manager.lastRootsRefreshMoment

    let validated = waitFor manager.validateRoot(knownRoot)

    check:
      validated
      # No refresh should have been triggered on a fast-path hit.
      manager.lastRootsRefreshMoment == preRefreshTs

  test "validateRoot: triggers on-demand refresh when root is not in window":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    # validRoots is intentionally not pre-populated — the refresh must happen
    # inside validateRoot to bring the on-chain root into the window.
    check:
      manager.validRoots.len == 0

    let onChainRootU256 = (waitFor manager.fetchMerkleRoot()).valueOr:
      raiseAssert "failed to fetch root: " & error
    let onChainRoot = UInt256ToField(onChainRootU256)

    let validated = waitFor manager.validateRoot(onChainRoot)

    check:
      validated
      manager.validRoots.len > 0

  test "validateRoot: throttles refreshes to RootsRefreshMinInterval":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    # First miss: an unknown root forces refreshRoots to run end-to-end.
    var badRoot1: MerkleNode
    badRoot1[0] = 0x42
    discard waitFor manager.validateRoot(badRoot1)
    let firstRefreshTs = manager.lastRootsRefreshMoment

    # Second miss within RootsRefreshMinInterval must be throttled out;
    # lastRootsRefreshMoment stays pinned to the previous refresh timestamp.
    var badRoot2: MerkleNode
    badRoot2[0] = 0x43
    discard waitFor manager.validateRoot(badRoot2)

    check:
      manager.lastRootsRefreshMoment == firstRefreshTs

  test "validateRoot: concurrent misses coalesce onto a single refresh future":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    # Clean gates: the throttle window must not short-circuit the first call,
    # and the in-flight slot must start empty so we can observe whether
    # subsequent callers install a second future.
    manager.lastRootsRefreshMoment = default(Moment)
    manager.rootsRefreshInFlightFut = nil

    var badRoot: MerkleNode
    badRoot[0] = 0x77

    # The first validateRoot call runs synchronously down to the suspended
    # RPC inside doRefresh, installing rootsRefreshInFlightFut along the way.
    # Calls 2 and 3 enter while that future is still pending, so they must
    # observe the same reference and await it rather than start a second
    # doRefresh.
    let f1 = manager.validateRoot(badRoot)
    let inFlight = manager.rootsRefreshInFlightFut
    let f2 = manager.validateRoot(badRoot)
    let afterSecond = manager.rootsRefreshInFlightFut
    let f3 = manager.validateRoot(badRoot)
    let afterThird = manager.rootsRefreshInFlightFut

    check:
      inFlight != nil
      not inFlight.finished()
      # No new doRefresh future was created by the coalescing callers.
      afterSecond == inFlight
      afterThird == inFlight

    waitFor allFutures(f1, f2, f3)

    check:
      # The same in-flight future served all three callers and was never
      # replaced by a competing refresh.
      manager.rootsRefreshInFlightFut == inFlight

  test "generateProof: fast-paths without refresh inside throttle window":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    # Prime cache and pin the throttle so the publish-path freshness check
    # short-circuits on the cached value.
    manager.merkleProofCache = (waitFor manager.fetchMerkleProofElements()).valueOr:
      raiseAssert "failed to fetch initial path: " & error
    manager.lastMerklePathCheckMoment = Moment.now()
    manager.proofPathRefreshInFlightFut = nil

    let primedCache = manager.merkleProofCache

    let proofRes = waitFor manager.generateProof(
      data = "hello".toBytes(), epoch = default(Epoch), messageId = MessageId(1)
    )

    check:
      proofRes.isOk()
      # Hot path: no refresh future created, cache untouched.
      manager.proofPathRefreshInFlightFut == nil
      manager.merkleProofCache == primedCache

  test "generateProof: refetches path when cache is empty":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    # No path yet; generateProof must run the freshness check, see the empty
    # cache, and refetch.
    manager.merkleProofCache = @[]
    manager.proofPathRefreshInFlightFut = nil

    let proofRes = waitFor manager.generateProof(
      data = "hello".toBytes(), epoch = default(Epoch), messageId = MessageId(1)
    )

    check:
      proofRes.isOk()
      manager.merkleProofCache.len > 0
      manager.proofPathRefreshInFlightFut != nil

  test "ensureFreshMerkleProofPath: errors when membership index is not set":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    # No registration → no membership index. Guard must error rather than
    # crashing inside fetchMerkleProofElements (which unwraps the Option).
    check:
      manager.membershipIndex.isNone()

    let res = waitFor manager.ensureFreshMerkleProofPath()
    check:
      res.isErr()
      res.error == "membership index is not set"

  test "ensureFreshMerkleProofPath: refetches when throttle window has expired":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    # Prime cache with a non-empty value and an old throttle timestamp, so
    # the cache fast-path does NOT trigger and we exercise the refetch branch.
    manager.merkleProofCache = (waitFor manager.fetchMerkleProofElements()).valueOr:
      raiseAssert "failed to prime path: " & error
    manager.lastMerklePathCheckMoment = Moment.now() - PathCheckMinInterval - 1.seconds
    manager.proofPathRefreshInFlightFut = nil

    let preCheckTs = manager.lastMerklePathCheckMoment
    let res = waitFor manager.ensureFreshMerkleProofPath()

    check:
      res.isOk()
      manager.merkleProofCache.len > 0
      manager.proofPathRefreshInFlightFut != nil
      # lastMerklePathCheckMoment was bumped to "now" by the refetch.
      manager.lastMerklePathCheckMoment > preCheckTs

  test "ensureFreshMerkleProofPath: refresh bumps the member-count metric":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    const credentialCount = 2
    let credentials = generateCredentials(credentialCount)
    for i in 0 ..< credentials.len:
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "register failed for credential " & $i & ": " & error

    # Force a refetch by emptying the cache; the doRefresh closure should
    # invoke updateMemberCount on the success path.
    manager.merkleProofCache = @[]
    manager.proofPathRefreshInFlightFut = nil
    waku_rln_number_registered_memberships.set(0.0) # baseline

    let res = waitFor manager.ensureFreshMerkleProofPath()

    check:
      res.isOk()
      manager.merkleProofCache.len > 0
      waku_rln_number_registered_memberships.value() == float64(credentialCount)

  test "ensureFreshMerkleProofPath: concurrent calls coalesce onto a single refresh future":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials()
    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    # Empty cache + epoch-zero check timestamp guarantees the first caller
    # will fall through to fetchMerkleProofElements; the followers should
    # observe the resulting in-flight future and await it rather than start
    # their own refresh.
    manager.merkleProofCache = @[]
    manager.lastMerklePathCheckMoment = default(Moment)
    manager.proofPathRefreshInFlightFut = nil

    let f1 = manager.ensureFreshMerkleProofPath()
    let inFlight = manager.proofPathRefreshInFlightFut
    let f2 = manager.ensureFreshMerkleProofPath()
    let afterSecond = manager.proofPathRefreshInFlightFut
    let f3 = manager.ensureFreshMerkleProofPath()
    let afterThird = manager.proofPathRefreshInFlightFut

    check:
      inFlight != nil
      not inFlight.finished()
      afterSecond == inFlight
      afterThird == inFlight

    waitFor allFutures(f1, f2, f3)
    let r1 = f1.read()
    let r2 = f2.read()
    let r3 = f3.read()

    check:
      r1.isOk()
      r2.isOk()
      r3.isOk()
      # Same future served all callers; field was not replaced by a second
      # refresh while the first was still in flight.
      manager.proofPathRefreshInFlightFut == inFlight
      manager.merkleProofCache.len > 0

  test "verifyProof: should verify valid proof":
    let credentials = generateCredentials()
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      if registrations.len == 1 and
          registrations[0].rateCommitment ==
          getRateCommitment(credentials, UserMessageLimit(20)).get() and
          registrations[0].index == 0:
        manager.idCredentials = some(credentials)
        fut.complete()

    manager.onRegister(callback)

    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "error returned when calling register: " & error
    waitFor fut

    let rootUpdated = waitFor manager.updateRecentRoots()

    if rootUpdated:
      let proofResult = waitFor manager.fetchMerkleProofElements()
      if proofResult.isErr():
        error "Failed to fetch Merkle proof", error = proofResult.error
      manager.merkleProofCache = proofResult.get()

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    info "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProof = (
      waitFor manager.generateProof(
        data = messageBytes, epoch = epoch, messageId = MessageId(0)
      )
    ).valueOr:
      raiseAssert $error

    let verified = manager.verifyProof(messageBytes, validProof).valueOr:
      raiseAssert $error

    check:
      verified

  test "verifyProof: should reject invalid proof":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let idCredential = generateCredentials()

    (waitFor manager.register(idCredential, UserMessageLimit(20))).isOkOr:
      assert false, "error returned when calling register: " & error

    let messageBytes = "Hello".toBytes()

    let rootUpdated = waitFor manager.updateRecentRoots()

    manager.merkleProofCache = newSeq[byte](640)
    for i in 0 ..< 640:
      manager.merkleProofCache[i] = byte(rand(255))
    # chunk[0] becomes the MSB after reversal in group_manager; must be < 0x30
    for i in 0 ..< 20:
      manager.merkleProofCache[i * 32] = 0
    # Pin the freshness throttle so ensureFreshMerkleProofPath does NOT refetch
    # and overwrite the intentionally-corrupted cache we just planted.
    manager.lastMerklePathCheckMoment = Moment.now()

    let epoch = default(Epoch)
    info "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let invalidProofRes = waitFor manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(0)
    )

    check:
      invalidProofRes.isOk()
    let invalidProof = invalidProofRes.get()

    # verify the proof (should be false)
    let verified = manager.verifyProof(messageBytes, invalidProof).valueOr:
      raiseAssert $error

    check:
      verified == false

  test "isReady should return false if ethRpc is none":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    manager.ethRpc = none(Web3)

    var isReady = true
    try:
      isReady = waitFor manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == false

  test "isReady should return true if ethRpc is ready":
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    var isReady = false
    try:
      isReady = waitFor manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == true

  test "proof roundtrip: generateRlnProofWithWitness -> verifyRlnProof":
    ## Smoke test: proof gen -> wire serialize -> deserialize -> ffi_verify_with_roots.
    let credentials = generateCredentials()

    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "register failed: " & error

    discard waitFor manager.updateRecentRoots()
    let roots = manager.validRoots.items().toSeq()
    require:
      roots.len > 0

    let proofElements = (waitFor manager.fetchMerkleProofElements()).valueOr:
      raiseAssert "fetchMerkleProofElements failed: " & error

    let signal = "Hello, RLN!".toBytes()
    let epoch = default(Epoch)

    # Build RLNWitnessInput the same way group_manager.generateProof does.
    var pathElements = newSeq[byte]()
    for i in 0 ..< proofElements.len div 32:
      pathElements.add(proofElements[i * 32 .. (i + 1) * 32 - 1].reversed())

    let xCfr = hashToFieldLe(signal).valueOr:
      raiseAssert "hashToFieldLe failed: " & error
    defer:
      ffi_cfr_free(xCfr)
    let x = cfrToBytesLe(xCfr).valueOr:
      raiseAssert "cfrToBytesLe failed: " & error

    let extNullifier = generateExternalNullifier(epoch, DefaultRlnIdentifier).valueOr:
      raiseAssert "generateExternalNullifier failed: " & error

    let witness = RLNWitnessInput(
      identity_secret: seqToField(credentials.idSecretHash),
      user_message_limit: uint64ToField(uint64(UserMessageLimit(20))),
      message_id: uint64ToField(uint64(MessageId(1))),
      path_elements: pathElements,
      identity_path_index: uint64ToIndex(manager.membershipIndex.get(), 20),
      x: x,
      external_nullifier: extNullifier,
    )

    # Step 1: generate proof via the FFI wrapper
    let proof = generateRlnProofWithWitness(
      manager.rlnInstance, witness, epoch, DefaultRlnIdentifier
    ).valueOr:
      raiseAssert "generateRlnProofWithWitness failed: " & error

    let zeroField = default(array[32, byte])
    check:
      proof.merkleRoot != zeroField
      proof.nullifier != zeroField

    # Step 2: serialize -> deserialize -> verify (the actual roundtrip)
    let verified = verifyRlnProof(manager.rlnInstance, proof, signal, roots).valueOr:
      raiseAssert "verifyRlnProof failed: " & error
    check verified == true

    # Step 3: wrong signal -> x mismatch -> false
    let wrongSignalVerified = verifyRlnProof(
      manager.rlnInstance, proof, "wrong".toBytes(), roots
    ).valueOr:
      raiseAssert "verifyRlnProof (wrong signal) failed: " & error
    check wrongSignalVerified == false

    # Step 4: bad root -> root not in set -> false
    # byte[31] in LE is the MSB; 0x01 < 0x30 so this is a canonical field element.
    var badRoot: MerkleNode
    for i in 0 ..< 32:
      badRoot[i] = 0x01
    let badRootVerified = verifyRlnProof(manager.rlnInstance, proof, signal, @[badRoot]).valueOr:
      raiseAssert "verifyRlnProof (bad root) failed: " & error
    check badRootVerified == false
