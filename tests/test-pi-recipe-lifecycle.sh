#!/usr/bin/env bash
# Host-side tests for pi-recipe full-lifecycle ownership (rip-cage-p35a.3).
#
# Implements the acceptance contract:
#   - pi's extensions-dir provisioning (rip-cage-fwp3) lives in pi's own recipe
#     (examples/pi/manifest-fragment.yaml), as a TOOL 'init' agent-context
#     boot-hook (rip-cage-p35a.2 seam, ADR-005 D7) — NOT in base init-rip-cage.sh.
#   - init-rip-cage.sh's remaining pi/PI_CODING references are all justified
#     base-infra (genuinely can't move to the per-recipe seam).
#   - manifest/default-tools.yaml and the l72i.7 e2e fixture (verbatim copies of
#     the pi-recipe entry) stay in sync with examples/pi/manifest-fragment.yaml.
#   - the pi recipe ships the --model launch_arg MECHANISM + a documented
#     EXAMPLE, but NOT an active universal default (DESIGN CLARIFICATION,
#     orchestrator note 2026-07-02: forcing one provider on every operator
#     would break anyone without that provider's auth).
#
# =============================================================================
# Test tiers
# =============================================================================
#   T1 (host-only, runs always):
#     T1a — pi-recipe TOOL entry declares an 'init' field (single-line,
#           mkdir the extensions dir with the fwp3 fail-loud WARNING intent).
#     T1b — the 'init' value passes _manifest_validate (hook-bounds clean).
#     T1c — _manifest_generate_tool_init_config_dockerfile_steps, run against
#           a sandbox seeded with the REAL examples/pi/manifest-fragment.yaml,
#           bakes a tool-init-config.json step (the seam actually wires the
#           real recipe, not just a synthetic fixture).
#     T1d — init-rip-cage.sh no longer contains the fwp3 mkdir block (unique
#           markers: _rc_pi_ext_dir=, the command -v pi gated mkdir).
#     T1e — init-rip-cage.sh's remaining pi-specific lines (chown, substrate
#           link loop, pi-verify) each carry a BASE-INFRA justification tag.
#     T1f — manifest/default-tools.yaml's pi-recipe entry byte-matches examples/
#           pi/manifest-fragment.yaml's pi-recipe entry (dist-sync).
#     T1g — tests/fixtures/manifest-dcg-herdr-pi.yaml's pi-recipe entry
#           byte-matches examples/pi/manifest-fragment.yaml's pi-recipe entry
#           (e2e-fixture-sync — keeps the l72i.7 conjunction test representative).
#     T1h — examples/pi/manifest-fragment.yaml documents the --model
#           launch_arg MECHANISM (a commented EXAMPLE naming openai-codex/
#           gpt-5.5 + the throttle rationale) but the pi-recipe TOOL entry
#           itself declares NO active launch_args field (no universal default).
#     T1i — manifest/default-tools.yaml's pi-recipe entry ALSO has no active
#           launch_args field (the shipped default never force-pins a model).
#
#   T2 (e2e, NEEDS_CONTAINER / RC_E2E=1): covered by the existing
#     tests/test-multiplexer-lifecycle.sh (l72i7) three-conjunction test,
#     which builds tests/fixtures/manifest-dcg-herdr-pi.yaml and asserts
#     herdr integration status pi:installed + the extensions dir fix
#     (rip-cage-fwp3) — run that suite under RC_E2E=1 for the real-cage leg.
#
# =============================================================================
# Positive-sentinel discipline: every failure increments FAILURES; script
# ends with [[ $FAILURES -eq 0 ]] || exit 1.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
PI_FRAGMENT="${REPO_ROOT}/examples/pi/manifest-fragment.yaml"
INIT_SCRIPT="${REPO_ROOT}/cage/init/init-rip-cage.sh"
DIST_MANIFEST="${REPO_ROOT}/manifest/default-tools.yaml"
E2E_FIXTURE="${REPO_ROOT}/tests/fixtures/manifest-dcg-herdr-pi.yaml"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Extract a single top-level "- name: <name>" tools[] entry's YAML block
# (from its "- name:" line up to but excluding the next "  - name:" line or
# EOF) out of a manifest file. Used to compare pi-recipe entries across
# examples/pi, dist, and the e2e fixture for byte-for-byte sync.
extract_entry() {
  local file="$1" name="$2"
  awk -v name="$name" '
    /^  - name: / {
      if (in_entry) exit
      if ($0 == "  - name: " name) { in_entry=1 }
    }
    in_entry { print }
  ' "$file"
}

# ---------------------------------------------------------------------------
# T1a — pi-recipe declares an init field (mkdir the extensions dir)
# ---------------------------------------------------------------------------
test_t1a_pi_recipe_declares_init_hook() {
  local entry
  entry=$(extract_entry "$PI_FRAGMENT" "pi-recipe")
  if [[ -z "$entry" ]]; then
    fail "T1a SENTINEL FAILED: could not extract pi-recipe entry from ${PI_FRAGMENT}"
    return
  fi
  if echo "$entry" | grep -q "^    init:" \
     && echo "$entry" | grep -q "extensions" \
     && echo "$entry" | grep -q "mkdir"; then
    pass "T1a pi-recipe TOOL entry declares an 'init' hook that mkdirs the extensions dir"
  else
    fail "T1a pi-recipe entry missing an 'init:' field mkdir-ing the extensions dir. entry:
${entry}"
  fi
}

# ---------------------------------------------------------------------------
# T1b — the init value passes _manifest_validate (hook-bounds clean)
# ---------------------------------------------------------------------------
test_t1b_init_value_passes_validation() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-pi-recipe-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cp "$PI_FRAGMENT" "${TEST_HOME}/.config/rip-cage/tools.yaml"

  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "T1b pi-recipe's init hook passes _manifest_validate (hook-bounds clean)"
  else
    fail "T1b pi-recipe manifest failed validation. exit=${exit_code} stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# ---------------------------------------------------------------------------
# T1c — the seam wires the REAL recipe (not just a synthetic fixture)
# ---------------------------------------------------------------------------
test_t1c_seam_wires_real_recipe() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-pi-recipe-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cp "$PI_FRAGMENT" "${TEST_HOME}/.config/rip-cage/tools.yaml"

  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_tool_init_config_dockerfile_steps" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "tool-init-config.json"; then
    pass "T1c TOOL init seam bakes tool-init-config.json from the REAL pi-recipe fragment"
  else
    fail "T1c expected a Dockerfile step baking tool-init-config.json from the real pi-recipe. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# ---------------------------------------------------------------------------
# T1d — init-rip-cage.sh no longer contains the fwp3 mkdir block
# ---------------------------------------------------------------------------
test_t1d_base_init_no_longer_has_fwp3_block() {
  if grep -q '_rc_pi_ext_dir=' "$INIT_SCRIPT"; then
    fail "T1d init-rip-cage.sh still contains the fwp3 mkdir block (_rc_pi_ext_dir= present) — should be relocated to pi-recipe's init hook"
  else
    pass "T1d init-rip-cage.sh no longer contains the fwp3 mkdir block (_rc_pi_ext_dir= absent — relocated)"
  fi
}

# ---------------------------------------------------------------------------
# T1e — remaining pi-specific lines in init-rip-cage.sh carry a BASE-INFRA tag
# ---------------------------------------------------------------------------
test_t1e_remaining_pi_lines_justified() {
  local tag_count
  tag_count=$(grep -c 'BASE-INFRA (pi' "$INIT_SCRIPT" || true)
  if [[ "$tag_count" -ge 3 ]]; then
    pass "T1e init-rip-cage.sh's remaining pi-specific blocks carry BASE-INFRA justification tags (found ${tag_count})"
  else
    fail "T1e expected >=3 'BASE-INFRA (pi' justification tags in init-rip-cage.sh, found ${tag_count}"
  fi
}

# ---------------------------------------------------------------------------
# T1f — manifest/default-tools.yaml pi-recipe entry byte-matches examples/pi
# ---------------------------------------------------------------------------
test_t1f_dist_pi_recipe_in_sync() {
  local examples_entry dist_entry
  examples_entry=$(extract_entry "$PI_FRAGMENT" "pi-recipe")
  dist_entry=$(extract_entry "$DIST_MANIFEST" "pi-recipe")

  if [[ -z "$examples_entry" ]]; then
    fail "T1f SENTINEL FAILED: could not extract pi-recipe entry from examples/pi/manifest-fragment.yaml"
    return
  fi
  if [[ -z "$dist_entry" ]]; then
    fail "T1f SENTINEL FAILED: could not extract pi-recipe entry from manifest/default-tools.yaml"
    return
  fi
  if [[ "$examples_entry" == "$dist_entry" ]]; then
    pass "T1f manifest/default-tools.yaml pi-recipe entry byte-matches examples/pi/manifest-fragment.yaml (regenerated)"
  else
    fail "T1f manifest/default-tools.yaml pi-recipe entry is STALE relative to examples/pi/manifest-fragment.yaml — regenerate dist (memory dist-default-manifest-must-be-regenerated-when-example-recipes-change)"
  fi
}

# ---------------------------------------------------------------------------
# T1g — l72i.7 e2e fixture pi-recipe entry byte-matches examples/pi
# ---------------------------------------------------------------------------
test_t1g_e2e_fixture_pi_recipe_in_sync() {
  local examples_entry fixture_entry
  examples_entry=$(extract_entry "$PI_FRAGMENT" "pi-recipe")
  fixture_entry=$(extract_entry "$E2E_FIXTURE" "pi-recipe")

  if [[ -z "$examples_entry" ]]; then
    fail "T1g SENTINEL FAILED: could not extract pi-recipe entry from examples/pi/manifest-fragment.yaml"
    return
  fi
  if [[ -z "$fixture_entry" ]]; then
    fail "T1g SENTINEL FAILED: could not extract pi-recipe entry from ${E2E_FIXTURE}"
    return
  fi
  if [[ "$examples_entry" == "$fixture_entry" ]]; then
    pass "T1g e2e fixture (manifest-dcg-herdr-pi.yaml) pi-recipe entry byte-matches examples/pi/manifest-fragment.yaml"
  else
    fail "T1g e2e fixture pi-recipe entry is STALE relative to examples/pi/manifest-fragment.yaml — the l72i.7 conjunction test would exercise a stale recipe"
  fi
}

# ---------------------------------------------------------------------------
# T1h — --model launch_arg MECHANISM documented as example, NOT active default
# ---------------------------------------------------------------------------
test_t1h_model_pin_mechanism_documented_not_defaulted() {
  local entry
  entry=$(extract_entry "$PI_FRAGMENT" "pi-recipe")
  if [[ -z "$entry" ]]; then
    fail "T1h SENTINEL FAILED: could not extract pi-recipe entry"
    return
  fi
  local has_active_launch_args=0
  echo "$entry" | grep -q "^    launch_args:" && has_active_launch_args=1

  local doc_mentions_model doc_mentions_example doc_mentions_rationale
  doc_mentions_model=$(grep -c -- '--model' "$PI_FRAGMENT" || true)
  doc_mentions_example=$(grep -c 'openai-codex/gpt-5.5' "$PI_FRAGMENT" || true)
  doc_mentions_rationale=$(grep -ciE '400|throttle' "$PI_FRAGMENT" || true)

  if [[ "$has_active_launch_args" -eq 0 ]] \
     && [[ "$doc_mentions_model" -ge 1 ]] \
     && [[ "$doc_mentions_example" -ge 1 ]] \
     && [[ "$doc_mentions_rationale" -ge 1 ]]; then
    pass "T1h --model launch_arg MECHANISM documented (openai-codex/gpt-5.5 example + throttle rationale), pi-recipe TOOL entry itself has NO active launch_args (no universal default)"
  else
    fail "T1h expected: no active launch_args on pi-recipe (got active=${has_active_launch_args}) AND documented --model example + rationale (mentions: model=${doc_mentions_model} example=${doc_mentions_example} rationale=${doc_mentions_rationale})"
  fi
}

# ---------------------------------------------------------------------------
# T1i — dist pi-recipe entry also has no active launch_args (shipped default
# never force-pins a model)
# ---------------------------------------------------------------------------
test_t1i_dist_pi_recipe_no_active_pin() {
  local entry
  entry=$(extract_entry "$DIST_MANIFEST" "pi-recipe")
  if [[ -z "$entry" ]]; then
    fail "T1i SENTINEL FAILED: could not extract pi-recipe entry from dist"
    return
  fi
  if echo "$entry" | grep -q "^    launch_args:"; then
    fail "T1i manifest/default-tools.yaml pi-recipe entry declares an active launch_args (would force a --model pin on every operator) — DESIGN CLARIFICATION forbids a universal default"
  else
    pass "T1i manifest/default-tools.yaml pi-recipe entry has no active launch_args (no universal --model default shipped)"
  fi
}

echo "=== test-pi-recipe-lifecycle.sh ==="
test_t1a_pi_recipe_declares_init_hook
test_t1b_init_value_passes_validation
test_t1c_seam_wires_real_recipe
test_t1d_base_init_no_longer_has_fwp3_block
test_t1e_remaining_pi_lines_justified
test_t1f_dist_pi_recipe_in_sync
test_t1g_e2e_fixture_pi_recipe_in_sync
test_t1h_model_pin_mechanism_documented_not_defaulted
test_t1i_dist_pi_recipe_no_active_pin

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
