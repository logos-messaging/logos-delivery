{.push raises: [].}

import std/math
import chronos, chronicles, metrics

logScope:
  topics = "waku event_loop_monitor"

declarePublicGauge event_loop_load,
  "chronos event loop load EWMA by window (1.0 = sustained lag at MaxAcceptedLag)",
  labels = ["window"]

declarePublicCounter event_loop_accumulated_lag_secs,
  "chronos event loop total accumulated lag in seconds since node start"

type OnLagChange* = proc(lagTooHigh: bool) {.gcsafe, raises: [].}

proc eventLoopMonitorLoop*(onLagChange: OnLagChange = nil) {.async.} =
  ## Monitors chronos event loop responsiveness by measuring how much each
  ## iteration oversleeps its `CheckInterval`.
  ##
  ## The lag is normalised against `MaxAcceptedLag` and tracked as an EWMA
  ## over 1, 5, and 15-minute windows (Unix load-average decay model),
  ## exposed via the `event_loop_load` gauge (labelled by window: 1m/5m/15m):
  ##
  ##   load < 1.0   → within budget
  ##   load = 1.0   → sustained lag at MaxAcceptedLag (fully loaded)
  ##   load > 1.0   → over budget; e.g. 2.0 means twice the accepted lag
  ##
  ## `onLagChange` is called when instantaneous lag crosses `MaxAcceptedLag`.

  const CheckInterval = 5.seconds
  const MaxAcceptedLag = 50.milliseconds

  # Decay factors: α = 1 − e^(−CheckInterval_secs / window_secs)
  # Mirrors the Unix load-average convention so each EWMA has a half-life equal
  # to its named window.
  const alpha1m = 1.0 - exp(-5.0 / 60.0) # ≈ 0.0821
  const alpha5m = 1.0 - exp(-5.0 / 300.0) # ≈ 0.0165
  const alpha15m = 1.0 - exp(-5.0 / 900.0) # ≈ 0.0055

  var ewma1m = 0.0
  var ewma5m = 0.0
  var ewma15m = 0.0

  var now = Moment.now()
  var lagWasHigh = false

  while true:
    let lastWakeup = now
    await sleepAsync(CheckInterval)
    now = Moment.now()

    let actualElapsed = now - lastWakeup
    let lag = max(ZeroDuration, actualElapsed - CheckInterval)
    const maxAcceptedLagSecs = MaxAcceptedLag.nanoseconds.float64 / 1_000_000_000.0

    let lagSecs = lag.nanoseconds.float64 / 1_000_000_000.0
    let load = lagSecs / maxAcceptedLagSecs

    event_loop_accumulated_lag_secs.inc(lagSecs)

    ewma1m = alpha1m * load + (1.0 - alpha1m) * ewma1m
    ewma5m = alpha5m * load + (1.0 - alpha5m) * ewma5m
    ewma15m = alpha15m * load + (1.0 - alpha15m) * ewma15m

    event_loop_load.set(round(ewma1m, 4), labelValues = ["1m"])
    event_loop_load.set(round(ewma5m, 4), labelValues = ["5m"])
    event_loop_load.set(round(ewma15m, 4), labelValues = ["15m"])

    let lagIsHigh = lag > MaxAcceptedLag

    if lag > CheckInterval:
      warn "chronos event loop severely lagging, many tasks may be accumulating",
        expected_secs = CheckInterval.seconds,
        lag_secs = round(lagSecs, 4),
        load_1m = round(ewma1m, 4),
        load_5m = round(ewma5m, 4),
        load_15m = round(ewma15m, 4)

    if not onLagChange.isNil() and lagIsHigh != lagWasHigh:
      lagWasHigh = lagIsHigh
      onLagChange(lagIsHigh)
