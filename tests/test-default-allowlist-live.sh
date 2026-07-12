#!/usr/bin/env bash
# tests/test-default-allowlist-live.sh -- LIVE effect-based proof for the
# curated default egress allowlist (rip-cage-o2h0, S7 of the msb migration
# epic rip-cage-tsf2, ADR-029 D4).
#
# This is the bead's harness target made literal: "Real agent turn on
# defaults-only cage with no denials; out-of-default host yields no data."
# Drives the REAL config->flags chain end to end -- a fresh HOME (nothing
# pre-seeded), a real `rc up --dry-run` to trigger the EXISTING, unchanged
# _config_ensure_global_seeded auto-seed path (cli/up.sh, S7 touches only
# cli/lib/config.sh's _config_default_global_yaml content), then the REAL
# S6 translator _up_build_egress_config_json and the REAL S2 generator
# _msb_flags_generate -- never a hand-rolled host list. If S7's seeded
# content or S2/S6's wiring regresses, this test exercises the actual
# shipped path and fails against it directly.
#
# Per the msb fake-accept confound (bd memory
# msb-netstack-fake-accepts-tcp-connect-not-egress): the ALLOW claim rests
# on a REAL Claude Code completion -- generative content only Anthropic's
# API can produce, the strongest available anti-fake-accept confound
# (mirrors rip-cage-cmqb / rip-cage-1ujn) -- never connect()-success. The
# DENY claim rests on zero bytes returned by curl to a host outside the
# curated defaults, on the SAME booted cage (positive+negative control,
# rules out a dead-network false positive).
#
# SAFETY (mirrors rip-cage-1ujn / rip-cage-xuy8): NEVER mounts or writes the
# real ~/.claude. Builds a disposable scratch claude home (mktemp -d),
# copies (never prints) the real .credentials.json + minimal non-token
# claude.json fields. Real ~/.claude is verified untouched (mtime
# unchanged) at the end.
#
# Coverage (mirrors the bead's acceptance criteria):
#   AC1  a cage booted from ONLY the real auto-seeded defaults (no manual
#        host additions) completes a real basic `claude -p` turn end to
#        end -- real generative output, not connect-success
#   AC1b zero denial-driven repair-loop trips for the shipped defaults:
#        trace-level DNS-denial log lines never name any of the 3 curated
#        hosts after the real turn
#   AC2  a host OUTSIDE the defaults yields ZERO bytes on the SAME cage --
#        confirms the defaults are a tight allowlist, not allow-all
#
# NEEDS_MSB + a real, authenticated host Claude Code session
# (~/.claude/.credentials.json). Self-skips (exit 0, SKIP: ...) when any
# prerequisite is missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
RUN_ID="$$"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json >/dev/null 2>&1; then
  echo "SKIP: msb not responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "\"reference\": \"${IMAGE}\""; then
  echo "SKIP: ${IMAGE} not loaded into msb -- skipping $(basename "$0") (run: rc build, then msb load)"
  exit 0
fi
if [[ ! -s "${HOME}/.claude/.credentials.json" ]]; then
  echo "SKIP: no host ~/.claude/.credentials.json (host claude not authed) -- skipping $(basename "$0")"
  exit 0
fi

REAL_CLAUDE_MTIME_BEFORE=$(stat -f "%m" "${HOME}/.claude/.credentials.json" 2>/dev/null || stat -c "%Y" "${HOME}/.claude/.credentials.json" 2>/dev/null)

CAGE="o2h0-default-allowlist-${RUN_ID}"
TEST_HOME=""
SCRATCH=""

cleanup() {
  msb remove -f "$CAGE" >/dev/null 2>&1 || true
  [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
  [[ -n "${SCRATCH:-}" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH"
  rm -f /tmp/o2h0-*.err
}
trap cleanup EXIT

# ===========================================================================
# Setup: fresh HOME, real auto-seed, real translator + generator chain --
# no hand-rolled host list anywhere below this point.
# ===========================================================================
echo ""
echo "=== Setup: real auto-seed -> real _up_build_egress_config_json -> real _msb_flags_generate ==="
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-o2h0-live-XXXXXX")
mkdir -p "${TEST_HOME}/.config/rip-cage"
TEST_WS="${TEST_HOME}/workspace"
mkdir -p "$TEST_WS"

HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$TEST_WS" \
  bash "$RC" up --dry-run "$TEST_WS" >/dev/null 2>&1 || true

SEEDED_CFG="${TEST_HOME}/.config/rip-cage/config.yaml"
if [[ -f "$SEEDED_CFG" ]] && grep -q "api.anthropic.com" "$SEEDED_CFG"; then
  pass "Setup: fresh rc up auto-seeded the curated default allowlist to disk"
else
  fail "Setup: auto-seed did not produce the curated allowlist" "$(cat "$SEEDED_CFG" 2>&1)"
fi

EGRESS_JSON=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _up_build_egress_config_json '${TEST_WS}'")
mapfile -t FLAGS < <(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "source '${RC}' 2>/dev/null; _msb_flags_generate '${EGRESS_JSON}'")
if [[ "${#FLAGS[@]}" -gt 0 ]] && printf '%s\n' "${FLAGS[@]}" | grep -qF "allow@api.anthropic.com"; then
  pass "Setup: real generator produced --net-rule allow@api.anthropic.com from the real auto-seeded defaults"
else
  fail "Setup: generator did not produce the expected default net-rules" "egress_json=${EGRESS_JSON} flags=${FLAGS[*]:-<empty>}"
fi

# Scratch claude home -- NEVER touches real ~/.claude beyond a read-only copy.
SCRATCH=$(mktemp -d)
mkdir -p "${SCRATCH}/claude-dir"
cp "${HOME}/.claude/.credentials.json" "${SCRATCH}/claude-dir/.credentials.json"
chmod 600 "${SCRATCH}/claude-dir/.credentials.json"
if [[ -f "${HOME}/.claude.json" ]]; then
  jq -c '{hasCompletedOnboarding, oauthAccount}' "${HOME}/.claude.json" > "${SCRATCH}/claude.json"
else
  echo '{}' > "${SCRATCH}/claude.json"
fi

if msb run -d --name "$CAGE" --replace --timeout 90s --log-level trace "${FLAGS[@]}" \
  -v "${SCRATCH}/claude-dir:/home/agent/.claude" \
  --mount-file "${SCRATCH}/claude.json:/home/agent/.claude.json" \
  -w /home/agent "$IMAGE" -- sleep 300 >/tmp/o2h0-boot.err 2>&1; then
  pass "Setup: cage boots from ONLY the real generator-emitted default flags"
else
  fail "Setup: cage failed to boot" "$(cat /tmp/o2h0-boot.err)"
fi

# ===========================================================================
# AC1: real basic claude -p turn completes end to end on the defaults-only
# cage -- real generative output (anti-fake-accept confound), not
# connect-success.
# ===========================================================================
echo ""
echo "=== AC1: real claude -p turn on a defaults-only cage ==="
SENTINEL="O2H0-DEFAULT-ALLOWLIST-OK-${RUN_ID}"
AC1_OUT=$(msb exec "$CAGE" -- sh -c "claude -p 'reply with exactly: ${SENTINEL}'" 2>/tmp/o2h0-ac1.err)
AC1_RC=$?
if [[ "$AC1_RC" -eq 0 && "$AC1_OUT" == *"$SENTINEL"* ]]; then
  pass "AC1: real claude -p turn succeeded end-to-end on defaults-only cage (real generative output: '${AC1_OUT}')"
else
  fail "AC1: expected the real claude completion to echo the sentinel" "rc=${AC1_RC} out='${AC1_OUT}' err=$(cat /tmp/o2h0-ac1.err)"
fi

# ===========================================================================
# AC1b: zero denial-driven repair-loop trips for the shipped defaults --
# trace-level DNS-denial log lines never name any of the 3 curated hosts.
# ===========================================================================
echo ""
echo "=== AC1b: zero denials logged against any of the 3 curated default hosts ==="
DENIED_DEFAULT_HOSTS=$(msb logs "$CAGE" --source system 2>/dev/null \
  | grep -o "denied by network policy domain=[^ ]*" \
  | grep -E "api\.anthropic\.com|mcp-proxy\.anthropic\.com|http-intake\.logs\.us5\.datadoghq\.com" || true)
if [[ -z "$DENIED_DEFAULT_HOSTS" ]]; then
  pass "AC1b: no denial-log lines name any of the 3 curated default hosts (zero denial-driven repair-loop trips)"
else
  fail "AC1b: a curated default host was denied" "$DENIED_DEFAULT_HOSTS"
fi

# ===========================================================================
# AC2: a host OUTSIDE the defaults yields ZERO bytes on the SAME cage --
# tight allowlist, not allow-all. (AC1's real completion above is this
# same cage's positive control -- rules out a dead-network false positive.)
# ===========================================================================
echo ""
echo "=== AC2: an out-of-default host yields zero bytes on the SAME cage ==="
AC2_OUT=$(msb exec "$CAGE" -- sh -c 'curl -s --max-time 8 http://icanhazip.com/' 2>/tmp/o2h0-ac2.err)
if [[ -z "$AC2_OUT" ]]; then
  pass "AC2: out-of-default host (icanhazip.com) returned ZERO bytes on the SAME cage that just completed a real claude turn (not connect-success)"
else
  fail "AC2: expected zero bytes from an out-of-default host" "got: '${AC2_OUT}'"
fi

msb remove -f "$CAGE" >/dev/null 2>&1 || true

# ===========================================================================
# Safety corroboration: real ~/.claude untouched.
# ===========================================================================
echo ""
REAL_CLAUDE_MTIME_AFTER=$(stat -f "%m" "${HOME}/.claude/.credentials.json" 2>/dev/null || stat -c "%Y" "${HOME}/.claude/.credentials.json" 2>/dev/null)
if [[ "$REAL_CLAUDE_MTIME_BEFORE" == "$REAL_CLAUDE_MTIME_AFTER" ]]; then
  pass "Safety: real ~/.claude/.credentials.json mtime unchanged (never touched)"
else
  fail "Safety: real ~/.claude/.credentials.json mtime CHANGED" "before=${REAL_CLAUDE_MTIME_BEFORE} after=${REAL_CLAUDE_MTIME_AFTER}"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-default-allowlist-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-default-allowlist-live.sh: all ${TOTAL} tests passed ==="
