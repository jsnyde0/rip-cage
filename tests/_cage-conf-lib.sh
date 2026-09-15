#!/usr/bin/env bash
# tests/_cage-conf-lib.sh -- give a scratch project a native msb cage config.
#
# WHY EVERY `rc up` TEST NEEDS THIS NOW. Since ADR-031 D2 (rip-cage-ely4.9),
# `rc up` launches from one native microsandbox `--conf` file per project and
# refuses, before any msb call, when it cannot find one. There is deliberately
# no implicit default cage and rc never writes the file itself -- composing it
# is the operator's job (ADR-005 D12: rc owns the mechanical seams, not the
# composition). So a test pointing `rc up` at a fresh mktemp directory gets a
# CAGE_CONFIG_MISSING refusal rather than whatever it meant to assert.
#
# Usage, from any test:
#   source "${SCRIPT_DIR}/_cage-conf-lib.sh"
#   CONF=$(cage_conf_for "$TEST_DIR")            # default image
#   CONF=$(cage_conf_for "$TEST_DIR" "$MY_TAG")  # stub/fixture image
#   RC_CAGE_CONF="$CONF" "$RC" up --dry-run "$TEST_DIR"
#
# THE CONFIG IS WRITTEN OUTSIDE THE PROJECT, DELIBERATELY. rc refuses a config
# that resolves inside a tree that same config mounts (ADR-031 D5(a)) -- an
# agent inside the cage could otherwise edit the file deciding what the next
# cage mounts. A fixture written into the project would be refused before the
# test reached its own subject.

# cage_conf_for <project-dir> [image-ref]
#
# Write a minimal-but-real cage config for PROJECT-DIR and echo its path.
# Minimal-but-real matters: it carries the four things every cage needs (an
# image, a workspace mount, a working directory, a default-deny egress policy
# with one allowed host) so a test asserting on the launch argv sees a
# representative one, not a degenerate one.
cage_conf_for() {
  local _proj="$1"
  local _image="${2:-rip-cage:latest}"

  # BSD mktemp only accepts the X-run at the END of a template, so make a
  # directory and name the file inside it rather than templating a suffix.
  local _dir _conf
  _dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cage-conf-XXXXXX") || return 1
  _conf="${_dir}/cage.yaml"

  cat > "$_conf" <<CAGE_CONF
image: ${_image}
workdir: /workspace
mounts:
  - "${_proj}:/workspace"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CAGE_CONF

  printf '%s\n' "$_conf"
}
