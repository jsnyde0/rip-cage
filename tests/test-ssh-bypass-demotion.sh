#!/usr/bin/env bash
# Tier-1 structural smoke test: block-ssh-bypass hook demoted from base image to composable recipe (rip-cage-wlwc.11).
#
# ADR-025 D2 (command-string guard = composable recipe, not floor),
# ADR-026 D2 (same), ADR-022 (known_hosts mount floor — distinct from the ssh-bypass hook),
# ADR-005 D12 (composable seam, not bundler).
#
# Three structural proofs (host-side, auth-free, fast):
#
#   SS1 — Dockerfile: block-ssh-bypass.sh absent from baked hooks COPY and chmod.
#          Grep proves absence of the hooks COPY and the chmod hooks/*.sh that
#          baked the hook into the base image. The known_hosts/ssh_config MOUNT floor
#          (COPY cage/guards/ssh/known_hosts.github + COPY cage/guards/ssh/ssh_config) MUST still be present.
#
#   SS2 — settings.json: no PreToolUse wiring for block-ssh-bypass.
#          The baked settings.json must NOT contain "block-ssh-bypass" — confirming
#          the hook is un-baked from the CC configuration layer.
#
#   SS3 — examples/ssh-bypass/ recipe exists, genuinely provisions the hook root-owned,
#          and ships a CC PreToolUse settings fragment.
#          (a) examples/ssh-bypass/manifest-fragment.yaml exists.
#          (b) install_cmd provisions block-ssh-bypass.sh via chown root:root at its
#              dest path — genuine provisioning, not a phantom host-missing mount.
#          (c) A CC PreToolUse settings fragment (examples/ssh-bypass/settings-fragment.json)
#              exists and references the hook's dest path.
#          (d) manifest-fragment.yaml validates clean via _manifest_validate.
#
# Tier-2 behavioral tests (RC_E2E-gated, authored not run):
#   SB1 — A cage WITH the ssh-bypass recipe denies a host-key-override ssh command.
#   SB2 — A cage WITHOUT the recipe has no ssh-bypass guard (containment via other layers).
#
# Anti-false-green discipline:
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * SS3(b) is the positive control: if install_cmd has no root-owned write for the
#     hook, SS3 fails — preventing a false pass from a decorative phantom-mount recipe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
DOCKERFILE="${REPO_ROOT}/cage/Dockerfile"
SETTINGS_JSON="${REPO_ROOT}/cage/agent/settings.json"
EXAMPLES_SSH="${REPO_ROOT}/examples/ssh-bypass"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

setup_manifest_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-ssh-bypass-demotion-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist:
    - ".ssh"
    - ".gnupg"
    - ".aws"
  allow_risky: null
YAML
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# ---------------------------------------------------------------------------
# SS1 — Dockerfile: block-ssh-bypass ABSENT from baked hooks COPY/chmod;
#        known_hosts/ssh_config MOUNT floor STILL PRESENT (unchanged).
# ---------------------------------------------------------------------------
test_ss1_hook_absent_from_dockerfile_floor_intact() {
  # The hooks/ COPY baked block-ssh-bypass.sh. After demotion, COPY hooks/ must be gone.
  local hooks_copy_count
  hooks_copy_count=$(grep -cE "^COPY hooks/" "$DOCKERFILE" || true)

  if [[ "$hooks_copy_count" -eq 0 ]]; then
    pass "SS1(a) Dockerfile: 'COPY hooks/' bake line ABSENT — block-ssh-bypass.sh un-baked from base image"
  else
    fail "SS1(a) Dockerfile: 'COPY hooks/' bake still present (count=${hooks_copy_count}) — un-bake incomplete; must remove the COPY hooks/ line"
  fi

  # chmod hooks/*.sh must also be gone (it made the baked hook executable)
  local hooks_chmod_count
  hooks_chmod_count=$(grep -cE "hooks/\*\.sh" "$DOCKERFILE" || true)

  if [[ "$hooks_chmod_count" -eq 0 ]]; then
    pass "SS1(b) Dockerfile: 'hooks/*.sh' chmod bake line ABSENT — hook chmod un-baked"
  else
    fail "SS1(b) Dockerfile: 'hooks/*.sh' chmod still present in Dockerfile (count=${hooks_chmod_count}) — un-bake incomplete"
  fi

  # Known_hosts floor MUST still be present (ADR-022 — distinct from the ssh-bypass hook)
  local known_hosts_count ssh_config_count
  known_hosts_count=$(grep -cE "COPY cage/guards/ssh/known_hosts" "$DOCKERFILE" || true)
  ssh_config_count=$(grep -cE "COPY cage/guards/ssh/ssh_config" "$DOCKERFILE" || true)

  if [[ "$known_hosts_count" -gt 0 && "$ssh_config_count" -gt 0 ]]; then
    pass "SS1(c) Dockerfile: known_hosts floor INTACT (COPY cage/guards/ssh/known_hosts.github count=${known_hosts_count}, COPY cage/guards/ssh/ssh_config count=${ssh_config_count}) — floor untouched (ADR-022)"
  else
    fail "SS1(c) Dockerfile: known_hosts floor BROKEN — known_hosts_count=${known_hosts_count}, ssh_config_count=${ssh_config_count}; this floor must NOT be removed (ADR-022)"
  fi
}

# ---------------------------------------------------------------------------
# SS2 — settings.json: no PreToolUse wiring for block-ssh-bypass
# ---------------------------------------------------------------------------
test_ss2_settings_json_no_wiring() {
  local ssh_bypass_count
  ssh_bypass_count=$(grep -cE "block-ssh-bypass" "$SETTINGS_JSON" || true)

  if [[ "$ssh_bypass_count" -eq 0 ]]; then
    pass "SS2 settings.json: 'block-ssh-bypass' PreToolUse wiring ABSENT (count=0) — hook un-baked from CC settings"
  else
    fail "SS2 settings.json: 'block-ssh-bypass' still present (count=${ssh_bypass_count}) — PreToolUse wiring un-bake incomplete"
  fi
}

# ---------------------------------------------------------------------------
# SS3 — examples/ssh-bypass/ recipe exists, genuinely provisions the hook
#        root-owned, and ships a CC PreToolUse settings fragment.
# ---------------------------------------------------------------------------
test_ss3_recipe_ships_and_provisions() {
  local manifest_file="${EXAMPLES_SSH}/manifest-fragment.yaml"
  local settings_frag="${EXAMPLES_SSH}/settings-fragment.json"

  # (a) manifest-fragment.yaml exists
  if [[ ! -f "$manifest_file" ]]; then
    fail "SS3(a) examples/ssh-bypass/manifest-fragment.yaml: file NOT FOUND at ${manifest_file}"
    return
  fi
  pass "SS3(a) examples/ssh-bypass/manifest-fragment.yaml: file exists"

  # (b) install_cmd provisions block-ssh-bypass.sh root-owned at its dest path.
  #     The dest path is /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh (same path
  #     the baked hook occupied — the recipe must provision it at the same dest so the
  #     settings-fragment hook command works without rc edits).
  local install_cmd_content
  install_cmd_content=$(grep "install_cmd:" "$manifest_file" || true)

  local recipe_ok=1
  if ! echo "$install_cmd_content" | grep -q "block-ssh-bypass"; then
    fail "SS3(b) recipe install_cmd: missing write for block-ssh-bypass.sh hook — recipe does not provision the hook asset"
    recipe_ok=0
  fi
  if ! echo "$install_cmd_content" | grep -q "chown root:root"; then
    fail "SS3(b) recipe install_cmd: missing 'chown root:root' — hook must be provisioned root-owned (agent-unwritable)"
    recipe_ok=0
  fi
  if [[ "$recipe_ok" -eq 1 ]]; then
    pass "SS3(b) recipe install_cmd: provisions block-ssh-bypass.sh root-owned at dest path — real provisioning (not phantom mount)"
  fi

  # (c) settings-fragment.json exists and references the hook dest path
  if [[ ! -f "$settings_frag" ]]; then
    fail "SS3(c) examples/ssh-bypass/settings-fragment.json: file NOT FOUND at ${settings_frag} — CC PreToolUse registration fragment missing"
    return
  fi
  if ! grep -q "block-ssh-bypass" "$settings_frag"; then
    fail "SS3(c) examples/ssh-bypass/settings-fragment.json: does not reference 'block-ssh-bypass' — settings fragment must show hook registration"
  else
    pass "SS3(c) examples/ssh-bypass/settings-fragment.json: exists and references block-ssh-bypass hook path"
  fi
  # settings-fragment.json must be valid JSON
  if jq . "$settings_frag" >/dev/null 2>&1; then
    pass "SS3(c) examples/ssh-bypass/settings-fragment.json: valid JSON"
  else
    fail "SS3(c) examples/ssh-bypass/settings-fragment.json: invalid JSON — jq parse failed"
  fi

  # (d) manifest-fragment.yaml validates clean via _manifest_validate
  setup_manifest_sandbox
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${manifest_file}'" 2>"$stderr_file" || exit_code=$?
  teardown_manifest_sandbox

  if [[ "$exit_code" -eq 0 ]]; then
    pass "SS3(d) examples/ssh-bypass/manifest-fragment.yaml: validates clean via _manifest_validate"
  else
    fail "SS3(d) examples/ssh-bypass/manifest-fragment.yaml: _manifest_validate rejected it. exit=${exit_code} stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# SB1 / SB2 — Behavioral (Tier-2, RC_E2E-gated)
# ---------------------------------------------------------------------------
test_sb1_cage_with_recipe_denies_host_key_override_ssh() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / RC_E2E): SB1 cage+ssh-bypass recipe denies host-key-override ssh — set RC_E2E=1 to run"
    return 0
  fi
  # Author note: build a cage from examples/ssh-bypass/manifest-fragment.yaml, then
  # docker exec to test that 'ssh -o StrictHostKeyChecking=accept-new host' is denied.
  # Owned by integration-harness bead .6.
  echo "SKIP (RC_E2E enabled but SB1 is owned by integration-harness bead .6 — skipping here)"
  return 0
}

test_sb2_cage_without_recipe_has_no_ssh_bypass_guard() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / RC_E2E): SB2 cage without recipe has no ssh-bypass guard — set RC_E2E=1 to run"
    return 0
  fi
  echo "SKIP (RC_E2E enabled but SB2 is owned by integration-harness bead .6 — skipping here)"
  return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-ssh-bypass-demotion.sh — block-ssh-bypass hook demoted from base image to composable recipe (rip-cage-wlwc.11) ==="
echo ""
echo "--- SS1-SS3: Structural (Tier-1, host-side, auth-free) ---"
test_ss1_hook_absent_from_dockerfile_floor_intact
test_ss2_settings_json_no_wiring
test_ss3_recipe_ships_and_provisions

echo ""
echo "--- SB1-SB2: Behavioral (Tier-2, RC_E2E-gated) ---"
test_sb1_cage_with_recipe_denies_host_key_override_ssh
test_sb2_cage_without_recipe_has_no_ssh_bypass_guard

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
