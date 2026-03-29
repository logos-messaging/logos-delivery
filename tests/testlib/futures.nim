import chronos

import waku/[waku_core/message, waku_store]

const
  FUTURE_TIMEOUT* = 1.seconds
  FUTURE_TIMEOUT_MEDIUM* = 5.seconds
  FUTURE_TIMEOUT_LONG* = 10.seconds
  FUTURE_TIMEOUT_SHORT* = 100.milliseconds
  FUTURE_TIMEOUT_SCORING* = 13.seconds # Scoring is 12s, so we need to wait more

proc newPushHandlerFuture*(): Future[(string, WakuMessage)] =
  newFuture[(string, WakuMessage)]()

proc newBoolFuture*(): Future[bool] =
  newFuture[bool]()

proc newHistoryFuture*(): Future[StoreQueryRequest] =
  newFuture[StoreQueryRequest]()

proc toResult*[T](future: Future[T]): Result[T, string] =
  if future.cancelled():
    return chronos.err("Future timeouted before completing.")
  elif future.finished() and not future.failed():
    return chronos.ok(future.read())
  else:
    return chronos.err("Future finished but failed.")

proc toResult*(future: Future[void]): Result[void, string] =
  if future.cancelled():
    return chronos.err("Future timeouted before completing.")
  elif future.finished() and not future.failed():
    return chronos.ok()
  else:
    return chronos.err("Future finished but failed.")

proc waitForResult*[T](
    future: Future[T], timeout = FUTURE_TIMEOUT
): Future[Result[T, string]] {.async.} =
  discard await future.withTimeout(timeout)
  return future.toResult()

proc reset*[T](future: Future[T]): void =
  # Likely an incomplete reset, but good enough for testing purposes (for now)
  future.internalError = nil
  future.internalState = FutureState.Pending
