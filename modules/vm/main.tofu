# modules/vm/main.tofu

locals {
  fqdn = var.spec.dns_domain == null ? var.vm_name : "${var.vm_name}.${var.spec.dns_domain}"

  # The VM resource blocks on the guest agent reporting an address, so the agent
  # package is not optional.
  ci_packages = distinct(concat(["qemu-guest-agent"], var.spec.packages))

  # Always applied, never left to inventory: the foreign-VM guard keys off it.
  # Sorted because ProxMox normalizes tag order; an unsorted list here would
  # read back differently and produce a perpetual diff.
  tags = sort(distinct(concat([var.managed_tag], var.spec.tags)))

  # The runcmd list lives in cloud-init/base.runcmd.json.tftpl rather than in
  # HCL so that scripts/check-cloud-init.sh renders the exact same source this
  # module does; a hand-copied literal in the check script is how commands
  # escaped validation before.
  runcmd = jsondecode(
    templatefile("${var.cloud_init_dir}/base.runcmd.json.tftpl", {
      ci_user = var.ci_user
      vm_name = var.vm_name
    })
  )

  base_user_data = templatefile("${var.cloud_init_dir}/base.yaml.tftpl", {
    vm_name          = var.vm_name
    fqdn             = local.fqdn
    timezone         = var.ci_timezone
    ci_user          = var.ci_user
    ssh_public_keys  = var.ssh_public_keys
    packages         = local.ci_packages
    runcmd           = local.runcmd
    archive_snapshot = var.spec.archive_snapshot
    package_upgrade  = var.spec.package_upgrade
  })

  user_data = trimspace(local.base_user_data)
}

# Uploaded over SSH: the ProxMox API exposes no endpoint for snippets.
#
# The snippet's ID is derived from its (stable) file name, so editing a
# cloud-init template re-uploads the snippet but shows "0 to change" on the VM
# - the running guest keeps whatever it booted with. Template changes reach a
# VM only by recreating it (delete the inventory file, apply, restore, apply).
resource "proxmox_virtual_environment_file" "user_data" {
  node_name    = var.pve_node
  datastore_id = var.snippet_datastore
  content_type = "snippets"

  source_raw {
    file_name = "${var.vm_name}-user-data.yaml"
    data      = local.user_data
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  node_name   = var.pve_node
  vm_id       = var.spec.vm_id
  name        = var.vm_name
  description = coalesce(var.spec.description, "Managed by OpenTofu")
  tags        = local.tags

  started         = var.spec.started
  on_boot         = var.spec.on_boot
  stop_on_destroy = true

  # Needed to read back the guest's address; destroy does not depend on it
  # because stop_on_destroy above is a hard stop. The timeout matches the
  # resource's 30-minute create timeout - the agent wait is the binding
  # constraint on first boot, which includes a full package_upgrade.
  agent {
    enabled = true
    trim    = true
    timeout = "30m"
  }

  cpu {
    cores = var.spec.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.spec.memory_mb
  }

  # virtio-scsi-single is what makes the per-disk iothread below meaningful.
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]

  # Pointing file_id at the existing image makes ProxMox import and convert it
  # into the target datastore; the source image is left untouched. file_id is
  # ignore_changes'd below: it only matters at creation, and without that a
  # bump of the fleet-wide cloud_image_file_id would diff - and destroy/create
  # - every existing VM's disk at once.
  disk {
    datastore_id = var.disk_datastore
    file_id      = var.cloud_image_file_id
    interface    = "scsi0"
    size         = var.spec.disk_gb
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  initialization {
    datastore_id      = var.disk_datastore
    interface         = "ide2"
    user_data_file_id = proxmox_virtual_environment_file.user_data.id

    ip_config {
      ipv4 {
        address = var.spec.ipv4
        gateway = var.spec.gateway
      }
    }

    # Omitted entirely when unset, so the guest inherits the node's resolvers.
    dynamic "dns" {
      for_each = length(var.spec.dns_servers) > 0 || var.spec.dns_domain != null ? [1] : []

      content {
        servers = var.spec.dns_servers
        domain  = var.spec.dns_domain
      }
    }
  }

  network_device {
    bridge  = var.network_bridge
    vlan_id = var.spec.vlan_id
  }

  operating_system {
    type = "l26"
  }

  # Ubuntu cloud images expect a serial console; without one `qm terminal` and
  # the early boot log are unavailable.
  serial_device {}

  # Three layers of protection for the VMs that predate this project. These fail
  # the plan, unlike a check block, which would only warn.
  lifecycle {
    ignore_changes = [disk[0].file_id]

    precondition {
      condition     = !contains(var.duplicate_vm_ids, var.spec.vm_id)
      error_message = "VMID ${var.spec.vm_id} appears in more than one inventory file; a collision would fail halfway through apply."
    }

    precondition {
      condition     = var.spec.vm_id >= var.managed_vmid_min
      error_message = "VMID ${var.spec.vm_id} is below the managed floor of ${var.managed_vmid_min}; IDs under it are hand-built and off limits."
    }

    precondition {
      condition     = !contains(keys(var.protected_vm_ids), tostring(var.spec.vm_id))
      error_message = "VMID ${var.spec.vm_id} is ${lookup(var.protected_vm_ids, tostring(var.spec.vm_id), "reserved")}, built before this project and never managed by it."
    }

    precondition {
      condition     = !contains(var.foreign_vm_ids, var.spec.vm_id)
      error_message = "VMID ${var.spec.vm_id} already exists on the node and is not tagged '${var.managed_tag}', so it is not ours to manage."
    }
  }
}
