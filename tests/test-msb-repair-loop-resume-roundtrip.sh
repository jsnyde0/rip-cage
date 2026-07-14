#!/usr/bin/env bash
# tests/test-msb-repair-loop-resume-roundtrip.sh -- Fold-4a REQUIRED test
# (Fable ruling 2026-07-12, folded into bead rip-cage-tsf2.1's notes).
#
# The full repair round-trip INCLUDING a post-reload session RESUME was
# UNTESTED before this file: tests/test-msb-lifecycle-reload-repair-loop.sh
# (S6, rip-cage-rj68) proves DENY -> FIX (rc reload, cold-recreate) -> RETRY
# with real data, but stops there -- no resume leg.
# tests/test-msb-lifecycle-create-resume.sh proves create -> stop -> `rc up`
# RESUME with a real in-guest commit, but has no deny/reload/net-readback at
# all. Neither file chains BOTH halves. This file closes that gap: it
# chains DENY -> FIX (rc reload) -> RETRY -> STOP -> RESUME (`rc up`) ->
# RETRY AGAIN, proving the amended network policy the reload applied
# SURVIVES a real stop+resume cycle on the recreated cage, not just the
# immediate post-reload state.
#
# msb fake-accepts denied/unreachable TCP (connect() succeeds, zero bytes)
# -- every claim below rests on REAL bidirectional application data (a
# nonzero HTTP response body), never connect-success alone, plus a
# POSITIVE CONTROL (an always-allowed host) on the SAME booted cage at
# every stage, ruling out a dead-network false positive.
#
# Coverage:
#   DENY    initially-denied host (www.wikipedia.org) yields ZERO bytes
#   CTRL1   positive control (example.com, allowed) yields REAL data on the
#           SAME cage before any fix — rules out a dead network
#   FIX     `rc reload` (cold-recreate) applies the amended allowlist to a
#           REAL, re-inspectable sandbox
#   RETRY1  the SAME previously-denied host now returns REAL bidirectional
#           data immediately post-reload (mirrors the existing repair-loop
#           test's own claim, re-proven here as this test's own baseline
#           before the NEW leg below)
#   CTRL2   positive control still real post-reload
#   STOP    the RECREATED (post-reload) sandbox is genuinely stopped via
#           the graceful primitive (independent msb inspect)
#   RESUME  `rc up` resumes the stopped, post-reload sandbox for real
#           (action=resumed, independent msb inspect confirms Running)
#   RETRY2  *** the Fold-4a core claim *** — after stop+resume, the
#           previously-denied host STILL returns REAL bidirectional data
#           on the SAME resumed cage (the amended net-rule policy survived
#           the resume, not just the initial post-reload boot)
#   CTRL3   positive control still real post-resume — rules out resume
#           having silently broken egress entirely (which would make
#           RETRY2 a false negative pass via a dead network, not a real
#           policy-survival proof)
#
# SESSION-RESUME LEG (Fable merge-gate seam, folded into rip-cage-tsf2.1's
# notes 2026-07-13): cold-recreate reload destroys ephemeral guest state BY
# DESIGN (ADR-029 D4) -- the only thing that CAN resume is host-mounted
# state. Before this leg, coverage was split: this file's own network-policy
# claim above proves REGULAR host-mounted state (config-driven net rules)
# survives; tests/test-msb-lifecycle-reload-repair-loop.sh proves a
# host-mounted WORKSPACE FILE survives `rc reload` (with an overlay-only
# negative control); tests/test-msb-claude-home-resume.sh proves a real
# CLAUDE SESSION survives cold-recreate, but drives raw `msb run --replace`
# directly (S6's `rc reload` verb did not exist when it was written -- see
# its own header). No single test proved a host-mounted claude/agent
# SESSION survives the REAL `rc reload` verb. This leg closes that gap on
# the SAME cage, chained into the SAME deny->fix->reload->stop->resume->retry
# round-trip above -- proving session continuity across BOTH transitions,
# not just one:
#   SESSION-PLANT      before the reload: plant a REAL Claude session (via
#                       cli/up.sh's OWN unconditional ${HOME}/.claude/projects
#                       + .../sessions mount -- the SAME production mount
#                       `rc up` always wires, no test-only mount added) with a
#                       unique codeword; assert the host-side transcript
#                       contains it immediately after planting
#   OVERLAY-SET         (honest negative control, mirrors
#                       test-msb-lifecycle-reload-repair-loop.sh) a marker
#                       written to the guest's OWN ephemeral overlay, planted
#                       alongside the session, to prove the recreate that
#                       follows is genuinely cold, not a no-op
#   SESSION-SURVIVAL-1  immediately post-reload: the codeword is (a) still
#                       present host-side in the mounted session dir, (b)
#                       visible via a REAL in-guest re-mount (`msb exec ...
#                       grep`, not a host-only check), and (c) functionally
#                       resumable (`claude --resume` in the recreated cage
#                       recalls it)
#   OVERLAY-GONE        (honest negative, continued) the guest-overlay-only
#                       marker is GONE post-reload -- proves cold-recreate
#                       really discarded ephemeral guest state even while
#                       the claude session (host-mounted) survived
#   SESSION-SURVIVAL-2  *** the session-leg's own Fold-4a-style core claim
#                       *** -- after the SAME stop+resume cycle RETRY2
#                       proves for network policy, the codeword is STILL
#                       (a)/(b)/(c)-provable on the resumed, post-reload cage
#                       -- session continuity survives a real stop+resume,
#                       not just the initial post-reload boot
#
# Self-skips ONLY the session-leg assertions above (network-policy coverage
# still runs) when host ~/.claude/.credentials.json is absent/empty, jq is
# unavailable, or the pre-built image was not composed with the claude-recipe
# (/usr/local/bin/claude wrapper absent) -- never fakes a PASS. Cleanup
# removes ONLY the specific transcript file(s) tagged with this run's unique
# codeword from the real, shared ${HOME}/.claude/projects `rc up` mounts
# (never `rm -rf` a whole project directory -- see the cleanup() comment).
#
# NEEDS_CONTAINER (docker, rc up's image-provisioning preflight) + NEEDS_MSB
# + a pre-built rip-cage:latest image already `msb load`-ed + a live network
# path to example.com / www.wikipedia.org. Self-skips otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker not available/responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

# SESSION-RESUME LEG prerequisites (narrower than the file-level gates above):
# absence here skips ONLY the SESSION-PLANT/SESSION-SURVIVAL-*/OVERLAY-*
# assertions below, not the whole file -- the pre-existing network-policy
# round-trip coverage still runs on a creds-less/no-jq machine.
SESSION_LEG=1
if [[ ! -s "${HOME}/.claude/.credentials.json" ]]; then
  SESSION_LEG=0
  echo "SKIP (session-resume leg only): no host ~/.claude/.credentials.json (host claude not authed) -- session-resume/overlay-negative-control assertions will not run"
elif ! command -v jq >/dev/null 2>&1; then
  SESSION_LEG=0
  echo "SKIP (session-resume leg only): jq not available -- session-resume assertions will not run"
elif ! docker run --rm "$IMAGE" test -x /usr/local/bin/claude >/dev/null 2>&1; then
  SESSION_LEG=0
  echo "SKIP (session-resume leg only): ${IMAGE} was not built with the claude-recipe composed (/usr/local/bin/claude wrapper absent) -- session-resume assertions will not run"
fi
CODEWORD=""
[[ "$SESSION_LEG" -eq 1 ]] && CODEWORD="TSF2ROUNDTRIP-$$-${RANDOM}"

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-repair-resume-roundtrip-XXXXXX")
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_NAME=""
cleanup() {
  [[ -n "$CAGE_NAME" ]] && msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
  [[ -n "$CAGE_NAME" ]] && msb volume remove "rc-state-${CAGE_NAME}" "rc-history-${CAGE_NAME}" >/dev/null 2>&1 || true
  # SESSION-RESUME LEG cleanup: cli/up.sh's `rc up` unconditionally mounts
  # the REAL ${HOME}/.claude/projects (rip-cage-dn2 -- session logs are
  # meant to survive container destroy onto the host, by design; that mount
  # is NOT test-only scaffolding this file adds). Remove ONLY the specific
  # transcript file(s) tagged with this run's unique codeword -- never
  # `rm -rf` a whole project directory: the `-workspace` symlink
  # init-rip-cage.sh maintains is a SINGLE mount-wide name shared by every
  # concurrently-live cage on this host, so a stale/foreign directory can
  # legitimately be the one a session landed in; deleting a whole directory
  # could destroy an unrelated concurrent cage's real session data.
  if [[ -n "${CODEWORD:-}" && -d "${HOME}/.claude/projects" ]]; then
    grep -rlF "$CODEWORD" "${HOME}/.claude/projects" 2>/dev/null | while IFS= read -r _leftover; do
      rm -f "$_leftover"
    done
  fi
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [example.com]
EOF

run_rc() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" "$RC" --output json "$@"
}

CR_OUT=$(run_rc up "$WS" 2>&1)
CR_RC=$?
if [[ "$CR_RC" -ne 0 ]]; then
  fail "setup: rc up failed" "$CR_OUT"
  echo ""
  echo "=== test-msb-repair-loop-resume-roundtrip.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created ${CAGE_NAME} with allowed_hosts=[example.com]"

fetch() {
  msb exec "$CAGE_NAME" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# DENY + CTRL1: initial state.
# ---------------------------------------------------------------------------
echo ""
echo "=== DENY + CTRL1: initial state -- wikipedia denied, example.com allowed ==="
DENY1=$(fetch https://www.wikipedia.org)
if [[ "$DENY1" == "000 0" ]]; then
  pass "DENY: www.wikipedia.org yields ZERO bytes before the reload (HTTP ${DENY1})"
else
  fail "DENY: expected zero-byte denial before reload" "$DENY1"
fi
CTRL1=$(fetch https://example.com)
CTRL1_SIZE="${CTRL1#* }"
if [[ "$CTRL1" == 200\ * && "$CTRL1_SIZE" -gt 0 ]]; then
  pass "CTRL1: example.com (allowed) returns real bidirectional data before reload (HTTP ${CTRL1})"
else
  fail "CTRL1: expected real data from the allowed host" "$CTRL1"
fi

# ---------------------------------------------------------------------------
# SESSION-PLANT + OVERLAY-SET: plant a REAL Claude session (host-mounted,
# should survive) and a guest-overlay-only marker (should NOT survive
# cold-recreate) before the reload. api.anthropic.com is already allowed
# without any project-file edit -- it is part of the curated DEFAULT
# allowlist ADR-029 D4 auto-seeds into a fresh global config.yaml on the
# first `rc up` above (network.allowed_hosts is a union-default list: the
# project file's [example.com] is UNIONED with the global default, not a
# replacement).
# ---------------------------------------------------------------------------
SESSION_ID=""
if [[ "$SESSION_LEG" -eq 1 ]]; then
  echo ""
  echo "=== SESSION-PLANT: plant a real Claude session pre-reload (codeword=${CODEWORD}) ==="
  PLANT_OUT=$(msb exec "$CAGE_NAME" -w /workspace -- claude -p "Remember this codeword: ${CODEWORD}. Confirm you stored it." --output-format json 2>/tmp/tsf2-roundtrip-plant.err)
  PLANT_RC=$?
  SESSION_ID=$(echo "$PLANT_OUT" | jq -r '.session_id // empty' 2>/dev/null)
  if [[ "$PLANT_RC" -eq 0 && -n "$SESSION_ID" ]]; then
    pass "SESSION-PLANT: planted a real Claude session pre-reload (session_id=${SESSION_ID})"
  else
    fail "SESSION-PLANT: planting the session failed" "rc=${PLANT_RC} out=${PLANT_OUT} err=$(cat /tmp/tsf2-roundtrip-plant.err 2>/dev/null)"
  fi
  if grep -rlF "$CODEWORD" "${HOME}/.claude/projects" >/dev/null 2>&1; then
    pass "SESSION-PLANT: host-side transcript under the mounted claude-home contains the planted codeword"
  else
    fail "SESSION-PLANT: no host-side transcript contains the codeword after planting" "$(grep -rl "$CODEWORD" "${HOME}/.claude/projects" 2>&1)"
  fi
else
  echo ""
  echo "SKIP: SESSION-PLANT (session-resume leg prerequisites not met, see startup SKIP lines above)"
fi

msb exec "$CAGE_NAME" -- sh -c 'echo pre-reload-overlay-marker > /home/agent/overlay-only-marker.txt'

# ---------------------------------------------------------------------------
# OVERLAY-PRESENT: the overlay-only marker write above is otherwise
# unchecked. Assert it landed BEFORE the reload -- without this, a silent
# write failure would make OVERLAY-GONE below pass VACUOUSLY (empty
# readback either way), collapsing the "cold-recreate is genuinely cold"
# proof it exists to provide.
# ---------------------------------------------------------------------------
OVERLAY_PREREAD=$(msb exec "$CAGE_NAME" -- cat /home/agent/overlay-only-marker.txt 2>/dev/null)
if [[ "$OVERLAY_PREREAD" == "pre-reload-overlay-marker" ]]; then
  pass "OVERLAY-PRESENT: the overlay-only marker was actually written pre-reload (makes OVERLAY-GONE below non-vacuous)"
else
  fail "OVERLAY-PRESENT: the overlay-only marker write did not land pre-reload" "got '${OVERLAY_PREREAD}'"
fi

# ---------------------------------------------------------------------------
# FIX: amend .rip-cage.yaml, run the REAL `rc reload` verb (cold-recreate).
# ---------------------------------------------------------------------------
echo ""
echo "=== FIX: amend .rip-cage.yaml + rc reload ==="
cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [example.com, www.wikipedia.org]
EOF
RELOAD_OUT=$(cd "$WS" && run_rc reload "$CAGE_NAME" 2>&1)
RELOAD_RC=$?
if [[ "$RELOAD_RC" -eq 0 ]]; then
  pass "FIX: rc reload exits 0"
else
  fail "FIX: rc reload failed" "$RELOAD_OUT"
  echo ""
  echo "=== test-msb-repair-loop-resume-roundtrip.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

# ---------------------------------------------------------------------------
# OVERLAY-GONE (honest negative, mirrors test-msb-lifecycle-reload-repair-
# loop.sh): the guest-overlay-only marker planted before the reload does NOT
# survive cold-recreate -- proves the recreate above was genuinely cold, not
# a no-op that would make SESSION-SURVIVAL-1 below a trivial/vacuous pass.
# ---------------------------------------------------------------------------
OVERLAY_READBACK=$(msb exec "$CAGE_NAME" -- cat /home/agent/overlay-only-marker.txt 2>/dev/null)
if [[ -z "$OVERLAY_READBACK" ]]; then
  pass "OVERLAY-GONE (honest negative): the guest-overlay-only marker did NOT survive cold-recreate, exactly as documented -- the reload that follows is a real cold-recreate, not a no-op"
else
  fail "OVERLAY-GONE: expected the overlay-only marker to be GONE under cold-recreate (would make SESSION-SURVIVAL-1 a vacuous pass otherwise)" "got '${OVERLAY_READBACK}'"
fi

# ---------------------------------------------------------------------------
# SESSION-SURVIVAL-1: immediately post-reload, the planted Claude session
# (host-mounted, unlike the overlay marker above) survives the SAME
# cold-recreate that just discarded the overlay marker.
# ---------------------------------------------------------------------------
if [[ "$SESSION_LEG" -eq 1 ]]; then
  echo ""
  echo "=== SESSION-SURVIVAL-1: immediately post-reload, the planted session survives ==="
  if grep -rlF "$CODEWORD" "${HOME}/.claude/projects" >/dev/null 2>&1; then
    pass "SESSION-SURVIVAL-1 (a): host-side transcript still contains the codeword immediately post-reload"
  else
    fail "SESSION-SURVIVAL-1 (a): host-side transcript lost the codeword post-reload" "$(grep -rl "$CODEWORD" "${HOME}/.claude/projects" 2>&1)"
  fi
  if msb exec "$CAGE_NAME" -- grep -rlF "$CODEWORD" /home/agent/.claude/projects >/dev/null 2>&1; then
    pass "SESSION-SURVIVAL-1 (b): the recreated cage's OWN claude-home mount also sees the codeword (real in-guest re-mount, not host-only)"
  else
    fail "SESSION-SURVIVAL-1 (b): recreated cage's claude-home mount does not see the codeword" "$(msb exec "$CAGE_NAME" -- find /home/agent/.claude/projects -name '*.jsonl' 2>&1 | head -5)"
  fi
  RESUME1_OUT=$(msb exec "$CAGE_NAME" -w /workspace -- claude --resume "$SESSION_ID" -p "What codeword did I ask you to remember? Reply with ONLY the codeword." --output-format json 2>/tmp/tsf2-roundtrip-resume1.err)
  RESUME1_RC=$?
  RESUME1_RESULT=$(echo "$RESUME1_OUT" | jq -r '.result // empty' 2>/dev/null)
  if [[ "$RESUME1_RC" -eq 0 && "$RESUME1_RESULT" == *"$CODEWORD"* ]]; then
    pass "SESSION-SURVIVAL-1 (c): claude --resume in the recreated cage recalled the codeword: '${RESUME1_RESULT}'"
  else
    fail "SESSION-SURVIVAL-1 (c): claude --resume did not recall the codeword post-reload" "rc=${RESUME1_RC} result='${RESUME1_RESULT}' err=$(cat /tmp/tsf2-roundtrip-resume1.err 2>/dev/null)"
  fi
else
  echo ""
  echo "SKIP: SESSION-SURVIVAL-1 (session-resume leg prerequisites not met, see startup SKIP lines above)"
fi

# ---------------------------------------------------------------------------
# RETRY1 + CTRL2: immediately post-reload (this is the EXISTING repair-loop
# test's own claim -- re-proven here as this test's baseline before the NEW
# stop+resume leg below).
# ---------------------------------------------------------------------------
echo ""
echo "=== RETRY1 + CTRL2: immediately post-reload, both hosts return real data ==="
RETRY1=$(fetch https://www.wikipedia.org)
RETRY1_SIZE="${RETRY1#* }"
if [[ "$RETRY1" == 200\ * && "$RETRY1_SIZE" -gt 0 ]]; then
  pass "RETRY1: www.wikipedia.org returns REAL bidirectional data immediately post-reload (HTTP ${RETRY1})"
else
  fail "RETRY1: expected real data from the newly-allowed host post-reload" "$RETRY1"
fi
CTRL2=$(fetch https://example.com)
CTRL2_SIZE="${CTRL2#* }"
if [[ "$CTRL2" == 200\ * && "$CTRL2_SIZE" -gt 0 ]]; then
  pass "CTRL2: example.com still returns real data immediately post-reload"
else
  fail "CTRL2: original allowed host regressed post-reload" "$CTRL2"
fi

# ---------------------------------------------------------------------------
# STOP: graceful stop of the RECREATED (post-reload) sandbox.
# ---------------------------------------------------------------------------
echo ""
echo "=== STOP: graceful stop of the recreated, post-reload sandbox ==="
msb stop "$CAGE_NAME" >/dev/null 2>&1
STOP_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$STOP_STATE" == "Stopped" ]]; then
  pass "STOP: independent msb inspect confirms the post-reload sandbox is genuinely stopped"
else
  fail "STOP: expected Stopped" "got '$STOP_STATE'"
fi

# ---------------------------------------------------------------------------
# RESUME: `rc up` resumes the stopped, post-reload sandbox for real.
# ---------------------------------------------------------------------------
echo ""
echo "=== RESUME: rc up resumes the post-reload sandbox ==="
RESUME_OUT=$(run_rc up "$WS" 2>&1)
RESUME_RC=$?
RESUME_ACTION=$(echo "$RESUME_OUT" | tail -1 | jq -r '.action' 2>/dev/null)
if [[ "$RESUME_RC" -eq 0 && "$RESUME_ACTION" == "resumed" ]]; then
  pass "RESUME: rc up resumes the post-reload sandbox for real (action=resumed)"
else
  fail "RESUME: expected action=resumed, exit 0" "rc=$RESUME_RC out=$RESUME_OUT"
fi
RESUME_STATE=$(msb inspect "$CAGE_NAME" --format json 2>/dev/null | jq -r '.status')
if [[ "$RESUME_STATE" == "Running" ]]; then
  pass "RESUME: independent msb inspect confirms Running after resume"
else
  fail "RESUME: expected Running after resume" "got '$RESUME_STATE'"
fi

# ---------------------------------------------------------------------------
# *** RETRY2 (Fold-4a core claim) + CTRL3 ***: the previously-denied host
# STILL returns REAL bidirectional data on the SAME resumed cage -- the
# amended net-rule policy survived a real stop+resume cycle, not just the
# initial post-reload boot. CTRL3 rules out RETRY2 passing via a dead
# network (which would make ANY host request look "not denied").
# ---------------------------------------------------------------------------
echo ""
echo "=== RETRY2 (Fold-4a core claim) + CTRL3: post-RESUME, the amended policy still holds ==="
RETRY2=$(fetch https://www.wikipedia.org)
RETRY2_SIZE="${RETRY2#* }"
if [[ "$RETRY2" == 200\ * && "$RETRY2_SIZE" -gt 0 ]]; then
  pass "RETRY2 (Fold-4a): www.wikipedia.org STILL returns REAL bidirectional data after stop+resume (HTTP ${RETRY2}) -- the reload-applied policy survived the resume"
else
  fail "RETRY2 (Fold-4a): expected real data from the previously-denied host after stop+resume -- the repair-loop's fix did NOT survive resume" "$RETRY2"
fi
CTRL3=$(fetch https://example.com)
CTRL3_SIZE="${CTRL3#* }"
if [[ "$CTRL3" == 200\ * && "$CTRL3_SIZE" -gt 0 ]]; then
  pass "CTRL3: example.com still returns real data post-resume (rules out a dead-network false positive on RETRY2)"
else
  fail "CTRL3: original allowed host regressed post-resume (RETRY2 would be unreliable)" "$CTRL3"
fi

# ---------------------------------------------------------------------------
# *** SESSION-SURVIVAL-2 (the session-leg's own Fold-4a-style core claim) ***
# the SAME codeword is STILL (a)/(b)/(c)-provable on the SAME resumed,
# post-reload cage -- session continuity survives a real stop+resume, not
# just the initial post-reload boot (mirrors RETRY2's claim for network
# policy, one section up, for the host-mounted claude-home instead).
# ---------------------------------------------------------------------------
if [[ "$SESSION_LEG" -eq 1 ]]; then
  echo ""
  echo "=== SESSION-SURVIVAL-2 (Fold-4a-style core claim): post-RESUME, the planted session still holds ==="
  if grep -rlF "$CODEWORD" "${HOME}/.claude/projects" >/dev/null 2>&1; then
    pass "SESSION-SURVIVAL-2 (a): host-side transcript STILL contains the codeword after stop+resume"
  else
    fail "SESSION-SURVIVAL-2 (a): host-side transcript lost the codeword after stop+resume" "$(grep -rl "$CODEWORD" "${HOME}/.claude/projects" 2>&1)"
  fi
  if msb exec "$CAGE_NAME" -- grep -rlF "$CODEWORD" /home/agent/.claude/projects >/dev/null 2>&1; then
    pass "SESSION-SURVIVAL-2 (b): the resumed cage's OWN claude-home mount STILL sees the codeword (real in-guest re-mount)"
  else
    fail "SESSION-SURVIVAL-2 (b): resumed cage's claude-home mount does not see the codeword" "$(msb exec "$CAGE_NAME" -- find /home/agent/.claude/projects -name '*.jsonl' 2>&1 | head -5)"
  fi
  RESUME2_OUT=$(msb exec "$CAGE_NAME" -w /workspace -- claude --resume "$SESSION_ID" -p "What codeword did I ask you to remember? Reply with ONLY the codeword." --output-format json 2>/tmp/tsf2-roundtrip-resume2.err)
  RESUME2_RC=$?
  RESUME2_RESULT=$(echo "$RESUME2_OUT" | jq -r '.result // empty' 2>/dev/null)
  if [[ "$RESUME2_RC" -eq 0 && "$RESUME2_RESULT" == *"$CODEWORD"* ]]; then
    pass "SESSION-SURVIVAL-2 (c): claude --resume on the stop+resumed cage STILL recalled the codeword: '${RESUME2_RESULT}' -- session continuity survives reload AND a subsequent real stop+resume"
  else
    fail "SESSION-SURVIVAL-2 (c): claude --resume did not recall the codeword after stop+resume" "rc=${RESUME2_RC} result='${RESUME2_RESULT}' err=$(cat /tmp/tsf2-roundtrip-resume2.err 2>/dev/null)"
  fi
else
  echo ""
  echo "SKIP: SESSION-SURVIVAL-2 (session-resume leg prerequisites not met, see startup SKIP lines above)"
fi

echo ""
echo "=== test-msb-repair-loop-resume-roundtrip.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
