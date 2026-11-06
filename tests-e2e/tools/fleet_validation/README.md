# Fleet validation

Drives liblogosdelivery clients against the logos.dev fleet and measures loss,
latency and fleet load per DC, over TCP and QUIC.

## Setup

```bash
tests-e2e/scripts/prepare_lib.sh   # or: make liblogosdelivery NIMFLAGS="-d:chronicles_log_level=INFO"
python3 -m venv .venv && .venv/bin/pip install cffi cbor2 result pyyaml
SSH_USER=<you> ./fleet_tunnels.sh up   # fleet metrics on :18001-18006, logs in fleet-logs/
```

## Run

```bash
.venv/bin/python orchestrator.py scenarios/smoke.yaml
```

Output goes to `runs/<run_id>/[<case>/]<transport>/` (`report.md`, `summary.json`,
raw `nodes/*.jsonl`, fleet `metrics/*.prom`), rolled up in `runs/<run_id>/SUMMARY.md`.

## Constraints

- The fleet prunes more than 5 connections per source IP (`DefaultColocationLimit`),
  so each case runs 2 senders + 2 receivers and cases run sequentially.
- Clients mirror the `logos.dev` preset without using it: preset entry nodes are
  appended to `entry-node` overrides, which would defeat per-DC pinning.
- Core clients still learn other fleet nodes via rendezvous/peer exchange (no
  override to disable them); Edge clients stay on their DC's two nodes.
