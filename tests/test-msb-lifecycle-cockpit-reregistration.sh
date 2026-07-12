#!/usr/bin/env bash
# tests/test-msb-lifecycle-cockpit-reregistration.sh -- effect-based proof
# for bead rip-cage-rj68 (S6) criterion 3: "After resume, cockpit/herdr
# state is re-registered."
#
# HONESTY NOTE (per the bead's explicit instruction on interactive/heavy
# criteria): the rip-cage:latest image available in THIS environment was
# NOT built with the herdr MULTIPLEXER manifest entry baked in (confirmed
# live: no /etc/rip-cage/multiplexers/ directory, no herdr binary). A full
# herdr-baked image requires `rc build` against a tools.yaml declaring
# examples/herdr/manifest-fragment.yaml's TOOL+MULTIPLEXER entries, which
# was judged out of scope for this bead's time budget (real Docker image
# build). Consequently:
#   - VERIFIED here, for real: rc's OWN `_up_init_container` function
#     (the exact function cli/up.sh's create AND resume paths call) really
#     dispatches to a real herdr server start hook and produces a real,
#     freshly-registered herdr control socket + session file -- proven
#     across a genuine graceful-stop/start (fresh kernel boot) cycle, using
#     a herdr binary sideloaded via the SAME pinned URL/checksum the real
#     manifest-fragment.yaml TOOL entry uses (not a mock/stub), and the
#     SAME hook script content the real MULTIPLEXER entry bakes.
#   - NOT VERIFIED here: the full config-driven path (`session.multiplexer:
#     herdr` in .rip-cage.yaml selected THROUGH rc up's config validator,
#     which requires the image's rc.multiplexers label to declare herdr as
#     baked -- correctly refused against this environment's non-herdr
#     image). NOT VERIFIED: interactive pane usability (attaching a real
#     TTY to the herdr TUI) -- no interactive terminal in this harness.
#     Say this plainly rather than fabricate a green for either.
#
# NEEDS_MSB + a pre-built rip-cage:latest image + live network path to
# github.com (to fetch the herdr binary, mirroring the real TOOL entry's
# own build-time-only egress need). Self-skips otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

NAME="cockpit-reg-$$"
cleanup() { msb remove --force "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! msb create "$IMAGE" --name "$NAME" \
    --net-default deny --net-rule "allow@github.com:tcp:443,allow@*.githubusercontent.com:tcp:443,allow@objects.githubusercontent.com:tcp:443" \
    >/dev/null 2>&1; then
  fail "setup: msb create failed"
  echo ""
  echo "=== test-msb-lifecycle-cockpit-reregistration.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then :; fi
if msb exec "$NAME" -- command -v herdr >/dev/null 2>&1; then
  fail "unexpected: herdr already present in ${IMAGE} -- sideload precondition invalid, update this test's honesty framing"
fi

# RC_MULTIPLEXER must be a GUEST env var (what init-rip-cage.sh reads via
# `${RC_MULTIPLEXER:-none}`) -- a real `rc up` bakes it at `msb create`
# time via -e. Setting it in the HOST shell before calling a bash function
# has no effect on `msb exec`'s guest environment (msb execs do not
# inherit the caller's host env); `msb modify --env --restart` is the
# live-sandbox equivalent of having baked it at create time (env changes
# require an explicit --restart/--next-start apply policy -- confirmed
# live; a bare `msb modify --env` alone is REJECTED, not silently queued).
MODIFY_OUT=$(msb modify "$NAME" --env RC_MULTIPLEXER=herdr --restart 2>&1)
MODIFY_RC=$?
if [[ "$MODIFY_RC" -ne 0 ]]; then
  fail "setup: msb modify --env --restart failed" "$MODIFY_OUT"
  echo ""
  echo "=== test-msb-lifecycle-cockpit-reregistration.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

# Sideload herdr, exactly the pinned URL + checksum examples/herdr/manifest-fragment.yaml's TOOL entry uses.
SIDELOAD=$(mktemp)
cat > "$SIDELOAD" <<'SCRIPT'
set -e
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then TARGET=aarch64; EXPECTED_SHA=77407959c514c25c870bbcc6d2a2c86fef5b5701ed0c7c37745d7412e8563d72; else TARGET=x86_64; EXPECTED_SHA=ad2a5d480a4e04609a9dd30a19ec07854578df6b5f0ea9299246963baf40363b; fi
curl -fsSL "https://github.com/ogulcancelik/herdr/releases/download/v0.7.0/herdr-linux-${TARGET}" -o /tmp/herdr
echo "${EXPECTED_SHA}  /tmp/herdr" | sha256sum -c -
install -m 755 /tmp/herdr /usr/local/bin/herdr
rm -f /tmp/herdr
mkdir -p /etc/rip-cage/multiplexers/herdr
cat > /etc/rip-cage/multiplexers/herdr/start <<'HOOK'
mkdir -p "${HOME}/.config/herdr"
[ -d /workspace ] && export HERDR_STARTUP_CWD=/workspace
herdr server > /tmp/rip-cage-mux-herdr.log 2>&1 &
echo "[rip-cage] herdr server started (PID=$!)"
HOOK
printf '%s\n' 'herdr' > /etc/rip-cage/multiplexers/herdr/attach
chmod +x /etc/rip-cage/multiplexers/herdr/start /etc/rip-cage/multiplexers/herdr/attach
SCRIPT
msb copy "$SIDELOAD" "${NAME}:/tmp/herdr-sideload.sh" >/dev/null 2>&1
SIDELOAD_OUT=$(msb exec "$NAME" -u root -- sh /tmp/herdr-sideload.sh 2>&1)
SIDELOAD_RC=$?
rm -f "$SIDELOAD"
if [[ "$SIDELOAD_RC" -eq 0 ]]; then
  pass "setup: herdr sideloaded (pinned URL, checksum verified against the real manifest-fragment.yaml value)"
else
  fail "setup: herdr sideload failed" "$SIDELOAD_OUT"
  echo ""
  echo "=== test-msb-lifecycle-cockpit-reregistration.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

# shellcheck source=/dev/null
source "$RC" 2>/dev/null

echo ""
echo "=== FIRST-BOOT: rc's own _up_init_container dispatches to a real herdr start ==="
_UP_INIT_OK=""
_up_init_container "$NAME" >/tmp/cockpit-init1.out 2>&1
if [[ "$_UP_INIT_OK" == "true" ]]; then
  pass "FIRST-BOOT: _up_init_container reports success"
else
  fail "FIRST-BOOT: _up_init_container reported failure" "$(cat /tmp/cockpit-init1.out)"
fi
if grep -q "session.multiplexer=herdr: start hook completed" /tmp/cockpit-init1.out; then
  pass "FIRST-BOOT: init-rip-cage.sh's own log confirms the herdr start hook ran"
else
  fail "FIRST-BOOT: expected the herdr start-hook completion line" "$(cat /tmp/cockpit-init1.out)"
fi
PID1=$(msb exec "$NAME" -- pgrep -f 'herdr server' 2>/dev/null | head -1)
SOCK1=$(msb exec "$NAME" -- sh -c 'test -S ~/.config/herdr/herdr.sock && echo present' 2>/dev/null)
if [[ -n "$PID1" && "$SOCK1" == "present" ]]; then
  pass "FIRST-BOOT: a REAL herdr server process (pid ${PID1}) and control socket exist in-guest"
else
  fail "FIRST-BOOT: expected a real herdr process + socket" "pid='${PID1}' sock='${SOCK1}'"
fi

echo ""
echo "=== RESUME: graceful stop + start (fresh kernel boot) loses the old registration ==="
msb stop "$NAME" >/dev/null 2>&1
msb start "$NAME" >/dev/null 2>&1
PID_GONE=$(msb exec "$NAME" -- pgrep -f 'herdr server' 2>/dev/null || true)
if [[ -z "$PID_GONE" ]]; then
  pass "RESUME setup: the pre-resume herdr process is genuinely gone after the fresh boot (proves this isn't a no-op restart)"
else
  fail "RESUME setup: expected no herdr process immediately post-resume" "got pid '${PID_GONE}'"
fi

echo ""
echo "=== RE-REGISTER: _up_init_container re-run on resume produces a NEW, real herdr registration ==="
_UP_INIT_OK=""
_up_init_container "$NAME" >/tmp/cockpit-init2.out 2>&1
if [[ "$_UP_INIT_OK" == "true" ]]; then
  pass "RE-REGISTER: post-resume _up_init_container reports success"
else
  fail "RE-REGISTER: post-resume _up_init_container reported failure" "$(cat /tmp/cockpit-init2.out)"
fi
PID2=$(msb exec "$NAME" -- pgrep -f 'herdr server' 2>/dev/null | head -1)
SOCK2=$(msb exec "$NAME" -- sh -c 'test -S ~/.config/herdr/herdr.sock && echo present' 2>/dev/null)
if [[ -n "$PID2" && "$SOCK2" == "present" ]]; then
  pass "RE-REGISTER: a NEW real herdr server process (pid ${PID2}) and control socket exist post-resume"
else
  fail "RE-REGISTER: expected a real post-resume herdr process + socket" "pid='${PID2}' sock='${SOCK2}'"
fi
if [[ -n "$PID1" && -n "$PID2" && "$PID1" != "$PID2" ]]; then
  pass "RE-REGISTER: the post-resume herdr process is a GENUINELY NEW process (pid ${PID1} -> ${PID2}, not the same one surviving)"
else
  fail "RE-REGISTER: expected a distinct PID pre/post resume" "pid1=${PID1} pid2=${PID2}"
fi

rm -f /tmp/cockpit-init1.out /tmp/cockpit-init2.out

echo ""
echo "=== test-msb-lifecycle-cockpit-reregistration.sh: ${FAILURES}/${TOTAL} failure(s) ==="
echo "NOTE: interactive pane usability and the full config-driven (rc up + .rip-cage.yaml session.multiplexer) path were NOT exercised -- see this file's header for exactly why."
[[ "$FAILURES" -eq 0 ]]
