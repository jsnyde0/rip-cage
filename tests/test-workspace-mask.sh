#!/usr/bin/env bash
# Host-tier tests for ADR-030 mounts.mask (rip-cage-goaz) -- the workspace-mask
# primitive: operator-declared workspace-relative paths get masked in-cage via
# nested single-file :ro overmounts presenting a legible breadcrumb (D6),
# with fail-loud on a missing mask source (D5), union merge + provenance
# (D4, riding ADR-021's config substrate).
#
# Mirrors tests/test-secret-path-denylist.sh's structure (setup_sandbox /
# teardown_sandbox, direct _up_prepare_docker_mounts invocation for the
# mount-building logic that --dry-run never reaches on the new-container
# path -- see the run-args comment at cli/up.sh:2503 for why).
#
# Coverage (host-tier, no live cage):
#   (a) rc config show surfaces mounts.mask union(global,project) header +
#       real per-element global/project provenance tags (not a substring
#       match on the fixture filenames)
#   (b) missing mask source fails loud at rc up (D5), exercised under the
#       SAME set -euo pipefail production runs under -- asserts execution
#       never reaches a post-call sentinel, proving the abort actually
#       propagates (not just that the function returns non-zero)
#   (c) declared existing mask path -> ro overmount added, breadcrumb content
#   (d) layer-merge: global mask + project mask both apply (union, not replace)
#   (g) an absolute mask path is rejected (workspace-relative contract, D4)
#   (h) a mask path with a '..' component is rejected (workspace-relative
#       contract, D4) -- both (g)/(h) fixtures point at real, existing,
#       regular host files so only the dedicated lexical check can catch them
#   (e) shellcheck clean on touched files
#
# In-cage acceptance (shadowed content read from inside a live cage, write
# fails, rest of workspace stays rw both directions) is NEEDS_CONTAINER / e2e
# tier -- see test_f_e2e_incage_mask_behavior below, self-skips unless
# RC_E2E=1 or RUN_E2E=1 (same convention as test-manifest-tool.sh).

set -uo pipefail

# Run-host.sh exports RC_CONFIG_GLOBAL pointing to an empty-denylist fixture
# for the suite. Each test here builds its own sandbox config under
# XDG_CONFIG_HOME; unset the inherited value so it resolves correctly.
unset RC_CONFIG_GLOBAL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TEST_TMPDIR=""

# Crash-safe scratch-cage cleanup (only exercised by test_f, RC_E2E-gated —
# harmless to source unconditionally: scratch_cage_register only arms its
# trap when actually called).
# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# Create a fresh sandbox each test:
#   TEST_TMPDIR  — temporary root
#   TEST_HOME    — fake HOME
#   TEST_WS      — fake workspace directory
setup_sandbox() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-wsm-test-XXXXXX")
  TEST_HOME="${TEST_TMPDIR}/home"
  TEST_WS="${TEST_TMPDIR}/workspace"
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  mkdir -p "$TEST_WS"
}

teardown_sandbox() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
  TEST_HOME=""
  TEST_WS=""
}

write_empty_global_config() {
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: []
YAML
}

# ---------------------------------------------------------------------------
# (a) rc config show surfaces mounts.mask with union(global, project) provenance
#
# Fixture paths are DELIBERATELY named without the substrings "global",
# "project", or "union" (alpha.env / beta.env) -- a prior version of this
# test used global-secret.env / project-secret.env and asserted
# `grep -qE "global|project|union"` against the whole output, which the
# FILENAMES themselves satisfy regardless of whether rc config show emits
# any real provenance annotation (tautological pass). This version asserts
# on the LITERAL provenance markers _config_format_yaml emits: the field-
# level "# union(global, project)" header on the mask: line, and the
# per-element "# global" / "# project" trailing tags -- verified against
# real `rc config show` output (cli/lib/config.sh:_config_format_yaml):
#   mask:                   # union(global, project)
#     - alpha.env                 # global
#     - beta.env                 # project
# ---------------------------------------------------------------------------
test_a_config_show_mask_provenance() {
  setup_sandbox

  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: []
  mask:
    - alpha.env
YAML

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
mounts:
  mask:
    - beta.env
YAML

  local stdout_out
  local exit_code=0
  stdout_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    bash -c "cd '${TEST_WS}' && bash '${RC}' config show" 2>/dev/null
  ) || exit_code=$?

  # Field-level provenance header on the mask: field itself.
  local has_union_header=0
  printf '%s' "$stdout_out" \
    | grep -qE '^[[:space:]]*mask:[[:space:]]*#[[:space:]]*union\(global, project\)[[:space:]]*$' \
    && has_union_header=1

  # Per-element provenance tags -- each path tagged with the layer it
  # actually came from, not a substring match on the path's own name.
  local has_alpha_global_tag=0 has_beta_project_tag=0
  printf '%s' "$stdout_out" \
    | grep -qE '^[[:space:]]*-[[:space:]]*alpha\.env[[:space:]]*#[[:space:]]*global[[:space:]]*$' \
    && has_alpha_global_tag=1
  printf '%s' "$stdout_out" \
    | grep -qE '^[[:space:]]*-[[:space:]]*beta\.env[[:space:]]*#[[:space:]]*project[[:space:]]*$' \
    && has_beta_project_tag=1

  if [[ "$exit_code" -eq 0 \
     && "$has_union_header" -eq 1 \
     && "$has_alpha_global_tag" -eq 1 \
     && "$has_beta_project_tag" -eq 1 ]]; then
    pass "(a) rc config show surfaces mounts.mask union(global,project) header + per-element global/project tags"
  else
    fail "(a) expected mask: # union(global, project) header + alpha.env # global + beta.env # project tags; exit=$exit_code union_header=$has_union_header alpha_tag=$has_alpha_global_tag beta_tag=$has_beta_project_tag out=${stdout_out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (b) missing mask source fails loud at rc up (D5) -- exercised at the
# PRODUCTION propagation level, not just the function's own return code.
#
# Invokes _up_prepare_docker_mounts directly (the mount-building function
# _UP_RUN_ARGS accumulates into) since --dry-run never reaches it on the
# new-container path (cli/up.sh:2503 always returns 'would_create' before the
# _up_prepare_docker_mounts call at cli/up.sh:3056). This is the same pattern
# test-secret-path-denylist.sh's test_bprime uses.
#
# The inner harness runs under `set -euo pipefail` -- the SAME strict mode
# `rc` itself runs under (rc:6) -- and the real call site
# (`_up_prepare_docker_mounts "$path" "$name"`, cli/up.sh) is a bare
# statement, exactly like the sentinel echo below. A prior version of this
# test ran the inner script under `set -uo pipefail` (no -e) and only
# checked the function's own return code via `|| exit_code=$?` -- since the
# function call was the LAST statement in that script, its exit status
# bubbled up regardless of whether -e was even active, so the assertion
# never actually proved "rc up aborts" (production's set -e propagation),
# only "the function returns non-zero" (a weaker claim). This version adds
# an UNREACHABLE sentinel statement AFTER the call and asserts it never
# executes -- the only way that can hold is if `set -e` actually stops
# execution at the failed mask check, the same mechanism the real bare
# call site at cli/up.sh relies on to abort cmd_up.
# ---------------------------------------------------------------------------
test_b_missing_mask_source_fails_loud() {
  setup_sandbox
  write_empty_global_config

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
mounts:
  mask:
    - does-not-exist.env
YAML

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "
      set -euo pipefail
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container'
      echo 'UNREACHABLE_SENTINEL_AFTER_MASK_CALL' >&2
    " 2>&1 >/dev/null
  ) || exit_code=$?

  local sentinel_reached=0
  printf '%s' "$stderr_out" | grep -q "UNREACHABLE_SENTINEL_AFTER_MASK_CALL" && sentinel_reached=1

  if [[ "$exit_code" -ne 0 ]] \
     && printf '%s' "$stderr_out" | grep -q "does-not-exist.env" \
     && printf '%s' "$stderr_out" | grep -q "mounts.mask" \
     && [[ "$sentinel_reached" -eq 0 ]]; then
    pass "(b) missing mounts.mask source aborts under set -e (production propagation) naming the path + mounts.mask, execution never reaches the post-call sentinel (exit=$exit_code)"
  else
    fail "(b) expected non-zero exit + message naming does-not-exist.env + mounts.mask + sentinel NOT reached; got exit=$exit_code sentinel_reached=$sentinel_reached stderr=${stderr_out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (c) declared existing mask path -> ro overmount added over /workspace/<path>
# ---------------------------------------------------------------------------
test_c_existing_mask_path_overmounted_ro() {
  setup_sandbox
  write_empty_global_config

  echo "SUPER_SECRET=abc123" > "${TEST_WS}/secret.env"

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
mounts:
  mask:
    - secret.env
YAML

  local out
  local exit_code=0
  out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "
      set -uo pipefail
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container'
      for _a in \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"; do printf '%s\n' \"\$_a\"; done
    " 2>&1
  ) || exit_code=$?

  local has_mask_mount
  has_mask_mount=$(printf '%s' "$out" | grep -c ":/workspace/secret.env:ro" || true)

  if [[ "$exit_code" -eq 0 && "$has_mask_mount" -gt 0 ]]; then
    pass "(c) existing mask path 'secret.env' produces a :ro overmount over /workspace/secret.env"
  else
    fail "(c) expected a :/workspace/secret.env:ro mount arg; exit=$exit_code has_mount=$has_mask_mount out=${out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (d) layer-merge: global mask + project mask both apply (union, not replace)
# ---------------------------------------------------------------------------
test_d_layer_merge_union_both_apply() {
  setup_sandbox

  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: []
  mask:
    - global-secret.env
YAML

  echo "GLOBAL=1" > "${TEST_WS}/global-secret.env"
  echo "PROJECT=1" > "${TEST_WS}/project-secret.env"

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
mounts:
  mask:
    - project-secret.env
YAML

  local out
  local exit_code=0
  out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "
      set -uo pipefail
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container'
      for _a in \"\${_UP_RUN_ARGS[@]+\${_UP_RUN_ARGS[@]}}\"; do printf '%s\n' \"\$_a\"; done
    " 2>&1
  ) || exit_code=$?

  local has_global has_project
  has_global=$(printf '%s' "$out" | grep -c ":/workspace/global-secret.env:ro" || true)
  has_project=$(printf '%s' "$out" | grep -c ":/workspace/project-secret.env:ro" || true)

  if [[ "$exit_code" -eq 0 && "$has_global" -gt 0 && "$has_project" -gt 0 ]]; then
    pass "(d) global mask + project mask both applied (union, not project-replace-global)"
  else
    fail "(d) expected BOTH global-secret.env and project-secret.env overmounted; exit=$exit_code has_global=$has_global has_project=$has_project out=${out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (g) an absolute mask path is rejected -- fails loud, does not silently
# escape /workspace.
#
# ADR-030 D4 / config.md state mounts.mask entries are workspace-relative.
# The declared entry is /etc/hosts, which DOES exist on the host (and is a
# regular file) -- if only the D5 existence/regular-file checks ran, this
# entry would sail through and produce a dest
# /workspace//etc/hosts -> normalizes to a path escaping the workspace root.
# Only a dedicated lexical contract check catches this; the fixture is
# chosen specifically so existence/regular-file checks alone cannot.
# ---------------------------------------------------------------------------
test_g_absolute_mask_path_rejected() {
  setup_sandbox
  write_empty_global_config

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
mounts:
  mask:
    - /etc/hosts
YAML

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "
      set -uo pipefail
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container'
    " 2>&1 >/dev/null
  ) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] \
     && printf '%s' "$stderr_out" | grep -q "/etc/hosts" \
     && printf '%s' "$stderr_out" | grep -qi "workspace-relative"; then
    pass "(g) absolute mounts.mask entry '/etc/hosts' rejected as not workspace-relative (exit=$exit_code)"
  else
    fail "(g) expected non-zero exit + message naming /etc/hosts + workspace-relative; got exit=$exit_code stderr=${stderr_out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (h) a mask path with a '..' component escaping the workspace root is
# rejected -- fails loud, does not silently escape /workspace.
#
# The declared entry ../outside.env resolves (lexically) to a real file
# that DOES exist one level above the workspace -- same rationale as (g):
# a fixture that would pass a bare existence/regular-file check, so only
# the dedicated lexical contract check can catch it.
# ---------------------------------------------------------------------------
test_h_dotdot_escape_mask_path_rejected() {
  setup_sandbox
  write_empty_global_config

  echo "OUTSIDE=1" > "${TEST_TMPDIR}/outside.env"

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
mounts:
  mask:
    - ../outside.env
YAML

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "
      set -uo pipefail
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container'
    " 2>&1 >/dev/null
  ) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] \
     && printf '%s' "$stderr_out" | grep -q "\.\./outside\.env" \
     && printf '%s' "$stderr_out" | grep -qi "workspace-relative"; then
    pass "(h) '..'-escaping mounts.mask entry '../outside.env' rejected as not workspace-relative (exit=$exit_code)"
  else
    fail "(h) expected non-zero exit + message naming ../outside.env + workspace-relative; got exit=$exit_code stderr=${stderr_out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (e) shellcheck rc + cli/up.sh + cli/lib/config.sh exit clean
# ---------------------------------------------------------------------------
test_e_shellcheck_clean() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    pass "(e) shellcheck not installed — skip (not required in this env)"
    return
  fi

  local exit_code=0
  shellcheck "$RC" "${SCRIPT_DIR}/../cli/up.sh" "${SCRIPT_DIR}/../cli/lib/config.sh" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "(e) shellcheck rc + cli/up.sh + cli/lib/config.sh exits 0"
  else
    fail "(e) shellcheck exited $exit_code — new warnings from the mounts.mask change?"
  fi
}

# ---------------------------------------------------------------------------
# (f) NEEDS_CONTAINER / e2e — real in-cage mask behavior:
#       - the masked path reads as the breadcrumb content in-cage
#       - writing to the masked path fails (ro)
#       - a sibling non-masked workspace file stays rw in BOTH directions
#         (host edit visible in-cage; in-cage edit visible on host)
#
# Self-skips unless RC_E2E=1 or RUN_E2E=1 (same convention as
# test-manifest-tool.sh's T2/T3/T4). Requires a built rip-cage image and a
# reachable msb runtime — not run by the default host-only suite.
# ---------------------------------------------------------------------------
test_f_e2e_incage_mask_behavior() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / RC_E2E): (f) real in-cage mask behavior — set RC_E2E=1 or RUN_E2E=1 to run"
    return
  fi

  setup_sandbox
  write_empty_global_config

  echo "SUPER_SECRET=abc123" > "${TEST_WS}/secret.env"
  echo "not-secret" > "${TEST_WS}/plain.txt"

  cat > "${TEST_WS}/.rip-cage.yaml" <<'YAML'
version: 2
mounts:
  mask:
    - secret.env
YAML

  # rc derives the container name from the last two path components
  # (cli/lib/container.sh:container_name) — compute the same way rather
  # than hardcoding a name rc would never actually assign.
  local cage_name
  cage_name=$(
    HOME="$TEST_HOME" bash -c "source '$RC' 2>/dev/null; container_name '$TEST_WS'"
  )
  scratch_cage_register "$cage_name"

  local exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up "$TEST_WS" >/dev/null 2>&1 || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "(f) rc up failed to bring up e2e mask-test cage; exit=$exit_code"
    teardown_sandbox
    return
  fi

  # (f1) masked path reads as the breadcrumb, not the real secret content
  local masked_content
  masked_content=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash "$RC" exec "$cage_name" -- cat /workspace/secret.env 2>/dev/null)
  if printf '%s' "$masked_content" | grep -qi "masked by rip-cage" \
     && ! printf '%s' "$masked_content" | grep -q "SUPER_SECRET"; then
    pass "(f1) masked path reads as breadcrumb in-cage, real content not visible"
  else
    fail "(f1) expected breadcrumb content, no secret; got: ${masked_content:-(empty)}"
  fi

  # (f2) write to masked path fails (ro)
  local write_exit=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash "$RC" exec "$cage_name" -- sh -c 'echo x >> /workspace/secret.env' >/dev/null 2>&1 || write_exit=$?
  if [[ "$write_exit" -ne 0 ]]; then
    pass "(f2) write to masked path fails (ro overmount)"
  else
    fail "(f2) expected write to masked path to fail; it succeeded"
  fi

  # (f3) sibling non-masked file stays rw both directions
  local plain_incage
  plain_incage=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash "$RC" exec "$cage_name" -- cat /workspace/plain.txt 2>/dev/null)
  if [[ "$plain_incage" == "not-secret" ]]; then
    pass "(f3a) non-masked sibling file reads correctly in-cage (rw mount intact)"
  else
    fail "(f3a) expected 'not-secret'; got: ${plain_incage:-(empty)}"
  fi

  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash "$RC" exec "$cage_name" -- sh -c 'echo edited-in-cage > /workspace/plain.txt' >/dev/null 2>&1
  if [[ "$(cat "${TEST_WS}/plain.txt" 2>/dev/null)" == "edited-in-cage" ]]; then
    pass "(f3b) in-cage write to non-masked file visible on host (rw both directions)"
  else
    fail "(f3b) expected host file to show in-cage edit"
  fi

  # Cleanup: scratch_cage_register's EXIT/INT/TERM trap destroys $cage_name.

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== test-workspace-mask.sh — ADR-030 mounts.mask (rip-cage-goaz) ==="
test_a_config_show_mask_provenance
test_b_missing_mask_source_fails_loud
test_c_existing_mask_path_overmounted_ro
test_d_layer_merge_union_both_apply
test_g_absolute_mask_path_rejected
test_h_dotdot_escape_mask_path_rejected
test_e_shellcheck_clean
test_f_e2e_incage_mask_behavior

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
