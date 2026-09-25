## In-memory cache backing the messaging event REST endpoints.
##
## REST is a poll-based client/server surface, so the interactive MessagingClient
## events must be buffered here for later observation:
##   * send-related events (sent / propagated / error) grouped by request id
##   * received messages
##
## Both surfaces are evict-after-poll: a GET returns the buffered data and clears
## it. A generous overflow cap bounds memory if nobody polls. Each eviction adds
## to the `dropped` count of the next poll and to a metric. All access happens
## on the single chronos event loop (broker listeners + REST handlers), so the
## synchronous (no-await) ops below need no locking.

{.push raises: [].}

import std/[tables, deques, options]
import results, metrics
import logos_delivery/waku/waku_core/time
import ./types

declarePublicCounter logos_delivery_rest_received_dropped,
  "received messages evicted from the messaging REST buffer before a poll took them"
declarePublicCounter logos_delivery_rest_send_status_dropped,
  "send statuses (request ids) evicted from the messaging REST buffer before a poll took them"

const
  DefaultMaxReceived* = 50 ## Received messages kept between polls (spec default).
  DefaultMaxSendRequests* = 10_000
    ## Overflow guard: distinct request ids retained between polls.

type MessagingEventCache* = ref object
  # Send events grouped by request id, with FIFO insertion order for overflow
  # eviction. Cleared on poll.
  sendByReqId: Table[string, SendStatus]
  sendOrder: Deque[string]
  maxSendRequests: int
  sendDropped: uint64 ## request ids evicted since the last poll of all statuses
  # Received messages, bounded ring. Cleared on poll.
  received: Deque[ReceivedMessageRecord]
  maxReceived: int
  nextReceivedSeq: uint64 ## the `seq` the next received record gets, from 1
  receivedDropped: uint64 ## records evicted since the last poll

proc new*(
    T: type MessagingEventCache,
    maxReceived = DefaultMaxReceived,
    maxSendRequests = DefaultMaxSendRequests,
): MessagingEventCache =
  MessagingEventCache(
    sendByReqId: initTable[string, SendStatus](),
    sendOrder: initDeque[string](),
    maxSendRequests: maxSendRequests,
    received: initDeque[ReceivedMessageRecord](),
    maxReceived: maxReceived,
  )

proc recordSend*(
    self: MessagingEventCache,
    requestId: string,
    messageHash: string,
    kind: SendEventKind,
    error = "",
) =
  ## Append a send event to its request id's timeline, creating the entry (and
  ## evicting the oldest request id past the overflow cap) as needed.
  let record = SendEventRecord(
    kind: kind,
    messageHash: messageHash,
    error: error,
    timestamp: getNowInNanosecondTime(),
  )

  if not self.sendByReqId.hasKey(requestId):
    self.sendByReqId[requestId] = SendStatus(requestId: requestId, events: @[])
    self.sendOrder.addLast(requestId)

    while self.sendOrder.len > self.maxSendRequests:
      let evicted = self.sendOrder.popFirst()
      self.sendByReqId.del(evicted)
      inc self.sendDropped
      logos_delivery_rest_send_status_dropped.inc()

  self.sendByReqId.withValue(requestId, status):
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
    inc self.receivedDropped
    logos_delivery_rest_received_dropped.inc()

proc pollAllSend*(
    self: MessagingEventCache
): tuple[statuses: seq[SendStatus], dropped: uint64] =
  ## Return all buffered send statuses and clear the store (evict-after-poll),
  ## with the number of request ids evicted since the previous poll.
  var statuses: seq[SendStatus]
  for reqId in self.sendOrder:
    self.sendByReqId.withValue(reqId, status):
      statuses.add(status[])
  self.sendByReqId.clear()
  self.sendOrder.clear()
  let dropped = self.sendDropped
  self.sendDropped = 0
  return (statuses, dropped)

proc pollSend*(self: MessagingEventCache, requestId: string): Opt[SendStatus] =
  ## Return one request id's send status and remove it (evict-after-poll).
  var status: SendStatus
  if not self.sendByReqId.pop(requestId, status):
    return Opt.none(SendStatus)

  # Deque has no random removal; rebuild order without the polled id.
  var rebuilt = initDeque[string]()
  for reqId in self.sendOrder:
    if reqId != requestId:
      rebuilt.addLast(reqId)
  self.sendOrder = rebuilt

  return Opt.some(status)

proc pollReceived*(
    self: MessagingEventCache
): tuple[records: seq[ReceivedMessageRecord], dropped: uint64] =
  ## Return buffered received messages (oldest first) and clear (evict-after-poll),
  ## with the number of records evicted since the previous poll.
  var records: seq[ReceivedMessageRecord]
  for record in self.received:
    records.add(record)
  self.received.clear()
  let dropped = self.receivedDropped
  self.receivedDropped = 0
  return (records, dropped)

{.pop.}
