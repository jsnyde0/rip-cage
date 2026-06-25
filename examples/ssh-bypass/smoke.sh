#!/usr/bin/env bash
# examples/ssh-bypass/smoke.sh — Behavioral smoke test for the ssh-bypass recipe.
#
# Installed by the ssh-bypass recipe's install_cmd into:
#   /usr/local/lib/rip-cage/recipe-tests/ssh-bypass-smoke.sh
# as root:root 0755, run by the generic runner (run-recipe-smokes.sh).
#
# Covers (probe-by-probe, mirrors pre-move test-safety-stack.sh #12/#12b-#12d
# and #11h chaining-robustness check):
#
#   SSH-1  — ssh-bypass blocker denies the verified bypass shape
#             (StrictHostKeyChecking=accept-new + UserKnownHostsFile=tmp)
#   SSH-2  — refusal message names .rip-cage.yaml + rc config init
#   SSH-3  — ssh-bypass blocker catches /usr/bin/ssh direct path call
#   SSH-4  — ssh-bypass blocker allows legitimate ssh (no override flags)
#   SSH-5  — chaining-robust: denies chained ssh-bypass after &&
#
# The hook path is verified at the start; if absent the script exits immediately
# (opt-in recipe not installed — not a failure, the runner only runs this file
# when it's been installed by the recipe's install_cmd).

set -uo pipefail

FAILURES=0
TOTAL=0

check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ — $detail}"
  else
    echo "FAIL  [$TOTAL] $name${detail:+ — $detail}"
    FAILURES=$((FAILURES + 1))
  fi
}

HOOK_PATH="/usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh"

echo "=== SSH-Bypass Recipe Smoke Test ==="
echo ""

# Sanity: the hook must be installed (this file IS installed by the recipe, so
# the hook should always be there — fail clearly if it's missing).
if [[ ! -x "$HOOK_PATH" ]]; then
  echo "FAIL  [0] ssh-bypass hook missing or not executable: $HOOK_PATH"
  echo "=== SSH-Bypass Smoke Summary: 0 checks, 1 failed ==="
  exit 1
fi

# ---------------------------------------------------------------------------
# SSH-1: ssh-bypass blocker denies the verified bypass shape (ADR-022 D5)
# ---------------------------------------------------------------------------
_ssh1_result=$(printf '{"tool_name":"Bash","tool_input":{"command":"ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/x git@gitlab.com"}}' | \
  "$HOOK_PATH" 2>/dev/null || true)
if echo "$_ssh1_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "SSH-1 blocker denies UserKnownHostsFile+accept-new bypass shape" "pass"
else
  check "SSH-1 blocker denies UserKnownHostsFile+accept-new bypass shape" "fail" "$_ssh1_result"
fi

# ---------------------------------------------------------------------------
# SSH-2: refusal message names .rip-cage.yaml + rc config init
# ---------------------------------------------------------------------------
if echo "$_ssh1_result" | grep -q '\.rip-cage\.yaml' && echo "$_ssh1_result" | grep -q 'rc config init'; then
  check "SSH-2 refusal message names .rip-cage.yaml + rc config init" "pass"
else
  check "SSH-2 refusal message names .rip-cage.yaml + rc config init" "fail" "$_ssh1_result"
fi
unset _ssh1_result

# ---------------------------------------------------------------------------
# SSH-3: ssh-bypass blocker catches /usr/bin/ssh direct path call
# ---------------------------------------------------------------------------
_ssh3_result=$(printf '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/ssh -o StrictHostKeyChecking=no host"}}' | \
  "$HOOK_PATH" 2>/dev/null || true)
if echo "$_ssh3_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "SSH-3 blocker catches /usr/bin/ssh direct path" "pass"
else
  check "SSH-3 blocker catches /usr/bin/ssh direct path" "fail" "$_ssh3_result"
fi
unset _ssh3_result

# ---------------------------------------------------------------------------
# SSH-4: ssh-bypass blocker does NOT block legitimate ssh (no override flags)
# ---------------------------------------------------------------------------
_ssh4_result=$(printf '{"tool_name":"Bash","tool_input":{"command":"ssh git@github.com"}}' | \
  "$HOOK_PATH" 2>/dev/null || true)
if [[ -z "$_ssh4_result" ]]; then
  check "SSH-4 blocker allows legitimate ssh (no override flags)" "pass"
else
  check "SSH-4 blocker allows legitimate ssh (no override flags)" "fail" "$_ssh4_result"
fi
unset _ssh4_result

# ---------------------------------------------------------------------------
# SSH-5: chaining-robust — denies chained ssh-bypass after &&
# Payload written to temp file (avoids literal && in shell command string).
# ---------------------------------------------------------------------------
_ssh5_payload=$(mktemp /tmp/ssh-bypass-smoke-5-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"echo x && ssh -o StrictHostKeyChecking=no host"}}' > "$_ssh5_payload"
_ssh5_result=$(cat "$_ssh5_payload" | "$HOOK_PATH" 2>/dev/null || true)
rm -f "$_ssh5_payload"
if echo "$_ssh5_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "SSH-5 chaining-robust: denies chained ssh-bypass after &&" "pass"
else
  check "SSH-5 chaining-robust: denies chained ssh-bypass after &&" "fail" "$_ssh5_result"
fi
unset _ssh5_payload _ssh5_result

echo ""
echo "=== SSH-Bypass Smoke Summary: $TOTAL checks, $FAILURES failed ==="
[[ "$FAILURES" -eq 0 ]] || exit 1
exit 0
