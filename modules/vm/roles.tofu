# modules/vm/roles.tofu
#
# base.yaml.tftpl owns the `runcmd` key, so a role's YAML fragment cannot emit
# it without producing a duplicate top-level key. Commands a role needs after
# its packages are installed live in cloud-init/roles/<role>.runcmd.json.tftpl
# instead, composed into base's runcmd list here.
#
# A role is therefore up to two pieces, both under cloud-init/roles/: a YAML
# fragment (<role>.yaml.tftpl) for additional top-level keys, and a runcmd file
# (<role>.runcmd.json.tftpl) for commands. Either piece is optional, but a role
# must have at least one - variables.tofu validates that.
#
# The runcmd files live under cloud-init/ rather than in HCL so that
# scripts/check-cloud-init.sh renders the exact same source the module does;
# a hand-copied literal in the check script is how role commands escaped
# validation before.

locals {
  runcmd_vars = { ci_user = var.ci_user, vm_name = var.vm_name }

  base_runcmd = jsondecode(
    templatefile("${var.cloud_init_dir}/base.runcmd.json.tftpl", local.runcmd_vars)
  )

  role_runcmd_file = var.spec.role == null ? null : "${var.cloud_init_dir}/roles/${var.spec.role}.runcmd.json.tftpl"

  role_runcmd = local.role_runcmd_file == null || !fileexists(coalesce(local.role_runcmd_file, "-")) ? [] : jsondecode(
    templatefile(local.role_runcmd_file, local.runcmd_vars)
  )

  runcmd = concat(local.base_runcmd, local.role_runcmd)
}
