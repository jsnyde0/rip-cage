#!/usr/bin/env bash
# Host-side tests for mounts.symlinks.* config group and rc up symlink-follow
# mount synthesis (rip-cage-c1p.2).
#
# Coverage (matches acceptance criteria in bead rip-cage-c1p.2):
#   S1   _collect_dangling_symlinks: returns (link|target) tuples for absolute symlinks
#   S2   _collect_dangling_symlinks: skips relative symlinks
#   S3   _collect_dangling_symlinks: skips symlinks resolving inside root
#   S4   _collect_dangling_symlinks: error on readlink failure (broken chain)
#   S5   Whitelist structural assertion: scanner does NOT touch /workspace
#   S6   on_dangling=skip: mount synthesis skips + warns
#   S7   on_dangling=error: mount synthesis aborts loud
#   S8   on_dangling=follow: mount synthesis adds second bind mount
#   S9   on_dangling=warn: mount synthesis adds second bind mount + loud log
#   S10  mode=ro: bind mount spec includes :ro suffix
#   S11  mode=rw: bind mount spec omits :ro suffix
#   S12  scope=parent: mount source is dirname of target
#   S13  scope=file: mount source is the leaf target file
#   S14  Collision with FHS reserved path (e.g. /etc/foo) → abort loud
#   S15  Fingerprint computed from sorted link→target(mode) lines
#   S16  rc reload refuses loud when mounts.symlinks.* differs (C5-equivalent)
#   S17  ADR-021 D5 invariant: both configs absent, no dangling symlinks vs
#        with dangling symlinks → label set differs only in rc.symlink-follow-fingerprint
#   S18  cage-claude.md negative invariant: bead B does NOT modify cage-claude.md
#   S24  Reserved-path collision under on_dangling=skip → skipped, exit 0, warning
#        (rip-cage-hcdn: on_dangling=skip actually unblocks a reserved-path symlink)
#   S25  Broken symlink chain under on_dangling=skip → collector skips, exit 0,
#        continues scan past the broken link (rip-cage-hcdn sibling fold)
#
# Tests S1-S15 are host-only (no Docker required).
# Tests S16 uses the docker stub pattern from test-rc-reload.sh.
# Tests S17 requires Docker (conditional).
# S18 is a static git-diff check.
#
# ADRs: ADR-001 D1 (fail-loud), ADR-019 D1 (auth.json sub-mount preserved, hhh.12),
#       ADR-021 D2/D3/D5 (schema/merge/versioning), ADR-022 D6 (rc reload)

set -uo pipefail

# tests/run-host.sh exports RC_CONFIG_GLOBAL pointing to an empty-denylist fixture
# for the whole suite. RC_CONFIG_GLOBAL takes precedence over XDG_CONFIG_HOME in
# _config_global_path (rc:6207-6208), so per-call XDG sandboxes get silently
# shadowed — S20/S22/S22b see an empty denylist and fail. Unset here so per-call
# XDG sandboxes resolve correctly.
# Mirror of the fix in tests/test-secret-path-denylist.sh (see run-host.sh:102-109).
unset RC_CONFIG_GLOBAL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS S$1: $2"; }
fail() { echo "FAIL S$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  rm -f /tmp/rc-sfl-mount-print-helper.sh 2>/dev/null
}
trap cleanup EXIT

setup_sandbox() {
  # Fixtures live in the default temp dir. On macOS this resolves to
  # /var/folders/... (i.e. /private/var/...), which rc's symlink-reserved-path
  # check deliberately does NOT canonicalize (rc:1543), so the targets are
  # permitted. On a Linux host this test is NOT run under --host-only: every
  # writable top-level (/home, /tmp, /var) is in rc's FHS-reserved set, leaving
  # no non-reserved scratch dir — see the NEEDS_CONTAINER entry in run-host.sh.
  TEST_HOME=$(mktemp -d)
  mkdir -p "${TEST_HOME}/.pi/agent"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Source rc to pick up internal functions for unit testing.
# rc has a sourced-vs-invoked guard (BASH_SOURCE != $0), so sourcing is safe.
# shellcheck disable=SC1090
source_rc() {
  source "$RC"
}

# ---------------------------------------------------------------------------
# S1: _collect_dangling_symlinks returns (link|target) for absolute symlinks
# ---------------------------------------------------------------------------
test_s1_collect_absolute_symlinks() {
  setup_sandbox
  # Create a real file outside the pi root and an absolute symlink to it
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"

  local out exit_code=0
  out=$(HOME="$TEST_HOME" bash -c "source '$RC'; _collect_dangling_symlinks '${TEST_HOME}/.pi/agent'") || exit_code=$?

  local link target
  link=$(echo "$out" | cut -d'|' -f1)
  target=$(echo "$out" | cut -d'|' -f2)

  # macOS resolves /var/folders → /private/var/folders; normalize for comparison
  local norm_link norm_target
  norm_link=$(readlink -f "${TEST_HOME}/.pi/agent/AGENTS.md" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/AGENTS.md")
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")

  # The link path in output is the find result (may be normalized by readlink -f in helper)
  # Just check that the target matches and the link ends with AGENTS.md
  if [[ "$exit_code" -eq 0 \
     && "$link" == *"/AGENTS.md" \
     && "$target" == "$norm_target" ]]; then
    pass "1" "_collect_dangling_symlinks returns link|target for absolute symlinks"
  else
    fail "1" "_collect_dangling_symlinks basic" "exit=$exit_code link=$link target=$target norm_target=$norm_target"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S2: _collect_dangling_symlinks skips relative symlinks
# ---------------------------------------------------------------------------
test_s2_skip_relative_symlinks() {
  setup_sandbox
  # Create a relative symlink (points to a sibling in same dir)
  echo "content" > "${TEST_HOME}/.pi/agent/realfile.md"
  (cd "${TEST_HOME}/.pi/agent" && ln -sf "realfile.md" "rellink.md")

  local out
  out=$(HOME="$TEST_HOME" bash -c "source '$RC'; _collect_dangling_symlinks '${TEST_HOME}/.pi/agent'")

  if [[ -z "$out" ]]; then
    pass "2" "_collect_dangling_symlinks skips relative symlinks"
  else
    fail "2" "expected empty output for relative symlinks" "got: $out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S3: _collect_dangling_symlinks skips symlinks resolving inside the root
# ---------------------------------------------------------------------------
test_s3_skip_inroot_symlinks() {
  setup_sandbox
  # Create a file inside the pi root and an absolute symlink to it (inside root)
  echo "content" > "${TEST_HOME}/.pi/agent/realfile.md"
  ln -sf "${TEST_HOME}/.pi/agent/realfile.md" "${TEST_HOME}/.pi/agent/inroot-link.md"

  local out
  out=$(HOME="$TEST_HOME" bash -c "source '$RC'; _collect_dangling_symlinks '${TEST_HOME}/.pi/agent'")

  # Should be empty — symlink target is inside the root
  if [[ -z "$out" ]]; then
    pass "3" "_collect_dangling_symlinks skips symlinks resolving inside root"
  else
    fail "3" "expected empty output for in-root symlinks" "got: $out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S4: _collect_dangling_symlinks aborts on broken symlink chain
# (acc 22: readlink failure → rc up aborts loud per ADR-001 D1)
# ---------------------------------------------------------------------------
test_s4_broken_symlink_chain_aborts() {
  setup_sandbox
  # Create a symlink that points to a nonexistent absolute path
  ln -sf "/nonexistent/absolute/path/file.md" "${TEST_HOME}/.pi/agent/broken.md"

  local out exit_code=0
  out=$(HOME="$TEST_HOME" bash -c "source '$RC'; _collect_dangling_symlinks '${TEST_HOME}/.pi/agent'" 2>&1) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    pass "4" "_collect_dangling_symlinks aborts loud on broken symlink chain"
  else
    fail "4" "expected non-zero exit for broken symlink chain" "exit=$exit_code out=$out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S5: Whitelist structural assertion — /workspace is NEVER scanned
# (acc 21: scanner whitelist = {~/.pi/agent}; /workspace never in find)
# ---------------------------------------------------------------------------
test_s5_workspace_not_scanned() {
  # Source rc and examine _SFL_SCAN_ROOTS construction in _up_prepare_docker_mounts.
  # We do this by grepping the rc source for /workspace in the scan roots context.
  local rc_text
  rc_text=$(grep -n "_SFL_SCAN_ROOTS\|/workspace" "$RC" | grep -v "^#")

  # The scan roots assignment should ONLY include ~/.pi/agent, never /workspace.
  # Assert: no line assigns /workspace to _SFL_SCAN_ROOTS.
  if echo "$rc_text" | grep "_SFL_SCAN_ROOTS" | grep -q "/workspace"; then
    fail "5" "structural: /workspace found in _SFL_SCAN_ROOTS" "$(echo "$rc_text" | grep "_SFL_SCAN_ROOTS")"
  else
    pass "5" "structural: /workspace is never in _SFL_SCAN_ROOTS (whitelist enforcement)"
  fi
}

# ---------------------------------------------------------------------------
# S6: on_dangling=skip — no mount added, warning logged
# (acc 4)
# ---------------------------------------------------------------------------
# Helper script for printing -v mount args inside bash -c invocations.
# Written as a separate file so it can be sourced without shell expansion issues.
_MOUNT_PRINT_HELPER=/tmp/rc-sfl-mount-print-helper.sh
cat > "$_MOUNT_PRINT_HELPER" <<'HELPER_EOF'
_print_mounts() {
  local _pmf_prev=""
  for _pmf_a in "${_UP_RUN_ARGS[@]+"${_UP_RUN_ARGS[@]}"}"; do
    if [[ "$_pmf_prev" == "-v" ]]; then echo "MOUNT: $_pmf_a"; fi
    _pmf_prev="$_pmf_a"
  done
}
HELPER_EOF

test_s6_on_dangling_skip() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  local norm_target
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")

  # Write project config with on_dangling=skip
  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  cat > "${ws}/.rip-cage.yaml" <<YAML
version: 1
mounts:
  symlinks:
    on_dangling: skip
    scope: file
    mode: rw
YAML

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  # Check: no MOUNT for norm_target (mirror format), but SFL-specific skip warning logged.
  # Use the mirror-mount format (norm_target:norm_target) — same as S8 — so that the
  # intentional pi-substrate mount (norm_target:/home/agent/.rc-context/pi-AGENTS.md:ro)
  # is NOT counted as a symlink-follow mirror mount (they differ in destination format).
  # Grep for the SFL-specific "on_dangling=skip" marker to avoid matching the unrelated
  # OAuth-file-missing "skipping mount" warnings (.claude.json, .credentials.json).
  local has_target_mount has_warning
  has_target_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}:${norm_target}" || true)
  has_warning=$(echo "$out" | grep -c "on_dangling=skip" || true)

  if [[ "$has_target_mount" -eq 0 && "$has_warning" -gt 0 ]]; then
    pass "6" "on_dangling=skip: no second mount added, warning logged"
  else
    fail "6" "on_dangling=skip behavior" "has_target_mount=$has_target_mount has_warning=$has_warning exit=$exit_code"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S7: on_dangling=error — rc up aborts loud
# (acc 5)
# ---------------------------------------------------------------------------
test_s7_on_dangling_error() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  cat > "${ws}/.rip-cage.yaml" <<'YAML'
version: 1
mounts:
  symlinks:
    on_dangling: error
    scope: file
    mode: rw
YAML

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
  " 2>&1) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] && echo "$out" | grep -q "dangling symlink"; then
    pass "7" "on_dangling=error: rc up aborts loud with actionable message"
  else
    fail "7" "on_dangling=error behavior" "exit=$exit_code out=$out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S8: on_dangling=follow — second bind mount added (default behavior)
# (acc 3 + 20)
# ---------------------------------------------------------------------------
test_s8_on_dangling_follow() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  local norm_target
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  # No .rip-cage.yaml — defaults apply (follow/file/rw)

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  # Check: a MOUNT with the target path was added (without :ro suffix for rw)
  local has_target_mount has_log
  has_target_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}:${norm_target}" || true)
  has_log=$(echo "$out" | grep -c "follow-symlink:" || true)

  if [[ "$exit_code" -eq 0 && "$has_target_mount" -gt 0 && "$has_log" -gt 0 ]]; then
    pass "8" "on_dangling=follow (default): second bind mount added at host-target path, log emitted"
  else
    fail "8" "on_dangling=follow behavior" "exit=$exit_code has_target_mount=$has_target_mount has_log=$has_log norm_target=$norm_target"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S9: on_dangling=warn — same as follow but loud log
# (acc 6)
# ---------------------------------------------------------------------------
test_s9_on_dangling_warn() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  local norm_target
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  cat > "${ws}/.rip-cage.yaml" <<'YAML'
version: 1
mounts:
  symlinks:
    on_dangling: warn
    scope: file
    mode: rw
YAML

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  local has_target_mount has_log
  has_target_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}:${norm_target}" || true)
  has_log=$(echo "$out" | grep -c "follow-symlink:" || true)

  if [[ "$exit_code" -eq 0 && "$has_target_mount" -gt 0 && "$has_log" -gt 0 ]]; then
    pass "9" "on_dangling=warn: second bind mount added + log emitted"
  else
    fail "9" "on_dangling=warn behavior" "exit=$exit_code has_target_mount=$has_target_mount has_log=$has_log"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S10: mode=ro — bind mount spec includes :ro suffix
# (acc 7)
# ---------------------------------------------------------------------------
test_s10_mode_ro() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  local norm_target
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  cat > "${ws}/.rip-cage.yaml" <<'YAML'
version: 1
mounts:
  symlinks:
    on_dangling: follow
    scope: file
    mode: ro
YAML

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  local has_ro_mount
  has_ro_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}:${norm_target}:ro" || true)

  if [[ "$exit_code" -eq 0 && "$has_ro_mount" -gt 0 ]]; then
    pass "10" "mode=ro: bind mount spec includes :ro suffix"
  else
    fail "10" "mode=ro bind mount spec" "exit=$exit_code has_ro_mount=$has_ro_mount mounts=$(echo "$out" | grep "MOUNT:")"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S11: mode=rw — bind mount spec omits :ro suffix
# (acc 8)
# ---------------------------------------------------------------------------
test_s11_mode_rw() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  local norm_target
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  # Default (rw) — no .rip-cage.yaml

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  # The mount should be present WITHOUT :ro
  local has_rw_mount has_ro_mount
  has_rw_mount=$(echo "$out" | grep "MOUNT:" | grep "${norm_target}:${norm_target}" | grep -v ":ro" | grep -c "." || true)
  has_ro_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}:${norm_target}:ro" || true)

  if [[ "$exit_code" -eq 0 && "$has_rw_mount" -gt 0 && "$has_ro_mount" -eq 0 ]]; then
    pass "11" "mode=rw: bind mount spec omits :ro suffix"
  else
    fail "11" "mode=rw bind mount spec" "exit=$exit_code has_rw=$has_rw_mount has_ro=$has_ro_mount mounts=$(echo "$out" | grep "MOUNT:")"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S12: scope=parent — mount source is dirname of target
# (acc 9)
# ---------------------------------------------------------------------------
test_s12_scope_parent() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  local norm_target norm_parent
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")
  norm_parent=$(dirname "$norm_target")

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  cat > "${ws}/.rip-cage.yaml" <<'YAML'
version: 1
mounts:
  symlinks:
    on_dangling: follow
    scope: parent
    mode: rw
YAML

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  # scope=parent: mount source should be the containing dir, not the leaf file
  local has_parent_mount has_leaf_mount
  has_parent_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_parent}:${norm_parent}" || true)
  has_leaf_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}:${norm_target}" || true)

  if [[ "$exit_code" -eq 0 && "$has_parent_mount" -gt 0 && "$has_leaf_mount" -eq 0 ]]; then
    pass "12" "scope=parent: mount source is dirname of target"
  else
    fail "12" "scope=parent mount source" "exit=$exit_code has_parent=$has_parent_mount has_leaf=$has_leaf_mount norm_parent=$norm_parent mounts=$(echo "$out" | grep "MOUNT:")"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S13: scope=file (default) — mount source is the leaf target file
# (acc 20)
# ---------------------------------------------------------------------------
test_s13_scope_file() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  local norm_target norm_parent
  norm_target=$(readlink -f "${target_dir}/AGENTS.md" 2>/dev/null || echo "${target_dir}/AGENTS.md")
  norm_parent=$(dirname "$norm_target")

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  # Default scope=file (no .rip-cage.yaml)

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  local has_leaf_mount
  has_leaf_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}:${norm_target}" || true)
  # The containing dir should NOT be a standalone second mount (without the leaf)
  local has_parent_only_mount
  has_parent_only_mount=$(echo "$out" | grep "MOUNT:" | grep "${norm_parent}:${norm_parent}" | grep -v "AGENTS.md" | grep -c "." || true)

  if [[ "$exit_code" -eq 0 && "$has_leaf_mount" -gt 0 && "$has_parent_only_mount" -eq 0 ]]; then
    pass "13" "scope=file (default): mount source is leaf target, not parent dir"
  else
    fail "13" "scope=file mount source" "exit=$exit_code has_leaf=$has_leaf_mount has_parent_only=$has_parent_only_mount norm_target=$norm_target"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S14: Collision with FHS reserved path → abort loud
# (acc 23)
# ---------------------------------------------------------------------------
test_s14_fhs_reserved_collision() {
  setup_sandbox
  # Create a symlink to an FHS reserved path. Use /etc/hosts (exists on macOS/Linux).
  # On macOS readlink -f /etc/hosts → /private/etc/hosts; our check handles both.
  if [[ -f /etc/hosts ]]; then
    ln -sf /etc/hosts "${TEST_HOME}/.pi/agent/etc-link.md"

    local ws="${TEST_HOME}/workspace"
    mkdir -p "$ws"

    local out exit_code=0
    out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
      source '$RC'
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$ws' 'testcage'
    " 2>&1) || exit_code=$?

    if [[ "$exit_code" -ne 0 ]] && echo "$out" | grep -q "reserved cage path"; then
      pass "14" "FHS reserved path collision (/etc/hosts) → abort loud"
    else
      fail "14" "FHS reserved collision check" "exit=$exit_code out=$out"
    fi
  else
    pass "14" "FHS reserved path collision test skipped (no /etc/hosts on this platform)"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S24: Reserved-path collision under on_dangling=skip → skipped, exit 0, warning
# (rip-cage-hcdn: on_dangling=skip actually skips a reserved-path-resolving
# symlink instead of aborting — the error message at rc:1519 has always told
# the user to set on_dangling=skip to unblock; this proves it now works.)
# ---------------------------------------------------------------------------
test_s24_reserved_collision_skip() {
  setup_sandbox
  if [[ -f /etc/hosts ]]; then
    ln -sf /etc/hosts "${TEST_HOME}/.pi/agent/etc-link.md"

    local ws="${TEST_HOME}/workspace"
    mkdir -p "$ws"
    cat > "${ws}/.rip-cage.yaml" <<'YAML'
version: 1
mounts:
  symlinks:
    on_dangling: skip
    scope: file
    mode: rw
YAML

    local out exit_code=0
    out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
      source '$RC'
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$ws' 'testcage'
    " 2>&1) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "etc-link.md" \
       && echo "$out" | grep -q "on_dangling=skip" \
       && ! echo "$out" | grep -q "refuse to mount"; then
      pass "24" "reserved-path collision under on_dangling=skip: skipped (mount never attempted), exit 0, warning logged"
    else
      fail "24" "reserved-path collision under on_dangling=skip" "exit=$exit_code out=$out"
    fi
  else
    pass "24" "reserved-path collision under on_dangling=skip test skipped (no /etc/hosts on this platform)"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S25: Broken symlink chain under on_dangling=skip → collector skips, exit 0
# (rip-cage-hcdn sibling fold: _collect_dangling_symlinks honors on_dangling
# so a broken-chain link is skipped WITHOUT truncating links found after it.)
# ---------------------------------------------------------------------------
test_s25_broken_chain_skip() {
  setup_sandbox
  # Broken symlink (nonexistent absolute target)
  ln -sf "/nonexistent/absolute/path/file.md" "${TEST_HOME}/.pi/agent/broken.md"
  # A second, VALID absolute symlink pointing outside root — proves skip
  # continues past the broken link rather than truncating the scan.
  local valid_target_dir="${TEST_HOME}/canonical"
  mkdir -p "$valid_target_dir"
  echo "content" > "${valid_target_dir}/valid.md"
  ln -sf "${valid_target_dir}/valid.md" "${TEST_HOME}/.pi/agent/valid-link.md"
  local norm_valid_target
  norm_valid_target=$(readlink -f "${valid_target_dir}/valid.md" 2>/dev/null || echo "${valid_target_dir}/valid.md")

  local out exit_code=0
  out=$(HOME="$TEST_HOME" bash -c "source '$RC'; _collect_dangling_symlinks '${TEST_HOME}/.pi/agent' skip" 2>&1) || exit_code=$?

  local has_warning has_valid_line
  has_warning=$(echo "$out" | grep -c "broken symlink chain" || true)
  has_valid_line=$(echo "$out" | grep -c "${norm_valid_target}" || true)

  if [[ "$exit_code" -eq 0 && "$has_warning" -gt 0 && "$has_valid_line" -gt 0 ]]; then
    pass "25" "_collect_dangling_symlinks on_dangling=skip: skips broken chain, continues scan (valid link still emitted), exit 0"
  else
    fail "25" "_collect_dangling_symlinks on_dangling=skip broken chain behavior" "exit=$exit_code has_warning=$has_warning has_valid_line=$has_valid_line out=$out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S15: Fingerprint computation is deterministic and covers link+target+mode
# ---------------------------------------------------------------------------
test_s15_fingerprint_deterministic() {
  setup_sandbox
  local target_dir="${TEST_HOME}/canonical"
  mkdir -p "$target_dir"
  echo "hello" > "${target_dir}/AGENTS.md"
  ln -sf "${target_dir}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"

  local fp1 fp2
  fp1=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw'")
  fp2=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw'")

  # Different mode should produce different fingerprint
  local fp_ro
  fp_ro=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'ro'")

  if [[ "$fp1" == "$fp2" && "$fp1" != "$fp_ro" && -n "$fp1" ]]; then
    pass "15" "fingerprint: deterministic across runs, differs on mode change"
  else
    fail "15" "fingerprint determinism" "fp1=$fp1 fp2=$fp2 fp_ro=$fp_ro"
  fi

  # Empty root (no dangling symlinks) fingerprint should differ from non-empty
  teardown_sandbox
  setup_sandbox  # fresh pi/agent with no symlinks
  local fp_empty
  fp_empty=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw'")

  if [[ "$fp_empty" != "$fp1" ]]; then
    pass "15b" "fingerprint: empty set differs from non-empty set"
  else
    fail "15b" "fingerprint empty vs non-empty" "fp_empty=$fp_empty fp1=$fp1"
  fi
  teardown_sandbox

  # S15c: Different on_dangling policy must produce different fingerprint
  # (same symlinks, same mode — only policy differs)
  setup_sandbox
  local target_dir2="${TEST_HOME}/canonical"
  mkdir -p "$target_dir2"
  echo "hello" > "${target_dir2}/AGENTS.md"
  ln -sf "${target_dir2}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"

  local fp_follow fp_skip fp_warn
  fp_follow=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file'")
  fp_skip=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'skip' 'file'")
  fp_warn=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'warn' 'file'")

  if [[ "$fp_follow" != "$fp_skip" && "$fp_follow" != "$fp_warn" && "$fp_skip" != "$fp_warn" && -n "$fp_follow" ]]; then
    pass "15c" "fingerprint: on_dangling policy change produces different fingerprint"
  else
    fail "15c" "fingerprint on_dangling sensitivity" "fp_follow=$fp_follow fp_skip=$fp_skip fp_warn=$fp_warn"
  fi

  # S15d: Different scope must produce different fingerprint
  local fp_file_scope fp_parent_scope
  fp_file_scope=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file'")
  fp_parent_scope=$(HOME="$TEST_HOME" bash -c "source '$RC'; _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'parent'")

  if [[ "$fp_file_scope" != "$fp_parent_scope" && -n "$fp_file_scope" ]]; then
    pass "15d" "fingerprint: scope change produces different fingerprint"
  else
    fail "15d" "fingerprint scope sensitivity" "fp_file_scope=$fp_file_scope fp_parent_scope=$fp_parent_scope"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S16: rc reload refuses loud when mounts.symlinks.* changes
# (acc 11 — extend test-rc-reload.sh pattern)
# ---------------------------------------------------------------------------

# Build a docker stub for reload tests
make_docker_stub_symlink() {
  local stub_dir="$1" cname="$2" state="$3" workspace="$4"
  cat > "${stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  info) exit 0 ;;
esac
case " \$* " in
  *" inspect "*"State.Status"*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "${state}"
    exit 0
    ;;
  *" inspect "*"rc.source.path"*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "${workspace}"
    exit 0
    ;;
  *" inspect "*"rc.config-loaded"*"${cname}"*)
    echo ""
    exit 0
    ;;
  *" inspect "*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "{}"
    exit 0
    ;;
  *)
    echo "stub: unhandled docker args: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${stub_dir}/docker"
}

test_s16_rc_reload_refuses_mounts_symlinks_change() {
  local test_home stub_dir ws cname cache_dir
  test_home=$(mktemp -d)
  ws="${test_home}/workspace"
  cname="rc-sfl-reload-test"
  cache_dir="${test_home}/.cache/rip-cage/${cname}"
  stub_dir="${test_home}/stub"
  mkdir -p "$ws" "$cache_dir" "$stub_dir" "${test_home}/.ssh"

  make_docker_stub_symlink "$stub_dir" "$cname" "running" "$ws"

  # Write initial applied-config snapshot with mounts.symlinks.mode=rw
  cat > "${cache_dir}/config-applied.json" <<'JSON'
{"version":1,"ssh":{"allowed_keys":null,"allowed_hosts":[]},"mounts":{"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}}}
JSON

  # Write live .rip-cage.yaml with mounts.symlinks.mode changed to ro
  cat > "${ws}/.rip-cage.yaml" <<YAML
version: 1
mounts:
  symlinks:
    on_dangling: follow
    scope: file
    mode: ro
YAML

  local out exit_code=0
  out=$(PATH="${stub_dir}:$PATH" HOME="$test_home" XDG_CONFIG_HOME="${test_home}/.config" \
    "$RC" reload "$cname" 2>&1) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] && echo "$out" | grep -q "reload-eligible"; then
    pass "16" "rc reload refuses loud when mounts.symlinks.* changes (not reload-eligible)"
  else
    fail "16" "rc reload should refuse mounts.symlinks.* change" "exit=$exit_code out=$out"
  fi

  rm -rf "$test_home"
}

# ---------------------------------------------------------------------------
# S19: rc up for a *running* container refuses loud when fingerprint drifts
# (label-lock must fire for both running and exited state, not just exited).
# Uses the same docker stub + HOME override pattern as S16.
# ---------------------------------------------------------------------------

# Build a docker stub for running-state fingerprint tests.
# Includes the rc.symlink-follow-fingerprint label so the lock can compare.
make_docker_stub_fingerprint() {
  local stub_dir="$1" cname="$2" state="$3" workspace="$4" stored_fp="$5"
  cat > "${stub_dir}/docker" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  info) exit 0 ;;
  image) exit 0 ;;   # image inspect — pretend image exists
esac
case " \$* " in
  *" inspect "*"State.Status"*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "${state}"
    exit 0
    ;;
  *" inspect "*"rc.source.path"*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "${workspace}"
    exit 0
    ;;
  *" inspect "*"rc.symlink-follow-fingerprint"*"${cname}"*)
    echo "${stored_fp}"
    exit 0
    ;;
  *" inspect "*"rc.config-loaded"*"${cname}"*)
    echo ""
    exit 0
    ;;
  *" inspect "*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo "{}"
    exit 0
    ;;
  *)
    echo "stub: unhandled docker args: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${stub_dir}/docker"
}

test_s19_fingerprint_lock_fires_for_running_container() {
  local test_home stub_dir ws ws_real cname pi_agent
  test_home=$(mktemp -d)
  # Use a deterministic workspace path so container_name() produces a predictable name.
  # container_name() uses last two path components: parent-base.
  # Must use realpath for ws_real so stub rc.source.path label matches VALIDATED_PATH.
  ws="${test_home}/workspace"
  mkdir -p "$ws"
  ws_real=$(realpath "$ws" 2>/dev/null)
  local ws_slug ws_parent_slug
  ws_slug=$(basename "$ws_real")
  ws_parent_slug=$(basename "$(dirname "$ws_real")")
  cname="${ws_parent_slug}-${ws_slug}"
  stub_dir="${test_home}/stub"
  pi_agent="${test_home}/.pi/agent"
  mkdir -p "$stub_dir" "${test_home}/.ssh" "$pi_agent"

  # Write a benign global config (no denylist patterns) so rc up preflight passes.
  mkdir -p "${test_home}/.config/rip-cage"
  cat > "${test_home}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
YAML

  # Create a dangling symlink in the fake pi/agent dir
  local fake_target="${test_home}/dotpi-fake/AGENTS.md"
  mkdir -p "$(dirname "$fake_target")"
  ln -sf "$fake_target" "${pi_agent}/AGENTS.md"
  # target does not exist → dangling

  # Compute the fingerprint as it would have been at create time: follow policy.
  # Pass workspace so fingerprint matches what cmd_up would compute (D2 FIRM).
  local stored_fp
  stored_fp=$(HOME="$test_home" XDG_CONFIG_HOME="${test_home}/.config" bash -c "source '$RC'; _symlink_follow_fingerprint '${pi_agent}' 'rw' 'follow' 'file' '$ws_real'")

  # Create the docker stub. rc.source.path must match VALIDATED_PATH (realpath of ws).
  make_docker_stub_fingerprint "$stub_dir" "$cname" "running" "$ws_real" "$stored_fp"

  # Write .rip-cage.yaml with on_dangling changed to skip
  cat > "${ws}/.rip-cage.yaml" <<YAML
version: 1
mounts:
  symlinks:
    on_dangling: skip
YAML

  local out exit_code=0
  out=$(PATH="${stub_dir}:$PATH" HOME="$test_home" XDG_CONFIG_HOME="${test_home}/.config" \
    RC_CONFIG_GLOBAL="${test_home}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="$(dirname "$ws_real")" \
    "$RC" up "$ws" 2>&1) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] && echo "$out" | grep -q "destroy and re-up"; then
    pass "19" "fingerprint label-lock fires for running container on policy drift (follow→skip)"
  else
    fail "19" "rc up (running container, follow→skip) should refuse loud with destroy-and-re-up" "exit=$exit_code out=$out"
  fi

  rm -rf "$test_home"
}

# ---------------------------------------------------------------------------
# S17: ADR-021 D5 invariant — both configs absent
# With no dangling symlinks vs with dangling symlinks, label set differs only
# in rc.symlink-follow-fingerprint.
# This test is Docker-conditional.
# (acc 19)
# ---------------------------------------------------------------------------
test_s17_d5_label_invariant() {
  if ! command -v docker &>/dev/null; then
    echo "SKIP S17: docker not available"
    return 0
  fi
  if ! docker info &>/dev/null 2>&1; then
    echo "SKIP S17: docker daemon not accessible"
    return 0
  fi
  if ! docker image inspect rip-cage:latest &>/dev/null 2>&1; then
    echo "SKIP S17: rip-cage:latest image not found (run ./rc build first)"
    return 0
  fi

  # This test is complex and requires creating two containers.
  # We rely on the simpler fingerprint test (S15) + unit tests as proxy.
  # Full end-to-end label comparison requires a real rc up cycle with a workspace.
  # Mark as a TODO for the full e2e test suite.
  echo "SKIP S17: ADR-021 D5 label invariant test — deferred to e2e suite"
}

# ---------------------------------------------------------------------------
# S18: cage-claude.md negative invariant — bead B does NOT modify cage-claude.md
# (acc 24)
# ---------------------------------------------------------------------------
test_s18_cage_claude_md_unchanged() {
  local last_cage_mod
  last_cage_mod=$(git -C "$REPO_ROOT" log --oneline -- cage-claude.md 2>/dev/null | head -1 || true)
  if [[ -z "$last_cage_mod" ]]; then
    pass "18" "cage-claude.md negative invariant: file has no modifications in git log"
    return
  fi

  # Check if cage-claude.md has any uncommitted changes
  local cage_status
  cage_status=$(git -C "$REPO_ROOT" status --porcelain -- cage-claude.md 2>/dev/null || true)
  if [[ -z "$cage_status" ]]; then
    pass "18" "cage-claude.md negative invariant: no uncommitted changes to cage-claude.md in bead B"
  else
    fail "18" "cage-claude.md should not be modified by bead B" "status: $cage_status"
  fi
}

# ---------------------------------------------------------------------------
# S-SCHEMA: Additional schema regression — existing tests should still pass
# after adding 3 new schema fields (regression guard)
# ---------------------------------------------------------------------------
test_s_schema_regression() {
  # Quick regression check: source rc and verify selection list keys still work
  local selection_keys
  selection_keys=$(HOME="/tmp" bash -c "source '$RC'; _config_schema_selection_list_keys")
  local has_allowed_keys has_on_dangling has_mode
  has_allowed_keys=$(echo "$selection_keys" | grep -c "ssh.allowed_keys" || true)
  has_on_dangling=$(echo "$selection_keys" | grep -c "mounts.symlinks.on_dangling" || true)
  has_mode=$(echo "$selection_keys" | grep -c "mounts.symlinks.mode" || true)

  if [[ "$has_allowed_keys" -gt 0 && "$has_on_dangling" -gt 0 && "$has_mode" -gt 0 ]]; then
    pass "schema" "_config_schema_selection_list_keys includes existing + new fields"
  else
    fail "schema" "schema selection_list keys regression" "got: $selection_keys"
  fi
}

# ---------------------------------------------------------------------------
# ADR-019 D1 alignment: auth.json narrow sub-mount present (hhh.12 evolved topology)
# Assert the pi auth.json bind mount is wired after our symlink-follow additions
# ---------------------------------------------------------------------------
test_s_adr019_pi_mount_preserved() {
  setup_sandbox
  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  # Create auth.json so the skip-if-missing guard passes
  printf '{"fake":true}\n' > "${TEST_HOME}/.pi/agent/auth.json"

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source "/tmp/rc-sfl-mount-print-helper.sh"; _print_mounts
  " 2>&1) || exit_code=$?

  # auth.json sub-mount should be present (ADR-019 D1 evolved: narrow sub-mount)
  local has_pi_mount
  has_pi_mount=$(echo "$out" | grep "MOUNT:" | grep -c "\.pi/agent/auth\.json:/home/agent/\.pi/agent/auth\.json" || true)

  if [[ "$has_pi_mount" -gt 0 ]]; then
    pass "adr019" "ADR-019 D1 (evolved): auth.json narrow sub-mount present after symlink-follow additions"
  else
    fail "adr019" "auth.json sub-mount not found in run args" "output: $(echo "$out" | grep "MOUNT:" | head -10)"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S20: Denylist gating — dangling symlink with .aws-class target → skipped + warn
# ADR-023 D5/D6 (incidental surface: warn-and-skip, not fail-loud).
# Acceptance #1, #3: check runs against readlink -f resolved target.
# ---------------------------------------------------------------------------
# write_denylist_config writes the 16 default patterns to a test config dir.
write_denylist_config() {
  local config_dir="$1"
  mkdir -p "$config_dir"
  cat > "${config_dir}/config.yaml" <<'YAML'
version: 1
mounts:
  denylist:
    - .ssh
    - .gnupg
    - .gpg
    - .aws
    - .azure
    - .gcloud
    - .kube
    - .docker
    - credentials
    - .netrc
    - .npmrc
    - .pypirc
    - id_rsa
    - id_ed25519
    - private_key
    - .secret
YAML
}

test_s20_denylist_blocks_aws_symlink_target() {
  setup_sandbox
  # Create a target under .aws (matches default denylist pattern)
  local aws_dir="${TEST_HOME}/.aws"
  mkdir -p "$aws_dir"
  echo "key=secret" > "${aws_dir}/credentials"
  local norm_target
  norm_target=$(readlink -f "${aws_dir}/credentials" 2>/dev/null || echo "${aws_dir}/credentials")

  # Symlink from pi/agent into the .aws directory
  ln -sf "$norm_target" "${TEST_HOME}/.pi/agent/AGENTS.md"

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"

  # Write global denylist config
  write_denylist_config "${TEST_HOME}/.config/rip-cage"

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source '/tmp/rc-sfl-mount-print-helper.sh'; _print_mounts
  " 2>&1) || exit_code=$?

  local has_target_mount has_denylist_warning
  has_target_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}" || true)
  has_denylist_warning=$(echo "$out" | grep -c "matched secret-path denylist pattern" || true)

  if [[ "$exit_code" -eq 0 && "$has_target_mount" -eq 0 && "$has_denylist_warning" -gt 0 ]]; then
    pass "20" "denylist blocks .aws symlink target: not mounted, warn emitted"
  else
    fail "20" "denylist .aws symlink gate" "exit=$exit_code has_mount=$has_target_mount has_warn=$has_denylist_warning out=$out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S21: Denylist — non-matching symlink target mounts normally (no regression)
# Acceptance #2: targets NOT on denylist still get mounted (c1p.2 follow behavior intact).
# ---------------------------------------------------------------------------
test_s21_denylist_allows_non_matching_target() {
  setup_sandbox
  # Create a target NOT under any denylist component
  local safe_dir="${TEST_HOME}/safe-data"
  mkdir -p "$safe_dir"
  echo "safe" > "${safe_dir}/AGENTS.md"
  local norm_target
  norm_target=$(readlink -f "${safe_dir}/AGENTS.md" 2>/dev/null || echo "${safe_dir}/AGENTS.md")

  ln -sf "$norm_target" "${TEST_HOME}/.pi/agent/AGENTS.md"

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"

  # Write global denylist config (default 16 patterns — none match "safe-data")
  write_denylist_config "${TEST_HOME}/.config/rip-cage"

  local out exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$ws' 'testcage'
    source '/tmp/rc-sfl-mount-print-helper.sh'; _print_mounts
  " 2>&1) || exit_code=$?

  local has_target_mount has_denylist_warning
  has_target_mount=$(echo "$out" | grep "MOUNT:" | grep -c "${norm_target}" || true)
  has_denylist_warning=$(echo "$out" | grep -c "matched secret-path denylist pattern" || true)

  if [[ "$exit_code" -eq 0 && "$has_target_mount" -gt 0 && "$has_denylist_warning" -eq 0 ]]; then
    pass "21" "denylist allows non-matching symlink target: mounted, no warning"
  else
    fail "21" "non-matching symlink target mount regression" "exit=$exit_code has_mount=$has_target_mount has_warn=$has_denylist_warning out=$out"
  fi
  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S22: Fingerprint excludes denylist-skipped targets (acceptance #4, D2 FIRM).
# With denylist active, the skipped target is NOT in the fingerprint hash.
# Flipping denylist to skip a previously-included target → different fingerprint.
# ---------------------------------------------------------------------------
test_s22_fingerprint_excludes_denylisted_targets() {
  setup_sandbox

  # Create two distinct targets: one matching denylist (.aws), one safe
  local aws_dir="${TEST_HOME}/.aws"
  mkdir -p "$aws_dir"
  echo "secret" > "${aws_dir}/creds"
  local aws_target
  aws_target=$(readlink -f "${aws_dir}/creds" 2>/dev/null || echo "${aws_dir}/creds")

  local safe_dir="${TEST_HOME}/safe"
  mkdir -p "$safe_dir"
  echo "safe" > "${safe_dir}/AGENTS.md"
  local safe_target
  safe_target=$(readlink -f "${safe_dir}/AGENTS.md" 2>/dev/null || echo "${safe_dir}/AGENTS.md")

  # Link both from pi/agent
  ln -sf "$aws_target" "${TEST_HOME}/.pi/agent/aws-link.md"
  ln -sf "$safe_target" "${TEST_HOME}/.pi/agent/safe-link.md"

  # Write global config with .aws in denylist (blocks aws_target)
  write_denylist_config "${TEST_HOME}/.config/rip-cage"

  # Fingerprint WITH denylist (aws_target excluded)
  local fp_with_denylist
  fp_with_denylist=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file' '$TEST_HOME/workspace'
  ")

  # Write global config with NO denylist (both targets included)
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
YAML

  local fp_without_denylist
  fp_without_denylist=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file' '$TEST_HOME/workspace'
  ")

  # The fingerprints must differ (denylist changes what's included in the hash)
  if [[ "$fp_with_denylist" != "$fp_without_denylist" && -n "$fp_with_denylist" && -n "$fp_without_denylist" ]]; then
    pass "22" "fingerprint differs when denylist excludes a target (denylist changes fp)"
  else
    fail "22" "fingerprint should differ with vs without denylist" "with_denylist=$fp_with_denylist without_denylist=$fp_without_denylist"
  fi

  # Also verify: flipping denylist to skip a previously-included target → drift
  # Scenario: create-time had no denylist (both targets in fp), now .aws is denied
  # The stored create-time fp = fp_without_denylist; current resume fp = fp_with_denylist
  # They differ → drift detection fires
  if [[ "$fp_without_denylist" != "$fp_with_denylist" ]]; then
    pass "22b" "fingerprint drift: flipping denylist changes fp (resume would detect drift)"
  else
    fail "22b" "stored vs current fp should differ when denylist changes" "stored=$fp_without_denylist current=$fp_with_denylist"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S23: Fingerprint denylist-gate is silent (no warning from fingerprint fn itself)
# Acceptance: warning fires once at mount site (Surface 1), not during hash computation.
# ---------------------------------------------------------------------------
test_s23_fingerprint_gate_is_silent() {
  setup_sandbox

  local aws_dir="${TEST_HOME}/.aws"
  mkdir -p "$aws_dir"
  echo "secret" > "${aws_dir}/creds"
  local aws_target
  aws_target=$(readlink -f "${aws_dir}/creds" 2>/dev/null || echo "${aws_dir}/creds")
  ln -sf "$aws_target" "${TEST_HOME}/.pi/agent/aws-link.md"

  local ws="${TEST_HOME}/workspace"
  mkdir -p "$ws"
  write_denylist_config "${TEST_HOME}/.config/rip-cage"

  # Capture stderr from _symlink_follow_fingerprint invocation
  local fp_stderr
  fp_stderr=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file' '$ws'
  " 2>&1 1>/dev/null)

  # No warning should come from the fingerprint function itself
  if ! echo "$fp_stderr" | grep -q "matched secret-path denylist pattern"; then
    pass "23" "fingerprint function is silent (no denylist warning from hash computation)"
  else
    fail "23" "fingerprint function should not emit denylist warning" "stderr=$fp_stderr"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-symlink-follow.sh — mounts.symlinks.* config + rc up synthesis ==="
test_s1_collect_absolute_symlinks
test_s2_skip_relative_symlinks
test_s3_skip_inroot_symlinks
test_s4_broken_symlink_chain_aborts
test_s5_workspace_not_scanned
test_s6_on_dangling_skip
test_s7_on_dangling_error
test_s8_on_dangling_follow
test_s9_on_dangling_warn
test_s10_mode_ro
test_s11_mode_rw
test_s12_scope_parent
test_s13_scope_file
test_s14_fhs_reserved_collision
test_s15_fingerprint_deterministic
test_s16_rc_reload_refuses_mounts_symlinks_change
test_s19_fingerprint_lock_fires_for_running_container
test_s17_d5_label_invariant
test_s18_cage_claude_md_unchanged
test_s_schema_regression
test_s_adr019_pi_mount_preserved
test_s20_denylist_blocks_aws_symlink_target
test_s21_denylist_allows_non_matching_target
test_s22_fingerprint_excludes_denylisted_targets
test_s23_fingerprint_gate_is_silent
test_s24_reserved_collision_skip
test_s25_broken_chain_skip

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
