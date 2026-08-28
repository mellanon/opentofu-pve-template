# providers.tofu

provider "sops" {}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = local.proxmox_api_token

  # The node serves a self-signed certificate. Every API call carries the
  # token, so this trades MITM exposure on the LAN for convenience; installing
  # the node's CA into this workstation's trust store is what removes it.
  insecure = true

  # No ssh block, deliberately. The provider only ever needed SSH to upload
  # cloud-init snippets, which the API cannot do; with the snippet gone there
  # is nothing left that is not an API call, and root on the hypervisor is no
  # longer a credential this project holds.
}
