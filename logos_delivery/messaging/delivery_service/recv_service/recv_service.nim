import logos_delivery/waku/compat/option_valueor
## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##

import std/[tables, sequtils, options, sets]
import chronos, chronicles, libp2p/utility
import brokers/broker_context
import
  logos_delivery/waku/[
    waku_core,
    waku_core/topics,
    waku_store/client,
    waku_store/common,
    waku_filter_v2/client,
    api/events/message_events,
    api/events/health_events,
    waku_node,
    node/subscription_manager,
  ]
import logos_delivery/messaging/api/events

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const PruneOldMsgsPeriod = chronos.minutes(1)

const DelayExtra* = chronos.seconds(5)
  ## Additional security time to overlap the missing messages queries

type TupleHashAndMsg =
  tuple[hash: WakuMessageHash, msg: WakuMessage, pubsubTopic: PubsubTopic]

type RecvMessage = object
  msgHash: WakuMessageHash
  rxTime: Timestamp
    ## timestamp of the rx message. We will not keep the rx messages forever

type RecvService* = ref object of RootObj
  brokerCtx: BrokerContext
  node: WakuNode
  seenMsgListener: MessageSeenEventListener
  connStatusListener: EventConnectionStatusChangeListener

  recentReceivedMsgs: seq[RecvMessage]

  online: bool
    ## Whether we currently have connectivity (ConnectionStatus != Disconnected).
    ## Status events carry only the new state, so this remembers the previous one
    ## to act on edges, not every event: `PartiallyConnected`/`Connected` flicker
    ## while still online, and the bool collapses that — backfill once when we come
    ## online, stamp the gap start when we go offline.
  backfillHandler: Future[void] ## in-flight store backfill task
  msgPrunerHandler: Future[void] ## removes too old messages

  startTimeToCheck: Timestamp
  endTimeToCheck: Timestamp

proc getMissingMsgsFromStore(
    self: RecvService, msgHashes: seq[WakuMessageHash]
): Future[Result[seq[TupleHashAndMsg], string]] {.async.} =
  let storeResp: StoreQueryResponse = (
    await self.node.wakuStoreClient.queryToAny(
      StoreQueryRequest(includeData: true, messageHashes: msgHashes)
    )
  ).valueOr:
    return err("getMissingMsgsFromStore: " & $error)

  let otherwiseMsg = WakuMessage()
  let otherwiseTopic = PubsubTopic("")
  return ok(
    storeResp.messages.mapIt(
      (
        hash: it.messageHash,
        msg: it.message.get(otherwiseMsg),
        pubsubTopic: it.pubsubTopic.get(otherwiseTopic),
      )
    )
  )

proc processIncomingMessage(
    self: RecvService, pubsubTopic: string, message: WakuMessage
): bool =
  ## Return false if the incoming message is from a non-subscribed topic,
  ## or if the message is a duplicate (recently-seen). Otherwise, save it as
  ## recently-seen, emit a MessageReceivedEvent, and return true.

  if not self.node.subscriptionManager.isContentSubscribed(
    pubsubTopic, message.contentTopic
  ):
    trace "skipping message as I am not subscribed",
      shard = pubsubTopic, contentTopic = message.contentTopic
    return false

  let msgHash = computeMessageHash(pubsubTopic, message)
  if self.recentReceivedMsgs.anyIt(it.msgHash == msgHash):
    trace "skipping duplicate message",
      shard = pubsubTopic,
      contentTopic = message.contentTopic,
      msg_hash = msgHash.to0xHex()
    return false

  let rxMsg = RecvMessage(msgHash: msgHash, rxTime: message.timestamp)
  self.recentReceivedMsgs.add(rxMsg)
  MessageReceivedEvent.emit(self.brokerCtx, msgHash.to0xHex(), message)
  return true

proc checkStore*(self: RecvService) {.async.} =
  ## Checks the store for messages that were not received directly and
  ## delivers them via MessageReceivedEvent.
  if self.node.wakuStoreClient.isNil():
    error "recv service has no store client mounted, skipping store check"
    return

  self.endTimeToCheck = getNowInNanosecondTime()

  ## query store and deliver new recovered messages per subscribed topic
  for pubsubTopic, contentTopics in self.node.subscriptionManager.subscribedContentTopics:
    let storeResp: StoreQueryResponse = (
      await self.node.wakuStoreClient.queryToAny(
        StoreQueryRequest(
          includeData: false,
          pubsubTopic: some(pubsubTopic),
          contentTopics: toSeq(contentTopics),
          startTime: some(self.startTimeToCheck - DelayExtra.nanos),
          endTime: some(self.endTimeToCheck + DelayExtra.nanos),
        )
      )
    ).valueOr:
      error "checkStore failed to get remote msgHashes",
        pubsubTopic = pubsubTopic, cTopics = toSeq(contentTopics), error = $error
      continue

    ## compare the msgHashes seen from the store vs the ones received directly
    let msgHashesInStore = storeResp.messages.mapIt(it.messageHash)
    let rxMsgHashes = self.recentReceivedMsgs.mapIt(it.msgHash)
    let missedHashes: seq[WakuMessageHash] =
      msgHashesInStore.filterIt(not rxMsgHashes.contains(it))

    if missedHashes.len > 0:
      info "missed messages detected, checking store for missed messages",
        pubsubTopic = pubsubTopic, missedCount = missedHashes.len

      ## Now retrieve the missing WakuMessages and deliver them
      let missingMsgsRet = await self.getMissingMsgsFromStore(missedHashes)
      if missingMsgsRet.isOk():
        for msgTuple in missingMsgsRet.get():
          if self.processIncomingMessage(msgTuple.pubsubTopic, msgTuple.msg):
            info "recv service store-recovered message",
              msg_hash = shortLog(msgTuple.hash), pubsubTopic = msgTuple.pubsubTopic
      else:
        error "failed to retrieve missing messages: ", error = $missingMsgsRet.error

  ## update next check times
  self.startTimeToCheck = self.endTimeToCheck

proc onConnectionStatusChange(self: RecvService, status: ConnectionStatus) =
  ## Backfill the store over the window we were offline (`Disconnected`).
  let nowOnline = status != ConnectionStatus.Disconnected
  if nowOnline == self.online:
    return
  self.online = nowOnline

  if not nowOnline:
    self.startTimeToCheck = getNowInNanosecondTime()
    return

  # At most one backfill in flight; skip if the previous is still running.
  # Triggers are paced by health-monitor status changes, so overlap is unlikely.
  if self.backfillHandler.isNil() or self.backfillHandler.finished():
    info "recv service backfilling missed messages after coming back online"
    self.backfillHandler = self.checkStore()

proc new*(T: typedesc[RecvService], node: WakuNode): T =
  ## The storeClient will help to acquire any possible missed messages

  let now = getNowInNanosecondTime()
  var recvService = RecvService(
    node: node,
    startTimeToCheck: now,
    brokerCtx: node.brokerCtx,
    recentReceivedMsgs: @[],
  )

  return recvService

proc loopPruneOldMessages(self: RecvService) {.async.} =
  while true:
    let oldestAllowedTime = getNowInNanosecondTime() - MaxMessageLife.nanos
    self.recentReceivedMsgs.keepItIf(it.rxTime > oldestAllowedTime)
    await sleepAsync(PruneOldMsgsPeriod)

proc startRecvService*(self: RecvService) =
  self.msgPrunerHandler = self.loopPruneOldMessages()

  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      discard self.processIncomingMessage(event.topic, event.message),
  ).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    quit(QuitFailure)

  self.connStatusListener = EventConnectionStatusChange.listen(
    self.brokerCtx,
    proc(event: EventConnectionStatusChange) {.async: (raises: []).} =
      self.onConnectionStatusChange(event.connectionStatus),
  ).valueOr:
    error "Failed to set EventConnectionStatusChange listener", error = error
    quit(QuitFailure)

proc stopRecvService*(self: RecvService) {.async.} =
  await MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  await EventConnectionStatusChange.dropListener(
    self.brokerCtx, self.connStatusListener
  )
  if not self.backfillHandler.isNil():
    await self.backfillHandler.cancelAndWait()
    self.backfillHandler = nil
  if not self.msgPrunerHandler.isNil():
    await self.msgPrunerHandler.cancelAndWait()
    self.msgPrunerHandler = nil
