#!/usr/bin/env bash
# Host-side unit tests for DCG host-adoptable policy (ADR-025 D1/D5, rip-cage-hhh.11.2).
#
# Coverage:
#   C1  Schema — dcg.packs and dcg.custom_rule_paths are additive_list in schema
#   C2  Safe-by-default — no dcg.* config adds NO mount (baked default untouched)
#   C3  Happy path — dcg.packs: [net] produces merged config with net in enabled list
#   C4  Additive — merged config always contains "core" (floor is uncrossable)
#   C5  custom_rule_paths — generates custom_paths in merged config pointing at /workspace path
#   C6  Fail-closed — malformed TOML → _up_validate_dcg_config exits non-zero (tomllib hosts)
#   C7  No mount on no-config — _UP_DCG_CONFIG_PATH unset/empty when no dcg.* configured
#   C8  Mount path set — _UP_DCG_CONFIG_PATH set to cache-file path when dcg.packs configured
#
# All tests run host-side without docker (source rc pattern per test-egress-rules-gen.sh).
# ADRs: ADR-025 D1/D5, ADR-021 D1/D2
#
# Note: -e intentionally omitted so individual test failures don't abort the suite.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS C$1: $2"; }
fail() { echo "FAIL C$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

# Source rc to get access to internal functions.
# shellcheck disable=SC1090
source "$RC" 2>/dev/null

# Build sandbox with optional config files. Sets TEST_HOME, TEST_WS, CACHE_DIR.
TEST_HOME=""
TEST_WS=""
CACHE_DIR=""

setup_sandbox() {
  local gf="${1:-}" pf="${2:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-dcg-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.ssh"
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
  if [[ -n "$gf" ]]; then
    cp "${SCRIPT_DIR}/fixtures/${gf}" "${TEST_HOME}/.config/rip-cage/config.yaml"
  fi
  if [[ -n "$pf" ]]; then
    cp "${SCRIPT_DIR}/fixtures/${pf}" "${TEST_WS}/.rip-cage.yaml"
  fi
  CACHE_DIR="${TEST_HOME}/.cache/rip-cage/test-container"
  mkdir -p "$CACHE_DIR"
}

teardown_sandbox() {
  if [[ -n "${TEST_HOME:-}" ]]; then
    rm -rf "$TEST_HOME"
  fi
  TEST_HOME="" TEST_WS="" CACHE_DIR=""
}

# ---------------------------------------------------------------------------
# C1  Schema — dcg.packs and dcg.custom_rule_paths are additive_list
# ---------------------------------------------------------------------------
echo ""
echo "=== C1: schema declares dcg.packs and dcg.custom_rule_paths as additive_list ==="

_c1_packs_type=$(_config_schema_field_type 'dcg.packs' 2>/dev/null || true)
_c1_paths_type=$(_config_schema_field_type 'dcg.custom_rule_paths' 2>/dev/null || true)

_c1_ok=true _c1_reason=""
if [[ "$_c1_packs_type" != "additive_list" ]]; then
  _c1_ok=false; _c1_reason="dcg.packs type='$_c1_packs_type' (want additive_list)"
fi
if [[ "$_c1_paths_type" != "additive_list" ]]; then
  _c1_ok=false; _c1_reason="${_c1_reason:+$_c1_reason; }dcg.custom_rule_paths type='$_c1_paths_type' (want additive_list)"
fi

if [[ "$_c1_ok" == "true" ]]; then
  pass 1 "dcg.packs and dcg.custom_rule_paths are additive_list in schema"
else
  fail 1 "schema field types" "$_c1_reason"
fi

# ---------------------------------------------------------------------------
# C2  Safe-by-default — no dcg.* → _UP_DCG_CONFIG_PATH empty, no mount
# ---------------------------------------------------------------------------
echo ""
echo "=== C2: no dcg.* config → no mount path set ==="

setup_sandbox "" ""

(
  # Subshell: isolate env/HOME changes
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  _UP_DCG_CONFIG_PATH="" \
  bash -c "
    source '${RC}' 2>/dev/null
    _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'
    echo DCG_PATH=\${_UP_DCG_CONFIG_PATH}
  " 2>/dev/null
) > /tmp/rc-dcg-c2-out 2>/tmp/rc-dcg-c2-err
_c2_exit=$?

_c2_ok=true _c2_reason=""
if [[ "$_c2_exit" -ne 0 ]]; then
  _c2_ok=false; _c2_reason="function exited non-zero ($_c2_exit) on no-config case"
fi
if grep -q "DCG_PATH=." /tmp/rc-dcg-c2-out 2>/dev/null; then
  _c2_ok=false; _c2_reason="${_c2_reason:+$_c2_reason; }DCG_PATH unexpectedly set: $(grep DCG_PATH /tmp/rc-dcg-c2-out)"
fi
if [[ -f "${CACHE_DIR}/dcg-config.toml" ]]; then
  _c2_ok=false; _c2_reason="${_c2_reason:+$_c2_reason; }dcg-config.toml written when it should not be"
fi
rm -f /tmp/rc-dcg-c2-out /tmp/rc-dcg-c2-err

if [[ "$_c2_ok" == "true" ]]; then
  pass 2 "no dcg.* config: _UP_DCG_CONFIG_PATH empty, no mount"
else
  fail 2 "safe-by-default: no mount on no-config" "$_c2_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C3  Happy path — dcg.packs: [net] produces merged config with net in enabled
# ---------------------------------------------------------------------------
echo ""
echo "=== C3: dcg.packs: [net] → merged config contains net pack ==="

setup_sandbox "" "config-project-dcg-packs-net.yaml"

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'" \
  2>/dev/null
_c3_exit=$?

_c3_ok=true _c3_reason=""
if [[ "$_c3_exit" -ne 0 ]]; then
  _c3_ok=false; _c3_reason="function exited non-zero ($_c3_exit)"
fi
if [[ ! -f "${CACHE_DIR}/dcg-config.toml" ]]; then
  _c3_ok=false; _c3_reason="${_c3_reason:+$_c3_reason; }dcg-config.toml not written to cache"
else
  if ! grep -qF 'net' "${CACHE_DIR}/dcg-config.toml"; then
    _c3_ok=false; _c3_reason="${_c3_reason:+$_c3_reason; }net pack not in generated config"
  fi
fi

if [[ "$_c3_ok" == "true" ]]; then
  pass 3 "dcg.packs: [net] produces merged config with net in enabled list"
else
  fail 3 "dcg.packs: [net] happy path" "$_c3_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C4  Floor preserved — merged config always contains "core" (additive only)
# ---------------------------------------------------------------------------
echo ""
echo "=== C4: floor preserved — merged config always contains core ==="

setup_sandbox "" "config-project-dcg-packs-net.yaml"

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'" \
  2>/dev/null
_c4_exit=$?

_c4_ok=true _c4_reason=""
if [[ "$_c4_exit" -ne 0 ]]; then
  _c4_ok=false; _c4_reason="function exited non-zero"
fi
if [[ ! -f "${CACHE_DIR}/dcg-config.toml" ]]; then
  _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }dcg-config.toml not written"
else
  if ! grep -qF '"core"' "${CACHE_DIR}/dcg-config.toml"; then
    _c4_ok=false; _c4_reason="${_c4_reason:+$_c4_reason; }core pack not in merged config (floor violation)"
  fi
fi

if [[ "$_c4_ok" == "true" ]]; then
  pass 4 "core pack always present in merged config (floor uncrossable)"
else
  fail 4 "floor preserved: core always in merged config" "$_c4_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C5  custom_rule_paths — cage-relative paths (/workspace/...) in config
# ---------------------------------------------------------------------------
echo ""
echo "=== C5: dcg.custom_rule_paths → /workspace paths in generated config ==="

setup_sandbox "" "config-project-dcg-custom-paths.yaml"
mkdir -p "${TEST_WS}/.rip-cage/dcg-rules"
echo "# test rule" > "${TEST_WS}/.rip-cage/dcg-rules/test-rule.yaml"

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'" \
  2>/dev/null
_c5_exit=$?

_c5_ok=true _c5_reason=""
if [[ "$_c5_exit" -ne 0 ]]; then
  _c5_ok=false; _c5_reason="function exited non-zero"
fi
if [[ ! -f "${CACHE_DIR}/dcg-config.toml" ]]; then
  _c5_ok=false; _c5_reason="${_c5_reason:+$_c5_reason; }dcg-config.toml not written"
else
  if ! grep -qF '/workspace/' "${CACHE_DIR}/dcg-config.toml"; then
    _c5_ok=false; _c5_reason="${_c5_reason:+$_c5_reason; }/workspace path not found in generated config"
  fi
fi

if [[ "$_c5_ok" == "true" ]]; then
  pass 5 "dcg.custom_rule_paths generates /workspace/* cage-relative paths"
else
  fail 5 "custom_rule_paths: cage-relative /workspace paths in config" "$_c5_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C6  Fail-closed — malformed TOML → _up_validate_dcg_config exits non-zero
# Conditional: only runs when Python 3.11+ or tomli is available (host may
# have Python 3.9; container-side init-rip-cage.sh is the hard stop there).
# ---------------------------------------------------------------------------
echo ""
echo "=== C6: validation step rejects malformed TOML (when tomllib/tomli available) ==="

_c6_has_tomllib=$(python3 -c "
try:
    import tomllib
    print('yes')
except ImportError:
    try:
        import tomli
        print('yes')
    except ImportError:
        print('no')
" 2>/dev/null || true)

if [[ "$_c6_has_tomllib" == "yes" ]]; then
  setup_sandbox "" "config-project-dcg-packs-net.yaml"
  mkdir -p "$CACHE_DIR"
  echo "this is [not valid toml" > "${CACHE_DIR}/dcg-config.toml"

  bash -c "source '${RC}' 2>/dev/null; _up_validate_dcg_config '${CACHE_DIR}/dcg-config.toml'" \
    2>/dev/null
  _c6_exit=$?

  if [[ "$_c6_exit" -ne 0 ]]; then
    pass 6 "malformed TOML → validation exits non-zero (fail-closed)"
  else
    fail 6 "fail-closed validation" "malformed TOML accepted without error (exit 0)"
  fi
  teardown_sandbox
else
  echo "SKIP C6: tomllib/tomli not available on this host (Python 3.9) — container-side init-rip-cage.sh is the hard stop"
fi

# ---------------------------------------------------------------------------
# C7  No mount on empty global config — _UP_DCG_CONFIG_PATH empty when no dcg.*
# ---------------------------------------------------------------------------
echo ""
echo "=== C7: empty dcg.* in global config → _UP_DCG_CONFIG_PATH empty ==="

setup_sandbox "config-global-basic.yaml" ""

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'; echo DCG_PATH=\${_UP_DCG_CONFIG_PATH}" \
  2>/dev/null > /tmp/rc-dcg-c7-out
_c7_exit=$?

_c7_ok=true _c7_reason=""
if [[ "$_c7_exit" -ne 0 ]]; then
  _c7_ok=false; _c7_reason="function exited non-zero ($_c7_exit)"
fi
if grep -q "DCG_PATH=." /tmp/rc-dcg-c7-out 2>/dev/null; then
  _c7_ok=false; _c7_reason="${_c7_reason:+$_c7_reason; }DCG_PATH unexpectedly set: $(grep DCG_PATH /tmp/rc-dcg-c7-out)"
fi
rm -f /tmp/rc-dcg-c7-out

if [[ "$_c7_ok" == "true" ]]; then
  pass 7 "global config with no dcg.* fields: _UP_DCG_CONFIG_PATH empty"
else
  fail 7 "no mount on no-dcg-fields global config" "$_c7_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C8  Mount path set — _UP_DCG_CONFIG_PATH set when dcg.packs configured
# ---------------------------------------------------------------------------
echo ""
echo "=== C8: dcg.packs configured → _UP_DCG_CONFIG_PATH points to cache file ==="

setup_sandbox "" "config-project-dcg-packs-net.yaml"

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'; echo DCG_PATH=\${_UP_DCG_CONFIG_PATH}" \
  2>/dev/null > /tmp/rc-dcg-c8-out
_c8_exit=$?

_c8_ok=true _c8_reason=""
if [[ "$_c8_exit" -ne 0 ]]; then
  _c8_ok=false; _c8_reason="function exited non-zero"
fi
_c8_path=$(grep "^DCG_PATH=" /tmp/rc-dcg-c8-out 2>/dev/null | cut -d= -f2- || true)
if [[ -z "$_c8_path" ]]; then
  _c8_ok=false; _c8_reason="${_c8_reason:+$_c8_reason; }_UP_DCG_CONFIG_PATH not set when dcg.packs configured"
elif [[ "$_c8_path" != *"dcg-config.toml"* ]]; then
  _c8_ok=false; _c8_reason="${_c8_reason:+$_c8_reason; }_UP_DCG_CONFIG_PATH='$_c8_path' does not point to dcg-config.toml"
fi
rm -f /tmp/rc-dcg-c8-out

if [[ "$_c8_ok" == "true" ]]; then
  pass 8 "dcg.packs configured: _UP_DCG_CONFIG_PATH set to cache file path"
else
  fail 8 "mount path set on dcg.packs config" "$_c8_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "---"
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All DCG policy tests passed."
  exit 0
else
  echo "$FAILURES DCG policy test(s) failed."
  exit 1
fi
