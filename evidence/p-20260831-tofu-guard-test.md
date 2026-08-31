**Prediction**: Guard system will fail "tofu apply" because hypervisor state is different than configuration state

```sh
❯ diff guards.tofu guards.tofu.new
37,38d36
<     "100" = "100-template"
<     "101" = "101-template"
40,42c38
<     "202" = "202-dev"
<     "203" = "203-test"
<     "204" = "204-test"
---
>     "202" = "202-test"
52c48
<       for id in ["100", "101", "201", "202", "203", "204", "301", "302"] :
---
>       for id in ["201", "202", "301", "302"] :
```

**Result**: Pass, although the final phrase about the token is a bit misleading.

```sh
❯ mv inventory/ubuntu-test.yaml inventory/destroy/

❯ tofu apply
Acquiring state lock. This may take a few moments...
data.sops_file.secrets: Reading...
data.sops_file.secrets: Read complete after 0s [id=-]
data.proxmox_virtual_environment_vms.all: Reading...
data.proxmox_virtual_environment_nodes.available: Reading...
data.proxmox_virtual_environment_nodes.available: Read complete after 0s [id=nodes]
data.proxmox_virtual_environment_vms.all: Read complete after 1s [id=990ab9d1-407e-4685-ade1-3380a88f3ae6]

Planning failed. OpenTofu encountered an error while generating this plan.

╷
│ Error: Resource postcondition failed
│
│   on guards.tofu line 68, in data "proxmox_virtual_environment_vms" "all":
│   68:       condition = alltrue([
│   69:         for id in keys(var.protected_vm_ids) :
│   70:         contains([for vm in self.vms : tostring(vm.vm_id)], id)
│   71:       ])
│     ├────────────────
│     │ self.vms is list of object with 5 elements
│     │ var.protected_vm_ids is map of string with 8 elements
│
│ The VM listing from the node is missing at least one protected VMID (100, 101, 201, 202,
│ 203, 204, 301, 302). The API token can no longer see the whole node, so the foreign-VM
│ guard cannot be trusted; fix the token's ACL before planning.
╵
```

