# modules/vm-pve/outputs.tofu

output "vm_id" {
  description = "VMID of the provisioned VM."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "Name of the provisioned VM."
  value       = proxmox_virtual_environment_vm.this.name
}

locals {
  # The guest agent reports one address list per interface, and
  # ipv4_addresses / mac_addresses / network_interface_names share that
  # ordering. Select by the MAC of the NIC this module created, rather than
  # flattening every interface and filtering what is obviously not wanted.
  #
  # Flattening was wrong as soon as a role installed docker: the guest grew a
  # docker0 at 172.17.0.1, and the ansible inventory takes element 0 as
  # ansible_host. It happens to still be right here because the agent lists
  # eth0 first, which is luck, not a guarantee.
  #
  # Matching the MAC rather than filtering addresses or names is what makes
  # this robust: docker's bridge address is configurable (daemon.json bip),
  # podman/libvirt/CNI each bring their own ranges, and interface names vary
  # by image (eth0, ens18, enp0s18, br-*, veth*). None of them can present the
  # MAC ProxMox assigned to net0.
  #
  # A for-expression rather than index(): it yields an empty list when the
  # agent has not reported yet, where index() would raise. The inventory
  # already treats "no address" as skip-with-a-notice.
  nic_ipv4 = flatten([
    for i, mac in proxmox_virtual_environment_vm.this.mac_addresses :
    proxmox_virtual_environment_vm.this.ipv4_addresses[i]
    if lower(mac) == lower(proxmox_virtual_environment_vm.this.network_device[0].mac_address)
  ])
}

output "ipv4_addresses" {
  description = "IPv4 addresses the guest agent reports for this VM's own NIC. Excludes loopback and any bridge a layer-2 role brings with it."
  value       = local.nic_ipv4
}

output "ansible_roles" {
  description = "Ansible roles the spec declares for this VM (layer 2)."
  value       = var.spec.ansible_roles
}

# Passed through to the ansible inventory, which is what applies them now that
# there is no cloud-init snippet.
output "packages" {
  description = "apt packages the spec declares for this VM (layer 2)."
  value       = var.spec.packages
}

output "archive_snapshot" {
  description = "snapshot.ubuntu.com ID the spec pins apt to, or null (layer 2)."
  value       = var.spec.archive_snapshot
}

output "ssh_command" {
  description = "Ready-to-run SSH command for the cloud-init user."
  value       = format("ssh %s@%s", var.ci_user, try(local.nic_ipv4[0], "<pending>"))
}
