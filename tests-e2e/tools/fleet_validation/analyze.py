"""Summarise one transport run directory into report.md + summary.json.

Loss is judged per (sender group -> receiver group) pair: every message whose
send call succeeded is expected at every receiver, since receivers subscribe to
all of the run's topics.
"""

import json
import re
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import fleet

HERE = Path(__file__).resolve().parent

FLEET_COUNTERS = [
    "logos_delivery_node_messages_total",
    "logos_delivery_lightpush_v3_messages_total",
    "logos_delivery_lightpush_v3_errors_total",
    "logos_delivery_filter_requests_total",
    "logos_delivery_archive_inserts_total",
    "logos_delivery_archive_errors_total",
    "logos_delivery_node_errors_total",
    "logos_delivery_event_loop_accumulated_lag_secs_total",
    "process_cpu_seconds_total",
]
FLEET_GAUGES = ["logos_delivery_filter_subscriptions", "libp2p_peers", "process_resident_memory_bytes"]
LOG_TS = re.compile(r"^(\S+) ")


def pct(values, p):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p / 100 * (len(values) - 1))))]


def fmt_ms(v):
    return "-" if v is None else f"{v * 1000:.0f}"


def load_nodes(nodes_dir: Path):
    nodes = {}
    for f in sorted(nodes_dir.glob("*.jsonl")):
        recs = [json.loads(l) for l in f.open() if l.strip()]
        cfg = next((r for r in recs if r["k"] == "config"), None)
        if cfg:
            nodes[cfg["args"]["name"]] = {"args": cfg["args"], "recs": recs}
    return nodes


def group(args):
    return f"{args['mode']}-{args['dc']}"


def sender_stats(nodes):
    sends = {}  # (sender, q) -> info
    by_step_group = defaultdict(lambda: defaultdict(list))
    for name, n in nodes.items():
        a = n["args"]
        if a["role"] != "sender":
            continue
        rid_events = defaultdict(dict)
        for r in n["recs"]:
            if r["k"] == "event":
                ev = r["ev"]
                et = ev.get("eventType", "")
                if et.startswith("message_") and "requestId" in ev:
                    rid_events[ev["requestId"]].setdefault(et, (r["t"], ev.get("error")))
        for r in n["recs"]:
            if r["k"] != "send":
                continue
            evs = rid_events.get(r.get("rid"), {})
            info = {"t0": r["t0"], "ok": "rid" in r, "err": r.get("err"), "lag": r["lag"], "evs": evs, "step": a["step"], "group": group(a)}
            sends[(name, r["q"])] = info
            by_step_group[a["step"]][group(a)].append(info)
    rows = []
    for step, groups in sorted(by_step_group.items()):
        for g, infos in sorted(groups.items()):
            ok = [i for i in infos if i["ok"]]
            prop = [i["evs"]["message_propagated"][0] - i["t0"] for i in ok if "message_propagated" in i["evs"]]
            sent = [i["evs"]["message_sent"][0] - i["t0"] for i in ok if "message_sent" in i["evs"]]
            errs = [i["evs"]["message_error"][1] for i in ok if "message_error" in i["evs"]]
            queued = sum(1 for i in ok if "message_queued" in i["evs"])
            no_terminal = sum(1 for i in ok if not ({"message_sent", "message_error"} & set(i["evs"])))
            err_kinds = defaultdict(int)
            for e in errs + [i["err"] for i in infos if not i["ok"]]:
                err_kinds[str(e)[:80]] += 1
            rows.append({
                "step": step, "group": g, "attempted": len(infos), "call_err": len(infos) - len(ok),
                "propagated": len(prop), "sent": len(sent), "error": len(errs), "queued": queued,
                "no_terminal": no_terminal,
                "prop_p50": pct(prop, 50), "prop_p99": pct(prop, 99),
                "sent_p50": pct(sent, 50), "sent_p99": pct(sent, 99),
                "max_lag": max((i["lag"] for i in infos), default=0), "errors": dict(err_kinds),
            })
    return sends, rows


def delivery_stats(nodes, sends):
    receivers = {n: v for n, v in nodes.items() if v["args"]["role"] == "receiver"}
    pair = defaultdict(lambda: {"expected": 0, "live": 0, "history": 0, "lat": [], "dups": 0})
    lost_samples = defaultdict(list)
    for rname, r in receivers.items():
        rg = group(r["args"])
        got = {}
        hashes = defaultdict(int)
        for rec in r["recs"]:
            if rec["k"] != "recv" or not rec.get("body"):
                continue
            hashes[rec["hash"]] += 1
            key = (rec["body"]["s"], rec["body"]["q"])
            if key not in got:
                got[key] = (rec["t"], rec["source"], rec["body"]["ts"])
        dup_by_sender = defaultdict(int)
        for rec in r["recs"]:
            if rec["k"] == "recv" and rec.get("body") and hashes[rec["hash"]] > 1:
                dup_by_sender[rec["body"]["s"]] += 1
        for (sname, q), info in sends.items():
            if not info["ok"]:
                continue
            p = pair[(info["step"], info["group"], rg)]
            p["expected"] += 1
            hit = got.get((sname, q))
            if hit is None:
                if len(lost_samples[(info["step"], info["group"], rg)]) < 5:
                    lost_samples[(info["step"], info["group"], rg)].append(f"{sname}#{q}->{rname}")
                continue
            if hit[1] == "live":
                p["live"] += 1
                p["lat"].append(hit[0] - hit[2])
            else:
                p["history"] += 1
        for sname, d in dup_by_sender.items():
            step = sname.rsplit("-st", 1)[-1]
            sg = sname.split("-st")[0].split("-", 1)[1].rsplit("-", 1)[0]
            pair[(step, sg, rg)]["dups"] += d
    rows = []
    for (step, sg, rg), p in sorted(pair.items()):
        lost = p["expected"] - p["live"] - p["history"]
        rows.append({
            "step": step, "from": sg, "to": rg, "expected": p["expected"], "live": p["live"],
            "history": p["history"], "lost": lost, "loss_pct": 100 * lost / p["expected"] if p["expected"] else 0,
            "dups": p["dups"], "lat_p50": pct(p["lat"], 50), "lat_p95": pct(p["lat"], 95), "lat_p99": pct(p["lat"], 99),
            "lost_samples": lost_samples.get((step, sg, rg), []),
        })
    return rows


def parse_prom(path: Path):
    vals = defaultdict(float)
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        try:
            vals[name] += float(line.rsplit(" ", 1)[1])
        except ValueError:
            pass
    return vals


def fleet_stats(run_dir: Path, steps):
    rows = []
    for st in steps:
        for host in fleet.METRICS_PORTS:
            pre, post = (run_dir / "metrics" / f"{st['id']}_{s}__{host}.prom" for s in ("pre", "post"))
            if not (pre.exists() and post.exists()):
                continue
            a, b = parse_prom(pre), parse_prom(post)
            row = {"step": st["id"], "host": host.split(".logos")[0]}
            for c in FLEET_COUNTERS:
                row[c] = b.get(c, 0) - a.get(c, 0)
            for g in FLEET_GAUGES:
                row[g] = b.get(g, 0)
            row.update(fleet_log_counts(host, st["start"] - 5, st["end"]))
            rows.append(row)
    return rows


def fleet_log_counts(host: str, t_from: float, t_to: float):
    path = HERE / "fleet-logs" / f"{host}.log"
    counts = {"log_WRN": 0, "log_ERR": 0, "colocation_prunes": 0}
    if not path.exists():
        return counts
    for line in path.open(errors="replace"):
        prune = "due to ip colocation" in line
        if not prune and "] WRN " not in line and "] ERR " not in line:
            continue
        m = LOG_TS.match(line)
        try:
            ts = datetime.fromisoformat(m.group(1)).timestamp() if m else None
        except ValueError:
            ts = None
        if ts is None or not (t_from <= ts <= t_to):
            continue
        counts["colocation_prunes" if prune else "log_WRN" if "] WRN " in line else "log_ERR"] += 1
    return counts


def write_report(run_dir: Path, manifest, send_rows, deliv_rows, fleet_rows):
    L = [f"# {manifest['run_id']} / {manifest['transport']}", ""]
    if manifest.get("receivers_not_ready"):
        L += [f"Receivers not ready: {manifest['receivers_not_ready']}", ""]
    L += ["## Send side", "", "| step | sender | attempted | call_err | propagated | sent | error | queued | no_terminal | prop p50/p99 ms | sent p50/p99 ms | max lag s |", "|" + "---|" * 12]
    for r in send_rows:
        L.append(f"| {r['step']} | {r['group']} | {r['attempted']} | {r['call_err']} | {r['propagated']} | {r['sent']} | {r['error']} | {r['queued']} | {r['no_terminal']} | {fmt_ms(r['prop_p50'])}/{fmt_ms(r['prop_p99'])} | {fmt_ms(r['sent_p50'])}/{fmt_ms(r['sent_p99'])} | {r['max_lag']:.2f} |")
    errs = [(r["step"], r["group"], r["errors"]) for r in send_rows if r["errors"]]
    if errs:
        L += ["", "Send errors:"] + [f"- step {s} {g}: {e}" for s, g, e in errs]
    L += ["", "## Delivery", "", "| step | from | to | expected | live | history | lost | loss % | dups | latency p50/p95/p99 ms |", "|" + "---|" * 10]
    for r in deliv_rows:
        L.append(f"| {r['step']} | {r['from']} | {r['to']} | {r['expected']} | {r['live']} | {r['history']} | {r['lost']} | {r['loss_pct']:.2f} | {r['dups']} | {fmt_ms(r['lat_p50'])}/{fmt_ms(r['lat_p95'])}/{fmt_ms(r['lat_p99'])} |")
    samples = [(r["step"], r["from"], r["to"], r["lost_samples"]) for r in deliv_rows if r["lost_samples"]]
    if samples:
        L += ["", "Lost samples:"] + [f"- step {s} {a}->{b}: {x}" for s, a, b, x in samples]
    L += ["", "## Fleet (per step deltas)", "", "| step | node | relay msgs | lightpush | lp err | filter req | store inserts | store err | node err | loop lag s | cpu s | filter subs | peers | RSS MB | log WRN | log ERR | coloc prunes |", "|" + "---|" * 17]
    for r in fleet_rows:
        L.append(
            f"| {r['step']} | {r['host']} | {r['logos_delivery_node_messages_total']:.0f} | {r['logos_delivery_lightpush_v3_messages_total']:.0f} | "
            f"{r['logos_delivery_lightpush_v3_errors_total']:.0f} | {r['logos_delivery_filter_requests_total']:.0f} | {r['logos_delivery_archive_inserts_total']:.0f} | "
            f"{r['logos_delivery_archive_errors_total']:.0f} | {r['logos_delivery_node_errors_total']:.0f} | {r['logos_delivery_event_loop_accumulated_lag_secs_total']:.2f} | "
            f"{r['process_cpu_seconds_total']:.1f} | {r['logos_delivery_filter_subscriptions']:.0f} | {r['libp2p_peers']:.0f} | {r['process_resident_memory_bytes'] / 1e6:.0f} | {r['log_WRN']} | {r['log_ERR']} | {r['colocation_prunes']} |"
        )
    (run_dir / "report.md").write_text("\n".join(L) + "\n")
    return "\n".join(L)


def main():
    run_dir = Path(sys.argv[1])
    manifest = json.loads((run_dir / "manifest.json").read_text())
    nodes = load_nodes(run_dir / "nodes")
    sends, send_rows = sender_stats(nodes)
    deliv_rows = delivery_stats(nodes, sends)
    fleet_rows = fleet_stats(run_dir, manifest["steps"])
    fatal = {n: r["err"] for n, v in nodes.items() for r in v["recs"] if r["k"] == "fatal"}
    (run_dir / "summary.json").write_text(json.dumps({"send": send_rows, "delivery": deliv_rows, "fleet": fleet_rows, "fatal": fatal}, indent=1, default=str))
    print(write_report(run_dir, manifest, send_rows, deliv_rows, fleet_rows))
    if fatal:
        print("FATAL:", fatal)


if __name__ == "__main__":
    main()
