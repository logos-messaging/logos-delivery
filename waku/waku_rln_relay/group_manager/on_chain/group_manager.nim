{.push raises: [].}

import
  os,
  web3,
  web3/eth_api_types,
  web3/primitives,
  eth/keys as keys,
  chronicles,
  nimcrypto/keccak as keccak,
  stint,
  json,
  std/[strutils, tables, algorithm, strformat],
  stew/[byteutils, arrayops],
  sequtils

import
  ../../../waku_keystore,
  ../../rln,
  ../../rln/rln_interface,
  ../../conversion_utils,
  ../group_manager_base,
  ./retry_wrapper,
  ./rpc_wrapper

export group_manager_base

logScope:
  topics = "waku rln_relay onchain_group_manager"

type
  WakuRlnContractWithSender = Sender[WakuRlnContract]
  OnchainGroupManager* = ref object of GroupManager
    ethClientUrls*: seq[string]
    ethPrivateKey*: Option[string]
    ethContractAddress*: string
    ethRpc*: Option[Web3]
    wakuRlnContract*: Option[WakuRlnContractWithSender]
    registrationTxHash*: Option[TxHash]
    chainId*: UInt256
    keystorePath*: Option[string]
    keystorePassword*: Option[string]
    registrationHandler*: Option[RegistrationHandler]
    latestProcessedBlock*: BlockNumber
    merkleProofCache*: seq[byte]

# The below code is not working with the latest web3 version due to chainId being null (specifically on linea-sepolia)
# TODO: find better solution than this custom sendEthCallWithoutParams call

proc fetchMerkleProofElements*(
    g: OnchainGroupManager
): Future[Result[seq[byte], string]] {.async.} =
  try:
    let membershipIndex = g.membershipIndex.get()
    let index40 = stuint(membershipIndex, 40)

    let methodSig = "getMerkleProof(uint40)"
    var paddedParam = newSeq[byte](32)
    let indexBytes = index40.toBytesBE()
    for i in 0 ..< min(indexBytes.len, paddedParam.len):
      paddedParam[paddedParam.len - indexBytes.len + i] = indexBytes[i]

    let response = await sendEthCallWithParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = methodSig,
      params = paddedParam,
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )

    return response
  except CatchableError:
    error "Failed to fetch Merkle proof elements", error = getCurrentExceptionMsg()
    return err("Failed to fetch merkle proof elements: " & getCurrentExceptionMsg())

proc fetchMerkleRoot*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  try:
    let merkleRoot = await sendEthCallWithoutParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "root()",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )
    return merkleRoot
  except CatchableError:
    error "Failed to fetch Merkle root", error = getCurrentExceptionMsg()
    return err("Failed to fetch merkle root: " & getCurrentExceptionMsg())

proc fetchNextFreeIndex*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  try:
    let nextFreeIndex = await sendEthCallWithoutParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "nextFreeIndex()",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )
    return nextFreeIndex
  except CatchableError:
    error "Failed to fetch next free index", error = getCurrentExceptionMsg()
    return err("Failed to fetch next free index: " & getCurrentExceptionMsg())

proc fetchMembershipStatus*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[Result[bool, string]] {.async.} =
  try:
    let params = idCommitment.reversed()
    let responseBytes = (
      await sendEthCallWithParams(
        ethRpc = g.ethRpc.get(),
        functionSignature = "isInMembershipSet(uint256)",
        params = params,
        fromAddress = g.ethRpc.get().defaultAccount,
        toAddress = fromHex(Address, g.ethContractAddress),
        chainId = g.chainId,
      )
    ).valueOr:
      return err("Failed to check membership: " & error)

    return ok(responseBytes.len == 32 and responseBytes[^1] == 1'u8)
  except CatchableError:
    error "Failed to fetch membership set membership", error = getCurrentExceptionMsg()
    return err("Failed to fetch membership set membership: " & getCurrentExceptionMsg())

proc fetchMaxMembershipRateLimit*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  try:
    let maxMembershipRateLimit = await sendEthCallWithoutParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "maxMembershipRateLimit()",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )
    return maxMembershipRateLimit
  except CatchableError:
    error "Failed to fetch max membership rate limit", error = getCurrentExceptionMsg()
    return err("Failed to fetch max membership rate limit: " & getCurrentExceptionMsg())

template initializedGuard(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(CatchableError, "OnchainGroupManager is not initialized")

template retryWrapper(
    g: OnchainGroupManager, res: auto, errStr: string, body: untyped
): auto =
  retryWrapper(res, RetryStrategy.new(), errStr, g.onFatalErrorAction):
    body

proc updateRoots*(g: OnchainGroupManager): Future[bool] {.async.} =
  let rootRes = (await g.fetchMerkleRoot()).valueOr:
    return false

  let merkleRoot = UInt256ToField(rootRes)

  if g.validRoots.len == 0:
    g.validRoots.addLast(merkleRoot)
    return true

  if g.validRoots[g.validRoots.len - 1] != merkleRoot:
    if g.validRoots.len > AcceptableRootWindowSize:
      discard g.validRoots.popFirst()
    g.validRoots.addLast(merkleRoot)
    return true

  return false

proc trackRootChanges*(g: OnchainGroupManager) {.async: (raises: [CatchableError]).} =
  try:
    initializedGuard(g)
    const rpcDelay = 5.seconds

    while true:
      await sleepAsync(rpcDelay)
      let rootUpdated = await g.updateRoots()

      if rootUpdated:
        ## The membership set on-chain has changed (some new members have joined or some members have left)
        if g.membershipIndex.isSome():
          ## A membership index exists only if the node has registered with RLN.
          ## Non-registered nodes cannot have Merkle proof elements.
          let proofResult = await g.fetchMerkleProofElements()
          if proofResult.isErr():
            error "Failed to fetch Merkle proof", error = proofResult.error
          else:
            g.merkleProofCache = proofResult.get()

        let nextFreeIndex = (await g.fetchNextFreeIndex()).valueOr:
          error "Failed to fetch next free index", error = error
          raise
            newException(CatchableError, "Failed to fetch next free index: " & error)

        let memberCount = cast[int64](nextFreeIndex)
        waku_rln_number_registered_memberships.set(float64(memberCount))
  except CatchableError:
    error "Fatal error in trackRootChanges", error = getCurrentExceptionMsg()

method register*(
    g: OnchainGroupManager, rateCommitment: RateCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  try:
    let leaf = rateCommitment.toLeaf().get()
    if g.registerCb.isSome():
      let idx = g.latestIndex
      info "registering member via callback", rateCommitment = leaf, index = idx
      await g.registerCb.get()(@[Membership(rateCommitment: leaf, index: idx)])
    g.latestIndex.inc()
  except CatchableError:
    raise newException(ValueError, getCurrentExceptionMsg())

method register*(
    g: OnchainGroupManager,
    identityCredential: IdentityCredential,
    userMessageLimit: UserMessageLimit,
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let wakuRlnContract = g.wakuRlnContract.get()

  var gasPrice: int
  g.retryWrapper(gasPrice, "Failed to get gas price"):
    let fetchedGasPrice = uint64(await ethRpc.provider.eth_gasPrice())
    ## Multiply by 2 to speed up the transaction
    ## Check for overflow when casting to int
    if fetchedGasPrice > uint64(high(int) div 2):
      warn "Gas price overflow detected, capping at maximum int value",
        fetchedGasPrice = fetchedGasPrice, maxInt = high(int)
      high(int)
    else:
      let calculatedGasPrice = int(fetchedGasPrice) * 2
      debug "Gas price calculated",
        fetchedGasPrice = fetchedGasPrice, gasPrice = calculatedGasPrice
      calculatedGasPrice
  let idCommitmentHex = identityCredential.idCommitment.inHex()
  debug "identityCredential idCommitmentHex", idCommitment = idCommitmentHex
  let idCommitment = identityCredential.idCommitment.toUInt256()
  let idCommitmentsToErase: seq[UInt256] = @[]
  info "registering the member",
    idCommitment = idCommitment,
    userMessageLimit = userMessageLimit,
    idCommitmentsToErase = idCommitmentsToErase
  var txHash: TxHash
  g.retryWrapper(txHash, "Failed to register the member"):
    await wakuRlnContract
      .register(idCommitment, userMessageLimit.stuint(32), idCommitmentsToErase)
      .send(gasPrice = gasPrice)

  # wait for the transaction to be mined
  var tsReceipt: ReceiptObject
  g.retryWrapper(tsReceipt, "Failed to get the transaction receipt"):
    await ethRpc.getMinedTransactionReceipt(txHash)
  debug "registration transaction mined", txHash = txHash
  g.registrationTxHash = some(txHash)
  # the receipt topic holds the hash of signature of the raised events
  debug "ts receipt", receipt = tsReceipt[]

  if tsReceipt.status.isNone():
    raise newException(ValueError, "Transaction failed: status is None")
  if tsReceipt.status.get() != 1.Quantity:
    raise newException(
      ValueError, "Transaction failed with status: " & $tsReceipt.status.get()
    )

  ## Search through all transaction logs to find the MembershipRegistered event
  let expectedEventSignature = cast[FixedBytes[32]](keccak.keccak256.digest(
    "MembershipRegistered(uint256,uint256,uint32)"
  ).data)

  var membershipRegisteredLog: Option[LogObject]
  for log in tsReceipt.logs:
    if log.topics.len > 0 and log.topics[0] == expectedEventSignature:
      membershipRegisteredLog = some(log)
      break

  if membershipRegisteredLog.isNone():
    raise newException(
      ValueError, "register: MembershipRegistered event not found in transaction logs"
    )

  let registrationLog = membershipRegisteredLog.get()

  ## Parse MembershipRegistered event data: idCommitment(256) || membershipRateLimit(256) || index(32)
  let arguments = registrationLog.data
  trace "registration transaction log data", arguments = arguments
  let
    ## Extract membership index from transaction log data (big endian)
    membershipIndex = UInt256.fromBytesBE(arguments[64 .. 95])

  trace "parsed membershipIndex", membershipIndex
  g.userMessageLimit = some(userMessageLimit)
  g.membershipIndex = some(membershipIndex.toMembershipIndex())
  g.idCredentials = some(identityCredential)

  let rateCommitment = RateCommitment(
      idCommitment: identityCredential.idCommitment, userMessageLimit: userMessageLimit
    )
    .toLeaf()
    .get()

  if g.registerCb.isSome():
    let member = Membership(rateCommitment: rateCommitment, index: g.latestIndex)
    await g.registerCb.get()(@[member])
  g.latestIndex.inc()

  return

method withdraw*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g) # TODO: after slashing is enabled on the contract

method withdrawBatch*(
    g: OnchainGroupManager, idCommitments: seq[IDCommitment]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

proc getRootFromProofAndIndex(
    g: OnchainGroupManager, elements: seq[byte], bits: seq[byte]
): GroupManagerResult[array[32, byte]] =
  # this is a helper function to get root from merkle proof elements and index
  # it's currently not used anywhere, but can be used to verify the root from the proof and index
  # Compute leaf hash from idCommitment and messageLimit
  let messageLimitField = uint64ToField(g.userMessageLimit.get())
  var hash = poseidon(@[g.idCredentials.get().idCommitment, @messageLimitField]).valueOr:
    return err("Failed to compute leaf hash: " & error)

  for i in 0 ..< bits.len:
    let sibling = elements[i * 32 .. (i + 1) * 32 - 1]

    let hashRes =
      if bits[i] == 0:
        poseidon(@[@hash, sibling])
      else:
        poseidon(@[sibling, @hash])

    hash = hashRes.valueOr:
      return err("Failed to compute poseidon hash: " & error)

  return ok(hash)

method generateProof*(
    g: OnchainGroupManager,
    data: seq[byte],
    epoch: Epoch,
    messageId: MessageId,
    rlnIdentifier = DefaultRlnIdentifier,
): GroupManagerResult[RateLimitProof] {.gcsafe, raises: [].} =
  ## Generates an RLN proof using the cached Merkle proof and custom witness
  # Ensure identity credentials and membership index are set
  if g.idCredentials.isNone():
    return err("identity credentials are not set")
  if g.membershipIndex.isNone():
    return err("membership index is not set")
  if g.userMessageLimit.isNone():
    return err("user message limit is not set")

  if (g.merkleProofCache.len mod 32) != 0:
    return err("Invalid merkle proof cache length")

  let identity_secret = seqToField(g.idCredentials.get().idSecretHash)
  let user_message_limit = uint64ToField(g.userMessageLimit.get())
  let message_id = uint64ToField(messageId)
  var path_elements = newSeq[byte](0)

  let identity_path_index = uint64ToIndex(g.membershipIndex.get(), 20)
  for i in 0 ..< g.merkleProofCache.len div 32:
    let chunk = g.merkleProofCache[i * 32 .. (i + 1) * 32 - 1]
    path_elements.add(chunk.reversed())

  let x = keccak.keccak256.digest(data)

  let extNullifier = generateExternalNullifier(epoch, rlnIdentifier).valueOr:
    return err("Failed to compute external nullifier: " & error)

  let witness = RLNWitnessInput(
    identity_secret: identity_secret,
    user_message_limit: user_message_limit,
    message_id: message_id,
    path_elements: path_elements,
    identity_path_index: identity_path_index,
    x: x,
    external_nullifier: extNullifier,
  )

  let serializedWitness = serialize(witness)

  var input_witness_buffer = toBuffer(serializedWitness)

  # Generate the proof using the zerokit API
  var output_witness_buffer: Buffer
  let witness_success = generate_proof_with_witness(
    g.rlnInstance, addr input_witness_buffer, addr output_witness_buffer
  )

  if not witness_success:
    return err("Failed to generate proof")

  # Parse the proof into a RateLimitProof object
  var proofValue = cast[ptr array[320, byte]](output_witness_buffer.`ptr`)
  let proofBytes: array[320, byte] = proofValue[]

  ## Parse the proof as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> ]
  let
    proofOffset = 128
    rootOffset = proofOffset + 32
    externalNullifierOffset = rootOffset + 32
    shareXOffset = externalNullifierOffset + 32
    shareYOffset = shareXOffset + 32
    nullifierOffset = shareYOffset + 32

  var
    zkproof: ZKSNARK
    proofRoot, shareX, shareY: MerkleNode
    externalNullifier: ExternalNullifier
    nullifier: Nullifier

  discard zkproof.copyFrom(proofBytes[0 .. proofOffset - 1])
  discard proofRoot.copyFrom(proofBytes[proofOffset .. rootOffset - 1])
  discard
    externalNullifier.copyFrom(proofBytes[rootOffset .. externalNullifierOffset - 1])
  discard shareX.copyFrom(proofBytes[externalNullifierOffset .. shareXOffset - 1])
  discard shareY.copyFrom(proofBytes[shareXOffset .. shareYOffset - 1])
  discard nullifier.copyFrom(proofBytes[shareYOffset .. nullifierOffset - 1])

  # Create the RateLimitProof object
  let output = RateLimitProof(
    proof: zkproof,
    merkleRoot: proofRoot,
    externalNullifier: externalNullifier,
    epoch: epoch,
    rlnIdentifier: rlnIdentifier,
    shareX: shareX,
    shareY: shareY,
    nullifier: nullifier,
  )

  info "Proof generated successfully", proof = output

  waku_rln_remaining_proofs_per_epoch.dec()
  waku_rln_total_generated_proofs.inc()
  return ok(output)

method verifyProof*(
    g: OnchainGroupManager, input: seq[byte], proof: RateLimitProof
): GroupManagerResult[bool] {.gcsafe, raises: [].} =
  ## -- Verifies an RLN rate-limit proof against the set of valid Merkle roots --

  var normalizedProof = proof

  let externalNullifier = generateExternalNullifier(proof.epoch, proof.rlnIdentifier).valueOr:
    return err("Failed to compute external nullifier: " & error)
  normalizedProof.externalNullifier = externalNullifier

  let proofBytes = serialize(normalizedProof, input)
  let proofBuffer = proofBytes.toBuffer()

  let rootsBytes = serialize(g.validRoots.items().toSeq())
  let rootsBuffer = rootsBytes.toBuffer()

  var validProof: bool # out-param
  let ffiOk = verify_with_roots(
    g.rlnInstance, # RLN context created at init()
    addr proofBuffer, # (proof + signal)
    addr rootsBuffer, # valid Merkle roots
    addr validProof # will be set by the FFI call
    ,
  )

  if not ffiOk:
    return err("could not verify the proof")
  else:
    info "Proof verified successfully"

  return ok(validProof)

method onRegister*(g: OnchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

method onWithdraw*(g: OnchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

proc establishConnection(
    g: OnchainGroupManager
): Future[GroupManagerResult[Web3]] {.async.} =
  var ethRpc: Web3

  g.retryWrapper(ethRpc, "Failed to connect to the Ethereum client"):
    var innerEthRpc: Web3
    var connected = false
    for clientUrl in g.ethClientUrls:
      ## We give a chance to the user to provide multiple clients
      ## and we try to connect to each of them
      try:
        innerEthRpc = await newWeb3(clientUrl)
        connected = true
        break
      except CatchableError:
        error "failed connect Eth client", error = getCurrentExceptionMsg()

    if not connected:
      raise newException(CatchableError, "all failed")

    innerEthRpc

  return ok(ethRpc)

method init*(g: OnchainGroupManager): Future[GroupManagerResult[void]] {.async.} =
  # check if the Ethereum client is reachable
  let ethRpc: Web3 = (await establishConnection(g)).valueOr:
    return err("failed to connect to Ethereum clients: " & $error)

  var fetchedChainId: UInt256
  g.retryWrapper(fetchedChainId, "Failed to get the chain id"):
    await ethRpc.provider.eth_chainId()

  # Set the chain id
  if g.chainId == 0:
    warn "Chain ID not set in config, using RPC Provider's Chain ID",
      providerChainId = fetchedChainId

  if g.chainId != 0 and g.chainId != fetchedChainId:
    return err(
      "The RPC Provided a Chain ID which is different than the provided Chain ID: provided = " &
        $g.chainId & ", actual = " & $fetchedChainId
    )

  g.chainId = fetchedChainId

  if g.ethPrivateKey.isSome():
    let pk = g.ethPrivateKey.get()
    let parsedPk = keys.PrivateKey.fromHex(pk).valueOr:
      return err("failed to parse the private key" & ": " & $error)
    ethRpc.privateKey = Opt.some(parsedPk)
    ethRpc.defaultAccount =
      ethRpc.privateKey.get().toPublicKey().toCanonicalAddress().Address

  let contractAddress = web3.fromHex(web3.Address, g.ethContractAddress)
  let wakuRlnContract = ethRpc.contractSender(WakuRlnContract, contractAddress)

  g.ethRpc = some(ethRpc)
  g.wakuRlnContract = some(wakuRlnContract)

  if g.keystorePath.isSome() and g.keystorePassword.isSome():
    if not fileExists(g.keystorePath.get()):
      error "File provided as keystore path does not exist", path = g.keystorePath.get()
      return err("File provided as keystore path does not exist")

    var keystoreQuery = KeystoreMembership(
      membershipContract:
        MembershipContract(chainId: $g.chainId, address: g.ethContractAddress)
    )
    if g.membershipIndex.isSome():
      keystoreQuery.treeIndex = MembershipIndex(g.membershipIndex.get())
    waku_rln_membership_credentials_import_duration_seconds.nanosecondTime:
      let keystoreCred = getMembershipCredentials(
        path = g.keystorePath.get(),
        password = g.keystorePassword.get(),
        query = keystoreQuery,
        appInfo = RLNAppInfo,
      ).valueOr:
        return err("failed to get the keystore credentials: " & $error)

    g.membershipIndex = some(keystoreCred.treeIndex)
    g.userMessageLimit = some(keystoreCred.userMessageLimit)
    # now we check on the contract if the commitment actually has a membership
    let idCommitmentBytes = keystoreCred.identityCredential.idCommitment
    let idCommitmentUInt256 = keystoreCred.identityCredential.idCommitment.toUInt256()
    let idCommitmentHex = idCommitmentBytes.inHex()
    info "Keystore idCommitment in bytes", idCommitmentBytes = idCommitmentBytes
    info "Keystore idCommitment in UInt256 ", idCommitmentUInt256 = idCommitmentUInt256
    info "Keystore idCommitment in hex ", idCommitmentHex = idCommitmentHex
    let idCommitment = keystoreCred.identityCredential.idCommitment
    let membershipExists = (await g.fetchMembershipStatus(idCommitment)).valueOr:
      return err("the commitment does not have a membership: " & error)
    info "membershipExists", membershipExists = membershipExists

    g.idCredentials = some(keystoreCred.identityCredential)

  let maxMembershipRateLimitRes = await g.fetchMaxMembershipRateLimit()
  let maxMembershipRateLimit = maxMembershipRateLimitRes.valueOr:
    return err("failed to fetch max membership rate limit: " & error)

  g.rlnRelayMaxMessageLimit = cast[uint64](maxMembershipRateLimit)

  proc onDisconnect() {.async.} =
    error "Ethereum client disconnected"

    var newEthRpc: Web3 = (await g.establishConnection()).valueOr:
      g.onFatalErrorAction("failed to connect to Ethereum clients onDisconnect")
      return

    newEthRpc.ondisconnect = ethRpc.ondisconnect
    g.ethRpc = some(newEthRpc)

  ethRpc.ondisconnect = proc() =
    asyncSpawn onDisconnect()

  g.initialized = true
  return ok()

method stop*(g: OnchainGroupManager): Future[void] {.async, gcsafe.} =
  if g.ethRpc.isSome():
    g.ethRpc.get().ondisconnect = nil
    await g.ethRpc.get().close()

  g.initialized = false

method isReady*(g: OnchainGroupManager): Future[bool] {.async.} =
  initializedGuard(g)

  if g.ethRpc.isNone():
    return false

  if g.wakuRlnContract.isNone():
    return false

  return true
