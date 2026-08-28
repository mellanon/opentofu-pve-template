# Contributing

Thanks for contributing! This repo is a generic, reusable template — it must
work for anyone's ProxMox environment, so it contains **no real site data**.

## Workflow

1. Fork the repo and create a branch from `main`.
2. Make your change and test it (see below).
3. Open a pull request. `main` is protected — all changes land via PR, and CI
   must pass.

## Placeholder conventions

Never commit values from a real environment — yours or anyone else's. Use the
repo's placeholders consistently:

- IP addresses: the `10.0.0.x` range (e.g. `10.0.0.10` for the node,
  `10.0.0.50` for a VM).
- SSH key comments: `user@desktop`, `user@provisioner`.
- Timezone: `Etc/UTC`.
- Datastores: `local` (dir), `local-lvm` (lvmthin).
- Anywhere a user must substitute their own value, mark the line with an
  `EDIT:` comment — grep for `EDIT` to see the existing ones.

CI and review will reject PRs containing real hostnames, LAN addresses, keys,
or tokens.

## Testing your change

With a ProxMox node of your own: copy `terraform.tfvars.example` to
`terraform.tfvars`, fill in the `EDIT` values (see README.md for the full
setup, including `secrets.enc.json` — layout in `secrets.enc.json.example`),
then `source tofu.env` and use `inventory-example.yaml` as a starting spec.
You will also need a golden image on the node — `./scripts/build-image.sh
--upload` builds and uploads one; see README.md, "Building the golden image".

Without a node, run what CI runs:

```sh
export TF_VAR_state_passphrase=ci-dummy-passphrase-render-only
tofu init -input=false
tofu validate
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook ansible/site.yaml --syntax-check -i localhost,
(cd ansible && ansible-lint)
```

The dummy passphrase satisfies the state-encryption config for read-only
rendering; no state is created or read.

`check-ansible.sh` needs an applied state (it inspects the live inventory), so
it only runs against a real environment; CI covers the state-independent parts
(syntax check and lint). Run the full script if you have a node.

## Style

- Any collection beyond `ansible.builtin` must be pinned in
  `ansible/requirements.yml` in the same change that uses it. CI installs
  `ansible-core`, which ships none, so an unpinned `community.*` task passes
  locally and fails there.
- Ansible role names use underscores; each is a directory under
  `ansible/roles/`. Pin software versions in the role's `defaults/main.yaml`.
- Keep guard behavior intact: `guards.tofu` and the validations in
  `modules/vm-pve/variables.tofu` exist to protect pre-existing VMs and must not
  be weakened.
