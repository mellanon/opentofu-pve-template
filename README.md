# Smithy

A **smithy** is a work place that contains a forge, a kind of crucible. A place where one might forge weld several layers of steel into a single piece.

## Infrastructure factory

A reference implementation of infrastructure as code for provisioning and 
deprovisioning VMs. Built for **repeatable software-test environments**: 
the environment around the software under test stays fixed — same image, 
same package versions. The VMs are designed to be ephemeral.

Core components for VM management: 
- A golden image carries what has to exist before first boot (the guest agent)
- OpenTofu drives the ProxMox VE hypervisor (bpg/proxmox provider) and its 
native cloud-init settings — identity, keys, addressing
- Ansible owns everything after boot — re-appliable at any time without 
touching the VM lifecycle.

Persistent backend components:
- A grafana/otel-lgtm container provides an OpenTelemetry endpoint to 
capture and store Claude Code telemetry from agents running during testing. 
- A windmill-labs/windmill container is being evaluated as an orchestrator for the
overall testing workflow.

## Overview 

- **One YAML file per VM.** Provisioning is adding a file to `inventory/`;
  deprovisioning is deleting one, or moving it to the destroy subdirectory. 
  Only `vm_id` is required — everything else inherits a typed `optional()` 
  default from the `spec` contract in `modules/vm-pve/variables.tofu`.
- **Repeatable environments.** Per-VM `archive_snapshot:` pins apt to
  [snapshot.ubuntu.com](https://snapshot.ubuntu.com) at a chosen instant, so
  package installs resolve identically forever; `package_upgrade` defaults to
  false. Third-party repos (e.g. docker) are covered by explicit version pins
  in the ansible role defaults instead.
- **Composable post-boot software.** A spec lists ansible roles, for example,
  (`ansible_roles: [nats_server, bun, claude, docker, metafactory_arc,
  assay_env]`) and
  `ansible-playbook ansible/site.yaml` applies them — idempotently, with every
  download verified and every version pinned. A dynamic inventory reads
  the tofu state, so there is no hosts file to maintain, and changing ansible 
  content never diffs the plan or recreates a VM.
- **Guardrails for pre-existing VMs.** A VMID floor, a named protected list,
  and a live check that refuses to plan against any VM on the node not tagged
  `opentofu` — with validations that prevent the guards themselves from being
  quietly weakened, and a fail-closed check if the API token can no longer see
  the whole node.
- **Encrypted state and plans** (pbkdf2 + AES-GCM, `enforced = true`), secrets
  via sops/age, and a `.gitignore` that covers the sharp edges (`crash.log`
  contains a TRACE-level dump including the API token, regardless of TF_LOG).
- **Real validation gates.** `scripts/check-ansible.sh` asserts the dynamic
  inventory's shape — every hostvar the roles rely on, every declared role
  backed by a real directory — and syntax-checks and lints the playbook.
  `scripts/build-image.sh` verifies the upstream image against its published
  `SHA256SUMS`, asserts inside the built image that the build-time apt pin did
  not leak, and has the node verify the upload's checksum.

## Layout

```
├── CLAUDE.md              # notes for coding agents; AGENTS.md is a symlink
├── versions.tofu
├── providers.tofu
├── encryption.tofu
├── main.tofu              # sops secrets, node data source
├── guards.tofu            # protected VMIDs + live foreign-VM lookup   [EDIT]
├── vms.tofu               # inventory/ -> module.vm-pve, for_each
├── variables.tofu         # fleet-wide defaults                        [EDIT]
├── outputs.tofu
├── modules/vm-pve/        # the contract: what a VM is
├── ansible/               # post-boot software
│   ├── ansible.cfg
│   ├── requirements.yml           # pinned collections (the only source)
│   ├── site.yaml                  # base, then each VM's declared roles
│   ├── inventory/tofu.py          # dynamic inventory from tofu output
│   └── roles/<role>/              # base (every VM), then nats_server, bun,
│                                  # claude, docker, metafactory_arc,
│                                  # assay_env (last: fingerprint + interchange)
├── inventory/             # one YAML file per VM                       [EDIT]
├── scripts/               # build-image.sh, check-ansible.sh,
│                          # install-collections.sh, vm-fingerprint.sh
├── otel-lgtm/             # grafana/otel-lgtm observability stack      [EDIT]
│                          # (docker compose; see its README.md)
└── windmill/              # Windmill workflow engine (docker compose;  [EDIT]
                           # see its README.md; local-dev/ is the wmill
                           # CLI workspace)
```

The two container directories are deployments that run on a persistent backend 
system NOT on a test VM. In the reference implementation they are running on the
same system that is running opentofu and ansible, but that is not required.

## Prerequisites

Download and install on PATH, for example ~/.local/bin

- OpenTofu, https://github.com/opentofu/opentofu/releases/tag/v1.12.6
- sops, https://github.com/getsops/sops/releases/tag/v3.13.3
- age, https://github.com/FiloSottile/age/releases/tag/v1.2.1
- uv, https://github.com/astral-sh/uv/releases/tag/0.12.6

- `libguestfs-tools` (Debian/Ubuntu package name) if you build the golden image there (see "Building the golden image"). On Arch Linux the package name is `libguestfs`.

- A ProxMox VE node (built against 9.x) with:
  - a datastore that allows the **`import`** content type for the golden
    image (`local` by default; `iso` will not do — PVE only imports a disk
    from `images` or `import` content),
  - a golden image uploaded (see "Building the golden image"), and
  - an API token for provisioning, with the usual
    `VM.*`/`Datastore.*`/`SDN.Use` privileges. That is the only credential
    this project needs — nothing here has, or wants, SSH to the node.

## Setup

1. **Age key + secrets.** Generate a key, put its public half in `.sops.yaml`
   (see the EDIT comment there — consider a second offline recipient), then:

   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   cp secrets.enc.json.example secrets.enc.json   # fill in, then:
   sops -e -i secrets.enc.json
   ```

   `secrets.enc.json` holds the ProxMox API token and the state passphrase
   (16 characters minimum). Once encrypted it is safe to commit.

2. **API user, role, and token.** As root on the node:

   ```bash
   pveum user add opentofu-prov@pve --comment "OpenTofu provisioning (API token only)"

   pveum role add OpenTofuProv -privs "Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,Pool.Allocate,Pool.Audit,SDN.Audit,SDN.Use,Sys.AccessNetwork,Sys.Audit,Sys.Console,Sys.Modify,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.GuestAgent.Unrestricted,VM.Migrate,VM.PowerMgmt"
   pveum acl modify / -user opentofu-prov@pve -role OpenTofuProv

   # privsep=0: the token inherits the user's ACLs. The secret prints ONCE -
   # it goes into secrets.enc.json (proxmox.api_token_secret).
   pveum user token add opentofu-prov@pve provisioning --privsep 0
   ```

   `Datastore.AllocateTemplate` is what lets the same token upload the golden
   image, so no second identity is needed.

3. **Golden image.** Build and upload one before the first `tofu apply` — see
   "Building the golden image". A stock cloud image will not do: it has no
   guest agent, and apply blocks for the full 30-minute timeout waiting for an
   address that never arrives.

## Building the golden image

Every VM's disk is imported from a golden image: an upstream Ubuntu cloud image
with `qemu-guest-agent` baked in. The agent is the one thing ansible cannot
install — `tofu apply` blocks until the agent reports an address, and the
dynamic inventory reads that same address to connect at all — so it has to be
present before first boot.

`scripts/build-image.sh` does the whole job. On the machine that builds:

```bash
sudo apt install libguestfs-tools
# libguestfs boots its appliance with the host kernel, which ships mode 0600
sudo dpkg-statoverride --update --add root root 0644 /boot/vmlinuz-$(uname -r)
sudo usermod -aG kvm "$USER"     # then log out and back in
```

The script's preflight checks each of those and names the fix if one is
missing; without `kvm` it still works, just slowly under emulation. Then:

```bash
./scripts/build-image.sh --upload
```

which downloads the dated upstream serial, verifies it against that
directory's `SHA256SUMS`, installs the agent with `virt-customize`, and uploads
the result through the storage API as `import` content — the same token as
everything else, no scp. It prints the `volid` to put in
`cloud_image_file_id`. Build without `--upload`
first if you want to inspect the image (`virt-df`, `guestfish --ro`).

Options: `--serial YYYYMMDD` picks the upstream build (default is the one this
repo currently pins), `--snapshot YYYYMMDDTHHMMSSZ` the snapshot.ubuntu.com
instant the agent is installed from, and `--outdir` where to work (default
`private/images/`, gitignored; budget ~2.5 GB).

Rebuild when the upstream serial should move, then repoint
`cloud_image_file_id` at the new file name. **Never overwrite an uploaded
image**: the disk source is create-only, so a same-name replacement silently
changes what a running VM was built from without any plan diff. Build a new
name, repoint, and delete the old volume once nothing references it.

## Opentofu and Ansible startup

Note: Edit all the copied files with your specific data.

- `cp .sops.yaml.example .sops.yaml`
- `cp guards.tofu.example guards.tofu`
- `cp variables.tofu.example variables.tofu`
- `cp inventory-example.yaml inventory/<vm_name>.yaml`
- `uv venv --python 3.14 --managed-python`
- `uv pip install -r requirements.txt`
- `source tofu.env` # this also sources .venv/bin/activate
- `./scripts/install-collections.sh` # after tofu.env, which names the path
- `tofu init` # the first init installs the providers
- `tofu plan` # verify the output looks like what you expect

Note: The `ssh_public_keys` in terraform.tfvars are the keys that reach the 
*VMs*. Override any fleet defaults there too.

## otel-lgtm startup

- `cd otel-lgtm`
- `cp .env.example .env`
- `docker compose up -d`

## windmill startup

- `cd windmill`
- `cp .env.example .env`
- `docker compose up -d`

## windmill local development

[Windmill local development](https://www.windmill.dev/docs/advanced/local_development)
[Windmill CLI](https://www.windmill.dev/docs/advanced/cli)

- `cd windmill/local-dev`
- `cp .env.example .env`
- `cp wmill.yaml.example wmill.yaml`

## Optional pre-push guard hook

- `cp prepush.env.example prepush.env`
- `git config core.hooksPath .githooks`

## Usage

- **Add a VM:** create `inventory/<name>.yaml` (the file name becomes the VM
  name and hostname — DNS label rules apply) and `tofu apply`. See
  `inventory-example.yaml` for every knob including snapshot pinning and
  ansible roles.
- **Remove a VM:** `mv inventory/<name>.yaml inventory/destroy/` and
  `tofu apply` — only `inventory/*.yaml` is scanned, so the spec stays on disk
  while the VM and its disk are destroyed. Moving it back provisions a fresh
  VM (all guest data is gone). To keep a VM but power it off, set
  `started: false` instead. (Plain `mv`: this template gitignores
  `inventory/*.yaml`, so `git mv` fails. A fork that tracks its own specs can
  use `git mv`.)
- **Install software:** list roles in the spec
  (`ansible_roles: [docker, ...]`) and run
  `ansible-playbook ansible/site.yaml [--limit <vm>]` — no plan diff, no
  recreation, idempotent (second run reports changed=0). Removing a role from
  the list does *not* uninstall it; clean removal is a rebuild.
- **After touching anything under `ansible/`:** run
  `./scripts/check-ansible.sh`.
- **Prove a rebuild is identical:**
  `./scripts/vm-fingerprint.sh ubuntu@<ip> fingerprints/<name>.txt` captures
  the VM's environment (packages, apt config, enabled units, users, and the
  ansible-installed files — minus per-instance noise like host keys and
  machine-id). Capture, destroy + reprovision, re-run ansible, capture again
  to the same path: an empty diff is the proof. `fingerprints/**` is
  gitignored, so captures stay local unless you commit one deliberately.

## Fingerprints

Short version of the command sequence to destroy, recreate, and validate the
fingerprint, assuming an inventory entry for a VM called ubuntu-test at
10.0.0.50. Capture to one path throughout and let `git diff` do the comparing;
rebuilding the same configuration should produce no diff.

**Important**: Always start a session with `source tofu.env`

```sh
source tofu.env
./scripts/vm-fingerprint.sh ubuntu@10.0.0.50 fingerprints/ubuntu-test.txt
cp fingerprints/ubuntu-test.txt /tmp/baseline.txt

mv inventory/ubuntu-test.yaml inventory/destroy/
tofu apply
mv inventory/destroy/ubuntu-test.yaml inventory/
tofu apply
ansible-playbook ansible/site.yaml --limit ubuntu-test

./scripts/vm-fingerprint.sh ubuntu@10.0.0.50 fingerprints/ubuntu-test.txt
diff /tmp/baseline.txt fingerprints/ubuntu-test.txt   # empty = identical rebuild
```

`fingerprints/**` and `inventory/*.yaml` are both gitignored, so this uses
`cp`/`diff` and plain `mv` rather than `git add -f`/`git diff` and `git mv`.
A fork that tracks its specs and captures can use the git forms throughout.

NOTE: The inventory/destroy directory name is intentional, so it is clear what
the next "tofu apply" is expected to do.

## Ansible

Cloud-init is decided at first boot and reachable only by recreating the VM —
that is the right place for identity and network, and the wrong place for
anything else. Everything softer lives in `ansible/` and follows the same
declarative grammar as the rest of the repo:

- **Specs declare, roles implement.** `ansible_roles:` in a VM's YAML rides
  through the module into `tofu output -json vms`;
  `ansible/inventory/tofu.py` (python3 stdlib only, no galaxy dependencies)
  reshapes that output into hosts, one group per role, and hostvars.
  `site.yaml` is a single play that `include_role`s each host's declared
  list, so adding a role never touches it, and a typo'd role name fails at
  `tofu plan` time via a `fileexists()` validation in the spec contract.
- **The `base` role is implicit.** No spec lists it and none can opt out:
  `site.yaml` applies it to every host via `roles:`, ahead of the include
  loop. It owns the apt snapshot pin, the `APT::Periodic` zeros, the masked
  apt-daily timers, key-only SSH, the timezone, and the spec's `packages:` —
  the baseline that used to be cloud-init's, now re-appliable to a running VM.
- **Collections are pinned** in `ansible/requirements.yml`, and both a
  workstation and CI install from it with `./scripts/install-collections.sh`.
  `requirements.txt` pins `ansible-core`, which ships none, so a `community.*`
  task without an entry there fails in both places — and `check-ansible.sh`
  verifies the installed versions against the pins before it lints anything.
- **Role names use underscores** (`nats_server`, not `nats-server`): they
  double as Ansible group names, which must be valid identifiers.
- **Every download is verified, every version pinned** in the role's
  `defaults/main.yaml`. The bundled roles show four install patterns:
  `nats_server` (tarball + upstream `SHA256SUMS` via `get_url checksum=`),
  `bun` (zip + `SHASUMS256.txt`; needs `unzip` in the VM's packages —
  asserted in-role; also owns the `~/.bun/bin` PATH block in `.bashrc`),
  `claude` (vendor installer, binary verified against the release manifest
  first), `metafactory_arc` (pinned git tag + `bun install`/`bun link`; needs
  `git` in the VM's packages, and `bun` earlier in the role list — spec order
  is application order), and `docker` — which pins the signing key by full GPG
  fingerprint, writes a deb822 source, installs version-pinned packages, and
  manages `daemon.json` with a restart handler.
- **`assay_env` is the capstone, and installs nothing.** Listed last, it runs
  `scripts/vm-fingerprint.sh` from the control node (`delegate_to: localhost`),
  parses the capture's `DIGESTS` block, and writes
  `/etc/assay/environment.json` — the interchange
  [assay](https://github.com/the-metafactory/assay/blob/main/environments/README.md)
  reads to learn which environment a result was produced under. It and `docker`
  are the only *spec-declared* roles using `become` — the implicit `base` role
  uses it throughout. A missing or malformed digest fails the role before
  anything is written, and revokes any environment file an earlier run left
  behind: a file naming a digest that was never computed is worse than no
  file, and so is one naming a digest this run could not confirm. The capture
  lands under gitignored
  `fingerprints/` and is never registered as content — it carries the guest's
  `authorized_keys`.
- **Host-key checking is off** in `ansible.cfg` (same stance as
  `vm-fingerprint.sh`): host keys are per-instance noise in a fleet where
  rebuilds are routine, and `accept-new` would poison `known_hosts` on first
  contact then hard-fail after every rebuild.
- **Unreachable VMs** (powered off, or the guest agent not up) are skipped by
  the inventory with a stderr notice instead of failing the whole run.

## Credentials

Two credentials, one job each:

| Credential | Authenticates to | Used for |
|---|---|---|
| API token (in `secrets.enc.json`) | ProxMox API | provisioning, and uploading the golden image |
| `ssh_public_keys` (tfvars) | `<ci_user>@<vm>` | reaching the VMs |

There is deliberately no hypervisor SSH credential. One used to exist, because
the ProxMox API has no snippets endpoint and the provider fell back to SSH as
root to upload cloud-init user-data. Removing the snippet removed the reason:
every call this project makes is now an API call carrying the token, and a
compromised workstation cannot reach root on the node through anything here.

The API identity lives in the `@pve` realm, which is not a Linux account, so it
could never have been the SSH identity — that split was structural, and is now
simply absent.

## Protecting pre-existing VMs

Three plan-time layers in `guards.tofu` + `modules/vm-pve/main.tofu`
(preconditions, not `check` blocks — they fail the plan rather than warn):

1. **VMID floor** — managed VMs live at or above `managed_vmid_min`.
2. **Named protected list** — failure messages name the VM, not just the ID.
3. **Live foreign-VM check** — everything on the node not tagged `opentofu`
   is refused, covering VMs hand-built after adoption. Fails closed: an
   unreachable node fails the plan, and a postcondition rejects the listing
   if the protected VMs are not all visible (an ACL-narrowed token shortens
   the list instead of erroring).

Two things no code can do, so do them on the node: **never `tofu import` a
pre-existing VMID** (import puts it in state; from that moment destroy can
reach it), and set `qm set <id> --protection 1` on the VMs that matter — the
one guard OpenTofu genuinely cannot bypass.

## Repeatability notes

- **Name images with their build serial** (the `-20260720` suffix in the
  examples). cloud-images.ubuntu.com publishes a `.manifest` per build listing
  every installed package+version, but only the serial ties your local file to
  it — the PVE web UI downloads a serial-less name that becomes untraceable
  once `current/` moves on. Verify with the build's `SHA256SUMS` before
  renaming. Serial-suffixed names also let images from different builds
  co-exist for different test setups. Baseline = manifest, delta = inventory
  `packages:`, delta versions = `archive_snapshot` — the whole environment is
  specified without booting anything.
- Ubuntu cloud images ship apt *sources* but not package *indexes*; the base
  role refreshes them (`update_cache: true`) before installing, so the spec's
  `packages:` resolve against the pin.
- **unattended-upgrades is disabled on every VM** (the image ships it
  enabled). The base role zeroes the `APT::Periodic` jobs and *masks* the
  apt-daily timers — masked rather than merely disabled, because a package
  postinst re-running `systemctl preset` can undo a disable, and a test
  environment must not change itself. Drop those tasks from
  `ansible/roles/base/tasks/main.yaml` if you *want* automatic updates.
- `archive_snapshot:` writes `APT::Snapshot "<ts>";` to apt.conf.d from the
  base role, before it installs anything, so the pin is in force for the
  spec's own packages and for any later manual `apt install`. An apt.conf.d
  file survives cloud-init regenerating `ubuntu.sources`.
- **What reaches a running VM, and what does not.** `packages:`,
  `archive_snapshot:`, `ci_timezone` and every `ansible_roles` entry are
  applied by ansible, so editing them and re-running the playbook is enough.
  `package_upgrade` is the exception: it becomes PVE's `ciupgrade`, which
  cloud-init reads on first boot only, so changing it reaches new VMs only.
- The disk's image reference is create-only (`ignore_changes`): bumping
  `cloud_image_file_id` affects new VMs, never existing ones. That is also why
  an uploaded image must never be replaced in place — same name, different
  bytes, no plan diff.

## Rotating the state passphrase

`encryption.tofu` has a standing two-slot design — `main` (current) and
`previous` (pre-rotation, placeholder outside rotation windows) — with both
key providers sharing `encrypted_metadata_alias = "state"`. That alias
matters: pbkdf2 otherwise keys its salt metadata to the provider's block
name, and renaming/moving passphrases between blocks makes existing state
undecryptable. With the alias, rotation never touches HCL:

```bash
# 1. demote the current passphrase, generate a new one
OLD="$(sops -d --extract '["state"]["passphrase"]' secrets.enc.json)"
sops set secrets.enc.json '["state"]["passphrase_previous"]' "\"$OLD\""
sops set secrets.enc.json '["state"]["passphrase"]' "\"$(openssl rand -base64 24)\""

# 2. re-encrypt state under the new key
source tofu.env
tofu apply -refresh-only -auto-approve

# 3. prove the new key decrypts alone
TF_VAR_state_passphrase_previous=rotation-placeholder-unused \
  tofu state pull >/dev/null && echo ok

# 4. retire the old passphrase and re-verify
sops set secrets.enc.json '["state"]["passphrase_previous"]' '"rotation-placeholder-unused"'
source tofu.env && tofu plan   # expect: No changes
```

`terraform.tfstate.backup` keeps pre-rotation ciphertext for one write cycle
— delete it when rotating away from a compromised passphrase. The placeholder
must stay >= 16 characters (pbkdf2 minimum).

## License / provenance

Extracted from a working single-node homelab setup; values in this template
(IPs, VMIDs, names) are placeholders — every spot needing a real value is
marked `EDIT` or `replace-me`.
