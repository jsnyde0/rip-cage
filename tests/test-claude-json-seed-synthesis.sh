#!/usr/bin/env bash
# test-claude-json-seed-synthesis.sh — NEEDS_CONTAINER host-tier test
#
# Verifies init-rip-cage.sh's R4 seed-synthesis extension (rip-cage-vwka):
# when the live ~/.claude.json mount is ABSENT (non-possession posture,
# auth.per_tool.claude: none) and no ~/.claude/.claude.json.seed exists yet,
# init writes a minimal synthesized seed carrying hasCompletedOnboarding:true
# — so interactive claude skips the theme+login onboarding screens instead of
# hitting an unusable-in-cage browser OAuth login wall (proven manually
# 2026-07-06). The possession-case snapshot (rip-cage-p1p, R4) must stay
# byte-identical, and synthesis must never clobber an existing seed.
#
# Coverage:
#   V1  — seed synthesized when the live mount is absent (non-possession)
#   V1b — synthesized seed carries no oauthAccount / credential-shaped fields
#   V2  — synthesis never clobbers an existing seed: a sentinel written into
#         the seed survives a second init run (real docker-stop + rc-up resume,
#         same call site as the possession-case rip-cage-p1p ordering)
#   V3  — positive control: possession path still snapshots byte-identical to
#         the live ~/.claude.json mount (R4 ordering untouched)
#   V4  — claude-wrapper 'no seed snapshot' WARNING does not fire once a seed
#         is present. Copies the UNMODIFIED canonical wrapper
#         (examples/claude/claude-session-wrapper.sh) into the cage and stubs
#         only REAL_CLAUDE (so exec doesn't spend a real model call) — the
#         wrapper source itself is never edited, only a container-local copy.
#   V5  — genuinely-broken case: the WARNING still fires when no seed exists
#         at all (keeps the wrapper's fail-loud fallback alive per the bead's
#         explicit constraint — this is NOT a regression to fix away)
#
# CRITICAL: run-host.sh exports RC_CONFIG_GLOBAL pointing to a benign fixture
# for the whole suite. Standalone runs must not inherit a dev machine's real
# global config (e.g. a promoted network.egress.mediator that requires
# egress=on — see rip-cage-u2ro). unset here and sandbox HOME/XDG_CONFIG_HOME
# per cage, matching the test-auto-seed.sh pattern.
unset RC_CONFIG_GLOBAL

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
WRAPPER_SRC="${REPO_ROOT}/examples/claude/claude-session-wrapper.sh"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not built — run ./rc build first"
  exit 0
fi

echo "=== test-claude-json-seed-synthesis.sh ==="

NP_HOME=""; NP_WS_ROOT=""; NP_NAME=""
PC_HOME=""; PC_WS_ROOT=""; PC_NAME=""

cleanup() {
  if [[ -n "$NP_NAME" ]]; then
    docker rm -f "$NP_NAME" >/dev/null 2>&1 || true
    docker volume rm "rc-state-${NP_NAME}" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PC_NAME" ]]; then
    docker rm -f "$PC_NAME" >/dev/null 2>&1 || true
    docker volume rm "rc-state-${PC_NAME}" >/dev/null 2>&1 || true
  fi
  [[ -n "$NP_HOME" && -d "$NP_HOME" ]] && rm -rf "$NP_HOME"
  [[ -n "$NP_WS_ROOT" && -d "$NP_WS_ROOT" ]] && rm -rf "$NP_WS_ROOT"
  [[ -n "$PC_HOME" && -d "$PC_HOME" ]] && rm -rf "$PC_HOME"
  [[ -n "$PC_WS_ROOT" && -d "$PC_WS_ROOT" ]] && rm -rf "$PC_WS_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Setup: non-possession cage (no live ~/.claude.json mount, no credentials
# file — the same non-possession shape as rip-cage-df1c's case 6: a
# CLAUDE_CODE_OAUTH_TOKEN placeholder carried via --env-file).
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup: non-possession cage (no live ~/.claude.json mount) ==="
NP_WS_ROOT=$(mktemp -d)
NP_HOME=$(mktemp -d)
NP_WS="${NP_WS_ROOT}/np-cage"
mkdir -p "$NP_WS"
git -C "$NP_WS" init -q
NP_ENVFILE="${NP_WS_ROOT}/np.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=placeholder-token-vwka\n' > "$NP_ENVFILE"
chmod 600 "$NP_ENVFILE"
NP_UP_OUT="${NP_WS_ROOT}/np-up.out"
HOME="$NP_HOME" \
  RC_SKIP_KEYCHAIN_EXTRACTION=1 \
  ANTHROPIC_API_KEY="" \
  RC_ALLOWED_ROOTS="$(realpath "$NP_WS_ROOT")" \
  RIP_CAGE_EGRESS=off \
  "$RC" up "$NP_WS" --env-file "$NP_ENVFILE" </dev/null >"$NP_UP_OUT" 2>&1 || true
NP_NAME=$(docker ps -a --filter "label=rc.source.path=$(realpath "$NP_WS")" \
  --format '{{.Names}}' 2>/dev/null | head -1)

NP_LIVE=false
if [[ -z "$NP_NAME" ]]; then
  fail "non-possession cage did not start (see $NP_UP_OUT)"
else
  NP_LOG=$(cat "$NP_UP_OUT" 2>/dev/null || true)
  # Gate on the init sentinel so an absence assertion below can't pass
  # vacuously against an empty capture (rip-cage-igm discipline).
  if printf '%s\n' "$NP_LOG" | grep -q '\[rip-cage\] pi '; then
    NP_LIVE=true
    pass "non-possession cage booted (init sentinel present)"
  else
    fail "non-possession cage init sentinel absent — init output not captured" "(see $NP_UP_OUT)"
  fi
fi

# ---------------------------------------------------------------------------
# V1 / V1b
# ---------------------------------------------------------------------------
if [[ "$NP_LIVE" == "true" ]]; then
  echo ""
  echo "=== V1: seed synthesized when mount absent ==="
  NP_SEED=$(docker exec "$NP_NAME" cat /home/agent/.claude/.claude.json.seed 2>/dev/null || true)
  if [[ -z "$NP_SEED" ]]; then
    fail "V1: /home/agent/.claude/.claude.json.seed missing or empty in non-possession cage"
  else
    pass "V1: /home/agent/.claude/.claude.json.seed present and non-empty"
    if echo "$NP_SEED" | jq -e '.hasCompletedOnboarding == true' >/dev/null 2>&1; then
      pass "V1: synthesized seed has hasCompletedOnboarding:true"
    else
      fail "V1: synthesized seed missing hasCompletedOnboarding:true" "content: $NP_SEED"
    fi

    echo ""
    echo "=== V1b: synthesized seed carries no credential-shaped fields ==="
    if echo "$NP_SEED" | jq -e 'has("oauthAccount")' >/dev/null 2>&1; then
      fail "V1b: synthesized seed unexpectedly has oauthAccount" "content: $NP_SEED"
    else
      pass "V1b: synthesized seed has no oauthAccount key"
    fi
    if echo "$NP_SEED" | jq -e 'has("claudeAiOauth")' >/dev/null 2>&1; then
      fail "V1b: synthesized seed unexpectedly has claudeAiOauth" "content: $NP_SEED"
    else
      pass "V1b: synthesized seed has no claudeAiOauth key"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# V2: synthesis never clobbers an existing seed. Overwrite the seed with a
# sentinel, then drive a REAL resume (docker stop + rc up) — the same call
# site (_up_init_container) that runs on the possession-case ordering — and
# confirm the sentinel survives untouched.
# ---------------------------------------------------------------------------
if [[ "$NP_LIVE" == "true" ]]; then
  echo ""
  echo "=== V2: synthesis never clobbers an existing seed ==="
  V2_SENTINEL='{"sentinel-vwka":"do-not-clobber","hasCompletedOnboarding":true}'
  docker exec "$NP_NAME" sh -c "printf '%s' '${V2_SENTINEL}' > /home/agent/.claude/.claude.json.seed"
  docker stop "$NP_NAME" >/dev/null 2>&1
  NP_RESUME_OUT="${NP_WS_ROOT}/np-resume.out"
  HOME="$NP_HOME" \
    RC_SKIP_KEYCHAIN_EXTRACTION=1 \
    ANTHROPIC_API_KEY="" \
    RC_ALLOWED_ROOTS="$(realpath "$NP_WS_ROOT")" \
    RIP_CAGE_EGRESS=off \
    "$RC" up "$NP_WS" </dev/null >"$NP_RESUME_OUT" 2>&1 || true
  NP_RESUME_LOG=$(cat "$NP_RESUME_OUT" 2>/dev/null || true)
  if ! printf '%s\n' "$NP_RESUME_LOG" | grep -q '\[rip-cage\] pi '; then
    fail "V2: resume init sentinel absent — cannot trust post-resume seed state" "(see $NP_RESUME_OUT)"
  else
    NP_SEED_AFTER=$(docker exec "$NP_NAME" cat /home/agent/.claude/.claude.json.seed 2>/dev/null || true)
    if [[ "$NP_SEED_AFTER" == "$V2_SENTINEL" ]]; then
      pass "V2: pre-existing seed sentinel survived a second init run (resume) unchanged"
    else
      fail "V2: pre-existing seed was overwritten by a second init run" "before=$V2_SENTINEL after=$NP_SEED_AFTER"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# V4 / V5: claude-wrapper WARNING behavior. Reuses the non-possession cage
# (a seed is present after V1/V2). Copies the real, unmodified canonical
# wrapper into the container and stubs only REAL_CLAUDE so exec is harmless.
# ---------------------------------------------------------------------------
if [[ "$NP_LIVE" == "true" ]]; then
  echo ""
  echo "=== V4: claude-wrapper WARNING does not fire when a seed is present ==="
  if docker cp "$WRAPPER_SRC" "${NP_NAME}:/tmp/wrapper-under-test.sh" >/dev/null 2>&1; then
    # docker cp always writes as root regardless of the container's default
    # user; /tmp's sticky bit then blocks the agent user's sed -i rename.
    # chown to agent first so the rest of this block runs as a normal
    # non-root exec, matching every other docker exec in this file.
    docker exec -u root "$NP_NAME" chown agent:agent /tmp/wrapper-under-test.sh
    docker exec "$NP_NAME" sed -i 's#^REAL_CLAUDE=/usr/bin/claude#REAL_CLAUDE=/bin/true#' /tmp/wrapper-under-test.sh
    docker exec "$NP_NAME" chmod +x /tmp/wrapper-under-test.sh
    docker exec "$NP_NAME" rm -rf /home/agent/.claude-sessions/vwka-v4-test
    V4_OUT=$(docker exec -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/vwka-v4-test "$NP_NAME" /tmp/wrapper-under-test.sh --version 2>&1)
    V4_EXIT=$?
    if [[ $V4_EXIT -ne 0 ]]; then
      fail "V4: patched wrapper invocation failed (exit $V4_EXIT)" "$V4_OUT"
    elif echo "$V4_OUT" | grep -q 'no ~/.claude/.claude.json.seed snapshot found'; then
      fail "V4: WARNING fired despite a seed being present" "$V4_OUT"
    else
      pass "V4: no 'no seed snapshot' WARNING when a seed is present"
    fi

    echo ""
    echo "=== V5: genuinely-broken case — WARNING still fires when no seed exists ==="
    docker exec "$NP_NAME" sh -c "mv /home/agent/.claude/.claude.json.seed /tmp/seed-moved-aside-vwka.json"
    docker exec "$NP_NAME" rm -rf /home/agent/.claude-sessions/vwka-v5-test
    V5_OUT=$(docker exec -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/vwka-v5-test "$NP_NAME" /tmp/wrapper-under-test.sh --version 2>&1)
    V5_EXIT=$?
    if [[ $V5_EXIT -ne 0 ]]; then
      fail "V5: patched wrapper invocation failed (exit $V5_EXIT)" "$V5_OUT"
    elif echo "$V5_OUT" | grep -q 'no ~/.claude/.claude.json.seed snapshot found'; then
      pass "V5: WARNING still fires when no seed exists (genuinely-broken case preserved)"
    else
      fail "V5: WARNING did not fire despite no seed existing" "$V5_OUT"
    fi
  else
    fail "V4/V5: docker cp of the canonical wrapper into the cage failed"
  fi
fi

# ---------------------------------------------------------------------------
# Setup: possession-posture cage (live ~/.claude.json fixture mounted) —
# positive control for V3.
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup: possession-posture cage (live ~/.claude.json mounted) ==="
PC_WS_ROOT=$(mktemp -d)
PC_HOME=$(mktemp -d)
PC_WS="${PC_WS_ROOT}/pc-cage"
mkdir -p "$PC_WS"
git -C "$PC_WS" init -q
PC_SENTINEL='{"possession-sentinel-vwka":"abc123","hasCompletedOnboarding":true}'
printf '%s' "$PC_SENTINEL" > "${PC_HOME}/.claude.json"
PC_UP_OUT="${PC_WS_ROOT}/pc-up.out"
HOME="$PC_HOME" \
  RC_SKIP_KEYCHAIN_EXTRACTION=1 \
  ANTHROPIC_API_KEY=sk-test-vwka-pc \
  RC_ALLOWED_ROOTS="$(realpath "$PC_WS_ROOT")" \
  RIP_CAGE_EGRESS=off \
  "$RC" up "$PC_WS" </dev/null >"$PC_UP_OUT" 2>&1 || true
PC_NAME=$(docker ps -a --filter "label=rc.source.path=$(realpath "$PC_WS")" \
  --format '{{.Names}}' 2>/dev/null | head -1)

PC_LIVE=false
if [[ -z "$PC_NAME" ]]; then
  fail "possession-control cage did not start (see $PC_UP_OUT)"
else
  PC_LOG=$(cat "$PC_UP_OUT" 2>/dev/null || true)
  if printf '%s\n' "$PC_LOG" | grep -q '\[rip-cage\] pi '; then
    PC_LIVE=true
    pass "possession-control cage booted (init sentinel present)"
  else
    fail "possession-control cage init sentinel absent" "(see $PC_UP_OUT)"
  fi
fi

# ---------------------------------------------------------------------------
# V3: positive control — possession path still snapshots (R4 / rip-cage-p1p
# ordering untouched).
# ---------------------------------------------------------------------------
if [[ "$PC_LIVE" == "true" ]]; then
  echo ""
  echo "=== V3: positive control — possession path still snapshots ==="
  PC_SEED=$(docker exec "$PC_NAME" cat /home/agent/.claude/.claude.json.seed 2>/dev/null || true)
  if [[ "$PC_SEED" == "$PC_SENTINEL" ]]; then
    pass "V3: possession-posture seed is byte-identical to the live ~/.claude.json mount"
  else
    fail "V3: possession-posture seed does not match the live mount" "expected=$PC_SENTINEL got=$PC_SEED"
  fi
fi

echo ""
echo "=== Summary: $FAILURES failure(s) ==="
exit $FAILURES
