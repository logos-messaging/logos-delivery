#!/usr/bin/env python3
"""Fails when behavioural nim-libp2p modules are imported outside the backend.

logos-delivery talks to libp2p through the interfaces in
logos_delivery/waku/libp2p_iface; only logos_delivery/waku/libp2p_backend may
import the modules that implement behaviour (switch, streams, protocols,
transports, ...). Modules that only define plain value types shared by the whole
code base (peer ids, multiaddresses, keys, ...) are exempt, see VALUE_TYPES.

Files that still import a behavioural module are listed in
scripts/libp2p_imports_allowlist.txt. The list only shrinks: a new offender
fails the check, and so does a listed file that no longer offends.

    scripts/check_libp2p_imports.py [--update]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "libp2p_imports_allowlist.txt"
SCAN = ["logos_delivery", "apps", "library"]
BACKEND = ("logos_delivery/waku/libp2p_backend/", "logos_delivery/waku/libp2p_iface/")

# libp2p modules (path prefixes under `libp2p/`) that only provide value types
VALUE_TYPES = (
    "peerid",
    "multiaddress",
    "multihash",
    "multicodec",
    "multibase",
    "cid",
    "varint",
    "vbuffer",
    "crypto/",
    "peerinfo",
    "signed_envelope",
    "routing_record",
    "errors",
    "utils/",
    "protobuf/minprotobuf",
    "protocols/pubsub/timedcache",
    "wire",
    "nameresolving/nameresolver",
)

IMPORT_RE = re.compile(r"libp2p/(\[[^\]]*\]|[A-Za-z0-9_/]+)")


def modules(text: str):
    """Yields every `libp2p/<module>` referenced by an import-like line."""
    for line in text.splitlines():
        code = line.split("#", 1)[0]
        for m in IMPORT_RE.finditer(code):
            # skip URLs and prose such as github.com/libp2p/...
            if m.start() > 0 and code[m.start() - 1] not in " \t,[":
                continue
            spec = m.group(1)
            if spec.startswith("["):
                for part in spec.strip("[]").split(","):
                    part = part.strip().split(" ")[0]
                    if part:
                        yield part
            else:
                yield spec


def is_value_type(module: str) -> bool:
    return any(
        module == v or (v.endswith("/") and module.startswith(v)) for v in VALUE_TYPES
    )


def offenders():
    found = {}
    for top in SCAN:
        for path in sorted((ROOT / top).rglob("*.nim")):
            rel = path.relative_to(ROOT).as_posix()
            if rel.startswith(BACKEND):
                continue
            bad = sorted(
                {m for m in modules(path.read_text()) if not is_value_type(m)}
            )
            if bad:
                found[rel] = bad
    return found


def main() -> int:
    found = offenders()
    if "--update" in sys.argv:
        ALLOWLIST.write_text(
            "# Files that still import behavioural nim-libp2p modules.\n"
            "# This list only shrinks, see scripts/check_libp2p_imports.py.\n"
            + "".join(f"{f}\n" for f in found)
        )
        print(f"wrote {len(found)} entries to {ALLOWLIST.relative_to(ROOT)}")
        return 0

    allowed = {
        l.strip()
        for l in ALLOWLIST.read_text().splitlines()
        if l.strip() and not l.startswith("#")
    }
    new = sorted(set(found) - allowed)
    stale = sorted(allowed - set(found))
    for f in new:
        print(f"new libp2p import outside the backend: {f}: {', '.join(found[f])}")
    for f in stale:
        print(f"{f} no longer imports libp2p behaviour, remove it from the allow-list")
    if new:
        print("Use the interfaces in logos_delivery/waku/libp2p_iface instead.")
    if new or stale:
        return 1
    print(f"libp2p imports confined: {len(found)} allow-listed files remain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
