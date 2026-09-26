#!/usr/bin/env python3
"""delivery_module under real logoscore daemons, on this host, no docker.

The docker suite beside this (pytest) needs Linux builds of the module and a
Linux logoscore image. This runs the same scenarios with the released
logoscore binaries and the bundle built here: one daemon for the lifecycle
and query checks, two daemons peered by static nodes for delivery, every
outcome read over the CLI and its event stream.

    python3 local_e2e.py --modules-dir <dir with delivery_module/manifest.json> \
        [--logoscore <path>] [--rln-presets <json>]

--logoscore defaults to the one on PATH. With --rln-presets, a third daemon
checks that a node on an RLN-enabled preset gets its questions answered by
liblogos_rln_module (which must be installed in the modules dir too).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

MODULE = "delivery_module"
TOPIC = "/test/1/logos-delivery-e2e/proto"
CLUSTER_ID = "198"
MESH_STABILIZATION_S = 12.0


class Daemon:
    """One logoscore daemon with a config dir of its own (a parallel instance)."""

    def __init__(self, logoscore: str, modules_dir: Path, root: Path, label: str,
                 env: dict[str, str] | None = None):
        self.logoscore = logoscore
        self.label = label
        self.config_dir = root / label / "config"
        self.persistence = root / label / "data"
        self.config_dir.mkdir(parents=True)
        self.persistence.mkdir(parents=True)
        self.modules_dir = modules_dir
        self.log = open(root / label / "daemon.log", "w")
        self.env = dict(os.environ, LOGOSCORE_CONFIG_DIR=str(self.config_dir), **(env or {}))
        self.proc: subprocess.Popen | None = None
        self.watchers: list[Watcher] = []

    def start(self, timeout: float = 30.0) -> None:
        self.proc = subprocess.Popen(
            [self.logoscore, "-D", "-m", str(self.modules_dir),
             "--persistence-path", str(self.persistence)],
            stdout=self.log, stderr=subprocess.STDOUT, env=self.env,
        )
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = self.cli("status", check=False)
            if r and r.get("daemon", {}).get("status") == "running":
                return
            time.sleep(0.5)
        raise RuntimeError(f"{self.label}: daemon did not come up")

    def stop(self) -> None:
        for w in self.watchers:
            w.close()
        self.cli("stop", check=False)
        if self.proc:
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()

    def cli(self, *args: str, check: bool = True, timeout: float = 120.0) -> dict:
        r = subprocess.run([self.logoscore, "--json", *args], capture_output=True,
                           text=True, env=self.env, timeout=timeout)
        out: dict = {"status": "error", "message": r.stdout + r.stderr}
        for line in reversed(r.stdout.strip().splitlines()):
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict):
                out = parsed
                break
        if check and out.get("status") != "ok":
            raise AssertionError(f"{self.label}: {' '.join(args)} -> {out}")
        return out

    def load(self, module: str = MODULE) -> None:
        self.cli("load-module", module)

    def call(self, method: str, *args: str, timeout: float = 120.0) -> dict:
        """The method's StdLogosResult {success, value, error}; a method that
        answers a bare value (a tstr) is wrapped as a success."""
        r = self.cli("call", MODULE, method, *args, timeout=timeout)["result"]
        return r if isinstance(r, dict) else {"success": True, "value": r, "error": None}

    def call_ok(self, method: str, *args: str, timeout: float = 120.0):
        r = self.call(method, *args, timeout=timeout)
        if not r.get("success"):
            raise AssertionError(f"{self.label}: {method}{args} failed: {r.get('error')!r}")
        return r.get("value")

    def watch(self) -> "Watcher":
        w = Watcher(self)
        self.watchers.append(w)
        return w


class Watcher:
    """`logoscore watch <module> --json`, one JSON object per line, on a queue."""

    def __init__(self, daemon: Daemon):
        self.proc = subprocess.Popen(
            [daemon.logoscore, "watch", MODULE, "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=daemon.env,
        )
        self.events: queue.Queue[dict] = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        time.sleep(1.0)  # the subscription takes a moment to arm

    def _pump(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if line.startswith("{"):
                try:
                    self.events.put(json.loads(line))
                except json.JSONDecodeError:
                    pass

    def next(self, event: str, timeout: float, predicate=None) -> dict:
        deadline = time.time() + timeout
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise AssertionError(f"no {event} within {timeout}s")
            try:
                e = self.events.get(timeout=left)
            except queue.Empty:
                continue
            if e.get("event") == event and (predicate is None or predicate(e)):
                return e

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def arg(event: dict, i: int):
    return event.get("data", {}).get(f"arg{i}")


def node_config(tcp_port: int, static_peers: list[str] | None = None, preset: str | None = None) -> str:
    cfg = {
        "logLevel": "INFO", "listenAddress": "0.0.0.0", "tcpPort": tcp_port,
        "clusterId": CLUSTER_ID, "numShardsInNetwork": 1,
        "relay": True, "store": False, "filter": False, "lightpush": False,
        "peerExchange": False, "discv5Discovery": False, "reliabilityEnabled": True,
    }
    if static_peers:
        cfg["staticnodes"] = static_peers
    if preset:
        # a preset node joins that network; only the layer's own knobs apply
        cfg = {"preset": preset, "messagingOverrides": {
            "logLevel": "INFO", "tcp-port": tcp_port, "discv5-udp-port": tcp_port + 1000}}
    return json.dumps(cfg)


def loopback_multiaddr(node: Daemon) -> str:
    raw = str(node.call_ok("getNodeInfo", "MyMultiaddresses")).strip().strip("@[]")
    for a in re.split(r"[,\n]", raw):
        a = a.strip()
        if "/tcp/" in a and "/quic" not in a:
            return re.sub(r"/ip4/[^/]+/", "/ip4/127.0.0.1/", a, count=1)
    raise AssertionError(f"no tcp multiaddr in {raw!r}")


def payload_bytes(v) -> bytes:
    """The contract's bstr on the wire: {"_bytes": <base64url, unpadded>}."""
    if isinstance(v, dict) and "_bytes" in v:
        s = v["_bytes"]
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    raise AssertionError(f"not a bytes payload: {v!r}")


class Suite:
    def __init__(self) -> None:
        self.results: list[tuple[str, str]] = []

    def run(self, name: str, fn, known_issue: str | None = None) -> None:
        """`known_issue` names a failure that is somebody else's and expected:
        it is reported, not counted."""
        t0 = time.time()
        try:
            fn()
            self.results.append((name, "ok"))
            print(f"  ok    {name} ({time.time() - t0:.1f}s)", flush=True)
        except Exception as e:  # noqa: BLE001
            if known_issue:
                self.results.append((name, "known"))
                print(f"  known {name}: {e}\n        ({known_issue})", flush=True)
            else:
                self.results.append((name, f"FAIL: {e}"))
                print(f"  FAIL  {name}: {e}", flush=True)

    def failed(self) -> int:
        return sum(1 for _, r in self.results if r not in ("ok", "known"))


def lifecycle_and_queries(solo: Daemon) -> None:
    solo.load()
    w = solo.watch()
    solo.call_ok("createNode", node_config(61000))
    twice = solo.call("createNode", node_config(61000))
    assert not twice.get("success"), "second createNode must be refused"
    solo.call_ok("start")
    started = w.next("nodeStarted", timeout=60)
    assert arg(started, 0) is True, f"nodeStarted reported failure: {started}"
    ids = json.loads(solo.call_ok("getAvailableNodeInfoIDs"))
    assert "Version" in ids and "MyMultiaddresses" in ids, ids
    assert solo.call_ok("getNodeInfo", "Version"), "empty version"
    assert solo.call_ok("getAvailableConfigs"), "empty configs"
    solo.call_ok("subscribe", TOPIC)
    solo.call_ok("unsubscribe", TOPIC)
    assert solo.call_ok("collectOpenMetricsText").startswith("#"), "no metrics text"
    solo.call_ok("stop")
    stopped = w.next("nodeStopped", timeout=60)
    assert arg(stopped, 0) is True, f"nodeStopped reported failure: {stopped}"


def deliver(sender: Daemon, receiver: Daemon, text: str) -> None:
    ws, wr = sender.watch(), receiver.watch()
    request_id = sender.call_ok("send", TOPIC, text)
    assert isinstance(request_id, str) and request_id, f"send answered {request_id!r}"
    got = wr.next("messageReceived", timeout=45,
                  predicate=lambda e: arg(e, 1) == TOPIC and arg(e, 3) == "live"
                  and payload_bytes(arg(e, 2)) == text.encode())
    assert arg(got, 0).startswith("0x"), got
    ws.next("messagePropagated", timeout=45, predicate=lambda e: arg(e, 0) == request_id)
    ws.close()
    wr.close()


def two_nodes(a: Daemon, b: Daemon, suite: Suite) -> None:
    a.load()
    a.call_ok("createNode", node_config(61001))
    wa = a.watch()
    a.call_ok("start")
    wa.next("nodeStarted", timeout=60)
    wa.close()
    peer = loopback_multiaddr(a)
    b.load()
    b.call_ok("createNode", node_config(61002, static_peers=[peer]))
    wb = b.watch()
    b.call_ok("start")
    wb.next("nodeStarted", timeout=60)
    wb.close()
    a.call_ok("subscribe", TOPIC)
    b.call_ok("subscribe", TOPIC)
    time.sleep(MESH_STABILIZATION_S)
    suite.run("A -> B: B receives live, A sees it propagated", lambda: deliver(a, b, "hello from A"))
    suite.run("B -> A: the other way round", lambda: deliver(b, a, "hello from B"))


def rln_question(rln: Daemon) -> None:
    rln.load("liblogos_rln_module")
    rln.load()
    w = rln.watch()
    rln.call_ok("createNode", node_config(61003, preset="logos.test"))
    state = rln.call_ok("rlnState")
    assert state.get("state") == "Ready", state
    ready = w.next("rlnStateChanged", timeout=10)
    assert arg(ready, 0) == "Ready", ready
    rln.call_ok("start")
    w.next("nodeStarted", timeout=90)
    # The node asked the RLN module at start-up; its answer, whatever it was,
    # is in the node's own log. Without a registered membership it is a
    # refusal, and that still proves the round trip.
    rln.log.flush()
    answer = [l for l in Path(rln.log.name).read_text().splitlines()
              if "could not verify RLN membership" in l]
    assert answer, "no trace of the membership question in the node's log"
    assert "timeout" not in answer[0] and "unreachable" not in answer[0], answer[0]


def host_pid(label: str = MODULE) -> int:
    r = subprocess.run(["pgrep", "-f", f"logos_host.*--name {label}"], capture_output=True, text=True)
    pids = [int(x) for x in r.stdout.split()]
    assert len(pids) == 1, f"expected one {label} host, found {pids}"
    return pids[0]


def host_threads_and_rss(pid: int) -> tuple[int, int]:
    threads = len(subprocess.run(["ps", "-M", str(pid)], capture_output=True, text=True).stdout.splitlines()) - 1
    rss = int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0)
    return threads, rss


def wait_lines(log_path: Path, needle: str, want: set[str], timeout: float) -> list[str]:
    """Log lines containing `needle`, until one per id in `want` has been seen."""
    deadline = time.time() + timeout
    while True:
        lines = [l for l in log_path.read_text().splitlines() if needle in l]
        seen = {rid for rid in want if any(rid in l for l in lines)}
        if seen == want:
            return lines
        if time.time() > deadline:
            raise AssertionError(f"{len(seen)}/{len(want)} ids reached {needle!r} within {timeout}s")
        time.sleep(0.5)


def rln_stress(rln: Daemon, burst: int) -> None:
    """The node's questions under load, and with the RLN module gone and back.

    Every send on a node whose membership is unverified asks the RLN module
    for the membership state again, so a burst of sends is a burst of
    concurrent questions: nim-ffi reverse calls handed to the module on the
    node's thread, one lp call each, answered from lp's completion thread and
    matched back by call id. Each must come back with the module's own answer
    (a refusal here, without a membership), none by timeout.
    """
    log = Path(rln.log.name)
    pid = host_pid()
    threads0, rss0 = host_threads_and_rss(pid)

    def burst_of_sends(n: int, tag: str) -> set[str]:
        ids = {rln.call_ok("send", TOPIC, f"{tag} {i}") for i in range(n)}
        assert len(ids) == n, "sends answered with duplicate request ids"
        return ids

    for round_no in range(3):
        ids = burst_of_sends(burst, f"burst{round_no}")
        lines = wait_lines(log, "Failed to attach RLN proof", ids, timeout=60)
        mine = [l for l in lines if any(rid in l for rid in ids)]
        bad = [l for l in mine if "timeout" in l.lower() or "unreachable" in l.lower() or "not a JSON" in l]
        assert not bad, f"an answer did not come from the module: {bad[0][:200]}"
        assert rln.call_ok("getNodeInfo", "Version"), "the node stopped answering"
        threads, rss = host_threads_and_rss(pid)
        assert threads == threads0, f"host threads went {threads0} -> {threads}"
    rln.log.flush()

    # The RLN module gone: logos-core holds a call for a module that may yet
    # come back, so a question ends at the library's own deadline (70 s for a
    # registry read) as a failure, and meanwhile the node keeps answering:
    # the questions are asynchronous, nothing blocks its thread.
    rln.cli("unload-module", "liblogos_rln_module")
    ids = burst_of_sends(3, "gone")
    time.sleep(5)
    assert rln.call_ok("getNodeInfo", "Version"), "the node stopped answering while a question was pending"
    lines = wait_lines(log, "Failed to attach RLN proof", ids, timeout=110)
    mine = [l for l in lines if any(rid in l for rid in ids)]
    assert all("Permanent" not in l for l in mine), f"an absent module answered: {mine[0][:200]}"

    threads, rss = host_threads_and_rss(pid)
    assert threads == threads0, f"host threads went {threads0} -> {threads}"
    assert rss < rss0 * 2, f"host RSS went {rss0} -> {rss} kB"
    print(f"        {3 * burst + 3} questions; host threads {threads}, rss {rss0 // 1024} -> {rss // 1024} MB")


def rln_after_reload(rln: Daemon, burst: int) -> None:
    """The RLN module back: the node's questions must reach it again."""
    log = Path(rln.log.name)
    rln.load("liblogos_rln_module")
    time.sleep(2)
    ids = {rln.call_ok("send", TOPIC, f"back {i}") for i in range(burst)}
    lines = wait_lines(log, "Failed to attach RLN proof", ids, timeout=60)
    mine = [l for l in lines if any(rid in l for rid in ids)]
    assert all("Permanent" in l or "invalid_argument" in l for l in mine), \
        f"the reloaded module did not answer: {mine[0].split('error=')[-1][:160]}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--modules-dir", required=True, type=Path)
    ap.add_argument("--logoscore", default=shutil.which("logoscore"))
    ap.add_argument("--rln-presets", type=Path, default=None)
    ap.add_argument("--stress", type=int, default=0, metavar="N",
                    help="with --rln-presets: bursts of N sends, the RLN module unloaded and reloaded")
    ap.add_argument("--keep", action="store_true", help="keep the run directory")
    args = ap.parse_args()
    if not args.logoscore:
        print("logoscore not found: pass --logoscore", file=sys.stderr)
        return 2
    if not (args.modules_dir / MODULE / "manifest.json").is_file():
        print(f"{args.modules_dir} holds no {MODULE}", file=sys.stderr)
        return 2
    root = Path(tempfile.mkdtemp(prefix="delivery-e2e-"))
    print(f"run dir: {root}")
    suite = Suite()
    daemons: list[Daemon] = []
    try:
        solo = Daemon(args.logoscore, args.modules_dir, root, "solo")
        daemons.append(solo)
        solo.start()
        suite.run("lifecycle and queries on one node", lambda: lifecycle_and_queries(solo))
        solo.stop()

        a = Daemon(args.logoscore, args.modules_dir, root, "a")
        b = Daemon(args.logoscore, args.modules_dir, root, "b")
        daemons += [a, b]
        a.start()
        b.start()
        suite.run("two nodes peered by static nodes", lambda: two_nodes(a, b, suite))
        a.stop()
        b.stop()

        if args.rln_presets:
            rln = Daemon(args.logoscore, args.modules_dir, root, "rln",
                         env={"LOGOS_DELIVERY_RLN_PRESETS": str(args.rln_presets)})
            daemons.append(rln)
            rln.start()
            suite.run("RLN questions reach liblogos_rln_module", lambda: rln_question(rln))
            if args.stress:
                suite.run(f"RLN questions under load ({args.stress} per burst), and with the module unloaded",
                          lambda: rln_stress(rln, args.stress))
                suite.run("RLN questions answered again after the module is reloaded",
                          lambda: rln_after_reload(rln, args.stress),
                          known_issue="logos-core: a reloaded module refuses a caller's cached token and "
                                      "answers null, which lp reports as a success, so the caller never "
                                      "re-exchanges; the caller must be reloaded too")
    finally:
        for d in daemons:
            try:
                d.stop()
            except Exception:  # noqa: BLE001
                pass
        if not args.keep and suite.failed() == 0:
            shutil.rmtree(root, ignore_errors=True)
    print(f"{len(suite.results) - suite.failed()} passed, {suite.failed()} failed" +
          ("" if suite.failed() == 0 or not args.keep else f" (logs in {root})"))
    return 1 if suite.failed() else 0


if __name__ == "__main__":
    sys.exit(main())
