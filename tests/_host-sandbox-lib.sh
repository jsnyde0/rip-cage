#!/usr/bin/env bash
# tests/_host-sandbox-lib.sh — shared host-test config sandbox (rip-cage-w3lq).
#
# Bare per-file test runs are non-hermetic: only the full-suite driver
# (tests/run-host.sh) previously built the benign config sandbox described
# below. A promoted global config (e.g. a real ~/.config/rip-cage/config.yaml
# with network.egress.mediator set to something other than "none", requiring
# egress to be on) is silently picked up by any host-side test that does not
# sandbox its own RC_CONFIG_GLOBAL/XDG_CONFIG_HOME, and can break a test that
# forces egress=off or otherwise depends on the "no config" default. This is
# the single seam extracted so both run-host.sh AND a single-file wrapper
# (tests/run-one.sh) build the identical sandbox.
#
# Extracted verbatim (same fixture content, same env-var precedence, same
# "do not export RC_MANIFEST_GLOBAL" isolation contract) from
# tests/run-host.sh circa rip-cage-w3lq.
#
# Usage (source, then call):
#   # shellcheck source=tests/_host-sandbox-lib.sh
#   source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
#   _host_sandbox_setup
#   trap '_host_sandbox_cleanup' EXIT INT TERM
#   ... run test(s) ...
#
# Provides:
#   _host_sandbox_setup()    — creates a mktemp dir and points
#                               XDG_CONFIG_HOME at it (unless the caller's
#                               environment already set it — same
#                               ${VAR:-default} precedence as the original
#                               run-host.sh code). Records the created
#                               directory in _HOST_SANDBOX_CFG_DIR
#                               for _host_sandbox_cleanup to remove.
#   _host_sandbox_cleanup()  — rm -rf the directory _host_sandbox_setup
#                               created (no-op if setup was never called or
#                               already cleaned up).
#
# Callers own their own trap registration (EXIT/INT/TERM) — this lib does
# not install a trap itself, so a caller that ALSO needs its own cleanup
# (e.g. run-host.sh's scratch-cage sweep) can compose both in one handler.

set -u

# ---------------------------------------------------------------------------
# Scratch root (rip-cage-6v34.6) — every `mktemp -d` in a host test must land
# under a SHORT, SYMLINK-FREE directory inside $HOME. macOS's default TMPDIR
# (`/var/folders/<32-char>/T/`) violates both properties and red-lines every
# cage-creating suite arm on msb >= 0.6.9:
#
#   SHORT     msb derives a per-sandbox Unix socket path from the workspace
#             and MSB_HOME paths and refuses to create the sandbox when the
#             shortest derived path exceeds the platform's 104-byte AF_UNIX
#             limit ("sandbox runtime socket path is too long", upstream
#             v0.6.9 / commit e0c0f9ba). A macOS mktemp root spends ~60 of
#             those 104 bytes before the test appends anything.
#   SYMLINK-  msb >= 0.6.16 rejects any `-v` whose HOST source path traverses
#   FREE      a symlink, failing guest boot with `mount <tag>: Not a directory
#             (os error 20)`. `/var` is a symlink to `/private/var`, so every
#             mount rooted at a macOS mktemp dir trips it (rip-cage-6v34.7).
#
# Exported at SOURCE time (not from _host_sandbox_setup) so a sourcer that
# mktemps before calling setup — or that never calls setup at all, like
# tests/test-e2e-lifecycle.sh — still gets the short root.
_HOST_SCRATCH_ROOT=""

# _host_scratch_root_setup — point TMPDIR at ~/.cache/rc-t, symlink-resolved.
# An operator (or a CI runner with its own short tmp root) overrides the
# choice explicitly via RC_TEST_TMPDIR; there is deliberately no heuristic
# that "keeps a TMPDIR that looks short enough", because the 104-byte budget
# is spent by paths this lib cannot see (MSB_HOME, the sandbox name, the
# per-test workspace subpath).
_host_scratch_root_setup() {
  local _root="${RC_TEST_TMPDIR:-${HOME}/.cache/rc-t}"
  mkdir -p "$_root" 2>/dev/null || return 0
  # `cd && pwd -P` is the bash-3.2-portable realpath (BSD realpath lacks -m).
  _root=$(cd "$_root" 2>/dev/null && pwd -P) || return 0
  [[ -n "$_root" ]] || return 0
  _HOST_SCRATCH_ROOT="$_root"
  export TMPDIR="$_root"
}

_host_scratch_root_setup

# _host_scratch_mktemp_d [NAME_HINT] — mktemp -d inside the short root.
#
# REQUIRED for any temp dir that becomes a cage WORKSPACE or a `HOME` handed
# to `rc up`. A bare `mktemp -d` is not enough on macOS: BSD mktemp ignores
# $TMPDIR when called with no template and uses the Darwin per-user temp dir
# (/var/folders/<32-char>/T/) regardless. Only an explicit template honors
# the root, which is what this helper supplies.
#
# Echoes the created directory. Falls back to a plain `mktemp -d` if the
# short root is unavailable, so a test never dies here — it just loses the
# short-root guarantee, which its own `rc up` will then report loudly.
_host_scratch_mktemp_d() {
  local _hint="${1:-t}"
  if [[ -z "${_HOST_SCRATCH_ROOT:-}" ]]; then
    mktemp -d
    return $?
  fi
  mktemp -d "${_HOST_SCRATCH_ROOT}/${_hint}.XXXXXX"
}

_HOST_SANDBOX_CFG_DIR=""

# _host_sandbox_setup — build the benign config-fixture sandbox and export the
# env vars that make `rc` resolve its host config against it instead of the
# real ~/.config/rip-cage/.
#
# The tools.yaml this used to seed went with the manifest (ADR-031 D4,
# rip-cage-ely4.11). rc reads no tool list at all now, so there is nothing left
# to shadow on that path; XDG_CONFIG_HOME still points at the sandbox because
# rc build's own containment check and the protected-paths resolver both read
# the operator's host config dir, and neither may reach the developer's real one.
#
# No config.yaml / RC_CONFIG_GLOBAL to seed either: the layered rip-cage config
# schema retired per ADR-031 D2 in favor of one native msb --conf file per
# project plus the shipped protected-paths floor (rip-cage-ely4.9).
_host_sandbox_setup() {
  _HOST_SANDBOX_CFG_DIR=$(mktemp -d)
  mkdir -p "${_HOST_SANDBOX_CFG_DIR}/rip-cage"

  export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${_HOST_SANDBOX_CFG_DIR}}"
}

# _host_sandbox_cleanup — remove the sandbox directory created by
# _host_sandbox_setup. Safe to call even if setup was never called (no-op).
_host_sandbox_cleanup() {
  [[ -n "${_HOST_SANDBOX_CFG_DIR:-}" ]] && rm -rf "${_HOST_SANDBOX_CFG_DIR}"
}
