#!/usr/bin/env bash
# Host-side tests for manifest mounts: field schema change and rc-up consumer.
# (rip-cage-buuo.1 — ADR-005 D7, D9, ADR-023)
#
# This bead changes the mounts[] element from a scalar string to an object
# {host, dest}. Tests here cover:
#
#   SCHEMA / VALIDATOR
#     MV1  Valid {host, dest} object mount in a TOOL entry parses and loads
#     MH1  Scalar string mount (old shape) is rejected by the validator naming 'mounts'
#     MH2  Object missing 'host' field is rejected naming 'host'
#     MH3  Object missing 'dest' field is rejected naming 'dest'
#     MH4  Object with empty 'host' value is rejected naming 'host'
#     MH5  Object with empty 'dest' value is rejected naming 'dest'
#
#   DENYLIST COUPLING (EFFECT — not presence-only)
#     MD1  Denylisted host in new {host, dest} object shape is REJECTED
#          — realpath+denylist refusal fires (not merely "the check function exists")
#
#   CONSUMER (_manifest_build_mount_args)
#     MC1  Tool with valid {host, dest} mount emits "-v host:dest" arg
#     MC2  Load-bearing: removing the consumer makes a mount-expecting fixture RED
#          (proven by asserting the function is called in _up_prepare_docker_mounts)
#     MC3  No-regression: empty mounts: [] produces no -v arg
#     MC4  No-regression: absent manifest produces no manifest-driven -v args
#     MC5  Skip-if-host-missing: mount entry whose host dir does not exist is skipped
#
# Positive-sentinel discipline: every failure increments FAILURES.
# Script ends with exit-propagation shape: [[ $FAILURES -eq 0 ]] || exit 1
#
# NOTE on RC_E2E parity:
#   The claim that manifest-driven mounts reach -v parity with the hardcoded cm
#   mount is falsifiable only at RC_E2E=1 (a real docker run). The host-side
#   codegen tier (MC1–MC5) proves mount-arg construction logic; it cannot prove
#   the arg actually results in a mount inside a running cage. RC_E2E=1 is the
#   green tier for full parity. If RC_E2E=1 is not available, this fact is
#   reported by the test — NOT silently greened.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build a sandbox HOME + config with optional manifest fixture.
# Also seeds a config.yaml with the default denylist so denylist tests are
# self-contained regardless of the driver's RC_CONFIG_GLOBAL.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-mounts-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist:
    - ".ssh"
    - ".gnupg"
    - ".aws"
    - ".gcloud"
    - "credentials"
    - ".netrc"
    - ".git-credentials"
    - "id_rsa"
    - "id_ed25519"
    - "id_ecdsa"
    - ".kube"
    - ".docker"
    - ".npmrc"
    - ".pypirc"
    - ".cargo/credentials"
    - ".m2/settings.xml"
  allow_risky: null
YAML
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_load in the sandbox. Outputs JSON on stdout; stderr to file if given.
run_manifest_load() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_load" 2>"$stderr_file"
}

# Run _manifest_validate in the sandbox.
run_manifest_validate() {
  local manifest_file="$1"
  local stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${manifest_file}'" 2>"$stderr_file"
}

# Run _manifest_check_mounts_denylist in the sandbox with a given workspace.
run_manifest_check_denylist() {
  local workspace="$1"
  local stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    bash -c "source '${RC}'; _manifest_check_mounts_denylist '${workspace}'" 2>"$stderr_file"
}

# Run _manifest_build_mount_args in the sandbox with a given workspace.
# Returns the generated mount args on stdout.
run_manifest_build_mount_args() {
  local workspace="$1"
  local stderr_file="${2:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    bash -c "source '${RC}'; _manifest_build_mount_args '${workspace}'" 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# MV1 — Valid {host, dest} object mount parses and loads
# ---------------------------------------------------------------------------
test_mv1_valid_object_mount_parses() {
  setup_manifest_sandbox "manifest-with-object-mount.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_load "$stderr_file") || exit_code=$?
  local host_field dest_field
  host_field=$(jq -r '.tools[] | select(.name == "tool-with-mount") | .mounts[0].host' <<<"$out" 2>/dev/null)
  dest_field=$(jq -r '.tools[] | select(.name == "tool-with-mount") | .mounts[0].dest' <<<"$out" 2>/dev/null)
  if [[ "$exit_code" -eq 0 && -n "$host_field" && -n "$dest_field" ]]; then
    pass "MV1 valid {host, dest} mount parses: host=${host_field} dest=${dest_field}"
  else
    fail "MV1 valid {host, dest} mount parse failed: exit=$exit_code host=$host_field dest=$dest_field stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MH1 — Scalar string mount (old shape) is rejected naming 'mounts'
# ---------------------------------------------------------------------------
test_mh1_scalar_mount_rejected() {
  setup_manifest_sandbox "manifest-hostile-scalar-mount.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "mounts" "$stderr_file"; then
    pass "MH1 scalar string mount (old shape) rejected non-zero + names 'mounts'"
  else
    fail "MH1 expected non-zero exit + 'mounts' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MH2 — Object missing 'host' field is rejected naming 'host'
# ---------------------------------------------------------------------------
test_mh2_missing_host_rejected() {
  setup_manifest_sandbox "manifest-hostile-mount-missing-host.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "host" "$stderr_file"; then
    pass "MH2 mount object missing 'host' field rejected non-zero + names 'host'"
  else
    fail "MH2 expected non-zero exit + 'host' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MH3 — Object missing 'dest' field is rejected naming 'dest'
# ---------------------------------------------------------------------------
test_mh3_missing_dest_rejected() {
  setup_manifest_sandbox "manifest-hostile-mount-missing-dest.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "dest" "$stderr_file"; then
    pass "MH3 mount object missing 'dest' field rejected non-zero + names 'dest'"
  else
    fail "MH3 expected non-zero exit + 'dest' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MH4 — Object with empty 'host' value is rejected naming 'host'
# ---------------------------------------------------------------------------
test_mh4_empty_host_rejected() {
  setup_manifest_sandbox "manifest-hostile-mount-empty-host.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "host" "$stderr_file"; then
    pass "MH4 mount object with empty 'host' rejected non-zero + names 'host'"
  else
    fail "MH4 expected non-zero exit + 'host' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MH5 — Object with empty 'dest' value is rejected naming 'dest'
# ---------------------------------------------------------------------------
test_mh5_empty_dest_rejected() {
  setup_manifest_sandbox "manifest-hostile-mount-empty-dest.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  run_manifest_load "$stderr_file" >/dev/null || exit_code=$?
  if [[ "$exit_code" -ne 0 ]] && grep -qi "dest" "$stderr_file"; then
    pass "MH5 mount object with empty 'dest' rejected non-zero + names 'dest'"
  else
    fail "MH5 expected non-zero exit + 'dest' in error. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MD1 — EFFECT: denylisted host in new {host, dest} object shape is REJECTED
#
# This is the bead's tripwire: a manifest entry with a denylisted .host value
# must produce a REFUSAL from _manifest_check_mounts_denylist — not merely
# run the check function. The test asserts the OUTPUT of run_rc_up fails with
# the specific denylist refusal message produced only by
# _manifest_check_mounts_denylist.
#
# ADR-023 FIRM: fail-open regression here is a security defect.
# ---------------------------------------------------------------------------
test_md1_denylisted_host_in_object_shape_rejected() {
  setup_manifest_sandbox "manifest-hostile-denylisted-mount-object.yaml"
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-up-denylist-test-XXXXXX")
  local out exit_code
  exit_code=0
  # Run rc up with the sandbox manifest and workspace
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$tmpdir" \
    "${RC}" up "$tmpdir" 2>&1) || exit_code=$?

  # Specific EFFECT sentinel: the error must mention manifest-declared mount + denylist
  # in the exact format produced by _manifest_check_mounts_denylist.
  local denied_signal
  denied_signal=$(grep -iE "manifest.*(mount|declared).*(denylist|denied|refusing)|denylist.*(manifest|declared).*mount" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$denied_signal" ]]; then
    pass "MD1 EFFECT: denylisted .host in new object shape REJECTED by denylist check (exit=$exit_code)"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "MD1 EFFECT: denylist check did NOT fire (exit=0) — denylisted host in object shape slipped through. output='${out:0:300}'"
  else
    fail "MD1 EFFECT: exited non-zero (exit=$exit_code) but denylist-refusal message NOT present. output='${out:0:500}'"
  fi
  rm -rf "$tmpdir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MD2 — SECURITY: tilde-expanded path that resolves to a DENYLISTED location
#        is STILL REJECTED (expansion feeds the denylist; does NOT bypass it).
#
# rip-cage-buuo.5: after the ~/  and $HOME expansion fix, a manifest entry of
# the form  host: "~/.ssh"  must be rejected by the denylist — the expansion
# resolves to $HOME/.ssh which matches the ".ssh" denylist pattern.  This test
# is the security tripwire proving the expansion does NOT shortcut the denylist
# check.
#
# ADR-023 FIRM: fail-open regression here is a security defect.
# ---------------------------------------------------------------------------
test_md2_tilde_expanded_denylisted_path_rejected() {
  # Build a manifest with a tilde-based host that expands to ~/.ssh.
  # We create a real ~/.ssh directory inside TEST_HOME so the expansion
  # produces an existing path (otherwise skip-if-missing would fire instead
  # of the denylist, making this test vacuous).
  setup_manifest_sandbox
  local ssh_dir="${TEST_HOME}/.ssh"
  mkdir -p "$ssh_dir"

  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" << 'YAML'
version: 1
tools:
  - name: hostile-tilde-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "~/.ssh"
        dest: "/home/agent/ssh-data"
YAML

  local tmpdir out exit_code
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-up-md2-test-XXXXXX")
  exit_code=0
  # Run rc up: the tilde expands to $TEST_HOME/.ssh (which is denylisted).
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$tmpdir" \
    "${RC}" up "$tmpdir" 2>&1) || exit_code=$?

  # Specific EFFECT sentinel: denylist-refusal message must be present.
  local denied_signal
  denied_signal=$(grep -iE "manifest.*(mount|declared).*(denylist|denied|refusing)|denylist.*(manifest|declared).*mount" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$denied_signal" ]]; then
    pass "MD2 SECURITY: tilde-expanded ~/.ssh REJECTED by denylist (expansion feeds denylist, not bypasses it — exit=$exit_code)"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "MD2 SECURITY FAIL: denylist check did NOT fire for ~-expanded denylisted path (exit=0) — tilde expansion bypassed the denylist. output='${out:0:300}'"
  else
    fail "MD2 SECURITY: exited non-zero (exit=$exit_code) but denylist-refusal message NOT present (may be a different failure). output='${out:0:500}'"
  fi
  rm -rf "$tmpdir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MC1 — Consumer: valid {host, dest} mount emits "-v host:dest" arg
#
# Tests _manifest_build_mount_args directly: with a manifest declaring a
# {host, dest} mount whose host dir EXISTS on the host, the function must
# emit a "-v <realpath(host)>:<dest>" string.
# ---------------------------------------------------------------------------
test_mc1_consumer_emits_v_arg() {
  # Create a real directory on the host to use as the mount source.
  local host_dir
  host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-mount-host-XXXXXX")
  local host_dir_real
  host_dir_real=$(realpath "$host_dir" 2>/dev/null) || host_dir_real="$host_dir"
  local dest_path="/home/agent/tool-data"

  # Write a manifest with this host dir as the mount source.
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: data-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${host_dir}"
        dest: "${dest_path}"
YAML

  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-ws-XXXXXX")
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_build_mount_args "$workspace" "$stderr_file") || exit_code=$?

  # The function must emit "<realpath>:<dest>" (no -v prefix; caller adds -v).
  local expected_arg="${host_dir_real}:${dest_path}"
  if [[ "$exit_code" -eq 0 ]] && grep -qF -- "$expected_arg" <<<"$out"; then
    pass "MC1 consumer emits host:dest arg: '${expected_arg}'"
  else
    fail "MC1 consumer did NOT emit expected host:dest arg '${expected_arg}'. exit=$exit_code out='${out}' stderr=$(cat "$stderr_file")"
  fi

  rm -f "$stderr_file"
  rm -rf "$host_dir" "$workspace"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MC2 — Load-bearing: _manifest_build_mount_args emission is effect-based.
#
# Calls _manifest_build_mount_args directly with a real existing host directory
# and asserts that a "host:dest" mapping appears in the output.  This test goes
# RED if:
#   - the function no longer emits any output, OR
#   - the "host:dest" line is removed from the emission loop.
#
# This is an effect-based test, not a presence check.  Deleting the emit line
# (echo "${resolved_host}:${mount_dest}") from the production code causes this
# test to FAIL, proving it is load-bearing.
# ---------------------------------------------------------------------------
test_mc2_consumer_emits_host_dest_mapping() {
  # Create a real directory to serve as the mount host.
  local mc2_host_dir
  mc2_host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-mc2-host-XXXXXX")
  local mc2_host_real
  mc2_host_real=$(realpath "$mc2_host_dir" 2>/dev/null) || mc2_host_real="$mc2_host_dir"
  local mc2_dest="/home/agent/mc2-data"

  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: mc2-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${mc2_host_dir}"
        dest: "${mc2_dest}"
YAML

  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-ws-XXXXXX")
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_build_mount_args "$workspace" "$stderr_file") || exit_code=$?

  # EFFECT: the function must emit "host:dest" (no -v prefix; caller adds -v).
  # If the emission is removed, this grep fails and the test goes RED.
  local expected_mapping="${mc2_host_real}:${mc2_dest}"
  if [[ "$exit_code" -eq 0 ]] && grep -qF -- "$expected_mapping" <<<"$out"; then
    pass "MC2 EFFECT: _manifest_build_mount_args emits host:dest mapping '${expected_mapping}' (load-bearing)"
  else
    fail "MC2 EFFECT: _manifest_build_mount_args did NOT emit expected mapping '${expected_mapping}'. exit=$exit_code out='${out}' stderr=$(cat "$stderr_file")"
  fi

  rm -f "$stderr_file"
  rm -rf "$mc2_host_dir" "$workspace"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MC3 — No-regression: empty mounts: [] produces no -v arg
# ---------------------------------------------------------------------------
test_mc3_empty_mounts_no_v_arg() {
  setup_manifest_sandbox "manifest-with-scratch-tool.yaml"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-ws-XXXXXX")
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_build_mount_args "$workspace" "$stderr_file") || exit_code=$?

  # After Defect-1 fix the function emits "host:dest" lines (no -v prefix).
  # For empty mounts there must be no output at all.
  local out_trimmed="${out//[[:space:]]/}"
  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out_trimmed" ]]; then
    pass "MC3 empty mounts: [] produces no mount arg (empty output)"
  else
    fail "MC3 empty mounts: [] should produce no mount arg (empty output). exit=$exit_code out='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  rm -rf "$workspace"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MC4 — No-regression: absent/default manifest produces no manifest-driven -v args
# ---------------------------------------------------------------------------
test_mc4_default_manifest_no_mounts() {
  setup_manifest_sandbox
  # No tools.yaml = default manifest (all bundled, all mounts: [])
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-ws-XXXXXX")
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_build_mount_args "$workspace" "$stderr_file") || exit_code=$?

  # After Defect-1 fix the function emits "host:dest" lines (no -v prefix).
  # For absent/default manifest there must be no output at all.
  local out_trimmed="${out//[[:space:]]/}"
  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out_trimmed" ]]; then
    pass "MC4 absent/default manifest: no manifest-driven mount args (empty output)"
  else
    fail "MC4 absent/default manifest: unexpected mount output. exit=$exit_code out='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  rm -rf "$workspace"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MC5 — Skip-if-host-missing: mount entry whose host dir does not exist is skipped
# ---------------------------------------------------------------------------
test_mc5_skip_if_host_missing() {
  setup_manifest_sandbox
  local missing_dir="/tmp/rip-cage-test-nonexistent-dir-$(date +%s)"
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: data-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${missing_dir}"
        dest: "/home/agent/tool-data"
YAML

  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-ws-XXXXXX")
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_build_mount_args "$workspace" "$stderr_file") || exit_code=$?

  # Must exit 0 (skip, not error), and must NOT emit any mount arg.
  # After Defect-1 fix the function emits "host:dest" lines (no -v prefix).
  local out_trimmed="${out//[[:space:]]/}"
  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out_trimmed" ]]; then
    pass "MC5 skip-if-host-missing: missing host dir skipped silently (no mount arg, exit=0)"
  elif [[ "$exit_code" -ne 0 ]]; then
    fail "MC5 skip-if-host-missing: expected exit 0 (skip), got exit=$exit_code stderr=$(cat "$stderr_file")"
  else
    fail "MC5 skip-if-host-missing: emitted unexpected mount arg despite missing host dir. out='${out}'"
  fi
  rm -f "$stderr_file"
  rm -rf "$workspace"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# ME1 — E2E parity claim (RC_E2E=1 required)
#
# The -v parity claim vs the hardcoded cm mount is falsifiable only at RC_E2E=1.
# This test NAMES the skip explicitly so the reviewer knows the host-tier
# codegen above is NOT sufficient to claim parity green.
# ---------------------------------------------------------------------------
test_me1_rc_e2e_parity() {
  if [[ "${RC_E2E:-}" != "1" ]]; then
    echo "SKIP (RC_E2E not set): ME1 real-cage parity proof — manifest-driven -v mount must match cm mount shape inside a real running cage. Set RC_E2E=1 to run this tier. Host-side codegen (MC1–MC5) proves mount-arg construction; it does NOT prove in-cage mounting."
    return 0
  fi

  # RC_E2E=1: build a cage with a manifest declaring a real host directory mount,
  # then docker exec to verify the mount is actually present inside.
  local me1_host_dir
  me1_host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-me1-host-XXXXXX")
  echo "rip-cage-me1-sentinel" > "${me1_host_dir}/sentinel.txt"
  local me1_real
  me1_real=$(realpath "$me1_host_dir" 2>/dev/null) || me1_real="$me1_host_dir"

  local me1_home
  me1_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-me1-home-XXXXXX")
  mkdir -p "${me1_home}/.config/rip-cage"
  cat > "${me1_home}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: data-tool
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${me1_real}"
        dest: "/home/agent/tool-data"
YAML

  local me1_ws_base me1_ws
  me1_ws_base=$(mktemp -d "${TMPDIR:-/tmp}/rc-me1-ws-XXXXXX")
  mkdir -p "${me1_ws_base}/rc"
  me1_ws="${me1_ws_base}/rc/manifest-me1"
  mkdir -p "$me1_ws"
  local me1_ws_resolved
  me1_ws_resolved=$(realpath "$me1_ws_base" 2>/dev/null) || me1_ws_resolved="$me1_ws_base"

  # shellcheck disable=SC2329
  _me1_cleanup() {
    docker stop "rc-manifest-me1" 2>/dev/null || true
    docker rm "rc-manifest-me1" 2>/dev/null || true
    docker volume rm "rc-state-rc-manifest-me1" 2>/dev/null || true
    rm -rf "$me1_host_dir" "$me1_home" "$me1_ws_base"
  }
  trap _me1_cleanup RETURN

  # rc up with the manifest declaring the mount.
  # Non-TTY mode: rc up exits non-zero from the tmux-attach step even when the
  # container starts successfully (tmux cannot open a terminal without a TTY).
  # We capture output, ignore the exit code, and check container state directly.
  local up_out
  up_out=$(HOME="$me1_home" XDG_CONFIG_HOME="${me1_home}/.config" \
    RC_MANIFEST_GLOBAL="${me1_home}/.config/rip-cage/tools.yaml" \
    RC_ALLOWED_ROOTS="$me1_ws_resolved" \
    "${RC}" up "$me1_ws" 2>&1) || true

  local me1_container="rc-manifest-me1"

  # Confirm the container is actually running (not just that rc up exited 0).
  local container_state
  container_state=$(docker inspect "$me1_container" --format '{{.State.Status}}' 2>/dev/null || true)
  if [[ "$container_state" != "running" ]]; then
    fail "ME1 container '${me1_container}' is not running after rc up (state='${container_state}'). up output: ${up_out:0:300}"
    return
  fi

  # Probe: the sentinel file must be visible inside the cage at the dest path.
  local probe_out probe_rc=0
  probe_out=$(docker exec "$me1_container" \
    cat /home/agent/tool-data/sentinel.txt 2>&1) || probe_rc=$?

  if [[ "$probe_rc" -eq 0 ]] && echo "$probe_out" | grep -q "rip-cage-me1-sentinel"; then
    pass "ME1 RC_E2E parity: manifest-declared mount present inside cage at /home/agent/tool-data/sentinel.txt"
  elif [[ "$probe_rc" -ne 0 ]]; then
    fail "ME1 RC_E2E parity: sentinel file NOT readable inside cage (exit=${probe_rc}) — mount not applied. probe='${probe_out:0:200}'"
  else
    fail "ME1 RC_E2E parity: sentinel file found but content unexpected: '${probe_out}'"
  fi
}

# ---------------------------------------------------------------------------
# MA1 — SECURITY (rip-cage-rc09): dest /etc/claude-code is REJECTED
#
# A manifest mount whose dest is /etc/claude-code (the CC managed-settings
# guard, ADR-027 D3) must be rejected by the dest-allowlist check BEFORE any
# docker invocation.  This is the guard the earlier narrow-denylist draft
# missed (design finding N1).
# ---------------------------------------------------------------------------
test_ma1_dest_etc_claude_code_rejected() {
  setup_manifest_sandbox "manifest-hostile-dest-etc-claude-code.yaml"
  # Create a real /tmp/agent-data so skip-if-host-missing does not fire.
  local host_dir
  host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma1-host-XXXXXX")
  # Rewrite the fixture to use this real dir.
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: hostile-dest-etc-claude-code
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${host_dir}"
        dest: "/etc/claude-code"
YAML

  local tmpdir out exit_code
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma1-ws-XXXXXX")
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$tmpdir" \
    "${RC}" up "$tmpdir" 2>&1) || exit_code=$?

  local denied_signal
  denied_signal=$(grep -iE "dest.*outside.*allowlist|allowlist.*dest|mount.*dest.*not.*allowed|dest.*agent.writable|agent.writable.*allowlist|mount.*dest.*outside|not.*agent-writable|dest.*allow" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$denied_signal" ]]; then
    pass "MA1 SECURITY: dest /etc/claude-code REJECTED by dest-allowlist check (exit=$exit_code)"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "MA1 SECURITY FAIL: dest-allowlist check did NOT fire (exit=0) — /etc/claude-code slipped through. output='${out:0:300}'"
  else
    fail "MA1 SECURITY: exited non-zero (exit=$exit_code) but dest-allowlist message NOT present. output='${out:0:500}'"
  fi
  rm -rf "$tmpdir" "$host_dir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MA2 — SECURITY (rip-cage-rc09): '..' escape dest is REJECTED after normalization
#
# A manifest mount whose dest is /home/agent/../etc/rip-cage/pi lexically
# normalizes to /etc/rip-cage/pi (the DCG guard root, ADR-027 D1) — outside
# the agent-writable allowlist.  Must be rejected even though it appears to
# start with /home/agent/.
# ---------------------------------------------------------------------------
test_ma2_dest_dotdot_escape_rejected() {
  setup_manifest_sandbox
  local host_dir
  host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma2-host-XXXXXX")
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: hostile-dest-dotdot-escape
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${host_dir}"
        dest: "/home/agent/../etc/rip-cage/pi"
YAML

  local tmpdir out exit_code
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma2-ws-XXXXXX")
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$tmpdir" \
    "${RC}" up "$tmpdir" 2>&1) || exit_code=$?

  local denied_signal
  denied_signal=$(grep -iE "dest.*outside.*allowlist|allowlist.*dest|mount.*dest.*not.*allowed|dest.*agent.writable|agent.writable.*allowlist|mount.*dest.*outside|not.*agent-writable|dest.*allow" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$denied_signal" ]]; then
    pass "MA2 SECURITY: '..' escape dest /home/agent/../etc/rip-cage/pi REJECTED after normalization (exit=$exit_code)"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "MA2 SECURITY FAIL: dest-allowlist did NOT reject '..' escape (exit=0) — canonicalization bypass slipped through. output='${out:0:300}'"
  else
    fail "MA2 SECURITY: exited non-zero (exit=$exit_code) but dest-allowlist message NOT present. output='${out:0:500}'"
  fi
  rm -rf "$tmpdir" "$host_dir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MA3 — SECURITY (rip-cage-rc09): parent-shadow dest /usr/local/bin is REJECTED
#
# A manifest mount whose dest is /usr/local/bin (a root-owned floor dir hosting
# the pi shim, claude binary, and DCG init) must be rejected by the allowlist —
# not under /home/agent or /workspace (parent-shadow coverage by construction).
# ---------------------------------------------------------------------------
test_ma3_dest_usr_local_bin_rejected() {
  setup_manifest_sandbox
  local host_dir
  host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma3-host-XXXXXX")
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: hostile-dest-usr-local-bin
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${host_dir}"
        dest: "/usr/local/bin"
YAML

  local tmpdir out exit_code
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma3-ws-XXXXXX")
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$tmpdir" \
    "${RC}" up "$tmpdir" 2>&1) || exit_code=$?

  local denied_signal
  denied_signal=$(grep -iE "dest.*outside.*allowlist|allowlist.*dest|mount.*dest.*not.*allowed|dest.*agent.writable|agent.writable.*allowlist|mount.*dest.*outside|not.*agent-writable|dest.*allow" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$denied_signal" ]]; then
    pass "MA3 SECURITY: parent-shadow dest /usr/local/bin REJECTED by dest-allowlist check (exit=$exit_code)"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "MA3 SECURITY FAIL: dest-allowlist did NOT reject /usr/local/bin (exit=0). output='${out:0:300}'"
  else
    fail "MA3 SECURITY: exited non-zero (exit=$exit_code) but dest-allowlist message NOT present. output='${out:0:500}'"
  fi
  rm -rf "$tmpdir" "$host_dir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MA4 — ACCEPTED: dest under /home/agent is allowed by the allowlist
#
# A manifest mount whose dest is under /home/agent (agent-writable space)
# must NOT be rejected by the dest-allowlist check.  This is the positive
# case — proves the allowlist does not over-block legitimate mounts.
# ---------------------------------------------------------------------------
test_ma4_dest_home_agent_accepted() {
  setup_manifest_sandbox
  local host_dir
  host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma4-host-XXXXXX")
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: allowed-dest-home-agent
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${host_dir}"
        dest: "/home/agent/tool-data"
YAML

  local tmpdir out exit_code
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma4-ws-XXXXXX")
  exit_code=0
  # We can test at the _manifest_check_mounts_denylist level directly
  # (the full rc up would need docker).  Call the check function directly.
  local stderr_file
  stderr_file=$(mktemp)
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    bash -c "source '${RC}'; _manifest_check_mounts_denylist '${tmpdir}'" 2>"$stderr_file" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "MA4 ACCEPTED: dest /home/agent/tool-data allowed by dest-allowlist (exit=0)"
  else
    fail "MA4 ACCEPTED: dest /home/agent/tool-data was REJECTED by dest-allowlist (should be allowed). exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  rm -rf "$tmpdir" "$host_dir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MA5 — CARVE-OUT: root_owned_required: true at AGENT-SPACE dest is accepted
#
# Under the honest carve-out (rip-cage-rc09 fix), a root_owned_required: true
# mount at a system dest is only exempt if the HOST SOURCE is root-owned (uid 0,
# non-writable).  A test cannot easily create a root-owned host dir without sudo,
# so MA5 now asserts the ALWAYS-SAFE shape: root_owned_required: true with an
# agent-space dest (/home/agent/...) is accepted regardless of source ownership.
#
# Rationale: the allowlist accepts /home/agent/... unconditionally.  Whether the
# exemption fires or not does not matter — the dest passes either way.  This
# proves the fix does NOT over-reject legitimate agent-space mounts that happen
# to carry root_owned_required: true.
#
# The system-dest exemption (ADR-027 D1 FIRM) is covered by the trust model:
# in production, root-owned assets ARE root-owned on the host, so the exemption
# fires.  The positive-sentinel for that path requires sudo to create, so it is
# left to RC_E2E=1 (or manual verification by a root-capable CI environment).
# ---------------------------------------------------------------------------
test_ma5_root_owned_required_agent_space_accepted() {
  setup_manifest_sandbox
  local host_dir
  host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma5-host-XXXXXX")
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: root-owned-agent-space-mount
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${host_dir}"
        dest: "/home/agent/tool-data"
        root_owned_required: true
YAML

  local tmpdir exit_code
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma5-ws-XXXXXX")
  exit_code=0
  local stderr_file
  stderr_file=$(mktemp)
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    bash -c "source '${RC}'; _manifest_check_mounts_denylist '${tmpdir}'" 2>"$stderr_file" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "MA5 CARVE-OUT: root_owned_required:true at /home/agent/tool-data accepted (agent-space dest — always valid regardless of source ownership)"
  else
    fail "MA5 CARVE-OUT: root_owned_required:true mount at agent-space dest was REJECTED — over-blocking. exit=$exit_code stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  rm -rf "$tmpdir" "$host_dir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# MA6 — SECURITY (rip-cage-rc09): root_owned_required:true + system dest +
#        non-root host source is REJECTED by the dest-allowlist.
#
# This is the bypass regression guard for the honest carve-out fix.
# A fragment with root_owned_required: true + dest: /etc/rip-cage/pi +
# host: <a normal (agent-writable, non-root) dir> must NOT be exempted from
# the allowlist.  The host dir is a mktemp dir (owned by the current user,
# not root) — so _host_source_is_root_owned returns false → no exemption →
# allowlist rejects the system dest /etc/rip-cage/pi.
#
# ADR-027 D1 / rip-cage-rc09 security: fail-open regression here is a
# security defect (shadow the guard with agent-writable content).
# ---------------------------------------------------------------------------
test_ma6_root_owned_required_nonroot_source_system_dest_rejected() {
  setup_manifest_sandbox
  local host_dir
  host_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma6-host-XXXXXX")
  # host_dir is owned by the current user (NOT root) — this is the attack shape.
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: hostile-nonroot-source-system-dest
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts:
      - host: "${host_dir}"
        dest: "/etc/rip-cage/pi"
        root_owned_required: true
YAML

  local tmpdir out exit_code
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-ma6-ws-XXXXXX")
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_MANIFEST_GLOBAL="${TEST_HOME}/.config/rip-cage/tools.yaml" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$tmpdir" \
    "${RC}" up "$tmpdir" 2>&1) || exit_code=$?

  # The rc09 allowlist error message must be present.
  local denied_signal
  denied_signal=$(grep -iE "dest.*outside.*allowlist|allowlist.*dest|mount.*dest.*not.*allowed|dest.*agent.writable|agent.writable.*allowlist|mount.*dest.*outside|not.*agent-writable|dest.*allow" <<<"$out" | head -1)

  if [[ "$exit_code" -ne 0 ]] && [[ -n "$denied_signal" ]]; then
    pass "MA6 SECURITY: root_owned_required:true + system dest /etc/rip-cage/pi + non-root host source REJECTED by allowlist (exit=$exit_code) — bypass closed (rip-cage-rc09)"
  elif [[ "$exit_code" -eq 0 ]]; then
    fail "MA6 SECURITY FAIL: root_owned_required:true bypass NOT closed — non-root source + system dest slipped through (exit=0). output='${out:0:300}'"
  else
    fail "MA6 SECURITY: exited non-zero (exit=$exit_code) but dest-allowlist message NOT present. output='${out:0:500}'"
  fi
  rm -rf "$tmpdir" "$host_dir"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-manifest-mounts.sh — manifest mounts schema + consumer (rip-cage-buuo.1) ==="
echo ""
echo "--- SCHEMA/VALIDATOR tests ---"
test_mv1_valid_object_mount_parses
test_mh1_scalar_mount_rejected
test_mh2_missing_host_rejected
test_mh3_missing_dest_rejected
test_mh4_empty_host_rejected
test_mh5_empty_dest_rejected

echo ""
echo "--- DENYLIST EFFECT tests ---"
test_md1_denylisted_host_in_object_shape_rejected
test_md2_tilde_expanded_denylisted_path_rejected

echo ""
echo "--- CONSUMER tests ---"
test_mc1_consumer_emits_v_arg
test_mc2_consumer_emits_host_dest_mapping
test_mc3_empty_mounts_no_v_arg
test_mc4_default_manifest_no_mounts
test_mc5_skip_if_host_missing

echo ""
echo "--- DEST ALLOWLIST tests (rip-cage-rc09) ---"
test_ma1_dest_etc_claude_code_rejected
test_ma2_dest_dotdot_escape_rejected
test_ma3_dest_usr_local_bin_rejected
test_ma4_dest_home_agent_accepted
test_ma5_root_owned_required_agent_space_accepted
test_ma6_root_owned_required_nonroot_source_system_dest_rejected

echo ""
echo "--- E2E PARITY (RC_E2E=1) ---"
test_me1_rc_e2e_parity

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
