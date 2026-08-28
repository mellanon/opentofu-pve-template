#!/usr/bin/env python3
"""Dynamic Ansible inventory sourced from `tofu output -json vms`.

The tofu state is the single source of truth for what exists and where it
listens; specs (inventory/*.yaml) declare which ansible roles each VM gets,
and that list rides along through the module outputs. This script just
reshapes `tofu output -json vms` into inventory JSON:

  - one host per VM, named by inventory name (so --limit <name> works)
  - group "vms" holding every reachable VM
  - one group per declared role, for ad-hoc targeting (ansible bun -m ...)
  - hostvars: ansible_host (the VM's own NIC, per the module output),
    ansible_user,
    vm_id, vm_ansible_roles (what site.yaml applies), and the three the base
    role consumes: vm_packages, vm_archive_snapshot (may be None), vm_timezone

A VM with no reported address (powered off, or agent not up yet) is skipped
with a notice on stderr: an unreachable-by-design host in inventory would
turn every fleet run red.

Deliberately does not source tofu.env itself: sourcing it is the repo's one
universal session precondition, and hiding it here would fork the convention.

Python stdlib only.
"""

import json
import subprocess
import sys
from os import environ
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def fail(message):
    print(f"tofu.py inventory: {message}", file=sys.stderr)
    sys.exit(1)


def tofu_vms():
    if "TF_VAR_state_passphrase" not in environ:
        fail("TF_VAR_state_passphrase is not set - run 'source tofu.env' from the repo root first")
    result = subprocess.run(
        ["tofu", "output", "-json", "vms"],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    if result.returncode != 0:
        fail(f"'tofu output -json vms' failed:\n{result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as err:
        fail(f"'tofu output -json vms' produced invalid JSON: {err}")


def build_inventory():
    inventory = {
        "_meta": {"hostvars": {}},
        "vms": {"hosts": []},
    }
    for name, vm in sorted(tofu_vms().items()):
        addresses = vm.get("ipv4_addresses", [])
        if not addresses:
            print(
                f"tofu.py inventory: skipping {name} (vm_id {vm['vm_id']}): "
                "no address reported - powered off or guest agent not up",
                file=sys.stderr,
            )
            continue
        inventory["_meta"]["hostvars"][name] = {
            "ansible_host": addresses[0],
            "ansible_user": vm["ansible_user"],
            "vm_id": vm["vm_id"],
            "vm_ansible_roles": vm.get("ansible_roles", []),
            # Applied by the base role rather than at first boot, which is why
            # they ride the inventory instead of the cloud-init drive.
            "vm_packages": vm.get("packages", []),
            "vm_archive_snapshot": vm.get("archive_snapshot"),
            "vm_timezone": vm["timezone"],
        }
        inventory["vms"]["hosts"].append(name)
        for role in vm.get("ansible_roles", []):
            inventory.setdefault(role, {"hosts": []})["hosts"].append(name)
    return inventory


def main():
    args = sys.argv[1:]
    if args[:1] == ["--host"]:
        print("{}")  # all hostvars are served via _meta
    else:
        print(json.dumps(build_inventory(), indent=2))


if __name__ == "__main__":
    main()
