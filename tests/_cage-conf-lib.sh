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
  local _proj
  # RESOLVE the project path before writing it into a mount line. msb does not
  # follow a host-side symlink in a bind source, and on macOS $TMPDIR lives
  # under /var, which IS a symlink to /private/var — an unresolved path boots
  # to "mount ...: Not a directory (os error 20)" (measured, msb 0.6.18, spike
  # rip-cage-ely4.16). The shipped template says the same thing to operators.
  _proj=$(cd "$1" 2>/dev/null && pwd -P) || _proj="$1"
  local _image="${2:-rip-cage:latest}"

  # WHERE this lands is load-bearing for two separate reasons.
  #
  # Beside the project, never inside it: rc refuses a config that resolves
  # inside a tree that same config mounts (ADR-031 D5(a)), so a fixture written
  # into the workspace would be refused before the test reached its subject.
  #
  # Beside the project, never in a fresh mktemp dir: the config path appears IN
  # the launch argv, and suites that assert argv determinism scrub volatile
  # paths relative to their own sandbox root (test-up-run-args-e2e E4). A path
  # under TMPDIR sits outside that root, survives scrubbing, and makes every
  # run differ on a path the caller never chose. The project's parent is inside
  # the sandbox, so the existing scrubber handles it.
  local _conf
  _conf="$(dirname "$_proj")/.rc-test-cage-$(basename "$_proj").yaml"

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

# cage_conf_install <project-dir> <xdg-config-home> [image-ref] [host ...]
#
# Write the cage config at the DEFAULT path rc resolves —
# <xdg>/rip-cage/projects/<cage-name>.yaml — and echo it.
#
# Use this instead of cage_conf_for when a test drives verbs OTHER than
# `rc up <path>`: `rc reload <cage>` takes a cage NAME, recreates through
# cmd_up, and has no workspace argument to derive a config from. Seeding the
# default path is what makes every verb in a suite find the same config
# without threading RC_CAGE_CONF through each call.
#
# HOSTS are the bare domains that become `network.allow` entries, one
# `<host>:tcp:443` line each. Default: the single host cage_conf_for writes.
# A suite that ASSERTS on the resulting rule count passes its own list here so
# the count under test is one the fixture chose, not a helper default it would
# still observe with the config ignored entirely (rip-cage-jgz2). Pass "" for
# IMAGE-REF to take the default image and still supply hosts.
#
# The cage name is derived by rc's own container_name(), not reimplemented
# here — a second copy of that rule would drift from the first.
cage_conf_install() {
  local _projarg="$1" _xdg="$2" _image="${3:-}"
  local _proj _name _dir _conf
  [[ -n "$_image" ]] || _image="rip-cage:latest"
  # bash 3.2: `shift 3` fails outright when fewer than 3 args were passed, so
  # only shift what is there before collecting the variadic host list.
  if [[ "$#" -ge 3 ]]; then shift 3; else shift "$#"; fi
  local -a _hosts=("${@:-}")
  [[ "$#" -gt 0 ]] || _hosts=("api.anthropic.com")
  # Same symlink resolution as cage_conf_for above, same reason.
  _proj=$(cd "$_projarg" 2>/dev/null && pwd -P) || _proj="$_projarg"

  _name=$(bash -c "source '${REPO_ROOT}/rc' 2>/dev/null; container_name '$_proj'") || return 1
  [[ -n "$_name" ]] || return 1

  _dir="${_xdg}/rip-cage/projects"
  mkdir -p "$_dir" || return 1
  _conf="${_dir}/${_name}.yaml"

  # The named volumes are declared here, not left out, because suites that use
  # this installer assert they SURVIVE a cold recreate (test-rc-reload L1).
  # They moved from generated rc flags into the config with rip-cage-ely4.9, so
  # a fixture config without them produces a cage with no persistent state and
  # the survival property becomes untestable — which is exactly how a real
  # operator config composed without these lines would behave.
  cat > "$_conf" <<CAGE_CONF
image: ${_image}
workdir: /workspace
mounts:
  - "${_proj}:/workspace"
  - named: "rc-state-${_name}"
    target: /home/agent/.claude-state
    create: ensure-exists
  - named: "rc-history-${_name}"
    target: /commandhistory
    create: ensure-exists
network:
  policy: none
  allow:
CAGE_CONF
  local _h
  for _h in "${_hosts[@]}"; do
    printf '    - "%s:tcp:443"\n' "$_h" >> "$_conf"
  done
  printf '%s\n' "$_conf"
}
