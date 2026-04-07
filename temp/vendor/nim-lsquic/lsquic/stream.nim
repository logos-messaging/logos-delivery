# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[deques, posix]
import chronos
import chronicles
import ./[lsquic_ffi, errors]

type WriteTask* = object
  data*: ptr byte
  dataLen*: int
  offset*: int
  doneFut*: Future[void].Raising([CancelledError, StreamError])

type ReadTask* = object
  data*: ptr byte
  dataLen*: int
  doneFut*: Future[int].Raising([CancelledError, StreamError])

type Stream* = ref object
  quicStream*: ptr lsquic_stream_t
  closedByEngine*: bool
  closeWrite*: bool
  # This is called when on_close callback is executed
  closed*: AsyncEvent
  # Reuse a single closed-event waiter to minimize allocations on hot paths.
  # (no per call allocation)
  closedWaiter*: Future[void].Raising([CancelledError])
  writeLock*: AsyncLock
  toWrite*: Opt[WriteTask]
  readLock*: AsyncLock
  isEof*: bool # Received a FIN from remote
  toRead*: Opt[ReadTask]
  doProcess*: proc() {.gcsafe, raises: [].}

proc new*(T: typedesc[Stream], quicStream: ptr lsquic_stream_t = nil): T =
  let closed = newAsyncEvent()
  let closedWaiter = closed.wait()
  let s = Stream(
    quicStream: quicStream,
    closed: closed,
    closedWaiter: closedWaiter,
    readLock: newAsyncLock(),
    writeLock: newAsyncLock(),
  )
  GC_ref(s) # Keep it pinned until stream_if.on_close is executed
  s

proc abortPendingWrites*(stream: Stream, reason: string = "") =
  let task = stream.toWrite.valueOr:
    return
  task.doneFut.fail(newException(StreamError, reason))
  stream.toWrite = Opt.none(WriteTask)

proc abort*(stream: Stream) =
  if stream.closeWrite and stream.isEof:
    if not stream.closed.isSet():
      stream.closed.fire()
    stream.abortPendingWrites("stream aborted")
    return

  if not stream.closedByEngine:
    let ret = lsquic_stream_close(stream.quicStream)
    if ret != 0:
      trace "could not abort stream", streamId = lsquic_stream_id(stream.quicStream)
    stream.doProcess()

  stream.closeWrite = true
  stream.isEof = true
  stream.abortPendingWrites("stream aborted")
  stream.closed.fire()

proc close*(stream: Stream) {.async: (raises: [StreamError, CancelledError]).} =
  if stream.closeWrite or stream.closedByEngine:
    return

  # Closing only the write side
  let ret = lsquic_stream_shutdown(stream.quicStream, 1)
  if ret == 0:
    if stream.isEof:
      if lsquic_stream_close(stream.quicStream) != 0:
        stream.abort()
        raise newException(StreamError, "could not close the stream")
      stream.doProcess()

    stream.abortPendingWrites("steam closed")
    stream.closeWrite = true

proc readOnce*(
    stream: Stream, dst: ptr byte, dstLen: int
): Future[int] {.async: (raises: [CancelledError, StreamError]).} =
  if dstLen == 0 or dst.isNil:
    raiseAssert "dst cannot be nil"

  if stream.isEof or stream.closedByEngine:
    return 0

  await stream.readLock.acquire()

  defer:
    try:
      stream.readLock.release()
    except AsyncLockError:
      discard # should not happen - lock acquired directly above

  # In case stream was closed while waiting for lock being acquired
  if stream.closedByEngine:
    return 0

  let n = lsquic_stream_read(stream.quicStream, dst, dstLen.csize_t)

  if n == 0:
    stream.isEof = true
    return 0
  elif n > 0:
    return n

  if n < 0 and errno != EWOULDBLOCK:
    stream.abort()
    raise newException(StreamError, "could not read: " & $errno)

  if lsquic_stream_wantread(stream.quicStream, 1) == -1:
    stream.abort()
    raise newException(StreamError, "could not set wantread")

  let doneFut =
    Future[int].Raising([CancelledError, StreamError]).init("Stream.readOnce")
  stream.toRead = Opt.some(ReadTask(data: dst, dataLen: dstLen, doneFut: doneFut))

  stream.doProcess()

  let raceFut = await race(stream.closedWaiter, doneFut)
  if raceFut == stream.closedWaiter:
    await doneFut.cancelAndWait()
    stream.isEof = true
    stream.closeWrite = true
    return 0

  return await doneFut

template readOnce*(stream: Stream, dst: var openArray[byte]): untyped =
  ## Convenience helper that forwards an openArray/seq to the pointer-based API.
  (if dst.len == 0: stream.readOnce(nil, 0)
  else: stream.readOnce(dst[0].addr, dst.len))

proc write*(
    stream: Stream, data: seq[byte]
) {.async: (raises: [CancelledError, StreamError]).} =
  if data.len == 0:
    return

  if stream.closeWrite or stream.closedByEngine:
    raise newException(StreamError, "stream closed")

  await stream.writeLock.acquire()

  defer:
    try:
      stream.writeLock.release()
    except AsyncLockError:
      discard # should not happen - lock acquired directly above

  if stream.closedByEngine:
    raise newException(StreamError, "stream closed")

  # Try to write immediately
  let p = data[0].addr
  let n = lsquic_stream_write(stream.quicStream, p, data.len.csize_t)
  if n >= data.len:
    if lsquic_stream_flush(stream.quicStream) != 0:
      stream.abort()
    stream.doProcess()
    return
  elif n < 0:
    error "could not write to stream", streamId = lsquic_stream_id(stream.quicStream), n
    raise newException(StreamError, "could not write")

  # Enqueue otherwise
  let doneFut = Future[void].Raising([CancelledError, StreamError]).init("Stream.write")
  stream.toWrite = Opt.some(
    WriteTask(data: data[0].addr, dataLen: data.len, doneFut: doneFut, offset: n)
  )

  discard lsquic_stream_wantwrite(stream.quicStream, 1)

  stream.doProcess()

  let raceFut = await race(stream.closedWaiter, doneFut)
  if raceFut == stream.closedWaiter:
    if not doneFut.finished:
      doneFut.fail(newException(StreamError, "stream closed"))
    stream.closeWrite = true

  await doneFut
