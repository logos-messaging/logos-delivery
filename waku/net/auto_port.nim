{.push raises: [].}

import std/[net, random]
import chronos, results

const
  AutoPortRetryCount* = 20
  AutoPortMin = 50000'u16
  AutoPortMax = 59000'u16
  AutoPortAttemptTimeout = chronos.seconds(30)

proc getAutoPort*(): uint16 =
  var rng = initRand()
  uint16(rng.rand(AutoPortMin.int .. AutoPortMax.int))

proc tryWithAutoPort*[T](
    startingPort: Port,
    attempt: proc(p: Port): Future[Result[T, string]] {.async: (raises: []).},
): Future[Result[T, string]] {.async: (raises: []).} =
  ## If `startingPort == Port(0)`, call `attempt` up to `AutoPortRetryCount`
  ## times with random ports. Otherwise call it once with `startingPort`.
  ## Returns the first ok or the last err.
  let autoMode = startingPort == Port(0)
  let attempts = if autoMode: AutoPortRetryCount else: 1
  var lastErr = ""
  for i in 1 .. attempts:
    let port =
      if autoMode:
        Port(getAutoPort())
      else:
        startingPort
    let fut = attempt(port)
    let res =
      try:
        if await fut.withTimeout(AutoPortAttemptTimeout):
          await fut
        else:
          fut.cancelSoon()
          Result[T, string].err("bind attempt timed out")
      except CancelledError:
        fut.cancelSoon()
        Result[T, string].err("bind attempt cancelled")
    if res.isOk():
      return ok(res.get())
    lastErr = res.error
  if autoMode:
    return err("auto-port exhausted; last error: " & lastErr)
  return err("port bind failed: " & lastErr)
