# encryption.tofu

terraform {
  encryption {
    # pbkdf2 stores its salt in the state's meta section under a key. Without
    # an alias that key is the provider's own address, which welds the block
    # name to every byte it ever encrypted; the stable alias below is what
    # makes passphrase rotation a pure secrets-file operation.
    key_provider "pbkdf2" "main" {
      passphrase               = var.state_passphrase
      encrypted_metadata_alias = "state"
    }

    # Standing rotation slot. Writes always use main; previous is only ever
    # tried when decrypting something main cannot. Outside a rotation window
    # it holds a placeholder and is never consulted. Rotation procedure:
    # README.md, "Rotating the state passphrase".
    key_provider "pbkdf2" "previous" {
      passphrase               = var.state_passphrase_previous
      encrypted_metadata_alias = "state"
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    method "aes_gcm" "previous" {
      keys = key_provider.pbkdf2.previous
    }

    # enforced: refuse to ever read or write plaintext state/plans, rather than
    # falling back silently if this block stops resolving.
    state {
      method   = method.aes_gcm.main
      enforced = true

      fallback {
        method = method.aes_gcm.previous
      }
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true

      fallback {
        method = method.aes_gcm.previous
      }
    }
  }
}

variable "state_passphrase" {
  type      = string
  sensitive = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters (the pbkdf2 minimum). An empty value usually means tofu.env was not sourced or sops failed to decrypt."
  }
}

variable "state_passphrase_previous" {
  description = "Pre-rotation passphrase, tried only when the current one cannot decrypt. Holds a placeholder outside rotation windows; sourced from secrets.enc.json state.passphrase_previous by tofu.env."
  type        = string
  sensitive   = true
  default     = "rotation-placeholder-unused"

  validation {
    condition     = length(var.state_passphrase_previous) >= 16
    error_message = "state_passphrase_previous must be at least 16 characters (the pbkdf2 minimum)."
  }
}
