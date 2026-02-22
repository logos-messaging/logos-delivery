## This module reinforces the publish operation with regular store-v3 requests.
##

import std/[sequtils, tables, options, typetraits]
import chronos, chronicles, libp2p/utility
import
  ./[send_processor, relay_processor, lightpush_processor, delivery_task],
  ../[subscription_service],
  waku/[
    waku_core,
    node/waku_node,
    node/peer_manager,
    waku_store/client,
    waku_store/common,
    waku_relay/protocol,
    waku_rln_relay/rln_relay,
    waku_lightpush/client,
    waku_lightpush/callbacks,
    events/message_events,
    common/broker/broker_context,
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
  brokerCtx: BrokerContext
  taskCache: seq[DeliveryTask]
    ## Cache that contains the delivery task per message hash.
    ## This is needed to make sure the published messages are properly published

  serviceLoopHandle: Future[void] ## handle that allows to stop the async task
  sendProcessor: BaseSendProcessor

  node: WakuNode
  checkStoreForMessages: bool
  subscriptionService: SubscriptionService

proc setupSendProcessorChain(
    peerManager: PeerManager,
    lightpushClient: WakuLightPushClient,
    relay: WakuRelay,
    rlnRelay: WakuRLNRelay,
    brokerCtx: BrokerContext,
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

    processors.add(RelaySendProcessor.new(isLightPushAvail, publishProc, brokerCtx))
  if isLightPushAvail:
    processors.add(LightpushSendProcessor.new(peerManager, lightpushClient, brokerCtx))

  var currentProcessor: BaseSendProcessor = processors[0]
  for i in 1 ..< processors.len:
    currentProcessor.chain(processors[i])
    currentProcessor = processors[i]
    trace "Send processor chain", index = i, processor = type(processors[i]).name

  return ok(processors[0])

proc new*(
    T: typedesc[SendService],
    preferP2PReliability: bool,
    w: WakuNode,
    s: SubscriptionService,
): Result[T, string] =
  if w.wakuRelay.isNil() and w.wakuLightpushClient.isNil():
    return err(
      "Could not create SendService. wakuRelay or wakuLightpushClient should be set"
    )

  let checkStoreForMessages = preferP2PReliability and not w.wakuStoreClient.isNil()

  let sendProcessorChain = setupSendProcessorChain(
    w.peerManager, w.wakuLightPushClient, w.wakuRelay, w.wakuRlnRelay, w.brokerCtx
  ).valueOr:
    return err("failed to setup SendProcessorChain: " & $error)

  let sendService = SendService(
    brokerCtx: w.brokerCtx,
    taskCache: newSeq[DeliveryTask](),
    serviceLoopHandle: nil,
    sendProcessor: sendProcessorChain,
    node: w,
    checkStoreForMessages: checkStoreForMessages,
    subscriptionService: s,
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
  # TODO: confirm hash format for store query!!!

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
    # TODO: in case of unable to strore check messages shall we report success instead?
    if not task.propagateEventEmitted:
      info "Message successfully propagated",
        requestId = task.requestId, msgHash = task.msgHash.to0xHex()
      MessagePropagatedEvent.emit(
        self.brokerCtx, task.requestId, task.msgHash.to0xHex()
      )
      task.propagateEventEmitted = true
    return
  of DeliveryState.SuccessfullyValidated:
    info "Message successfully sent",
      requestId = task.requestId, msgHash = task.msgHash.to0xHex()
    MessageSentEvent.emit(self.brokerCtx, task.requestId, task.msgHash.to0xHex())
    return
  of DeliveryState.FailedToDeliver:
    error "Failed to send message",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      error = task.errorDesc
    MessageErrorEvent.emit(
      self.brokerCtx, task.requestId, task.msgHash.to0xHex(), task.errorDesc
    )
    return
  else:
    # rest of the states are intermediate and does not translate to event
    discard

  if task.messageAge() > MaxTimeInCache:
    error "Failed to send message",
      requestId = task.requestId,
      msgHash = task.msgHash.to0xHex(),
      error = "Message too old",
      age = task.messageAge()
    task.state = DeliveryState.FailedToDeliver
    MessageErrorEvent.emit(
      self.brokerCtx,
      task.requestId,
      task.msgHash.to0xHex(),
      "Unable to send within retry time window",
    )

proc evaluateAndCleanUp(self: SendService) =
  self.taskCache.forEach(self.reportTaskResult(it))
  self.taskCache.keepItIf(
    it.state != DeliveryState.SuccessfullyValidated and
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
    ## Use OnlineStateChange observers to pause/resume the loop
    await sleepAsync(ServiceLoopInterval)

proc startSendService*(self: SendService) =
  self.serviceLoopHandle = self.serviceLoop()

proc stopSendService*(self: SendService) =
  if not self.serviceLoopHandle.isNil():
    discard self.serviceLoopHandle.cancelAndWait()

proc send*(self: SendService, task: DeliveryTask) {.async.} =
  assert(not task.isNil(), "task for send must not be nil")

  info "SendService.send: processing delivery task",
    requestId = task.requestId, msgHash = task.msgHash.to0xHex()

  self.subscriptionService.subscribe(task.msg.contentTopic).isOkOr:
    error "SendService.send: failed to subscribe to content topic",
      contentTopic = task.msg.contentTopic, error = error

  await self.sendProcessor.process(task)
  reportTaskResult(self, task)
  if task.state != DeliveryState.FailedToDeliver:
    self.addTask(task)
