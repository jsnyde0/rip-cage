#!/usr/bin/env bash
# Host-side unit tests for DCG host-adoptable policy (ADR-025 D1/D5, rip-cage-hhh.11.2).
#
# Coverage:
#   C1   Schema — dcg.packs and dcg.custom_rule_paths are additive_list in schema
#   C2   Safe-by-default — no dcg.* config adds NO mount (baked default untouched)
#   C3   Happy path — dcg.packs: [net] produces merged config with net in enabled list
#   C4   Additive — merged config always contains "core" (floor is uncrossable)
#   C5   custom_rule_paths — generates custom_paths in merged config pointing at /workspace path
#   C6   Fail-closed — malformed TOML → _up_validate_dcg_config exits non-zero (tomllib hosts)
#   C7   No mount on no-config — _UP_DCG_CONFIG_PATH unset/empty when no dcg.* configured
#   C8   Mount path set — _UP_DCG_CONFIG_PATH set to cache-file path when dcg.packs configured
#   C9   Traversal rejection — ../.. in custom_rule_paths escaping /workspace → skipped w/ warning
#   C10  Regression guard — mixed entry: bad traversal skipped, good glob kept
#   C11  Missing python3 graceful degrade — absent python3 binary → return 0 (not fail-closed)
#        (authoritative gate is init-rip-cage.sh:256-267 / ADR-025 D5, container-side)
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
# As of rip-cage-k2d5, rc guards its `set -euo pipefail` behind a sourced-vs-invoked
# check, so sourcing no longer forces `set -e` onto this shell. The `set +e` below is
# kept defensively (belt-and-suspenders) so bare non-zero commands in C6+ do not abort
# the suite even if that guard ever regresses (especially on Python 3.11+ hosts where
# tomllib is present and C6 actually runs the parse).
# shellcheck disable=SC1090
source "$RC" 2>/dev/null
set +e

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

# _make_no_python3_path: return a PATH string that includes essential tools
# but NOT python3. Creates a temp bindir (once; cached in _NO_PY3_BINDIR)
# with symlinks to needed tools from their real locations, deliberately
# omitting python3 — so `command -v python3` fails regardless of where the
# system installed python3.
# Pattern mirrors _make_no_yq_path in tests/test-config-loader.sh:
# - _NO_PY3_BINDIR is a top-level global (so cleanup sees it)
# - NO trap registered inside the function (trap in a $(...) subshell fires
#   on subshell exit, destroying the dir before the caller can use it)
# - Cleanup handled by the top-level _cleanup_no_py3 via trap ... EXIT below.
_NO_PY3_BINDIR=""
_make_no_python3_path() {
  if [[ -z "${_NO_PY3_BINDIR:-}" ]]; then
    _NO_PY3_BINDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dcg-no-py3-XXXXXX")
    local tool loc
    # Symlink all tools rc may call from within _up_validate_dcg_config (except python3).
    for tool in bash sh cat grep sed awk sort uniq cut tr wc head tail find \
                xargs mktemp realpath readlink rm mkdir cp mv chmod touch printf tee \
                date id uname pwd ls jq dirname basename stat file \
                docker git curl wget; do
      loc=$(command -v "$tool" 2>/dev/null) || continue
      ln -sf "$loc" "${_NO_PY3_BINDIR}/${tool}" 2>/dev/null || true
    done
    # Deliberately do NOT symlink python3 — that's the whole point.
  fi
  echo "$_NO_PY3_BINDIR"
}
_cleanup_no_py3() {
  [[ -n "${_NO_PY3_BINDIR:-}" && -d "${_NO_PY3_BINDIR:-}" ]] && rm -rf "$_NO_PY3_BINDIR"
}
trap _cleanup_no_py3 EXIT

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
# C9  Traversal rejection — ../.. in custom_rule_paths escaping /workspace
#     Entry must be SKIPPED (not appear in config) and a loud warning emitted.
# ---------------------------------------------------------------------------
echo ""
echo "=== C9: dcg.custom_rule_paths with ../.. traversal → skipped with loud warning ==="

setup_sandbox "" "config-project-dcg-traversal-paths.yaml"

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'" \
  2>/tmp/rc-dcg-c9-err > /tmp/rc-dcg-c9-out
_c9_exit=$?

_c9_ok=true _c9_reason=""
if [[ "$_c9_exit" -ne 0 ]]; then
  _c9_ok=false; _c9_reason="function exited non-zero ($_c9_exit) — traversal should warn-and-skip, not fail"
fi
# The escaping path must NOT appear in the generated config.
if [[ -f "${CACHE_DIR}/dcg-config.toml" ]]; then
  if grep -qF '../../etc/passwd' "${CACHE_DIR}/dcg-config.toml"; then
    _c9_ok=false; _c9_reason="${_c9_reason:+$_c9_reason; }escaping path leaked into dcg-config.toml"
  fi
  if grep -qF '/workspace/../../etc/passwd' "${CACHE_DIR}/dcg-config.toml"; then
    _c9_ok=false; _c9_reason="${_c9_reason:+$_c9_reason; }resolved escaping path leaked into dcg-config.toml"
  fi
fi
# A loud warning must appear on stderr naming the offending entry and the escape.
if ! grep -q 'escapes /workspace\|outside /workspace' /tmp/rc-dcg-c9-err 2>/dev/null; then
  _c9_ok=false; _c9_reason="${_c9_reason:+$_c9_reason; }no loud warning emitted on stderr (want message mentioning /workspace escape)"
fi
rm -f /tmp/rc-dcg-c9-out /tmp/rc-dcg-c9-err

if [[ "$_c9_ok" == "true" ]]; then
  pass 9 "custom_rule_paths ../.. traversal: skipped with loud warning, not leaked into config"
else
  fail 9 "custom_rule_paths traversal rejection" "$_c9_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C10 Regression guard — mixed entry: bad traversal skipped, good glob kept
#     The valid workspace-relative glob must still produce /workspace path;
#     the traversal entry must not appear. (C5 happy path + C9 in one fixture.)
# ---------------------------------------------------------------------------
echo ""
echo "=== C10: mixed custom_rule_paths (traversal + valid glob) → only valid glob in config ==="

setup_sandbox "" "config-project-dcg-mixed-paths.yaml"
mkdir -p "${TEST_WS}/.rip-cage/dcg-rules"
echo "# test rule" > "${TEST_WS}/.rip-cage/dcg-rules/test-rule.yaml"

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
  bash -c "source '${RC}' 2>/dev/null; _up_resolve_dcg_config '${TEST_WS}' '${CACHE_DIR}'" \
  2>/tmp/rc-dcg-c10-err > /tmp/rc-dcg-c10-out
_c10_exit=$?

_c10_ok=true _c10_reason=""
if [[ "$_c10_exit" -ne 0 ]]; then
  _c10_ok=false; _c10_reason="function exited non-zero ($_c10_exit)"
fi
if [[ ! -f "${CACHE_DIR}/dcg-config.toml" ]]; then
  _c10_ok=false; _c10_reason="${_c10_reason:+$_c10_reason; }dcg-config.toml not written"
else
  # Valid glob must appear.
  if ! grep -qF '/workspace/.rip-cage/dcg-rules/' "${CACHE_DIR}/dcg-config.toml"; then
    _c10_ok=false; _c10_reason="${_c10_reason:+$_c10_reason; }valid /workspace glob path not in generated config"
  fi
  # Traversal entry must NOT appear (in any form).
  if grep -qF 'etc/passwd' "${CACHE_DIR}/dcg-config.toml"; then
    _c10_ok=false; _c10_reason="${_c10_reason:+$_c10_reason; }traversal entry leaked into dcg-config.toml"
  fi
fi
# Loud warning must be emitted.
if ! grep -q 'escapes /workspace\|outside /workspace' /tmp/rc-dcg-c10-err 2>/dev/null; then
  _c10_ok=false; _c10_reason="${_c10_reason:+$_c10_reason; }no loud warning emitted for the traversal entry"
fi
rm -f /tmp/rc-dcg-c10-out /tmp/rc-dcg-c10-err

if [[ "$_c10_ok" == "true" ]]; then
  pass 10 "mixed paths: traversal skipped with warning, valid glob preserved"
else
  fail 10 "mixed custom_rule_paths: traversal skipped + valid glob kept" "$_c10_reason"
fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C11  Missing python3 graceful degrade — absent python3 binary → return 0
#
# When python3 is absent from PATH entirely, _up_validate_dcg_config must
# return 0 (graceful degrade — matching the existing missing-tomllib path at
# rc:3354). The authoritative fail-closed gate is init-rip-cage.sh:256-267
# (container-side, python3 + tomllib guaranteed in image — ADR-025 D5).
#
# Discrimination: C6 (malformed TOML + python3 present → fail-closed) is the
# paired positive control proving the function still CAN fail-closed, so C11's
# "returns 0" is not vacuous.
#
# rip-cage-lce7
# ---------------------------------------------------------------------------
echo ""
echo "=== C11: python3 absent from PATH → _up_validate_dcg_config returns 0 (graceful degrade) ==="

_c11_no_py3_path=$(_make_no_python3_path)

# Verify python3 truly absent from sanitized PATH (sanity check).
_c11_py3_check=$(PATH="$_c11_no_py3_path" command -v python3 2>/dev/null || true)
if [[ -n "$_c11_py3_check" ]]; then
  fail 11 "missing-python3 graceful degrade" "python3 still found in sanitized PATH: $_c11_py3_check — test is not discriminating"
else
  # Use the baked valid TOML config so the [[ -f ]] precondition (rc:3340) is satisfied.
  _c11_valid_cfg="${SCRIPT_DIR}/../cage/guards/dcg/default-config.toml"

  PATH="$_c11_no_py3_path" bash -c "
    source '${RC}' 2>/dev/null
    _up_validate_dcg_config '${_c11_valid_cfg}'
  " > /tmp/rc-dcg-c11-out 2>/tmp/rc-dcg-c11-err
  _c11_exit=$?

  _c11_ok=true _c11_reason=""
  if [[ "$_c11_exit" -ne 0 ]]; then
    _c11_ok=false
    _c11_reason="function returned $_c11_exit (want 0) — missing python3 incorrectly treated as malformed TOML"
  fi
  if grep -q "malformed TOML" /tmp/rc-dcg-c11-err 2>/dev/null; then
    _c11_ok=false
    _c11_reason="${_c11_reason:+$_c11_reason; }printed 'malformed TOML' error (should gracefully degrade when python3 absent)"
  fi
  rm -f /tmp/rc-dcg-c11-out /tmp/rc-dcg-c11-err

  if [[ "$_c11_ok" == "true" ]]; then
    pass 11 "python3 absent: _up_validate_dcg_config returns 0 (graceful degrade — container init is the hard stop)"
  else
    fail 11 "missing-python3 graceful degrade" "$_c11_reason"
  fi
fi

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
