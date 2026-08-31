**Operational receipt**: Verify new baseline is repeatable.

Note: Showing more of the output in this receipt to give an better idea of what it looks like. Only the hypervisor details provided by tofu for the specific VM are removed.

```sh
❯ source tofu.env

❯ mv inventory/ubuntu-test.yaml inventory/destroy/

❯ tofu apply
Acquiring state lock. This may take a few moments...
data.sops_file.secrets: Reading...
data.sops_file.secrets: Read complete after 0s [id=-]
data.proxmox_virtual_environment_nodes.available: Reading...
data.proxmox_virtual_environment_vms.all: Reading...
data.proxmox_virtual_environment_nodes.available: Read complete after 0s [id=nodes]
data.proxmox_virtual_environment_vms.all: Read complete after 0s [id=3ed77a7f-a928-46dd-9a6f-663b1c678868]
module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this: Refreshing state... [id=500]

OpenTofu used the selected providers to generate the following execution plan. Resource
actions are indicated with the following symbols:
  - destroy

OpenTofu will perform the following actions:

  # module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this will be destroyed
  # (because module.vm-pve["ubuntu-test"] is not in configuration)
<snip>

Plan: 0 to add, 0 to change, 1 to destroy.

Changes to Outputs:
  ~ vms              = {
      - ubuntu-test = {
          - ansible_roles    = [
              - "nats_server",
              - "bun",
              - "claude",
              - "docker",
              - "metafactory_arc",
            ]
          - ansible_user     = "ubuntu"
          - archive_snapshot = "20260721T000000Z"
          - ipv4_addresses   = [
              - "10.0.0.50",
            ]
          - packages         = [
              - "unzip",
              - "git",
              - "gh",
              - "tree",
            ]
          - ssh_command      = "ssh ubuntu@10.0.0.50"
          - timezone         = "Etc/UTC"
          - vm_id            = 500
        }
    }

Do you want to perform these actions?
  OpenTofu will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this: Destroying... [id=500]
module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this: Destruction complete after 2s

Apply complete! Resources: 0 added, 0 changed, 1 destroyed.

Outputs:

nodes = tolist([
  "pve",
])
protected_vm_ids = tomap({
 <snip>
})
vms = {}

❯ mv inventory/destroy/ubuntu-test.yaml inventory/

❯ tofu apply
Acquiring state lock. This may take a few moments...
data.sops_file.secrets: Reading...
data.sops_file.secrets: Read complete after 0s [id=-]
data.proxmox_virtual_environment_vms.all: Reading...
data.proxmox_virtual_environment_nodes.available: Reading...
data.proxmox_virtual_environment_nodes.available: Read complete after 0s [id=nodes]
data.proxmox_virtual_environment_vms.all: Read complete after 0s [id=d4e3e0d1-b235-4ebe-bcfe-ac30577b0f6f]

OpenTofu used the selected providers to generate the following execution plan. Resource
actions are indicated with the following symbols:
  + create

OpenTofu will perform the following actions:

  # module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this will be created
  + resource "proxmox_virtual_environment_vm" "this" {
<snip>

Plan: 1 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  ~ vms              = {
      + ubuntu-test = {
          + ansible_roles    = [
              + "nats_server",
              + "bun",
              + "claude",
              + "docker",
              + "metafactory_arc",
            ]
          + ansible_user     = "ubuntu"
          + archive_snapshot = "20260721T000000Z"
          + ipv4_addresses   = (known after apply)
          + packages         = [
              + "unzip",
              + "git",
              + "gh",
              + "tree",
            ]
          + ssh_command      = (known after apply)
          + timezone         = "Etc/UTC"
          + vm_id            = 500
        }
    }

Do you want to perform these actions?
  OpenTofu will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this: Creating...
module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this: Still creating... [10s elapsed]
module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this: Still creating... [20s elapsed]
module.vm-pve["ubuntu-test"].proxmox_virtual_environment_vm.this: Creation complete after 22s [id=500]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

nodes = tolist([
  "pve",
])
protected_vm_ids = tomap({
  <snip>
})
vms = {
  "ubuntu-test" = {
    "ansible_roles" = tolist([
      "nats_server",
      "bun",
      "claude",
      "docker",
      "metafactory_arc",
    ])
    "ansible_user" = "ubuntu"
    "archive_snapshot" = "20260721T000000Z"
    "ipv4_addresses" = [
      "10.0.0.50",
    ]
    "packages" = tolist([
      "unzip",
      "git",
      "gh",
      "tree",
    ])
    "ssh_command" = "ssh ubuntu@10.0.0.50"
    "timezone" = "Etc/UTC"
    "vm_id" = 500
  }
}

❯ ansible-playbook ansible/site.yaml --limit ubuntu-test

PLAY [Apply the fleet baseline and each VM's declared roles] *******************************

TASK [Gathering Facts] *********************************************************************
ok: [ubuntu-test]

TASK [base : Pin apt to the spec's archive snapshot] ***************************************
changed: [ubuntu-test]

TASK [base : Remove the apt snapshot pin when the spec has none] ***************************
skipping: [ubuntu-test]

TASK [base : Zero the apt periodic jobs] ***************************************************
changed: [ubuntu-test]

TASK [base : Stop and disable the apt-daily timers] ****************************************
ok: [ubuntu-test] => (item=apt-daily.timer)
ok: [ubuntu-test] => (item=apt-daily-upgrade.timer)

TASK [base : Mask the apt-daily timers] ****************************************************
changed: [ubuntu-test] => (item=apt-daily.timer)
changed: [ubuntu-test] => (item=apt-daily-upgrade.timer)

TASK [base : Enforce key-only SSH] *********************************************************
changed: [ubuntu-test]

TASK [base : Check the assembled sshd config is valid] *************************************
ok: [ubuntu-test]

TASK [base : Set the timezone] *************************************************************
ok: [ubuntu-test]

TASK [base : Install the spec's packages] **************************************************
changed: [ubuntu-test]

TASK [Include each role the VM's spec declares] ********************************************
included: nats_server for ubuntu-test => (item=nats_server)
included: bun for ubuntu-test => (item=bun)
included: claude for ubuntu-test => (item=claude)
included: docker for ubuntu-test => (item=docker)
included: metafactory_arc for ubuntu-test => (item=metafactory_arc)

TASK [nats_server : Probe installed nats-server version] ***********************************
ok: [ubuntu-test]

TASK [nats_server : Create scratch directory] **********************************************
changed: [ubuntu-test]

TASK [nats_server : Ensure ~/.local/bin exists] ********************************************
changed: [ubuntu-test]

TASK [nats_server : Download tarball, verified against upstream SHA256SUMS] ****************
changed: [ubuntu-test]

TASK [nats_server : Unpack] ****************************************************************
changed: [ubuntu-test]

TASK [nats_server : Install binary] ********************************************************
changed: [ubuntu-test]

TASK [nats_server : Remove scratch directory] **********************************************
changed: [ubuntu-test]

TASK [bun : Add ~/.bun/bin to the interactive shell PATH] **********************************
changed: [ubuntu-test]

TASK [bun : Probe installed bun version] ***************************************************
ok: [ubuntu-test]

TASK [bun : Probe for unzip (unarchive needs it for .zip)] *********************************
ok: [ubuntu-test]

TASK [bun : Refuse to continue without unzip] **********************************************
skipping: [ubuntu-test]

TASK [bun : Create scratch directory] ******************************************************
changed: [ubuntu-test]

TASK [bun : Ensure ~/.bun/bin exists] ******************************************************
changed: [ubuntu-test]

TASK [bun : Download zip, verified against upstream SHASUMS256.txt] ************************
changed: [ubuntu-test]

TASK [bun : Unpack] ************************************************************************
changed: [ubuntu-test]

TASK [bun : Install binary] ****************************************************************
changed: [ubuntu-test]

TASK [bun : Remove scratch directory] ******************************************************
changed: [ubuntu-test]

TASK [claude : Probe installed claude version binary] **************************************
ok: [ubuntu-test]

TASK [claude : Probe ~/.local/bin/claude symlink] ******************************************
ok: [ubuntu-test]

TASK [claude : Create scratch directory] ***************************************************
changed: [ubuntu-test]

TASK [claude : Fetch release manifest] *****************************************************
ok: [ubuntu-test]

TASK [claude : Check the manifest checksum is a plausible SHA256] **************************
ok: [ubuntu-test] => {
    "changed": false,
    "msg": "All assertions passed"
}

TASK [claude : Download binary, verified against the manifest checksum] ********************
changed: [ubuntu-test]

TASK [claude : Run the vendor installer] ***************************************************
changed: [ubuntu-test]

TASK [claude : Remove scratch directory] ***************************************************
changed: [ubuntu-test]

TASK [docker : Ensure /etc/apt/keyrings exists] ********************************************
ok: [ubuntu-test]

TASK [docker : Download Docker's signing key] **********************************************
[WARNING]: Module remote_tmp /root/.ansible/tmp did not exist and was created with a mode of 0700, this may cause issues when running as another user. To avoid this, create the remote_tmp dir with the correct permissions manually
changed: [ubuntu-test]

TASK [docker : Read the key's fingerprint] *************************************************
ok: [ubuntu-test]

TASK [docker : Check the key matches the pinned fingerprint] *******************************
ok: [ubuntu-test] => {
    "changed": false,
    "msg": "All assertions passed"
}

TASK [docker : Configure the docker apt repository (deb822)] *******************************
changed: [ubuntu-test]

TASK [docker : Install pinned docker packages] *********************************************
changed: [ubuntu-test]

TASK [docker : Configure the docker daemon] ************************************************
changed: [ubuntu-test]

TASK [docker : Add the login user to the docker group] *************************************
changed: [ubuntu-test]

TASK [metafactory_arc : Probe for bun (cross-role dependency)] *****************************
ok: [ubuntu-test]

TASK [metafactory_arc : Refuse to continue without bun] ************************************
skipping: [ubuntu-test]

TASK [metafactory_arc : Probe for git (layer-1 dependency)] ********************************
ok: [ubuntu-test]

TASK [metafactory_arc : Refuse to continue without git] ************************************
skipping: [ubuntu-test]

TASK [metafactory_arc : Clone arc at the pinned tag] ***************************************
changed: [ubuntu-test]

TASK [metafactory_arc : Probe the arc link] ************************************************
ok: [ubuntu-test]

TASK [metafactory_arc : Install production dependencies] ***********************************
changed: [ubuntu-test]

TASK [metafactory_arc : Link arc into ~/.bun/bin] ******************************************
changed: [ubuntu-test]

RUNNING HANDLER [base : Reload sshd] *******************************************************
changed: [ubuntu-test]

RUNNING HANDLER [docker : Restart docker] **************************************************
changed: [ubuntu-test]

PLAY RECAP *********************************************************************************
ubuntu-test                : ok=54   changed=32   unreachable=0    failed=0    skipped=4    rescued=0    ignored=0


❯ ./scripts/vm-fingerprint.sh ubuntu@10.0.0.50 fingerprints/new-baseline-retest.txt
fingerprint written to fingerprints/new-baseline-retest.txt
##### DIGESTS #####
core      sha256:76aece3866be7d81769e1c01658a9eb86a4498bba4b54705988045622eb005b7
provider  sha256:61cb3c9398c74f84c2994fc40c5f1c3a817ddbbddbe61e1fdde307820bb3e992
combined  sha256:138abcb51e9379f027706a72c782a61a4a0685607a851894c6abdee6c0613cb2

❯ diff fingerprints/new-baseline.txt fingerprints/new-baseline-retest.txt

❯
```

