## Sharded, mutex-guarded MPSC ingress for `ptr FFIThreadRequest`: N intrusive
## FIFOs (one per producer) spread lock contention; the request is its own node
## so enqueue never touches a Nim GC heap. Unbounded — submit never blocks.

import std/[atomics, locks]
import ./ffi_thread_request

const
  RequestQueueCount* = 16
    ## Independent ingress queues; ≥ concurrent producer count keeps collisions low.
  QueuePadBytes = 192
    ## Pads each queue past a cache line (128B on Apple silicon) to avoid false
    ## sharing between adjacent queues.

static:
  # `myQueueIndex` masks with `and`, so the count must be a power of two.
  doAssert (RequestQueueCount and (RequestQueueCount - 1)) == 0,
    "RequestQueueCount must be a power of two"

type
  RequestQueue = object
    lock: Lock
    head: ptr FFIThreadRequest ## consumer pops here (oldest)
    tail: ptr FFIThreadRequest ## producers append here (newest)
    pad: array[QueuePadBytes, byte]

  RequestQueueBank* = object
    queues: array[RequestQueueCount, RequestQueue]

var gRequestQueue {.threadvar.}: int
var gRequestQueueAssigned {.threadvar.}: bool
var gRequestQueueCounter: Atomic[int]
  ## Round-robins producers onto distinct queues on first use so they fill evenly.

proc myQueueIndex(): int {.raises: [].} =
  if not gRequestQueueAssigned:
    gRequestQueue = gRequestQueueCounter.fetchAdd(1)
    gRequestQueueAssigned = true
  return gRequestQueue and (RequestQueueCount - 1)

proc initRequestQueue*(bank: var RequestQueueBank) {.raises: [].} =
  for queue in bank.queues.mitems:
    queue.lock.initLock()
    queue.head = nil
    queue.tail = nil

proc deinitRequestQueue*(bank: var RequestQueueBank) {.raises: [].} =
  ## Both producers and consumer must have stopped. Frees any still-queued request
  ## (e.g. one raced in after the final drain) so a teardown race leaks nothing.
  for queue in bank.queues.mitems:
    var request = queue.head
    while not request.isNil():
      let nextRequest = request[].next
      deleteRequest(request)
      request = nextRequest
    queue.head = nil
    queue.tail = nil
    queue.lock.deinitLock()

proc pushRequest*(
    bank: var RequestQueueBank, request: ptr FFIThreadRequest
): bool {.raises: [].} =
  ## Append `request` to this thread's queue (takes ownership). True only when the
  ## queue was empty — the one push that must wake the sleeping consumer.
  request[].next = nil
  let idx = myQueueIndex()
  withLock bank.queues[idx].lock:
    let wasEmpty = bank.queues[idx].tail.isNil()
    if bank.queues[idx].tail.isNil():
      bank.queues[idx].head = request
    else:
      bank.queues[idx].tail[].next = request
    bank.queues[idx].tail = request
    return wasEmpty

proc mergeQueues*(bank: var RequestQueueBank): ptr FFIThreadRequest {.raises: [].} =
  ## Single-consumer: splice every queue into one chain and reset them. Caller owns
  ## the chain and must read each `next` before dispatch (dispatch frees the request).
  var head: ptr FFIThreadRequest = nil
  var tail: ptr FFIThreadRequest = nil
  for queue in bank.queues.mitems:
    withLock queue.lock:
      let h = queue.head
      if not h.isNil():
        if head.isNil():
          head = h
        else:
          tail[].next = h
        tail = queue.tail
        queue.head = nil
        queue.tail = nil
  return head
