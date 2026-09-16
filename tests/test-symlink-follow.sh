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
# Tests S16/S19 use a fake-msb PATH-shim stub (rip-cage-qzsx, S8 of the msb
# migration epic rip-cage-tsf2 — cli/reload.sh + cli/up.sh's resume path were
# rewired onto msb by rip-cage-rj68, S6; the stub pattern is the msb-native
# translation of the original docker-inspect-stub idiom from
# test-rc-reload.sh).
# Tests S17 requires Docker (conditional).
# S18 is a static git-diff check.
#
# ADRs: ADR-001 D1 (fail-loud), ADR-019 D1 (auth.json sub-mount preserved, hhh.12),
#       ADR-021 D2/D3/D5 (schema/merge/versioning), ADR-022 D6 (rc reload)

set -uo pipefail

# tests/run-host.sh exports RC_CONFIG_GLOBAL pointing to an empty-denylist fixture
# for the whole suite. RC_CONFIG_GLOBAL takes precedence over XDG_CONFIG_HOME in
# _config_global_path (cli/lib/config.sh:_config_global_path), so per-call XDG sandboxes get silently
# shadowed — S20/S22/S22b see an empty denylist and fail. Unset here so per-call
# XDG sandboxes resolve correctly.
# Mirror of the fix in tests/test-secret-path-denylist.sh (see run-host.sh:102-109).
unset RC_CONFIG_GLOBAL

# ===========================================================================
# RESCOPED BY rip-cage-ely4.9 (ADR-031 D2). Read this before adding a case.
#
# mounts.symlinks.{on_dangling,scope,mode} and mounts.denylist retired with the
# rip-cage config schema. Each became the retired schema's OWN DEFAULT --
# follow / file / rw -- and the denylist became the SHIPPED, host-global
# protected-paths list. So symlink-follow behaviour still exists; what no
# longer exists is the ability to VARY it per project.
#
# That split is the whole rule for this file:
#   KEPT (14)      the observable survives with the retired default, and the
#                  case never needed the knob: S1-S5 (collector units),
#                  S8/S11/S13 (the three surviving defaults), S14, S15*, S18,
#                  S21, S23, S25, Sadr019.
#   RESCOPED (3)   the observable survives but the fixture drove it through a
#                  deleted surface: S20/S22/S22b now rely on the shipped list
#                  (.aws is on it) and, for S22b, on RC_PROTECTED_PATHS
#                  pointing at a list that omits it.
#   RETIRED (8)    the case only varied a deleted knob: S6, S7, S10, S12, S16,
#                  S24, S-SCHEMA, and S19 -- each says so at its own banner,
#                  with what replaced it or what coverage was lost.
#   SKIPPED (1)    S17, on its own pre-existing precondition.
#
# Two fixtures were re-homed ABOVE the cases while doing this: _print_mounts'
# writer and make_msb_stub_symlink both sat under a retired case's banner, so
# deleting that case took them with it and every surviving case that used them
# died with exit 127. A shared fixture under a case banner is a trap for the
# next retirement -- keep them up here.
# ===========================================================================


# Captured before any case sandboxes HOME (see S19).
REAL_DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

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
  # check deliberately does NOT canonicalize (cli/up.sh:'not /var or /tmp'), so the targets are
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
# SHARED HELPERS — restored by rip-cage-ely4.9.
#
# These two lived physically between two case banners that this bead retired,
# so a banner-to-banner deletion took them with it and every surviving case
# that called them died with exit 127. They are helpers, not cases: re-homed
# here, above the cases, so the next retirement cannot repeat the mistake.
# ---------------------------------------------------------------------------

# Helper script for printing -v mount args inside bash -c invocations.
# Written as a separate file so it can be sourced without shell expansion
# issues. Re-homed above the cases by rip-cage-ely4.9: it used to sit under the
# S6 banner, so retiring S6 deleted the writer and every surviving case that
# sourced it died with exit 127. A shared fixture under a case banner is a trap
# for the next retirement.
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
make_msb_stub_symlink() {
  local stub_dir="$1" cname="$2" state="$3" workspace="$4"
  cat > "${stub_dir}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  inspect)
    if [[ "\${2:-}" != "${cname}" || "${state}" == "missing" ]]; then
      echo "Error: no such sandbox: \${2:-}" >&2
      exit 1
    fi
    _status="Stopped"
    [[ "${state}" == "running" ]] && _status="Running"
    echo "{\"status\":\"\${_status}\",\"config\":{\"manifest_digest\":\"\",\"labels\":{\"rc.source.path\":\"${workspace}\"}}}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "${stub_dir}/msb"
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
# S6: RETIRED by rip-cage-ely4.9 — on_dangling=skip.
#
# ADR-031 D2 retires the rip-cage config schema, and mounts.symlinks.{on_dangling,
# scope,mode} went with it: each became the retired schema's OWN DEFAULT
# (follow / file / rw), so an unconfigured cage behaves exactly as before. This
# case is retired because `skip` was one of four values of a knob that no longer exists — the observable it asserted can no longer be
# produced, so there is no narrower true version to keep.
#
# Everything that survives the retirement is still covered: S1-S5 (the
# collector, never config-driven), S8/S11/S13 (the three surviving defaults),
# S14 (reserved-path collision), S15* (fingerprint determinism), and the
# rescoped S19/S20/S22/S22b below.

# S7: RETIRED by rip-cage-ely4.9 — on_dangling=error.
#
# ADR-031 D2 retires the rip-cage config schema, and mounts.symlinks.{on_dangling,
# scope,mode} went with it: each became the retired schema's OWN DEFAULT
# (follow / file / rw), so an unconfigured cage behaves exactly as before. This
# case is retired because `error` was one of four values of a knob that no longer exists — the observable it asserted can no longer be
# produced, so there is no narrower true version to keep.
#
# Everything that survives the retirement is still covered: S1-S5 (the
# collector, never config-driven), S8/S11/S13 (the three surviving defaults),
# S14 (reserved-path collision), S15* (fingerprint determinism), and the
# rescoped S19/S20/S22/S22b below.

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
version: 2
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
# S10: RETIRED by rip-cage-ely4.9 — mode=ro.
#
# ADR-031 D2 retires the rip-cage config schema, and mounts.symlinks.{on_dangling,
# scope,mode} went with it: each became the retired schema's OWN DEFAULT
# (follow / file / rw), so an unconfigured cage behaves exactly as before. This
# case is retired because `ro` was the non-default half of a knob that no longer exists; S11 covers the surviving `rw` behaviour — the observable it asserted can no longer be
# produced, so there is no narrower true version to keep.
#
# Everything that survives the retirement is still covered: S1-S5 (the
# collector, never config-driven), S8/S11/S13 (the three surviving defaults),
# S14 (reserved-path collision), S15* (fingerprint determinism), and the
# rescoped S19/S20/S22/S22b below.

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
# S12: RETIRED by rip-cage-ely4.9 — scope=parent.
#
# ADR-031 D2 retires the rip-cage config schema, and mounts.symlinks.{on_dangling,
# scope,mode} went with it: each became the retired schema's OWN DEFAULT
# (follow / file / rw), so an unconfigured cage behaves exactly as before. This
# case is retired because `parent` was the non-default half of a knob that no longer exists; S13 covers the surviving `file` behaviour — the observable it asserted can no longer be
# produced, so there is no narrower true version to keep.
#
# Everything that survives the retirement is still covered: S1-S5 (the
# collector, never config-driven), S8/S11/S13 (the three surviving defaults),
# S14 (reserved-path collision), S15* (fingerprint determinism), and the
# rescoped S19/S20/S22/S22b below.

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
# S24: RETIRED by rip-cage-ely4.9 — reserved-path collision under on_dangling=skip.
#
# ADR-031 D2 retires the rip-cage config schema, and mounts.symlinks.{on_dangling,
# scope,mode} went with it: each became the retired schema's OWN DEFAULT
# (follow / file / rw), so an unconfigured cage behaves exactly as before. This
# case is retired because the collision abort itself survives and is covered by S14; only the `skip` variant's knob is gone — the observable it asserted can no longer be
# produced, so there is no narrower true version to keep.
#
# Everything that survives the retirement is still covered: S1-S5 (the
# collector, never config-driven), S8/S11/S13 (the three surviving defaults),
# S14 (reserved-path collision), S15* (fingerprint determinism), and the
# rescoped S19/S20/S22/S22b below.

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
# S16: RETIRED by rip-cage-ely4.9 — rc reload refuses on mounts.symlinks.* change.
#
# ADR-031 D2 retires the rip-cage config schema, and mounts.symlinks.{on_dangling,
# scope,mode} went with it: each became the retired schema's OWN DEFAULT
# (follow / file / rw), so an unconfigured cage behaves exactly as before. This
# case is retired because both halves are gone — the config key AND reload's refuse-loud, which belonged to the retired diff engine — the observable it asserted can no longer be
# produced, so there is no narrower true version to keep.
#
# Everything that survives the retirement is still covered: S1-S5 (the
# collector, never config-driven), S8/S11/S13 (the three surviving defaults),
# S14 (reserved-path collision), S15* (fingerprint determinism), and the
# rescoped S19/S20/S22/S22b below.

# ---------------------------------------------------------------------------
# S19: RETIRED by rip-cage-ely4.9 — running-container fingerprint label-lock.
#
# It drove drift by flipping mounts.symlinks.on_dangling from follow to skip.
# That knob retired with the schema (ADR-031 D2) and is now the constant
# `follow`, so the original trigger cannot be produced.
#
# I TRIED TO RESCOPE IT and could not do so honestly, which is why this is a
# retirement WITH A NOTE rather than a quietly-deleted case. The intended
# replacement trigger was real host-side drift -- add a dangling symlink after
# the fingerprint is stored -- because the mount set is computed from the live
# filesystem at every launch. Measured directly (rip-cage-ely4.9):
#
#   fp(one dangling symlink) == fp(two dangling symlinks)
#
# Adding a symlink did not move the fingerprint with this fixture's shape, so a
# rescoped S19 would assert a refusal that never fires. A test that passes for
# a reason I cannot explain is worse than no test.
#
# WHAT THIS COSTS, plainly: the running-branch label-lock
# (_up_resolve_resume_symlink_fingerprint against a RUNNING cage) has no live
# coverage now. The guard itself is untouched code. S15/S15b/S15c/S15d still
# cover fingerprint determinism and the stopped-branch resolvers are exercised
# by tests/test-image-drift-resume.sh. The gap AND the fingerprint-
# insensitivity observation above are handed up rather than absorbed.

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
  last_cage_mod=$(git -C "$REPO_ROOT" log --oneline -- cage/agent/cage-claude.md 2>/dev/null | head -1 || true)
  if [[ -z "$last_cage_mod" ]]; then
    pass "18" "cage-claude.md negative invariant: file has no modifications in git log"
    return
  fi

  # Check if cage-claude.md has any uncommitted changes
  local cage_status
  cage_status=$(git -C "$REPO_ROOT" status --porcelain -- cage/agent/cage-claude.md 2>/dev/null || true)
  if [[ -z "$cage_status" ]]; then
    pass "18" "cage-claude.md negative invariant: no uncommitted changes to cage-claude.md in bead B"
  else
    fail "18" "cage-claude.md should not be modified by bead B" "status: $cage_status"
  fi
}

# ---------------------------------------------------------------------------
# S-SCHEMA: RETIRED by rip-cage-ely4.9.
#
# It resolved per-field TYPES out of the rip-cage config schema
# (_config_schema_field_type on mounts.allow_risky and two mounts.symlinks
# enums) as a regression guard on the v2 type model. ADR-031 D2 retires the
# schema, the loader and that helper together, so there are no field types left
# to resolve. A guard over a type system that no longer exists cannot fail, and
# a check that cannot fail is worse than no check.

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
# RESCOPED by rip-cage-ely4.9. These cases used to write a 16-pattern
# mounts.denylist into a per-test config; ADR-031 D2 replaces that with the
# SHIPPED protected-paths list, which is host-global and already contains
# .aws. So the fixture writes nothing and the behaviour holds by default --
# which is a stronger setup, because the cases now exercise the list an
# operator actually gets rather than one the test invented.
#
# write_denylist_config is kept as a NO-OP shim so the four call sites stay
# legible as "this case depends on .aws being protected" rather than silently
# depending on a default.
write_denylist_config() {
  : "${1:?}"  # the protected-paths list is shipped; nothing to write
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
  # Wording moved with the rule (rip-cage-ely4.9): the denylist became the
  # protected-paths list, so the skip warning says "is a protected path". Both
  # spellings match so this tracks the property, not one release's phrasing.
  has_denylist_warning=$(echo "$out" | grep -cE "is a protected path|matched secret-path denylist pattern" || true)

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
    _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file'
  ")

  # RESCOPED by rip-cage-ely4.9: the comparison list is no longer a per-project
  # config key but an operator-editable FILE (ADR-031 D2). Point
  # RC_PROTECTED_PATHS at a list that omits .aws — the same "what if this target
  # were not protected?" question, asked of the surface that now answers it.
  local nolist="${TEST_HOME}/protected-paths-without-aws"
  printf '.ssh\n.gnupg\ncredentials\n' > "$nolist"

  local fp_without_denylist
  fp_without_denylist=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_PROTECTED_PATHS="$nolist" bash -c "
    source '$RC'
    _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file'
  ")

  # The fingerprints must differ: a protected target is excluded from the hash.
  if [[ "$fp_with_denylist" != "$fp_without_denylist" && -n "$fp_with_denylist" && -n "$fp_without_denylist" ]]; then
    pass "22" "fingerprint differs when a target is protected vs not (protection changes fp)"
  else
    fail "22" "fingerprint should differ with vs without protection" "protected=$fp_with_denylist unprotected=$fp_without_denylist"
  fi

  # 22b: the same difference read as DRIFT. A cage created while .aws was not
  # protected stores fp_without; after the operator adds .aws to the list, the
  # resume-side recompute yields fp_with — so the label-lock fires rather than
  # silently resuming a cage whose mount set has quietly changed.
  if [[ "$fp_without_denylist" != "$fp_with_denylist" ]]; then
    pass "22b" "fingerprint drift: editing the protected-paths list changes fp (resume detects it)"
  else
    fail "22b" "stored vs current fp should differ when the protected-paths list changes" "stored=$fp_without_denylist current=$fp_with_denylist"
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
    _symlink_follow_fingerprint '${TEST_HOME}/.pi/agent' 'rw' 'follow' 'file'
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
test_s8_on_dangling_follow
test_s9_on_dangling_warn
test_s11_mode_rw
test_s13_scope_file
test_s14_fhs_reserved_collision
test_s15_fingerprint_deterministic
test_s17_d5_label_invariant
test_s18_cage_claude_md_unchanged
test_s_adr019_pi_mount_preserved
test_s20_denylist_blocks_aws_symlink_target
test_s21_denylist_allows_non_matching_target
test_s22_fingerprint_excludes_denylisted_targets
test_s23_fingerprint_gate_is_silent
test_s25_broken_chain_skip

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi

