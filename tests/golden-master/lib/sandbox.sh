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

# Fixed (non-mktemp, non-random) scratch-root NAME, but per-PROCESS-unique
# scratch-root PATH: the default fallback nests the fixed leaf directory
# name "rc-golden-master-root" under a $$-tagged parent
# (rc-golden-master-root.$$/), computed ONCE here at source-time (module
# load), not inside gm_sandbox_reset -- every case within one invocation
# still shares the same root; only cross-process invocations differ
# (rip-cage-6qxs: a shared, unlocked GM_ROOT let any two overlapping
# sandbox-sourcing processes rm -rf/mkdir-race each other's fixtures).
#
# The leaf basename is kept EXACTLY "rc-golden-master-root" (not
# "rc-golden-master-root.$$") deliberately: `container_name()`
# (cli/lib/container.sh) derives container names from
# basename(dirname(path))-basename(path) alone, discarding the rest of the
# path -- so the workspace's container name embeds GM_ROOT's bare basename
# literally, UNSCRUBBED (scrub.sh's gm_scrub_root_script only scrubs
# full-path occurrences of GM_ROOT, not this standalone token; see
# up_dry_run_json_*/up_validate_warning_seam snapshots, which hardcode
# "rc-golden-master-root-workspace"). Tagging the basename itself with $$
# would vary that literal every run and break golden-master byte-
# determinism; nesting under a $$-tagged PARENT keeps the full path
# per-process-unique (so gm_sandbox_reset's rm -rf never collides across
# processes) while the basename-derived container name stays byte-for-byte
# identical to the recorded baseline. mktemp's randomized suffix (and
# macOS's randomized /var/folders/<rand> TMPDIR) is intentionally NOT used
# for the same reason a fixed name was originally chosen: it would inject
# nondeterminism into every path reference before the scrub even runs
# (full-path occurrences ARE scrubbed, so this is about full-path
# CONTENT-derived tokens like the container name, not the scrub itself).
#
# Override via GM_ROOT_OVERRIDE for the two-directional self-check driver,
# which needs TWO independent scratch roots (one per run) so the second
# run's fixture writes cannot mask a scrub gap in the first run's captured
# paths.
GM_ROOT="${GM_ROOT_OVERRIDE:-${TMPDIR:-/tmp}/rc-golden-master-root.$$/rc-golden-master-root}"
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
    # rip-cage-qt4k: pin LC_ALL=C for cross-machine collation determinism.
    # gm_capture launches the child `rc` with plain `env` (NOT env -i), so it
    # inherits the invoking shell's locale (LANG/LC_ALL/LC_COLLATE). rc's
    # allowlist path (_allowlist_read_observed_hosts, cli/allowlist.sh) pipes
    # through `sort -u`, whose ordering is locale-collation-dependent, so a
    # non-C ambient locale (e.g. a CI runner vs a laptop) could yield a
    # different byte order and break golden-master byte-identity across
    # machines. LC_ALL=C dominates LANG and every other LC_* (incl.
    # LC_COLLATE), and comes AFTER any inherited value in env's left-to-right
    # arg processing, so it wins over whatever the caller's shell exported.
    # Latent today (no GM case exercises the sort -u path yet) but pinned
    # ahead of the msb migration running the net on a different-locale runner.
    "LC_ALL=C"
  )
  # rip-cage-9odv: namespace-scoped hermeticity. gm_capture launches the
  # child `rc` with plain `env` (whitelist-APPEND, not clean-slate `env -i`)
  # so it inherits the calling process's FULL environment. That's fine for
  # most vars (e.g. tests/run-host.sh's own driver fixture legitimately
  # wants ambient ordinary vars to pass through), but it means an ambient
  # RC_CONFIG_GLOBAL/RC_MANIFEST_GLOBAL/etc (e.g. run-host.sh ~line 193
  # exports RC_CONFIG_GLOBAL for ITS OWN fixture) silently overrides the
  # config golden-master cases resolve against -- capture.sh --check was
  # 55/55 standalone but red inside the full run-host.sh suite. Explicitly
  # `-u` every currently-exported RC_*/RIP_CAGE_* var before the _env
  # assignments below: `env` processes args left-to-right, so a later
  # explicit RC_CONFIG_GLOBAL=... in _env (the GM_CONFIG_GLOBAL opt-in a
  # few lines down) still wins over an earlier `-u RC_CONFIG_GLOBAL` here.
  # Deliberately NOT a full env -i clean-slate: that would also strip
  # LANG/LC_ALL and other base vars `rc` may read, risking collation drift
  # and colliding with the separate LC_ALL=C pin (rip-cage-qt4k). Scoped to
  # this one namespace so it closes the whole RC_*/RIP_CAGE_* leak class
  # without touching locale. GM_DOCKER_* (forwarded below) is a DIFFERENT,
  # deliberately-forwarded namespace (shim knobs) -- left untouched.
  local -a _env_unset=()
  local _leak_var
  for _leak_var in $(compgen -e 2>/dev/null | grep -E '^(RC_|RIP_CAGE_)' || true); do
    _env_unset+=(-u "$_leak_var")
  done
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
  # ${_env_unset[@]+...}: expand to nothing when _env_unset is empty (clean
  # env, no ambient RC_*/RIP_CAGE_*) WITHOUT tripping `set -u` on bash 3.2
  # (macOS /bin/bash), where a bare "${empty[@]}" is an unbound-variable error.
  env ${_env_unset[@]+"${_env_unset[@]}"} "${_env[@]}" "$RC" "$@" >"$_outfile" 2>"$_errfile" < "${GM_STDIN:-/dev/null}"
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
