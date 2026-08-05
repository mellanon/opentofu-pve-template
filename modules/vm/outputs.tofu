# modules/vm/outputs.tofu

output "vm_id" {
  description = "VMID of the provisioned VM."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "Name of the provisioned VM."
  value       = proxmox_virtual_environment_vm.this.name
}

output "ipv4_addresses" {
  description = "Addresses reported by the guest agent, excluding loopback."
  value = [
    for addr in flatten(proxmox_virtual_environment_vm.this.ipv4_addresses) :
    addr if addr != "127.0.0.1"
  ]
}

output "ansible_roles" {
  description = "Ansible roles the spec declares for this VM (layer 2)."
  value       = var.spec.ansible_roles
}

output "ssh_command" {
  description = "Ready-to-run SSH command for the cloud-init user."
  value = format(
    "ssh %s@%s",
    var.ci_user,
    try(
      [
        for addr in flatten(proxmox_virtual_environment_vm.this.ipv4_addresses) :
        addr if addr != "127.0.0.1"
      ][0],
      "<pending>",
    ),
  )
}
