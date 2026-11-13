#!/usr/bin/env python3
"""Fails when a Prometheus metric label may take an unbounded set of values.

Every label value passed to a metric (`m.inc/dec/set/observe`, via
`labelValues = [..]` or a trailing positional list) must be a string literal,
an `if c: "a" else: "b"` of literals, a `const` string, a call to a helper in
LABEL_FUNCS, or a `let` bound to such a call. Each helper maps its input to a
fixed set of values (see logos_delivery/waku/waku_core/metric_labels.nim).
Anything else creates one time series per distinct value, which Prometheus
cannot handle. There is no allowlist and no waiver.

Checks:
  1. unbounded:  label value that is none of the above.
  2. tainted:    same, and it visibly carries free-form text (`error`, `.msg`,
                 peer ids, addresses, ...).
  3. labels:     a labelled metric called without a literal list of values.
  4. arity:      number of values differs from the declared label names.
  5. declared:   label names that look unbounded (`peer_id`, `addr`, ...).
  6. helper:     a LABEL_FUNCS name not defined exactly once, so a lookalike
                 cannot pass as a reviewed helper.

    scripts/check_metric_labels.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN = ["logos_delivery", "apps", "library", "examples", "tools"]

STR = r'(?:"[^"\\]*"|r"[^"]*")'
LITERAL_RE = re.compile(rf"^(?:{STR}|if .+?: {STR} else: {STR})$")
IDENT_RE = re.compile(r"^[A-Za-z_]\w*$")
LABEL_FUNCS = [
    "agentLabel",
    "codecLabel",
    "enumLabel",
    "dialSourceLabel",
    "clusterLabel",
    "topicLabel",
    "shardLabel",
    "shardIdLabel",
    "statusLabel",
    "convertQueryToMetricLabel",
    "stmtLabel",
    "countryLabel",
    "peerIndexLabel",
]
LABEL_CALL_RE = re.compile(rf"^(?:[\w.]+\.)?(?:{'|'.join(LABEL_FUNCS)})\(")
HELPER_DEF_RE = re.compile(rf"^(?:func|proc)\s+({'|'.join(LABEL_FUNCS)})\*?\s*[\[(]", re.M)
CALL_RE = re.compile(r"(\w+)\s*\.\s*(?:inc|dec|set|observe)\s*\(")
DECL_RE = re.compile(
    r"declare(?:Public)?(?:Counter|Gauge|Histogram|Summary)\s+(\w+)\s*,(.*?)(?=\n\S|\Z)",
    re.S,
)
CONST_ITEM_RE = re.compile(rf"^[ \t]+(\w+)\*?\s*=\s*{STR}", re.M)
CONST_ONE_RE = re.compile(rf"^const\s+(\w+)\*?\s*(?:\{{\.[^}}]*\.\}}\s*)?=\s*{STR}", re.M)
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
            tail = m.group(2)
            # `labels = [..]` may come before `buckets = [..]`; else a trailing list
            lm = re.search(r"\blabels\s*=\s*\[([^\[\]]*)\]", tail) or re.search(
                r"\[([^\[\]]*)\]\s*$", tail.strip()
            )
            if lm and '"' in lm.group(1):
                decls[m.group(1)] = (rel, re.findall(r'"([^"]*)"', lm.group(1)))
    return decls


def is_label_call(expr):
    """True if the whole `expr` is one call to a LABEL_FUNCS helper."""
    m = LABEL_CALL_RE.match(expr)
    if not m:
        return False
    args = balanced(expr, m.end())
    return m.end() + len(args) + 1 == len(expr)


def binding_rhs(text, pos, ident, kinds="let|var"):
    """The expression `ident` was last bound to before `pos`, or None.

    With kinds="let" a later `var` or assignment rebinding yields None."""
    window = text[max(0, pos - 4000) : pos]
    last = None
    for m in re.finditer(rf"\b(let|var)\s+{re.escape(ident)}\b[^=\n]*=\s*(.*)", window):
        last = m
    if not last or not re.fullmatch(kinds, last.group(1)):
        return None
    if re.search(rf"^\s*{re.escape(ident)}\s*=[^=]", window[last.end() :], re.M):
        return None
    rhs = last.group(2)
    start = window.rfind("\n", 0, last.start()) + 1
    indent = last.start() - start
    for line in window[last.end() :].split("\n")[1:]:
        if line.strip() and len(line) - len(line.lstrip()) > indent:
            rhs += " " + line.strip()
        elif line.strip():
            break
    return " ".join(rhs.split())


def tainted_binding(text, pos, ident):
    """True if `ident` was last bound before `pos` to free-form text."""
    rhs = binding_rhs(text, pos, ident)
    return rhs is not None and bool(BOUND_RHS_TAINT.search(re.sub(STR, '""', rhs)))


WHY = {
    "tainted": (
        "This label value carries free-form text (an error, message, peer id, "
        "address, ...). Every distinct value becomes a new Prometheus time series, "
        "so it grows without bound.",
        "Replace it with a fixed set of values (a const or a literal, e.g. "
        '"dial_failure") and log the detail instead.',
    ),
    "unbounded": (
        "This label value is not a literal, a `const` or a label helper call, so "
        "nothing proves it takes a fixed set of values.",
        "Use a literal/const, or map it with a helper from "
        "logos_delivery/waku/waku_core/metric_labels.nim (`enumLabel` for an "
        "enum). A new helper must return only values of a fixed set and be "
        "added to LABEL_FUNCS in this script.",
    ),
    "labels": (
        "A labelled metric is called without a literal list of label values, so "
        "they cannot be checked.",
        "Pass `labelValues = [..]` with one checked value per label.",
    ),
    "helper": (
        "A label helper must be defined exactly once, or a lookalike would pass "
        "as a reviewed one.",
        "Rename the other definition, or update LABEL_FUNCS.",
    ),
    "arity": (
        "The number of label values differs from the labels the metric declares.",
        "Pass exactly one value per declared label.",
    ),
    "name": (
        "A declared label name suggests an unbounded dimension.",
        "Use a bounded dimension, or drop the label.",
    ),
}
ORDER = ["tainted", "unbounded", "labels", "arity", "name", "helper"]
TITLE = {
    "tainted": "free-form text used as a metric label",
    "unbounded": "metric label not provably bounded",
    "labels": "metric label values not checkable",
    "arity": "metric label count mismatch",
    "name": "suspicious metric label name",
    "helper": "label helper not defined exactly once",
}


def bounded(expr, text, pos, consts):
    return bool(
        LITERAL_RE.match(expr)
        or is_label_call(expr)
        or (IDENT_RE.match(expr) and expr in consts)
        or (
            IDENT_RE.match(expr)
            and is_label_call(binding_rhs(text, pos, expr, kinds="let") or "")
        )
    )


def analyse(texts, consts, decls):
    """Returns findings as (kind, location, detail)."""
    out = []
    for rel, text in texts.items():
        for m in CALL_RE.finditer(text):
            args = re.sub(r"[ \t]#[^\n\"]*(?=\n|$)", "", balanced(text, m.end()))
            loc = f"{rel}:{text.count(chr(10), 0, m.start()) + 1}"
            name = m.group(1)
            labels = label_list(args)
            if labels is None:
                if name in decls:
                    out.append(("labels", loc, f"`{name}` called with `{' '.join(args.split())}`"))
                continue
            if name in decls and len(decls[name][1]) != len(labels):
                out.append(
                    (
                        "arity",
                        loc,
                        f"`{name}` declares {len(decls[name][1])} label(s) "
                        f"{decls[name][1]}, call passes {len(labels)}",
                    )
                )
            for expr in labels:
                if bounded(expr, text, m.start(), consts):
                    continue
                bad = TAINT_RE.search(expr) or (
                    IDENT_RE.match(expr) and tainted_binding(text, m.start(), expr)
                )
                out.append(
                    ("tainted" if bad else "unbounded", loc, f"`{name}` label value `{expr}`")
                )
    return out


def helper_definitions(texts):
    out = []
    defs = {}
    for rel, text in texts.items():
        for m in HELPER_DEF_RE.finditer(text):
            defs.setdefault(m.group(1), []).append(rel)
    for fn in LABEL_FUNCS:
        where = defs.get(fn, [])
        if len(where) != 1:
            out.append(("helper", ", ".join(where) or "-", f"`{fn}` defined {len(where)} times"))
    return out


def main():
    texts = {
        f.relative_to(ROOT).as_posix(): f.read_text(errors="replace") for f in nim_files()
    }
    consts = string_consts(texts)
    decls = declarations(texts)
    findings = analyse(texts, consts, decls) + helper_definitions(texts)
    for m, (rel, names) in sorted(decls.items()):
        for n in names:
            if BAD_LABEL_NAME.search(n):
                findings.append(("name", rel, f"`{m}` declares label `{n}`"))

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
        for _, loc, detail in sorted(set(group)):
            print(f"  {loc}: {detail}")
    print(f"\nmetric labels: {len(findings)} problem(s) found")
    return 1


if __name__ == "__main__":
    sys.exit(main())
