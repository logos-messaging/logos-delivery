## In-memory cache backing the messaging event REST endpoints.
##
## REST is a poll-based client/server surface, so the interactive MessagingClient
## events must be buffered here for later observation:
##   * send-related events (sent / propagated / error) grouped by request id
##   * received messages
##
## Both surfaces are evict-after-poll: a GET returns the buffered data and clears
## it. A generous overflow cap bounds memory if nobody polls. All access happens
## on the single chronos event loop (broker listeners + REST handlers), so the
## synchronous (no-await) ops below need no locking.

{.push raises: [].}

import std/[tables, deques, options]
import results
import logos_delivery/waku/waku_core/time
import ./types

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
  # Received messages, bounded ring. Cleared on poll.
  received: Deque[ReceivedMessageRecord]
  maxReceived: int

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

  self.sendByReqId.withValue(requestId, status):
    status[].events.add(record)

proc recordReceived*(
    self: MessagingEventCache, messageHash: string, message: RelayWakuMessage
) =
  ## Buffer a received message, dropping the oldest past the ring capacity.
  self.received.addLast(
    ReceivedMessageRecord(messageHash: messageHash, message: message)
  )

  while self.received.len > self.maxReceived:
    discard self.received.popFirst()

proc pollAllSend*(self: MessagingEventCache): seq[SendStatus] =
  ## Return all buffered send statuses and clear the store (evict-after-poll).
  for reqId in self.sendOrder:
    self.sendByReqId.withValue(reqId, status):
      result.add(status[])
  self.sendByReqId.clear()
  self.sendOrder.clear()

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

proc pollReceived*(self: MessagingEventCache): seq[ReceivedMessageRecord] =
  ## Return buffered received messages (oldest first) and clear (evict-after-poll).
  for record in self.received:
    result.add(record)
  self.received.clear()

{.pop.}
