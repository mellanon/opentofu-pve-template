# Crucible AC-0

## Positive

### Baseline

```sh
❯ grep -Ev '^\s*#|^$' inventory/ubuntu-test.yaml
vm_id: 500
description: "Ubuntu 26.04 cloud image, managed by OpenTofu"
cpu_cores: 2
memory_mb: 4096
disk_gb: 32
ipv4: 
gateway: 
dns_servers: 
dns_domain: 
archive_snapshot: 20260721T000000Z
packages:
    - unzip   # needed by the bun ansible role
    - git     # needed by the metafactory_arc ansible role (gh only Recommends it)
    - gh
    - tree
ansible_roles: [nats_server, bun, claude, docker, metafactory_arc]
tags: ["ubuntu"]

❯ grep -Ev '^\s+#|^$' ansible/roles/{nats_server,bun,claude,docker,metafactory_arc}/defaults/main.yaml
ansible/roles/nats_server/defaults/main.yaml:# Pinned fleet-wide; verified against the upstream SHA256SUMS at download.
ansible/roles/nats_server/defaults/main.yaml:nats_server_version: "2.14.4"
ansible/roles/bun/defaults/main.yaml:# Pinned fleet-wide; verified against the upstream SHASUMS256.txt at download.
ansible/roles/bun/defaults/main.yaml:bun_version: "1.3.14"
ansible/roles/claude/defaults/main.yaml:# Pinned fleet-wide; the binary is verified against the checksum in the
ansible/roles/claude/defaults/main.yaml:# release's own manifest.json before the vendor installer runs.
ansible/roles/claude/defaults/main.yaml:claude_version: "2.1.221"
ansible/roles/docker/defaults/main.yaml:# download.docker.com has no snapshot service, so a VM's archive_snapshot
ansible/roles/docker/defaults/main.yaml:# cannot pin these; the explicit versions below (epoch included) are the pin.
ansible/roles/docker/defaults/main.yaml:# Current versions: apt-cache madison docker-ce on a guest, or the Version:
ansible/roles/docker/defaults/main.yaml:# fields in
ansible/roles/docker/defaults/main.yaml:# https://download.docker.com/linux/ubuntu/dists/resolute/stable/binary-amd64/Packages
ansible/roles/docker/defaults/main.yaml:docker_packages:
ansible/roles/docker/defaults/main.yaml:  - docker-ce=5:29.7.1-1~ubuntu.26.04~resolute
ansible/roles/docker/defaults/main.yaml:  - docker-ce-cli=5:29.7.1-1~ubuntu.26.04~resolute
ansible/roles/docker/defaults/main.yaml:  - containerd.io=2.2.6-1~ubuntu.26.04~resolute
ansible/roles/docker/defaults/main.yaml:  - docker-compose-plugin=5.3.1-1~ubuntu.26.04~resolute
ansible/roles/docker/defaults/main.yaml:  - docker-buildx-plugin=0.36.1-1~ubuntu.26.04~resolute
ansible/roles/docker/defaults/main.yaml:  - docker-ce-rootless-extras=5:29.7.2-1~ubuntu.26.04~resolute
ansible/roles/docker/defaults/main.yaml:# Docker's signing key, pinned by full fingerprint: a bare signed-by URL
ansible/roles/docker/defaults/main.yaml:# would trust whatever download.docker.com serves.
ansible/roles/docker/defaults/main.yaml:docker_gpg_fingerprint: "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
ansible/roles/metafactory_arc/defaults/main.yaml:# Pinned fleet-wide; installed from the tagged release of the git repo, so
ansible/roles/metafactory_arc/defaults/main.yaml:# the tag is the verification for arc's own source. From 0.45.0 arc tracks
ansible/roles/metafactory_arc/defaults/main.yaml:# its bun.lock, so its dependency tree is pinned too and the role installs
ansible/roles/metafactory_arc/defaults/main.yaml:# with --frozen-lockfile.
ansible/roles/metafactory_arc/defaults/main.yaml:metafactory_arc_version: "0.45.0"
```

Destroy/create

```sh
❯ ./scripts/vm-fingerprint.sh ubuntu@<vm-ip> fingerprints/ubuntu-test.txt
fingerprint written to fingerprints/ubuntu-test.txt
##### DIGESTS #####
core      sha256:cecf2948f2adbd7e54c1667465393a4f2983e7801ca8f6ce786f04dc6913dbfb
provider  sha256:0b63ff004e7aa8bb397d8f3cfb4e09eb37ca9e5bc3de71637aa8cbfefaaf533c
combined  sha256:3c099f378d48c5d00e02b1c8f2d8af18ccefa59dc5b2d89f52443ea97e781bd0

❯ git diff fingerprints/ubuntu-test.txt

❯
```

---

## Negative

Starting from same baseline

### Change

NATS server version changed from 2.14.4 to 2.14.5

```sh
❯ vi ansible/roles/nats_server/defaults/main.yaml

❯ cat ansible/roles/nats_server/defaults/main.yaml
# Pinned fleet-wide; verified against the upstream SHA256SUMS at download.
nats_server_version: "2.14.5"
```

### Fingerprint result

Destroy/create

```sh
❮ ./scripts/vm-fingerprint.sh ubuntu@<vm-ip> fingerprints/ubuntu-test.txt
fingerprint written to fingerprints/ubuntu-test.txt
##### DIGESTS #####
core      sha256:b54df67b4df039cb6a63adc00fb8384f5dc604fc944780162a701d9f0e2eb576
provider  sha256:0b63ff004e7aa8bb397d8f3cfb4e09eb37ca9e5bc3de71637aa8cbfefaaf533c
combined  sha256:aa15a8f0781be64c44781cb6ce43276c3826be31994d2e32a5fecf3c734dd996

❯ git diff
diff --git a/ansible/roles/nats_server/defaults/main.yaml b/ansible/roles/nats_server/defaults/main.yaml
index 714cfa1..3ffc84a 100644
--- a/ansible/roles/nats_server/defaults/main.yaml
+++ b/ansible/roles/nats_server/defaults/main.yaml
@@ -1,2 +1,2 @@
 # Pinned fleet-wide; verified against the upstream SHA256SUMS at download.
-nats_server_version: "2.14.4"
+nats_server_version: "2.14.5"
diff --git a/fingerprints/ubuntu-test.txt b/fingerprints/ubuntu-test.txt
index 6e1ebc1..f0e55ee 100644
--- a/fingerprints/ubuntu-test.txt
+++ b/fingerprints/ubuntu-test.txt
@@ -1858,11 +1858,11 @@ e39090ffe9c45c59082c3746e2aa2546dc53e3c5eeb4ad83f8210be7e2e58022  .bun/install/c
 a757e3b924af184b25e2386d1678b1fe341805a516ebf9bccee219b47aebd5e7  .bun/install/cache/yaml@2.9.0@@@1/dist/visit.js
 20b8b197cbd10dad245d45e463dfe58e4c8c25a47e24bc4256ad9ab58bf35683  .bun/install/cache/yaml@2.9.0@@@1/package.json
 2f1db26f6cc426ef698210b592f40cec49be1b6c4b34e7f2d61904786242bd85  .bun/install/cache/yaml@2.9.0@@@1/util.js
-4b0bb1385667f2189814e6ac37bbe82d67da8ee3e81af61c316032319a48d11d  .local/bin/nats-server
+e1a2f9ba25077f4cf753bee829483bd68fbf0a4eec9b6645a1e5785a6de0c0d1  .local/bin/nats-server
 60db8e88d42c24b5199c92cfd56ec88370c510c3789c6f364af748354f087ada  .local/share/claude/versions/2.1.221

 ===== layer2 versions =====
-nats-server: v2.14.4
+nats-server: v2.14.5
 1.3.14
 /home/ubuntu/.local/share/claude/versions/2.1.221
 ../install/global/node_modules/arc/src/cli.ts
@@ -1897,6 +1897,6 @@ status: done
 nocloud

 ##### DIGESTS #####
-core      sha256:cecf2948f2adbd7e54c1667465393a4f2983e7801ca8f6ce786f04dc6913dbfb
+core      sha256:b54df67b4df039cb6a63adc00fb8384f5dc604fc944780162a701d9f0e2eb576
 provider  sha256:0b63ff004e7aa8bb397d8f3cfb4e09eb37ca9e5bc3de71637aa8cbfefaaf533c
-combined  sha256:3c099f378d48c5d00e02b1c8f2d8af18ccefa59dc5b2d89f52443ea97e781bd0
+combined  sha256:aa15a8f0781be64c44781cb6ce43276c3826be31994d2e32a5fecf3c734dd996

❯
```

