# outputs.tofu

output "nodes" {
  description = "Nodes visible to the configured API token."
  value       = data.proxmox_virtual_environment_nodes.available.names
}

output "vms" {
  description = "Provisioned VMs, keyed by inventory name."
  value = {
    for name, vm in module.vm-pve : name => {
      vm_id          = vm.vm_id
      ipv4_addresses = vm.ipv4_addresses
      ssh_command    = vm.ssh_command
      ansible_roles  = vm.ansible_roles
      ansible_user   = var.ci_user

      # Layer 2 inputs: ansible/inventory/tofu.py turns these into hostvars,
      # and the base role applies them. They are here rather than in the
      # cloud-init drive because ansible can re-apply them to a running VM.
      packages         = vm.packages
      archive_snapshot = vm.archive_snapshot
      timezone         = var.ci_timezone
    }
  }
}

output "protected_vm_ids" {
  description = "VMIDs this configuration refuses to manage."
  value       = var.protected_vm_ids
}
