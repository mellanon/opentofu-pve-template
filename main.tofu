# main.tofu

data "sops_file" "secrets" {
  source_file = "${path.module}/secrets.enc.json"
}

locals {
  proxmox_api_token = format(
    "%s=%s",
    data.sops_file.secrets.data["proxmox.api_token_id"],
    data.sops_file.secrets.data["proxmox.api_token_secret"],
  )
}

data "proxmox_virtual_environment_nodes" "available" {}
