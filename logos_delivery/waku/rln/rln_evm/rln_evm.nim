{.push raises: [].}

import
  std/[sequtils, tables, times, deques],
  chronicles,
  chronos,
  stint,
  web3,
  json,
  web3/eth_api_types,
  eth/keys,
  results,
  stew/[byteutils, arrayops]

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

import logos_delivery/waku/[common/error_handling, waku_core, waku_keystore]
import logos_delivery/waku/rln/types as rln_api_types
import logos_delivery/waku/rln/rln_plugin

# Re-export the submodules so existing `import rln`
# callers see the moved symbols
# (RlnEvm, WakuRlnConfig, generateRLNProof, etc.).
export types, config, proof, nullifier_log

logScope:
  topics = "waku rln"

proc stop*(rlnEvm: RlnEvm) {.async: (raises: [Exception]).} =
  ## stops the rln protocol and epochmonitoring
  ## Throws an error if it cannot stop the rln protocol

  if not rlnEvm.epochMonitorFuture.isNil():
    await rlnEvm.epochMonitorFuture.cancelAndWait()

  # stop the group sync, and flush data to tree db
  info "stopping rln"
  await rlnEvm.groupManager.stop()

proc validateMessage*(
    rlnEvm: RlnEvm, msg: WakuMessage
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
  logos_delivery_rln_messages_total.inc()

  # checks if the message's timestamp is within acceptable range
  let currentTime = getTime().toUnixFloat()
  let messageTime = msg.timestamp.float64 / 1e9

  let timeDiff = uint64(abs(currentTime - messageTime))

  trace "Time info",
    currentTime = currentTime, messageTime = messageTime, msgHash = msg.hash

  if timeDiff > rlnEvm.rlnMaxTimestampGap:
    debug "Invalid message: timestamp difference exceeds threshold",
      timeDiff = timeDiff,
      maxTimestampGap = rlnEvm.rlnMaxTimestampGap,
      contentTopic = msg.contentTopic
    logos_delivery_rln_invalid_messages_total.inc(labelValues = ["invalid_timestamp"])
    return MessageValidationResult.Invalid

  let computedEpoch = rlnEvm.calcEpoch(messageTime)
  if proof.epoch != computedEpoch:
    debug "Invalid message: timestamp mismatches epoch",
      proofEpoch = fromEpoch(proof.epoch),
      computedEpoch = fromEpoch(computedEpoch),
      contentTopic = msg.contentTopic
    logos_delivery_rln_invalid_messages_total.inc(labelValues = ["timestamp_mismatch"])
    return MessageValidationResult.Invalid

  let rootValidationRes = await rlnEvm.groupManager.validateRoot(proof.merkleRoot)
  if not rootValidationRes:
    debug "Invalid message: provided root does not belong to acceptable window of roots",
      provided = proof.merkleRoot.inHex(),
      validRoots = rlnEvm.groupManager.validRoots.mapIt(it.inHex()),
      contentTopic = msg.contentTopic
    logos_delivery_rln_invalid_messages_total.inc(labelValues = ["invalid_root"])
    return MessageValidationResult.Invalid

  # verify the proof
  let
    contentTopicBytes = toBytes(msg.contentTopic)
    timestampBytes = toBytes(msg.timestamp.uint64)
    input = concat(msg.payload, contentTopicBytes, @(timestampBytes))

  logos_delivery_rln_proof_verification_total.inc()
  logos_delivery_rln_proof_verification_duration_seconds.nanosecondTime:
    let proofVerificationRes = rlnEvm.groupManager.verifyProof(msg.toRLNSignal(), proof)

  proofVerificationRes.isOkOr:
    logos_delivery_rln_errors_total.inc(labelValues = ["proof_verification"])
    debug "Invalid message: proof verification failed",
      payloadLen = msg.payload.len, contentTopic = msg.contentTopic
    return MessageValidationResult.Invalid

  if not proofVerificationRes.value():
    # invalid proof
    debug "Invalid message: invalid proof",
      payloadLen = msg.payload.len, contentTopic = msg.contentTopic
    logos_delivery_rln_invalid_messages_total.inc(labelValues = ["invalid_proof"])
    return MessageValidationResult.Invalid

  # check if double messaging has happened
  let proofMetadata = proof.extractMetadata().valueOr:
    logos_delivery_rln_errors_total.inc(labelValues = ["proof_metadata_extraction"])
    return MessageValidationResult.Invalid

  let msgEpoch = proof.epoch
  let hasDup = rlnEvm.hasDuplicate(msgEpoch, proofMetadata)
  if hasDup.isErr():
    logos_delivery_rln_errors_total.inc(labelValues = ["duplicate_check"])
  elif hasDup.value == true:
    trace "invalid message: message is spam",
      payloadLen = msg.payload.len, contentTopic = msg.contentTopic
    logos_delivery_rln_spam_messages_total.inc()
    return MessageValidationResult.Spam

  trace "message is valid",
    payloadLen = msg.payload.len, contentTopic = msg.contentTopic
  # Metric increment moved to validator to include shard label
  return MessageValidationResult.Valid

proc validateMessageAndUpdateLog*(
    rlnEvm: RlnEvm, msg: WakuMessage
): Future[MessageValidationResult] {.async.} =
  ## validates the message and updates the log to prevent double messaging
  ## in future messages

  let isValidMessage = await rlnEvm.validateMessage(msg)

  let msgProof = RateLimitProof.init(msg.proof).valueOr:
    return MessageValidationResult.Invalid

  let proofMetadata = msgProof.extractMetadata().valueOr:
    return MessageValidationResult.Invalid

  # insert the message to the log (never errors) only if the
  # message is valid.
  if isValidMessage == MessageValidationResult.Valid:
    discard rlnEvm.updateLog(msgProof.epoch, proofMetadata)

  return isValidMessage

proc monitorEpochs(rlnEvm: RlnEvm) {.async.} =
  while true:
    try:
      if rlnEvm.groupManager.userMessageLimit.isSome():
        logos_delivery_rln_remaining_proofs_per_epoch.set(
          rlnEvm.groupManager.userMessageLimit.get().float64
        )
      else:
        debug "userMessageLimit is not set in monitorEpochs"
    except CatchableError:
      error "Error in epoch monitoring", error = getCurrentExceptionMsg()

    let nextEpochTime = rlnEvm.nextEpoch(epochTime())
    let sleepDuration = int((nextEpochTime - epochTime()) * 1000)
    await sleepAsync(sleepDuration)

proc mount(
    conf: WakuRlnConfig, registrationHandler = Opt.none(RegistrationHandler)
): Future[Result[RlnEvm, string]] {.async.} =
  var
    groupManager: RlnEvmGroupManagerBase
    rlnEvm: RlnEvm
  # create an RLN instance
  let rlnInstance = createRLNInstance().valueOr:
    return err("could not create RLN instance: " & $error)

  let (rlnRelayCredPath, rlnRelayCredPassword) =
    if conf.creds.isSome:
      (Opt.some(conf.creds.get().path), Opt.some(conf.creds.get().password))
    else:
      (Opt.none(string), Opt.none(string))

  groupManager = RlnEvmGroupManager(
    userMessageLimit: Opt.some(conf.userMessageLimit),
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

  rlnEvm = RlnEvm(
    groupManager: groupManager,
    nonceManager: NonceManager.init(conf.userMessageLimit, conf.epochSizeSec.float),
    rlnEpochSizeSec: conf.epochSizeSec,
    rlnMaxEpochGap: max(uint64(MaxClockGapSeconds / float64(conf.epochSizeSec)), 1),
    rlnMaxTimestampGap: uint64(MaxClockGapSeconds),
    onFatalErrorAction: conf.onFatalErrorAction,
  )

  # Start epoch monitoring in the background
  rlnEvm.epochMonitorFuture = monitorEpochs(rlnEvm)

  return ok(rlnEvm)

proc isReady*(rlnEvm: RlnEvm): Future[bool] {.async.} =
  ## returns true if the rln-relay protocol is ready to relay messages
  ## returns false otherwise

  # could be nil during startup
  if rlnEvm.groupManager == nil:
    return false
  try:
    return await rlnEvm.groupManager.isReady()
  except CatchableError:
    debug "could not check if the rln-relay protocol is ready",
      err = getCurrentExceptionMsg()
    return false

proc toRlnPlugin*(rlnEvm: RlnEvm): RlnPlugin =
  ## The node's handle on this backend (`node.rlnPlugin`). The closures
  ## capture this instance, so each node reaches only its own backend.
  proc stopBackend(): Future[void] {.async.} =
    try:
      await rlnEvm.stop() ## this can raise an exception
    except Exception:
      error "exception stopping the node", error = getCurrentExceptionMsg()

  proc backendReady(): Future[bool] {.async.} =
    return await rlnEvm.isReady()

  proc proofRejected() =
    rlnEvm.groupManager.scheduleMerkleProofRefresh()

  proc validate(
      message: WakuMessage
  ): Future[Result[ValidationResult, RlnError]] {.async.} =
    ## Drops nullifier-log epochs outside the accepted window, then validates
    ## the proof and logs it if valid; the in-node nullifier log does duplicate
    ## and spam detection.
    rlnEvm.clearNullifierLog()

    let msgProof = protocol_types.RateLimitProof.init(message.proof).valueOr:
      trace "Rln validator reject", error = error
      return ok(ValidationResult(verdict: ProofVerdict.Invalid))

    let validationRes = await rlnEvm.validateMessageAndUpdateLog(message)
    trace "Rln proof checked",
      validation = validationRes,
      root = inHex(msgProof.merkleRoot),
      shareX = inHex(msgProof.shareX),
      shareY = inHex(msgProof.shareY),
      nullifier = inHex(msgProof.nullifier)

    let verdict =
      case validationRes
      of MessageValidationResult.Valid: ProofVerdict.Valid
      of MessageValidationResult.Invalid: ProofVerdict.Invalid
      of MessageValidationResult.Spam: ProofVerdict.RateLimitViolation
    return ok(ValidationResult(verdict: verdict))

  proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
    ## Uses the wall clock and the root-refreshing generator: a message can
    ## wait in the send service's task cache while the group root moves on
    ## chain.
    let proof = (
      await rlnEvm.generateRLNProofWithRootRefresh(
        message.toRLNSignal(), float64(getTime().toUnix())
      )
    ).valueOr:
      return err(RlnError.transient(error))
    return ok(proof)

  return RlnPlugin(
    name: "onchain",
    stop: stopBackend,
    isReady: backendReady,
    onProofRejected: proofRejected,
    validateProof: validate,
    generateProof: generate,
  )

proc new*(
    T: type RlnEvm,
    conf: WakuRlnConfig,
    registrationHandler = Opt.none(RegistrationHandler),
): Future[Result[RlnEvm, string]] {.async.} =
  ## Mounts the rln-relay protocol on the node.
  ## The rln-relay protocol can be mounted in two modes: on-chain and off-chain.
  ## Returns an error if the rln-relay protocol could not be mounted.
  try:
    return await mount(conf, registrationHandler)
  except CatchableError:
    return err("could not mount the rln-relay protocol: " & getCurrentExceptionMsg())

proc mountOnchain*(
    conf: WakuRlnConfig, registrationHandler = Opt.none(RegistrationHandler)
): Future[Result[RlnEvm, string]] {.async.} =
  ## `RlnEvm.new` plus the contract-limit check, shared by the factory's
  ## descriptor and `setRlnValidator`.
  let rln = ?(await RlnEvm.new(conf, registrationHandler))
  if conf.userMessageLimit > rln.groupManager.rlnRelayMaxMessageLimit:
    error "Rln-user-message-limit can't exceed the MAX_MESSAGE_LIMIT in the rln contract"
  return ok(rln)

proc rlnEvmDescriptor*(
    conf: Opt[RlnConf], onMounted: proc(rln: RlnEvm) {.gcsafe, raises: [].}
): RlnPluginDescriptor =
  ## Selected when on-chain RLN configuration came from the CLI or a preset.
  ## `onMounted` receives the mounted instance before the record is returned.
  proc present(): bool =
    conf.isSome()

  proc mount(commonConf: RlnCommonConf): Future[Result[RlnPlugin, string]] {.async.} =
    let evmConf = conf.get()
    let rlnConf = WakuRlnConfig(
      dynamic: evmConf.dynamic,
      credIndex: evmConf.credIndex,
      ethContractAddress: evmConf.ethContractAddress,
      chainId: evmConf.chainId,
      ethClientUrls: evmConf.ethClientUrls,
      creds: evmConf.creds,
      userMessageLimit: evmConf.userMessageLimit,
      epochSizeSec: evmConf.epochSizeSec,
      onFatalErrorAction: commonConf.onFatalErrorAction,
      disableValidation: commonConf.disableValidation,
    )
    let rln = (await mountOnchain(rlnConf)).valueOr:
      return err(
        "failed to mount waku RLN relay protocol: failed to set rln validator: " & error
      )
    onMounted(rln)
    return ok(rln.toRlnPlugin())

  return RlnPluginDescriptor(name: "onchain", matches: present, mount: mount)
