# vms.tofu
#
# One YAML file per VM in inventory/. Provisioning is adding a file;
# deprovisioning is deleting one.

locals {
  inventory_dir = "${path.module}/inventory"

  vms = {
    for file_name in fileset(local.inventory_dir, "*.yaml") :
    trimsuffix(file_name, ".yaml") => yamldecode(file("${local.inventory_dir}/${file_name}"))
  }

  # Two inventory files claiming the same vm_id would both plan cleanly and
  # then collide halfway through apply; a module precondition turns that into
  # a plan-time failure naming the ID.
  duplicate_vm_ids = [
    for id in distinct([for vm in local.vms : vm.vm_id]) :
    id if length([for vm in local.vms : vm.vm_id if vm.vm_id == id]) > 1
  ]
}

module "vm" {
  source   = "./modules/vm"
  for_each = local.vms

  vm_name = each.key
  spec    = each.value

  # Fleet-wide settings, stated once here rather than repeated per inventory file.
  cloud_init_dir      = "${path.module}/cloud-init"
  ansible_dir         = "${path.module}/ansible"
  pve_node            = var.pve_node
  cloud_image_file_id = var.cloud_image_file_id
  snippet_datastore   = var.snippet_datastore
  disk_datastore      = var.disk_datastore
  network_bridge      = var.network_bridge
  ssh_public_keys     = var.ssh_public_keys
  ci_user             = var.ci_user
  ci_timezone         = var.ci_timezone

  managed_tag      = local.managed_tag
  managed_vmid_min = var.managed_vmid_min
  protected_vm_ids = var.protected_vm_ids
  foreign_vm_ids   = local.foreign_vm_ids
  duplicate_vm_ids = local.duplicate_vm_ids
}
