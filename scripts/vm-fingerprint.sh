#!/usr/bin/env bash
# Capture the determinism fingerprint of a VM over SSH, and digest it.
#
# Records everything the environment contract pins - package set and versions,
# apt configuration, enabled units, login user, kernel - and deliberately
# excludes what is per-instance by design: SSH host keys, machine-id,
# filesystem UUIDs, MAC addresses, cloud-init instance-id, logs, timestamps.
#
# The capture is split into two parts, digested separately:
#
#   CORE      what any provider must reproduce identically for the same VM
#             definition: package set and versions, apt pinning, enabled
#             units, login user, layer-2 file trees. Two VMs built from the
#             same definition on DIFFERENT providers should agree here.
#             Excludes the software under test - see layer2 files.
#   PROVIDER  where honest differences live on the record: kernel flavour,
#             apt mirror URIs, cloud-init datasource, base image identity.
#             Expected to differ between providers; must NOT differ between
#             two rebuilds on the same provider.
#
# Both digests, plus a combined one over the whole body, are appended to the
# capture so they are committed and diffed along with it.
#
# Workflow: capture to a tracked file, commit, destroy + reprovision, capture
# again to the same path - `git diff` empty means the rebuilt VM has the same
# environment, and the digests say so in one line each.
#
#   ./scripts/vm-fingerprint.sh ubuntu@10.0.0.50 fingerprints/ubuntu-test.txt
#
# A capture can also be re-digested without touching a VM, which is how the
# comparator is tested and how existing captures are re-digested if the
# core/provider split is ever re-cut:
#
#   ./scripts/vm-fingerprint.sh --from-file fingerprints/ubuntu-test.txt
#
# Host keys are instance noise here, so known-hosts checking is disabled for
# this script only (a rebuilt VM would otherwise hard-fail the connection).
# Your interactive ssh will still complain after a rebuild: ssh-keygen -R <ip>.

set -euo pipefail

usage="usage: vm-fingerprint.sh <user@host> [outfile]
       vm-fingerprint.sh --from-file <capture> [outfile]"

from_file=""
if [ "${1:-}" = "--from-file" ]; then
  from_file="${2:?$usage}"
  [ -r "$from_file" ] || { echo "not readable: $from_file" >&2; exit 2; }
  shift 2
  host=""
else
  host="${1:?$usage}"
  shift
fi
outfile="${1:-}"

# Re-reading a file that already carries a DIGESTS section drops it, along with
# the blank line separating it from the body, so that re-digesting an already
# digested capture reproduces the same three digests instead of folding that
# blank line into the provider section.
capture() {
  if [ -n "$from_file" ]; then
    awk '
      /^##### DIGESTS #####$/ { exit }
      /^$/                    { blanks++; next }
      { for (; blanks > 0; blanks--) print ""; print }
    ' "$from_file"
    return
  fi
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "$host" '
set -eu
section() { printf "\n===== %s =====\n" "$1"; }

printf "##### CORE #####\n"

section "os-release"
grep -E "^(PRETTY_NAME|VERSION_ID)=" /etc/os-release

section "hostname"
hostname

section "timezone"
readlink /etc/localtime

section "packages"
dpkg-query -W -f "\${Package}\t\${Version}\t\${Architecture}\n" | sort

section "apt configuration"
for f in /etc/apt/apt.conf.d/50cloudinit-snapshot /etc/apt/apt.conf.d/51cloudinit-no-auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades; do
  [ -e "$f" ] && { echo "--- $f"; cat "$f"; }
done

# The pin, without the mirror. Snapshot: is the determinism claim and belongs
# to core; URIs: is where the archive happens to be served from and moves with
# the provider (regional mirrors in cloud images), so it sits in PROVIDER. A
# provider that quietly drops the snapshot pin therefore breaks the CORE
# digest, loudly, instead of hiding behind a mirror difference.
section "apt pinning"
grep -rhE "^(Types|Suites|Components|Snapshot):" /etc/apt/sources.list.d/*.sources 2>/dev/null | sort || true

section "enabled units"
systemctl list-unit-files --state=enabled --no-legend --no-pager | awk "{print \$1}" | sort

section "login user"
getent passwd "$(whoami)"
id
sort ~/.ssh/authorized_keys

section "sshd drop-ins"
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -e "$f" ] || continue
  echo "--- $f"; sudo cat "$f"
done

section "layer2 files"
# Where the ansible tool roles install (~/.local, ~/.bun), with .local/state
# (claude lock files) and the compressed *.npm download blobs in
# .bun/install/cache excluded - the blobs are not content-stable across
# installs, unlike the extracted package trees next to them, which are what
# global/node_modules symlinks into and are covered. Scoped deliberately:
# hashing the whole home is non-idempotent by design (.claude.json,
# timestamped backups, caches).
#
# .local/share/metafactory is pruned too, and for a different reason than the
# rest: it is not noise, it is the software under test. arc installs packages
# into .local/share/metafactory/arc/repos, so hashing it would fold the
# targets git SHA into the environment digest - and an environment whose
# identity moves every time the thing being tested moves cannot answer the
# question the digest exists for, which is "were these two runs performed
# under the same conditions?". Same environment, two target versions is the
# comparison the whole exercise is built on, so the target is recorded in the
# run receipt instead, as name plus resolved ref.
#
# arc ITSELF stays in the fingerprint (see layer2 versions below): it lives in
# ~/arc, it decides how targets get installed, and it does not vary with which
# target is under test. Tooling is environment; the target is not.
for d in .local .bun; do
  [ -d "$d" ] || continue
  find "$d" -path "$d/state" -prune -o -path "$d/share/metafactory" -prune -o ! -path "$d/install/cache/*.npm" -print
done | sort
for d in .local .bun; do
  [ -d "$d" ] || continue
  find "$d" -path "$d/state" -prune -o -path "$d/share/metafactory" -prune -o -type f ! -path "$d/install/cache/*.npm" -print0 | xargs -0 -r sha256sum
done | sort -k2

section "layer2 versions"
[ -x .local/bin/nats-server ] && .local/bin/nats-server --version
[ -x .bun/bin/bun ] && .bun/bin/bun --version
# readlink, not claude --version: running the binary risks first-run side
# effects, and the symlink target is the version claim (the binary itself is
# hashed above).
[ -L .local/bin/claude ] && readlink .local/bin/claude
# arc lives in ~/arc (deliberately not hashed - node_modules is large and
# the lockfile owns its determinism); the pinned tag is the version claim.
# NOTE: this whole remote script is single-quoted - no apostrophes anywhere.
[ -L .bun/bin/arc ] && readlink .bun/bin/arc
[ -d arc/.git ] && git -C arc describe --tags

section "docker daemon"
[ -e /etc/docker/daemon.json ] && { echo "--- /etc/docker/daemon.json"; cat /etc/docker/daemon.json; }

printf "\n##### PROVIDER #####\n"

section "kernel"
uname -r

section "fqdn"
hostname -f 2>/dev/null || true

section "apt mirror"
grep -rhE "^URIs:" /etc/apt/sources.list.d/*.sources 2>/dev/null | sort || true

section "base image"
# Ubuntu cloud images record what they were built from; this is the closest
# thing to image identity visible from inside the guest, and it is what the
# datastore file path (proxmox) or the AMI id (ec2) resolves to.
[ -e /etc/cloud/build.info ] && cat /etc/cloud/build.info

section "cloud-init"
cloud-init status
# v1.platform is the datasource discriminator: nocloud on the proxmox path,
# ec2 on the aws one. Verified against a real VM rather than guessed - the
# first version of this line asked for v1.datasource, which is not a key.
#
# Guarded because of HOW that failed. cloud-init does not error on an unknown
# key: it warns on stderr and prints CI_MISSING_JINJA_VAR/<name> to stdout,
# exit 0. That sentinel would have digested perfectly cleanly, every time,
# recording a placeholder where the datasource belongs - a healthy trace over
# stale input, in the one file whose job is to catch exactly that. So an
# unusable answer stops the capture instead of being written into it.
if command -v cloud-init >/dev/null 2>&1; then
  ci_platform=$(cloud-init query -f "{{ v1.platform }}" 2>/dev/null || true)
  case "$ci_platform" in
    "" | CI_MISSING_JINJA_VAR*)
      echo "FATAL: cloud-init returned no usable v1.platform (got: $ci_platform)" >&2
      echo "check the available keys with: cat /run/cloud-init/instance-data.json" >&2
      exit 1
      ;;
  esac
  echo "$ci_platform"
else
  echo "cloud-init: not installed"
fi
'
}

# sha256sum on linux, shasum on macos - the operator machine, not the guest.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | awk '{print $1}'
  else
    shasum -a 256 <"$1" | awk '{print $1}'
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

capture >"$work/body"

# Split on the part markers. The markers themselves are not digested, so the
# digest is over content only and stays stable if the marker text is ever
# reworded.
awk -v core="$work/core" -v prov="$work/provider" '
  /^##### CORE #####$/     { out = core; next }
  /^##### PROVIDER #####$/ { out = prov; next }
  out                      { printf "%s\n", $0 > out }
' "$work/body"

: >>"$work/core"
: >>"$work/provider"

# An empty section still digests - to the well-known sha256 of the empty
# string - and would sail through a comparison looking like a match. Refuse
# instead: an empty half means the markers did not arrive (a capture from
# before the split, or a remote script that died early), not that the VM has
# no packages.
for part in core provider; do
  if [ ! -s "$work/$part" ]; then
    echo "refusing to digest: the $part section is empty." >&2
    echo "the capture is missing its ##### markers - pre-split file, or a truncated capture." >&2
    exit 3
  fi
done

cat "$work/core" "$work/provider" >"$work/combined"

{
  cat "$work/body"
  printf '\n##### DIGESTS #####\n'
  printf 'core      sha256:%s\n' "$(sha256_of "$work/core")"
  printf 'provider  sha256:%s\n' "$(sha256_of "$work/provider")"
  printf 'combined  sha256:%s\n' "$(sha256_of "$work/combined")"
} >"$work/out"

if [ -n "$outfile" ]; then
  mkdir -p "$(dirname "$outfile")"
  cp "$work/out" "$outfile"
  echo "fingerprint written to $outfile" >&2
  tail -4 "$outfile" >&2
else
  cat "$work/out"
fi
