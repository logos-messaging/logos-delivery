import chronos
import results

const
  DefaultRetryDelay* = 4000.millis
  DefaultRetryCount* = 15'u

type RetryStrategy* = object
  retryDelay*: Duration
  retryCount*: uint

proc new*(T: type RetryStrategy): RetryStrategy =
  return RetryStrategy(retryDelay: DefaultRetryDelay, retryCount: DefaultRetryCount)

proc retryWrapper*[T](
    retryStrategy: RetryStrategy, errStr: string, body: proc(): Future[T] {.async.}
): Future[Result[T, string]] {.async.} =
  var retryCount = retryStrategy.retryCount
  var lastError = ""

  while retryCount > 0:
    try:
      let value = await body()
      return ok(value)
    except CatchableError as e:
      retryCount -= 1
      lastError = e.msg
      if retryCount > 0:
        await sleepAsync(retryStrategy.retryDelay)

  return err(errStr & ": " & lastError)
