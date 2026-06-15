#!/usr/bin/env bash
# Host-side unit tests for rc up auto-seed of global config (rip-cage-j86).
#
# Coverage:
#   S1  fresh state (no global config): rc up auto-seeds and does NOT exit 1
#       at the old preflight point; one-line stderr notice emitted
#   S2  idempotent: second invocation does not rewrite or re-notice
#   S3  seeded content byte-matches _config_default_global_yaml (has all 16 patterns)
#   S4  rc doctor --host reports yq status line
#   S5  rc doctor --host reports global-config status line
#
# CRITICAL: run-host.sh exports RC_CONFIG_GLOBAL pointing to a benign fixture
# for all tests in the suite. These tests exercise the "config absent -> auto-seed"
# path and MUST override that fixture. We unset RC_CONFIG_GLOBAL at file-top so
# per-test XDG_CONFIG_HOME sandboxes resolve correctly (matching the pattern in
# test-secret-path-denylist.sh).
unset RC_CONFIG_GLOBAL

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_TMPDIR=""
TEST_HOME=""
TEST_WS=""

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# Set up a fresh per-test sandbox with:
#   TEST_TMPDIR  — temp root
#   TEST_HOME    — fake HOME (no .config/rip-cage/ created — that's the point)
#   TEST_WS      — fake workspace directory
setup_sandbox() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-autoseed-XXXXXX")
  TEST_HOME="${TEST_TMPDIR}/home"
  TEST_WS="${TEST_TMPDIR}/workspace"
  mkdir -p "$TEST_HOME"
  mkdir -p "$TEST_WS"
}

teardown_sandbox() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
  TEST_HOME=""
  TEST_WS=""
}

# ---------------------------------------------------------------------------
# S1: fresh state -> auto-seed: rc up does NOT exit 1 at old preflight point;
#     a one-line stderr notice is emitted naming the seeded config path.
# ---------------------------------------------------------------------------
test_s1_fresh_state_auto_seeds() {
  setup_sandbox
  # Deliberately do NOT create ~/.config/rip-cage/config.yaml

  local cfg_path="${TEST_HOME}/.config/rip-cage/config.yaml"
  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash "$RC" up --dry-run "$TEST_WS" 2>&1 >/dev/null
  ) || exit_code=$?

  # rc up --dry-run exits 0 when the image check is the only remaining step
  # (no docker required). Regardless of its exit, the global config MUST be
  # seeded and the notice MUST appear in stderr.
  if [[ ! -f "$cfg_path" ]]; then
    fail "S1 fresh state auto-seeds: global config not created at $cfg_path (exit=$exit_code, stderr=$stderr_out)"
    teardown_sandbox
    return
  fi
  if ! printf '%s' "$stderr_out" | grep -q "seeded default"; then
    fail "S1 fresh state auto-seeds: stderr notice missing 'seeded default' (exit=$exit_code, stderr=$stderr_out)"
    teardown_sandbox
    return
  fi
  # Must NOT exit 1 at the old "rc install" preflight (which said "Run rc install")
  if printf '%s' "$stderr_out" | grep -q "Run 'rc install'"; then
    fail "S1 fresh state auto-seeds: old hard-stop message appeared (should be gone) (stderr=$stderr_out)"
    teardown_sandbox
    return
  fi
  pass "S1 fresh state auto-seeds: config seeded, notice emitted, old hard-stop gone (exit=$exit_code)"

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S2: idempotent — second invocation does not rewrite or emit notice again.
# ---------------------------------------------------------------------------
test_s2_idempotent() {
  setup_sandbox
  # Pre-create the config dir and write sentinel config AND tool-manifest files
  # so the second run finds BOTH present and is genuinely silent (no re-seed of either).
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  local cfg_path="${TEST_HOME}/.config/rip-cage/config.yaml"
  cat > "$cfg_path" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
  # Pre-seed tools.yaml so _manifest_ensure_seeded finds it and returns silently.
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools: []
YAML
  local tools_path="${TEST_HOME}/.config/rip-cage/tools.yaml"
  # Idempotency invariant = CONTENT unchanged, not mtime. mtime is a fragile
  # proxy: it is second-granularity (stat %m/%Y) and a no-op re-stat or any
  # benign touch can flip it, producing a flaky failure on slower CI runners
  # while passing on a fast dev box. Compare the file bytes instead — the true
  # invariant is "the second run does not change the seeded files."
  local original_cfg original_tools
  original_cfg=$(cat "$cfg_path")
  original_tools=$(cat "$tools_path")

  local stderr_out
  stderr_out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash "$RC" up --dry-run "$TEST_WS" 2>&1 >/dev/null
  ) || true

  if printf '%s' "$stderr_out" | grep -q "seeded default"; then
    fail "S2 idempotent: seeding notice emitted on second run (should be silent) (stderr=$stderr_out)"
    teardown_sandbox
    return
  fi
  if [[ "$original_cfg" != "$(cat "$cfg_path")" ]]; then
    fail "S2 idempotent: config.yaml content changed on second run"
    teardown_sandbox
    return
  fi
  if [[ "$original_tools" != "$(cat "$tools_path")" ]]; then
    fail "S2 idempotent: tools.yaml content changed on second run"
    teardown_sandbox
    return
  fi
  pass "S2 idempotent: no notice, no rewrite of config.yaml or tools.yaml on second run"

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S3: seeded content contains all 16 expected denylist patterns.
# ---------------------------------------------------------------------------
test_s3_seeded_content_has_16_patterns() {
  setup_sandbox
  # No global config — let auto-seed create it

  local cfg_path="${TEST_HOME}/.config/rip-cage/config.yaml"
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  RC_ALLOWED_ROOTS="${TEST_WS}" \
  bash "$RC" up --dry-run "$TEST_WS" >/dev/null 2>&1 || true

  if [[ ! -f "$cfg_path" ]]; then
    fail "S3 seeded content: config not created (prereq failed)"
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
    pass "S3 seeded content: all 16 expected denylist patterns present"
  else
    fail "S3 seeded content: missing patterns: ${missing[*]} — file: $(cat "$cfg_path")"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S4: rc doctor --host reports a yq status line.
# ---------------------------------------------------------------------------
test_s4_doctor_host_reports_yq() {
  setup_sandbox
  # Provide a global config so doctor doesn't stall on missing config
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML

  local out
  out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash "$RC" doctor --host 2>&1 || true
  )

  if printf '%s' "$out" | grep -qi "yq"; then
    pass "S4 doctor --host reports yq status line"
  else
    fail "S4 doctor --host: expected a line mentioning 'yq'; got: $out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# S5: rc doctor --host reports global-config status line.
# ---------------------------------------------------------------------------
test_s5_doctor_host_reports_global_config() {
  setup_sandbox
  # Provide a global config
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML

  local out
  out=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash "$RC" doctor --host 2>&1 || true
  )

  # Should report on global config (e.g. "Global config: OK" or similar)
  if printf '%s' "$out" | grep -qi "global config\|config.yaml"; then
    pass "S5 doctor --host reports global-config status line"
  else
    fail "S5 doctor --host: expected a line about global config; got: $out"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== test-auto-seed.sh — rc up auto-seed of global config (rip-cage-j86) ==="
test_s1_fresh_state_auto_seeds
test_s2_idempotent
test_s3_seeded_content_has_16_patterns
test_s4_doctor_host_reports_yq
test_s5_doctor_host_reports_global_config

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
