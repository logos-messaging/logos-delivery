#!/usr/bin/env python3
"""Fails when a Prometheus metric label may take an unbounded set of values.

Every label value passed to a metric (`m.inc/dec/set/observe`, via
`labelValues = [..]` or a trailing positional list) must be a string literal,
an `if c: "a" else: "b"` of literals, or a `const` string. Anything else
creates one time series per distinct value, which Prometheus cannot handle.

Checks:
  1. unbounded:  non-literal, non-const label value. Bounded-but-unprovable
                 ones (enum conversions, ...) go in
                 scripts/metric_labels_allowlist.txt as `<file>::<expr>`.
  2. tainted:    value that visibly carries free-form text (`error`, `.msg`,
                 `getCurrentExceptionMsg`, peer ids, addresses, ...) or an
                 identifier bound to such text (`let x = "..." & y`). Never
                 allowlistable; waive one use with `# bounded-label: <why>` on
                 the call line, inside the call or on the line above.
  3. arity:      number of values differs from the declared label names.
  4. declared:   label names that look unbounded (`peer_id`, `addr`, ...).

The allowlist only shrinks: a new offender fails, and so does a stale entry.

    scripts/check_metric_labels.py [--update]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "metric_labels_allowlist.txt"
SCAN = ["logos_delivery", "apps", "library"]
WAIVER = "bounded-label:"

STR = r'(?:"[^"\\]*"|r"[^"]*")'
LITERAL_RE = re.compile(rf"^(?:{STR}|if .+?: {STR} else: {STR})$")
IDENT_RE = re.compile(r"^[A-Za-z_]\w*$")
CALL_RE = re.compile(r"(\w+)\s*\.\s*(?:inc|dec|set|observe)\s*\(")
DECL_RE = re.compile(
    r"declare(?:Public)?(?:Counter|Gauge|Histogram|Summary)\s+(\w+)\s*,(.*?)(?=\n\S|\Z)",
    re.S,
)
CONST_ITEM_RE = re.compile(rf"^[ \t]+(\w+)\*?\s*=\s*{STR}", re.M)
CONST_ONE_RE = re.compile(rf"^const\s+(\w+)\*?\s*=\s*{STR}", re.M)
TAINT_RE = re.compile(
    r"(?i)(\berror\b|\berr\w*\b|\.msg\b|\bmsg\b|getCurrentExceptionMsg|peerid|\bpeer\b|"
    r"\baddrs?\b|multiaddr|\bip\b|\bhash\b|\bagent\b|\.\$|\bdiagnostic\b)"
)
BOUND_RHS_TAINT = re.compile(r"&|getCurrentExceptionMsg|\.error\b|\.msg\b|\berror\b")
BAD_LABEL_NAME = re.compile(r"(?i)peer_?id|addr|ip|hash|msg|message|error_?msg|url|path|id$")


def nim_files():
    for d in SCAN:
        yield from sorted((ROOT / d).rglob("*.nim"))


def string_consts(texts):
    names = set()
    for text in texts.values():
        names.update(CONST_ONE_RE.findall(text))
        for m in re.finditer(r"^const\s*\n((?:[ \t]+.*\n?)+)", text, re.M):
            names.update(CONST_ITEM_RE.findall(m.group(1)))
    return names


def balanced(text, i):
    """Content of the paren group whose '(' sits just before index i."""
    depth, j = 1, i
    while j < len(text) and depth:
        c = text[j]
        depth += c in "([{"
        depth -= c in ")]}"
        j += 1
    return text[i : j - 1]


def split_top(s):
    out, depth, cur, instr = [], 0, "", False
    for c in s:
        if c == '"':
            instr = not instr
        if not instr:
            depth += c in "([{"
            depth -= c in ")]}"
            if c == "," and depth == 0:
                out.append(cur)
                cur = ""
                continue
        cur += c
    out.append(cur)
    return [" ".join(a.split()) for a in out if a.strip()]


def label_list(args):
    for a in split_top(args):
        m = re.match(r"^labelValues\s*=\s*\[(.*)\]$", a, re.S)
        if m:
            return split_top(m.group(1))
    parts = split_top(args)
    if len(parts) >= 2 and parts[-1].startswith("[") and parts[-1].endswith("]"):
        return split_top(parts[-1][1:-1])
    return None


def declarations(texts):
    decls = {}
    for rel, text in texts.items():
        for m in DECL_RE.finditer(text):
            lm = re.search(r"(?:labels\s*=\s*)?\[([^\[\]]*)\]\s*(?:,|$)", m.group(2), re.S)
            tail = m.group(2)
            lm = re.search(r"(?:labels\s*=\s*)?\[([^\[\]]*)\]\s*$", tail.strip(), re.S)
            if lm and '"' in lm.group(1) and "buckets" not in tail.split("[")[0]:
                decls[m.group(1)] = (rel, re.findall(r'"([^"]*)"', lm.group(1)))
    return decls


def tainted_binding(text, pos, ident):
    """True if `ident` was last bound before `pos` to a non-literal expression."""
    window = text[max(0, pos - 4000) : pos]
    last = None
    for m in re.finditer(rf"\b(?:let|var)\s+{re.escape(ident)}\b[^=\n]*=\s*(.*)", window):
        last = m
    if not last:
        return False
    rhs = last.group(1)
    start = window.rfind("\n", 0, last.start()) + 1
    indent = last.start() - start
    for line in window[last.end() :].split("\n")[1:]:
        if line.strip() and len(line) - len(line.lstrip()) > indent:
            rhs += " " + line.strip()
        elif line.strip():
            break
    rhs = re.sub(STR, '""', rhs)
    return bool(BOUND_RHS_TAINT.search(rhs))


WHY = {
    "tainted": (
        "This label value carries free-form text (an error, message, peer id, "
        "address, ...). Every distinct value becomes a new Prometheus time series, "
        "so it grows without bound.",
        "Replace it with a fixed set of values (a const or a literal, e.g. "
        '"dial_failure") and log the detail instead. If it is provably bounded, '
        "add `# bounded-label: <why>` on the call line or the line above it.",
    ),
    "unbounded": (
        "This label value is not a string literal or a `const`, so the linter "
        "cannot prove it takes a bounded set of values.",
        "Use a literal/const. If it is bounded (e.g. an enum), add "
        "`# bounded-label: <why>` on the call line or the line above it; "
        "`scripts/check_metric_labels.py --update` is only for existing code.",
    ),
    "arity": (
        "The number of label values differs from the labels the metric declares.",
        "Pass exactly one value per declared label.",
    ),
    "name": (
        "A declared label name suggests an unbounded dimension.",
        "Use a bounded dimension, or drop the label.",
    ),
    "stale": (
        "scripts/metric_labels_allowlist.txt lists an expression that no longer "
        "offends (it was fixed or removed).",
        "Delete the entry, or run `scripts/check_metric_labels.py --update`.",
    ),
}
ORDER = ["tainted", "unbounded", "arity", "name", "stale"]
TITLE = {
    "tainted": "free-form text used as a metric label",
    "unbounded": "metric label not provably bounded",
    "arity": "metric label count mismatch",
    "name": "suspicious metric label name",
    "stale": "stale allowlist entries",
}


def analyse(texts, consts, decls):
    """Returns findings as (kind, location, detail, allowlist_key|None)."""
    out = []
    for rel, text in texts.items():
        lines = text.splitlines()
        for m in CALL_RE.finditer(text):
            raw = balanced(text, m.end())
            call_line = text.count("\n", 0, m.start())
            waived = (
                WAIVER in raw
                or WAIVER in lines[call_line]
                or (call_line > 0 and WAIVER in lines[call_line - 1])
            )
            args = re.sub(r"[ \t]#[^\n\"]*(?=\n|$)", "", raw)
            labels = label_list(args)
            if labels is None:
                continue
            loc = f"{rel}:{call_line + 1}"
            name = m.group(1)
            if name in decls and len(decls[name][1]) != len(labels) and not waived:
                out.append(
                    (
                        "arity",
                        loc,
                        f"`{name}` declares {len(decls[name][1])} label(s) "
                        f"{decls[name][1]}, call passes {len(labels)}",
                        None,
                    )
                )
            for expr in labels:
                if LITERAL_RE.match(expr) or (IDENT_RE.match(expr) and expr in consts):
                    continue
                if waived:
                    continue
                bad = TAINT_RE.search(expr) or (
                    IDENT_RE.match(expr) and tainted_binding(text, m.start(), expr)
                )
                kind = "tainted" if bad else "unbounded"
                out.append(
                    (kind, loc, f"`{name}` label value `{expr}`", f"{rel}::{expr}")
                )
    return out


def main():
    texts = {
        f.relative_to(ROOT).as_posix(): f.read_text(errors="replace") for f in nim_files()
    }
    consts = string_consts(texts)
    decls = declarations(texts)
    found = analyse(texts, consts, decls)
    for m, (rel, names) in sorted(decls.items()):
        for n in names:
            if BAD_LABEL_NAME.search(n):
                found.append(("name", rel, f"`{m}` declares label `{n}`", None))

    keys = {k for kind, _, _, k in found if kind == "unbounded"}
    if "--update" in sys.argv:
        ALLOWLIST.write_text("".join(f"{e}\n" for e in sorted(keys)))
    allowed = (
        {l.strip() for l in ALLOWLIST.read_text().splitlines() if l.strip()}
        if ALLOWLIST.exists()
        else set()
    )
    # allowlisted `unbounded` findings are accepted; tainted ones never are
    findings = [f for f in found if not (f[0] == "unbounded" and f[3] in allowed)]
    for e in sorted(allowed - keys):
        findings.append(("stale", "scripts/metric_labels_allowlist.txt", e, None))

    if not findings:
        print("metric labels: all label values are bounded")
        return 0
    for kind in ORDER:
        group = [f for f in findings if f[0] == kind]
        if not group:
            continue
        why, fix = WHY[kind]
        print(f"\n== {TITLE[kind]} ({len(group)})")
        print(f"   why: {why}")
        print(f"   fix: {fix}")
        for _, loc, detail, _k in sorted(set((f[0], f[1], f[2], f[3]) for f in group)):
            print(f"  {loc}: {detail}")
    print(f"\nmetric labels: {len(findings)} problem(s) found")
    return 1


if __name__ == "__main__":
    sys.exit(main())
