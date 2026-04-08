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
    events/message_events,
    waku_node,
    common/broker/broker_context,
  ]

const StoreCheckPeriod = chronos.minutes(5) ## How often to perform store queries

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

proc processIncomingMessageOfInterest(
    self: RecvService, pubsubTopic: string, message: WakuMessage
): bool =
  ## Deduplicate (by hash), store (saves in recently-seen messages) and emit
  ## the MAPI MessageReceivedEvent for every unique incoming message.
  ## Returns true if the message was new and delivered.

  let msgHash = computeMessageHash(pubsubTopic, message)
  if not self.recentReceivedMsgs.anyIt(it.msgHash == msgHash):
    let rxMsg = RecvMessage(msgHash: msgHash, rxTime: message.timestamp)
    self.recentReceivedMsgs.add(rxMsg)
    MessageReceivedEvent.emit(self.brokerCtx, msgHash.to0xHex(), message)
    return true
  return false

proc checkStore*(self: RecvService) {.async.} =
  ## Checks the store for messages that were not received directly and
  ## delivers them via MessageReceivedEvent.
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

  ## Now retrieve the missing WakuMessages and deliver them
  let missingMsgsRet = await self.getMissingMsgsFromStore(missedHashes)
  if missingMsgsRet.isOk():
    for msgTuple in missingMsgsRet.get():
      if self.processIncomingMessageOfInterest(msgTuple.pubsubTopic, msgTuple.msg):
        info "recv service store-recovered message",
          msg_hash = shortLog(msgTuple.hash), pubsubTopic = msgTuple.pubsubTopic
  else:
    error "failed to retrieve missing messages: ", error = $missingMsgsRet.error

  ## update next check times
  self.startTimeToCheck = self.endTimeToCheck

proc msgChecker(self: RecvService) {.async.} =
  ## Continuously checks if a message has been received
  while true:
    await sleepAsync(StoreCheckPeriod)
    await self.checkStore()

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
    self.recentReceivedMsgs.keepItIf(it.rxTime > oldestAllowedTime)
    await sleepAsync(PruneOldMsgsPeriod)

proc startRecvService*(self: RecvService) =
  self.msgCheckerHandler = self.msgChecker()
  self.msgPrunerHandler = self.loopPruneOldMessages()

  self.seenMsgListener = MessageSeenEvent.listen(
    self.brokerCtx,
    proc(event: MessageSeenEvent) {.async: (raises: []).} =
      if not self.subscriptionManager.isSubscribed(
        event.topic, event.message.contentTopic
      ):
        trace "skipping message as I am not subscribed",
          shard = event.topic, contenttopic = event.message.contentTopic
        return

      discard self.processIncomingMessageOfInterest(event.topic, event.message),
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
