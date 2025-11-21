## This module is in charge of taking care of the messages that this node is expecting to
## receive and is backed by store-v3 requests to get an additional degree of certainty
##

import std/[tables, sequtils, options]
import chronos, chronicles, libp2p/utility
import
  waku/[
    waku_core,
    waku_store/client,
    waku_store/common,
    waku_filter_v2/client,
    waku_core/topics,
    events/delivery_events,
    waku_node,
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
  topicsInterest: Table[PubsubTopic, seq[ContentTopic]]
    ## Tracks message verification requests and when was the last time a
    ## pubsub topic was verified for missing messages
    ## The key contains pubsub-topics
  node: WakuNode
  onSubscribeListener: OnFilterSubscribeEventListener
  onUnsubscribeListener: OnFilterUnsubscribeEventListener

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
    success = success, dir = dir, comment = comment, msgHash = msgHash, msg = msg
  )

proc msgChecker(self: RecvService) {.async.} =
  ## Continuously checks if a message has been received
  while true:
    await sleepAsync(StoreCheckPeriod)

    self.endTimeToCheck = getNowInNanosecondTime()

    var msgHashesInStore = newSeq[WakuMessageHash](0)
    for pubsubTopic, cTopics in self.topicsInterest.pairs:
      let storeResp: StoreQueryResponse = (
        await self.node.wakuStoreClient.queryToAny(
          StoreQueryRequest(
            includeData: false,
            pubsubTopic: some(PubsubTopic(pubsubTopic)),
            contentTopics: cTopics,
            startTime: some(self.startTimeToCheck - DelayExtra.nanos),
            endTime: some(self.endTimeToCheck + DelayExtra.nanos),
          )
        )
      ).valueOr:
        error "msgChecker failed to get remote msgHashes",
          pubsubTopic, cTopics, error = $error
        continue

      msgHashesInStore.add(storeResp.messages.mapIt(it.messageHash))

    ## compare the msgHashes seen from the store vs the ones received directly
    let rxMsgHashes = self.recentReceivedMsgs.mapIt(it.msgHash)
    let missedHashes: seq[WakuMessageHash] =
      msgHashesInStore.filterIt(not rxMsgHashes.contains(it))

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

proc onSubscribe(
    self: RecvService, pubsubTopic: string, contentTopics: seq[string]
) {.gcsafe, raises: [].} =
  info "onSubscribe", pubsubTopic, contentTopics
  self.topicsInterest.withValue(pubsubTopic, contentTopicsOfInterest):
    contentTopicsOfInterest[].add(contentTopics)
  do:
    self.topicsInterest[pubsubTopic] = contentTopics

proc onUnsubscribe(
    self: RecvService, pubsubTopic: string, contentTopics: seq[string]
) {.gcsafe, raises: [].} =
  info "onUnsubscribe", pubsubTopic, contentTopics

  self.topicsInterest.withValue(pubsubTopic, contentTopicsOfInterest):
    let remainingCTopics =
      contentTopicsOfInterest[].filterIt(not contentTopics.contains(it))
    contentTopicsOfInterest[] = remainingCTopics

    if remainingCTopics.len == 0:
      self.topicsInterest.del(pubsubTopic)
  do:
    error "onUnsubscribe unsubscribing from wrong topic", pubsubTopic, contentTopics

proc new*(T: type RecvService, node: WakuNode): T =
  ## The storeClient will help to acquire any possible missed messages

  let now = getNowInNanosecondTime()
  var recvService = RecvService(node: node, startTimeToCheck: now)

  if not node.wakuFilterClient.isNil():
    let filterPushHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ) {.async, closure.} =
      ## Captures all the messages recived through filter

      let msgHash = computeMessageHash(pubSubTopic, message)
      let rxMsg = RecvMessage(msgHash: msgHash, rxTime: message.timestamp)
      recvService.recentReceivedMsgs.add(rxMsg)

    node.wakuFilterClient.registerPushHandler(filterPushHandler)

  return recvService

proc loopPruneOldMessages(self: RecvService) {.async.} =
  while true:
    let oldestAllowedTime = getNowInNanosecondTime() - MaxMessageLife.nanos
    self.recentReceivedMsgs.keepItIf(it.rxTime > oldestAllowedTime)
    await sleepAsync(PruneOldMsgsPeriod)

proc startRecvService*(self: RecvService) =
  self.msgCheckerHandler = self.msgChecker()
  self.msgPrunerHandler = self.loopPruneOldMessages()

  self.onSubscribeListener = OnFilterSubscribeEvent.listen(
    proc(subsEv: OnFilterSubscribeEvent): Future[void] {.async: (raises: []).} =
      self.onSubscribe(subsEv.pubsubTopic, subsEv.contentTopics)
  ).valueOr:
    error "Failed to set OnFilterSubscribeEvent listener", error = error
    quit(QuitFailure)

  self.onUnsubscribeListener = OnFilterUnsubscribeEvent.listen(
    proc(subsEv: OnFilterUnsubscribeEvent): Future[void] {.async: (raises: []).} =
      self.onUnsubscribe(subsEv.pubsubTopic, subsEv.contentTopics)
  ).valueOr:
    error "Failed to set OnFilterUnsubscribeEvent listener", error = error
    quit(QuitFailure)

proc stopRecvService*(self: RecvService) {.async.} =
  OnFilterSubscribeEvent.dropListener(self.onSubscribeListener)
  OnFilterUnSubscribeEvent.dropListener(self.onUnsubscribeListener)
  if not self.msgCheckerHandler.isNil():
    await self.msgCheckerHandler.cancelAndWait()
  if not self.msgPrunerHandler.isNil():
    await self.msgPrunerHandler.cancelAndWait()
