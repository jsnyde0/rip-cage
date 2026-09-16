#!/usr/bin/env bash
# Verification test for bead rip-cage-tha:
#   - sudoers chown is pinned to exact paths (no wildcard)
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

# --- Test 2: sudoers pins chown to /home/agent/.claude ---
echo ""
echo "-- Test 2: sudoers allows chown for /home/agent/.claude --"
if echo "$SUDOERS_LINE" | grep -q 'chown agent\\:agent /home/agent/.claude,'; then
  pass "sudoers allows chown for /home/agent/.claude"
else
  fail "sudoers missing chown for /home/agent/.claude"
  echo "  Line: $SUDOERS_LINE"
fi

# --- Test 3: sudoers pins chown to /home/agent/.claude-state ---
echo ""
echo "-- Test 3: sudoers allows chown for /home/agent/.claude-state --"
if echo "$SUDOERS_LINE" | grep -q 'chown agent\\:agent /home/agent/.claude-state'; then
  pass "sudoers allows chown for /home/agent/.claude-state"
else
  fail "sudoers missing chown for /home/agent/.claude-state"
  echo "  Line: $SUDOERS_LINE"
fi

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

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
