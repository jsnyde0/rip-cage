#!/usr/bin/env bash
# Verification test for bead rip-cage-tha:
#   - sudoers has no chown wildcard; ownership goes through own-agent-dir (Test 8)
#   - .claude and .claude-state dirs are pre-created after USER agent
set -euo pipefail
PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
DOCKERFILE="${REPO_ROOT}/cage/Dockerfile"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Dockerfile Sudoers & Pre-Created Dirs Tests ==="
echo ""

# --- Test 1: sudoers does NOT use chown wildcard ---
echo "-- Test 1: sudoers does not use chown wildcard --"
SUDOERS_LINE=$(grep 'sudoers.d/agent' "$DOCKERFILE")
if echo "$SUDOERS_LINE" | grep -q 'chown \*'; then
  fail "sudoers still uses chown wildcard"
  echo "  Line: $SUDOERS_LINE"
else
  pass "sudoers does not use chown wildcard"
fi

# Tests 2-3 (raw chown pinned to .claude / .claude-state) retired: a raw chown
# grant follows symlinks; Test 8 asserts the own-agent-dir grants instead.

# --- Test 4: Dockerfile pre-creates .claude and .claude-state dirs ---
echo ""
echo "-- Test 4: Dockerfile pre-creates .claude and .claude-state after USER agent --"
# Check that mkdir appears after USER agent line
AFTER_USER=$(sed -n '/^USER agent/,$ p' "$DOCKERFILE")
if echo "$AFTER_USER" | grep -q 'mkdir.*\.claude.*\.claude-state'; then
  pass "Dockerfile pre-creates .claude and .claude-state dirs after USER agent"
else
  fail "Dockerfile does not pre-create .claude and .claude-state after USER agent"
fi

# --- Test 5: the floor probe's expected sudo grant IS the Dockerfile's grant ---
# The probe runs as the agent, which cannot read /etc/sudoers.d/agent (0440
# root:root, by design), so it carries the expected command list literally. That
# literal is only trustworthy while it matches what the Dockerfile bakes, and
# nothing inside a cage can compare the two. This is that comparison, host-side:
# change one and this goes red. rip-cage-ely4.12.
echo ""
echo "-- Test 5: floor probe's expected sudo grant matches the Dockerfile --"
PROBE="${REPO_ROOT}/cage/floor/floor-probe.sh"
# Both sides normalized the same way the probe normalizes `sudo -n -l` output:
# split the comma list, drop sudoers' backslash escaping, trim, sort.
DOCKERFILE_GRANT=$(echo "$SUDOERS_LINE" \
  | sed -n 's/.*NOPASSWD:[[:space:]]*\(.*\)" > \/etc\/sudoers.d\/agent.*/\1/p' \
  | tr ',' '\n' | sed 's/\\//g; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort)
PROBE_GRANT=$(sed -n "/^_rc_floor_sudo_expected='/,/'$/p" "$PROBE" \
  | sed "s/^_rc_floor_sudo_expected='//; s/'$//" | grep -v '^$' | sort)
if [[ -z "$DOCKERFILE_GRANT" ]]; then
  fail "could not parse the sudoers grant out of the Dockerfile — this guard is vacuous, fix the parse"
elif [[ -z "$PROBE_GRANT" ]]; then
  fail "could not parse _rc_floor_sudo_expected out of ${PROBE} — this guard is vacuous, fix the parse"
elif [[ "$DOCKERFILE_GRANT" == "$PROBE_GRANT" ]]; then
  pass "floor probe's expected sudo grant matches the Dockerfile ($(echo "$PROBE_GRANT" | grep -c .) commands)"
else
  fail "floor probe's expected sudo grant has drifted from the Dockerfile"
  echo "  Dockerfile: $(echo "$DOCKERFILE_GRANT" | tr '\n' '|')"
  echo "  Probe:      $(echo "$PROBE_GRANT" | tr '\n' '|')"
fi

# --- Test 6: the grant carries no root-code-execution path ---
# apt-get (-o APT::Update::Pre-Invoke::=<cmd>) and dpkg (-i <deb with a
# maintainer script>, --root) each run arbitrary commands as root, which hands a
# steered agent every root-owned guard. ADR-002 D12, evolved 2026-11-09
# (rip-cage-rsh9.1): installs happen at build time in the FROM-extension
# Dockerfile (ADR-031 D4), never through runtime sudo.
echo ""
echo "-- Test 6: sudoers grants no package manager (root-code-execution path) --"
_t6_hits=$(echo "$DOCKERFILE_GRANT" | grep -E '(^|/)(apt|apt-get|dpkg|aptitude|npm|pip|pip3)( |$)' || true)
if [[ -z "$DOCKERFILE_GRANT" ]]; then
  fail "could not parse the sudoers grant — Test 6 is vacuous"
elif [[ -n "$_t6_hits" ]]; then
  fail "sudoers still grants a package manager: $(echo "$_t6_hits" | tr '\n' '|')"
else
  pass "sudoers grants no package manager"
fi

# --- Test 7: TIOCSTI is closed at boot through one exact-argument grant ---
# dev.tty.legacy_tiocsti=1 lets a process push keystrokes into a tty it holds.
# The guest boots with it on; init lowers it each boot via sudo. The grant is
# pinned to the exact argv, so it can only ever LOWER the value.
echo ""
echo "-- Test 7: sudoers pins sysctl to legacy_tiocsti=0 and init runs it --"
INIT="${REPO_ROOT}/cage/init/init-rip-cage.sh"
if ! echo "$DOCKERFILE_GRANT" | grep -qx '/usr/sbin/sysctl -w dev.tty.legacy_tiocsti=0'; then
  fail "sudoers lacks the exact '/usr/sbin/sysctl -w dev.tty.legacy_tiocsti=0' grant"
elif echo "$DOCKERFILE_GRANT" | grep 'sysctl' | grep -vqx '/usr/sbin/sysctl -w dev.tty.legacy_tiocsti=0'; then
  fail "sudoers grants sysctl beyond the one pinned argv"
elif ! grep -q 'sudo -n /usr/sbin/sysctl -w dev.tty.legacy_tiocsti=0' "$INIT"; then
  fail "init-rip-cage.sh does not run the pinned sysctl grant"
else
  pass "sysctl grant pinned to legacy_tiocsti=0 and init runs it"
fi

# --- Test 8: ownership fixes go through the no-follow helper, never raw chown ---
# A raw `chown agent:agent /home/agent/X` grant follows a symlink (GNU chown
# dereferences by default): the agent replaces X with a symlink to any root file,
# runs the grant, and owns that file. `chown -h` is not enough either: it still
# follows symlinks in the intermediate components (~/.pi, ~/.local), and the
# guest boots with fs.protected_hardlinks=0, so a hardlinked root file is chowned
# through its inode. Measured live on the pre-fix image (rip-cage-rsh9.1 round 2).
echo ""
echo "-- Test 8: sudoers grants no raw chown; init uses the own-agent-dir helper --"
HELPER_SRC="${REPO_ROOT}/cage/substrate/own-agent-dir"
HELPER_DST=/usr/local/lib/rip-cage/own-agent-dir
_t8_expected=$(printf '%s\n' "${HELPER_DST} claude" "${HELPER_DST} claude-state" \
  "${HELPER_DST} mise" "${HELPER_DST} pi-agent" | sort)
_t8_have=$(echo "$DOCKERFILE_GRANT" | grep -F "${HELPER_DST}" | sort || true)
if echo "$DOCKERFILE_GRANT" | grep -qE '(^|/)chown( |$)'; then
  fail "sudoers still grants a raw chown: $(echo "$DOCKERFILE_GRANT" | grep -E 'chown' | tr '\n' '|')"
elif [[ "$_t8_have" != "$_t8_expected" ]]; then
  fail "sudoers own-agent-dir grants are not exactly the four targets: $(echo "$_t8_have" | tr '\n' '|')"
elif [[ ! -f "$HELPER_SRC" ]] || ! head -1 "$HELPER_SRC" | grep -qx '#!/usr/bin/python3 -I'; then
  fail "${HELPER_SRC} missing or not an isolated-mode (-I) python3 script"
elif ! grep -q "COPY cage/substrate/own-agent-dir ${HELPER_DST}" "$DOCKERFILE"; then
  fail "Dockerfile does not install the helper at ${HELPER_DST}"
elif grep -nE 'sudo[^|;]*chown' "${REPO_ROOT}/cage/init/init-rip-cage.sh" | grep -v '^[0-9]*:[[:space:]]*#' | grep -q .; then
  fail "init-rip-cage.sh still calls sudo chown"
else
  pass "ownership grants are the four own-agent-dir targets; no raw chown"
fi

# --- Test 9: the helper refuses symlink and hardlink substitution ---
# Host-side behavior test on a scratch home owned by the caller (the helper's
# core takes home + uid; the sudo entry point pins /home/agent + 1000).
echo ""
echo "-- Test 9: own-agent-dir refuses symlinks and skips hardlinks --"
if [[ ! -f "$HELPER_SRC" ]]; then
  fail "helper missing — Test 9 cannot run"
else
  _t9_out=$(uv run --no-project python -I "${SCRIPT_DIR}/own-agent-dir-check.py" "$HELPER_SRC" 2>&1) && _t9_rc=0 || _t9_rc=$?
  if [[ "$_t9_rc" -eq 0 ]]; then
    pass "own-agent-dir: $(echo "$_t9_out" | tail -1)"
  else
    fail "own-agent-dir behavior: $(echo "$_t9_out" | tr '\n' '|')"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
