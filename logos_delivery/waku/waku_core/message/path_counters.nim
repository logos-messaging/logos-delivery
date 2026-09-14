## Message-path instrumentation counters (compile-time gated).
##
## Enabled only with `-d:msgPathCounters`. When the define is absent every hook
## below expands to `discard` — no globals, no runtime cost, no behaviour change.
## These counters exist purely so the message-path benchmark
## (`apps/benchmarks/message_path_bench.nim`) can validate the decode/hash-per-
## message claims in `docs/analysis/async_copy_analysis.md`.
##
## Single-threaded chronos assumption: plain `int64`, no atomics.

{.push raises: [].}

when defined(msgPathCounters):
  type MsgPathCounters* = object
    decodeCalls*: int64 ## `WakuMessage.decode` invocations
    hashCalls*: int64 ## `computeMessageHash` invocations
    decodedBytes*: int64 ## bytes fed into decode (proto buffer length)
    hashedBytes*: int64 ## bytes fed into the hash (payload + meta)

  var msgPathCounters* {.global.}: MsgPathCounters

  template countDecode*(bytes: int) =
    msgPathCounters.decodeCalls += 1
    msgPathCounters.decodedBytes += int64(bytes)

  template countHash*(bytes: int) =
    msgPathCounters.hashCalls += 1
    msgPathCounters.hashedBytes += int64(bytes)

  proc resetMsgPathCounters*() =
    msgPathCounters = MsgPathCounters()

else:
  template countDecode*(bytes: int) =
    discard

  template countHash*(bytes: int) =
    discard

{.pop.}
