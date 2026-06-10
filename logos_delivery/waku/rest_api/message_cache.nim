{.push raises: [].}

import
  std/[sequtils, sugar, algorithm, options],
  results,
  chronicles,
  chronos,
  libp2p/protocols/pubsub
import ../waku_core

logScope:
  topics = "waku node message_cache"

const DefaultMessageCacheCapacity: int = 50

type MessageCache* = ref object
  pubsubTopics: seq[PubsubTopic]
  contentTopics: seq[ContentTopic]

  pubsubIndex: seq[tuple[pubsubIdx: int, msgIdx: int]]
  contentIndex: seq[tuple[contentIdx: int, msgIdx: int]]

  messages: seq[WakuMessage]

  capacity: int

func `$`*(self: MessageCache): string =
  "Messages: " & $self.messages.len & " \nPubsubTopics: " & $self.pubsubTopics &
    " \nContentTopics: " & $self.contentTopics & " \nPubsubIndex: " & $self.pubsubIndex &
    " \nContentIndex: " & $self.contentIndex

func init*(T: type MessageCache, capacity = DefaultMessageCacheCapacity): T =
  MessageCache(capacity: capacity)

proc messagesCount*(self: MessageCache): int =
  self.messages.len

proc pubsubTopicCount*(self: MessageCache): int =
  self.pubsubTopics.len

proc contentTopicCount*(self: MessageCache): int =
  self.contentTopics.len

proc pubsubSearch(self: MessageCache, pubsubTopic: PubsubTopic): Option[int] =
  # Return some with the index if found none otherwise.

  for i, topic in self.pubsubTopics:
    if topic == pubsubTopic:
      return some(i)

  return none(int)

proc contentSearch(self: MessageCache, contentTopic: ContentTopic): Option[int] =
  # Return some with the index if found none otherwise.

  for i, topic in self.contentTopics:
    if topic == contentTopic:
      return some(i)

  return none(int)

proc isPubsubSubscribed*(self: MessageCache, pubsubTopic: PubsubTopic): bool =
  self.pubsubSearch(pubsubTopic).isSome()

proc isContentSubscribed*(self: MessageCache, contentTopic: ContentTopic): bool =
  self.contentSearch(contentTopic).isSome()

proc pubsubSubscribe*(self: MessageCache, pubsubTopic: PubsubTopic) =
  if self.pubsubSearch(pubsubTopic).isNone():
    self.pubsubTopics.add(pubsubTopic)

proc contentSubscribe*(self: MessageCache, contentTopic: ContentTopic) =
  if self.contentSearch(contentTopic).isNone():
    self.contentTopics.add(contentTopic)

proc removeMessage(self: MessageCache, idx: int) =
  # get last index because del() is a swap
  let lastIndex = self.messages.high

  self.messages.del(idx)

  # update indices
  var j = self.pubsubIndex.high
  while j > -1:
    let (pId, mId) = self.pubsubIndex[j]

    if mId == idx:
      self.pubsubIndex.del(j)
    elif mId == lastIndex:
      self.pubsubIndex[j] = (pId, idx)

    dec(j)

  j = self.contentIndex.high
  while j > -1:
    let (cId, mId) = self.contentIndex[j]

    if mId == idx:
      self.contentIndex.del(j)
    elif mId == lastIndex:
      self.contentIndex[j] = (cId, idx)

    dec(j)

proc pubsubUnsubscribe*(self: MessageCache, pubsubTopic: PubsubTopic) =
  let pubsubIdxOp = self.pubsubSearch(pubsubTopic)

  let pubsubIdx =
    if pubsubIdxOp.isSome():
      pubsubIdxOp.get()
    else:
      return

  let lastIndex = self.pubsubTopics.high
  self.pubsubTopics.del(pubsubIdx)

  var msgIndices = newSeq[int](0)

  var j = self.pubsubIndex.high
  while j > -1:
    let (pId, mId) = self.pubsubIndex[j]

    if pId == pubsubIdx:
      # remove index for this topic
      self.pubsubIndex.del(j)
      msgIndices.add(mId)
    elif pId == lastIndex:
      # swap the index because pubsubTopics.del() is a swap
      self.pubsubIndex[j] = (pubsubIdx, mId)

    dec(j)

  # check if messages on this pubsub topic are indexed by any content topic, if not remove them.
  for mId in msgIndices.sorted(SortOrder.Descending):
    if not self.contentIndex.anyIt(it.msgIdx == mId):
      self.removeMessage(mId)

proc contentUnsubscribe*(self: MessageCache, contentTopic: ContentTopic) =
  let contentIdxOP = self.contentSearch(contentTopic)

  let contentIdx =
    if contentIdxOP.isSome():
      contentIdxOP.get()
    else:
      return

  let lastIndex = self.contentTopics.high
  self.contentTopics.del(contentIdx)

  var msgIndices = newSeq[int](0)

  var j = self.contentIndex.high
  while j > -1:
    let (cId, mId) = self.contentIndex[j]

    if cId == contentIdx:
      # remove indices for this topic
      self.contentIndex.del(j)
      msgIndices.add(mId)
    elif cId == lastIndex:
      # swap the indices because contentTopics.del() is a swap
      self.contentIndex[j] = (contentIdx, mId)

    dec(j)

  # check if messages on this content topic are indexed by any pubsub topic, if not remove them.
  for mId in msgIndices.sorted(SortOrder.Descending):
    if not self.pubsubIndex.anyIt(it.msgIdx == mId):
      self.removeMessage(mId)

proc reset*(self: MessageCache) =
  self.messages.setLen(0)
  self.pubsubTopics.setLen(0)
  self.contentTopics.setLen(0)
  self.pubsubIndex.setLen(0)
  self.contentIndex.setLen(0)

proc addMessage*(self: MessageCache, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  ## Idempotent message addition.

  var oldestTime = int64.high
  var oldestMsg = int.high
  for i, message in self.messages.reversed:
    if message == msg:
      return

    if message.timestamp < oldestTime:
      oldestTime = message.timestamp
      oldestMsg = i

  # reverse index
  oldestMsg = self.messages.high - oldestMsg

  var pubsubIdxOp = self.pubsubSearch(pubsubTopic)
  var contentIdxOp = self.contentSearch(msg.contentTopic)

  if pubsubIdxOp.isNone() and contentIdxOp.isNone():
    return

  let pubsubIdx =
    if pubsubIdxOp.isNone():
      self.pubsubTopics.add(pubsubTopic)
      self.pubsubTopics.high
    else:
      pubsubIdxOp.get()

  let contentIdx =
    if contentIdxOp.isNone():
      self.contentTopics.add(msg.contentTopic)
      self.contentTopics.high
    else:
      contentIdxOp.get()

  # add the message, make space if needed
  if self.messages.len >= self.capacity:
    self.removeMessage(oldestMsg)

  let msgIdx = self.messages.len
  self.messages.add(msg)

  self.pubsubIndex.add((pubsubIdx, msgIdx))
  self.contentIndex.add((contentIdx, msgIdx))

proc getMessages*(
    self: MessageCache, pubsubTopic: PubsubTopic, clear = false
): Result[seq[WakuMessage], string] =
  ## Return all messages on this pubsub topic

  if self.pubsubTopics.len == 0:
    return err("not subscribed to any pubsub topics")

  let pubsubIdxOp = self.pubsubSearch(pubsubTopic)
  let pubsubIdx =
    if pubsubIdxOp.isNone:
      return err("not subscribed to this pubsub topic")
    else:
      pubsubIdxOp.get()

  let msgIndices = collect:
    for (pId, mId) in self.pubsubIndex:
      if pId == pubsubIdx:
        mId

  let messages = msgIndices.mapIt(self.messages[it])

  if clear:
    for idx in msgIndices.reversed:
      self.removeMessage(idx)

  return ok(messages)

proc getAutoMessages*(
    self: MessageCache, contentTopic: ContentTopic, clear = false
): Result[seq[WakuMessage], string] =
  ## Return all messages on this content topic

  if self.contentTopics.len == 0:
    return err("not subscribed to any content topics")

  let contentIdxOp = self.contentSearch(contentTopic)
  let contentIdx =
    if contentIdxOp.isNone():
      return err("not subscribed to this content topic")
    else:
      contentIdxOp.get()

  let msgIndices = collect:
    for (cId, mId) in self.contentIndex:
      if cId == contentIdx:
        mId

  let messages = msgIndices.mapIt(self.messages[it])

  if clear:
    for idx in msgIndices.sorted(SortOrder.Descending):
      self.removeMessage(idx)

  return ok(messages)
