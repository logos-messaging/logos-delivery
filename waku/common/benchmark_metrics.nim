{.push raises: [].}

import std/times
import metrics

export metrics

declarePublicSummary benchmark_duration_seconds,
  "duration in seconds", ["module", "proc"]

## Sets up a deferred timer that observes elapsed seconds into
## `benchmark_duration_seconds` when the enclosing scope exits.
## The summary's `_count` field tracks the number of calls.
##
## Both `module` and `procName` are static strings resolved at compile time,
## ensuring labels are always reliable regardless of build flags.
##
## Usage:
##   import waku/common/benchmark_metrics
##
##   proc myProc*() =
##     benchmarkPoint("waku_relay", "myProc")
##     # ... rest of the proc

when defined(metrics):
  proc recordBenchmark(
      startTime: float64, module: string, procName: string
  ) {.gcsafe, raises: [].} =
    benchmark_duration_seconds.observe(
      getTime().toUnixFloat() - startTime, labelValues = [module, procName]
    )

template benchmarkPoint*(module: static string, procName: static string) =
  when defined(metrics):
    let bpStartTime = getTime().toUnixFloat()
    defer:
      recordBenchmark(bpStartTime, module, procName)
