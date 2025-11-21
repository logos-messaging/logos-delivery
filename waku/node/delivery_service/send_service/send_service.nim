## This module reinforces the publish operation with regular store-v3 requests.
##

import std/[sequtils, tables, options]
import chronos, chronicles, libp2p/utility
import
  ./[send_processor, relay_processor, lightpush_processor, delivery_task],
  waku/[
    waku_core,
    node/waku_node,
    node/peer_manager,
    waku_store/client,
    waku_store/common,
    waku_archive/archive,
    waku_relay/protocol,
    waku_rln_relay/rln_relay,
    waku_lightpush/client,
    waku_lightpush/callbacks,
    events/delivery_events,
    events/message_events,
  ]

logScope:
  topics = "send service"

# This useful util is missing from sequtils, this extends applyIt with predicate...
template applyItIf*(varSeq, pred, op: untyped) =
  for i in low(varSeq) .. high(varSeq):
    let it {.inject.} = varSeq[i]
    if pred:
      op
      varSeq[i] = it

template forEach*(varSeq, op: untyped) =
  for i in low(varSeq) .. high(varSeq):
    let it {.inject.} = varSeq[i]
    op

const MaxTimeInCache* = chronos.minutes(1)
  ## Messages older than this time will get completely forgotten on publication and a
  ## feedback will be given when that happens

const ServiceLoopInterval* = chronos.seconds(1)
  ## Interval at which we check that messages have been properly received by a store node

const ArchiveTime = chronos.seconds(3)
  ## Estimation of the time we wait until we start confirming that a message has been properly
  ## received and archived by a store node

type SendService* = ref object of RootObj
  taskCache: seq[DeliveryTask]
    ## Cache that contains the delivery task per message hash.
    ## This is needed to make sure the published messages are properly published

  serviceLoopHandle: Future[void] ## handle that allows to stop the async task
  sendProcessor: BaseSendProcessor

  node: WakuNode
  checkStoreForMessages: bool

proc setupSendProcessorChain(
    peerManager: PeerManager,
    lightpushClient: WakuLightPushClient,
    relay: WakuRelay,
    rlnRelay: WakuRLNRelay,
): Result[BaseSendProcessor, string] =
  let isRelayAvail = not relay.isNil()
  let isLightPushAvail = not lightpushClient.isNil()

  if not isRelayAvail and not isLightPushAvail:
    return err("No valid send processor found for the delivery task")

  var processors = newSeq[BaseSendProcessor]()

  if isRelayAvail:
    let rln: Option[WakuRLNRelay] =
      if rlnRelay.isNil():
        none[WakuRLNRelay]()
      else:
        some(rlnRelay)
    let publishProc = getRelayPushHandler(relay, rln)

    processors.add(RelaySendProcessor.new(isLightPushAvail, publishProc))
  if isLightPushAvail:
    processors.add(LightpushSendProcessor.new(peerManager, lightpushClient))

  var currentProcessor: BaseSendProcessor = processors[0]
  for i in 1 ..< processors.len():
    currentProcessor.chain(processors[i])
    currentProcessor = processors[i]

  return ok(processors[0])

proc new*(
    T: type SendService, preferP2PReliability: bool, w: WakuNode
): Result[T, string] =
  if w.wakuRelay.isNil() and w.wakuLightpushClient.isNil():
    return err(
      "Could not create SendService. wakuRelay or wakuLightpushClient should be set"
    )

  let checkStoreForMessages = preferP2PReliability and not w.wakuStoreClient.isNil()

  let sendProcessorChain = setupSendProcessorChain(
    w.peerManager, w.wakuLightPushClient, w.wakuRelay, w.wakuRlnRelay
  ).valueOr:
    return err(error)

  let sendService = SendService(
    taskCache: newSeq[DeliveryTask](),
    serviceLoopHandle: nil,
    sendProcessor: sendProcessorChain,
    node: w,
    checkStoreForMessages: checkStoreForMessages,
  )

  return ok(sendService)

proc addTask(self: SendService, task: DeliveryTask) =
  self.taskCache.addUnique(task)

proc isStorePeerAvailable*(sendService: SendService): bool =
  return sendService.node.peerManager.selectPeer(WakuStoreCodec).isSome()

proc checkMsgsInStore(self: SendService, tasksToValidate: seq[DeliveryTask]) {.async.} =
  if tasksToValidate.len() == 0:
    return

  if not isStorePeerAvailable(self):
    warn "Skipping store validation for ",
      messageCount = tasksToValidate.len(), error = "no store peer available"
    return

  var hashesToValidate = tasksToValidate.mapIt(it.msgHash)

  let storeResp: StoreQueryResponse = (
    await self.node.wakuStoreClient.queryToAny(
      StoreQueryRequest(includeData: false, messageHashes: hashesToValidate)
    )
  ).valueOr:
    error "Failed to get store validation for messages",
      hashes = hashesToValidate.mapIt(shortLog(it)), error = $error
    return

  let storedItems = storeResp.messages.mapIt(it.messageHash)

  # Set success state for messages found in store
  self.taskCache.applyItIf(storedItems.contains(it.msgHash)):
    it.state = DeliveryState.SuccessfullyValidated

  # set retry state for messages not found in store
  hashesToValidate.keepItIf(not storedItems.contains(it))
  self.taskCache.applyItIf(hashesToValidate.contains(it.msgHash)):
    it.state = DeliveryState.NextRoundRetry

proc checkStoredMessages(self: SendService) {.async.} =
  if not self.checkStoreForMessages:
    return

  let tasksToValidate = self.taskCache.filterIt(
    it.state == DeliveryState.SuccessfullyPropagated and it.deliveryAge() > ArchiveTime and
      not it.isEphemeral()
  )

  await self.checkMsgsInStore(tasksToValidate)

proc reportTaskResult(self: SendService, task: DeliveryTask) =
  case task.state
  of DeliveryState.SuccessfullyPropagated:
    # TODO: in case of of unable to strore check messages shall we report success instead?
    info "Message successfully propagated",
      requestId = task.requestId, msgHash = task.msgHash
    MessagePropagatedEvent.emit(task.requestId, task.msgHash.toString())
    return
  of DeliveryState.SuccessfullyValidated:
    info "Message successfully sent", requestId = task.requestId, msgHash = task.msgHash
    MessageSentEvent.emit(task.requestId, task.msgHash.toString())
    return
  of DeliveryState.FailedToDeliver:
    error "Failed to send message",
      requestId = task.requestId, msgHash = task.msgHash, error = task.errorDesc
    MessageErrorEvent.emit(task.requestId, task.msgHash.toString(), task.errorDesc)
    return
  else:
    # rest of the states are intermediate and does not translate to event
    discard

  if task.messageAge() > MaxTimeInCache:
    error "Failed to send message",
      requestId = task.requestId, msgHash = task.msgHash, error = "Message too old"
    task.state = DeliveryState.FailedToDeliver
    MessageErrorEvent.emit(
      task.requestId, task.msgHash.toString(), "Unable to send within retry time window"
    )

proc evaluateAndCleanUp(self: SendService) =
  self.taskCache.forEach(self.reportTaskResult(it))
  self.taskCache.keepItIf(
    it.state != DeliveryState.SuccessfullyValidated or
      it.state != DeliveryState.FailedToDeliver
  )

  # remove propagated ephemeral messages as no store check is possible
  self.taskCache.keepItIf(
    not (it.isEphemeral() and it.state == DeliveryState.SuccessfullyPropagated)
  )

proc trySendMessages(self: SendService) {.async.} =
  let tasksToSend = self.taskCache.filterIt(it.state == DeliveryState.NextRoundRetry)

  for task in tasksToSend:
    # Todo, check if it has any perf gain to run them concurrent...
    await self.sendProcessor.process(task)

proc serviceLoop(self: SendService) {.async.} =
  ## Continuously monitors that the sent messages have been received by a store node
  while true:
    await self.trySendMessages()
    await self.checkStoredMessages()
    self.evaluateAndCleanUp()
    ## TODO: add circuit breaker to avoid infinite looping in case of persistent failures
    ## Use OnlienStateChange observers to pause/resume the loop
    await sleepAsync(ServiceLoopInterval)

proc startSendService*(self: SendService) =
  self.serviceLoopHandle = self.serviceLoop()

proc stopSendService*(self: SendService) =
  if not self.serviceLoopHandle.isNil():
    discard self.serviceLoopHandle.cancelAndWait()

proc send*(self: SendService, task: DeliveryTask): Future[void] {.async.} =
  assert(not task.isNil(), "task for send must not be nil")

  await self.sendProcessor.process(task)
  reportTaskResult(self, task)
  if task.state != DeliveryState.FailedToDeliver:
    self.addTask(task)
