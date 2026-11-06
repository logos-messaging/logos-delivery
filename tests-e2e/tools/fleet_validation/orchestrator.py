"""Run a YAML scenario: long-lived receivers, then sender steps, per transport.

Layout: runs/<run_id>/<transport>/{manifest.json, nodes/*.jsonl, nodes/*.log, metrics/*.prom}
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import yaml

import fleet

HERE = Path(__file__).resolve().parent
PY = sys.executable
FAR_FUTURE = 4102444800  # receivers are stopped with SIGTERM, not by deadline


class PortAlloc:
    def __init__(self, base: int):
        self.next = base

    def take(self) -> int:
        port = self.next
        self.next += 2  # tcp/quic share one port, discv5 takes the next
        return port


def scrape_fleet(dest: Path, label: str):
    dest.mkdir(parents=True, exist_ok=True)
    for host, port in fleet.METRICS_PORTS.items():
        try:
            body = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5).read()
        except Exception as e:
            body = f"# scrape failed: {e}\n".encode()
        (dest / f"{label}__{host}.prom").write_bytes(body)


def spawn(args_list, log_path: Path):
    log = open(log_path, "w")
    return subprocess.Popen([PY, str(HERE / "node_proc.py")] + args_list, stdout=log, stderr=subprocess.STDOUT)


def wait_ready(paths, timeout: float) -> list:
    deadline = time.time() + timeout
    pending = set(paths)
    while pending and time.time() < deadline:
        for p in list(pending):
            if p.exists() and any('"k":"ready"' in l or '"k":"fatal"' in l for l in p.open()):
                pending.discard(p)
        time.sleep(1)
    return sorted(str(p) for p in pending)


def expand(groups, role: str):
    for g in groups:
        for i in range(g.get("count", 1)):
            yield dict(g, role=role, name=f"{role[0]}-{g['mode']}-{g['dc']}-{i}")


def run_transport(scn: dict, run_id: str, transport: str, root: Path, ports: PortAlloc):
    out = root / transport
    nodes_dir = out / "nodes"
    nodes_dir.mkdir(parents=True, exist_ok=True)
    tag = f"{run_id}-{transport}"
    topics = [fleet.topic_for_shard(tag, s) for s in scn.get("shards", range(fleet.NUM_SHARDS))]
    manifest = {"run_id": run_id, "transport": transport, "topics": topics, "steps": [], "scenario": scn}

    common = ["--run-id", tag, "--transport", transport, "--topics", ",".join(topics)]
    receivers = []
    for r in expand(scn["receivers"], "receiver"):
        jsonl = nodes_dir / f"{r['name']}.jsonl"
        argv = common + [
            "--name", r["name"], "--role", "receiver", "--mode", r["mode"], "--dc", r["dc"],
            "--port", str(ports.take()), "--out", str(jsonl), "--stop-at", str(FAR_FUTURE),
        ]
        receivers.append((spawn(argv, nodes_dir / f"{r['name']}.log"), jsonl))
    not_ready = wait_ready([j for _, j in receivers], scn.get("ready_timeout", 120))
    manifest["receivers_not_ready"] = not_ready
    print(f"[{transport}] {len(receivers)} receivers up, not ready: {not_ready}", flush=True)
    time.sleep(scn.get("warmup", 10))

    for step in scn["steps"]:
        sid = str(step["id"])
        start_at = time.time() + scn.get("sender_start_delay", 15)
        scrape_fleet(out / "metrics", f"{sid}_pre")
        senders = []
        for s in expand(step["senders"], "sender"):
            name = f"{s['name']}-st{sid}"
            argv = common + [
                "--name", name, "--step", sid, "--role", "sender", "--mode", s["mode"], "--dc", s["dc"],
                "--port", str(ports.take()), "--out", str(nodes_dir / f"{name}.jsonl"),
                "--rate", str(s.get("rate", 1)), "--duration", str(step["duration"]),
                "--size", str(s.get("size", 512)), "--start-at", str(start_at),
                "--stop-at", str(start_at + step["duration"] + scn.get("sender_linger", 30)),
            ]
            senders.append(spawn(argv, nodes_dir / f"{name}.log"))
        print(f"[{transport}] step {sid}: {len(senders)} senders, {step['duration']}s", flush=True)
        for p in senders:
            p.wait()
        end = time.time()
        scrape_fleet(out / "metrics", f"{sid}_post")
        manifest["steps"].append({"id": sid, "start": start_at, "send_end": start_at + step["duration"], "end": end, "spec": step})
        time.sleep(scn.get("step_gap", 5))

    time.sleep(scn.get("settle", 30))
    for p, _ in receivers:
        p.terminate()
    for p, _ in receivers:
        try:
            p.wait(timeout=60)
        except subprocess.TimeoutExpired:
            p.kill()
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--transports", default=None, help="override, e.g. tcp,quic")
    ap.add_argument("--base-port", type=int, default=62000)
    args = ap.parse_args()

    scn = yaml.safe_load(open(args.scenario))
    run_id = args.run_id or f"{scn['name']}-{time.strftime('%m%d%H%M%S')}"
    root = HERE / "runs" / run_id
    transports = args.transports.split(",") if args.transports else scn.get("transports", ["tcp", "quic"])
    ports = PortAlloc(args.base_port)
    # A scenario is either one case, or `cases` run one after another so that
    # no more than a handful of our clients share this host's IP at a time
    # (the fleet prunes beyond 5 connections per IP).
    cases = scn.get("cases") or [{"id": ""}]
    for case in cases:
        cscn = {k: v for k, v in scn.items() if k != "cases"}
        cscn.update({k: v for k, v in case.items() if k != "id"})
        croot = root / str(case["id"]) if case["id"] else root
        for transport in transports:
            out = run_transport(cscn, f"{run_id}{'-' + str(case['id']) if case['id'] else ''}", transport, croot, ports)
            subprocess.run([PY, str(HERE / "analyze.py"), str(out)], stdout=subprocess.DEVNULL)
            print(f"report: {out / 'report.md'}", flush=True)
    subprocess.run([PY, str(HERE / "summarize.py"), str(root)])
    print(f"done: {root}")


if __name__ == "__main__":
    main()
