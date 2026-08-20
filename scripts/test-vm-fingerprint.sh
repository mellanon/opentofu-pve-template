#!/usr/bin/env bash
# Prove the fingerprint comparator can go red, without needing a VM.
#
# A detector nobody has watched fail is a detector nobody should trust. This
# injects known faults into a synthetic capture and asserts each one lands in
# the right half of the split:
#
#   a changed package version   -> CORE moves, PROVIDER holds
#   a changed kernel flavour    -> PROVIDER moves, CORE holds  (portability)
#   a dropped apt snapshot pin  -> CORE moves                  (an unpinned
#                                  archive cannot hide in the mirror line)
#
# The kernel case is the one worth staring at: it is the whole reason the
# capture is split. Two providers legitimately ship different kernel flavours,
# and the core digest has to survive that or cross-provider comparison is
# impossible.
#
# This covers the digesting half only. The other half of the claim - that two
# real rebuilds of the same VM definition capture identically - needs a
# destroy/recreate against a hypervisor and is not simulated here.
#
#   ./scripts/test-vm-fingerprint.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fingerprint="$here/vm-fingerprint.sh"
[ -x "$fingerprint" ] || { echo "not executable: $fingerprint" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"$work/base.txt" <<'FIXTURE'
##### CORE #####

===== packages =====
bun	1.2.0	arm64
git	1:2.43.0-1ubuntu7	arm64

===== apt pinning =====
Snapshot: 20260801T000000Z
Suites: noble

##### PROVIDER #####

===== kernel =====
6.8.0-45-generic

===== apt mirror =====
URIs: http://nz.archive.ubuntu.com/ubuntu/
FIXTURE

sed 's/1\.2\.0/1.2.1/'                     "$work/base.txt" >"$work/pkg.txt"
sed 's/6\.8\.0-45-generic/6.8.0-1021-aws/' "$work/base.txt" >"$work/kernel.txt"
grep -v '^Snapshot:'                       "$work/base.txt" >"$work/unpinned.txt"

digest() {  # digest <fixture> <core|provider|combined>
  "$fingerprint" --from-file "$1" | awk -v k="$2" '$1 == k { print $2 }'
}

failures=0
check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok      %s\n' "$1"
  else
    printf 'FAILED  %s\n          expected %s\n          actual   %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}
differs() {  # differs <description> <a> <b>
  if [ "$2" != "$3" ]; then
    printf 'ok      %s\n' "$1"
  else
    printf 'FAILED  %s\n          both were %s\n' "$1" "$2"
    failures=$((failures + 1))
  fi
}

base_core="$(digest "$work/base.txt" core)"
base_prov="$(digest "$work/base.txt" provider)"

check   "same capture digests the same twice" \
        "$base_core" "$(digest "$work/base.txt" core)"

differs "changed package version moves the CORE digest" \
        "$base_core" "$(digest "$work/pkg.txt" core)"
check   "changed package version leaves PROVIDER untouched" \
        "$base_prov" "$(digest "$work/pkg.txt" provider)"

differs "changed kernel flavour moves the PROVIDER digest" \
        "$base_prov" "$(digest "$work/kernel.txt" provider)"
check   "changed kernel flavour leaves CORE untouched (portability)" \
        "$base_core" "$(digest "$work/kernel.txt" core)"

differs "dropped apt snapshot pin moves the CORE digest" \
        "$base_core" "$(digest "$work/unpinned.txt" core)"

"$fingerprint" --from-file "$work/base.txt" >"$work/once.txt"
"$fingerprint" --from-file "$work/once.txt" >"$work/twice.txt"
check   "re-digesting an already-digested capture is idempotent" \
        "$(cat "$work/once.txt")" "$(cat "$work/twice.txt")"
check   "re-digesting does not append a second DIGESTS block" \
        "1" "$(grep -c '^##### DIGESTS #####$' "$work/twice.txt")"

# A capture from before the split has no markers, so both halves come out
# empty and digest to the sha256 of the empty string - which compares equal
# to any other empty capture. The script must refuse rather than report that
# well-known hash as a match.
printf '===== kernel =====\n6.8.0-45-generic\n' >"$work/presplit.txt"
if "$fingerprint" --from-file "$work/presplit.txt" >/dev/null 2>&1; then
  printf 'FAILED  %s\n' "a capture with no markers is refused, not digested as empty"
  failures=$((failures + 1))
else
  printf 'ok      %s\n' "a capture with no markers is refused, not digested as empty"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$failures check(s) failed"
  exit 1
fi
