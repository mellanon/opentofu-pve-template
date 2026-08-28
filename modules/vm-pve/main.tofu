# modules/vm-pve/main.tofu

locals {
  # Always applied, never left to inventory: the foreign-VM guard keys off it.
  # Sorted because ProxMox normalizes tag order; an unsorted list here would
  # read back differently and produce a perpetual diff.
  tags = sort(distinct(concat([var.managed_tag], var.spec.tags)))
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

  # import_from, not file_id. Both make ProxMox import and convert the image
  # into the target datastore and leave the source untouched, but file_id goes
  # through the provider's "custom disk" path, which shells out to `qm` over
  # SSH as root - the very dependency this design removes. import_from uses
  # PVE's native import-from API parameter instead.
  #
  # It is create-only (the provider ignores later changes) and ignore_changes'd
  # anyway: without that, bumping the fleet-wide cloud_image_file_id would diff
  # - and destroy/create - every existing VM's disk at once.
  disk {
    datastore_id = var.disk_datastore
    import_from  = var.cloud_image_file_id
    interface    = "scsi0"
    size         = var.spec.disk_gb
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # PVE's native cloud-init: these are VM config, written to the ci drive by the
  # node, so there is no snippet and no SSH to the hypervisor. Everything softer
  # - packages, timezone, apt pinning - is ansible's job (layer 2).
  #
  # Unlike the snippet this replaced, changing a value here DOES diff and PVE
  # regenerates the drive. That still does not reach a running guest: cloud-init
  # consumes the drive on first boot only. Rotating a key on a live VM means
  # ansible or a rebuild.
  initialization {
    datastore_id = var.disk_datastore
    interface    = "ide2"

    # PVE fills in the rest from the distro default user (`users: - default`),
    # which is where sudo, lock_passwd and the group list come from.
    user_account {
      username = var.ci_user
      keys     = var.ssh_public_keys
    }

    # Stated explicitly because PVE defaults ciupgrade to 1 and the provider's
    # schema default is Computed - leaving it unset is not a pin, and the
    # default is the opposite of what spec.package_upgrade defaults to.
    upgrade = var.spec.package_upgrade

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
    ignore_changes = [disk[0].import_from]

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
