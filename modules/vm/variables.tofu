# modules/vm/variables.tofu

variable "vm_name" {
  description = "VM name, also used as the guest hostname. Comes from the inventory file name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.vm_name))
    error_message = "vm_name '${var.vm_name}' (the inventory file name) must be a DNS label: lowercase letters, digits, and hyphens, not starting or ending with a hyphen. It becomes the ProxMox VM name and the guest hostname."
  }
}

variable "spec" {
  description = <<-EOT
    Per-VM settings, decoded from inventory/<vm_name>.yaml. Only vm_id is
    required; the optional() defaults below are what an inventory file inherits
    by staying silent.
  EOT

  type = object({
    vm_id       = number
    role        = optional(string)
    description = optional(string)
    cpu_cores   = optional(number, 2)
    memory_mb   = optional(number, 4096)
    disk_gb     = optional(number, 32)
    ipv4        = optional(string, "dhcp")
    gateway     = optional(string)
    dns_servers = optional(list(string), [])
    dns_domain  = optional(string)
    vlan_id     = optional(number)
    packages    = optional(list(string), [])
    tags        = optional(list(string), [])
    started     = optional(bool, true)
    on_boot     = optional(bool, false)

    # snapshot.ubuntu.com ID (YYYYMMDDTHHMMSSZ). When set, apt on the guest is
    # pinned to the archive as of that instant for the VM's whole life, so
    # package installs are reproducible. Third-party repos (e.g. docker) have
    # no snapshot service and are not covered.
    archive_snapshot = optional(string)

    # Default false: with a fixed base image, skipping the upgrade is what
    # keeps environments identical over time (and first boot much faster).
    # true is also deterministic when archive_snapshot is set - the base
    # upgrades to the pinned date instead of to "now".
    package_upgrade = optional(bool, false)
  })

  validation {
    condition     = var.spec.vm_id >= 100
    error_message = "spec.vm_id must be >= 100; ProxMox reserves lower IDs."
  }

  validation {
    condition     = var.spec.disk_gb >= 4
    error_message = "spec.disk_gb must be >= 4; the cloud image is already 3.5 GiB and disks cannot shrink."
  }

  validation {
    condition     = var.spec.ipv4 == "dhcp" || can(cidrhost(var.spec.ipv4, 0))
    error_message = "spec.ipv4 must be 'dhcp' or CIDR notation like 10.0.0.50/24; a bare address would pass the plan and fail at the API."
  }

  validation {
    condition     = var.spec.role == null || can(regex("^[a-z0-9-]+$", var.spec.role))
    error_message = "spec.role must be a bare role name (lowercase letters, digits, hyphens); it selects files under cloud-init/roles/."
  }

  validation {
    condition     = var.spec.archive_snapshot == null || can(regex("^[0-9]{8}T[0-9]{6}Z$", var.spec.archive_snapshot))
    error_message = "spec.archive_snapshot must be a snapshot.ubuntu.com ID like 20260801T000000Z (UTC, YYYYMMDDTHHMMSSZ)."
  }

  validation {
    condition = var.spec.role == null || (
      fileexists("${var.cloud_init_dir}/roles/${var.spec.role}.yaml.tftpl") ||
      fileexists("${var.cloud_init_dir}/roles/${var.spec.role}.runcmd.json.tftpl")
    )
    error_message = "spec.role names no file under cloud-init/roles/ - expected <role>.yaml.tftpl and/or <role>.runcmd.json.tftpl. A typo here would otherwise silently drop the role's commands."
  }

  validation {
    condition     = var.spec.ipv4 != "dhcp" || var.spec.gateway == null
    error_message = "spec.gateway must be omitted when spec.ipv4 is 'dhcp'."
  }

  validation {
    condition     = var.spec.ipv4 == "dhcp" || var.spec.gateway != null
    error_message = "spec.gateway is required when spec.ipv4 is a static address."
  }
}

variable "cloud_init_dir" {
  description = "Directory holding base.yaml.tftpl and roles/. Passed in so the module does not reach out with ../.."
  type        = string
}

variable "pve_node" {
  description = "ProxMox node that hosts the VM."
  type        = string
}

variable "cloud_image_file_id" {
  description = "Datastore reference to the cloud image used as the disk source."
  type        = string
}

variable "snippet_datastore" {
  description = "Datastore holding cloud-init snippets. Must have the 'snippets' content type."
  type        = string
}

variable "disk_datastore" {
  description = "Datastore holding the VM disk and the cloud-init drive."
  type        = string
}

variable "network_bridge" {
  description = "Bridge the VM's NIC attaches to."
  type        = string
}

variable "ssh_public_keys" {
  description = "Public keys authorized for ci_user."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "Provide at least one public key; the cloud image has no default password."
  }
}

variable "ci_user" {
  description = "Login account created by cloud-init."
  type        = string
}

variable "ci_timezone" {
  description = "Timezone applied by cloud-init."
  type        = string
}

variable "managed_tag" {
  description = "Tag applied to every VM this configuration owns. Drives the foreign-VM guard."
  type        = string
}

variable "managed_vmid_min" {
  description = "Floor for managed VMIDs. Anything below is hand-built and off limits."
  type        = number
}

variable "protected_vm_ids" {
  description = "VMIDs built before this project, keyed by ID as a string. Never manage, never import."
  type        = map(string)
}

variable "foreign_vm_ids" {
  description = "VMIDs live on the node that are not tagged managed_tag."
  type        = list(number)
}

variable "duplicate_vm_ids" {
  description = "VMIDs claimed by more than one inventory file. Computed at the root; any membership fails the plan."
  type        = list(number)
}
