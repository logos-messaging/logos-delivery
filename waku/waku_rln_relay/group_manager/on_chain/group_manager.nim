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
  stew/byteutils,
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

const RootRefreshDebounceInterval* = 1.seconds
  ## Minimum gap between on-demand recent-roots refreshes triggered by
  ## `validateRoot` misses, to bound contract-call rate under spam.

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
    lastRefreshAt*: Moment
    pendingRefresh*: Future[bool]
      ## Non-nil while an on-demand recent-roots refresh is in flight, so that
      ## concurrent `validateRoot` misses can ride along on a single RPC.

# The below code is not working with the latest web3 version due to chainId being null (specifically on linea-sepolia)
# TODO: find better solution than this custom sendEthCallWithoutParams call

proc fetchMerkleProofElements*(
    g: OnchainGroupManager
): Future[Result[seq[byte], string]] {.async.} =
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
    fromAddress = g.ethRpc.get().defaultAccount,
    toAddress = fromHex(Address, g.ethContractAddress),
    chainId = g.chainId,
    params = paddedParam,
  )

  return response

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

proc fetchMerkleRootsCache*(
    g: OnchainGroupManager
): Future[Result[seq[byte], string]] {.async.} =
  let
    # using sendEthCallWithParams to get return type of seq[bytes] for getRecentRoots() function which returns an array of bytes32
    merkleRoots = await sendEthCallWithParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "getRecentRoots()",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )
  return merkleRoots

proc fetchNextFreeIndex*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  let nextFreeIndex = await sendEthCallWithoutParams(
    ethRpc = g.ethRpc.get(),
    functionSignature = "nextFreeIndex()",
    fromAddress = g.ethRpc.get().defaultAccount,
    toAddress = fromHex(Address, g.ethContractAddress),
    chainId = g.chainId,
  )
  return nextFreeIndex

proc fetchMembershipStatus*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[Result[bool, string]] {.async.} =
  let params = idCommitment.reversed()
  let responseBytes = (
    await sendEthCallWithParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "isInMembershipSet(uint256)",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
      params = params,
    )
  ).valueOr:
    return err("Failed to check membership: " & error)

  return ok(responseBytes.len == 32 and responseBytes[^1] == 1'u8)

proc fetchMaxMembershipRateLimit*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  let maxMembershipRateLimit = await sendEthCallWithoutParams(
    ethRpc = g.ethRpc.get(),
    functionSignature = "maxMembershipRateLimit()",
    fromAddress = g.ethRpc.get().defaultAccount,
    toAddress = fromHex(Address, g.ethContractAddress),
    chainId = g.chainId,
  )

  return maxMembershipRateLimit

proc checkInitialized(g: OnchainGroupManager): Result[void, string] =
  if not g.initialized:
    return err("OnchainGroupManager is not initialized")
  return ok()

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

proc updateRecentRoots*(g: OnchainGroupManager): Future[bool] {.async.} =
  ## Fetch recent roots from the contract roots cache and update the validRoots deque, ensuring we maintain a window of unique acceptable roots.
  ## Contract returns array of uint256 roots, newest first, zero-padded to the cache size (e.g. 5).
  let bytes = (await g.fetchMerkleRootsCache()).valueOr:
    error "Failed to fetch current Merkle root", error = error
    return false

  if (bytes.len mod 32) != 0:
    error "Invalid recent roots payload length", length = bytes.len
    return false

  let chunkCount = bytes.len div 32
  if chunkCount != RlnContractRootCacheSize:
    warn "Unexpected number of recent roots returned; proceeding anyway",
      count = chunkCount

  # Parse 32-byte chunks (contract returns newest-first) into MerkleNode values,
  # reversing to oldest-first and skipping zero roots.
  var newRootsDequeOrder: seq[MerkleNode] = @[]
  for startIdx in countdown(bytes.len - 32, 0, 32):
    let u = UInt256.fromBytesBE(bytes.toOpenArray(startIdx, startIdx + 31))
    if u.isZero:
      continue
    newRootsDequeOrder.add(UInt256ToField(u))

  if newRootsDequeOrder.len == 0:
    debug "no non-zero recent roots to add; skipping update"
    return false

  # Determine overlap with existing tail so we only append truly new roots
  let overlap = min(g.validRoots.len, newRootsDequeOrder.len)
  var matchLen = 0
  for startIdx in (g.validRoots.len - overlap) ..< g.validRoots.len:
    if g.validRoots[startIdx] == newRootsDequeOrder[0]:
      matchLen = g.validRoots.len - startIdx
      break

  let toAdd = newRootsDequeOrder[matchLen ..< newRootsDequeOrder.len]
  if toAdd.len == 0:
    return false

  # Append new roots to the tail; trim happens below if we exceed the window.
  for root in toAdd:
    g.validRoots.addLast(root)
  debug "appended recent roots to list of valid roots", count = toAdd.len, roots = toAdd

  while g.validRoots.len > AcceptableRootWindowSize:
    discard g.validRoots.popFirst()

  return true

proc syncFromContract*(g: OnchainGroupManager): Future[bool] {.async.} =
  ## Refresh validRoots from the contract's recent-roots cache. If anything
  ## changed and this node is a registered member, also refresh the local
  ## Merkle proof cache so subsequent generateProof calls use the latest tree.
  ## Returns whether validRoots was updated.
  let rootUpdated = await g.updateRecentRoots()
  if rootUpdated and g.membershipIndex.isSome():
    ## A membership index exists only if the node has registered with RLN.
    ## Non-registered nodes cannot have Merkle proof elements.
    let proofResult = await g.fetchMerkleProofElements()
    if proofResult.isErr():
      error "Failed to fetch Merkle proof", error = proofResult.error
    else:
      g.merkleProofCache = proofResult.get()
  return rootUpdated

proc trackRootChanges*(g: OnchainGroupManager): Future[Result[void, string]] {.async.} =
  ?checkInitialized(g)

  const rpcDelay = 10.seconds

  while true:
    let rootUpdated = await g.syncFromContract()

    if rootUpdated:
      ## The membership set on-chain has changed (some new members have joined or some members have left)
      let nextFreeIndex = (await g.fetchNextFreeIndex()).valueOr:
        error "Failed to fetch next free index", error = error
        return err("Failed to fetch next free index: " & error)

      let memberCount = cast[int64](nextFreeIndex)
      waku_rln_number_registered_memberships.set(float64(memberCount))
    await sleepAsync(rpcDelay)

method register*(
    g: OnchainGroupManager, rateCommitment: RateCommitment
): Future[Result[void, string]] {.async.} =
  ?checkInitialized(g)

  try:
    let leaf = rateCommitment.toLeaf().get()
    if g.registerCb.isSome():
      let idx = g.latestIndex
      info "registering member via callback", rateCommitment = leaf, index = idx
      await g.registerCb.get()(@[Membership(rateCommitment: leaf, index: idx)])
    g.latestIndex.inc()
  except Exception as e:
    return err("Failed to call register callback: " & e.msg)

  return ok()

method register*(
    g: OnchainGroupManager,
    identityCredential: IdentityCredential,
    userMessageLimit: UserMessageLimit,
): Future[Result[void, string]] {.async.} =
  ?checkInitialized(g)

  let ethRpc = g.ethRpc.get()
  let wakuRlnContract = g.wakuRlnContract.get()

  let gasPrice = (
    await retryWrapper(
      RetryStrategy.new(),
      "Failed to get gas price",
      proc(): Future[int] {.async.} =
        let fetchedGasPrice = uint64(await ethRpc.provider.eth_gasPrice())
        if fetchedGasPrice > uint64(high(int) div 2):
          warn "Gas price overflow detected, capping at maximum int value",
            fetchedGasPrice = fetchedGasPrice, maxInt = high(int)
          return high(int)
        else:
          let calculatedGasPrice = int(fetchedGasPrice) * 2
          debug "Gas price calculated",
            fetchedGasPrice = fetchedGasPrice, gasPrice = calculatedGasPrice
          return calculatedGasPrice,
    )
  ).valueOr:
    return err("Failed to get gas price: " & error)

  let idCommitmentHex = identityCredential.idCommitment.inHex()
  debug "identityCredential idCommitmentHex", idCommitment = idCommitmentHex
  let idCommitment = identityCredential.idCommitment.toUInt256()
  let idCommitmentsToErase: seq[UInt256] = @[]
  info "registering the member",
    idCommitment = idCommitment,
    userMessageLimit = userMessageLimit,
    idCommitmentsToErase = idCommitmentsToErase
  let txHash = (
    await retryWrapper(
      RetryStrategy.new(),
      "Failed to register the member",
      proc(): Future[TxHash] {.async.} =
        return await wakuRlnContract
          .register(idCommitment, userMessageLimit.stuint(32), idCommitmentsToErase)
          .send(gasPrice = gasPrice),
    )
  ).valueOr:
    return err("Failed to register member: " & error)

  # wait for the transaction to be mined
  let tsReceipt = (
    await retryWrapper(
      RetryStrategy.new(),
      "Failed to get the transaction receipt",
      proc(): Future[ReceiptObject] {.async.} =
        return await ethRpc.getMinedTransactionReceipt(txHash),
    )
  ).valueOr:
    return err("Failed to get transaction receipt: " & error)
  debug "registration transaction mined", txHash = txHash
  g.registrationTxHash = some(txHash)
  # the receipt topic holds the hash of signature of the raised events
  debug "ts receipt", receipt = tsReceipt[]

  if tsReceipt.status.isNone():
    return err("Transaction failed: status is None")
  if tsReceipt.status.get() != 1.Quantity:
    return err("Transaction failed with status: " & $tsReceipt.status.get())

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
    return err("register: MembershipRegistered event not found in transaction logs")

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
    try:
      await g.registerCb.get()(@[member])
    except Exception as e:
      return err("Failed to call register callback: " & e.msg)
  g.latestIndex.inc()

  return ok()

method withdraw*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[Result[void, string]] {.async.} =
  checkInitialized(g).isOkOr:
    return err(error)
  return ok()

method withdrawBatch*(
    g: OnchainGroupManager, idCommitments: seq[IDCommitment]
): Future[Result[void, string]] {.async.} =
  checkInitialized(g).isOkOr:
    return err(error)

  return ok()

proc getRootFromProofAndIndex(
    g: OnchainGroupManager, elements: seq[byte], bits: seq[byte]
): GroupManagerResult[array[32, byte]] =
  # this is a helper function to get root from merkle proof elements and index
  # it's currently not used anywhere, but can be used to verify the root from the proof and index
  # Compute leaf hash from idCommitment and messageLimit
  let messageLimitField = uint64ToField(g.userMessageLimit.get())
  var hash = poseidon(g.idCredentials.get().idCommitment, @messageLimitField).valueOr:
    return err("Failed to compute leaf hash: " & error)

  for i in 0 ..< bits.len:
    let sibling = elements[i * 32 .. (i + 1) * 32 - 1]

    let hashRes =
      if bits[i] == 0:
        poseidon(@hash, sibling)
      else:
        poseidon(sibling, @hash)

    hash = hashRes.valueOr:
      return err("Failed to compute poseidon hash: " & error)

  return ok(hash)

method generateProof*(
    g: OnchainGroupManager,
    data: seq[byte],
    epoch: Epoch,
    messageId: MessageId,
    rlnIdentifier = DefaultRlnIdentifier,
): GroupManagerResult[RateLimitProof] {.gcsafe.} =
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

  let xCfr = hashToFieldLe(data).valueOr:
    return err("Failed to hash signal to field: " & error)
  defer:
    ffi_cfr_free(xCfr)
  let x = cfrToBytesLe(xCfr).valueOr:
    return err("Failed to serialize signal hash: " & error)

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

  waku_rln_proof_generation_duration_seconds.nanosecondTime:
    let output = generateRlnProofWithWitness(
      g.rlnInstance, witness, epoch, rlnIdentifier
    ).valueOr:
      return err("Failed to generate proof: " & error)

  info "Proof generated successfully", proof = output

  waku_rln_remaining_proofs_per_epoch.dec()
  waku_rln_total_generated_proofs.inc()
  return ok(output)

method validateRoot*(g: OnchainGroupManager, root: MerkleNode): Future[bool] {.async.} =
  ## Validates the root against the local valid roots window. If the root is
  ## not found, refresh the local window from the on-chain recent-roots cache
  ## and re-check once before giving up. Concurrent misses share a single
  ## in-flight refresh; new refreshes are debounced by
  ## `RootRefreshDebounceInterval` to bound contract-call rate.
  if g.indexOfRoot(root) >= 0:
    return true

  # Coalesce: if a refresh is already in flight, ride along instead of starting a new one.
  if not g.pendingRefresh.isNil and not g.pendingRefresh.finished:
    debug "Root validation missed but refresh already in flight; waiting for refresh to complete"
    discard await g.pendingRefresh
    return g.indexOfRoot(root) >= 0

  # Debounce: don't queue another refresh too soon after the previous one.
  let now = Moment.now()
  if now - g.lastRefreshAt < RootRefreshDebounceInterval:
    debug "Root validation missed but refresh is recently performed; skipping refresh"
    return false

  g.lastRefreshAt = now
  debug "Root not found in valid roots; refreshing from contract cache"
  g.pendingRefresh = g.syncFromContract()
  discard await g.pendingRefresh

  return g.indexOfRoot(root) >= 0

method verifyProof*(
    g: OnchainGroupManager, input: seq[byte], proof: RateLimitProof
): GroupManagerResult[bool] {.gcsafe.} =
  let validProof = verifyRlnProof(
    g.rlnInstance, proof, input, g.validRoots.items().toSeq()
  ).valueOr:
    return err("could not verify the proof: " & error)

  info "Proof verified", isValid = validProof
  return ok(validProof)

method onRegister*(g: OnchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

method onWithdraw*(g: OnchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

proc establishConnection(
    g: OnchainGroupManager
): Future[GroupManagerResult[Web3]] {.async.} =
  let ethRpc = (
    await retryWrapper(
      RetryStrategy.new(),
      "Failed to connect to the Ethereum client",
      proc(): Future[Web3] {.async.} =
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

        ## this exception is handled by the retrywrapper
        if not connected:
          raise newException(CatchableError, "all failed")

        return innerEthRpc,
    )
  ).valueOr:
    return err("Failed to establish Ethereum connection: " & error)

  return ok(ethRpc)

method init*(g: OnchainGroupManager): Future[GroupManagerResult[void]] {.async.} =
  # check if the Ethereum client is reachable
  let ethRpc: Web3 = (await establishConnection(g)).valueOr:
    return err("failed to connect to Ethereum clients: " & $error)

  let fetchedChainId = (
    await retryWrapper(
      RetryStrategy.new(),
      "Failed to get the chain id",
      proc(): Future[UInt256] {.async.} =
        return await ethRpc.provider.eth_chainId(),
    )
  ).valueOr:
    return err("Failed to get chain id: " & error)

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

    let newEthRpc: Web3 = (await g.establishConnection()).valueOr:
      error "Fatal: failed to reconnect to Ethereum clients after disconnect",
        error = error
      g.onFatalErrorAction("failed to reconnect to Ethereum clients: " & error)
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

  if not g.rlnInstance.isNil:
    ffi_rln_free(g.rlnInstance)
    g.rlnInstance = nil

  g.initialized = false

method isReady*(g: OnchainGroupManager): Future[bool] {.async.} =
  checkInitialized(g).isOkOr:
    return false

  if g.ethRpc.isNone():
    error "Ethereum RPC client is not configured"
    return false

  if g.wakuRlnContract.isNone():
    error "Waku RLN contract is not configured"
    return false
  return true
