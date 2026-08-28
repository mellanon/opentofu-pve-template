# OpenTofu provisioning for ProxMox VE

Infrastructure as code for provisioning and deprovisioning VMs on ProxMox VE.
Three layers: a golden image carries what has to exist before first boot,
OpenTofu drives the hypervisor and PVE's native cloud-init settings, and
Ansible owns everything after boot.
See README.md for setup; this file is what a working session needs that is not
obvious from reading the code.

## Environment

Template placeholders — fill in for your site (marked `EDIT` in the code):

- ProxMox node name/endpoint: `variables.tofu` (`pve_node`, `pve_endpoint`).
- Datastores: `disk_datastore` holds VM disks and cloud-init drives; the
  golden image needs a datastore with the **`import`** content type (not
  `iso` — see the `import_from` gotcha below).
- Golden image: built by `scripts/build-image.sh` and named as the disk's
  `import_from`, so ProxMox imports and converts it server-side; there is no
  `download_file` resource. It exists to carry `qemu-guest-agent` — see the
  gotcha below.
- Secrets: `secrets.enc.json`, age via sops, key at
  `~/.config/sops/age/keys.txt`. Holds the API token and the state passphrase.

## Hard rules

**Pre-existing VMs must never be touched.** `guards.tofu` plus lifecycle
preconditions in `modules/vm-pve/main.tofu` enforce a VMID floor, a named
protected list, and a live check that rejects any VMID belonging to a VM not
tagged
`opentofu`. Validations stop the floor and the list from being weakened by
tfvars or `TF_VAR_*` overrides, and a postcondition fails the plan if the
protected VMs are not all visible in the API listing (fail closed).

**Never `tofu import` a pre-existing VMID.** No code can guard against it, and
it is the only action that puts one in destroy range.

## Working on this

Always `source tofu.env` first — it exports `TF_VAR_state_passphrase` from
sops and redirects logs to `logs/tofu.log`. Without it every command fails on
the state encryption key. It refuses to run if sops fails or you are not in
the repo root.

`terraform.tfvars` is gitignored and must exist locally; `ssh_public_keys` is
the only required variable. See `terraform.tfvars.example`.

Adding a VM is adding a file to `inventory/`; deprovisioning is removing one —
by convention, move it to `inventory/destroy/` (only `inventory/*.yaml` is
scanned; subdirectories are invisible). Plain `mv`, not `git mv`: this
template gitignores `inventory/*.yaml` and `inventory/destroy/*.yaml`, so
`git mv` fails with "not under version control" — a fork that tracks its own
specs can use `git mv`. The next apply destroys the VM and its disk; moving
the file back provisions a *fresh* VM. To keep a VM and its data but power it
off, set `started: false` instead. The filename is the VM name (DNS label).
Only `vm_id` is required — everything else takes an `optional()` default from
the `spec` object in `modules/vm-pve/variables.tofu`, which is the contract
worth reading first.

**Layer 0 — the golden image.** `./scripts/build-image.sh [--upload]` builds
it: an upstream Ubuntu cloud image with `qemu-guest-agent` installed by
`virt-customize`, uploaded over the API. Rebuild when the upstream serial
should move; then repoint `cloud_image_file_id` at the new name. It is
uploaded as `import` content, not `iso`. Never replace an uploaded image in
place — `disk[0].import_from` is create-only *and* under `ignore_changes`, so
a same-name replacement changes what a running VM was built from with no plan
diff. Prerequisites are `libguestfs-tools`, a readable
`/boot/vmlinuz-$(uname -r)` (`dpkg-statoverride`), and membership of `kvm`;
the script's preflight names each remedy.

**Layer 1 — PVE cloud-init.** `initialization` in `modules/vm-pve/main.tofu`:
user, keys, addresses, DNS, and `upgrade`. These are VM config over the API, so
editing one *does* diff — but cloud-init only reads the drive on first boot, so
a diff still does not reach a running guest. Rotating a key on a live VM means
ansible or a rebuild.

**Layer 2 — Ansible.** Everything softer — installed software and its config —
lives in `ansible/` and is re-applied any time with
`ansible-playbook ansible/site.yaml [--limit <vm>]` (after `source tofu.env`,
which exports `ANSIBLE_CONFIG`; no plan diff, no recreation). A spec opts in
with `ansible_roles: [nats_server, bun, claude, docker, metafactory_arc]` —
order matters where roles depend on each other (metafactory_arc needs bun's
install; the bun role also owns the `~/.bun/bin` PATH block in `.bashrc`,
which serves interactive shells only). Underscore names,
each a directory under `ansible/roles/`, typos fail at plan time. The dynamic
inventory (`ansible/inventory/tofu.py`) reads `tofu output -json vms`, so it
needs an applied state; versions are pinned in each role's
`defaults/main.yaml`, and collections in `ansible/requirements.yml` (CI
installs from it — `ansible-core` alone ships none, so a `community.*` task
without a pin there passes locally and fails CI). The `base` role is in no
spec and cannot be opted out of: `site.yaml` applies it to every host via
`roles:`, ahead of the include loop. It carries what the cloud-init snippet
used to — the apt snapshot pin, the `APT::Periodic` zeros, the apt-daily
timers, key-only SSH, the timezone, and `spec.packages` — which means those
**are** now reachable without recreating the VM. Removing a role from the list
does **not** uninstall it; clean removal is a rebuild. Runs are idempotent
(second run reports changed=0). After touching anything under `ansible/`, run
`./scripts/check-ansible.sh`.

`./scripts/vm-fingerprint.sh <user>@<ip> fingerprints/<name>.txt` captures a
VM's environment fingerprint (packages, apt config, enabled units, users, and
the ansible-installed layer-2 files under `~/.local` and `~/.bun` — excluding
per-instance noise like host keys and machine-id). `fingerprints/**` is
gitignored, so a capture is local unless `git add -f`d deliberately. Rebuild
verification: capture, destroy + reprovision, run `ansible-playbook
ansible/site.yaml`, capture to the same path — an empty diff proves the
environment is identical. Verified on this design: two rebuilds produced
byte-identical captures.

## Gotchas that have already cost time

- **`ciupgrade` is not root-gated, whatever the provider says.** The bpg
  schema calls `initialization.upgrade` *"only allowed for `root@pam`"*; that
  is stale. In `PVE/API2/Qemu.pm` (9.2.3) `ciupgrade` sits in
  `$cloudinitoptions`, which needs `VM.Config.Cloudinit` **or**
  `VM.Config.Network`. It is set explicitly because the provider's schema
  default is Computed and PVE's own default is 1 — the opposite of
  `spec.package_upgrade`'s default. Confirmed on the node, not just in
  source: `qm config <id>` shows `ciupgrade: 0` after an apply by the token.
- **An `@pve`-realm token cannot SSH anywhere.** It exists only in ProxMox's
  user database — it is not a Linux account. Worth knowing before anyone
  proposes reuniting the API and SSH identities to bring snippets back.
- **A disk `file_id` needs SSH; `import_from` does not.** Sourcing a disk from
  `file_id` sends the provider down its "custom disk" path, which shells out
  to `qm` on the node as root. That is a second SSH dependency, quite separate
  from snippets, and it fails at *disk creation* with "unable to authenticate
  user over SSH". `import_from` passes PVE's native import-from parameter
  instead. It only accepts `images` or `import` content — never `iso` — and
  the upload endpoint restricts `import` filenames to
  `.ova/.qcow2/.raw/.vmdk` (`UPLOAD_IMPORT_EXT_RE_1` in `PVE/Storage.pm`).
  Hence `local:import/<name>.qcow2`: the extension is load-bearing.
- **`sshd_config.d` takes the FIRST value, apt.conf.d takes the last.** The
  include glob is read in lexical order, so a *lower* number wins. The base
  role's drop-in is `10-smithy.conf` for that reason; the image's own
  `60-cloudimg-settings.conf` would otherwise be authoritative.
- **`cloud-init status` exits 2 on "degraded done".** Under a `set -e` that is
  a silent, message-free abort — it cost a debugging session in
  `vm-fingerprint.sh`. Degraded is the *steady state* here: the user-data PVE
  generates uses the top-level `user:` key, deprecated in cloud-init 22.2.
  Nothing in this repo emits it and nothing here can suppress it.
- **Pick the guest address by MAC, not by filtering.** The agent reports one
  address list per interface, with `ipv4_addresses`, `mac_addresses` and
  `network_interface_names` sharing an index. Flattening them was fine until
  the docker role added a `docker0` at 172.17.0.1, which the ansible inventory
  could have taken as `ansible_host`. `modules/vm-pve/outputs.tofu` selects the
  entry whose MAC is `network_device[0].mac_address`; address ranges are
  configurable and interface names vary by image, but that MAC cannot be
  impersonated by a bridge the guest brought up itself.
- **`filename=@` must be the last `-F` in a PVE upload.** PVE parses the
  multipart body in order and streams everything after the file part into the
  file. A `checksum` field placed after it is never parsed *and* its bytes are
  appended to the image — which `qemu-img` reads without complaint, so the
  task reports OK and the corruption is silent. `scripts/build-image.sh` has
  the order right and the node then verifies the checksum itself.
- **`APT::Snapshot` cannot be used while building the image.** It adds the
  snapshot mirror alongside the configured one and refreshes both, and the
  cloud image's root filesystem has ~366 MB free against a ~120 MB unpacked
  universe index — the build dies in `dpkg --unpack`. `build-image.sh`
  rewrites `ubuntu.sources` to the snapshot mirror for the duration instead.
  Unrelated to a VM's own `archive_snapshot`, which still goes via apt.conf.d.
- **Repeatability knobs live per-VM in the spec.** `archive_snapshot:
  YYYYMMDDTHHMMSSZ` pins apt to snapshot.ubuntu.com; the ansible `base` role
  writes `APT::Snapshot` into apt.conf.d before it installs anything, so the
  pin is in force for the spec's own packages. Official archive only —
  third-party repos like docker are not snapshotted, which is why the docker
  role pins exact package versions in its defaults instead. `package_upgrade`
  defaults to **false** and is the one first-boot-only knob left: it becomes
  PVE's `ciupgrade`, so flipping it does not reach an existing VM, where
  `packages` and `archive_snapshot` now do. unattended-upgrades is disabled
  fleet-wide (the image ships it enabled): `base` zeros the `APT::Periodic`
  jobs and masks the apt-daily timers — masked, not merely disabled, because a
  postinst re-running `systemctl preset` can undo a disable.
- **The apt.conf.d filenames still say "cloudinit"** (`50cloudinit-snapshot`,
  `51cloudinit-no-auto-upgrades`) and must stay that way.
  `scripts/vm-fingerprint.sh` records apt configuration by filename; renaming
  them would make every fingerprint captured so far incomparable.
- **A child module must declare its own `required_providers`** naming
  `bpg/proxmox`. Without `modules/vm-pve/versions.tofu`, `tofu init` assumes
  `hashicorp/proxmox` and fails.
- **`agent { enabled = true }` makes apply block** until the guest agent
  reports an address. Quick with the default `package_upgrade: false`; with a
  VM that sets it true, expect several minutes (timeout is 30m). The agent
  comes from the golden image, and nothing else can supply it — ansible needs
  the address the agent reports in order to connect at all. Point
  `cloud_image_file_id` at a stock cloud image (uploaded as `import`) and
  apply hangs for the full 30m, then fails.
- **pbkdf2 welds its salt to the key provider's block name** unless
  `encrypted_metadata_alias` is set — renaming a provider (or moving a
  passphrase between blocks) makes existing state undecryptable. Both
  providers in `encryption.tofu` share the alias `"state"`, which is what
  makes passphrase rotation a pure secrets-file edit. Procedure: README.md,
  "Rotating the state passphrase".

## Runbook items not expressible in code

- **Set the ProxMox protection flag on pre-existing VMs** (`qm set <id>
  --protection 1` on the node). It disables VM and disk removal on the
  hypervisor itself — the only guard OpenTofu genuinely cannot bypass,
  including via `tofu import` + destroy.
- **Use two age recipients** (one offline backup) in `.sops.yaml`. A single
  key guards both the API token and the state passphrase; once state exists,
  losing that one file means permanently unreadable state.
- **`insecure = true` in `providers.tofu`** stands until the node's CA is
  installed into the workstation's trust store; every API call carries the
  token over unverified TLS.
- If the `opentofu` tag is ever stripped from a managed VM out of band, the
  foreign-VM guard blocks the plan; the fix is re-tagging by hand on the node.
  Accepted trade-off — the guard cannot tell that drift from a foreign VM.
