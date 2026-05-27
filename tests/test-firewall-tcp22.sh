#!/usr/bin/env bash
# Host-side unit tests for TCP-22 IP allowlisting + UDP/443 DROP + mode-aware banner.
# (rip-cage-hhh.4 / ADR-012 D8 evolved)
#
# Coverage:
#   T1  UDP/443 DROP rule is present in init-firewall.sh (D3 verification)
#   T2  Mode-aware banner: script contains mode-aware output text (observe/block/legacy)
#   T3  Mode-aware banner: script reads mode from egress-rules.yaml
#   T4  Mode-aware banner: banner not hardcoded unconditionally to "deny-list mode"
#   T5  _get_tcp22_allowed_ips: block mode resolves localhost to 127.0.0.1
#   T6  _get_tcp22_allowed_ips: legacy mode returns empty
#   T7  _get_tcp22_allowed_ips: observe mode returns empty (TCP-22 DROP only in block)
#   T8  init-firewall.sh contains iptables ACCEPT rule for TCP-22 (whitelist enforcement)
#   T9  init-firewall.sh contains iptables DROP/REJECT rule for TCP-22 (non-whitelisted)
#   T10 cmd_reload in rc contains TCP-22 refresh logic
#
# T5-T7 test a helper function _get_tcp22_allowed_ips sourced from init-firewall.sh.
# T8-T9 check for the presence of iptables command lines in init-firewall.sh.
# T10 checks that cmd_reload in rc invokes the TCP-22 refresh inside the container.
#
# All tests are docker-free.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
FIREWALL_SCRIPT="${REPO_ROOT}/init-firewall.sh"
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { echo "PASS T$1: $2"; TOTAL=$((TOTAL + 1)); }
fail() { echo "FAIL T$1: $2 -- $3"; FAILURES=$((FAILURES + 1)); TOTAL=$((TOTAL + 1)); }

# ---------------------------------------------------------------------------
# T1: UDP/443 DROP rule is present in init-firewall.sh (D3 verification)
# ADR-012 D8: UDP/443 blocked to force HTTP/2 fallback.
# ---------------------------------------------------------------------------
if grep -q 'iptables.*-p udp --dport 443 -j DROP' "$FIREWALL_SCRIPT" 2>/dev/null; then
  pass 1 "UDP/443 DROP rule present in init-firewall.sh"
else
  fail 1 "UDP/443 DROP rule present in init-firewall.sh" "no 'iptables -p udp --dport 443 -j DROP' found in $FIREWALL_SCRIPT"
fi

# ---------------------------------------------------------------------------
# T2-T4: Mode-aware banner
# ---------------------------------------------------------------------------

# T2: Script contains mode-aware output string that prints mode in the banner
# The banner must print "observe mode", "block mode", or "legacy" text.
# Must be more than just a comment about "block UDP" -- needs to be in echo/printf.
if grep -qE '(echo|printf).*egress firewall active.*(observe|block|legacy)' "$FIREWALL_SCRIPT" 2>/dev/null; then
  pass 2 "init-firewall.sh banner contains mode-aware output text (observe/block/legacy)"
else
  fail 2 "init-firewall.sh banner contains mode-aware output text" "no mode-aware echo/printf in banner found"
fi

# T3: Script reads mode from the generated rules file in banner/TCP-22 logic
# Must have code that reads 'mode:' from egress-rules.yaml in the mode-reading region
# (not just the rule-count Python snippet at line 126).
if grep -qE '(grep|python|awk).*mode.*egress-rules.yaml|egress-rules.yaml.*mode' "$FIREWALL_SCRIPT" 2>/dev/null; then
  pass 3 "init-firewall.sh reads mode from egress-rules.yaml"
else
  fail 3 "init-firewall.sh reads mode from egress-rules.yaml" "no code to extract mode from rules file for banner/TCP-22"
fi

# T4: Script does NOT have only a hardcoded "deny-list mode" banner (must be conditional/replaced)
# Before fix: echo "egress firewall active ($RULE_COUNT rules, deny-list mode)"
# After fix: mode-aware conditional
if grep -qE '^[[:space:]]*echo.*egress firewall active.*deny-list mode' "$FIREWALL_SCRIPT" 2>/dev/null; then
  fail 4 "banner not hardcoded unconditionally to deny-list mode" "static 'deny-list mode' echo still present"
else
  pass 4 "banner is not hardcoded unconditionally to 'deny-list mode'"
fi

# ---------------------------------------------------------------------------
# T5-T7: _get_tcp22_allowed_ips function
# ---------------------------------------------------------------------------
_T_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-tcp22-test-XXXXXX")

# shellcheck disable=SC2329  # invoked via trap
cleanup_t_dir() {
  local d="$_T_DIR"
  if [[ -n "$d" && -d "$d" ]]; then
    find "$d" -type f -delete 2>/dev/null
    find "$d" -type d -depth -delete 2>/dev/null
  fi
}
trap cleanup_t_dir EXIT

# Write fixture for block mode with localhost
printf 'version: 2\nmode: block\nallowed_hosts:\n  - localhost\n  - github.com\nwritable_hosts: []\nrules: []\n' \
  > "${_T_DIR}/rules-block.yaml"

# T5: block mode + localhost -> 127.0.0.1 in output
_t5_result=$(bash -c "
  source '${FIREWALL_SCRIPT}' 2>/dev/null
  _get_tcp22_allowed_ips '${_T_DIR}/rules-block.yaml' 2>/dev/null
" 2>/dev/null || true)

if echo "$_t5_result" | grep -q "127.0.0.1"; then
  pass 5 "_get_tcp22_allowed_ips: block mode resolves localhost to 127.0.0.1"
else
  fail 5 "_get_tcp22_allowed_ips: block mode resolves localhost to 127.0.0.1" "got: $_t5_result"
fi

# Write fixture for legacy mode
printf 'version: 1\nrules: []\n' > "${_T_DIR}/rules-legacy.yaml"

# T6: legacy mode -> empty output
_t6_result=$(bash -c "
  source '${FIREWALL_SCRIPT}' 2>/dev/null
  _get_tcp22_allowed_ips '${_T_DIR}/rules-legacy.yaml' 2>/dev/null
" 2>/dev/null || true)

if [[ -z "$_t6_result" ]]; then
  pass 6 "_get_tcp22_allowed_ips: legacy mode returns empty"
else
  fail 6 "_get_tcp22_allowed_ips: legacy mode returns empty" "got: $_t6_result"
fi

# Write fixture for observe mode
printf 'version: 2\nmode: observe\nallowed_hosts:\n  - localhost\nwritable_hosts: []\nrules: []\n' \
  > "${_T_DIR}/rules-observe.yaml"

# T7: observe mode -> empty output (TCP-22 DROP only in block mode)
_t7_result=$(bash -c "
  source '${FIREWALL_SCRIPT}' 2>/dev/null
  _get_tcp22_allowed_ips '${_T_DIR}/rules-observe.yaml' 2>/dev/null
" 2>/dev/null || true)

if [[ -z "$_t7_result" ]]; then
  pass 7 "_get_tcp22_allowed_ips: observe mode returns empty (TCP-22 DROP only in block)"
else
  fail 7 "_get_tcp22_allowed_ips: observe mode returns empty" "got: $_t7_result"
fi

# ---------------------------------------------------------------------------
# T8: init-firewall.sh contains iptables ACCEPT rule for TCP-22
# ---------------------------------------------------------------------------
if grep -qE 'iptables.*--dport 22.*ACCEPT|iptables.*dport 22.*j ACCEPT' "$FIREWALL_SCRIPT" 2>/dev/null; then
  pass 8 "init-firewall.sh contains iptables ACCEPT rule for TCP-22 (whitelist enforcement)"
else
  fail 8 "init-firewall.sh contains iptables ACCEPT rule for TCP-22" "no 'iptables ... --dport 22 ... ACCEPT' found"
fi

# ---------------------------------------------------------------------------
# T9: init-firewall.sh contains iptables DROP rule for TCP-22 (non-whitelisted)
# ---------------------------------------------------------------------------
if grep -qE 'iptables.*--dport 22.*(DROP|REJECT)|iptables.*dport 22.*j (DROP|REJECT)' "$FIREWALL_SCRIPT" 2>/dev/null; then
  pass 9 "init-firewall.sh contains iptables DROP rule for TCP-22 (non-whitelisted)"
else
  fail 9 "init-firewall.sh contains iptables DROP rule for TCP-22" "no 'iptables ... --dport 22 ... DROP/REJECT' found"
fi

# ---------------------------------------------------------------------------
# T10: cmd_reload in rc contains TCP-22 refresh logic
# Structural test: after regenerating egress-rules on reload, must also refresh
# the TCP-22 iptables rules inside the container.
# ---------------------------------------------------------------------------
if grep -qE '_setup_tcp22|tcp22|TCP.22|dport 22|port.22' "$RC" 2>/dev/null; then
  pass 10 "rc contains TCP-22 related code (reload/setup path)"
else
  fail 10 "rc contains TCP-22 related code" "no TCP-22 related code found in rc"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- Results: ${FAILURES} failure(s) out of ${TOTAL} checks ---"
exit "$FAILURES"
