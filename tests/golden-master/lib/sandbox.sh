#!/usr/bin/env bash
# tests/golden-master/lib/sandbox.sh — shared fixture-tree + sandbox-env
# machinery for the rc golden-master harness (rip-cage-9oyh §1).
#
# Mirrors tests/run-host.sh's driver-level sandbox idiom (RC_CONFIG_GLOBAL /
# XDG_CONFIG_HOME pointing at a fixture config+manifest pair) and the
# per-test HOME/XDG_CONFIG_HOME/RC_ALLOWED_ROOTS sandbox used throughout
# tests/test-credential-mounts.sh and tests/test-image-drift-resume.sh.
#
# Fixed scratch root (NOT mktemp): a golden master must be byte-identical
# across repeated runs; mktemp's randomized suffix (and macOS's randomized
# /var/folders/<rand> TMPDIR) would inject nondeterminism into every path
# reference before the scrub even runs. A FIXED, repo-external directory
# name is reset (rm -rf; mkdir -p) at the start of every capture.sh
# invocation instead.
#
# Sourced by capture.sh and by the harness's other host-side test scripts
# that want the same fixture idiom (§3(i)/§3(iii)/§3(vi) seam tests, §4
# gap-fill tests).
set -u

GM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GM_DIR="$(cd "${GM_LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${GM_DIR}/../.." && pwd)"
RC="${REPO_ROOT}/rc"
GM_FAKEBIN="${GM_LIB_DIR}/fake-bin"

# Fixed (non-mktemp) scratch root. Override via GM_ROOT_OVERRIDE for the
# two-directional self-check driver, which needs TWO independent scratch
# roots (one per run) so the second run's fixture writes cannot mask a
# scrub gap in the first run's captured paths.
GM_ROOT="${GM_ROOT_OVERRIDE:-${TMPDIR:-/tmp}/rc-golden-master-root}"
GM_ROOT="${GM_ROOT%/}"

GM_HOME="${GM_ROOT}/home"
GM_XDG="${GM_HOME}/.config"
GM_WS="${GM_ROOT}/workspace"

# gm_sandbox_reset — wipe and recreate the fixture tree: global config
# (denylist floor, matches tests/run-host.sh driver fixture), an empty
# (bundled-default) tools.yaml, and a bare workspace directory with no
# .rip-cage.yaml (each case seeds project-level fixtures itself as needed).
gm_sandbox_reset() {
  rm -rf "$GM_ROOT"
  mkdir -p "${GM_XDG}/rip-cage"
  mkdir -p "$GM_WS"
  cat > "${GM_XDG}/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
  touch "${GM_XDG}/rip-cage/tools.yaml"
}

# gm_capture VERB [ARGS...] — invoke the real `rc` under the sandbox env +
# content-keyed docker/uname shims, writing stdout/stderr/exit into
# GM_OUT/GM_ERR/GM_EXIT (globals, overwritten each call). stdin is /dev/null
# unless GM_STDIN names a file. RC_ALLOWED_ROOTS defaults to GM_WS; set
# GM_NO_ALLOWED_ROOTS=1 to omit it entirely (for the RC_VALIDATE_WARNING
# seam case, which needs it UNSET, not empty).
GM_OUT="" GM_ERR="" GM_EXIT=0
gm_capture() {
  local _outfile _errfile
  _outfile=$(mktemp) _errfile=$(mktemp)
  local -a _env=(
    "PATH=${GM_FAKEBIN}:${PATH}"
    "HOME=${GM_HOME}"
    "XDG_CONFIG_HOME=${GM_XDG}"
    "TERM=dumb"
  )
  if [[ "${GM_NO_ALLOWED_ROOTS:-0}" != "1" ]]; then
    _env+=("RC_ALLOWED_ROOTS=${GM_ALLOWED_ROOTS:-$GM_WS}")
  fi
  [[ -n "${GM_SHELL_OVERRIDE+x}" ]] && _env+=("SHELL=${GM_SHELL_OVERRIDE}")
  [[ -n "${GM_MANIFEST_GLOBAL:-}" ]] && _env+=("RC_MANIFEST_GLOBAL=${GM_MANIFEST_GLOBAL}")
  [[ -n "${GM_CONFIG_GLOBAL:-}" ]] && _env+=("RC_CONFIG_GLOBAL=${GM_CONFIG_GLOBAL}")
  # Forward every currently-set GM_DOCKER_* configuration var to the child
  # (the fake docker shim reads these directly). A single generic loop
  # (rather than one hardcoded line per var) so a new shim knob never needs
  # a matching edit here.
  local _gm_var
  for _gm_var in $(compgen -v GM_DOCKER_ 2>/dev/null || true); do
    _env+=("${_gm_var}=${!_gm_var}")
  done

  set +e
  env "${_env[@]}" "$RC" "$@" >"$_outfile" 2>"$_errfile" < "${GM_STDIN:-/dev/null}"
  GM_EXIT=$?
  set -e 2>/dev/null || true
  set +e
  GM_OUT=$(cat "$_outfile")
  GM_ERR=$(cat "$_errfile")
  rm -f "$_outfile" "$_errfile"
}

# gm_read_version — RC_VERSION exactly as `rc` itself resolves it (reads
# ${SCRIPT_DIR}/VERSION), for shim/env vars that must match the real value.
gm_read_version() {
  cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "unknown"
}

# gm_ws_realpath — the OS-resolved absolute path of the fixture workspace
# (macOS /tmp -> /private/tmp symlink means the raw $GM_WS string is not
# what `rc` itself reports/compares once it realpath()s the path arg).
gm_ws_realpath() {
  (cd "$GM_WS" && pwd -P)
}

# gm_capture_in DIR VERB... — like gm_capture, but runs with DIR as $PWD
# (some verbs, e.g. `rc config init`, resolve their target from raw `pwd`
# rather than an explicit path argument). Restores the caller's cwd after.
gm_capture_in() {
  local _dir="$1"; shift
  local _prev_pwd
  _prev_pwd="$(pwd)"
  cd "$_dir"
  gm_capture "$@"
  cd "$_prev_pwd"
}
