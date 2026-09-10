# Sourced from: nim-libp2p/tests/tools/unittest.nim
# Adds the ability for asyncSetup and asyncTeardown to be used in unittest2

import std/macros
import chronos, testutils/unittests

template asyncTeardown*(body: untyped): untyped =
  teardown:
    waitFor(
      (
        proc() {.async, gcsafe.} =
          body
      )()
    )

template asyncSetup*(body: untyped): untyped =
  setup:
    waitFor(
      (
        proc() {.async, gcsafe.} =
          body
      )()
    )

const
  timeoutDefault: Duration = 10.seconds
  sleepIntervalDefault: Duration = 100.milliseconds

proc buildAndExpr(n: NimNode): NimNode =
  # Helper proc to recursively build a combined boolean expression

  if n.kind == nnkStmtList and n.len > 0:
    var combinedExpr = n[0] # Start with the first expression
    for i in 1 ..< n.len:
      # Combine the current expression with the next using 'and'
      combinedExpr = newCall("and", combinedExpr, n[i])
    return combinedExpr
  else:
    return n

macro checkUntilTimeoutCustom*(
    timeout: Duration, sleepInterval: Duration, code: untyped
): untyped =
  ## Periodically checks a given condition until it is true or a timeout occurs.
  ##
  ## `code`: untyped - A condition expression that should eventually evaluate to true.
  ## `timeout`: Duration - The maximum duration to wait for the condition to be true.

  # Build the combined expression
  let combinedBoolExpr = buildAndExpr(code)

  quote:
    proc checkExpiringInternal(): Future[void] {.gensym, async.} =
      let start = Moment.now()
      while true:
        if Moment.now() > (start + `timeout`):
          checkpoint(
            "[TIMEOUT] Timeout was reached and the conditions were not true. Check if the code is working as " &
              "expected or consider increasing the timeout param."
          )
          check `code`
          return
        else:
          if `combinedBoolExpr`:
            return
          else:
            await sleepAsync(`sleepInterval`)

    await checkExpiringInternal()

macro checkUntilTimeout*(code: untyped): untyped =
  ## Same as `checkUntilTimeoutCustom` but with a default timeout of 10s with 100ms
  ## interval.
  quote:
    checkUntilTimeoutCustom(timeoutDefault, sleepIntervalDefault, `code`)
