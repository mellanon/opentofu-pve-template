# Smithy

A **smithy** is a work place that contains a forge, a kind of crucible. A place where one might forge weld several layers of steel into a single piece.

## Infrastructure factory

A reference implementation of infrastructure as code for provisioning and 
deprovisioning VMs. Built for **repeatable software-test environments**: 
the environment around the software under test stays fixed — same image, 
same package versions. The VMs are designed to be ephemeral.

Core components for VM management: 
- OpenTofu drives the ProxMox VE hypervisor (bpg/proxmox provider)
- cloud-init gives the guest its boot-time identity
- Ansible installs software post-boot — re-appliable at any time without 
touching the VM lifecycle.

Persistent backend components:
- A grafana/optel-lgtm container provides an OpenTelemetry endpoint to 
capture and store Claude Code telemetry from agents running during testing. 
- A windmill-labs/windmill container is being evaluated as an orchestrator for the
overall testing workflow.

## Overview 

- **One YAML file per VM.** Provisioning is adding a file to `inventory/`;
  deprovisioning is deleting one, or moving it to the destroy subdiredtory. 
  Only `vm_id` is required — everything else inherits a typed `optional()` 
  default from the `spec` contract in `modules/vm/variables.tofu`.
- **Repeatable environments.** Per-VM `archive_snapshot:` pins apt to
  [snapshot.ubuntu.com](https://snapshot.ubuntu.com) at a chosen instant, so
  package installs resolve identically forever; `package_upgrade` defaults to
  false. Third-party repos (e.g. docker) are covered by explicit version pins
  in the ansible role defaults instead.
- **Composable post-boot software.** A spec lists ansible roles, for example,
  (`ansible_roles: [nats_server, bun, claude, docker, metafactory_arc]`) and
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
- **Real validation gates.** `tofu validate` never sees the YAML that comes
  out of `templatefile()`; `scripts/check-cloud-init.sh` renders the real
  user-data plus an adversarial fixture (SSH key comment containing `: `,
  package containing `#`, hostname that is a YAML boolean) and runs
  duplicate-key and `cloud-init schema` checks, treating deprecation warnings
  as failures. `scripts/check-ansible.sh` asserts the dynamic inventory's
  shape and syntax-checks (and, when installed, lints) the playbook.

## Layout

```
├── versions.tofu  providers.tofu  encryption.tofu
├── main.tofu              # sops secrets, node data source
├── guards.tofu            # protected VMIDs + live foreign-VM lookup   [EDIT]
├── vms.tofu               # inventory/ -> module.vm, for_each
├── variables.tofu         # fleet-wide defaults                        [EDIT]
├── outputs.tofu
├── modules/vm/            # the contract: what a VM is
├── cloud-init/
│   ├── base.yaml.tftpl            # every VM gets this - the whole document
│   └── base.runcmd.json.tftpl     # commands every VM runs
├── ansible/               # post-boot software
│   ├── ansible.cfg
│   ├── site.yaml                  # one hostvar-driven play
│   ├── inventory/tofu.py          # dynamic inventory from tofu output
│   └── roles/<role>/              # nats_server, bun, claude, docker,
│                                  # metafactory_arc
├── inventory/             # one YAML file per VM                       [EDIT]
├── scripts/               # check-cloud-init.sh, check-ansible.sh,
│                          # vm-fingerprint.sh
├── otel-lgtm/             # grafana/otel-lgtm observability stack      [EDIT]
│                          # (docker compose; see its README.md)
└── windmill/              # Windmill workflow engine (docker compose;  [EDIT]
                           # see its README.md; local-dev/ is the wmill
                           # CLI workspace)
```

The two container directories are deployments that run on a persistent backend 
system NOT on a test VM. In the reference implementation they are running on the
same system that is running opentofu and ansible, but that is not required.

## Opentofu and Ansible startup

- `cp .sops.yaml.example .sops.yaml`
- `cp guards.tofu.example guards.tofu`
- `cp variables.tofu.example variables.tofu`
- `cp inventory-example.yaml inventory/<vm_name>.yaml`
- `uv venv --python 3.14 --managed-python`
- `uv pip install -r requirements.txt`
- `source tofu.env` # this also sources .venv/bin/activate
- `tofu init` # the first init installs the providers

## optel-lgtm startup

- `cd optel-lgtm`
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

**Edit copied files with site specific information.**

## Prerequisites

- OpenTofu >= 1.10, `sops`, `age`, `ansible` (ansible-core >= 2.15;
  `ansible-lint` optional), and (for the cloud-init check script)
  `python3-yaml` and `cloud-init` on the workstation.

- OpenTofu, https://github.com/opentofu/opentofu/releases/tag/v1.12.6
- sops, https://github.com/getsops/sops/releases/tag/v3.13.3
- age, https://github.com/FiloSottile/age/releases/tag/v1.2.1
- uv, https://github.com/astral-sh/uv/releases/tag/0.12.6

- A ProxMox VE node (built against 9.x) with:
  - a datastore that allows the `snippets` content type (`local` by default;
    lvmthin cannot hold snippets),
  - an Ubuntu cloud image uploaded (e.g.
    `local:iso/resolute-server-cloudimg-amd64-20260720.img`),
  - an API token for provisioning, and root SSH access for snippet upload
    (see Credentials below). Besides the usual `VM.*`/`Datastore.*`/`SDN.Use`
    privileges, the token needs **`Datastore.Allocate` on the snippet
    datastore** — the provider reads the storage config (`GET /storage/<id>`)
    before uploading, and PVE gates that behind the full admin privilege.
    Grant it via a role scoped to `/storage/<snippet-datastore>`, and give
    that role the *complete* `Datastore.*` set: PVE ACLs on a specific path
    override propagated ones instead of merging.

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

2. **API user, roles, and token.** As root on the node (adjust the snippet
   datastore path if yours is not `local`):

   ```bash
   pveum user add opentofu-prov@pve --comment "OpenTofu provisioning (API token only)"

   pveum role add OpenTofuProv -privs "Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,Pool.Allocate,Pool.Audit,SDN.Audit,SDN.Use,Sys.AccessNetwork,Sys.Audit,Sys.Console,Sys.Modify,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.GuestAgent.Unrestricted,VM.Migrate,VM.PowerMgmt"
   pveum acl modify / -user opentofu-prov@pve -role OpenTofuProv

   # Scoped role for the snippet datastore; must carry the FULL Datastore.*
   # set - an ACL on a specific path overrides the propagated role, it does
   # not merge with it.
   pveum role add OpenTofuSnippetStore -privs "Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit"
   pveum acl modify /storage/local -user opentofu-prov@pve -role OpenTofuSnippetStore

   # privsep=0: the token inherits the user's ACLs. The secret prints ONCE -
   # it goes into secrets.enc.json (proxmox.api_token_secret).
   pveum user token add opentofu-prov@pve provisioning --privsep 0
   ```

3. **Provisioning SSH key.** The ProxMox API has no snippets endpoint, so the
   provider uploads cloud-init user-data over SSH as root:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_pve -N ""
   ssh-copy-id -i ~/.ssh/id_ed25519_pve.pub root@<your-node>
   ```

## Opentofu and Ansible startup

Note: Edit all the copied files with your specific data.

- `cp .sops.yaml.example .sops.yaml`
- `cp guards.tofu.example guards.tofu`
- `cp variables.tofu.example variables.tofu`
- `cp inventory-example.yaml inventory/<vm_name>.yaml`
- `uv venv --python 3.14 --managed-python`
- `uv pip install -r requirements.txt`
- `source tofu.env` # this also sources .venv/bin/activate
- `tofu init` # the first init installs the providers
- `tofu plan` # verify the output looks like what you expect

Note: The `ssh_public_keys` in terraform.tfvars are the keys that reach the *VMs* 
NOT the Proxmox VE provisioning key. Override any fleet defaults there too.

## optel-lgtm startup

- `cd optel-lgtm`
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
  `inventory/example.yaml` for every knob including snapshot pinning and
  ansible roles.
- **Remove a VM:** `git mv inventory/<name>.yaml inventory/destroy/` and
  `tofu apply` — only `inventory/*.yaml` is scanned, so the spec stays in the
  repo while the VM, its disk, and its snippet are destroyed. Moving it back
  provisions a fresh VM (all guest data is gone). To keep a VM but power it
  off, set `started: false` instead.
- **Install software:** list roles in the spec
  (`ansible_roles: [docker, ...]`) and run
  `ansible-playbook ansible/site.yaml [--limit <vm>]` — no plan diff, no
  recreation, idempotent (second run reports changed=0). Removing a role from
  the list does *not* uninstall it; clean removal is a rebuild.
- **After touching anything under `cloud-init/`:** run
  `./scripts/check-cloud-init.sh`. **Under `ansible/`:**
  `./scripts/check-ansible.sh`.
- **Prove a rebuild is identical:**
  `./scripts/vm-fingerprint.sh ubuntu@<ip> fingerprints/<name>.txt` captures
  the VM's environment (packages, apt config, enabled units, users, and the
  ansible-installed files — minus per-instance noise like host keys and
  machine-id) into a tracked file. Capture, commit, destroy + reprovision,
  re-run ansible, capture again to the same path: an empty `git diff` is the
  proof.

## Fingerprints

Short version of the command sequence to destroy, recreate, and validate the fingerprint assuming the inventory entry is for a VM called ubuntu-test at an IP of 10.0.0.50. 
This test assumes the first build fingerprint was saved as fingerprints/ubuntu-test-build1.txt. Rebuilding the same configuration should be an empty diff.

**Important**: Always start a session with `source tofu.env`

```sh
source tofu.env
git mv inventory/ubuntu-test.yaml inventory/destroy/
tofu apply
git mv inventory/destroy/ubuntu-test.yaml inventory/
tofu apply
ansible-playbook ansible/site.yaml --limit ubuntu-test
./scripts/vm-fingerprint.sh ubuntu@10.0.0.50 fingerprints/ubuntu-test-build2.txt
diff fingerprints/ubuntu-test-build1.txt fingerprints/ubuntu-test-build2.txt
```

NOTE: The inventory/destroy directory name is intentional, so it is clear what the next "tofu apply" is expected to do.

## Ansible

Cloud-init is decided at first boot and reachable only by recreating the VM —
that is the right place for identity, network, and the apt baseline, and the
wrong place for software. Everything softer lives in `ansible/` and follows
the same declarative grammar as the rest of the repo:

- **Specs declare, roles implement.** `ansible_roles:` in a VM's YAML rides
  through the module into `tofu output -json vms`;
  `ansible/inventory/tofu.py` (python3 stdlib only, no galaxy dependencies)
  reshapes that output into hosts, one group per role, and hostvars.
  `site.yaml` is a single play that `include_role`s each host's declared
  list, so adding a role never touches it, and a typo'd role name fails at
  `tofu plan` time via a `fileexists()` validation in the spec contract.
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
  is application order), and `docker` — the only role using `become` — which
  pins the signing key by full GPG fingerprint, writes a deb822 source,
  installs version-pinned packages, and manages `daemon.json` with a restart
  handler.
- **Host-key checking is off** in `ansible.cfg` (same stance as
  `vm-fingerprint.sh`): host keys are per-instance noise in a fleet where
  rebuilds are routine, and `accept-new` would poison `known_hosts` on first
  contact then hard-fail after every rebuild.
- **Unreachable VMs** (powered off, or the guest agent not up) are skipped by
  the inventory with a stderr notice instead of failing the whole run.

## Credentials

Deliberately separate identities, one job each:

| Credential | Authenticates to | Used for |
|---|---|---|
| API token (in `secrets.enc.json`) | ProxMox API | everything except snippet upload |
| `id_ed25519_pve` | `root@<node>` | snippet upload only |
| `ssh_public_keys` (tfvars) | `<ci_user>@<vm>` | reaching the VMs |

The provisioning key is root on the hypervisor and exists only to upload YAML
files; keeping it out of the VMs means a compromised VM never saw the key that
owns the hypervisor. The API identity (`@pve` realm) is not a Linux account and
can never be the SSH identity — that split is structural, not a choice.

## Protecting pre-existing VMs

Three plan-time layers in `guards.tofu` + `modules/vm/main.tofu`
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
- Ubuntu cloud images ship apt *sources* but not package *indexes*; cloud-init
  refreshes indexes automatically whenever `packages:` is non-empty, so
  installs work regardless of `package_update`/`package_upgrade`.
- **unattended-upgrades is disabled on every VM** (the image ships it
  enabled). Base zeroes the `APT::Periodic` jobs via `bootcmd` and disables
  the apt-daily timers at first boot — a test environment must not change
  itself. Remove those lines from `base.yaml.tftpl` /
  `base.runcmd.json.tftpl` if you *want* automatic security updates.
- `archive_snapshot:` writes `APT::Snapshot "<ts>";` to apt.conf.d via
  `bootcmd` (init stage — before apt configures sources and installs packages;
  re-applied every boot, so later manual `apt install` stays pinned). An
  apt.conf.d file survives cloud-init regenerating `ubuntu.sources`.
- Changing a cloud-init template does **not** diff existing VMs (the snippet
  ID is name-based and unchanged); template changes reach a VM only by
  recreating it.
- The disk's image reference is create-only (`ignore_changes`): bumping
  `cloud_image_file_id` affects new VMs, never existing ones.

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
