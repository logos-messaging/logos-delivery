# Logging policy

This document defines what each log level means in Logos Messaging and how to
choose a level for a new log statement. It exists so that levels carry a
consistent, enforceable meaning for our two main audiences:

- **Operators** run at `INFO`: node state and health, no noise.
- **Developers** run at `DEBUG`: protocol interactions, no spam.

## Guiding principle

> **A healthy node logs nothing at WARN or above.**

Every `WARN`/`ERROR`/`FATAL` line must indicate something to fix, investigate, or
report. In review, ask: would a healthy node ever hit this line? If yes, it is
not `WARN` or above.

## Levels

Increasing severity: `TRACE`, `DEBUG`, `INFO`, `NOTICE`, `WARN`, `ERROR`,
`FATAL`.

- **TRACE** — high-volume internals: per-message relay/gossipsub handling,
  payloads, validation internals, loop ticks. Filtered to a topic when used.
- **DEBUG** — the developer narrative: one line per protocol interaction
  (request served, peer selected, dial result, retry attempt). Scales with
  protocol activity, not raw throughput.
- **INFO** — the operator narrative: lifecycle steps, one mount summary,
  connection-state changes, one periodic health line, and messages sent or
  received through the Messaging / Reliable Channels API. Not for
  per-peer-event churn.
- **NOTICE** — rare must-see lifecycle facts, visible above `INFO`: node
  started (version, addresses, ENR), shutdown initiated. A handful per process.
- **WARN** — degraded but recoverable, or config needing attention: exhausted
  retries for an optional capability, suspicious-but-valid config, deprecated
  options.
- **ERROR** — local malfunction: a broken internal assumption or a
  node-initiated operation that failed and impairs this node. Never caused
  solely by remote-peer input.
- **FATAL** — node cannot continue; process exit follows.

## Decision rules

1. **Remote/network anomalies** (invalid messages, malformed ENRs, unreachable
   peers) — `DEBUG` (`TRACE` on the per-message path) plus a metric counter.
2. **Retry loops** — each attempt `DEBUG` with attempt number; on exhaustion
   `WARN` if an optional capability is degraded, `ERROR` if core function is
   lost.
3. **Persistent conditions** — log the transition, not every tick. Repeats go
   to `DEBUG`.
4. **API and idempotent guards** ("not mounted", "already started") — `DEBUG`.
5. **Deprecated options** — config to be removed in future versions; `WARN`
   once, at config-parse time.
6. **Periodic status** — one consolidated `INFO` line per tick; detail to
   metrics or `DEBUG`.
7. **Hot paths** — request/response protocols `DEBUG` per request; relay/gossip
   `TRACE` per message.

## Style

- Start the message with a capital letter.
- Keep the message a constant with variable data in `key = value` fields,
  including the cause on failures (`error = $err`).
- Log an error at the boundary where it is handled, not before returning it.
- One `logScope` topic per module.
- No side effects or expensive computation in log arguments; lower levels may
  be compiled out.
- Give any demoted `WARN`/`ERROR` a metric counter if it was the only signal.