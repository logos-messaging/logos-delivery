{.used.}

{.push raises: [].}

import
  std/[options, sequtils, deques, random, locks, osproc, algorithm],
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
  waku/[
    waku_rln_relay,
    waku_rln_relay/protocol_types,
    waku_rln_relay/constants,
    waku_rln_relay/rln,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain/group_manager,
  ],
  ../testlib/wakucore,
  ./utils_onchain

suite "Onchain group manager":
  var anvilProc {.threadVar.}: Process
  var manager {.threadVar.}: OnchainGroupManager

  setup:
    anvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

  teardown:
    stopAnvil(anvilProc)

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

  test "trackRootChanges: should guard against uninitialized state":
    let initializedResult = waitFor manager.trackRootChanges()

    check:
      initializedResult.isErr()
      initializedResult.error == "OnchainGroupManager is not initialized"

  test "trackRootChanges: should sync to the state of the group":
    let credentials = generateCredentials()
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = waitFor manager.fetchMerkleRoot()

    (waitFor manager.register(credentials, UserMessageLimit(20))).isOkOr:
      assert false, "error returned when calling register: " & error

    discard waitFor withTimeout(trackRootChanges(manager), 15.seconds)

    let merkleRootAfter = waitFor manager.fetchMerkleRoot()

    check:
      merkleRootBefore != merkleRootAfter

  test "trackRootChanges: should fetch history correctly: fetch single root()":
    # basic check for the soon to be deprecated root contract function, is replaced by getRecentRoots()
    # TODO: We can't use `trackRootChanges()` directly in this test because its current implementation
    #       relies on a busy loop rather than event-based monitoring. but that busy loop fetch root every 5 seconds
    #       so we can't use it in this test. 

    const credentialCount = 6
    let credentials = generateCredentials(credentialCount)
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = (waitFor manager.fetchMerkleRoot()).valueOr:
      raiseAssert "Failed to fetch merkle root before: " & error

    for i in 0 ..< credentials.len():
      info "Registering credential", index = i, credential = credentials[i]
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "Failed to register credential " & $i & ": " & error
      discard waitFor manager.updateRoots()

    let merkleRootAfter = (waitFor manager.fetchMerkleRoot()).valueOr:
      raiseAssert "Failed to fetch merkle root after: " & error

    check:
      merkleRootBefore != merkleRootAfter
      manager.validRoots.len() == credentialCount

  test "trackRootChanges: should fetch history correctly: fetch root cache":
    # Verify that the group_manager list of valid roots is updated correctly from the recent roots
    # cache as new credentials are registered.
    # TODO: We can't use `trackRootChanges()` directly in this test because its current implementation
    #       relies on a busy loop rather than event-based monitoring. but that busy loop fetch root every 5 seconds
    #       so we can't use it in this test.

    const credentialCount = RlnContractRootCacheSize
    let credentials = generateCredentials(credentialCount)
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootCacheBefore = (waitFor manager.fetchMerkleRootsCache()).valueOr:
      raiseAssert "Failed to fetch merkle root cache before: " & error

    check:
      merkleRootCacheBefore.len == RlnContractRootCacheSize * 32
      merkleRootCacheBefore.allIt(it == 0'u8)
      manager.validRoots.len() == 0

    for i in 0 ..< credentials.len():
      info "Registering credential", index = i, credential = credentials[i]
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "Failed to register credential " & $i & ": " & error
      discard waitFor manager.updateRecentRoots()

    let merkleRootCacheAfter = (waitFor manager.fetchMerkleRootsCache()).valueOr:
      raiseAssert "Failed to fetch merkle root cache after: " & error

    check:
      merkleRootCacheAfter.len == RlnContractRootCacheSize * 32
      not merkleRootCacheAfter.allIt(it == 0'u8)
      manager.validRoots.len() == credentialCount
      manager.validRoots.items().toSeq().allIt(it != default(MerkleNode))

  test "trackRootChanges: oldest roots are evicted once the window is exceeded":
    const
      initialCount = AcceptableRootWindowSize - RlnContractRootCacheSize
      additionalCount = RlnContractRootCacheSize + 1
        # one more than the cache size to ensure eviction occurs
    let credentials = generateCredentials(initialCount + additionalCount)
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    # Register the first credentials and snapshot the 3 oldest roots.
    for i in 0 ..< initialCount:
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "Failed to register credential " & $i & ": " & error
      discard waitFor manager.updateRecentRoots()

    check manager.validRoots.len() >= 3
    let firstThreeBefore =
      @[manager.validRoots[0], manager.validRoots[1], manager.validRoots[2]]

    # Register the remaining credentials, pushing the deque past AcceptableRootWindowSize.
    for i in initialCount ..< credentials.len():
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "Failed to register credential " & $i & ": " & error
      discard waitFor manager.updateRecentRoots()

    let rootsAfter = manager.validRoots.items().toSeq()

    # AcceptableRootWindowSize + 1 registrations evicts exactly the single oldest root,
    # so only the first of the original three is gone; the other two remain.
    check:
      manager.validRoots.len() == AcceptableRootWindowSize
      firstThreeBefore[0] notin rootsAfter
      firstThreeBefore[1] in rootsAfter
      firstThreeBefore[2] in rootsAfter

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
    # TODO :- similar to ```trackRootChanges: should fetch history correctly```
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

    let validProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(1)
    )

    check:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    let validated = manager.validateRoot(validProof.merkleRoot)

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

    let messageBytes = "Hello".toBytes()

    let epoch = default(Epoch)
    info "epoch in bytes", epochHex = epoch.inHex()

    let validProofRes = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(1)
    )

    check:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    let validated = manager.validateRoot(validProof.merkleRoot)

    check:
      validated == false

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
    let validProof = manager.generateProof(
      data = messageBytes, epoch = epoch, messageId = MessageId(0)
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

    let epoch = default(Epoch)
    info "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let invalidProofRes = manager.generateProof(
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

  test "root queue should be updated correctly":
    const credentialCount = 9
    let credentials = generateCredentials(credentialCount)
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    type TestBackfillFuts = array[0 .. credentialCount - 1, Future[void]]
    var futures: TestBackfillFuts
    for i in 0 ..< futures.len():
      futures[i] = newFuture[void]()

    proc generateCallback(
        futs: TestBackfillFuts, credentials: seq[IdentityCredential]
    ): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        if registrations.len == 1 and
            registrations[0].rateCommitment ==
            getRateCommitment(credentials[futureIndex], UserMessageLimit(20)).get() and
            registrations[0].index == MembershipIndex(futureIndex):
          futs[futureIndex].complete()
          futureIndex += 1

      return callback

    manager.onRegister(generateCallback(futures, credentials))

    for i in 0 ..< credentials.len():
      (waitFor manager.register(credentials[i], UserMessageLimit(20))).isOkOr:
        assert false, "Failed to register credential " & $i & ": " & error
      discard waitFor manager.updateRecentRoots()

    waitFor allFutures(futures)

    check:
      manager.validRoots.len() == credentialCount

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
