#!/usr/bin/env bash
#
# sync-nimble-lock.sh
#
# Cross-check git-URL pinned `requires` in logos_delivery.nimble against nimble.lock and
# sync the lock entry for any pin that CHANGED relative to a git base ref
# (default: HEAD) -- and ONLY those entries. No other package is touched.
#
# It does NOT run `nimble lock` (which rewrites the whole file and churns
# unrelated packages). Instead it computes the package sha1 checksum itself,
# reproducing nimble's algorithm exactly (src/nimblepkg/checksums.nim):
#
#   files   = `git ls-files` in the package's git checkout at the pinned rev
#   files.sort()                       # lexicographic
#   sha1 = SHA1 over, for each existing regular file (in sorted order):
#            update(relative_path_string)
#            if symlink: update(symlink_target_string)
#            else:       update(file_bytes)          # 8192-byte chunks
#
# For each changed pin it updates exactly three fields of the matching lock
# entry, preserving all formatting and every other entry byte-for-byte:
#   version      = "#" + <rev-as-written-in-logos_delivery.nimble>   (commit or tag)
#   vcsRevision  = git rev-parse of the ref                 (resolves tags)
#   checksums.sha1 = the self-computed checksum
#
# The `dependencies` array is intentionally left untouched (see NOTE below).
#
# Usage:
#   tools/sync-nimble-lock.sh                       # dry-run; exit 1 if drift
#   tools/sync-nimble-lock.sh --apply               # update nimble.lock
#   tools/sync-nimble-lock.sh --base origin/master  # compare against a ref
#
# Exit codes: 0 = in sync / applied, 1 = drift (dry-run), 2 = usage/tooling error
#
# Portable across macOS (bash 3.2, BSD tools) and Linux: all logic is in
# python3; bash only parses args and checks tools. Requires: git, python3.
#
# NOTE on `dependencies`: a version bump can in principle change a package's
# direct dependency set. Reproducing nimble's dependency-name normalization
# without running nimble is fragile, and the user-requested scope is
# version/vcsRevision/sha1. If a bumped dependency added/removed a `requires`,
# update its lock `dependencies` array by hand. The script warns when the
# bumped package's own .nimble `requires` count differs from the lock entry.

set -euo pipefail

APPLY=0
BASE="HEAD"

usage() { sed -n '2,55p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    --base)    shift; [ $# -gt 0 ] || { echo "error: --base needs a ref" >&2; exit 2; }; BASE="$1" ;;
    --base=*)  BASE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not in a git repo" >&2; exit 2; }

export SYNC_ROOT="$ROOT" SYNC_APPLY="$APPLY" SYNC_BASE="$BASE" SYNC_PKGCACHE="${HOME}/.nimble/pkgcache"

exec python3 - <<'PYEOF'
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.environ["SYNC_ROOT"]
APPLY = os.environ["SYNC_APPLY"] == "1"
BASE = os.environ["SYNC_BASE"]
PKGCACHE = os.environ["SYNC_PKGCACHE"]

NIMBLE_FILE = os.path.join(ROOT, "logos_delivery.nimble")
LOCK_FILE = os.path.join(ROOT, "nimble.lock")

REQ_RE = re.compile(r'requires\s+"(https?://[^"#]+)#([^"]+)"')
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
NEAR_HASH_RE = re.compile(r"^[0-9a-fx]{38,42}$")  # catches the leading-`x` typo


def fail(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(2)


def warn(msg):
    sys.stderr.write("warning: %s\n" % msg)


def norm_url(url):
    u = url.rstrip("/")
    return u[:-4] if u.endswith(".git") else u


def git(args, cwd=None, check=True):
    r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        fail("git %s failed: %s" % (" ".join(args), (r.stderr or r.stdout).strip()))
    return r


# ---------------------------------------------------------------------------
# nimble checksum reproduction (verified byte-for-byte against nimble v0.22.3)
# ---------------------------------------------------------------------------
def compute_checksum(checkout_dir):
    out = git(["-C", checkout_dir, "ls-files"]).stdout
    files = out.strip().splitlines()
    files.sort()
    h = hashlib.sha1()
    for rel in files:
        path = os.path.join(checkout_dir, rel)
        if not os.path.isfile(path):
            # Skips directories / gitlinks / broken symlinks, matching nimble's
            # `fileExists` guard (regular file or symlink-to-file only).
            continue
        h.update(rel.encode("utf-8"))
        if os.path.islink(path):
            h.update(os.readlink(path).encode("utf-8"))
        else:
            with open(path, "rb") as fh:
                while True:
                    chunk = fh.read(8192)
                    if not chunk:
                        break
                    h.update(chunk)
    return h.hexdigest()


def get_checkout(url, rev, tmpdir):
    """Return (checkout_dir, cleanup_fn). Reuses ~/.nimble/pkgcache when the
    exact commit is already cloned; otherwise clones from the URL."""
    # pkgcache dirs are suffixed with the commit sha (commit pins only).
    if os.path.isdir(PKGCACHE):
        for name in os.listdir(PKGCACHE):
            if name.endswith("_" + rev) and os.path.isdir(os.path.join(PKGCACHE, name, ".git")):
                cache = os.path.join(PKGCACHE, name)
                git(["-C", cache, "checkout", "-q", rev])
                return cache, (lambda: None)
    # Fall back to a fresh clone (network). Full clone, then checkout the ref.
    dest = os.path.join(tmpdir, "clone")
    print("  cloning %s ..." % url)
    git(["clone", "--quiet", url, dest])
    r = git(["-C", dest, "checkout", "-q", rev], check=False)
    if r.returncode != 0:
        # commit may live on a ref not fetched by default; try fetching it
        git(["-C", dest, "fetch", "--quiet", "origin", rev], check=False)
        git(["-C", dest, "checkout", "-q", rev])
    return dest, (lambda: shutil.rmtree(dest, ignore_errors=True))


def dep_requires_count(checkout_dir):
    """Best-effort count of git/registry `requires` in the dep's .nimble file,
    for a heads-up if the lock `dependencies` array may be stale."""
    nimbles = [f for f in os.listdir(checkout_dir) if f.endswith(".nimble")]
    if not nimbles:
        return None
    try:
        txt = open(os.path.join(checkout_dir, nimbles[0])).read()
    except OSError:
        return None
    n = 0
    for m in re.finditer(r'requires\s+"([^"]+)"', txt):
        n += len([p for p in m.group(1).split(",") if p.strip()])
    return n or None


# ---------------------------------------------------------------------------
# detect changes
# ---------------------------------------------------------------------------
def parse_changed(base):
    r = git(["-C", ROOT, "diff", base, "--", "logos_delivery.nimble"], check=False)
    if r.returncode != 0:
        fail("git diff against %r failed: %s" % (base, r.stderr.strip()))
    changed, seen = [], set()
    for line in r.stdout.splitlines():
        if not line.startswith("+") or line.startswith("+++"):
            continue
        m = REQ_RE.search(line[1:])
        if not m:
            continue
        url, rev = m.group(1), m.group(2)
        key = norm_url(url)
        if key in seen:
            continue
        seen.add(key)
        if not COMMIT_RE.match(rev) and NEAR_HASH_RE.match(rev):
            fail("invalid commit hash for %s: %r is not a valid 40-char hex SHA "
                 "(stray character / typo?)" % (url, rev))
        changed.append((url, rev))
    return changed


# ---------------------------------------------------------------------------
# surgical lock patch (text-level: preserves formatting & all other entries)
# ---------------------------------------------------------------------------
PKG_OPEN_RE = re.compile(r'^\s{4}"[^"]+":\s*\{\s*$')
PKG_CLOSE_RE = re.compile(r'^\s{4}\},?\s*$')


def set_value(line, key, val):
    return re.sub(r'(^\s*"' + re.escape(key) + r'":\s*")[^"]*(")',
                  lambda m: m.group(1) + val + m.group(2), line, count=1)


def patch_lock_text(text, url, version, vcs_rev, sha1):
    lines = text.splitlines(keepends=True)
    url_re = re.compile(r'^\s*"url":\s*"' + re.escape(url) + r'"\s*,?\s*$')
    ui = next((i for i, l in enumerate(lines) if url_re.match(l)), None)
    if ui is None:
        return None
    # block bounds
    start = next(i for i in range(ui, -1, -1) if PKG_OPEN_RE.match(lines[i]))
    end = next(i for i in range(ui, len(lines)) if PKG_CLOSE_RE.match(lines[i]))
    done = set()
    for i in range(start, end + 1):
        if "version" not in done and re.match(r'^\s*"version":', lines[i]):
            lines[i] = set_value(lines[i], "version", version); done.add("version")
        elif "vcsRevision" not in done and re.match(r'^\s*"vcsRevision":', lines[i]):
            lines[i] = set_value(lines[i], "vcsRevision", vcs_rev); done.add("vcsRevision")
        elif "sha1" not in done and re.match(r'^\s*"sha1":', lines[i]):
            lines[i] = set_value(lines[i], "sha1", sha1); done.add("sha1")
    missing = {"version", "vcsRevision", "sha1"} - done
    if missing:
        fail("could not locate field(s) %s in lock block for %s" % (sorted(missing), url))
    return "".join(lines)


# ---------------------------------------------------------------------------
def main():
    for p in (NIMBLE_FILE, LOCK_FILE):
        if not os.path.isfile(p):
            fail("%s not found" % p)

    changed = parse_changed(BASE)
    if not changed:
        print("No changed git-URL `requires` in logos_delivery.nimble vs %s — nothing to sync." % BASE)
        return 0

    lock = json.load(open(LOCK_FILE))
    by_url = {}
    for name, e in lock.get("packages", {}).items():
        if e.get("url"):
            by_url[norm_url(e["url"])] = (name, e)

    drift = []  # (url, rev, name_or_None, cur_version_or_None)
    for url, rev in changed:
        hit = by_url.get(norm_url(url))
        want = "#" + rev
        if hit is None:
            drift.append((url, rev, None, None))
        elif hit[1].get("version") != want:
            drift.append((url, rev, hit[0], hit[1].get("version")))

    if not drift:
        print("nimble.lock already in sync with logos_delivery.nimble (%d changed pin(s) checked)." % len(changed))
        return 0

    print("Dependency drift (logos_delivery.nimble vs nimble.lock):")
    for url, rev, name, cur in drift:
        tag = name or "(missing)"
        print("  ~ %s [%s]\n      logos_delivery.nimble: #%s\n      nimble.lock: %s" % (url, tag, rev, cur))

    if not APPLY:
        print("\nRun with --apply to update nimble.lock (computes checksum itself; no `nimble lock`).")
        return 1

    print("\nApplying (computing checksums; not running `nimble lock`)...")
    text = open(LOCK_FILE).read()
    updated = []
    tmproot = tempfile.mkdtemp(prefix="sync-nimble-lock.")
    try:
        for url, rev, name, _cur in drift:
            if name is None:
                fail("%s has no entry in nimble.lock; this script updates existing "
                     "entries only (add new deps with a normal nimble install first)." % url)
            sub = os.path.join(tmproot, re.sub(r"\W+", "_", norm_url(url)))
            os.makedirs(sub, exist_ok=True)
            checkout, cleanup = get_checkout(url, rev, sub)
            try:
                vcs_rev = git(["-C", checkout, "rev-parse", "HEAD"]).stdout.strip()
                sha1 = compute_checksum(checkout)
                # dependency-drift heads-up
                cnt = dep_requires_count(checkout)
                lock_deps = len(by_url[norm_url(url)][1].get("dependencies", []))
                if cnt is not None and lock_deps and cnt != lock_deps:
                    warn("%s: .nimble has %d `requires` but lock lists %d dependencies; "
                         "review the `dependencies` array manually." % (name, cnt, lock_deps))
            finally:
                cleanup()
            new_text = patch_lock_text(text, url, "#" + rev, vcs_rev, sha1)
            if new_text is None:
                fail("could not find lock block for url %s" % url)
            text = new_text
            updated.append((name, "#" + rev, vcs_rev, sha1))
    finally:
        shutil.rmtree(tmproot, ignore_errors=True)

    with open(LOCK_FILE, "w") as f:
        f.write(text)

    print("\nUpdated nimble.lock (only these entries; all others untouched):")
    for name, ver, vcs, sha1 in updated:
        print("  %-16s version=%s" % (name, ver))
        print("  %-16s vcsRevision=%s" % ("", vcs))
        print("  %-16s sha1=%s" % ("", sha1))
    return 0


sys.exit(main())
PYEOF
