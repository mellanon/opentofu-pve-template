# versions.tofu

terraform {
  # 1.10 floor: variables inside the encryption block and cross-variable
  # references in validations both postdate 1.7. Tested on 1.12.5.
  required_version = ">= 1.10, < 2.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }

    sops = {
      source  = "carlpett/sops"
      version = "1.4.1"
    }
  }
}
