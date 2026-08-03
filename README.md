# OpenTofu + ProxMox VE: declarative, repeatable test VMs

Infrastructure as code for provisioning and deprovisioning VMs on ProxMox VE
with OpenTofu and cloud-init. Built for **repeatable software-test
environments**: the environment around the software under test stays fixed —
same image, same package versions — while the software varies, and several VM
configurations can run side by side.

Two layers: OpenTofu drives the hypervisor (bpg/proxmox provider), cloud-init
configures the guest.

## What you get

- **One YAML file per VM.** Provisioning is adding a file to `inventory/`;
  deprovisioning is deleting one. Only `vm_id` is required — everything else
  inherits a typed `optional()` default from the `spec` contract in
  `modules/vm/variables.tofu`.
- **Repeatable environments.** Per-VM `archive_snapshot:` pins apt to
  [snapshot.ubuntu.com](https://snapshot.ubuntu.com) at a chosen instant, so
  package installs resolve identically forever; `package_upgrade` defaults to
  false. Third-party repos (e.g. docker) are covered by explicit
  `name=version` pins in the package list instead.
- **Guardrails for pre-existing VMs.** A VMID floor, a named protected list,
  and a live check that refuses to plan against any VM on the node not tagged
  `opentofu` — with validations that prevent the guards themselves from being
  quietly weakened, and a fail-closed check if the API token can no longer see
  the whole node.
- **Encrypted state and plans** (pbkdf2 + AES-GCM, `enforced = true`), secrets
  via sops/age, and a `.gitignore` that covers the sharp edges (`crash.log`
  contains a TRACE-level dump including the API token, regardless of TF_LOG).
- **A real validation gate for cloud-init.** `tofu validate` never sees the
  YAML that comes out of `templatefile()`; `scripts/check-cloud-init.sh`
  renders every role combination plus an adversarial fixture (SSH key comment
  containing `: `, package containing `#`, hostname that is a YAML boolean)
  and runs duplicate-key and `cloud-init schema` checks, treating deprecation
  warnings as failures.

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
│   ├── base.yaml.tftpl            # every VM gets this
│   ├── base.runcmd.json.tftpl     # commands every VM runs
│   └── roles/
│       ├── <role>.yaml.tftpl        # extra top-level cloud-config keys
│       └── <role>.runcmd.json.tftpl # extra commands for that role
├── inventory/             # one YAML file per VM                       [EDIT]
└── scripts/check-cloud-init.sh
```

## Prerequisites

- OpenTofu >= 1.10, `sops`, `age`, and (for the check script) `python3-yaml`
  and `cloud-init` on the workstation.
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

4. **Variables.** `cp terraform.tfvars.example terraform.tfvars` and set
   `ssh_public_keys` (the keys that reach the *VMs* — not the provisioning
   key). Override any fleet defaults there too.

5. **Guards.** Edit `guards.tofu`: set the VMID floor and list your
   pre-existing VMs (defaults and validation lists together — the comments
   mark both spots).

6. **Plan.**

   ```bash
   source tofu.env    # decrypts the state passphrase, sets up logging
   tofu init && tofu plan
   ```

## Usage

- **Add a VM:** create `inventory/<name>.yaml` (the file name becomes the VM
  name and hostname — DNS label rules apply) and `tofu apply`. See
  `inventory/example.yaml` for every knob including snapshot pinning and the
  docker role.
- **Remove a VM:** `git mv inventory/<name>.yaml inventory/destroy/` and
  `tofu apply` — only `inventory/*.yaml` is scanned, so the spec stays in the
  repo while the VM, its disk, and its snippet are destroyed. Moving it back
  provisions a fresh VM (all guest data is gone). To keep a VM but power it
  off, set `started: false` instead.
- **Roles:** a role is up to two files under `cloud-init/roles/` — a YAML
  fragment for extra top-level cloud-config keys and a
  `<role>.runcmd.json.tftpl` for commands. Either is optional, but a named
  role must have at least one. A fragment must never emit a top-level key
  `base.yaml.tftpl` already emits (cloud-init silently drops one of a
  duplicated pair — this is why role commands are a separate file).
- **After touching anything under `cloud-init/`:** run
  `./scripts/check-cloud-init.sh`.
- **Prove a rebuild is identical:**
  `./scripts/vm-fingerprint.sh ubuntu@<ip> fingerprints/<name>.txt` captures
  the VM's environment (packages, apt config, enabled units, users — minus
  per-instance noise like host keys and machine-id) into a tracked file.
  Capture, commit, destroy + reprovision, capture again to the same path:
  an empty `git diff` is the proof.

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
