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
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  results,
  stew/[byteutils, arrayops]
import
  ./group_manager,
  ./rln,
  ./conversion_utils,
  ./constants,
  ./protocol_types,
  ./protocol_metrics,
  ./nonce_manager

import
  waku/[
    common/error_handling,
    waku_relay, # for WakuRelayHandler
    waku_core,
    requests/rln_requests,
    waku_keystore,
    common/broker/broker_context,
  ]

logScope:
  topics = "waku rln_relay"

type RlnRelayCreds* {.requiresInit.} = object
  path*: string
  password*: string

type RlnRelayConf* = object of RootObj
  # TODO: severals parameters are only needed when it's dynamic
  # change the config to either nest or use enum/type variant so it's obvious
  # and then it can be set to `requiresInit`
  dynamic*: bool
  credIndex*: Option[uint]
  ethContractAddress*: string
  ethClientUrls*: seq[string]
  chainId*: UInt256
  creds*: Option[RlnRelayCreds]
  epochSizeSec*: uint64
  userMessageLimit*: uint64
  ethPrivateKey*: Option[string]

type WakuRlnConfig* = object of RlnRelayConf
  onFatalErrorAction*: OnFatalErrorHandler

type WakuRLNRelay* = ref object of RootObj
  # the log of nullifiers and Shamir shares of the past messages grouped per epoch
  nullifierLog*: OrderedTable[Epoch, Table[Nullifier, ProofMetadata]]
  lastEpoch*: Epoch # the epoch of the last published rln message
  rlnEpochSizeSec*: uint64
  rlnMaxTimestampGap*: uint64
  rlnMaxEpochGap*: uint64
  groupManager*: GroupManager
  onFatalErrorAction*: OnFatalErrorHandler
  nonceManager*: NonceManager
  epochMonitorFuture*: Future[void]
  rootChangesFuture*: Future[void]
  brokerCtx*: BrokerContext

proc calcEpoch*(rlnPeer: WakuRLNRelay, t: float64): Epoch =
  ## gets time `t` as `flaot64` with subseconds resolution in the fractional part
  ## and returns its corresponding rln `Epoch` value

  let e = uint64(t / rlnPeer.rlnEpochSizeSec.float64)
  return toEpoch(e)

proc nextEpoch*(rlnPeer: WakuRLNRelay, time: float64): float64 =
  let
    currentEpoch = uint64(time / rlnPeer.rlnEpochSizeSec.float64)
    nextEpochTime = float64(currentEpoch + 1) * rlnPeer.rlnEpochSizeSec.float64
    currentTime = epochTime()

  # Ensure we always return a future time
  if nextEpochTime > currentTime:
    return nextEpochTime
  else:
    return epochTime()

proc stop*(rlnPeer: WakuRLNRelay) {.async: (raises: [Exception]).} =
  ## stops the rln-relay protocol
  ## Throws an error if it cannot stop the rln-relay protocol

  # stop the group sync, and flush data to tree db
  info "stopping rln-relay"
  RequestGenerateRlnProof.clearProvider(rlnPeer.brokerCtx)
  await rlnPeer.groupManager.stop()

proc hasDuplicate*(
    rlnPeer: WakuRLNRelay, epoch: Epoch, proofMetadata: ProofMetadata
): RlnRelayResult[bool] =
  ## returns true if there is another message in the  `nullifierLog` of the `rlnPeer` with the same
  ## epoch and nullifier as `proofMetadata`'s epoch and nullifier
  ## otherwise, returns false
  ## Returns an error if it cannot check for duplicates

  # check if the epoch exists
  let nullifier = proofMetadata.nullifier
  if not rlnPeer.nullifierLog.hasKey(epoch):
    return ok(false)
  try:
    if rlnPeer.nullifierLog[epoch].hasKey(nullifier):
      # there is an identical record, mark it as spam
      return ok(true)

    # there is no duplicate
    return ok(false)
  except KeyError:
    return err("the epoch was not found: " & getCurrentExceptionMsg())

proc updateLog*(
    rlnPeer: WakuRLNRelay, epoch: Epoch, proofMetadata: ProofMetadata
): RlnRelayResult[void] =
  ## saves supplied proofMetadata `proofMetadata`
  ## in the `nullifierLog` of the `rlnPeer`
  ## Returns an error if it cannot update the log

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKeyOrPut(
    epoch, {proofMetadata.nullifier: proofMetadata}.toTable()
  ):
    return ok()

  try:
    # check if an identical record exists
    if rlnPeer.nullifierLog[epoch].hasKeyOrPut(proofMetadata.nullifier, proofMetadata):
      # the above condition could be `discarded` but it is kept for clarity, that slashing will
      # be implemented here
      # TODO: slashing logic
      return ok()
    return ok()
  except KeyError:
    return
      err("the epoch was not found: " & getCurrentExceptionMsg()) # should never happen

proc getCurrentEpoch*(rlnPeer: WakuRLNRelay): Epoch =
  return rlnPeer.calcEpoch(epochTime())

proc absDiff*(e1, e2: Epoch): uint64 =
  ## returns the absolute difference between the two rln `Epoch`s `e1` and `e2`
  ## i.e., e1 - e2

  # convert epochs to their corresponding unsigned numerical values
  let
    epoch1 = fromEpoch(e1)
    epoch2 = fromEpoch(e2)

  # Manually perform an `abs` calculation
  if epoch1 > epoch2:
    return epoch1 - epoch2
  else:
    return epoch2 - epoch1

proc toRLNSignal*(wakumessage: WakuMessage): seq[byte] =
  ## it is a utility proc that prepares the `data` parameter of the proof generation procedure i.e., `proofGen`  that resides in the current module
  ## it extracts the `contentTopic`, `timestamp` and the `payload` of the supplied `wakumessage` and serializes them into a byte sequence

  let
    contentTopicBytes = toBytes(wakumessage.contentTopic)
    timestampBytes = toBytes(wakumessage.timestamp.uint64)
    output = concat(wakumessage.payload, contentTopicBytes, @(timestampBytes))
  return output

proc validateMessage*(
    rlnPeer: WakuRLNRelay, msg: WakuMessage
): MessageValidationResult =
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
      timeDiff = timeDiff, maxTimestampGap = rlnPeer.rlnMaxTimestampGap
    waku_rln_invalid_messages_total.inc(labelValues = ["invalid_timestamp"])
    return MessageValidationResult.Invalid

  let computedEpoch = rlnPeer.calcEpoch(messageTime)
  if proof.epoch != computedEpoch:
    warn "invalid message: timestamp mismatches epoch",
      proofEpoch = fromEpoch(proof.epoch), computedEpoch = fromEpoch(computedEpoch)
    waku_rln_invalid_messages_total.inc(labelValues = ["timestamp_mismatch"])
    return MessageValidationResult.Invalid

  let rootValidationRes = rlnPeer.groupManager.validateRoot(proof.merkleRoot)
  if not rootValidationRes:
    warn "invalid message: provided root does not belong to acceptable window of roots",
      provided = proof.merkleRoot.inHex(),
      validRoots = rlnPeer.groupManager.validRoots.mapIt(it.inHex())
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
    warn "invalid message: proof verification failed", payloadLen = msg.payload.len
    return MessageValidationResult.Invalid

  if not proofVerificationRes.value():
    # invalid proof
    warn "invalid message: invalid proof", payloadLen = msg.payload.len
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
    trace "invalid message: message is spam", payloadLen = msg.payload.len
    waku_rln_spam_messages_total.inc()
    return MessageValidationResult.Spam

  trace "message is valid", payloadLen = msg.payload.len
  # Metric increment moved to validator to include shard label
  return MessageValidationResult.Valid

proc validateMessageAndUpdateLog*(
    rlnPeer: WakuRLNRelay, msg: WakuMessage
): MessageValidationResult =
  ## validates the message and updates the log to prevent double messaging
  ## in future messages

  let isValidMessage = rlnPeer.validateMessage(msg)

  let msgProof = RateLimitProof.init(msg.proof).valueOr:
    return MessageValidationResult.Invalid

  let proofMetadata = msgProof.extractMetadata().valueOr:
    return MessageValidationResult.Invalid

  # insert the message to the log (never errors) only if the
  # message is valid.
  if isValidMessage == MessageValidationResult.Valid:
    discard rlnPeer.updateLog(msgProof.epoch, proofMetadata)

  return isValidMessage

proc createRlnProof(
    rlnPeer: WakuRLNRelay, msg: WakuMessage, senderEpochTime: float64
): RlnRelayResult[seq[byte]] =
  ## returns a new `RateLimitProof` for the supplied `msg`
  ## returns an error if it cannot create the proof
  ## `senderEpochTime` indicates the number of seconds passed since Unix epoch. The fractional part holds sub-seconds.
  ## The `epoch` field of `RateLimitProof` is derived from the provided `senderEpochTime` (using `calcEpoch()`)

  let input = msg.toRLNSignal()
  let epoch = rlnPeer.calcEpoch(senderEpochTime)

  let nonce = rlnPeer.nonceManager.getNonce().valueOr:
    return err("could not get new message id to generate an rln proof: " & $error)
  let proof = rlnPeer.groupManager.generateProof(input, epoch, nonce).valueOr:
    return err("could not generate rln-v2 proof: " & $error)

  return ok(proof.encode().buffer)

proc appendRLNProof*(
    rlnPeer: WakuRLNRelay, msg: var WakuMessage, senderEpochTime: float64
): RlnRelayResult[void] =
  msg.proof = rlnPeer.createRlnProof(msg, senderEpochTime).valueOr:
    return err($error)

  return ok()

proc clearNullifierLog*(rlnPeer: WakuRlnRelay) =
  # clear the first MaxEpochGap epochs of the nullifer log
  # if more than MaxEpochGap epochs are in the log
  let currentEpoch = fromEpoch(rlnPeer.getCurrentEpoch())

  var epochsToRemove: seq[Epoch] = @[]
  for epoch in rlnPeer.nullifierLog.keys():
    let epochInt = fromEpoch(epoch)

    # clean all epochs that are +- rlnMaxEpochGap from the current epoch
    if (currentEpoch + rlnPeer.rlnMaxEpochGap) <= epochInt or
        epochInt <= (currentEpoch - rlnPeer.rlnMaxEpochGap):
      epochsToRemove.add(epoch)

  for epochRemove in epochsToRemove:
    trace "clearing epochs from the nullifier log",
      currentEpoch = currentEpoch, cleanedEpoch = fromEpoch(epochRemove)
    rlnPeer.nullifierLog.del(epochRemove)

proc generateRlnValidator*(
    wakuRlnRelay: WakuRLNRelay, spamHandler = none(SpamHandler)
): WakuValidatorHandler =
  ## this procedure is a thin wrapper for the pubsub addValidator method
  ## it sets a validator for waku messages, acting in the registered pubsub topic
  ## the message validation logic is according to https://rfc.vac.dev/spec/17/
  proc validator(
      topic: string, message: WakuMessage
  ): Future[pubsub.ValidationResult] {.async.} =
    trace "rln-relay topic validator is called"
    wakuRlnRelay.clearNullifierLog()

    let msgProof = RateLimitProof.init(message.proof).valueOr:
      trace "generateRlnValidator reject", error = error
      return pubsub.ValidationResult.Reject

    # validate the message and update log
    let validationRes = wakuRlnRelay.validateMessageAndUpdateLog(message)

    let
      proof = toHex(msgProof.proof)
      epoch = fromEpoch(msgProof.epoch)
      root = inHex(msgProof.merkleRoot)
      shareX = inHex(msgProof.shareX)
      shareY = inHex(msgProof.shareY)
      nullifier = inHex(msgProof.nullifier)
      payload = string.fromBytes(message.payload)
    case validationRes
    of Valid:
      trace "message validity is verified, relaying",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      waku_rln_valid_messages_total.inc(labelValues = [topic])
      return pubsub.ValidationResult.Accept
    of Invalid:
      trace "message validity could not be verified, discarding",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      return pubsub.ValidationResult.Reject
    of Spam:
      trace "A spam message is found! yay! discarding:",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      if spamHandler.isSome():
        let handler = spamHandler.get()
        handler(message)
      return pubsub.ValidationResult.Reject

  return validator

proc monitorEpochs(wakuRlnRelay: WakuRLNRelay) {.async.} =
  while true:
    try:
      if wakuRlnRelay.groupManager.userMessageLimit.isSome():
        waku_rln_remaining_proofs_per_epoch.set(
          wakuRlnRelay.groupManager.userMessageLimit.get().float64
        )
      else:
        error "userMessageLimit is not set in monitorEpochs"
    except CatchableError:
      error "Error in epoch monitoring", error = getCurrentExceptionMsg()

    let nextEpochTime = wakuRlnRelay.nextEpoch(epochTime())
    let sleepDuration = int((nextEpochTime - epochTime()) * 1000)
    await sleepAsync(sleepDuration)

proc mount(
    conf: WakuRlnConfig, registrationHandler = none(RegistrationHandler)
): Future[RlnRelayResult[WakuRlnRelay]] {.async.} =
  var
    groupManager: GroupManager
    wakuRlnRelay: WakuRLNRelay
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

  wakuRlnRelay = WakuRLNRelay(
    groupManager: groupManager,
    nonceManager: NonceManager.init(conf.userMessageLimit, conf.epochSizeSec.float),
    rlnEpochSizeSec: conf.epochSizeSec,
    rlnMaxEpochGap: max(uint64(MaxClockGapSeconds / float64(conf.epochSizeSec)), 1),
    rlnMaxTimestampGap: uint64(MaxClockGapSeconds),
    onFatalErrorAction: conf.onFatalErrorAction,
    brokerCtx: globalBrokerContext(),
  )

  # track root changes on smart contract merkle tree
  if groupManager of OnchainGroupManager:
    let onchainManager = cast[OnchainGroupManager](groupManager)
    wakuRlnRelay.rootChangesFuture = onchainManager.trackRootChanges()

  # Start epoch monitoring in the background
  wakuRlnRelay.epochMonitorFuture = monitorEpochs(wakuRlnRelay)

  RequestGenerateRlnProof.setProvider(
    wakuRlnRelay.brokerCtx,
    proc(
        msg: WakuMessage, senderEpochTime: float64
    ): Future[Result[RequestGenerateRlnProof, string]] {.async.} =
      let proof = createRlnProof(wakuRlnRelay, msg, senderEpochTime).valueOr:
        return err("Could not create RLN proof: " & $error)

      return ok(RequestGenerateRlnProof(proof: proof)),
  ).isOkOr:
    return err("Proof generator provider cannot be set: " & $error)

  return ok(wakuRlnRelay)

proc isReady*(rlnPeer: WakuRLNRelay): Future[bool] {.async: (raises: [Exception]).} =
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
    T: type WakuRlnRelay,
    conf: WakuRlnConfig,
    registrationHandler = none(RegistrationHandler),
): Future[RlnRelayResult[WakuRlnRelay]] {.async.} =
  ## Mounts the rln-relay protocol on the node.
  ## The rln-relay protocol can be mounted in two modes: on-chain and off-chain.
  ## Returns an error if the rln-relay protocol could not be mounted.
  try:
    return await mount(conf, registrationHandler)
  except CatchableError:
    return err("could not mount the rln-relay protocol: " & getCurrentExceptionMsg())
