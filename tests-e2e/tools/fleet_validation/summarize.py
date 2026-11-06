"""Roll every <case>/<transport>/summary.json under a run root into SUMMARY.md."""

import json
import sys
from pathlib import Path


def fmt_ms(v):
    return "-" if v is None else f"{v * 1000:.0f}"


def main():
    root = Path(sys.argv[1])
    L = [f"# {root.name}", "", "| case | transport | step | spec | from | to | expected | lost | loss % | history | dups | p50/p99 ms | send err | no terminal | sent p99 ms | fleet max loop lag s | fleet max cpu s | coloc prunes |", "|" + "---|" * 18]
    for summary in sorted(root.rglob("summary.json")):
        run_dir = summary.parent
        data = json.loads(summary.read_text())
        manifest = json.loads((run_dir / "manifest.json").read_text())
        case = run_dir.parent.name if run_dir.parent != root else "-"
        specs = {st["id"]: st["spec"] for st in manifest["steps"]}
        send = {(r["step"], r["group"]): r for r in data["send"]}
        fleet = {}
        for r in data["fleet"]:
            f = fleet.setdefault(r["step"], {"lag": 0, "cpu": 0, "prunes": 0})
            f["lag"] = max(f["lag"], r["logos_delivery_event_loop_accumulated_lag_secs_total"])
            f["cpu"] = max(f["cpu"], r["process_cpu_seconds_total"])
            f["prunes"] += r.get("colocation_prunes", 0)
        for r in data["delivery"]:
            s = send.get((r["step"], r["from"]), {})
            spec = specs.get(r["step"], {})
            snd = (spec.get("senders") or [{}])[0]
            spec_txt = f"{snd.get('rate', 1)}/s x {snd.get('size', 512)}B x {spec.get('duration')}s"
            f = fleet.get(r["step"], {})
            L.append(
                f"| {case} | {manifest['transport']} | {r['step']} | {spec_txt} | {r['from']} | {r['to']} | {r['expected']} | {r['lost']} | "
                f"{r['loss_pct']:.2f} | {r['history']} | {r['dups']} | {fmt_ms(r['lat_p50'])}/{fmt_ms(r['lat_p99'])} | "
                f"{s.get('call_err', 0) + s.get('error', 0)} | {s.get('no_terminal', 0)} | {fmt_ms(s.get('sent_p99'))} | "
                f"{f.get('lag', 0):.2f} | {f.get('cpu', 0):.1f} | {f.get('prunes', 0)} |"
            )
    fatal = [str(p.parent) for p in root.rglob("summary.json") if json.loads(p.read_text()).get("fatal")]
    if fatal:
        L += ["", f"Runs with fatal client errors: {fatal}"]
    (root / "SUMMARY.md").write_text("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
