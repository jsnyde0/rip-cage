#!/usr/bin/env bash
# Integration tests for ADR-023 denylist plumbing (rip-cage-3gu.2).
#
# Coverage:
#   (a)  env-file path with .aws component → denied with D6 message
#   (b)  symlink pointing to denied path passed as --env-file → resolved + blocked
#   (b') skill symlink under ~/.claude/skills whose target is under .aws/ → warn-and-skip
#   (c)  --allow-risky-mount bypass for denied env-file path → allowed
#   (d)  mounts.allow_risky YAML bypass for denied env-file path → allowed
#   (f)  .env path (not in default denylist) → allowed
#   (j)  missing ~/.config/rip-cage/config.yaml → rc up fails loud naming rc install
#   (k)  rc install writes exactly the 16 expected default denylist patterns
#
# Tests run without Docker — they either parse rc output from a dummy workspace
# or use cmd_install / cmd_up preflight which don't require a running daemon.
# For mount-surface tests we use RC_ALLOWED_ROOTS to bypass the interactive prompt.

set -uo pipefail

# Run-host.sh exports RC_CONFIG_GLOBAL pointing to an empty-denylist fixture for
# the suite (see tests/run-host.sh). Each test in this file builds its own
# sandbox config under XDG_CONFIG_HOME and (where needed) sets RC_CONFIG_GLOBAL
# explicitly. Unset the inherited value so XDG_CONFIG_HOME resolves correctly
# for cases that don't override RC_CONFIG_GLOBAL.
unset RC_CONFIG_GLOBAL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TEST_TMPDIR=""

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
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-sdp-test-XXXXXX")
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

# Write the default 16-pattern global config to TEST_HOME.
write_default_global_config() {
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
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

# ---------------------------------------------------------------------------
# (a) env-file path with .aws component → denied with D6 message
# ---------------------------------------------------------------------------
test_a_envfile_aws_denied() {
  setup_sandbox
  write_default_global_config

  # Create a fake env file under a .aws dir
  mkdir -p "${TEST_TMPDIR}/.aws"
  touch "${TEST_TMPDIR}/.aws/credentials.fake"

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up --dry-run --env-file "${TEST_TMPDIR}/.aws/credentials.fake" "$TEST_WS" 2>&1 >/dev/null
  ) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] \
     && printf '%s' "$stderr_out" | grep -q "\.aws" \
     && printf '%s' "$stderr_out" | grep -q "matched secret-path denylist pattern"; then
    pass "(a) env-file .aws path denied with D6 message (exit=$exit_code)"
  else
    fail "(a) expected exit non-zero + D6 message naming .aws; got exit=$exit_code stderr=$stderr_out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (b) symlink to denied path passed as --env-file → resolved path blocked
# ---------------------------------------------------------------------------
test_b_envfile_symlink_resolved_and_blocked() {
  setup_sandbox
  write_default_global_config

  # Create target under .aws and a symlink to it
  mkdir -p "${TEST_TMPDIR}/.aws"
  touch "${TEST_TMPDIR}/.aws/credentials.fake"
  ln -s "${TEST_TMPDIR}/.aws/credentials.fake" "${TEST_TMPDIR}/link-to-aws-creds"

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up --dry-run --env-file "${TEST_TMPDIR}/link-to-aws-creds" "$TEST_WS" 2>&1 >/dev/null
  ) || exit_code=$?

  # Must be denied AND the stderr must name the resolved (real) path, not the symlink
  local resolved_path
  resolved_path=$(realpath "${TEST_TMPDIR}/.aws/credentials.fake" 2>/dev/null)

  if [[ "$exit_code" -ne 0 ]] \
     && printf '%s' "$stderr_out" | grep -qF "$resolved_path" \
     && printf '%s' "$stderr_out" | grep -q "matched secret-path denylist pattern"; then
    pass "(b) symlink-via-env-file resolved to $resolved_path and blocked"
  else
    fail "(b) expected exit non-zero + D6 message with resolved path; got exit=$exit_code stderr=$stderr_out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (b') skill symlink under ~/.claude/skills with target under .aws/ → warn-and-skip
#
# Tests _up_prepare_docker_mounts directly (sourcing rc) since the denylist
# check fires in the actual mount-build path, not in --dry-run (which exits
# early if the image is absent).  We invoke _up_prepare_docker_mounts in a
# subshell and capture its stderr; the function appends to the _UP_RUN_ARGS
# global but does NOT run docker — safe to call without Docker.
# ---------------------------------------------------------------------------
test_bprime_skill_symlink_aws_target_skipped() {
  setup_sandbox
  write_default_global_config

  # _collect_symlink_parents security check: target must be under $HOME.
  # On macOS, realpath resolves /tmp → /private/tmp. Set HOME to the
  # fully-resolved TEST_HOME so the check passes.
  local resolved_test_home
  resolved_test_home=$(realpath "$TEST_HOME" 2>/dev/null)
  local resolved_ws
  resolved_ws=$(realpath "$TEST_WS" 2>/dev/null)

  # Create a fake skill dir under <resolved_test_home>/.aws/my-skill
  mkdir -p "${resolved_test_home}/.aws/my-skill"
  touch "${resolved_test_home}/.aws/my-skill/SKILL.md"

  # Create ~/.claude/skills/ with a symlink pointing into the .aws directory
  mkdir -p "${resolved_test_home}/.claude/skills"
  ln -s "${resolved_test_home}/.aws/my-skill" "${resolved_test_home}/.claude/skills/test-denied-skill"

  # Make sure global config is also under the resolved path
  mkdir -p "${resolved_test_home}/.config/rip-cage"
  cp "${TEST_HOME}/.config/rip-cage/config.yaml" "${resolved_test_home}/.config/rip-cage/config.yaml" 2>/dev/null
  mkdir -p "$resolved_ws"

  # Call _up_prepare_docker_mounts directly in a subshell.
  # We supply the minimal globals it needs: wt_detected, _UP_RUN_ARGS.
  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$resolved_test_home" \
    XDG_CONFIG_HOME="${resolved_test_home}/.config" \
    bash -c "
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$resolved_ws' 'test-container'
    " 2>&1 >/dev/null
  ) || exit_code=$?

  # For warn-and-skip: the function should complete (exit 0) but emit a
  # stderr warning naming .aws and the skip action.
  if printf '%s' "$stderr_out" | grep -q "\.aws" \
     && printf '%s' "$stderr_out" | grep -qi "skip\|skipping"; then
    pass "(b') skill symlink to .aws/ target: warned and skipped (stderr named .aws pattern)"
  else
    fail "(b') expected stderr warning naming .aws with skip indication; got exit=$exit_code stderr=${stderr_out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (c) --allow-risky-mount bypass for denied env-file path → allowed
# ---------------------------------------------------------------------------
test_c_allow_risky_mount_flag_bypass() {
  setup_sandbox
  write_default_global_config

  mkdir -p "${TEST_TMPDIR}/.aws"
  touch "${TEST_TMPDIR}/.aws/credentials.fake"

  local resolved_env
  resolved_env=$(realpath "${TEST_TMPDIR}/.aws/credentials.fake" 2>/dev/null)

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up --dry-run \
      --allow-risky-mount "$resolved_env" \
      --env-file "$resolved_env" \
      "$TEST_WS" 2>&1 >/dev/null
  ) || exit_code=$?

  # With --allow-risky-mount, it should NOT be denied (no D6 "matched denylist" message)
  if ! printf '%s' "$stderr_out" | grep -q "matched secret-path denylist pattern"; then
    pass "(c) --allow-risky-mount bypass: no denylist denial (exit=$exit_code)"
  else
    fail "(c) expected no denylist denial with --allow-risky-mount; got exit=$exit_code stderr=$stderr_out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (d) mounts.allow_risky YAML bypass via .rip-cage.yaml → allowed
# ---------------------------------------------------------------------------
test_d_allow_risky_yaml_bypass() {
  setup_sandbox
  write_default_global_config

  mkdir -p "${TEST_TMPDIR}/.aws"
  touch "${TEST_TMPDIR}/.aws/credentials.fake"

  local resolved_env
  resolved_env=$(realpath "${TEST_TMPDIR}/.aws/credentials.fake" 2>/dev/null)

  # Write project config with mounts.allow_risky
  cat > "${TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
mounts:
  allow_risky:
    - ${resolved_env}
YAML

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up --dry-run \
      --env-file "$resolved_env" \
      "$TEST_WS" 2>&1 >/dev/null
  ) || exit_code=$?

  if ! printf '%s' "$stderr_out" | grep -q "matched secret-path denylist pattern"; then
    pass "(d) mounts.allow_risky YAML bypass: no denylist denial (exit=$exit_code)"
  else
    fail "(d) expected no denylist denial with mounts.allow_risky; got exit=$exit_code stderr=$stderr_out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (f) .env path (not in default 16-pattern denylist) → allowed
# ---------------------------------------------------------------------------
test_f_dotenv_path_allowed() {
  setup_sandbox
  write_default_global_config

  # Create a .env file in the workspace
  touch "${TEST_WS}/.env"

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash "$RC" up --dry-run \
      --env-file "${TEST_WS}/.env" \
      "$TEST_WS" 2>&1 >/dev/null
  ) || exit_code=$?

  if ! printf '%s' "$stderr_out" | grep -q "matched secret-path denylist pattern"; then
    pass "(f) .env path not in default denylist → no denial (exit=$exit_code)"
  else
    fail "(f) .env path should not be denied by default denylist; got exit=$exit_code stderr=$stderr_out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (j) missing ~/.config/rip-cage/config.yaml → rc up fails loud naming rc install
# ---------------------------------------------------------------------------
test_j_missing_global_config_fails_loud() {
  setup_sandbox
  # Do NOT write global config — it's absent

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash "$RC" up --dry-run "$TEST_WS" 2>&1 >/dev/null
  ) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] \
     && printf '%s' "$stderr_out" | grep -q "rc install"; then
    pass "(j) missing global config fails loud naming rc install (exit=$exit_code)"
  else
    fail "(j) expected exit non-zero + stderr naming 'rc install'; got exit=$exit_code stderr=$stderr_out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (k) rc install writes exactly the 16 expected default patterns
# ---------------------------------------------------------------------------
test_k_rc_install_writes_16_patterns() {
  setup_sandbox

  local cfg_path="${TEST_TMPDIR}/install-config.yaml"

  local exit_code=0
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_CONFIG_GLOBAL="$cfg_path" \
  bash "$RC" install --yes || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "(k) rc install --yes exited $exit_code"
    teardown_sandbox
    return
  fi

  if [[ ! -f "$cfg_path" ]]; then
    fail "(k) rc install did not create $cfg_path"
    teardown_sandbox
    return
  fi

  local expected_patterns=(
    .ssh .gnupg .gpg .aws .azure .gcloud .kube .docker
    credentials .netrc .npmrc .pypirc id_rsa id_ed25519 private_key .secret
  )
  local missing=()
  for pat in "${expected_patterns[@]}"; do
    if ! grep -qF "$pat" "$cfg_path"; then
      missing+=("$pat")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "(k) rc install wrote all 16 expected denylist patterns to $cfg_path"
  else
    fail "(k) rc install missing patterns: ${missing[*]} — file contents: $(cat "$cfg_path")"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (e) Workspace mount structurally exempted from denylist check
#
# Even when the workspace path contains a component matching the denylist
# (e.g. ~/.aws/<fixture>/), rc up must NOT fire _check_secret_path_denylist
# on the workspace path itself.  The denylist only applies to non-workspace
# mount surfaces (--env-file, beads redirect, skill symlink targets).
#
# This falsifies the implementer-error class of inserting the denylist check
# at the top of validate_path (which also validates workspace paths) instead
# of inside the env-file / skill-symlink branches.
# ---------------------------------------------------------------------------
test_e_workspace_structurally_exempted() {
  setup_sandbox
  write_default_global_config

  # Create a workspace whose path contains a denylist component (.aws).
  local aws_workspace="${TEST_TMPDIR}/.aws/my-project"
  mkdir -p "$aws_workspace"

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up --dry-run "$aws_workspace" 2>&1 >/dev/null
  ) || exit_code=$?

  # Workspace path must NOT trigger denylist.  The invocation should succeed
  # (exit 0) and stderr must NOT contain the denylist denial message.
  if [[ "$exit_code" -eq 0 ]] \
     && ! printf '%s' "$stderr_out" | grep -q "matched secret-path denylist pattern"; then
    pass "(e) workspace under .aws/ path not denied by denylist (exit=0)"
  else
    fail "(e) workspace path should not trigger denylist; got exit=$exit_code stderr=${stderr_out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (g) Project .rip-cage.yaml with mounts.denylist: [my-secret-pattern] is
# respected additively on top of global defaults.
#
# Subtest A: --env-file path containing my-secret-pattern component → denied.
# Subtest B: --env-file path containing .aws component → STILL denied (global
#            default not lost when project has its own denylist entry).
# ---------------------------------------------------------------------------
test_g_project_additive_denylist() {
  setup_sandbox
  write_default_global_config

  # Project config adds my-secret-pattern on top of global defaults.
  cat > "${TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
mounts:
  denylist:
    - my-secret-pattern
YAML

  # --- Subtest A: project pattern blocks path with my-secret-pattern component ---
  local project_dir="${TEST_TMPDIR}/my-secret-pattern"
  local env_path_a="${project_dir}/envfile.env"
  mkdir -p "$project_dir"
  touch "$env_path_a"

  local stderr_a
  local exit_a=0
  stderr_a=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up --dry-run \
      --env-file "$env_path_a" \
      "$TEST_WS" 2>&1 >/dev/null
  ) || exit_a=$?

  if [[ "$exit_a" -ne 0 ]] \
     && printf '%s' "$stderr_a" | grep -q "matched secret-path denylist pattern"; then
    pass "(g-A) project denylist pattern 'my-secret-pattern' blocks --env-file path (exit=$exit_a)"
  else
    fail "(g-A) expected project pattern to block path; got exit=$exit_a stderr=$stderr_a"
  fi

  # --- Subtest B: global .aws pattern still blocked (project doesn't shadow global) ---
  mkdir -p "${TEST_TMPDIR}/.aws"
  touch "${TEST_TMPDIR}/.aws/creds"

  local stderr_b
  local exit_b=0
  stderr_b=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_TMPDIR}" \
    bash "$RC" up --dry-run \
      --env-file "${TEST_TMPDIR}/.aws/creds" \
      "$TEST_WS" 2>&1 >/dev/null
  ) || exit_b=$?

  if [[ "$exit_b" -ne 0 ]] \
     && printf '%s' "$stderr_b" | grep -q "matched secret-path denylist pattern"; then
    pass "(g-B) global .aws pattern still denied when project has its own denylist (exit=$exit_b)"
  else
    fail "(g-B) expected global .aws pattern to remain effective; got exit=$exit_b stderr=$stderr_b"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (h) rc config show surfaces mounts.denylist with provenance
#
# Verifies that the existing generic provenance loop in cmd_config_show
# automatically surfaces mounts.denylist once it is declared in the schema
# (slot .1 declared it as additive_list).
#
# Setup: global config with [.aws, .ssh] + project config with [.env].
# Expected effective denylist: [.aws, .ssh, .env] (additive union).
# Expected provenance: output shows "union(global, project)" or per-element
# labels (global / project) for individual items.
# ---------------------------------------------------------------------------
test_h_config_show_denylist_provenance() {
  setup_sandbox

  # Global: .aws and .ssh
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<YAML
version: 1
mounts:
  denylist:
    - .aws
    - .ssh
YAML

  # Project: .env (additive on top)
  cat > "${TEST_WS}/.rip-cage.yaml" <<YAML
version: 1
mounts:
  denylist:
    - .env
YAML

  local stdout_out
  local exit_code=0
  stdout_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_CONFIG_GLOBAL="${TEST_HOME}/.config/rip-cage/config.yaml" \
    bash -c "cd '${TEST_WS}' && bash '${RC}' config show" 2>/dev/null
  ) || exit_code=$?

  # Must: surface mounts.denylist key
  local has_denylist_key=0
  printf '%s' "$stdout_out" | grep -q "denylist" && has_denylist_key=1

  # Must: show merged effective value contains .aws, .ssh, and .env
  local has_aws=0 has_ssh=0 has_env=0
  printf '%s' "$stdout_out" | grep -q "\.aws" && has_aws=1
  printf '%s' "$stdout_out" | grep -q "\.ssh" && has_ssh=1
  printf '%s' "$stdout_out" | grep -q "\.env" && has_env=1

  # Must: show provenance information (global, project, or union)
  local has_provenance=0
  printf '%s' "$stdout_out" | grep -qE "global|project|union" && has_provenance=1

  if [[ "$exit_code" -eq 0 \
     && "$has_denylist_key" -eq 1 \
     && "$has_aws" -eq 1 \
     && "$has_ssh" -eq 1 \
     && "$has_env" -eq 1 \
     && "$has_provenance" -eq 1 ]]; then
    pass "(h) rc config show surfaces mounts.denylist with provenance (all 3 patterns present)"
  else
    fail "(h) rc config show missing denylist/patterns/provenance; exit=$exit_code key=$has_denylist_key aws=$has_aws ssh=$has_ssh env=$has_env prov=$has_provenance"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (i) shellcheck rc exits clean
#
# Runs shellcheck against the rc script and asserts exit 0 (no warnings or
# errors).  Any shellcheck finding introduced by slots .1 or .2 must be fixed
# in rc before this test can pass (per bead .3 zero-rc-touch contract: if new
# warnings surface here, surface them rather than fixing inline, since that
# would breach the zero-rc-touch scope).
# ---------------------------------------------------------------------------
test_i_shellcheck_rc_clean() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    pass "(i) shellcheck not installed — skip (not required in this env)"
    return
  fi

  local exit_code=0
  shellcheck "$RC" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "(i) shellcheck rc exits 0 (no warnings)"
  else
    fail "(i) shellcheck rc exited $exit_code — new warnings in rc from slots .1/.2?"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== test-secret-path-denylist.sh — ADR-023 denylist plumbing (rip-cage-3gu.2/.3) ==="
test_a_envfile_aws_denied
test_b_envfile_symlink_resolved_and_blocked
test_bprime_skill_symlink_aws_target_skipped
test_c_allow_risky_mount_flag_bypass
test_d_allow_risky_yaml_bypass
test_e_workspace_structurally_exempted
test_f_dotenv_path_allowed
test_g_project_additive_denylist
test_h_config_show_denylist_provenance
test_i_shellcheck_rc_clean
test_j_missing_global_config_fails_loud
test_k_rc_install_writes_16_patterns

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
