#!/usr/bin/env bash
# Repo-specific Windows gate: liblogosdelivery.dll still exports the public C
# ABI its consumers bind by name.
#
# HOW IT IS RUN
#   logos-co/logos-windows-ci calls this through `extra-gates:` from the repo
#   root, after the standard gates, with `stage/` present and $OBJDUMP pointing
#   at the mingw objdump that action already proved can read pei-x86-64.
#
# BY HAND
#   OBJDUMP=x86_64-w64-mingw32-objdump DLL=result/bin/liblogosdelivery.dll \
#     bash .github/gates/exported-c-abi.sh
#
# WHY IT EXISTS
#   liblogosdelivery's C ABI is consumed by name from another repo
#   (logos-delivery-module, via generated/logosdelivery.h). When v0.2.0 moved
#   that ABI, nothing on either side noticed at build time: the DLL built, the
#   module built against the header it had, and the mismatch first surfaced as a
#   twenty-second timeout inside a running application.
#
#   A name list is NOT a signature check and does not pretend to be one -- an
#   argument that changes type still slips through. What it buys is that
#   REMOVING or RENAMING a public entry point becomes a red diff in this repo,
#   on the platform where the failure is least legible, instead of a runtime
#   symptom in someone else's.
set -euo pipefail

DLL="${DLL:-stage/liblogosdelivery/bin/liblogosdelivery.dll}"
OBJDUMP="${OBJDUMP:-x86_64-w64-mingw32-objdump}"

# The public entry points, as consumed by logos-delivery-module/src. Keep this
# list in step with generated/logosdelivery.h -- that is the point of it.
REQUIRED=(
  logosdelivery_create_node
  logosdelivery_start_node
  logosdelivery_stop_node
  logosdelivery_destroy
  logosdelivery_get_node_info
  logosdelivery_get_available_node_info_ids
  logosdelivery_get_available_configs
  logosdelivery_send
  logosdelivery_subscribe
  logosdelivery_unsubscribe
  logosdelivery_channel_create
  logosdelivery_channel_close
  logosdelivery_channel_exists
  logosdelivery_channel_send
  logosdelivery_add_event_listener
  logosdelivery_remove_event_listener
)

if ! command -v "$OBJDUMP" >/dev/null 2>&1 && [ ! -x "$OBJDUMP" ]; then
  # windows-ci guards this before calling us; the check is for the by-hand path,
  # where `nix build …binutils | head -1` happily hands over the -man output and
  # the failure would otherwise be a bare 127 from the capture below.
  echo "::error::OBJDUMP=$OBJDUMP is not an executable."
  exit 1
fi

if [ ! -f "$DLL" ]; then
  echo "::error::$DLL is not in the staged tree."
  echo "::error::staged targets: $(find stage -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
                                     | sed 's|^stage/||' | sort | tr '\n' ' ')"
  exit 1
fi

# Captured, then parsed. `objdump -p | awk` is a producer piped into a consumer,
# and this table is ~2000 lines: under `set -o pipefail` an early-exiting reader
# would promote SIGPIPE (141) to the pipeline's status and fail a perfectly good
# DLL. Capturing also makes objdump's own failure a failure here, rather than
# "no exports found".
dump=$("$OBJDUMP" -p "$DLL")

# objdump prints the export names under a header line, one per line, as
#     [Ordinal/Name Pointer] Table -- Ordinal Base 1
#               Ordinal   Hint Name
#     [   0] +base[   1]  0000 logosdelivery_add_event_listener
# so the name is the last field of every `+base[` row in that section.
exports=$(printf '%s\n' "$dump" \
  | awk '/^\[Ordinal\/Name Pointer\] Table/ {f=1; next}
         f && NF == 0                      {f=0}
         f && /\+base\[/                   {print $NF}')

# A reader that parsed nothing reports the same thing as a DLL that exports
# nothing, and both would make the loop below fail with a misleading message.
n=$(printf '%s\n' "$exports" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  echo "::error::parsed 0 export names out of $OBJDUMP -p $DLL."
  echo "::error::That is a fact about this gate's reader, not about the DLL."
  printf '%s\n' "$dump" | sed -n '1,40p' | sed 's/^/::error::  /'
  exit 1
fi
echo "$DLL exports $n names"

missing=""
for sym in "${REQUIRED[@]}"; do
  grep -qxF "$sym" <<<"$exports" || missing="$missing $sym"
done

if [ -n "$missing" ]; then
  echo "::error::liblogosdelivery.dll no longer exports:$missing"
  echo "::error::These are bound by name from logos-delivery-module. If the ABI"
  echo "::error::change is intentional, update this list AND the consumers in the"
  echo "::error::same train -- that is what this gate is for."
  echo "::error::--- what it does export ($n names) ---"
  # `sed -n '1,Np'` rather than `head -N`: head exits early, and under
  # `set -o pipefail` the SIGPIPE would abort this step BEFORE the `exit 1`
  # below that explains the actual problem.
  printf '%s\n' "$exports" | sort | sed -n '1,60p' | sed 's/^/::error::  /'
  exit 1
fi

echo "public C ABI intact: ${#REQUIRED[@]} required exports present"
