## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##

import std/[tables, sequtils, options, sets]
import chronos, chronicles, libp2p/utility
import ../[subscription_manager]
import
  waku/[
    waku_core,
    waku_store/client,
    waku_store/common,
    waku_filter_v2/client,
    waku_core/topics,
    events/delivery_events,
    events/message_events,
    waku_node,
    common/broker/broker_context,
  ]

const StoreCheckPeriod = chronos.minutes(5) ## How often to perform store queries

const MaxMessageLife = chronos.minutes(7) ## Max time we will keep track of rx messages

const PruneOldMsgsPeriod = chronos.minutes(1)

const DelayExtra* = chronos.seconds(5)
  ## Additional security time to overlap the missing messages queries

type TupleHashAndMsg = tuple[hash: WakuMessageHash, msg: WakuMessage]

type RecvMessage = object
  msgHash: WakuMessageHash
  rxTime: Timestamp
    ## timestamp of the rx message. We will not keep the rx messages forever

type RecvService* = ref object of RootObj
  brokerCtx: BrokerContext
  node: WakuNode
  seenMsgListener: MessageSeenEventListener
  subscriptionManager: SubscriptionManager

  recentReceivedMsgs: seq[RecvMessage]

  msgCheckerHandler: Future[void] ## allows to stop the msgChecker async task
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
    ## message to be returned if the Option message is none
  return ok(
    storeResp.messages.mapIt((hash: it.messageHash, msg: it.message.get(otherwiseMsg)))
  )

proc performDeliveryFeedback(
    self: RecvService,
    success: DeliverySuccess,
    dir: DeliveryDirection,
    comment: string,
    msgHash: WakuMessageHash,
    msg: WakuMessage,
) {.gcsafe, raises: [].} =
  info "recv monitor performDeliveryFeedback",
    success, dir, comment, msg_hash = shortLog(msgHash)

  DeliveryFeedbackEvent.emit(
    brokerCtx = self.brokerCtx,
    success = success,
    dir = dir,
    comment = comment,
    msgHash = msgHash,
    msg = msg,
  )

proc msgChecker(self: RecvService) {.async.} =
  ## Continuously checks if a message has been received
  while true:
    await sleepAsync(StoreCheckPeriod)
    self.endTimeToCheck = getNowInNanosecondTime()

    var msgHashesInStore = newSeq[WakuMessageHash](0)
    for pubsubTopic, contentTopics in self.subscriptionManager.subscribedTopics:
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
        error "msgChecker failed to get remote msgHashes",
          pubsubTopic = pubsubTopic, cTopics = toSeq(contentTopics), error = $error
        continue

      msgHashesInStore.add(storeResp.messages.mapIt(it.messageHash))

    ## compare the msgHashes seen from the store vs the ones received directly
    let rxMsgHashes = self.recentReceivedMsgs.mapIt(it.msgHash)
    let missedHashes: seq[WakuMessageHash] =
      msgHashesInStore.filterIt(not rxMsgHashes.contains(it))

    debug "AAAA msgChecker delivery discrepancy",
      store_hashes = msgHashesInStore.len,
      rx_hashes = rxMsgHashes.len,
      missed_hashes = missedHashes.len

    if missedHashes.len > 0:
      debug "AAAA msgChecker detected missed hashes",
        missed_hashes = missedHashes.len, missed_hash_list = missedHashes

    ## Now retrieve the missed WakuMessages
    let missingMsgsRet = await self.getMissingMsgsFromStore(missedHashes)
    if missingMsgsRet.isOk():
      ## Give feedback so that the api client can perfom any action with the missed messages
      for msgTuple in missingMsgsRet.get():
        self.performDeliveryFeedback(
          DeliverySuccess.UNSUCCESSFUL, RECEIVING, "Missed message", msgTuple.hash,
          msgTuple.msg,
        )
    else:
      error "failed to retrieve missing messages: ", error = $missingMsgsRet.error

    ## update next check times
    self.startTimeToCheck = self.endTimeToCheck

proc processIncomingMessageOfInterest(
    self: RecvService, pubsubTopic: string, message: WakuMessage
) =
  ## Resolve an incoming network message that was already filtered by topic.
  ## Deduplicate (by hash), store (saves in recently-seen messages) and emit
  ## the MAPI MessageReceivedEvent for every unique incoming message.

  let msgHash = computeMessageHash(pubsubTopic, message)
  debug "AAAA processIncomingMessageOfInterest received event",
    topic = pubsubTopic,
    contenttopic = message.contentTopic,
    msg_hash = shortLog(msgHash)

  if self.recentReceivedMsgs.anyIt(it.msgHash == msgHash):
    debug "AAAA processIncomingMessageOfInterest duplicate message skipped",
      topic = pubsubTopic,
      contenttopic = message.contentTopic,
      msg_hash = shortLog(msgHash)
    return

  let prevHashes = self.recentReceivedMsgs.mapIt(it.msgHash)
  let rxMsg = RecvMessage(msgHash: msgHash, rxTime: message.timestamp)
  self.recentReceivedMsgs.add(rxMsg)
  debug "AAAA recentReceivedMsgs added new message",
    topic = pubsubTopic,
    contenttopic = message.contentTopic,
    added_msg_hash = shortLog(msgHash),
    prev_entries = prevHashes.len,
    now_entries = self.recentReceivedMsgs.len,
    recent_hashes = self.recentReceivedMsgs.mapIt(it.msgHash)

  MessageReceivedEvent.emit(self.brokerCtx, msgHash.to0xHex(), message)

proc new*(T: typedesc[RecvService], node: WakuNode, s: SubscriptionManager): T =
  ## The storeClient will help to acquire any possible missed messages

  let now = getNowInNanosecondTime()
  var recvService = RecvService(
    node: node,
    startTimeToCheck: now,
    brokerCtx: node.brokerCtx,
    subscriptionManager: s,
    recentReceivedMsgs: @[],
  )

  return recvService

proc loopPruneOldMessages(self: RecvService) {.async.} =
  while true:
    let oldestAllowedTime = getNowInNanosecondTime() - MaxMessageLife.nanos
    let prevHashes = self.recentReceivedMsgs.mapIt(it.msgHash)
    let prevEntries = prevHashes.len
    let hashesBeforePrune = self.recentReceivedMsgs.mapIt(it.msgHash)
    self.recentReceivedMsgs.keepItIf(it.rxTime > oldestAllowedTime)
    debug "AAAA loopPruneOldMessages",
      before_entries = prevEntries,
      after_entries = self.recentReceivedMsgs.len,
      pruned_entries = prevEntries - self.recentReceivedMsgs.len,
      remaining_hashes = self.recentReceivedMsgs.mapIt(it.msgHash),
      hashesBeforePrune = hashesBeforePrune
    await sleepAsync(PruneOldMsgsPeriod)

proc startRecvService*(self: RecvService) =
  self.msgCheckerHandler = self.msgChecker()
  self.msgPrunerHandler = self.loopPruneOldMessages()

  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      let eventHash = computeMessageHash(event.topic, event.message)
      debug "AAAA MessageSeenEvent listener received event",
        topic = event.topic,
        contenttopic = event.message.contentTopic,
        msg_hash = shortLog(eventHash),
        timestamp = event.message.timestamp

      let subscribed =
        self.subscriptionManager.isSubscribed(event.topic, event.message.contentTopic)
      debug "AAAA MessageSeenEvent subscription check",
        topic = event.topic,
        contenttopic = event.message.contentTopic,
        subscribed = subscribed

      if not subscribed:
        debug "AAAA skipping MessageSeenEvent because not subscribed",
          shard = event.topic,
          contenttopic = event.message.contentTopic,
          msg_hash = shortLog(eventHash)
        return

      debug "AAAA MessageSeenEvent accepted for processing",
        topic = event.topic,
        contenttopic = event.message.contentTopic,
        msg_hash = shortLog(eventHash)
      self.processIncomingMessageOfInterest(event.topic, event.message),
  ).valueOr:
    error "Failed to set MessageSeenEvent listener", error = error
    quit(QuitFailure)

proc stopRecvService*(self: RecvService) {.async.} =
  MessageSeenEvent.dropListener(self.brokerCtx, self.seenMsgListener)
  if not self.msgCheckerHandler.isNil():
    await self.msgCheckerHandler.cancelAndWait()
    self.msgCheckerHandler = nil
  if not self.msgPrunerHandler.isNil():
    await self.msgPrunerHandler.cancelAndWait()
    self.msgPrunerHandler = nil
