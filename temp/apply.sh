#!/bin/bash
# Apply vendor patches for QUIC support.
# Run from the logos-delivery root directory:
#   bash temp/apply.sh
#
# This copies patched files from temp/vendor/ on top of vendor/.
# Run this AFTER `make update` to re-apply patches over fresh vendor state.
#
# nim-libp2p patches:
#   - quictransport.nim: getStreams, remote-close propagation, session.closed guard
#   - muxer.nim: base getStreams returns @[] instead of raising
#   - switch.nim: imports quictransport for vtable registration
#
# nim-lsquic patches:
#   - stream.nim: doProcess() on immediate write path (fixes stalled sends)
#   - context/context.nim: nil guard in makeStream
#   - context/client.nim: nil lsquicConn on connection close (prevents dangling pointer)
#   - context/server.nim: nil lsquicConn on connection close (prevents dangling pointer)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Applying nim-libp2p QUIC patches from $SCRIPT_DIR/vendor/ to $ROOT_DIR/vendor/"

find "$SCRIPT_DIR/vendor" -type f | while read src; do
    dst="$ROOT_DIR/${src#$SCRIPT_DIR/}"
    if [ -f "$dst" ]; then
        cp "$src" "$dst"
        echo "  patched: ${dst#$ROOT_DIR/}"
    else
        echo "  WARNING: target not found: ${dst#$ROOT_DIR/}"
    fi
done

echo "Done. Now rebuild: make wakunode2"
