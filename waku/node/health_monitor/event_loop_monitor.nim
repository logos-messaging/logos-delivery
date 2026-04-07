{.push raises: [].}

import chronos, chronicles, metrics

logScope:
  topics = "waku event_loop_monitor"

const CheckInterval = 5.seconds

declarePublicGauge event_loop_lag_seconds,
  "chronos event loop lag in seconds: difference between actual and expected wake-up interval"

proc eventLoopMonitorLoop*() {.async.} =
  ## Monitors chronos event loop responsiveness.
  ##
  ## Schedules a task every `CheckInterval`. Because chronos is single-threaded
  ## and cooperative, the task can only resume after all previously queued work
  ## completes. The actual elapsed time between iterations therefore reflects
  ## how saturated the event loop is:
  ##
  ##   actual_elapsed ≈ CheckInterval       → loop is healthy
  ##   actual_elapsed >> CheckInterval      → tasks are accumulating / loop is stalling
  ##
  ## The lag (actual - expected) is exposed via `event_loop_lag_seconds`.

  var lastWakeup = Moment.now()
  while true:
    await sleepAsync(CheckInterval)

    let now = Moment.now()
    let actualElapsed = now - lastWakeup
    let lag = actualElapsed - CheckInterval
    let lagSecs = lag.nanoseconds.float64 / 1_000_000_000.0

    event_loop_lag_seconds.set(lagSecs)

    if lag > CheckInterval:
      warn "chronos event loop severely lagging, many tasks may be accumulating",
        expected_secs = CheckInterval.seconds,
        actual_secs = actualElapsed.nanoseconds.float64 / 1_000_000_000.0,
        lag_secs = lagSecs
    elif lag > (CheckInterval div 2):
      info "chronos event loop lag detected",
        expected_secs = CheckInterval.seconds,
        actual_secs = actualElapsed.nanoseconds.float64 / 1_000_000_000.0,
        lag_secs = lagSecs

    lastWakeup = now
