#!/usr/bin/env bash
# Hack for libp2p 2.2 + older libp2p_mix: restore removed modules as shims.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LP=$(ls -dt "$ROOT"/nimbledeps/pkgs2/libp2p-2.2.* 2>/dev/null | head -1)
if [ -z "${LP:-}" ] || [ ! -d "$LP/libp2p" ]; then
  echo "libp2p 2.2 package not found under nimbledeps/pkgs2" >&2
  exit 1
fi
cat > "$LP/libp2p/utility.nim" <<'NIM'
# Shim: libp2p/utility removed in nim-libp2p 2.x; needed by current libp2p_mix pin.
import ./utils/[opt, shortlog, collections]
export opt, shortlog, collections
NIM
cat > "$LP/libp2p/utils/sequninit.nim" <<'NIM'
# Shim: libp2p/utils/sequninit removed; newSeqUninit lives in system.
export system
NIM
echo "Applied libp2p 2.2 shims in $LP"
