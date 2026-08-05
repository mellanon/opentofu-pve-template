# OpenTofu provisioning for ProxMox VE

Infrastructure as code for provisioning and deprovisioning VMs on ProxMox VE.
Three layers: OpenTofu drives the hypervisor, cloud-init gives the guest its
boot-time identity, and Ansible installs software post-boot.
See README.md for setup; this file is what a working session needs that is not
obvious from reading the code.

## Environment

Template placeholders — fill in for your site (marked `EDIT` in the code):

- ProxMox node name/endpoint: `variables.tofu` (`pve_node`, `pve_endpoint`).
- Datastores: snippets need a dir datastore with the `snippets` content type;
  lvmthin cannot hold them.
- Base image: referenced directly as a disk `file_id`, so ProxMox imports and
  converts it; there is no `download_file` resource.
- Secrets: `secrets.enc.json`, age via sops, key at
  `~/.config/sops/age/keys.txt`. Holds the API token and the state passphrase.

## Hard rules

**Pre-existing VMs must never be touched.** `guards.tofu` plus lifecycle
preconditions in `modules/vm/main.tofu` enforce a VMID floor, a named protected
list, and a live check that rejects any VMID belonging to a VM not tagged
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
by convention, `git mv` it to `inventory/destroy/` (only `inventory/*.yaml` is
scanned; subdirectories are invisible). The next apply destroys the VM, its
disk, and its snippet; moving the file back provisions a *fresh* VM. To keep a
VM and its data but power it off, set `started: false` instead. The filename
is the VM name (DNS label). Only `vm_id` is required — everything else takes
an `optional()` default from the `spec` object in `modules/vm/variables.tofu`,
which is the contract worth reading first.

After touching anything under `cloud-init/`, run
`./scripts/check-cloud-init.sh`. `tofu validate` checks HCL and structurally
never sees the YAML that comes out of `templatefile()`.

**Layer 2 — Ansible.** Cloud-init is decided at first boot and reachable only
by recreating the VM; everything softer — installed software and its config —
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
`defaults/main.yaml`. Removing a role from the list does **not** uninstall it —
clean removal is a rebuild. Runs are idempotent (second run reports
changed=0). After touching anything under `ansible/`, run
`./scripts/check-ansible.sh`.

`./scripts/vm-fingerprint.sh <user>@<ip> fingerprints/<name>.txt` captures a
VM's environment fingerprint (packages, apt config, enabled units, users, and
the ansible-installed layer-2 files under `~/.local` and `~/.bun` — excluding
per-instance noise like host keys and machine-id) into a tracked file.
Rebuild verification: capture, commit, destroy + reprovision, run
`ansible-playbook ansible/site.yaml`, capture to the same path — an empty
`git diff` proves the environment is identical.

## Gotchas that have already cost time

- **Snippets need SSH.** The ProxMox API has no snippets endpoint, so the
  provider uploads cloud-init user-data over SSH as root using
  `pve_ssh_private_key_path`. Everything else goes over the API token.
- **The file resource also needs `Datastore.Allocate` on the snippet
  datastore.** Before the SSH upload, the provider reads the storage config
  via `GET /storage/<id>`, which PVE gates behind the full admin privilege —
  `AllocateSpace`/`AllocateTemplate` are not enough (HTTP 403 at apply).
  Grant it via a role scoped to the snippet datastore, and give that role the
  *complete* `Datastore.*` set: PVE ACLs on a more specific path **override**
  the propagated role instead of merging with it.
- **An `@pve`-realm token cannot SSH anywhere.** It exists only in ProxMox's
  user database — it is not a Linux account. The API identity and the SSH
  identity can never be unified.
- **A cloud-config is one YAML mapping; duplicate top-level keys get silently
  dropped.** That is why `base.yaml.tftpl` is the entire document and nothing
  is ever appended to it — post-boot software belongs in an ansible role, not
  in cloud-init.
- **Every scalar interpolated into a cloud-init template must be
  `jsonencode()`d.** JSON is a YAML subset; a raw SSH key comment containing
  `: ` becomes a YAML mapping (VM boots with no authorized keys), a package
  containing `#` is silently truncated, and a VM named `no` becomes a boolean
  hostname. `check-cloud-init.sh` has an adversarial pass that regresses this.
- **Editing cloud-init templates does not diff the VM.** The snippet
  re-uploads but its ID (derived from the stable file name) is unchanged, so
  the plan shows "0 to change" and running guests keep what they booted with.
  Reaching an existing VM means recreating it: delete its inventory file,
  apply, restore, apply.
- **Repeatability knobs live per-VM in the spec.** `archive_snapshot:
  YYYYMMDDTHHMMSSZ` pins apt to snapshot.ubuntu.com via a `bootcmd` that
  writes `APT::Snapshot` into apt.conf.d (bootcmd runs init-stage, before
  apt-configure and package install; an apt.conf.d file survives cloud-init
  regenerating `ubuntu.sources`). Official archive only — third-party repos
  like docker are not snapshotted, which is why the docker ansible role pins
  exact package versions in its defaults instead.
  `package_upgrade` defaults to **false**; `package_update: true`
  is explicit but not load-bearing — cloud-init refreshes indexes whenever
  `packages:` is non-empty. unattended-upgrades is disabled fleet-wide (the
  image ships it enabled): base's `bootcmd` zeros the `APT::Periodic` jobs and
  a base runcmd disables the apt-daily timers.
- **PyYAML's `safe_load` does not error on duplicate keys**, it keeps the last
  one. `scripts/check-cloud-init.sh` installs a custom loader for this reason.
- **`cloud-init schema` catches deprecations that still "work."** The check
  script treats deprecation warnings as failures.
- **A child module must declare its own `required_providers`** naming
  `bpg/proxmox`. Without `modules/vm/versions.tofu`, `tofu init` assumes
  `hashicorp/proxmox` and fails.
- **`agent { enabled = true }` makes apply block** until the guest agent
  reports an address. Quick with the default `package_upgrade: false`; with a
  VM that sets it true, expect several minutes (timeout is 30m).
- **zsh's `echo` expands `\n`**, which corrupts expressions piped to
  `tofu console`. Use a quoted heredoc.
- **`tofu console` output is double-encoded** when wrapping `jsonencode` — HCL
  string quoting on top of the JSON. Two decode passes.
- **Once a state file exists, `tofu console` prints "Acquiring state lock..."
  to STDOUT**, corrupting anything piped from it — hence `-lock=false` and
  the result-line filter in `check-cloud-init.sh`.
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
