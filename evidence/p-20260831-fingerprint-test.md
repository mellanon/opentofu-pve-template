**Prediction**: Fingerprint system will document 2 changes. One for a change in SSH key for the new agent user on the provisioning system, and two for switching to the default UTC timezone.

```sh
❯ diff terraform.tfvars terraform.tfvars.old
<   "ssh-ed25519 AA<snip> human@desktop",    # main desktop
<   "ssh-ed25519 AA<snip> agent@new-server", # provisioning box
---
>   "ssh-ed25519 AA<snip> human@desktop", # main desktop
>   "ssh-ed25519 AA<snip> human@old-server",   # provisioning box
---
< # ci_timezone              = "Etc/UTC"
---
> # ci_timezone              = "America/Chicago"
```

**Result**: Pass

```sh
❯ ./scripts/vm-fingerprint.sh ubuntu@192.168.1.50 fingerprints/new-baseline.txt
fingerprint written to fingerprints/new-baseline.txt
##### DIGESTS #####
core      sha256:76aece3866be7d81769e1c01658a9eb86a4498bba4b54705988045622eb005b7
provider  sha256:61cb3c9398c74f84c2994fc40c5f1c3a817ddbbddbe61e1fdde307820bb3e992
combined  sha256:138abcb51e9379f027706a72c782a61a4a0685607a851894c6abdee6c0613cb2


❯ diff fingerprints/ubuntu-test.txt fingerprints/new-baseline.txt
11c11
< ../usr/share/zoneinfo/America/Chicago
---
> /usr/share/zoneinfo/Etc/UTC
821d820
< ssh-ed25519 AA<snip> human@old-server
822a822
> ssh-ed25519 AA<snip> agent@new-server
1901c1901
< core      sha256:55afa464d054bafacaca48935c64661c15f6c2fd95153272413bed533c2d3b27
---
> core      sha256:76aece3866be7d81769e1c01658a9eb86a4498bba4b54705988045622eb005b7
1903c1903
< combined  sha256:f7c5d53bb53398c7ebaaf2ec0d6f8a926b4478c17f92a24255c418b84011c568
---
> combined  sha256:138abcb51e9379f027706a72c782a61a4a0685607a851894c6abdee6c0613cb2
```

