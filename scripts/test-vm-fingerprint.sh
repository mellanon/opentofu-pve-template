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
URIs: http://archive.ubuntu.com/ubuntu/
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

# The software under test must not be inside the environment digest. It can
# get in by two doors, and each needs its own prune:
#
#   arc installs packages into ~/.local/share/metafactory/arc/repos, so
#   without a prune the layer2 file hash folds the target-s git SHA into the
#   environment, and "same environment, two target versions" stops being
#   expressible.
#
#   arc also writes a CLI shim per installed package into ~/.local/bin, as a
#   regular 0755 file. So the first `arc install <target>` drops
#   .local/bin/<target> into the same hash even when share/metafactory is
#   pruned. The shim dir is therefore pruned wholesale - see the reasoning
#   block above the find passes in the remote script for why wholesale and
#   not arc-owned-only, and for what that costs.
#
# Two checks per prune, because neither alone is enough: the first proves the
# prune is still written into both find passes, the second proves the
# expression does what it claims on a real tree. The expression is duplicated
# from the remote script - if you change it there, change it here.
# SC2016 is the point: this greps for the literal string $d as it appears in
# the script, not for the value of a variable.
# shellcheck disable=SC2016
prunes="$(grep -c -- '-path "\$d/share/metafactory" -prune' "$fingerprint" || true)"
check   "both layer2 find passes prune the metafactory data dir" \
        "2" "$prunes"
# shellcheck disable=SC2016
bin_prunes="$(grep -c -- '-path "\$d/bin" -prune' "$fingerprint" || true)"
check   "both layer2 find passes prune the shim dir" \
        "2" "$bin_prunes"

tree="$work/home"
mkdir -p "$tree/.local/bin" "$tree/.local/state" \
         "$tree/.local/share/metafactory/arc/repos/cortex" \
         "$tree/.bun/install/cache"
: >"$tree/.local/bin/nats-server"
# What an arc CLI shim for an installed target actually looks like on disk:
# a regular 0755 file, no arc header, no marker this script could match -
# which is why the prune is by path and the whole dir goes.
# SC2016 is the point again: this is a verbatim copy of what arc writes, not
# something this script should expand.
# shellcheck disable=SC2016
printf '#!/bin/bash\nexport ARC_INVOCATION_CWD="${ARC_INVOCATION_CWD:-$(pwd)}"\ncd "/home/u/.local/share/metafactory/arc/repos/cortex" && exec bun run ./cli.ts "$@"\n' \
  >"$tree/.local/bin/cortex"
chmod 0755 "$tree/.local/bin/cortex"
: >"$tree/.local/state/claude.lock"
: >"$tree/.local/share/metafactory/arc/repos/cortex/index.ts"
: >"$tree/.bun/install/cache/pkg.npm"
: >"$tree/.bun/install/cache/extracted.js"

listing="$(
  cd "$tree" || exit 1
  for d in .local .bun; do
    [ -d "$d" ] || continue
    find "$d" -path "$d/state" -prune -o -path "$d/share/metafactory" -prune -o -path "$d/bin" -prune -o ! -path "$d/install/cache/*.npm" -print
  done | sort
)"

seen() { printf '%s\n' "$listing" | grep -q "$1" && echo yes || echo no; }
check   "the software under test is excluded from the layer2 listing" \
        "no"  "$(seen 'share/metafactory')"
check   "an arc shim for the software under test is excluded too" \
        "no"  "$(seen 'bin/cortex')"
check   "the shim dir is pruned wholesale, tooling shims included" \
        "no"  "$(seen 'bin/nats-server')"
check   ".local/state is still excluded"      "no"  "$(seen 'state/claude.lock')"
check   "compressed .npm blobs are still excluded" "no"  "$(seen 'pkg.npm')"
check   "extracted cache trees are still covered"  "yes" "$(seen 'extracted.js')"

# Pruning bin wholesale trades its hashes for the version section, so that
# section is now the only place the layer-2 tooling identity survives. These
# checks are what makes the trade honest: drop a tool from layer2 versions
# after this and the suite goes red rather than the fingerprint going quiet.
# Comments are stripped so the prose above those lines cannot satisfy them.
versions="$(
  sed -n '/^section "layer2 versions"$/,/^section "docker daemon"$/p' "$fingerprint" \
    | grep -vE '^[[:space:]]*#'
)"
records() { printf '%s\n' "$versions" | grep -q "$1" && echo yes || echo no; }
for tool in nats-server bun claude arc; do
  check "layer2 versions still records $tool by version, not by hash" \
        "yes" "$(records "$tool")"
done

# cloud-init does not error on an unknown key - it prints
# CI_MISSING_JINJA_VAR/<name> to stdout and exits 0, which digests cleanly and
# records a placeholder where a real value belongs. v1.datasource is not a key
# and shipped here once; these are static checks because the alternative needs
# a booted VM, and a grep that runs is worth more than an assertion that does
# not.
# Comment lines are stripped first: the comments in the fingerprint script
# discuss both key names by name, and a check that counts its own explanation
# is not a check.
code_only() { grep -vE '^[[:space:]]*#' "$fingerprint"; }

check   "the fingerprint asks cloud-init for v1.platform" \
        "1" "$(code_only | grep -cF 'cloud-init query -f "{{ v1.platform }}"' || true)"
check   "it never asks for v1.datasource, which is not a key" \
        "0" "$(code_only | grep -c 'v1\.datasource' || true)"
check   "a CI_MISSING_JINJA_VAR answer stops the capture" \
        "1" "$(code_only | grep -c 'CI_MISSING_JINJA_VAR' || true)"

echo
if [ "$failures" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$failures check(s) failed"
  exit 1
fi
