import logos_delivery/waku/compat/option_valueor
## This module reinforces the publish operation with regular store-v3 requests.
##

import std/[sequtils, tables, options, typetraits]
import chronos, chronicles, libp2p/utility
import brokers/broker_context
import
  ./[send_processor, relay_processor, lightpush_processor, delivery_task],
  logos_delivery/waku/[waku_core, waku_store/common],
  logos_delivery/waku/waku,
  logos_delivery/waku/api/[store, subscriptions, publish]
import logos_delivery/events/messaging_client_events

logScope:
  topics = "send service"

# This useful util is missing from sequtils, this extends applyIt with predicate...
template applyItIf*(varSeq, pred, op: untyped) =
  for i in low(varSeq) .. high(varSeq):
    var it {.inject.} = varSeq[i]
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

  waku: Waku
  checkStoreForMessages: bool
  lastStoreCheckTime: Moment ## throttles store validation queries to ArchiveTime cadence

proc setupSendProcessorChain(
    waku: Waku, brokerCtx: BrokerContext
): Result[BaseSendProcessor, string] =
  let isRelayAvail = waku.hasRelay()
  let isLightPushAvail = waku.hasLightpush()

  if not isRelayAvail and not isLightPushAvail:
    return err("No valid send processor found for the delivery task")

  var processors = newSeq[BaseSendProcessor]()

  if isRelayAvail:
    let publishProc = waku.relayPushHandler()
    processors.add(RelaySendProcessor.new(isLightPushAvail, publishProc, brokerCtx))
  if isLightPushAvail:
    processors.add(LightpushSendProcessor.new(waku, brokerCtx))

  var currentProcessor: BaseSendProcessor = processors[0]
  for i in 1 ..< processors.len:
    currentProcessor.chain(processors[i])
    currentProcessor = processors[i]
    trace "Send processor chain", index = i, processor = type(processors[i]).name

  return ok(processors[0])

proc new*(
    T: typedesc[SendService], preferP2PReliability: bool, waku: Waku
): Result[T, string] =
  if not waku.hasRelay() and not waku.hasLightpush():
    return err(
      "Could not create SendService. wakuRelay or wakuLightpushClient should be set"
    )

  let checkStoreForMessages = preferP2PReliability and waku.isStoreMounted()

  let sendProcessorChain = setupSendProcessorChain(waku, waku.brokerCtx).valueOr:
    return err("failed to setup SendProcessorChain: " & $error)

  let sendService = SendService(
    brokerCtx: waku.brokerCtx,
    taskCache: newSeq[DeliveryTask](),
    serviceLoopHandle: nil,
    sendProcessor: sendProcessorChain,
    waku: waku,
    checkStoreForMessages: checkStoreForMessages,
    lastStoreCheckTime: Moment.now(),
  )

  return ok(sendService)

proc addTask(self: SendService, task: DeliveryTask) =
  self.taskCache.addUnique(task)

proc isStorePeerAvailable*(sendService: SendService): bool =
  return sendService.waku.hasStorePeer()

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
    await self.waku.storeQueryToAny(
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

  # Throttle store queries so they run at most every ArchiveTime (3s), regardless
  # of the 1s service loop cadence.
  if Moment.now() - self.lastStoreCheckTime < ArchiveTime:
    return

  let tasksToValidate = self.taskCache.filterIt(
    it.state == DeliveryState.SuccessfullyPropagated and
      it.propagationAge() > ArchiveTime and not it.isEphemeral()
  )

  if tasksToValidate.len() == 0:
    return

  self.lastStoreCheckTime = Moment.now()
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

  # Only tasks that never propagated are reported as hard send failures here.
  # Propagated-but-not-store-validated tasks are handled (warn + drop, no event)
  # in evaluateAndCleanUp.
  if task.firstPropagatedTime.isNone() and task.messageAge() > MaxTimeInCache:
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

  # remove propagated messages when no store confirmation will follow
  self.taskCache.keepItIf(
    not (
      it.state == DeliveryState.SuccessfullyPropagated and
      (it.isEphemeral() or not self.checkStoreForMessages)
    )
  )

  # Store validation timed out: the message was propagated but never confirmed in a
  # store node within MaxTimeInCache (measured from first propagation). Warn and drop
  # without emitting an app event.
  for task in self.taskCache:
    if task.firstPropagatedTime.isSome() and
        task.state != DeliveryState.SuccessfullyValidated and
        task.propagationAge() > MaxTimeInCache:
      warn "Message propagated but not validated by a store node within time window; stop trying.",
        requestId = task.requestId,
        msgHash = task.msgHash.to0xHex(),
        propagationAge = task.propagationAge()

  self.taskCache.keepItIf(
    not (
      it.firstPropagatedTime.isSome() and it.state != DeliveryState.SuccessfullyValidated and
      it.propagationAge() > MaxTimeInCache
    )
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

proc stopSendService*(self: SendService) {.async.} =
  if not self.serviceLoopHandle.isNil():
    await self.serviceLoopHandle.cancelAndWait()

proc send*(self: SendService, task: DeliveryTask) {.async.} =
  assert(not task.isNil(), "task for send must not be nil")

  info "SendService.send: processing delivery task",
    requestId = task.requestId, msgHash = task.msgHash.to0xHex()

  self.waku.subscribe(task.msg.contentTopic).isOkOr:
    error "SendService.send: failed to subscribe to content topic",
      contentTopic = task.msg.contentTopic, error = error

  await self.sendProcessor.process(task)
  reportTaskResult(self, task)
  if task.state != DeliveryState.FailedToDeliver:
    self.addTask(task)
