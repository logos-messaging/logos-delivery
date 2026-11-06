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
                 allowlistable; waive one line with `# bounded-label: <why>`.
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


def analyse(texts, consts, decls):
    unbounded, tainted, arity = set(), [], []
    for rel, text in texts.items():
        lines = text.splitlines()
        for m in CALL_RE.finditer(text):
            raw = balanced(text, m.end())
            waived = WAIVER in raw or WAIVER in lines[
                text.count("\n", 0, m.start())
            ]
            args = re.sub(r"[ \t]#[^\n\"]*(?=\n|$)", "", raw)
            labels = label_list(args)
            if labels is None:
                continue
            line_no = text.count("\n", 0, m.start()) + 1
            name = m.group(1)
            if name in decls and len(decls[name][1]) != len(labels) and not waived:
                arity.append(
                    f"{rel}:{line_no}: {name} declares {len(decls[name][1])} "
                    f"label(s), got {len(labels)}"
                )
            for expr in labels:
                if LITERAL_RE.match(expr) or (IDENT_RE.match(expr) and expr in consts):
                    continue
                if waived:
                    continue
                bad = TAINT_RE.search(expr) or (
                    IDENT_RE.match(expr) and tainted_binding(text, m.start(), expr)
                )
                if bad:
                    tainted.append(f"{rel}:{line_no}: {name}: {expr}")
                else:
                    unbounded.add(f"{rel}::{expr}")
    return unbounded, tainted, arity


def main():
    texts = {
        f.relative_to(ROOT).as_posix(): f.read_text(errors="replace") for f in nim_files()
    }
    consts = string_consts(texts)
    decls = declarations(texts)
    unbounded, tainted, arity = analyse(texts, consts, decls)
    badnames = [
        f"{rel}: {m}: label name `{n}` looks unbounded"
        for m, (rel, names) in sorted(decls.items())
        for n in names
        if BAD_LABEL_NAME.search(n)
    ]

    if "--update" in sys.argv:
        ALLOWLIST.write_text("".join(f"{e}\n" for e in sorted(unbounded)))
    allowed = (
        {l.strip() for l in ALLOWLIST.read_text().splitlines() if l.strip()}
        if ALLOWLIST.exists()
        else set()
    )
    new, stale = sorted(unbounded - allowed), sorted(allowed - unbounded)
    for e in tainted:
        print(f"tainted metric label: {e}")
    for e in arity:
        print(f"label arity mismatch: {e}")
    for e in badnames:
        print(f"suspicious label name: {e}")
    for e in new:
        print(f"unbounded metric label: {e}")
    for e in stale:
        print(f"stale allowlist entry (remove it): {e}")
    failed = bool(tainted or arity or badnames or new or stale)
    if failed:
        print(
            "\nMetric label values must be string literals or consts: every "
            "distinct value becomes a new time series.\nMap free-form values "
            "(errors, peer ids, addresses) to a fixed set and log them instead; "
            "waive a proven-bounded use with `# bounded-label: <why>`."
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
