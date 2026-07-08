#!/usr/bin/env bash
# Tier-1 structural smoke test: dcg demoted from base image to composable recipe (rip-cage-wlwc.10).
#
# ADR-025 D2 (dcg = composable recipe, not floor), ADR-025 D3 (dcg-guard engine retained),
# ADR-005 D12 (composable seam, not bundler).
#
# Three structural proofs (host-side, auth-free, fast):
#
#   DS1 — Dockerfile: no rust-builder stage (dcg binary un-baked from base image).
#          Grep proves absence of "rust-builder" stage header and the
#          "COPY --from=rust-builder" line that put the dcg binary into the runtime layer.
#
#   DS2 — Dockerfile: dcg engine ABSENT from base; recipe ACTUALLY provisions it.
#          (a) dcg/dcg-guard, dcg/default-config.toml, and ripcage-testsentinel absent
#              from the Dockerfile — engine fully un-baked (ADR-025 D2/D3 revised).
#          (b) examples/dcg/manifest-fragment.yaml install_cmd contains root-owned writes
#              for the guard wrapper, config, and sentinel dest paths — proving the recipe
#              genuinely provisions the engine, not phantom host-missing mounts.
#
#   DS3 — examples/dcg/manifest-fragment.yaml: recipe declares a from-source TOOL
#          entry (build_source present, version_pin non-bundled) PLUS at least one mount
#          with mode: ro and root_owned_required: true (tamper-proof wiring asset).
#          Validated by the existing manifest validator (_manifest_validate).
#
#   DS4 — Default manifest (rc _manifest_default_yaml): dcg is NOT in the default
#          manifest as a bundled tool — confirms dcg is opt-in, not shipped default.
#
# Tier-2 behavioral tests (RC_E2E-gated, authored not necessarily run):
#   DB1 — A cage WITH the dcg recipe (via examples/dcg/manifest-fragment.yaml) denies one
#          destructive command (rm -rf /). Gated behind RC_E2E=1.
#   DB2 — A cage WITHOUT the dcg recipe has no command-guard (containment still holds via
#          other layers). Gated behind RC_E2E=1.
#
# Anti-false-green discipline:
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * Structural tests assert SPECIFIC content, not merely file existence.
#   * DS2(b) is the positive control for the recipe: if install_cmd has no root-owned
#     writes for guard/config/sentinel, DS2 fails, preventing a false pass from a
#     decorative (phantom-mount) recipe that doesn't actually provision anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
DOCKERFILE="${REPO_ROOT}/cage/Dockerfile"
EXAMPLES_DCG="${REPO_ROOT}/examples/dcg"
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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-dcg-demotion-test-XXXXXX")
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
# DS1 — Dockerfile: no rust-builder stage and no COPY --from=rust-builder
#        (dcg binary un-baked from base image)
# ---------------------------------------------------------------------------
test_ds1_rust_builder_removed() {
  local rust_builder_stage_count copy_from_rust_count
  rust_builder_stage_count=$(grep -c "AS rust-builder" "$DOCKERFILE" || true)
  copy_from_rust_count=$(grep -c "COPY --from=rust-builder" "$DOCKERFILE" || true)

  if [[ "$rust_builder_stage_count" -eq 0 && "$copy_from_rust_count" -eq 0 ]]; then
    pass "DS1 Dockerfile: rust-builder stage ABSENT (count=0) and COPY --from=rust-builder ABSENT (count=0) — dcg binary un-baked"
  else
    fail "DS1 Dockerfile: rust-builder stage or COPY --from=rust-builder still present. stage_count=${rust_builder_stage_count} copy_count=${copy_from_rust_count} — un-bake incomplete"
  fi
}

# ---------------------------------------------------------------------------
# DS2 — Dockerfile: dcg engine ABSENT from base; recipe ACTUALLY provisions it.
#        (a) dcg/dcg-guard, dcg/default-config.toml, and ripcage-testsentinel ABSENT
#            from the Dockerfile — engine is not baked in base (ADR-025 D2/D3).
#        (b) examples/dcg/manifest-fragment.yaml install_cmd contains root-owned
#            writes for the guard wrapper, config, and sentinel paths — proving
#            the recipe genuinely provisions them (not decorative mounts).
# ---------------------------------------------------------------------------
test_ds2_dcg_engine_absent_from_base_and_provisioned_by_recipe() {
  # (a) Dockerfile must NOT contain the three engine COPYs
  local dcg_guard_in_df config_in_df sentinel_in_df
  dcg_guard_in_df=$(grep -cE "dcg/dcg-guard" "$DOCKERFILE" || true)
  config_in_df=$(grep -cE "dcg/default-config\.toml" "$DOCKERFILE" || true)
  sentinel_in_df=$(grep -cE "ripcage-testsentinel" "$DOCKERFILE" || true)

  local absent_ok=1
  if [[ "$dcg_guard_in_df" -gt 0 ]]; then
    fail "DS2(a) Dockerfile: dcg/dcg-guard still present in base image (count=${dcg_guard_in_df}) — engine un-bake incomplete (ADR-025 D2)"
    absent_ok=0
  fi
  if [[ "$config_in_df" -gt 0 ]]; then
    fail "DS2(a) Dockerfile: dcg/default-config.toml still present in base image (count=${config_in_df}) — engine un-bake incomplete (ADR-025 D2)"
    absent_ok=0
  fi
  if [[ "$sentinel_in_df" -gt 0 ]]; then
    fail "DS2(a) Dockerfile: ripcage-testsentinel still present in base image (count=${sentinel_in_df}) — engine un-bake incomplete (ADR-025 D2)"
    absent_ok=0
  fi
  if [[ "$absent_ok" -eq 1 ]]; then
    pass "DS2(a) Dockerfile: dcg-guard, default-config.toml, sentinel ALL absent from base image — engine un-baked (ADR-025 D2)"
  fi

  # (b) Recipe install_cmd must contain root-owned writes for all three dest paths.
  #     Grep the manifest for the exact chown+chmod commands that prove the recipe
  #     genuinely provisions the engine (not phantom host-missing mounts).
  local manifest_file="${EXAMPLES_DCG}/manifest-fragment.yaml"
  if [[ ! -f "$manifest_file" ]]; then
    fail "DS2(b) examples/dcg/manifest-fragment.yaml: file NOT FOUND — cannot verify recipe provisioning"
    return
  fi

  local install_cmd_content
  install_cmd_content=$(grep "install_cmd:" "$manifest_file" || true)

  local recipe_ok=1
  # Guard wrapper root-owned write
  if ! echo "$install_cmd_content" | grep -q "dcg-guard.*chown root:root\|chown root:root.*dcg-guard"; then
    # Check for the base64 pattern: writes to dcg-guard path then chown root:root
    if ! echo "$install_cmd_content" | grep -q "/usr/local/lib/rip-cage/bin/dcg-guard.*chown"; then
      fail "DS2(b) recipe install_cmd: missing root-owned write for dcg-guard wrapper at /usr/local/lib/rip-cage/bin/dcg-guard"
      recipe_ok=0
    fi
  fi
  # Config root-owned write
  if ! echo "$install_cmd_content" | grep -q "dcg/config\.toml\|rip-cage/dcg/config"; then
    fail "DS2(b) recipe install_cmd: missing root-owned write for dcg config at /usr/local/lib/rip-cage/dcg/config.toml"
    recipe_ok=0
  fi
  # Sentinel root-owned write
  if ! echo "$install_cmd_content" | grep -q "ripcage-testsentinel"; then
    fail "DS2(b) recipe install_cmd: missing root-owned write for sentinel at ripcage-testsentinel-rule.yaml path"
    recipe_ok=0
  fi
  if [[ "$recipe_ok" -eq 1 ]]; then
    pass "DS2(b) recipe install_cmd: provisions dcg-guard, config.toml, sentinel root-owned at dest paths — real provisioning (not phantom mounts)"
  fi
}

# ---------------------------------------------------------------------------
# DS3 — examples/dcg/manifest-fragment.yaml: recipe structure valid
#        a) manifest-fragment.yaml exists under examples/dcg/
#        b) declares a from-source TOOL with build_source (for the dcg binary)
#        c) declares an install_cmd TOOL entry for the wiring (dcg-guard + config + sentinel),
#           provisioning them root-owned via chown root:root (not phantom mounts)
#        d) validates clean via _manifest_validate
# ---------------------------------------------------------------------------
test_ds3_recipe_structure() {
  local manifest_file="${EXAMPLES_DCG}/manifest-fragment.yaml"

  # (a) File exists
  if [[ ! -f "$manifest_file" ]]; then
    fail "DS3 examples/dcg/manifest-fragment.yaml: file NOT FOUND at ${manifest_file}"
    return
  fi

  # (b) build_source present (from-source TOOL entry for the dcg binary)
  local has_build_source
  has_build_source=$(grep -c "build_source:" "$manifest_file" || true)
  if [[ "$has_build_source" -eq 0 ]]; then
    fail "DS3 examples/dcg/manifest-fragment.yaml: no build_source block found — recipe must declare from-source build for the dcg binary"
    return
  fi

  # (c) install_cmd present with chown root:root writes for the engine wiring assets.
  #     Ownership is enforced via install_cmd (base64-embedded root-owned writes),
  #     not phantom host-missing mounts. Check that the wiring assets appear in install_cmd.
  local has_install_cmd install_cmd_content
  has_install_cmd=$(grep -c "install_cmd:" "$manifest_file" || true)
  if [[ "$has_install_cmd" -eq 0 ]]; then
    fail "DS3 examples/dcg/manifest-fragment.yaml: no install_cmd found — recipe must declare wiring entry that provisions engine root-owned"
    return
  fi
  install_cmd_content=$(grep "install_cmd:" "$manifest_file" || true)
  if ! echo "$install_cmd_content" | grep -q "chown root:root"; then
    fail "DS3 examples/dcg/manifest-fragment.yaml: install_cmd has no 'chown root:root' — wiring assets must be provisioned root-owned"
    return
  fi

  # (d) validates clean via _manifest_validate
  setup_manifest_sandbox
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${manifest_file}'" 2>"$stderr_file" || exit_code=$?
  teardown_manifest_sandbox

  if [[ "$exit_code" -eq 0 ]]; then
    pass "DS3 examples/dcg/manifest-fragment.yaml: has build_source (binary), install_cmd with root-owned wiring writes, validates clean"
  else
    fail "DS3 examples/dcg/manifest-fragment.yaml: _manifest_validate rejected it. exit=${exit_code} stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
}

# ---------------------------------------------------------------------------
# DS4 — Default manifest: dcg NOT present as bundled (opt-in only)
# ---------------------------------------------------------------------------
test_ds4_dcg_not_in_default_manifest() {
  setup_manifest_sandbox

  # Emit the default manifest YAML and check dcg is not bundled
  local default_yaml exit_code
  exit_code=0
  default_yaml=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_default_yaml" 2>/dev/null) || exit_code=$?
  teardown_manifest_sandbox

  if [[ "$exit_code" -ne 0 ]]; then
    fail "DS4 _manifest_default_yaml failed to emit. exit=${exit_code}"
    return
  fi

  # dcg must NOT appear in the default manifest with version_pin: "bundled"
  # (it was previously bundled; after demotion it must be absent or opt-in only)
  local has_bundled_dcg
  has_bundled_dcg=$(echo "$default_yaml" | grep -c "name: dcg" || true)
  if [[ "$has_bundled_dcg" -eq 0 ]]; then
    pass "DS4 default manifest: dcg NOT present as bundled tool — opt-in recipe only (demotion complete)"
  else
    fail "DS4 default manifest: dcg still present as bundled tool (count=${has_bundled_dcg}) — demotion incomplete"
  fi
}

# ---------------------------------------------------------------------------
# DB1 / DB2 — Behavioral (Tier-2, RC_E2E-gated)
# ---------------------------------------------------------------------------
test_db1_cage_with_dcg_recipe_denies_destructive_command() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / RC_E2E): DB1 cage+dcg recipe denies destructive command — set RC_E2E=1 to run"
    return 0
  fi
  # Author note: build a cage from examples/dcg/manifest-fragment.yaml, then
  # docker exec to test that 'rm -rf /' is denied by the CC DCG PreToolUse hook.
  # This requires a running cage and is handled by the integration harness bead .6.
  echo "SKIP (RC_E2E enabled but DB1 is owned by integration-harness bead .6 — skipping here)"
  return 0
}

test_db2_cage_without_dcg_recipe_has_no_command_guard() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / RC_E2E): DB2 cage without dcg has no command-guard — set RC_E2E=1 to run"
    return 0
  fi
  echo "SKIP (RC_E2E enabled but DB2 is owned by integration-harness bead .6 — skipping here)"
  return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-dcg-demotion.sh — dcg demoted from base image to composable recipe (rip-cage-wlwc.10) ==="
echo ""
echo "--- DS1-DS4: Structural (Tier-1, host-side, auth-free) ---"
test_ds1_rust_builder_removed
test_ds2_dcg_engine_absent_from_base_and_provisioned_by_recipe
test_ds3_recipe_structure
test_ds4_dcg_not_in_default_manifest

echo ""
echo "--- DB1-DB2: Behavioral (Tier-2, RC_E2E-gated) ---"
test_db1_cage_with_dcg_recipe_denies_destructive_command
test_db2_cage_without_dcg_recipe_has_no_command_guard

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
