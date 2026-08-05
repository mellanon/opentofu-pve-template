#!/usr/bin/env bash
# Validate the cloud-init user-data this configuration emits.
#
# `tofu validate` checks HCL and never sees the YAML that comes out of
# templatefile(), so this closes that gap. It renders base.yaml.tftpl with the
# real runcmd list (from base.runcmd.json.tftpl, the same source the module
# reads) and checks three things:
#
#   1. the result parses as YAML with no duplicate mapping keys anywhere
#      (cloud-init silently drops one of a duplicated pair)
#   2. it passes `cloud-init schema`, which catches deprecated and malformed keys
#   3. deprecation warnings are treated as failures, not warnings
#
# It then renders one adversarial combination - an SSH key comment containing
# ': ', a package containing '#', a hostname that is a YAML boolean word - and
# asserts the values survive as strings. That is the regression test for the
# jsonencode() escaping in base.yaml.tftpl: without it these inputs silently
# change the document instead of failing.
#
# Requires: python3-yaml, cloud-init, an init'ed tofu.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "missing PyYAML: sudo apt install python3-yaml" >&2
  exit 1
fi
if ! command -v cloud-init >/dev/null; then
  echo "missing cloud-init: sudo apt install cloud-init" >&2
  exit 1
fi
if ! command -v tofu >/dev/null; then
  echo "missing tofu" >&2
  exit 1
fi

# tofu console evaluates the whole config. Before any state exists a dummy
# passphrase satisfies it, but once terraform.tfstate is on disk the real one
# is required to decrypt it - fail with a useful message instead of a cryptic
# state-encryption error.
if [ -e terraform.tfstate ] && [ -z "${TF_VAR_state_passphrase:-}" ]; then
  echo "terraform.tfstate exists; run 'source tofu.env' first so tofu console can decrypt it" >&2
  exit 1
fi
export TF_LOG=
export TF_VAR_state_passphrase="${TF_VAR_state_passphrase:-render-only-passphrase-unused}"
export TF_VAR_ssh_public_keys="${TF_VAR_ssh_public_keys:-[\"ssh-ed25519 AAAArenderonly check@local\"]}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Renders an HCL expression to stdout. jsonencode plus console's own string
# quoting means the result is double-encoded, hence the two decode passes.
# -lock=false: once a state file exists, console prints "Acquiring state
# lock..." to STDOUT, which would corrupt the pipeline; a read-only render
# needs no lock. The python side additionally keeps only the quoted result
# line in case a future tofu adds other stdout notices.
# On failure the diagnostics go to stderr (stdout is usually redirected into
# the output file) and the caller decides whether to continue.
render() {
  printf '%s\n' "$1" | tofu console -lock=false 2>"$workdir/err" \
    | python3 -c 'import json,sys; line=next(l for l in sys.stdin.read().splitlines() if l.lstrip().startswith("\"")); print(json.loads(json.loads(line)), end="")' \
    || { echo "render failed:" >&2; cat "$workdir/err" >&2; return 1; }
}

# The runcmd list a VM actually gets, built from the same file
# modules/vm/main.tofu reads.
runcmd_expr() {
  printf '%s' 'jsondecode(templatefile("./cloud-init/base.runcmd.json.tftpl", { ci_user = "ubuntu", vm_name = "checkvm" }))'
}

# base_expr <vm_name> <ssh_key> <package> <runcmd_expr> <snapshot_expr> <upgrade>
# The first three are literal strings, injected as HCL string literals; the
# last three are raw HCL (snapshot_expr is `null` or a quoted timestamp).
base_expr() {
  cat <<EXPR
jsonencode(templatefile("./cloud-init/base.yaml.tftpl", {
  vm_name = "$1", fqdn = "$1.example", timezone = "Etc/UTC",
  ci_user = "ubuntu", ssh_public_keys = ["$2"],
  packages = ["$3"], runcmd = $4,
  archive_snapshot = $5, package_upgrade = $6,
}))
EXPR
}

check_yaml() {
  python3 - "$1" <<'PY'
import sys, yaml

class Strict(yaml.SafeLoader):
    pass

def no_dupes(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in seen:
            raise ValueError(f"duplicate mapping key: {key!r}")
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)

Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dupes)
with open(sys.argv[1]) as f:
    yaml.load(f.read(), Loader=Strict)
PY
}

check_schema() {
  local out="$1" label="$2"
  # cloud-init exits 0 on deprecation warnings, so grep for them explicitly.
  local schema_out
  schema_out="$(cloud-init schema --config-file "$out" 2>&1 | grep -Ev 'log_util|schema\.py' || true)"
  if ! grep -q '^Valid schema' <<<"$schema_out"; then
    echo "FAIL  ${label}: ${schema_out}"
    return 1
  elif grep -qi 'deprecat' <<<"$schema_out"; then
    echo "FAIL  ${label}: deprecation: ${schema_out}"
    return 1
  fi
  return 0
}

status=0
label="base"
out="$workdir/base.yaml"

if ! render "$(base_expr checkvm "ssh-ed25519 AAAA check@local" qemu-guest-agent "$(runcmd_expr)" null false)" >"$out"; then
  echo "FAIL  ${label}: render (base)"
  status=1
elif ! check_yaml "$out"; then
  echo "FAIL  ${label}: YAML/duplicate-key check"
  status=1
elif check_schema "$out" "$label"; then
  echo "ok    ${label}"
else
  status=1
fi

# Adversarial pass: values shaped to break unescaped YAML interpolation, plus
# the snapshot pin and package_upgrade=true so the conditional bootcmd block
# gets schema coverage.
adv_key='ssh-ed25519 AAAA check@local: laptop key'
adv_pkg='foo # bar'
adv_name='no'
adv_snapshot='20260801T000000Z'
out="$workdir/adversarial.yaml"
if ! render "$(base_expr "$adv_name" "$adv_key" "$adv_pkg" "$(runcmd_expr)" "\"$adv_snapshot\"" true)" >"$out"; then
  echo "FAIL  <adversarial>: render"
  status=1
elif ! check_yaml "$out"; then
  echo "FAIL  <adversarial>: YAML/duplicate-key check"
  status=1
elif ! python3 - "$out" "$adv_name" "$adv_key" "$adv_pkg" "$adv_snapshot" <<'PY'
import sys, yaml
path, name, key, pkg, snapshot = sys.argv[1:6]
with open(path) as f:
    doc = yaml.safe_load(f)
assert doc["hostname"] == name, f"hostname mangled: {doc['hostname']!r}"
keys = doc["users"][0]["ssh_authorized_keys"]
assert key in keys, f"ssh key mangled: {keys!r}"
assert pkg in doc["packages"], f"package mangled: {doc['packages']!r}"
bootcmd = doc.get("bootcmd")
assert isinstance(bootcmd, list) and bootcmd and all(isinstance(c, str) for c in bootcmd), \
    f"bootcmd not a list of strings: {bootcmd!r}"
assert any(snapshot in c for c in bootcmd), f"snapshot missing from bootcmd: {bootcmd!r}"
assert any("Unattended-Upgrade" in c for c in bootcmd), \
    f"unattended-upgrades disable missing from bootcmd: {bootcmd!r}"
assert doc["package_upgrade"] is True, f"package_upgrade mangled: {doc['package_upgrade']!r}"
PY
then
  echo "FAIL  <adversarial>: a hostile value did not survive as a string - check jsonencode() in base.yaml.tftpl"
  status=1
elif check_schema "$out" "<adversarial>"; then
  echo "ok    <adversarial>"
else
  status=1
fi

exit "$status"
