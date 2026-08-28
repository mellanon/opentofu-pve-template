# modules/vm-pve/versions.tofu
#
# A child module must name its provider source; without this OpenTofu assumes
# hashicorp/proxmox and init fails.

terraform {
  # Matches the root: the cross-variable validations in variables.tofu need
  # OpenTofu 1.9+; tested on 1.12.
  required_version = ">= 1.10, < 2.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}
