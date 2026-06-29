import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import
  std/[sequtils, tables, times, deques],
  chronicles,
  options,
  chronos,
  stint,
  web3,
  json,
  web3/eth_api_types,
  eth/keys,
  results,
  stew/[byteutils, arrayops],
  brokers/broker_context

import
  ./group_manager,
  ./bindings,
  ./conversion_utils,
  ./constants,
  ./protocol_types,
  ./protocol_metrics,
  ./nonce_manager,
  ./types,
  ./config,
  ./proof,
  ./nullifier_log

import
  logos_delivery/waku/
    [common/error_handling, waku_core, requests/rln_requests, waku_keystore]

# Re-export the submodules so existing `import rln`
# (and `import rln/rln`) callers see the moved symbols
# (Rln, WakuRlnConfig, generateRLNProof, etc.).
export types, config, proof, nullifier_log

logScope:
  topics = "waku rln"

proc stop*(rlnPeer: Rln) {.async: (raises: [Exception]).} =
  ## stops the rln-relay protocol
  ## Throws an error if it cannot stop the rln-relay protocol

  # stop the group sync, and flush data to tree db
  info "stopping rln-relay"
  RequestGenerateRlnProof.clearProvider(rlnPeer.brokerCtx)
  await rlnPeer.groupManager.stop()

proc validateMessage*(
    rlnPeer: Rln, msg: WakuMessage
): Future[MessageValidationResult] {.async.} =
  ## validate the supplied `msg` based on the waku-rln-relay routing protocol i.e.,
  ## the `msg`'s epoch is within MaxEpochGap of the current epoch
  ## the `msg` has valid rate limit proof
  ## the `msg` does not violate the rate limit
  ## `timeOption` indicates Unix epoch time (fractional part holds sub-seconds)
  ## if `timeOption` is supplied, then the current epoch is calculated based on that

  let proof = RateLimitProof.init(msg.proof).valueOr:
    return MessageValidationResult.Invalid

  # track message count for metrics
  waku_rln_messages_total.inc()

  # checks if the message's timestamp is within acceptable range
  let currentTime = getTime().toUnixFloat()
  let messageTime = msg.timestamp.float64 / 1e9

  let timeDiff = uint64(abs(currentTime - messageTime))

  info "time info",
    currentTime = currentTime, messageTime = messageTime, msgHash = msg.hash

  if timeDiff > rlnPeer.rlnMaxTimestampGap:
    warn "invalid message: timestamp difference exceeds threshold",
      timeDiff = timeDiff,
      maxTimestampGap = rlnPeer.rlnMaxTimestampGap,
      contentTopic = msg.contentTopic
    waku_rln_invalid_messages_total.inc(labelValues = ["invalid_timestamp"])
    return MessageValidationResult.Invalid

  let computedEpoch = rlnPeer.calcEpoch(messageTime)
  if proof.epoch != computedEpoch:
    warn "invalid message: timestamp mismatches epoch",
      proofEpoch = fromEpoch(proof.epoch),
      computedEpoch = fromEpoch(computedEpoch),
      contentTopic = msg.contentTopic
    waku_rln_invalid_messages_total.inc(labelValues = ["timestamp_mismatch"])
    return MessageValidationResult.Invalid

  let rootValidationRes = await rlnPeer.groupManager.validateRoot(proof.merkleRoot)
  if not rootValidationRes:
    warn "invalid message: provided root does not belong to acceptable window of roots",
      provided = proof.merkleRoot.inHex(),
      validRoots = rlnPeer.groupManager.validRoots.mapIt(it.inHex()),
      contentTopic = msg.contentTopic
    waku_rln_invalid_messages_total.inc(labelValues = ["invalid_root"])
    return MessageValidationResult.Invalid

  # verify the proof
  let
    contentTopicBytes = toBytes(msg.contentTopic)
    timestampBytes = toBytes(msg.timestamp.uint64)
    input = concat(msg.payload, contentTopicBytes, @(timestampBytes))

  waku_rln_proof_verification_total.inc()
  waku_rln_proof_verification_duration_seconds.nanosecondTime:
    let proofVerificationRes =
      rlnPeer.groupManager.verifyProof(msg.toRLNSignal(), proof)

  proofVerificationRes.isOkOr:
    waku_rln_errors_total.inc(labelValues = ["proof_verification"])
    warn "invalid message: proof verification failed",
      payloadLen = msg.payload.len, contentTopic = msg.contentTopic
    return MessageValidationResult.Invalid

  if not proofVerificationRes.value():
    # invalid proof
    warn "invalid message: invalid proof",
      payloadLen = msg.payload.len, contentTopic = msg.contentTopic
    waku_rln_invalid_messages_total.inc(labelValues = ["invalid_proof"])
    return MessageValidationResult.Invalid

  # check if double messaging has happened
  let proofMetadata = proof.extractMetadata().valueOr:
    waku_rln_errors_total.inc(labelValues = ["proof_metadata_extraction"])
    return MessageValidationResult.Invalid

  let msgEpoch = proof.epoch
  let hasDup = rlnPeer.hasDuplicate(msgEpoch, proofMetadata)
  if hasDup.isErr():
    waku_rln_errors_total.inc(labelValues = ["duplicate_check"])
  elif hasDup.value == true:
    trace "invalid message: message is spam",
      payloadLen = msg.payload.len, contentTopic = msg.contentTopic
    waku_rln_spam_messages_total.inc()
    return MessageValidationResult.Spam

  trace "message is valid",
    payloadLen = msg.payload.len, contentTopic = msg.contentTopic
  # Metric increment moved to validator to include shard label
  return MessageValidationResult.Valid

proc validateMessageAndUpdateLog*(
    rlnPeer: Rln, msg: WakuMessage
): Future[MessageValidationResult] {.async.} =
  ## validates the message and updates the log to prevent double messaging
  ## in future messages

  let isValidMessage = await rlnPeer.validateMessage(msg)

  let msgProof = RateLimitProof.init(msg.proof).valueOr:
    return MessageValidationResult.Invalid

  let proofMetadata = msgProof.extractMetadata().valueOr:
    return MessageValidationResult.Invalid

  # insert the message to the log (never errors) only if the
  # message is valid.
  if isValidMessage == MessageValidationResult.Valid:
    discard rlnPeer.updateLog(msgProof.epoch, proofMetadata)

  return isValidMessage

proc monitorEpochs(rln: Rln) {.async.} =
  while true:
    try:
      if rln.groupManager.userMessageLimit.isSome():
        waku_rln_remaining_proofs_per_epoch.set(
          rln.groupManager.userMessageLimit.get().float64
        )
      else:
        error "userMessageLimit is not set in monitorEpochs"
    except CatchableError:
      error "Error in epoch monitoring", error = getCurrentExceptionMsg()

    let nextEpochTime = rln.nextEpoch(epochTime())
    let sleepDuration = int((nextEpochTime - epochTime()) * 1000)
    await sleepAsync(sleepDuration)

proc mount(
    conf: WakuRlnConfig, registrationHandler = none(RegistrationHandler)
): Future[RlnResult[Rln]] {.async.} =
  var
    groupManager: GroupManager
    rln: Rln
  # create an RLN instance
  let rlnInstance = createRLNInstance().valueOr:
    return err("could not create RLN instance: " & $error)

  let (rlnRelayCredPath, rlnRelayCredPassword) =
    if conf.creds.isSome:
      (some(conf.creds.get().path), some(conf.creds.get().password))
    else:
      (none(string), none(string))

  groupManager = OnchainGroupManager(
    userMessageLimit: some(conf.userMessageLimit),
    ethClientUrls: conf.ethClientUrls,
    ethContractAddress: $conf.ethContractAddress,
    chainId: conf.chainId,
    rlnInstance: rlnInstance,
    registrationHandler: registrationHandler,
    keystorePath: rlnRelayCredPath,
    keystorePassword: rlnRelayCredPassword,
    ethPrivateKey: conf.ethPrivateKey,
    membershipIndex: conf.credIndex,
    onFatalErrorAction: conf.onFatalErrorAction,
  )

  # Initialize the groupManager
  (await groupManager.init()).isOkOr:
    return err("could not initialize the group manager: " & $error)

  rln = Rln(
    groupManager: groupManager,
    nonceManager: NonceManager.init(conf.userMessageLimit, conf.epochSizeSec.float),
    rlnEpochSizeSec: conf.epochSizeSec,
    rlnMaxEpochGap: max(uint64(MaxClockGapSeconds / float64(conf.epochSizeSec)), 1),
    rlnMaxTimestampGap: uint64(MaxClockGapSeconds),
    onFatalErrorAction: conf.onFatalErrorAction,
    brokerCtx: globalBrokerContext(),
  )

  # Start epoch monitoring in the background
  rln.epochMonitorFuture = monitorEpochs(rln)

  RequestGenerateRlnProof.setProvider(
    rln.brokerCtx,
    proc(
        msg: WakuMessage, senderEpochTime: float64
    ): Future[Result[RequestGenerateRlnProof, string]] {.async.} =
      let proof = (await rln.generateRLNProof(msg.toRLNSignal(), senderEpochTime)).valueOr:
        return err("Could not create RLN proof: " & error)

      return ok(RequestGenerateRlnProof(proof: proof)),
  ).isOkOr:
    return err("Proof generator provider cannot be set: " & $error)

  return ok(rln)

proc isReady*(rlnPeer: Rln): Future[bool] {.async.} =
  ## returns true if the rln-relay protocol is ready to relay messages
  ## returns false otherwise

  # could be nil during startup
  if rlnPeer.groupManager == nil:
    return false
  try:
    return await rlnPeer.groupManager.isReady()
  except CatchableError:
    error "could not check if the rln-relay protocol is ready",
      err = getCurrentExceptionMsg()
    return false

proc new*(
    T: type Rln, conf: WakuRlnConfig, registrationHandler = none(RegistrationHandler)
): Future[RlnResult[Rln]] {.async.} =
  ## Mounts the rln-relay protocol on the node.
  ## The rln-relay protocol can be mounted in two modes: on-chain and off-chain.
  ## Returns an error if the rln-relay protocol could not be mounted.
  try:
    return await mount(conf, registrationHandler)
  except CatchableError:
    return err("could not mount the rln-relay protocol: " & getCurrentExceptionMsg())
