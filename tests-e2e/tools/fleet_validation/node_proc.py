"""One liblogosdelivery client node (sender or receiver) pinned to one fleet DC.

Every observation is appended as one JSON line to --out, stamped with the local
wall clock, so analyze.py can join senders and receivers running on this host.
"""

import argparse
import base64
import json
import os
import signal
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "vendor" / "logos-delivery-python-bindings"))
sys.path.insert(0, str(HERE))

from waku.wrapper import NodeWrapper, _event_callback, lib  # noqa: E402

import fleet  # noqa: E402

# The preset-driven wrapper appends override entry nodes to the preset's six,
# which defeats per-DC pinning, so this mirrors logos.dev without the preset.
LOGOS_DEV_BASE = {
    "cluster-id": 3,
    "num-shards-in-network": fleet.NUM_SHARDS,
    "max-msg-size": "150KiB",
    "reliability": True,
    "discv5-discovery": False,
    "enable-kad-discovery": False,
    "nat": "none",
}


class Recorder:
    def __init__(self, path: str):
        self._f = open(path, "a", buffering=1)
        self._lock = threading.Lock()

    def write(self, kind: str, **fields):
        line = json.dumps({"t": time.time(), "k": kind, **fields}, separators=(",", ":"))
        with self._lock:
            self._f.write(line + "\n")

    def close(self):
        with self._lock:
            self._f.close()


def build_config(args) -> dict:
    overrides = dict(LOGOS_DEV_BASE)
    overrides.update(
        {
            "entry-node": fleet.entry_nodes(args.dc, args.transport),
            "tcp-port": args.port,
            "discv5-udp-port": args.port + 1,
            "quic-support": args.transport == "quic",
            "quic-port": args.port,
        }
    )
    return {"mode": args.mode, "messagingOverrides": overrides}


def make_payload(args, seq: int) -> str:
    body = {"r": args.run_id, "s": args.name, "st": args.step, "q": seq, "ts": time.time()}
    raw = json.dumps(body, separators=(",", ":"))
    if args.size > len(raw):
        body["p"] = "x" * (args.size - len(raw) - 7)
        raw = json.dumps(body, separators=(",", ":"))
    return base64.b64encode(raw.encode()).decode()


def on_event(rec: Recorder, connected: threading.Event):
    def cb(ret, raw):
        try:
            ev = json.loads(raw)
        except Exception:
            rec.write("event_raw", ret=ret, raw=raw[:500].decode(errors="replace"))
            return
        et = ev.get("eventType")
        if et == "message_received":
            msg = ev.get("message", {})
            try:
                body = json.loads(base64.b64decode(msg.get("payload", "")))
                body.pop("p", None)
            except Exception:
                body = None
            rec.write(
                "recv",
                hash=ev.get("messageHash"),
                source=ev.get("source"),
                topic=msg.get("contentTopic"),
                body=body,
            )
            return
        if et == "connection_status_change" and ev.get("connectionStatus") in (
            "Connected",
            "PartiallyConnected",
        ):
            connected.set()
        rec.write("event", ev=ev)

    return cb


def add_queued_listener(node, cb_handle):
    # The vendored wrapper does not listen to onMessageQueued.
    return lib.logosdelivery_add_event_listener(
        node.ctx, b"onMessageQueued", _event_callback, cb_handle
    )


def peers_snapshot(node, rec: Recorder):
    res = node.get_node_info("Metrics")
    if res.is_err():
        rec.write("peers", err=res.err())
        return
    wanted = ("libp2p_peers ", "libp2p_open_streams", "logos_delivery_connected_peers", "libp2p_gossipsub_peers_per_topic_mesh")
    lines = [l for l in res.ok_value.splitlines() if l.startswith(wanted)]
    rec.write("peers", metrics=lines)


def run_sender(node, args, rec: Recorder, stop: threading.Event):
    topics = args.topics.split(",")
    start_at = args.start_at or time.time()
    total = int(args.rate * args.duration)
    rec.write("send_plan", total=total, rate=args.rate, start_at=start_at, topics=topics)
    for seq in range(total):
        due = start_at + seq / args.rate
        delay = due - time.time()
        if delay > 0 and stop.wait(delay):
            break
        if stop.is_set():
            break
        topic = topics[seq % len(topics)]
        t0 = time.time()
        res = node.send_message(
            {"contentTopic": topic, "payload": make_payload(args, seq), "ephemeral": False}
        )
        t1 = time.time()
        if res.is_ok():
            rec.write("send", q=seq, topic=topic, rid=res.ok_value, t0=t0, lag=t0 - due, call=t1 - t0)
        else:
            rec.write("send", q=seq, topic=topic, err=res.err(), t0=t0, lag=t0 - due, call=t1 - t0)
    rec.write("send_done")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--step", default="0")
    ap.add_argument("--role", choices=("sender", "receiver"), required=True)
    ap.add_argument("--mode", choices=("Edge", "Core"), required=True)
    ap.add_argument("--dc", choices=tuple(fleet.FLEET), required=True)
    ap.add_argument("--transport", choices=("tcp", "quic"), default="tcp")
    ap.add_argument("--topics", required=True, help="comma-separated content topics")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rate", type=float, default=1.0, help="sender msgs/s")
    ap.add_argument("--duration", type=float, default=60.0, help="sender seconds")
    ap.add_argument("--size", type=int, default=512, help="payload bytes")
    ap.add_argument("--start-at", type=float, default=0.0, help="sender epoch start")
    ap.add_argument("--stop-at", type=float, default=0.0, help="receiver epoch stop")
    ap.add_argument("--connect-timeout", type=float, default=60.0)
    args = ap.parse_args()

    rec = Recorder(args.out)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    config = build_config(args)
    rec.write("config", args=vars(args), config=config, pid=os.getpid())

    connected = threading.Event()
    cb = on_event(rec, connected)
    t0 = time.time()
    res = NodeWrapper.create_and_start(config, cb, timeout_s=60)
    if res.is_err():
        rec.write("fatal", stage="start", err=res.err())
        rec.close()
        sys.exit(2)
    node = res.ok_value
    add_queued_listener(node, node._event_cb_handler)
    info = {i: node.get_node_info(i) for i in ("MyPeerId", "Version")}
    rec.write("started", secs=time.time() - t0, **{i: r.ok_value if r.is_ok() else None for i, r in info.items()})

    if not connected.wait(args.connect_timeout):
        rec.write("warn", msg="no Connected status within timeout")
    rec.write("connected", secs=time.time() - t0)

    if args.role == "receiver":
        for topic in args.topics.split(","):
            sub = node.subscribe_content_topic(topic)
            rec.write("subscribe", topic=topic, ok=sub.is_ok(), err=None if sub.is_ok() else sub.err())
    rec.write("ready")
    peers_snapshot(node, rec)

    poller_stop = threading.Event()

    def poll_peers():
        while not poller_stop.wait(15):
            peers_snapshot(node, rec)

    threading.Thread(target=poll_peers, daemon=True).start()

    if args.role == "sender":
        run_sender(node, args, rec, stop)
    # Senders linger so propagated/sent events for the tail still arrive;
    # receivers stay until the orchestrator's stop time.
    end = args.stop_at or (time.time() + 30)
    stop.wait(max(0.0, end - time.time()))

    poller_stop.set()
    peers_snapshot(node, rec)
    res = node.stop_and_destroy(timeout_s=30)
    rec.write("stopped", ok=res.is_ok())
    rec.close()


if __name__ == "__main__":
    main()
