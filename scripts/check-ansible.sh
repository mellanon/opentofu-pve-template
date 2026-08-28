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
if [ -z "${ANSIBLE_COLLECTIONS_PATH:-}" ]; then
  echo "ANSIBLE_COLLECTIONS_PATH is not set; run 'source tofu.env' first" >&2
  exit 1
fi
export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"

status=0

# 1. Collections: every pin in ansible/requirements.yml installed, at exactly
#    the pinned version. Nothing else supplies them - requirements.txt pins
#    ansible-core, which ships none - and without this check a missing or
#    stale collection surfaces only as an opaque ansible-lint
#    "couldn't resolve module/action" three checks later.
if python3 -c '
import json, sys
from pathlib import Path
import yaml

root = Path(sys.argv[1]) / "ansible_collections"
pins = yaml.safe_load(Path("ansible/requirements.yml").read_text())["collections"]
for pin in pins:
    fqcn = pin["name"]
    manifest = root / Path(fqcn.replace(".", "/")) / "MANIFEST.json"
    if not manifest.is_file():
        sys.exit(f"{fqcn} is not installed - run ./scripts/install-collections.sh")
    want = pin["version"]
    found = json.loads(manifest.read_text())["collection_info"]["version"]
    if found != want:
        sys.exit(f"{fqcn} is {found}, pinned at {want} - run ./scripts/install-collections.sh")
print(f"ok    collections ({len(pins)} pinned)")
' "$ANSIBLE_COLLECTIONS_PATH"; then
  :
else
  echo "FAIL  collections" >&2
  status=1
fi

# 2. Inventory: valid JSON with the hostvars site.yaml and the roles rely on,
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

# 3. Playbook syntax.
if ansible-playbook ansible/site.yaml --syntax-check >/dev/null; then
  echo "ok    site.yaml syntax"
else
  echo "FAIL  site.yaml syntax" >&2
  status=1
fi

# 4. Lint, when available.
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
