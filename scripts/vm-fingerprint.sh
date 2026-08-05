#!/usr/bin/env bash
# Capture the determinism fingerprint of a VM over SSH.
#
# Records everything the environment contract pins - package set and versions,
# apt configuration, enabled units, login user, kernel - and deliberately
# excludes what is per-instance by design: SSH host keys, machine-id,
# filesystem UUIDs, MAC addresses, cloud-init instance-id, logs, timestamps.
#
# Workflow: capture to a tracked file, commit, destroy + reprovision, capture
# again to the same path - `git diff` empty means the rebuilt VM has the same
# environment.
#
#   ./scripts/vm-fingerprint.sh ubuntu@10.0.0.50 fingerprints/ubuntu-test.txt
#
# Host keys are instance noise here, so known-hosts checking is disabled for
# this script only (a rebuilt VM would otherwise hard-fail the connection).
# Your interactive ssh will still complain after a rebuild: ssh-keygen -R <ip>.

set -euo pipefail

host="${1:?usage: vm-fingerprint.sh <user@host> [outfile]}"
outfile="${2:-}"

capture() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR "$host" '
set -eu
section() { printf "\n===== %s =====\n" "$1"; }

section "os-release"
grep -E "^(PRETTY_NAME|VERSION_ID)=" /etc/os-release

section "kernel"
uname -r

section "hostname"
hostname; hostname -f 2>/dev/null || true

section "timezone"
readlink /etc/localtime

section "packages"
dpkg-query -W -f "\${Package}\t\${Version}\t\${Architecture}\n" | sort

section "apt configuration"
for f in /etc/apt/apt.conf.d/50cloudinit-snapshot /etc/apt/apt.conf.d/51cloudinit-no-auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades; do
  [ -e "$f" ] && { echo "--- $f"; cat "$f"; }
done

section "apt sources"
grep -rhE "^(Types|URIs|Suites|Components|Snapshot):" /etc/apt/sources.list.d/*.sources 2>/dev/null | sort || true

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
for d in .local .bun; do
  [ -d "$d" ] || continue
  find "$d" -path "$d/state" -prune -o ! -path "$d/install/cache/*.npm" -print
done | sort
for d in .local .bun; do
  [ -d "$d" ] || continue
  find "$d" -path "$d/state" -prune -o -type f ! -path "$d/install/cache/*.npm" -print0 | xargs -0 -r sha256sum
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

section "cloud-init"
cloud-init status
'
}

if [ -n "$outfile" ]; then
  mkdir -p "$(dirname "$outfile")"
  capture >"$outfile"
  echo "fingerprint written to $outfile" >&2
else
  capture
fi
