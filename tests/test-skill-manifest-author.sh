#!/usr/bin/env bash
# Harness target for rip-cage-buuo.4: repo-shipped skill (rip-cage-tool-manifest-author).
#
# Validates the skill is well-formed, that the cm worked example in the skill
# references real files, and that those files pass _manifest_validate.
#
# All checks are host-only (no container needed).
#
# =============================================================================
# Test cases
# =============================================================================
#   SA1 — Skill file exists at the expected path.
#   SA2 — Skill has valid YAML frontmatter with required fields: name, description.
#   SA3 — Skill references the cm manifest fixture (manifest-cm-example.yaml).
#   SA4 — Skill references the cm build script fixture (build-cm-from-source.sh).
#   SA5 — The cm manifest fixture that the skill ships as worked example PASSES
#         _manifest_validate (the fail-closed validator).  This is the key load-bearing
#         check — the skill's worked-example output must clear the validator.
#   SA6 — The skill does NOT instruct any in-cage write or runtime injection
#         (D7 host-only framing preserved: "in-cage write" / "runtime injection" phrases
#         must appear as things NOT to do, not as instructions to do them).
#   SA7 — Skill references no invented manifest fields (cross-check: every field name
#         that appears in the skill's schema summary exists in the rc validator).
# =============================================================================
# Positive-sentinel discipline:
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

_SKILL_PATH="${REPO_ROOT}/.agents/skills/rip-cage-tool-manifest-author/SKILL.md"
_CM_MANIFEST="${REPO_ROOT}/tests/fixtures/manifest-cm-example.yaml"
_CM_BUILD_SCRIPT="${REPO_ROOT}/tests/fixtures/build-cm-from-source.sh"
_RC_PATH="${REPO_ROOT}/rc"

echo "=== test-skill-manifest-author.sh — rip-cage-tool-manifest-author skill (rip-cage-buuo.4) ==="
echo ""

# ---------------------------------------------------------------------------
# SA1 — Skill file exists.
# ---------------------------------------------------------------------------
if [[ -f "$_SKILL_PATH" ]]; then
  pass "SA1 skill file exists at .agents/skills/rip-cage-tool-manifest-author/SKILL.md"
else
  fail "SA1 skill file MISSING: ${_SKILL_PATH}"
fi

# ---------------------------------------------------------------------------
# SA2 — Skill frontmatter has 'name' and 'description' fields.
# The beads-skill convention requires these two fields in the YAML front matter.
# ---------------------------------------------------------------------------
_SA2_OK=1
if [[ -f "$_SKILL_PATH" ]]; then
  # Extract the YAML front matter block (between the first two --- lines).
  _frontmatter=$(awk '/^---$/{found++; next} found==1{print} found==2{exit}' "$_SKILL_PATH" 2>/dev/null)

  _has_name=0
  _has_description=0
  if echo "$_frontmatter" | grep -qE '^name:[[:space:]]'; then
    _has_name=1
  fi
  if echo "$_frontmatter" | grep -qE '^description:[[:space:]]'; then
    _has_description=1
  fi

  if [[ "$_has_name" -eq 1 ]] && [[ "$_has_description" -eq 1 ]]; then
    _fm_name=$(echo "$_frontmatter" | grep -E '^name:' | head -1 | sed 's/^name:[[:space:]]*//')
    pass "SA2 skill frontmatter has 'name' and 'description' fields (name='${_fm_name}')"
  else
    fail "SA2 skill frontmatter missing required field(s): has_name=${_has_name} has_description=${_has_description}"
    _SA2_OK=0
  fi
else
  fail "SA2 skill file missing — cannot check frontmatter (SA1 already failed)"
  _SA2_OK=0
fi

# ---------------------------------------------------------------------------
# SA3 — Skill body references the cm manifest fixture.
# ---------------------------------------------------------------------------
if [[ -f "$_SKILL_PATH" ]]; then
  if grep -qF "manifest-cm-example.yaml" "$_SKILL_PATH" 2>/dev/null; then
    pass "SA3 skill references cm manifest fixture (manifest-cm-example.yaml)"
  else
    fail "SA3 skill does NOT reference cm manifest fixture (manifest-cm-example.yaml expected)"
  fi
fi

# ---------------------------------------------------------------------------
# SA4 — Skill body references the cm build script fixture.
# ---------------------------------------------------------------------------
if [[ -f "$_SKILL_PATH" ]]; then
  if grep -qF "build-cm-from-source.sh" "$_SKILL_PATH" 2>/dev/null; then
    pass "SA4 skill references cm build script fixture (build-cm-from-source.sh)"
  else
    fail "SA4 skill does NOT reference cm build script fixture (build-cm-from-source.sh expected)"
  fi
fi

# ---------------------------------------------------------------------------
# SA5 — The cm manifest fixture passes _manifest_validate (fail-closed validator).
# This is the load-bearing automatable check per the bead's harness target.
# ---------------------------------------------------------------------------
_T_SOURCE_OK=0
# shellcheck source=../rc
if ! source "$_RC_PATH" 2>/dev/null; then
  fail "SA5 setup: failed to source rc from ${_RC_PATH}"
else
  _T_SOURCE_OK=1
fi

if [[ "$_T_SOURCE_OK" -eq 1 ]] && [[ -f "$_CM_MANIFEST" ]]; then
  _sa5_rc=0
  _sa5_out=$(_manifest_validate "$_CM_MANIFEST" 2>&1) || _sa5_rc=$?
  if [[ "$_sa5_rc" -eq 0 ]]; then
    pass "SA5 cm manifest example (skill's worked example) passes _manifest_validate — fail-closed validator GREEN"
  else
    fail "SA5 cm manifest example FAILS _manifest_validate: ${_sa5_out}"
  fi
elif [[ "$_T_SOURCE_OK" -eq 1 ]]; then
  fail "SA5 cm manifest example missing (${_CM_MANIFEST}) — cannot validate"
fi

# ---------------------------------------------------------------------------
# SA6 — D7 framing: the skill must NOT instruct in-cage writes or runtime
# injection. Check that the relevant phrases appear as prohibitions.
# We check for "NOT" in the vicinity of "in-cage write" or "runtime injection".
# ---------------------------------------------------------------------------
if [[ -f "$_SKILL_PATH" ]]; then
  _sa6_ok=1

  # The skill must contain the "What NOT to do" section with these prohibitions.
  if ! grep -qiE "NOT.*in-cage write|in-cage write.*NOT|Do NOT write any file inside a running cage" "$_SKILL_PATH" 2>/dev/null; then
    fail "SA6 skill missing explicit prohibition of in-cage writes (D7 framing)"
    _sa6_ok=0
  fi
  if ! grep -qiE "NOT.*runtime injection|runtime injection.*NOT|Do NOT.*runtime injection" "$_SKILL_PATH" 2>/dev/null; then
    fail "SA6 skill missing explicit prohibition of runtime injection (D7 framing)"
    _sa6_ok=0
  fi
  if ! grep -qiE "HOST.*ONLY|HOST-SIDE|host.only invariant" "$_SKILL_PATH" 2>/dev/null; then
    fail "SA6 skill missing host-only invariant statement (D7 framing)"
    _sa6_ok=0
  fi

  if [[ "$_sa6_ok" -eq 1 ]]; then
    pass "SA6 skill has explicit host-only / D7 framing (in-cage writes and runtime injection prohibited)"
  fi
fi

# ---------------------------------------------------------------------------
# SA7 — No invented manifest fields. Cross-check every field name that appears
# in the skill's schema summary against the known valid field set from the rc
# validator. The known valid field names are extracted from the validator's
# error messages and the schema documentation above.
#
# Valid TOOL fields: name, archetype, version_pin, egress, mounts, install_cmd,
#   build_source, build_source.builder_image, build_source.build_script,
#   build_source.output_path
# Valid SHELL-INTEGRATION fields: name, archetype, version_pin, shell_init
# Valid IN-CAGE-DAEMON fields: name, archetype, version_pin, start, health,
#   state_dir, mcp_fragment
# Top-level fields: version, tools
#
# Strategy: check that the schema summary section of the skill does not contain
# any field name that is NOT in the known-valid set. We look for "field_name: "
# patterns in the schema summary block.
# ---------------------------------------------------------------------------
if [[ -f "$_SKILL_PATH" ]]; then
  # Known-valid field names (lowercase, without prefix or value).
  _VALID_FIELDS="version tools name archetype version_pin egress mounts install_cmd build_source builder_image build_script output_path shell_init start health state_dir mcp_fragment host dest"

  # Extract the schema summary block (between "## Schema summary" and the next "## " heading
  # or end of file). Look for "key: ..." patterns.
  _schema_block=$(awk '/^## Schema summary/,/^## [A-Z]/' "$_SKILL_PATH" 2>/dev/null | grep -E '^\s+[a-z_]+:' || true)

  _sa7_ok=1
  while IFS= read -r _field_line; do
    [[ -z "$_field_line" ]] && continue
    # Extract the field name (strip leading whitespace and trailing colon/value).
    _field_name=$(echo "$_field_line" | sed 's/^[[:space:]]*//' | cut -d: -f1 | cut -d. -f1 | tr -d ' ')
    # Skip empty, comment-like, or fully-uppercase lines.
    [[ -z "$_field_name" ]] && continue
    [[ "$_field_name" =~ ^[A-Z_-]+$ ]] && continue

    _found=0
    for _vf in $_VALID_FIELDS; do
      if [[ "$_field_name" == "$_vf" ]]; then
        _found=1
        break
      fi
    done
    if [[ "$_found" -eq 0 ]]; then
      fail "SA7 skill schema summary contains unrecognized field name: '${_field_name}' — may be an invented field not in the rc validator schema"
      _sa7_ok=0
    fi
  done <<< "$_schema_block"

  if [[ "$_sa7_ok" -eq 1 ]]; then
    pass "SA7 skill schema summary contains no invented field names — all fields match the rc validator schema"
  fi
fi

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
