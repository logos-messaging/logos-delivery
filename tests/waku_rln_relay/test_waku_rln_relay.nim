{.used.}

import
  std/[options, os, sequtils, tempfiles, strutils, osproc],
  stew/byteutils,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  libp2p/crypto/crypto,
  random

import
  waku/[
    waku_core,
    waku_rln_relay,
    waku_rln_relay/rln,
    waku_rln_relay/protocol_metrics,
    waku_keystore,
    common/broker/broker_context,
  ],
  ./rln/waku_rln_relay_utils,
  ./utils_onchain,
  ../testlib/[wakucore, futures, wakunode, testutils]

from std/times import epochTime

suite "Waku rln relay":
  var anvilProc {.threadVar.}: Process
  var manager {.threadVar.}: OnchainGroupManager

  setup:
    anvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

  teardown:
    stopAnvil(anvilProc)

  test "key_gen Nim Wrappers":
    let merkleDepth: csize_t = 20

    # keysBufferPtr will hold the generated identity credential i.e., id trapdoor, nullifier, secret hash and commitment
    var keysBuffer: Buffer
    let
      keysBufferPtr = addr(keysBuffer)
      done = key_gen(keysBufferPtr, true)
    require:
      # check whether the keys are generated successfully
      done

    let generatedKeys = cast[ptr array[4 * 32, byte]](keysBufferPtr.`ptr`)[]
    check:
      # the id trapdoor, nullifier, secert hash and commitment together are 4*32 bytes
      generatedKeys.len == 4 * 32
    info "generated keys: ", generatedKeys

  test "membership Key Generation":
    let idCredentialsRes = membershipKeyGen()
    require:
      idCredentialsRes.isOk()

    let idCredential = idCredentialsRes.get()
    let empty = default(array[32, byte])
    check:
      idCredential.idTrapdoor.len == 32
      idCredential.idNullifier.len == 32
      idCredential.idSecretHash.len == 32
      idCredential.idCommitment.len == 32
      idCredential.idTrapdoor != empty
      idCredential.idNullifier != empty
      idCredential.idSecretHash != empty
      idCredential.idCommitment != empty

    info "the generated identity credential: ", idCredential

  test "poseidon hash utils":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    # prepare the input
    let msg =
      @[
        "126f4c026cd731979365f79bd345a46d673c5a3f6f588bdc718e6356d02b6fdc".toBytes(),
        "1f0e5db2b69d599166ab16219a97b82b662085c93220382b39f9f911d3b943b1".toBytes(),
      ]

    let hashRes = poseidon(msg)

    # Value taken from zerokit
    check:
      hashRes.isOk()
      "28a15a991fe3d2a014485c7fa905074bfb55c0909112f865ded2be0a26a932c3" ==
        hashRes.get().inHex()

  test "RateLimitProof Protobuf encode/init test":
    var
      proof: ZKSNARK
      merkleRoot: MerkleNode
      epoch: Epoch
      shareX: MerkleNode
      shareY: MerkleNode
      nullifier: Nullifier
      rlnIdentifier: RlnIdentifier

    # populate fields with dummy values
    for x in proof.mitems:
      x = 1
    for x in merkleRoot.mitems:
      x = 2
    for x in epoch.mitems:
      x = 3
    for x in shareX.mitems:
      x = 4
    for x in shareY.mitems:
      x = 5
    for x in nullifier.mitems:
      x = 6
    for x in rlnIdentifier.mitems:
      x = 7

    let
      rateLimitProof = RateLimitProof(
        proof: proof,
        merkleRoot: merkleRoot,
        epoch: epoch,
        shareX: shareX,
        shareY: shareY,
        nullifier: nullifier,
        rlnIdentifier: rlnIdentifier,
      )
      protobuf = rateLimitProof.encode()
      decodednsp = RateLimitProof.init(protobuf.buffer)

    require:
      decodednsp.isOk()
    check:
      decodednsp.value == rateLimitProof

  test "toEpoch and fromEpoch consistency check":
    # check edge cases
    let
      epoch = uint64.high # rln epoch
      epochBytes = epoch.toEpoch()
      decodedEpoch = epochBytes.fromEpoch()
    check:
      epoch == decodedEpoch
    info "encoded and decode time",
      epoch = epoch, epochBytes = epochBytes, decodedEpoch = decodedEpoch

  test "Epoch comparison, epoch1 > epoch2":
    # check edge cases
    let
      time1 = uint64.high
      time2 = uint64.high - 1
      epoch1 = time1.toEpoch()
      epoch2 = time2.toEpoch()
    check:
      absDiff(epoch1, epoch2) == uint64(1)
      absDiff(epoch2, epoch1) == uint64(1)

  test "updateLog and hasDuplicate tests":
    let
      wakuRlnRelay = WakuRLNRelay()
      epoch = wakuRlnRelay.getCurrentEpoch()

    #  create some dummy nullifiers and secret shares
    var nullifier1: Nullifier
    for index, x in nullifier1.mpairs:
      nullifier1[index] = 1
    var shareX1: MerkleNode
    for index, x in shareX1.mpairs:
      shareX1[index] = 1
    let shareY1 = shareX1

    var nullifier2: Nullifier
    for index, x in nullifier2.mpairs:
      nullifier2[index] = 2
    var shareX2: MerkleNode
    for index, x in shareX2.mpairs:
      shareX2[index] = 2
    let shareY2 = shareX2

    let nullifier3 = nullifier1
    var shareX3: MerkleNode
    for index, x in shareX3.mpairs:
      shareX3[index] = 3
    let shareY3 = shareX3

    proc encodeAndGetBuf(proof: RateLimitProof): seq[byte] =
      return proof.encode().buffer

    let
      proof1 = RateLimitProof(
        epoch: epoch, nullifier: nullifier1, shareX: shareX1, shareY: shareY1
      )
      wm1 = WakuMessage(proof: proof1.encodeAndGetBuf())
      proof2 = RateLimitProof(
        epoch: epoch, nullifier: nullifier2, shareX: shareX2, shareY: shareY2
      )
      wm2 = WakuMessage(proof: proof2.encodeAndGetBuf())
      proof3 = RateLimitProof(
        epoch: epoch, nullifier: nullifier3, shareX: shareX3, shareY: shareY3
      )
      wm3 = WakuMessage(proof: proof3.encodeAndGetBuf())

    # check whether hasDuplicate correctly finds records with the same nullifiers but different secret shares
    # no duplicate for proof1 should be found, since the log is empty
    let proofMetadata1 = proof1.extractMetadata().tryGet()
    let isDuplicate1 = wakuRlnRelay.hasDuplicate(epoch, proofMetadata1).valueOr:
      raiseAssert $error
    assert isDuplicate1 == false, "no duplicate should be found"
    #  add it to the log
    discard wakuRlnRelay.updateLog(epoch, proofMetadata1)

    # no duplicate for proof2 should be found, its nullifier differs from proof1
    let proofMetadata2 = proof2.extractMetadata().tryGet()
    let isDuplicate2 = wakuRlnRelay.hasDuplicate(epoch, proofMetadata2).valueOr:
      raiseAssert $error
    # no duplicate is found
    assert isDuplicate2 == false, "no duplicate should be found"
    #  add it to the log
    discard wakuRlnRelay.updateLog(epoch, proofMetadata2)

    #  proof3 has the same nullifier as proof1 but different secret shares, it should be detected as duplicate
    let isDuplicate3 = wakuRlnRelay.hasDuplicate(
      epoch, proof3.extractMetadata().tryGet()
    ).valueOr:
      raiseAssert $error
    # it is a duplicate
    assert isDuplicate3, "duplicate should be found"

  asyncTest "validateMessageAndUpdateLog: against epoch gap":
    let index = MembershipIndex(5)

    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = index)
    var wakuRlnRelay: WakuRlnRelay
    lockNewGlobalBrokerContext:
      wakuRlnRelay = (await WakuRlnRelay.new(wakuRlnConfig)).valueOr:
        raiseAssert $error

    let manager = cast[OnchainGroupManager](wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials()

    try:
      waitFor manager.register(idCredentials, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let epoch1 = wakuRlnRelay.getCurrentEpoch()

    # Create messages from the same peer and append RLN proof to them (except wm4)
    var
      wm1 = WakuMessage(payload: "Valid message".toBytes(), timestamp: now())
      # Another message in the same epoch as wm1, expected to break the rate limit
      wm2 = WakuMessage(payload: "Spam message".toBytes(), timestamp: now())

    await sleepAsync(1.seconds)
    let epoch2 = wakuRlnRelay.getCurrentEpoch()

    var
      # wm3 points to the next epoch due to the sleep
      wm3 = WakuMessage(payload: "Valid message".toBytes(), timestamp: now())
      wm4 = WakuMessage(payload: "Invalid message".toBytes(), timestamp: now())

    # Append RLN proofs
    wakuRlnRelay.unsafeAppendRLNProof(wm1, epoch1, MessageId(1)).isOkOr:
      raiseAssert $error
    wakuRlnRelay.unsafeAppendRLNProof(wm2, epoch1, MessageId(1)).isOkOr:
      raiseAssert $error
    wakuRlnRelay.unsafeAppendRLNProof(wm3, epoch2, MessageId(3)).isOkOr:
      raiseAssert $error

    # Validate messages
    let
      msgValidate1 = wakuRlnRelay.validateMessageAndUpdateLog(wm1)
      # wm2 is within the same epoch as wm1 → should be spam
      msgValidate2 = wakuRlnRelay.validateMessageAndUpdateLog(wm2)
      # wm3 is in the next epoch → should be valid
      msgValidate3 = wakuRlnRelay.validateMessageAndUpdateLog(wm3)
      # wm4 has no RLN proof → should be invalid
      msgValidate4 = wakuRlnRelay.validateMessageAndUpdateLog(wm4)

    check:
      msgValidate1 == MessageValidationResult.Valid
      msgValidate2 == MessageValidationResult.Spam
      msgValidate3 == MessageValidationResult.Valid
      msgValidate4 == MessageValidationResult.Invalid

  asyncTest "validateMessageAndUpdateLog: against timestamp gap":
    let index = MembershipIndex(5)

    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = index)

    var wakuRlnRelay: WakuRlnRelay
    lockNewGlobalBrokerContext:
      wakuRlnRelay = (await WakuRlnRelay.new(wakuRlnConfig)).valueOr:
        raiseAssert $error

    let manager = cast[OnchainGroupManager](wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials()

    try:
      waitFor manager.register(idCredentials, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    # usually it's 20 seconds but we set it to 1 for testing purposes which make the test faster
    wakuRlnRelay.rlnMaxTimestampGap = 1

    var epoch = wakuRlnRelay.getCurrentEpoch()

    var
      wm1 = WakuMessage(
        payload: "timestamp message".toBytes(),
        contentTopic: DefaultPubsubTopic,
        timestamp: now(),
      )
      wm2 = WakuMessage(
        payload: "timestamp message".toBytes(),
        contentTopic: DefaultPubsubTopic,
        timestamp: now(),
      )

    wakuRlnRelay.unsafeAppendRLNProof(wm1, epoch, MessageId(1)).isOkOr:
      raiseAssert $error

    wakuRlnRelay.unsafeAppendRLNProof(wm2, epoch, MessageId(2)).isOkOr:
      raiseAssert $error

    # validate the first message because it's timestamp is the same as the generated timestamp
    let msgValidate1 = wakuRlnRelay.validateMessageAndUpdateLog(wm1)

    # wait for 2 seconds to make the timestamp different from generated timestamp
    await sleepAsync(2.seconds)

    let msgValidate2 = wakuRlnRelay.validateMessageAndUpdateLog(wm2)

    check:
      msgValidate1 == MessageValidationResult.Valid
      msgValidate2 == MessageValidationResult.Invalid

  asyncTest "multiple senders with same external nullifier":
    let index1 = MembershipIndex(5)
    let rlnConf1 = getWakuRlnConfig(manager = manager, index = index1)
    var wakuRlnRelay1: WakuRlnRelay
    lockNewGlobalBrokerContext:
      wakuRlnRelay1 = (await WakuRlnRelay.new(rlnConf1)).valueOr:
        raiseAssert "failed to create waku rln relay: " & $error

    let manager1 = cast[OnchainGroupManager](wakuRlnRelay1.groupManager)
    let idCredentials1 = generateCredentials()

    try:
      waitFor manager1.register(idCredentials1, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let index2 = MembershipIndex(6)
    let rlnConf2 = getWakuRlnConfig(manager = manager, index = index2)
    var wakuRlnRelay2: WakuRlnRelay
    lockNewGlobalBrokerContext:
      wakuRlnRelay2 = (await WakuRlnRelay.new(rlnConf2)).valueOr:
        raiseAssert "failed to create waku rln relay: " & $error

    let manager2 = cast[OnchainGroupManager](wakuRlnRelay2.groupManager)
    let idCredentials2 = generateCredentials()

    try:
      waitFor manager2.register(idCredentials2, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    # get the current epoch time
    let epoch = wakuRlnRelay1.getCurrentEpoch()

    #  create messages from different peers and append rln proofs to them
    var
      wm1 =
        WakuMessage(payload: "Valid message from sender 1".toBytes(), timestamp: now())
      # another message in the same epoch as wm1, it will break the messaging rate limit
      wm2 =
        WakuMessage(payload: "Valid message from sender 2".toBytes(), timestamp: now())

    wakuRlnRelay1.unsafeAppendRLNProof(wm1, epoch, MessageId(1)).isOkOr:
      raiseAssert $error
    wakuRlnRelay2.unsafeAppendRLNProof(wm2, epoch, MessageId(1)).isOkOr:
      raiseAssert $error

    let
      msgValidate1 = wakuRlnRelay1.validateMessageAndUpdateLog(wm1)
      msgValidate2 = wakuRlnRelay1.validateMessageAndUpdateLog(wm2)

    check:
      msgValidate1 == MessageValidationResult.Valid
      msgValidate2 == MessageValidationResult.Valid

  test "toIDCommitment and toUInt256":
    let idCredentialRes = membershipKeyGen()
    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()

    # convert the idCommitment to UInt256
    let idCUInt = idCredential.idCommitment.toUInt256()
    # convert the UInt256 back to ICommitment
    let idCommitment = toIDCommitment(idCUInt)

    # check that the conversion has not distorted the original value
    check:
      idCredential.idCommitment == idCommitment

  test "Read/Write RLN credentials":
    let idCredentialRes = membershipKeyGen()
    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()
    let empty = default(array[32, byte])
    require:
      idCredential.idTrapdoor.len == 32
      idCredential.idNullifier.len == 32
      idCredential.idSecretHash.len == 32
      idCredential.idCommitment.len == 32
      idCredential.idTrapdoor != empty
      idCredential.idNullifier != empty
      idCredential.idSecretHash != empty
      idCredential.idCommitment != empty

    info "the generated identity credential: ", idCredential

    let index = MembershipIndex(1)

    let keystoreMembership = KeystoreMembership(
      membershipContract: MembershipContract(
        chainId: "5", address: "0x0123456789012345678901234567890123456789"
      ),
      treeIndex: index,
      identityCredential: idCredential,
    )
    let password = "%m0um0ucoW%"

    let filepath = "./testRLNCredentials.txt"
    defer:
      removeFile(filepath)

    # Write RLN credentials
    require:
      addMembershipCredentials(
        path = filepath,
        membership = keystoreMembership,
        password = password,
        appInfo = RLNAppInfo,
      )
      .isOk()

    let readKeystoreRes = getMembershipCredentials(
      path = filepath,
      password = password,
      # here the query would not include
      # the identityCredential,
      # since it is not part of the query
      # but have used the same value
      # to avoid re-declaration
      query = keystoreMembership,
      appInfo = RLNAppInfo,
    )
    assert readKeystoreRes.isOk(), $readKeystoreRes.error

    # getMembershipCredentials returns the credential in the keystore which matches
    # the query, in this case the query is =
    # chainId = "5" and
    # address = "0x0123456789012345678901234567890123456789" and
    # treeIndex = 1
    let readKeystoreMembership = readKeystoreRes.get()
    check:
      readKeystoreMembership == keystoreMembership

  test "histogram static bucket generation":
    let buckets = generateBucketsForHistogram(10)

    check:
      buckets.len == 5
      buckets == [2.0, 4.0, 6.0, 8.0, 10.0]

  asyncTest "nullifierLog clearing only after epoch has passed":
    let index = MembershipIndex(0)

    proc runTestForEpochSizeSec(rlnEpochSizeSec: uint) {.async.} =
      let wakuRlnConfig = getWakuRlnConfig(
        manager = manager, index = index, epochSizeSec = rlnEpochSizeSec.uint64
      )
      var wakuRlnRelay: WakuRlnRelay
      lockNewGlobalBrokerContext:
        wakuRlnRelay = (await WakuRlnRelay.new(wakuRlnConfig)).valueOr:
          raiseAssert $error

      let rlnMaxEpochGap = wakuRlnRelay.rlnMaxEpochGap
      let testProofMetadata = default(ProofMetadata)
      let testProofMetadataTable =
        {testProofMetadata.nullifier: testProofMetadata}.toTable()

      for i in 0 .. rlnMaxEpochGap:
        # we add epochs to the nullifierLog
        let testEpoch = wakuRlnRelay.calcEpoch(epochTime() + float(rlnEpochSizeSec * i))
        wakuRlnRelay.nullifierLog[testEpoch] = testProofMetadataTable
        check:
          wakuRlnRelay.nullifierLog.len().uint == i + 1

      check:
        wakuRlnRelay.nullifierLog.len().uint == rlnMaxEpochGap + 1

      # clearing it now will remove 1 epoch
      wakuRlnRelay.clearNullifierLog()

      check:
        wakuRlnRelay.nullifierLog.len().uint == rlnMaxEpochGap

    var testEpochSizes: seq[uint] = @[1, 5, 10, 30, 60, 600]
    for i in testEpochSizes:
      await runTestForEpochSizeSec(i)

  asyncTest "testing rln-relay rate limit testing ":
    let index = MembershipIndex(7)

    # Generate a random rate limit between 20 and 600
    randomize()
    let randomRateLimit = rand(20 .. 600).uint

    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = index)
    let wakuRlnRelay = (await WakuRlnRelay.new(wakuRlnConfig)).valueOr:
      raiseAssert $error

    let manager = cast[OnchainGroupManager](wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials(manager.rlnInstance)

    # Register the membership with the random rate limit
    try:
      waitFor manager.register(idCredentials, UserMessageLimit(randomRateLimit))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    # Fetch the rate limit for the registered membership
    let rateLimitRes =
      await manager.fetchMembershipRateLimit(idCredentials.idCommitment)
    if rateLimitRes.isErr():
      raiseAssert "Failed to fetch membership rate limit: " & rateLimitRes.error

    let rateLimit = rateLimitRes.get()
    check:
      rateLimit == randomRateLimit.u256 # Check against the random rate limit
