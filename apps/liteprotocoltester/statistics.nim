{.push raises: [].}

import
  std/[sets, tables, sequtils, options, strformat],
  chronos/timer as chtimer,
  chronicles,
  chronos,
  results,
  libp2p/peerid

from std/sugar import `=>`

import ./tester_message, ./lpt_metrics

type
  ArrivalInfo = object
    arrivedAt: Moment
    prevArrivedAt: Moment
    prevIndex: uint32

  MessageInfo = tuple[msg: ProtocolTesterMessage, info: ArrivalInfo]
  DupStat = tuple[hash: string, dupCount: int, size: uint64]

  StatHelper = object
    prevIndex: uint32
    prevArrivedAt: Moment
    lostIndices: HashSet[uint32]
    seenIndices: HashSet[uint32]
    maxIndex: uint32
    duplicates: OrderedTable[uint32, DupStat]

  Statistics* = object
    received: Table[uint32, MessageInfo]
    firstReceivedIdx*: uint32
    allMessageCount*: uint32
    receivedMessages*: uint32
    misorderCount*: uint32
    lateCount*: uint32
    duplicateCount*: uint32
    helper: StatHelper

  PerPeerStatistics* = Table[string, Statistics]

func `$`*(a: Duration): string {.inline.} =
  ## Original stringify implementation from chronos/timer.nim is not capable of printing 0ns
  ## Returns string representation of Duration ``a`` as nanoseconds value.

  if a.isZero:
    return "0ns"

  return chtimer.`$`(a)

proc init*(T: type Statistics, expectedMessageCount: int = 1000): T =
  result.helper.prevIndex = 0
  result.helper.maxIndex = 0
  result.helper.seenIndices.init(expectedMessageCount)
  result.received = initTable[uint32, MessageInfo](expectedMessageCount)
  return result

proc addMessage*(
    self: var Statistics, sender: string, msg: ProtocolTesterMessage, msgHash: string
) =
  if self.allMessageCount == 0:
    self.allMessageCount = msg.count
    self.firstReceivedIdx = msg.index
  elif self.allMessageCount != msg.count:
    error "Message count mismatch at message",
      index = msg.index, expected = self.allMessageCount, got = msg.count

  let currentArrived: MessageInfo = (
    msg: msg,
    info: ArrivalInfo(
      arrivedAt: Moment.now(),
      prevArrivedAt: self.helper.prevArrivedAt,
      prevIndex: self.helper.prevIndex,
    ),
  )
  lpt_receiver_received_bytes.inc(labelValues = [sender], amount = msg.size.int64)
  if self.received.hasKeyOrPut(msg.index, currentArrived):
    inc(self.duplicateCount)
    self.helper.duplicates.mgetOrPut(msg.index, (msgHash, 0, msg.size)).dupCount.inc()
    warn "Duplicate message",
      index = msg.index,
      hash = msgHash,
      times_duplicated = self.helper.duplicates[msg.index].dupCount
    lpt_receiver_duplicate_messages_count.inc(labelValues = [sender])
    lpt_receiver_distinct_duplicate_messages_count.set(
      labelValues = [sender], value = self.helper.duplicates.len()
    )
    return

  ## detect misorder arrival and possible lost messages
  if self.helper.prevIndex + 1 < msg.index:
    inc(self.misorderCount)
    warn "Misordered message arrival",
      index = msg.index, expected = self.helper.prevIndex + 1
  elif self.helper.prevIndex > msg.index:
    inc(self.lateCount)
    warn "Late message arrival", index = msg.index, expected = self.helper.prevIndex + 1

  self.helper.maxIndex = max(self.helper.maxIndex, msg.index)
  self.helper.prevIndex = msg.index
  self.helper.prevArrivedAt = currentArrived.info.arrivedAt
  inc(self.receivedMessages)
  lpt_receiver_received_messages_count.inc(labelValues = [sender])
  lpt_receiver_missing_messages_count.set(
    labelValues = [sender], value = (self.helper.maxIndex - self.receivedMessages).int64
  )

proc addMessage*(
    self: var PerPeerStatistics,
    peerId: string,
    msg: ProtocolTesterMessage,
    msgHash: string,
) =
  if not self.contains(peerId):
    self[peerId] = Statistics.init()

  let shortSenderId = PeerId.init(msg.sender).map(p => p.shortLog()).valueOr(msg.sender)

  discard catch:
    self[peerId].addMessage(shortSenderId, msg, msgHash)

  lpt_receiver_sender_peer_count.set(value = self.len)

proc lastMessageArrivedAt*(self: Statistics): Option[Moment] =
  if self.receivedMessages > 0:
    return some(self.helper.prevArrivedAt)
  return none(Moment)

proc lossCount*(self: Statistics): uint32 =
  self.helper.maxIndex - self.receivedMessages

proc calcLatency*(self: Statistics): tuple[min, max, avg: Duration] =
  var
    minLatency = nanos(0)
    maxLatency = nanos(0)
    avgLatency = nanos(0)

  if self.receivedMessages > 2:
    try:
      var prevArrivedAt = self.received[self.firstReceivedIdx].info.arrivedAt

      for idx, (msg, arrival) in self.received.pairs:
        if idx <= 1:
          continue
        let expectedDelay = nanos(msg.sincePrev)

        ## latency will be 0 if arrived in shorter time than expected
        var latency = arrival.arrivedAt - arrival.prevArrivedAt - expectedDelay

        ## will not measure zero latency, it is unlikely to happen but in case happens could
        ## ditort the min latency calulculation as we want to calculate the feasible minimum.
        if latency > nanos(0):
          if minLatency == nanos(0):
            minLatency = latency
          else:
            minLatency = min(minLatency, latency)

        maxLatency = max(maxLatency, latency)
        avgLatency += latency

      avgLatency = avgLatency div (self.receivedMessages - 1)
    except KeyError:
      error "Error while calculating latency: " & getCurrentExceptionMsg()

  return (minLatency, maxLatency, avgLatency)

proc missingIndices*(self: Statistics): seq[uint32] =
  var missing: seq[uint32] = @[]
  for idx in 1 .. self.helper.maxIndex:
    if not self.received.hasKey(idx):
      missing.add(idx)
  return missing

proc distinctDupCount(self: Statistics): int {.inline.} =
  return self.helper.duplicates.len()

proc allDuplicates(self: Statistics): int {.inline.} =
  var total = 0
  for _, (_, dupCount, _) in self.helper.duplicates.pairs:
    total += dupCount
  return total

proc dupMsgs(self: Statistics): string =
  var dupMsgs: string = ""
  for idx, (hash, dupCount, size) in self.helper.duplicates.pairs:
    dupMsgs.add(
      "    index: " & $idx & " | hash: " & hash & " | count: " & $dupCount & " | size: " &
        $size & "\n"
    )
  return dupMsgs

proc echoStat*(self: Statistics, peerId: string) =
  let (minL, maxL, avgL) = self.calcLatency()
  lpt_receiver_latencies.set(labelValues = [peerId, "min"], value = minL.nanos())
  lpt_receiver_latencies.set(labelValues = [peerId, "avg"], value = avgL.nanos())
  lpt_receiver_latencies.set(labelValues = [peerId, "max"], value = maxL.nanos())

  let printable = catch:
    """*------------------------------------------------------------------------------------------*
|  Expected  |  Received  |   Target   |    Loss    |  Misorder  |    Late    |            |
|{self.helper.maxIndex:>11} |{self.receivedMessages:>11} |{self.allMessageCount:>11} |{self.lossCount():>11} |{self.misorderCount:>11} |{self.lateCount:>11} |            |
*------------------------------------------------------------------------------------------*
| Latency stat:                                                                            |
|    min latency: {$minL:<73}|
|    avg latency: {$avgL:<73}|
|    max latency: {$maxL:<73}|
*------------------------------------------------------------------------------------------*
| Duplicate stat:                                                                          |
|    distinct duplicate messages: {$self.distinctDupCount():<57}|
|    sum duplicates             : {$self.allDuplicates():<57}|
  Duplicated messages:
    {self.dupMsgs()}
*------------------------------------------------------------------------------------------*
| Lost indices:                                                                            |
|  {self.missingIndices()} |
*------------------------------------------------------------------------------------------*""".fmt()

  echo printable.valueOr("Error while printing statistics: " & error.msg)

proc jsonStat*(self: Statistics): string =
  let minL, maxL, avgL = self.calcLatency()

  let json = catch:
    """{{"expected":{self.helper.maxIndex},
         "received": {self.receivedMessages},
         "target": {self.allMessageCount},
         "loss": {self.lossCount()},
         "misorder": {self.misorderCount},
         "late": {self.lateCount},
         "duplicate": {self.duplicateCount},
         "latency":
           {{"avg": "{avgL}",
             "min": "{minL}",
             "max": "{maxL}"
           }},
          "lostIndices": {self.missingIndices()}
     }}""".fmt()

  return json.valueOr("{\"result:\": \"" & error.msg & "\"}")

proc echoStats*(self: var PerPeerStatistics) =
  for peerId, stats in self.pairs:
    let peerLine = catch:
      "Receiver statistics from peer {peerId}".fmt()
    peerLine.isOkOr:
      echo "Error while printing statistics"
      continue
    echo peerLine.get()
    stats.echoStat(peerId)

proc jsonStats*(self: PerPeerStatistics): string =
  try:
    #!fmt: off
    var json = "{\"statistics\": ["
    var first = true
    for peerId, stats in self.pairs:
      if first:
        first = false
      else:
        json.add(", ")
      json.add("{{\"sender\": \"{peerId}\", \"stat\":".fmt())
      json.add(stats.jsonStat())
      json.add("}")
    json.add("]}")
    return json
    #!fmt: on
  except CatchableError:
    return
      "{\"result:\": \"Error while generating json stats: " & getCurrentExceptionMsg() &
      "\"}"

proc lastMessageArrivedAt*(self: PerPeerStatistics): Option[Moment] =
  var lastArrivedAt = Moment.init(0, Millisecond)
  for stat in self.values:
    let lastMsgFromPeerAt = stat.lastMessageArrivedAt().valueOr:
      continue

    if lastMsgFromPeerAt > lastArrivedAt:
      lastArrivedAt = lastMsgFromPeerAt

  if lastArrivedAt == Moment.init(0, Millisecond):
    return none(Moment)

  return some(lastArrivedAt)

proc checkIfAllMessagesReceived*(
    self: PerPeerStatistics, maxWaitForLastMessage: Duration
): Future[bool] {.async.} =
  # if there are no peers have sent messages, assume we just have started.
  if self.len == 0:
    return false

  # check if numerically all messages are received.
  # this suggest we received at least one message already from one peer
  var isAlllMessageReceived = true
  for stat in self.values:
    if (stat.allMessageCount == 0 and stat.receivedMessages == 0) or
        stat.helper.maxIndex < stat.allMessageCount:
      isAlllMessageReceived = false
      break

  if not isAlllMessageReceived:
    # if not all message received we still need to check if last message arrived within a time frame
    # to avoid endless waiting while publishers are already quit.
    let lastMessageAt = self.lastMessageArrivedAt()
    if lastMessageAt.isNone():
      return false

    # last message shall arrived within time limit
    if Moment.now() - lastMessageAt.get() < maxWaitForLastMessage:
      return false
    else:
      info "No message since max wait time", maxWait = $maxWaitForLastMessage

  ## Ok, we see last message arrived from all peers,
  ## lets check if all messages are received
  ## and if not let's wait another 20 secs to give chance the system will send them.
  var shallWait = false
  for stat in self.values:
    if stat.receivedMessages < stat.allMessageCount:
      shallWait = true

  if shallWait:
    await sleepAsync(20.seconds)

  return true
