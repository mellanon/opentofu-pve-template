# outputs.tofu

output "nodes" {
  description = "Nodes visible to the configured API token."
  value       = data.proxmox_virtual_environment_nodes.available.names
}

output "vms" {
  description = "Provisioned VMs, keyed by inventory name."
  value = {
    for name, vm in module.vm : name => {
      vm_id          = vm.vm_id
      ipv4_addresses = vm.ipv4_addresses
      ssh_command    = vm.ssh_command
      ansible_roles  = vm.ansible_roles
      ansible_user   = var.ci_user
    }
  }
}

output "protected_vm_ids" {
  description = "VMIDs this configuration refuses to manage."
  value       = var.protected_vm_ids
}
