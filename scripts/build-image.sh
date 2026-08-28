#!/usr/bin/env bash
# Build the golden Ubuntu cloud image and upload it to the ProxMox node.
#
# The bpg provider can only upload cloud-init snippets over SSH (the PVE API
# has no snippets endpoint), which is what forced a root SSH key for the
# hypervisor into providers.tofu. Everything that snippet did can move to PVE's
# native cloud-init settings or to the ansible base role - except installing
# qemu-guest-agent, because apply blocks until the agent reports an address and
# the ansible inventory reads the address from the agent. Ansible therefore
# cannot be what installs it, so it is baked in here instead.
#
# Deliberately API-only: the finished image goes up through the storage upload
# endpoint, not scp. Losing the SSH path is the entire point of the exercise -
# which is also why it is uploaded as `import` content rather than `iso`. A VM
# disk sourced from an iso-content volume goes through the provider's "custom
# disk" path, which shells out to `qm` over SSH as root; PVE's native
# import-from only accepts `images` or `import` content.
#
#   ./scripts/build-image.sh                     # build only
#   ./scripts/build-image.sh --upload            # build, then upload
#   ./scripts/build-image.sh --serial 20260823 --upload
#
# The build needs no secrets. --upload decrypts the API token from
# secrets.enc.json with sops, so it needs the age key - but not `source
# tofu.env`, which is only about the state passphrase.
#
# The output is named for both the upstream serial and the archive snapshot it
# was built against, and an uploaded image is never overwritten: disk file_id
# is under ignore_changes in modules/vm-pve, so a new name is a no-op for
# running VMs while an in-place replacement would silently change what they
# were built from. Build a new name, repoint cloud_image_file_id, delete the
# old volume by hand once nothing references it.

set -euo pipefail

cd "$(dirname "$0")/.."

# Same serial as the plain image already on the node. Bumping it is a separate
# change: a new serial moves every package version at once, which drowns any
# refactor being verified with scripts/vm-fingerprint.sh.
release="resolute"
serial="20260720"
snapshot=""
outdir="private/images"
datastore="local"
endpoint=""
node=""
do_upload=0
force=0

usage="usage: build-image.sh [options]

  --serial YYYYMMDD    upstream cloud image serial (default: $serial)
  --snapshot STAMP     snapshot.ubuntu.com timestamp to build against
                       (default: <serial>T000000Z)
  --outdir DIR         where to download and build (default: $outdir)
  --upload             upload the finished image to the node over the API
  --datastore ID       upload target datastore, must allow the 'import'
                       content type (default: $datastore)
  --endpoint URL       PVE API endpoint (default: variables.tofu's pve_endpoint)
  --node NAME          PVE node name (default: variables.tofu's pve_node)
  --force              rebuild an existing local image / overwrite on the node
  -h, --help           this"

die() { echo "build-image: $*" >&2; exit 1; }
warn() { echo "build-image: warning: $*" >&2; }
step() { echo; echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --serial)    serial="${2:?$usage}"; shift 2 ;;
    --snapshot)  snapshot="${2:?$usage}"; shift 2 ;;
    --outdir)    outdir="${2:?$usage}"; shift 2 ;;
    --datastore) datastore="${2:?$usage}"; shift 2 ;;
    --endpoint)  endpoint="${2:?$usage}"; shift 2 ;;
    --node)      node="${2:?$usage}"; shift 2 ;;
    --upload)    do_upload=1; shift ;;
    --force)     force=1; shift ;;
    -h|--help)   echo "$usage"; exit 0 ;;
    *)           die "unknown argument: $1"$'\n'"$usage" ;;
  esac
done

[[ "$serial" =~ ^[0-9]{8}(\.[0-9]+)?$ ]] || die "--serial must look like YYYYMMDD (got '$serial')"
: "${snapshot:=${serial%%.*}T000000Z}"
[[ "$snapshot" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "--snapshot must be YYYYMMDDTHHMMSSZ (got '$snapshot')"

base_url="https://cloud-images.ubuntu.com/${release}/${serial}"
upstream_name="${release}-server-cloudimg-amd64.img"
cached="${outdir}/${release}-server-cloudimg-amd64-${serial}.img"
# .qcow2, not .img: the image really is qcow2, and PVE only accepts
# .ova/.qcow2/.raw/.vmdk for an `import` upload. The extension is load-bearing.
golden_name="${release}-server-cloudimg-amd64-${serial}-golden-${snapshot}.qcow2"
golden="${outdir}/${golden_name}"
volid="${datastore}:import/${golden_name}"

# ---------------------------------------------------------------------------
# Preflight. Every failure names its own remedy - this script is run rarely
# enough that nobody remembers the setup.
# ---------------------------------------------------------------------------
step "Preflight"

command -v virt-customize >/dev/null || die "virt-customize not found; apt install libguestfs-tools"
command -v curl >/dev/null || die "curl not found"
command -v sha256sum >/dev/null || die "sha256sum not found"

# libguestfs boots its appliance with the host kernel, which Ubuntu ships mode
# 0600. Without the statoverride every guestfs call fails to launch.
kernel="/boot/vmlinuz-$(uname -r)"
[ -r "$kernel" ] || die "$kernel is not readable; run:
  sudo dpkg-statoverride --update --add root root 0644 $kernel"

# Not fatal, just slow: libguestfs silently falls back to TCG emulation, which
# turns a two-minute --install into a very long one.
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  warn "/dev/kvm is not accessible - the build will run under TCG emulation and be slow.
  Fix with: sudo usermod -aG kvm $USER   (then log out and back in)"
fi

mkdir -p "$outdir"

# The upstream image is ~860 MB and the golden copy grows past 1 GB while apt
# runs inside it. Only count the download if it is not already cached.
need_kb=$((1536 * 1024))
[ -f "$cached" ] || need_kb=$((need_kb + 900 * 1024))
avail_kb="$(df -Pk "$outdir" | awk 'NR==2 {print $4}')"
[ "$avail_kb" -ge "$need_kb" ] || die "only $((avail_kb / 1024)) MB free in $outdir, need ~$((need_kb / 1024)) MB.
  Note /tmp is a tmpfs here - building there spends RAM, not disk."

echo "ok    virt-customize, readable $kernel, $((avail_kb / 1024)) MB free in $outdir"

# ---------------------------------------------------------------------------
# Download and verify. The dated serial directory, never current/, which is a
# moving target: a golden image has to be reproducible from its own filename.
# ---------------------------------------------------------------------------
step "Fetching ${release}/${serial}"

if [ -f "$cached" ]; then
  echo "ok    already downloaded: $cached"
else
  curl -fSL --retry 3 -o "${cached}.part" "${base_url}/${upstream_name}" \
    || die "download failed: ${base_url}/${upstream_name}
  Serial ${serial} may have aged off the mirror; check https://cloud-images.ubuntu.com/${release}/"
  mv "${cached}.part" "$cached"
fi

expected="$(curl -fsSL "${base_url}/SHA256SUMS" | awk -v n="$upstream_name" '$2 == "*" n || $2 == n {print $1}')"
[ -n "$expected" ] || die "no $upstream_name line in ${base_url}/SHA256SUMS"
actual="$(sha256sum "$cached" | awk '{print $1}')"
[ "$actual" = "$expected" ] || die "checksum mismatch for $cached
  expected $expected
  actual   $actual
  Delete it and re-run."
echo "ok    sha256 $actual"

# ---------------------------------------------------------------------------
# Customise. virt-customize applies operations in command-line order.
# ---------------------------------------------------------------------------
step "Building $golden_name"

if [ -f "$golden" ] && [ "$force" -eq 0 ]; then
  echo "ok    already built: $golden (--force to rebuild)"
else
  # Build under .part and rename only on success, so an aborted build is never
  # mistaken for a finished one on the next run.
  rm -f "$golden" "${golden}.part"
  cp --reflink=auto "$cached" "${golden}.part"

  # The image's root filesystem is 2.2 GB with ~366 MB free, and apt's index
  # for universe alone is ~120 MB unpacked. Two things follow, and skipping
  # either one fills the guest disk mid-unpack:
  #
  #   - Fetch ONE index set, not two. APT::Snapshot adds the snapshot mirror
  #     alongside the configured one and refreshes both, so the sources file is
  #     rewritten to point at snapshot.ubuntu.com instead, and restored after.
  #     Same effect - the agent comes from the archive as of $snapshot - at
  #     half the disk cost, and the pin cannot leak into the built image.
  #   - Fetch only Packages. Translations, DEP-11 app-stream metadata and
  #     command-not-found indexes are pure waste in a headless image.
  #
  # The pin must NOT survive into the image under any spelling: baked into
  # apt.conf.d it would override every VM's own archive_snapshot, and left in
  # ubuntu.sources it would freeze the whole fleet at the build's snapshot.
  # Hence the restore, and the grep that fails the build if it did not happen.
  #
  # There is deliberately no `systemctl enable qemu-guest-agent`: the unit ships
  # an empty [Install] section, so enabling it is a no-op. It is started by
  # /usr/lib/udev/rules.d/60-qemu-guest-agent.rules when the virtio-serial port
  # org.qemu.guest_agent.0 appears. That rule is the whole reason apply
  # terminates - without the agent it blocks for the full 30m timeout waiting
  # for an address - so its presence is asserted rather than assumed.
  #
  # The 51cloudinit-no-auto-upgrades filename below is the one cloud-init used
  # to write. It is kept verbatim - "cloudinit" is a misnomer now, but
  # scripts/vm-fingerprint.sh records apt config by filename, so renaming it
  # would make every fingerprint captured so far incomparable.
  LIBGUESTFS_BACKEND=direct virt-customize -a "${golden}.part" \
    --run-command 'cp /etc/apt/sources.list.d/ubuntu.sources /root/ubuntu.sources.orig' \
    --run-command "sed -i 's|^URIs:.*|URIs: https://snapshot.ubuntu.com/ubuntu/${snapshot}|' /etc/apt/sources.list.d/ubuntu.sources" \
    --write '/etc/apt/apt.conf.d/50build-lean:Acquire::Languages "none";
Acquire::IndexTargets::deb::Translations::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::IndexTargets::deb::CNF::DefaultEnabled "false";' \
    --run-command 'rm -rf /var/lib/apt/lists/*' \
    --install qemu-guest-agent \
    --run-command 'mv /root/ubuntu.sources.orig /etc/apt/sources.list.d/ubuntu.sources' \
    --delete /etc/apt/apt.conf.d/50build-lean \
    --run-command 'grep -q archive.ubuntu.com /etc/apt/sources.list.d/ubuntu.sources' \
    --run-command 'test -f /usr/lib/udev/rules.d/60-qemu-guest-agent.rules' \
    --run-command 'systemctl disable apt-daily.timer apt-daily-upgrade.timer || true' \
    --write '/etc/apt/apt.conf.d/51cloudinit-no-auto-upgrades:APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";' \
    --run-command 'apt-get clean' \
    --run-command 'rm -rf /var/lib/apt/lists/*' \
    --truncate /etc/machine-id \
    || die "virt-customize failed; the partial image is at ${golden}.part"

  mv "${golden}.part" "$golden"
fi

golden_sha="$(sha256sum "$golden" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Upload over the API.
# ---------------------------------------------------------------------------
if [ "$do_upload" -eq 1 ]; then
  step "Uploading to $volid"

  command -v sops >/dev/null || die "sops not found; needed to decrypt the API token"

  # variables.tofu is a symlink to site-specific values outside the repo, so
  # read the defaults out of it rather than hardcoding an address here.
  tofu_default() {
    awk -v name="$1" '
      $0 ~ "^variable[[:space:]]+\"" name "\"" { inblock = 1; next }
      inblock && /^}/ { exit }
      inblock && /^[[:space:]]*default[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); sub(/[[:space:]]+$/, "")
        print; exit
      }
    ' variables.tofu
  }
  : "${endpoint:=$(tofu_default pve_endpoint)}"
  : "${node:=$(tofu_default pve_node)}"
  [ -n "$endpoint" ] || die "could not read pve_endpoint from variables.tofu; pass --endpoint"
  [ -n "$node" ] || die "could not read pve_node from variables.tofu; pass --node"
  endpoint="${endpoint%/}"

  token_id="$(sops -d --extract '["proxmox"]["api_token_id"]' secrets.enc.json)" \
    || die "sops decryption failed; is the age key at ~/.config/sops/age/keys.txt?"
  token_secret="$(sops -d --extract '["proxmox"]["api_token_secret"]' secrets.enc.json)" \
    || die "sops decryption failed"
  [ -n "$token_id" ] && [ -n "$token_secret" ] || die "sops returned an empty API token"
  auth="Authorization: PVEAPIToken=${token_id}=${token_secret}"

  # -k mirrors providers.tofu's `insecure = true`: the node serves a
  # self-signed certificate. The token rides on every one of these calls.
  api() { curl -k -fsS -H "$auth" "$@"; }

  if api "${endpoint}/api2/json/nodes/${node}/storage/${datastore}/content?content=import" \
    | grep -q "\"volid\":\"${volid}\""; then
    if [ "$force" -eq 0 ]; then
      die "$volid already exists on the node.
  Never replace an uploaded image in place - VMs pin their disk source by
  file_id under ignore_changes, so a same-name replacement changes what a
  running VM was built from without any plan diff. Build a new snapshot or
  serial instead. --force overrides."
    fi
    warn "$volid exists and --force was given; overwriting"
  fi

  # filename=@ MUST be the last -F. PVE parses the multipart body in order and
  # streams everything after the file part straight into the file, so any field
  # placed after it is both silently ignored as a parameter and appended to the
  # image as garbage - which qemu-img happily tolerates, so nothing complains.
  # With the order below, checksum is a real parameter and the node verifies
  # the upload itself; the task fails on mismatch.
  echo "      $(du -h "$golden" | awk '{print $1}') to ${node}/${datastore} - this takes a few minutes"
  upid="$(api --max-time 1800 \
    -F content=import \
    -F checksum-algorithm=sha256 \
    -F "checksum=${golden_sha}" \
    -F "filename=@${golden}" \
    "${endpoint}/api2/json/nodes/${node}/storage/${datastore}/upload" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"])')" \
    || die "upload failed"
  echo "      task $upid"

  # The upload endpoint returns as soon as the task is queued; the node is
  # still writing (and checksumming) after that.
  while :; do
    status_json="$(api "${endpoint}/api2/json/nodes/${node}/tasks/${upid}/status")"
    read -r task_status task_exit <<<"$(printf '%s' "$status_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
print(d.get("status", ""), d.get("exitstatus", ""))')"
    [ "$task_status" = "stopped" ] && break
    sleep 5
  done
  [ "$task_exit" = "OK" ] || die "upload task finished with: ${task_exit:-<none>}
  Check the node: pvenode task log $upid"
  echo "ok    uploaded"
fi

# ---------------------------------------------------------------------------
step "Done"
cat <<EOF

  image     $golden
  sha256    $golden_sha
  volid     $volid

Set cloud_image_file_id to the volid above, in variables.tofu and in
variables.tofu.example.
EOF
if [ "$do_upload" -eq 0 ]; then
  echo
  echo "Not uploaded. Re-run with --upload, or upload by hand in the web UI:"
  echo "  node -> ${datastore} -> Import -> Upload"
fi
