## In-memory cache backing the messaging event REST endpoints.
##
## REST is a poll-based client/server surface, so the interactive MessagingClient
## events must be buffered here for later observation:
##   * send-related events (sent / propagated / error) grouped by message hash
##   * received messages
##
## Both surfaces are evict-after-poll: a GET returns the buffered data and clears
## it. A generous overflow cap bounds memory if nobody polls. All access happens
## on the single chronos event loop (broker listeners + REST handlers), so the
## synchronous (no-await) ops below need no locking.

{.push raises: [].}

import std/[tables, deques]
import results, metrics
import logos_delivery/waku/waku_core/time
import rest/messaging_api/types

declarePublicCounter logos_delivery_rest_received_dropped,
  "received messages evicted from the messaging REST buffer before a poll took them"
declarePublicCounter logos_delivery_rest_send_dropped,
  "send statuses evicted from the messaging REST buffer before a poll took them"

const
  DefaultMaxReceived* = 50 ## Received messages kept between polls (spec default).
  DefaultMaxSendRequests* = 10_000
    ## Overflow guard: distinct message hashes retained between polls.

type MessagingEventCache* = ref object
  # Send events grouped by message hash, with FIFO insertion order for overflow
  # eviction. Cleared on poll.
  sendByHash: Table[string, SendStatus]
  sendOrder: Deque[string]
  maxSendRequests: int
  # Received messages, bounded ring. Cleared on poll.
  received: Deque[ReceivedMessageRecord]
  maxReceived: int
  nextReceivedSeq: uint64 ## the `seq` of the newest received record; 0 before the first

proc new*(
    T: type MessagingEventCache,
    maxReceived = DefaultMaxReceived,
    maxSendRequests = DefaultMaxSendRequests,
): MessagingEventCache =
  MessagingEventCache(
    sendByHash: initTable[string, SendStatus](),
    sendOrder: initDeque[string](),
    maxSendRequests: maxSendRequests,
    received: initDeque[ReceivedMessageRecord](),
    maxReceived: maxReceived,
  )

proc recordSend*(
    self: MessagingEventCache,
    messageHash: string,
    kind: SendEventKind,
    errorKind = Opt.none(MessageErrorKind),
    error = "",
) =
  ## Append a send event to its message's timeline, creating the entry (and
  ## evicting the oldest message past the overflow cap) as needed.
  let record = SendEventRecord(
    kind: kind, errorKind: errorKind, error: error, timestamp: getNowInNanosecondTime()
  )

  if not self.sendByHash.hasKey(messageHash):
    self.sendByHash[messageHash] = SendStatus(messageHash: messageHash, events: @[])
    self.sendOrder.addLast(messageHash)

    while self.sendOrder.len > self.maxSendRequests:
      let evicted = self.sendOrder.popFirst()
      self.sendByHash.del(evicted)
      logos_delivery_rest_send_dropped.inc()

  self.sendByHash.withValue(messageHash, status):
    status[].events.add(record)

proc recordReceived*(
    self: MessagingEventCache,
    messageHash: string,
    message: RelayWakuMessage,
    source: MessageSource,
) =
  ## Buffer a received message, dropping the oldest past the ring capacity.
  inc self.nextReceivedSeq
  self.received.addLast(
    ReceivedMessageRecord(
      seq: self.nextReceivedSeq,
      messageHash: messageHash,
      message: message,
      source: source,
    )
  )

  while self.received.len > self.maxReceived:
    discard self.received.popFirst()
    logos_delivery_rest_received_dropped.inc()

proc pollAllSend*(self: MessagingEventCache): seq[SendStatus] =
  ## Return all buffered send statuses and clear the store (evict-after-poll).
  for messageHash in self.sendOrder:
    self.sendByHash.withValue(messageHash, status):
      result.add(status[])
  self.sendByHash.clear()
  self.sendOrder.clear()

proc pollSend*(self: MessagingEventCache, messageHash: string): Opt[SendStatus] =
  ## Return the send status of one message and remove it (evict-after-poll).
  var status: SendStatus
  if not self.sendByHash.pop(messageHash, status):
    return Opt.none(SendStatus)

  # Deque has no random removal; rebuild order without the polled hash.
  var rebuilt = initDeque[string]()
  for queuedHash in self.sendOrder:
    if queuedHash != messageHash:
      rebuilt.addLast(queuedHash)
  self.sendOrder = rebuilt

  return Opt.some(status)

proc clear*(self: MessagingEventCache) =
  ## Drops every buffered send status and received message, polled or not.
  self.sendByHash.clear()
  self.sendOrder.clear()
  self.received.clear()

proc pollReceived*(self: MessagingEventCache): seq[ReceivedMessageRecord] =
  ## Return buffered received messages (oldest first) and clear (evict-after-poll).
  for record in self.received:
    result.add(record)
  self.received.clear()

{.pop.}
