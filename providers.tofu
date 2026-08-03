# providers.tofu

provider "sops" {}

locals {
  # Bare host for the SSH node pin, derived from the endpoint so the address
  # lives in exactly one place.
  pve_host = regex("^https?://([^:/]+)", var.pve_endpoint)[0]
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = local.proxmox_api_token

  # The node serves a self-signed certificate. Every API call carries the
  # token, so this trades MITM exposure on the LAN for convenience; installing
  # the node's CA into this workstation's trust store is what removes it.
  insecure = true

  ssh {
    username    = "root"
    private_key = file(pathexpand(var.pve_ssh_private_key_path))

    # Pin the node's address so uploads do not depend on "pve" resolving from
    # the workstation.
    node {
      name    = var.pve_node
      address = local.pve_host
    }
  }
}
