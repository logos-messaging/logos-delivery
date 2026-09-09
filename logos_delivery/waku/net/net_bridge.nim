## Carries net ops to a backend registered over the C ABI, and carries the
## answers back. A backend answers from a foreign thread, so a response crosses
## on shared memory and wakes the library thread through a signal.

{.push raises: [].}

import std/[json, locks, tables]
import results, chronicles, chronos, chronos/threadsync, metrics
import ./net_transport

declarePublicCounter logos_delivery_net_bridge_ops,
  "number of net backend ops by outcome", ["op", "outcome"]

logScope:
  topics = "waku net bridge"

const
  NetBackendAbiVersion* = 1'u32
  MaxNetBackends = 8
  MaxBackendNameLen = 63

type
  NetSubmitFn* = proc(
    requestId: uint64, opJson: cstring, opLen: csize_t, userData: pointer
  ) {.cdecl, gcsafe, raises: [].}

  NetBackendTable* = object
    version*: uint32
    submit*: NetSubmitFn

  BackendSlot = object
    name: array[MaxBackendNameLen + 1, char]
    submit: NetSubmitFn
    userData: pointer
    used: bool

  Response = object
    next: ptr Response
    requestId: uint64
    ok: bool
    len: int
    data: ptr UncheckedArray[byte]

  OpAnswer = object
    ok: bool
    data: string

  NetBridgeTransport* = ref object of NetTransport
    name*: string
    submitFn: NetSubmitFn
    userData: pointer

var
  bridgeLock: Lock
  backends: array[MaxNetBackends, BackendSlot]
  responseHead: ptr Response
  responseTail: ptr Response
  responseSignal: ThreadSignalPtr
  signalReady: bool
  drainClaimed: bool

var nextRequestId: uint64

var
  pending {.threadvar.}: Table[uint64, Future[OpAnswer]]
  drainFut {.threadvar.}: Future[void]

initLock(bridgeLock)

proc slotFor(name: cstring): int =
  ## Caller holds the lock. A free slot when the name is new, else the match.
  var free = -1
  for i in 0 ..< MaxNetBackends:
    if not backends[i].used:
      if free < 0:
        free = i
      continue
    if cast[cstring](addr backends[i].name[0]) == name:
      return i
  return free

proc registerNetBackend*(
    name: cstring, table: ptr NetBackendTable, userData: pointer
): cint {.gcsafe.} =
  if name.isNil() or table.isNil() or table.submit.isNil():
    return 1
  if table.version != NetBackendAbiVersion:
    return 2
  ## Read once: the caller owns that buffer, so a second `len` could size the
  ## copy past the array the first one cleared.
  let nameLen = len(name)
  if nameLen > MaxBackendNameLen:
    return 3

  acquire(bridgeLock)
  defer:
    release(bridgeLock)

  let slot = slotFor(name)
  if slot < 0:
    return 4

  zeroMem(addr backends[slot].name[0], MaxBackendNameLen + 1)
  copyMem(addr backends[slot].name[0], cast[pointer](name), nameLen)
  backends[slot].submit = table.submit
  backends[slot].userData = userData
  backends[slot].used = true

  return 0

proc freeResponse(node: ptr Response) =
  if not node.data.isNil():
    deallocShared(node.data)
  deallocShared(node)

proc netBackendRespond*(
    requestId: uint64, ok: bool, data: pointer, len: int
): cint {.gcsafe.} =
  ## Runs on the backend's thread: it may touch no Nim heap and must not block.
  if len < 0:
    return 1

  let node = cast[ptr Response](allocShared0(sizeof(Response)))
  node.requestId = requestId
  node.ok = ok

  if len > 0 and not data.isNil():
    node.data = cast[ptr UncheckedArray[byte]](allocShared(len))
    copyMem(node.data, data, len)
    node.len = len

  acquire(bridgeLock)

  ## No drain means nothing waits on this and nothing would ever free it.
  if not signalReady:
    release(bridgeLock)
    freeResponse(node)
    return 1

  if responseTail.isNil():
    responseHead = node
  else:
    responseTail.next = node
  responseTail = node

  ## Fired under the lock, because a drain on its way out closes the signal
  ## under the same lock. Outside it, this could write to a closed handle.
  discard responseSignal.fireSync()

  release(bridgeLock)

  return 0

proc takeResponses(): ptr Response =
  acquire(bridgeLock)
  let head = responseHead
  responseHead = nil
  responseTail = nil
  release(bridgeLock)

  return head

proc answerOf(node: ptr Response): OpAnswer =
  var answer = OpAnswer(ok: node.ok)
  if node.len > 0:
    answer.data = newString(node.len)
    copyMem(addr answer.data[0], node.data, node.len)

  return answer

proc dispatchResponses() =
  var node = takeResponses()
  while not node.isNil():
    let next = node.next

    pending.withValue(node.requestId, fut):
      if not fut[].finished():
        fut[].complete(answerOf(node))
    pending.del(node.requestId)

    freeResponse(node)

    node = next

proc releaseDrain() =
  acquire(bridgeLock)
  let signal = responseSignal
  let hadSignal = signalReady
  var queued = responseHead

  responseHead = nil
  responseTail = nil
  signalReady = false
  drainClaimed = false
  release(bridgeLock)

  while not queued.isNil():
    let next = queued.next
    freeResponse(queued)
    queued = next

  if hadSignal:
    discard signal.close()

proc drainLoop() {.async: (raises: []).} =
  while true:
    try:
      await responseSignal.wait()
    except CancelledError:
      break
    except AsyncError as e:
      error "the net bridge signal failed, so no answer can reach this thread",
        err = e.msg
      break

    dispatchResponses()

  drainFut = nil
  releaseDrain()

proc startDrain(): Result[void, string] =
  if not drainFut.isNil():
    return ok()

  ## `pending` and the loop are per thread, the signal and the queue are not.
  ## A second thread taking them over would strand every future the first one
  ## is still holding, so it is refused instead.
  acquire(bridgeLock)
  let taken = drainClaimed
  if not taken:
    drainClaimed = true
  release(bridgeLock)

  if taken:
    return err("the net bridge already belongs to another thread")

  let signal = ThreadSignalPtr.new().valueOr:
    acquire(bridgeLock)
    drainClaimed = false
    release(bridgeLock)

    return err("failed to create the net bridge signal: " & error)

  acquire(bridgeLock)
  responseSignal = signal
  signalReady = true
  release(bridgeLock)

  drainFut = drainLoop()

  return ok()

proc getNetTransport*(name: string): Result[NetTransport, string] =
  ## Runs on the library thread, where the returned transport is used.
  acquire(bridgeLock)
  var found = -1
  for i in 0 ..< MaxNetBackends:
    if backends[i].used and $cast[cstring](addr backends[i].name[0]) == name:
      found = i
      break
  let slot =
    if found < 0:
      BackendSlot()
    else:
      backends[found]
  release(bridgeLock)

  if found < 0:
    return err("no net backend named '" & name & "' is registered")

  ?startDrain()

  return ok(
    NetTransport(
      NetBridgeTransport(name: name, submitFn: slot.submit, userData: slot.userData)
    )
  )

method submit*(
    transport: NetBridgeTransport, op: string, args: JsonNode, timeout: Duration
): Future[Result[JsonNode, string]] {.async: (raises: []).} =
  let payload =
    try:
      $(%*{"op": op, "args": args})
    except CatchableError as e:
      return err("failed to encode op " & op & ": " & e.msg)

  inc(nextRequestId)
  let requestId = nextRequestId
  let fut = Future[OpAnswer].Raising([CancelledError]).init("netbridge.op")
  pending[requestId] = fut

  transport.submitFn(
    requestId, cstring(payload), csize_t(payload.len), transport.userData
  )

  var answer: OpAnswer
  try:
    if not await fut.withTimeout(timeout):
      pending.del(requestId)
      logos_delivery_net_bridge_ops.inc(labelValues = [op, "timeout"])
      return err("op " & op & " timed out")
    answer = fut.read()
  except CatchableError as e:
    pending.del(requestId)
    logos_delivery_net_bridge_ops.inc(labelValues = [op, "failed"])
    return err("op " & op & " failed: " & e.msg)

  if not answer.ok:
    logos_delivery_net_bridge_ops.inc(labelValues = [op, "error"])
    return err(answer.data)

  let node =
    try:
      parseJson(answer.data)
    except CatchableError as e:
      logos_delivery_net_bridge_ops.inc(labelValues = [op, "failed"])
      return err("op " & op & " returned invalid JSON: " & e.msg)

  logos_delivery_net_bridge_ops.inc(labelValues = [op, "ok"])

  return ok(node)

{.pop.}
