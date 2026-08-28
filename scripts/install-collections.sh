#!/usr/bin/env bash
# Install the pinned ansible collections named in ansible/requirements.yml.
#
# One script for both environments: the local venv and CI run this same
# command, so the two cannot drift in how the collections arrive. Where they
# land is the caller's choice, named by ANSIBLE_COLLECTIONS_PATH - tofu.env
# sets it locally, the workflow's job env: block sets it in CI - because that
# is also the variable every later ansible command reads.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v ansible-galaxy >/dev/null; then
  echo "missing ansible-galaxy; create the venv first (see README)" >&2
  exit 1
fi

# Singular _PATH, not the plural spelling: ansible-compat hard errors on
# ANSIBLE_COLLECTIONS_PATHS, and ansible-lint runs through ansible-compat.
if [ -z "${ANSIBLE_COLLECTIONS_PATH:-}" ]; then
  echo "ANSIBLE_COLLECTIONS_PATH is not set; run 'source tofu.env' first" >&2
  exit 1
fi
# A colon-separated list is valid for ansible itself but not for -p, which
# takes exactly one directory. Fail rather than silently install into the head.
case "$ANSIBLE_COLLECTIONS_PATH" in
  *:*)
    echo "ANSIBLE_COLLECTIONS_PATH must name a single directory: $ANSIBLE_COLLECTIONS_PATH" >&2
    exit 1
    ;;
esac

# --force is not cosmetic. Without it galaxy short-circuits to "Nothing to do"
# whenever a copy of a requested collection exists anywhere in its own search
# path - a runner image ships some preinstalled - and installs nothing into
# the path everything else here reads.
ansible-galaxy collection install -r ansible/requirements.yml \
  -p "$ANSIBLE_COLLECTIONS_PATH" --force

# Logged, not just installed: what landed is the thing worth seeing in a CI
# run's output when a lint failure turns out to be a missing collection.
ansible-galaxy collection list -p "$ANSIBLE_COLLECTIONS_PATH"
