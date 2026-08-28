#!/usr/bin/env bash
# Validate the ansible layer: the dynamic inventory's shape and the site
# playbook's syntax. Run it after touching anything under ansible/.
#
# The inventory check needs the tofu state (that is where the fleet lives),
# so this requires `source tofu.env` first, same as everything else here.
#
# ansible-lint runs when installed but is not a dependency.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v ansible-playbook >/dev/null; then
  echo "missing ansible-playbook" >&2
  exit 1
fi
if [ -z "${TF_VAR_state_passphrase:-}" ]; then
  echo "TF_VAR_state_passphrase is not set; run 'source tofu.env' first so the inventory can read the tofu state" >&2
  exit 1
fi
export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"

status=0

# 1. Inventory: valid JSON with the hostvars site.yaml and the roles rely on,
#    and every declared role backed by a real role directory (belt and braces
#    with the tofu plan-time validation).
if ansible-inventory --list | python3 -c '
import json, sys
from pathlib import Path

inv = json.load(sys.stdin)
hostvars = inv.get("_meta", {}).get("hostvars", {})
if not hostvars:
    sys.exit("no reachable VMs in inventory - is the fleet applied and running?")
for host, hv in hostvars.items():
    for key in ("ansible_host", "ansible_user", "vm_ansible_roles",
                "vm_packages", "vm_archive_snapshot", "vm_timezone"):
        if key not in hv:
            sys.exit(f"{host}: hostvar {key!r} missing")
    for role in hv["vm_ansible_roles"]:
        if not Path(f"ansible/roles/{role}/tasks/main.yaml").is_file():
            sys.exit(f"{host}: declared role {role!r} has no ansible/roles/{role}/tasks/main.yaml")
print(f"ok    inventory ({len(hostvars)} host(s))")
'; then
  :
else
  echo "FAIL  inventory" >&2
  status=1
fi

# 2. Playbook syntax.
if ansible-playbook ansible/site.yaml --syntax-check >/dev/null; then
  echo "ok    site.yaml syntax"
else
  echo "FAIL  site.yaml syntax" >&2
  status=1
fi

# 3. Lint, when available.
if command -v ansible-lint >/dev/null; then
  if (cd ansible && ansible-lint) >/dev/null 2>&1; then
    echo "ok    ansible-lint"
  else
    echo "FAIL  ansible-lint" >&2
    status=1
  fi
else
  echo "skip  ansible-lint (not installed)"
fi

exit "$status"
