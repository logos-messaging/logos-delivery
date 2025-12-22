{.used.}

{.push raises: [].}

import
  std/[options, sequtils, deques, random, locks, osproc],
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
    try:
      discard manager.trackRootChanges()
    except CatchableError:
      check getCurrentExceptionMsg().len == 38

  test "trackRootChanges: should sync to the state of the group":
    let credentials = generateCredentials()
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = waitFor manager.fetchMerkleRoot()

    try:
      waitFor manager.register(credentials, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    discard waitFor withTimeout(trackRootChanges(manager), 15.seconds)

    let merkleRootAfter = waitFor manager.fetchMerkleRoot()

    check:
      merkleRootBefore != merkleRootAfter

  test "trackRootChanges: should fetch history correctly":
    # TODO: We can't use `trackRootChanges()` directly in this test because its current implementation
    #       relies on a busy loop rather than event-based monitoring. but that busy loop fetch root every 5 seconds
    #       so we can't use it in this test. 

    const credentialCount = 6
    let credentials = generateCredentials(credentialCount)
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = waitFor manager.fetchMerkleRoot()

    try:
      for i in 0 ..< credentials.len():
        info "Registering credential", index = i, credential = credentials[i]
        waitFor manager.register(credentials[i], UserMessageLimit(20))
        discard waitFor manager.updateRoots()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    let merkleRootAfter = waitFor manager.fetchMerkleRoot()

    check:
      merkleRootBefore != merkleRootAfter
      manager.validRoots.len() == credentialCount

  test "register: should guard against uninitialized state":
    let dummyCommitment = default(IDCommitment)

    try:
      waitFor manager.register(
        RateCommitment(
          idCommitment: dummyCommitment, userMessageLimit: UserMessageLimit(20)
        )
      )
    except CatchableError:
      assert true
    except Exception:
      assert false, "exception raised: " & getCurrentExceptionMsg()

  test "register: should register successfully":
    # TODO :- similar to ```trackRootChanges: should fetch history correctly```
    (waitFor manager.init()).isOkOr:
      raiseAssert $error

    let idCredentials = generateCredentials()
    let merkleRootBefore = waitFor manager.fetchMerkleRoot()

    try:
      waitFor manager.register(idCredentials, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

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

    try:
      waitFor manager.register(
        RateCommitment(
          idCommitment: idCommitment, userMessageLimit: UserMessageLimit(20)
        )
      )
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    waitFor fut

  test "withdraw: should guard against uninitialized state":
    let idSecretHash = generateCredentials().idSecretHash

    try:
      waitFor manager.withdraw(idSecretHash)
    except CatchableError:
      assert true
    except Exception:
      assert false, "exception raised: " & getCurrentExceptionMsg()

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

    try:
      waitFor manager.register(idCredentials, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    waitFor fut

    let rootUpdated = waitFor manager.updateRoots()

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

    try:
      waitFor manager.register(credentials, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()
    waitFor fut

    let rootUpdated = waitFor manager.updateRoots()

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

    try:
      waitFor manager.register(idCredential, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling startGroupSync: " & getCurrentExceptionMsg()

    let messageBytes = "Hello".toBytes()

    let rootUpdated = waitFor manager.updateRoots()

    manager.merkleProofCache = newSeq[byte](640)
    for i in 0 ..< 640:
      manager.merkleProofCache[i] = byte(rand(255))

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
    const credentialCount = 12
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

    try:
      manager.onRegister(generateCallback(futures, credentials))

      for i in 0 ..< credentials.len():
        waitFor manager.register(credentials[i], UserMessageLimit(20))
        discard waitFor manager.updateRoots()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

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
