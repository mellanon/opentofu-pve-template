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
