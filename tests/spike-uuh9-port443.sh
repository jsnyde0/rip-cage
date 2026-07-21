#!/usr/bin/env bash
# tests/spike-uuh9-port443.sh -- THROWAWAY empirical spike for bead
# rip-cage-uuh9 (ADR-029 D4 floor call): does scoping the default egress
# allowlist's net-rules to tcp:443 break any legitimate default traffic?
#
# NOT wired into the test suite. Does NOT edit any shipped config, the
# generator, or .rip-cage.yaml / the global config -- the port-scope
# transform happens ONLY on a runtime copy of the FLAGS array produced by
# the real generator chain, inside this script.
#
# Per the msb fake-accept confound (bd memory
# msb-netstack-fake-accepts-tcp-connect-not-egress): connect()-success on a
# disallowed port/host proves NOTHING (msb fake-accepts TCP connects; :443
# is grabbed by the TLS interceptor then dropped, :53 is answered by msb's
# own DNS forwarder). Every ALLOW verdict below rests on real bidirectional
# application data (real generative claude output, or a real HTTP body with
# size>0). Every BLOCK verdict rests on ZERO bytes WITH a same-context
# positive control proving the network/host is otherwise live.
#
# Q1 (acceptance 1+3): a defaults-only cage with net-rules rewritten to
#     allow@<host>:tcp:443 completes a real `claude -p` turn with ZERO
#     denials against any of the REAL auto-seeded default hosts (read live
#     from the generator's own output -- not a hand-typed list, since the
#     actual defaults may differ from any assumed set). Also probes
#     github.com (a floor host, if present in the real generator output) on
#     :443 for real bidirectional data.
# Q2 (acceptance 2): a non-443 port to an ALLOWED host is BLOCKED, proven
#     via a same-host baseline (:80 real data under an all-ports rule) +
#     positive control (:443 real data under the port-scoped rule) +
#     block probe (:80 zero bytes under the port-scoped rule).
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

echo ""
echo "=== Sweep: removing any leftover spike-uuh9-* cages from a prior run ==="
while IFS= read -r _leftover; do
  [[ -z "$_leftover" ]] && continue
  echo "  removing leftover: $_leftover"
  msb remove -f "$_leftover" >/dev/null 2>&1 || true
done < <(msb list --format json 2>/dev/null | jq -r '.[].name' 2>/dev/null | grep '^spike-uuh9-' || true)

CAGE_Q1="spike-uuh9-q1-${RUN_ID}"
CAGE_Q2_BASELINE="spike-uuh9-q2base-${RUN_ID}"
CAGE_Q2_SCOPED="spike-uuh9-q2scoped-${RUN_ID}"
TEST_HOME=""
SCRATCH=""

cleanup() {
  msb remove -f "$CAGE_Q1" >/dev/null 2>&1 || true
  msb remove -f "$CAGE_Q2_BASELINE" >/dev/null 2>&1 || true
  msb remove -f "$CAGE_Q2_SCOPED" >/dev/null 2>&1 || true
  [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
  [[ -n "${SCRATCH:-}" && -d "$SCRATCH" ]] && rm -rf "$SCRATCH"
  rm -f /tmp/spike-uuh9-*.err /tmp/spike-uuh9-*.out
}
trap cleanup EXIT

# ===========================================================================
# Setup: fresh HOME, real auto-seed, real translator + generator chain --
# verbatim from tests/test-default-allowlist-live.sh. No hand-rolled host
# list anywhere below this point (except Q2's example.com probe, which is a
# spike-only host chosen for its stable, redirect-free 200 response on both
# :80 and :443 -- explicitly licensed by the bead brief).
# ===========================================================================
echo ""
echo "=== Setup: real auto-seed -> real _up_build_egress_config_json -> real _msb_flags_generate ==="
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-uuh9-spike-XXXXXX")
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

echo ""
echo "=== Setup: real generator's live default host set (egress_json) ==="
echo "$EGRESS_JSON" | jq .
DEFAULT_HOSTS=()
while IFS= read -r _h; do DEFAULT_HOSTS+=("$_h"); done < <(jq -r '.allowed_hosts[]' <<<"$EGRESS_JSON")
echo "Live default hosts (from the real generator, this run): ${DEFAULT_HOSTS[*]}"

# ===========================================================================
# THE ONE CHANGE: port-scope transform. Rewrite ONLY net-rule allow values
# (the token immediately following a literal --net-rule that matches
# ^allow@[^:]+$) to append :tcp:443. Every other flag (--net-default,
# --secret, -e, ...) is left byte-for-byte untouched. This is a runtime
# array transform in THIS throwaway script only -- it does not touch
# cli/lib/msb_flags.sh.
# ===========================================================================
echo ""
echo "=== Port-scope transform: allow@<host> -> allow@<host>:tcp:443 ==="
FLAGS443=()
_prev=""
for _tok in "${FLAGS[@]}"; do
  if [[ "$_prev" == "--net-rule" && "$_tok" =~ ^allow@[^:]+$ ]]; then
    FLAGS443+=("${_tok}:tcp:443")
  else
    FLAGS443+=("$_tok")
  fi
  _prev="$_tok"
done

echo "Net-rule tokens BEFORE transform:"
printf '  %s\n' "${FLAGS[@]}" | grep -A0 "^  allow@" || true
echo "Net-rule tokens AFTER transform (what Q1's cage actually boots with):"
NET_RULE_TOKENS_443=()
_prev=""
for _tok in "${FLAGS443[@]}"; do
  if [[ "$_prev" == "--net-rule" ]]; then
    NET_RULE_TOKENS_443+=("$_tok")
    echo "  $_tok"
  fi
  _prev="$_tok"
done

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

# ===========================================================================
# Q1 setup: boot the port-scoped defaults cage.
# ===========================================================================
echo ""
echo "=== Q1 setup: booting defaults-only cage with PORT-SCOPED (:tcp:443) net-rules ==="
if msb run -d --name "$CAGE_Q1" --replace --timeout 90s --log-level trace "${FLAGS443[@]}" \
  -v "${SCRATCH}/claude-dir:/home/agent/.claude" \
  --mount-file "${SCRATCH}/claude.json:/home/agent/.claude.json" \
  -w /home/agent "$IMAGE" -- sleep 300 >/tmp/spike-uuh9-q1-boot.err 2>&1; then
  pass "Q1 setup: port-scoped defaults cage boots"
else
  fail "Q1 setup: cage failed to boot" "$(cat /tmp/spike-uuh9-q1-boot.err)"
fi

# ===========================================================================
# Q1-turn: real claude -p turn on the port-scoped defaults cage.
# ===========================================================================
echo ""
echo "=== Q1-turn: real claude -p turn on the port-scoped (:443) defaults cage ==="
SENTINEL="UUH9-PORT443-SPIKE-OK-${RUN_ID}"
Q1_OUT=$(msb exec "$CAGE_Q1" -- sh -c "claude -p 'reply with exactly: ${SENTINEL}'" 2>/tmp/spike-uuh9-q1-turn.err)
Q1_RC=$?
if [[ "$Q1_RC" -eq 0 && "$Q1_OUT" == *"$SENTINEL"* ]]; then
  pass "Q1-turn: real claude -p turn succeeded end-to-end on the port-scoped defaults cage (real generative output: '${Q1_OUT}')"
else
  fail "Q1-turn: expected the real claude completion to echo the sentinel" "rc=${Q1_RC} out='${Q1_OUT}' err=$(cat /tmp/spike-uuh9-q1-turn.err)"
fi

# ===========================================================================
# Q1-denials: zero denial-log lines for any of the REAL live default hosts.
# ===========================================================================
echo ""
echo "=== Q1-denials: scanning trace logs for 'denied by network policy domain=' ==="
ALL_DENIED_LINES=$(msb logs "$CAGE_Q1" --source system --trace 2>/dev/null | grep -o "denied by network policy domain=[^ ]*" || true)
echo "--- every denied-domain line seen (verbatim) ---"
if [[ -z "$ALL_DENIED_LINES" ]]; then
  echo "(none)"
else
  echo "$ALL_DENIED_LINES"
fi
echo "------------------------------------------------"

DENIED_DEFAULT_HOSTS=""
for _h in "${DEFAULT_HOSTS[@]}"; do
  _hit=$(echo "$ALL_DENIED_LINES" | grep -F "domain=${_h}" || true)
  if [[ -n "$_hit" ]]; then
    DENIED_DEFAULT_HOSTS="${DENIED_DEFAULT_HOSTS}${_hit}"$'\n'
  fi
done
if [[ -z "$DENIED_DEFAULT_HOSTS" ]]; then
  pass "Q1-denials: no denial-log lines name any of the REAL live default hosts (${DEFAULT_HOSTS[*]}) under :443 scoping"
else
  fail "Q1-denials: a real default host was denied under :443 scoping -- acceptance-3 candidate (needs a non-443 port)" "$DENIED_DEFAULT_HOSTS"
fi

# ===========================================================================
# Q1-github443: floor-traffic probe on the SAME port-scoped cage, IF
# github.com is actually one of the live default hosts this run (it is a
# manifest-declared floor host via the seeded gh tool entry, not a
# network.allowed_hosts config entry -- report its absence rather than
# skip silently if the seed ever changes).
# ===========================================================================
echo ""
echo "=== Q1-github443: git floor host (github.com) real-data probe over :443 ==="
if printf '%s\n' "${DEFAULT_HOSTS[@]}" | grep -qxF "github.com"; then
  GH_PROBE=$(msb exec "$CAGE_Q1" -- sh -c "curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://github.com" 2>/tmp/spike-uuh9-q1-gh.err)
  echo "curl result: ${GH_PROBE}"
  GH_CODE="${GH_PROBE%% *}"
  GH_SIZE="${GH_PROBE##* }"
  if [[ "$GH_CODE" == "200" && "$GH_SIZE" -gt 0 ]]; then
    pass "Q1-github443: github.com delivered real bidirectional data over :443 on the port-scoped cage (${GH_PROBE})"
  else
    fail "Q1-github443: github.com did not deliver real data over :443" "${GH_PROBE} err=$(cat /tmp/spike-uuh9-q1-gh.err)"
  fi
else
  fail "Q1-github443: github.com is not in this run's live default host set -- probe not meaningful, reporting rather than papering over" "live_hosts=${DEFAULT_HOSTS[*]}"
fi

# ===========================================================================
# Gap A: a bare `claude -p` turn never contacts doltremoteapi.dolthub.com or
# api.github.com -- their zero-denial result above is SILENCE, not proof
# they work on :443. Functionally touch every remaining live default host on
# the SAME port-scoped cage and report real-data reachability per host, so
# criterion-3 is answered by exercise, not by a host being un-contacted.
# ===========================================================================
echo ""
echo "=== Gap A: functionally exercising every un-contacted floor host on :443 ==="

echo ""
echo "--- Gap A: api.github.com (real JSON body expected) ---"
GH_API_PROBE=$(msb exec "$CAGE_Q1" -- sh -c "curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://api.github.com/" 2>/tmp/spike-uuh9-q1-ghapi.err)
echo "curl result: ${GH_API_PROBE}"
GH_API_CODE="${GH_API_PROBE%% *}"
GH_API_SIZE="${GH_API_PROBE##* }"
if [[ "$GH_API_CODE" == "200" && "$GH_API_SIZE" -gt 0 ]]; then
  pass "Gap-A api.github.com: real JSON body delivered over :443 on the port-scoped cage (${GH_API_PROBE})"
else
  fail "Gap-A api.github.com: did not deliver real data over :443" "${GH_API_PROBE} err=$(cat /tmp/spike-uuh9-q1-ghapi.err)"
fi

if msb exec "$CAGE_Q1" -- sh -c "command -v gh" >/dev/null 2>&1; then
  if msb exec "$CAGE_Q1" -- sh -c "gh auth status" >/dev/null 2>&1; then
    GH_RATE_OUT=$(msb exec "$CAGE_Q1" -- sh -c "gh api /rate_limit" 2>/tmp/spike-uuh9-q1-ghcli.err)
    GH_RATE_RC=$?
    echo "gh api /rate_limit rc=${GH_RATE_RC}"
    if [[ "$GH_RATE_RC" -eq 0 ]] && echo "$GH_RATE_OUT" | jq -e '.resources' >/dev/null 2>&1; then
      pass "Gap-A gh CLI: 'gh api /rate_limit' returned real JSON over :443 (rc=0, .resources present)"
    else
      fail "Gap-A gh CLI: 'gh api /rate_limit' did not return real JSON" "rc=${GH_RATE_RC} out=${GH_RATE_OUT} err=$(cat /tmp/spike-uuh9-q1-ghcli.err)"
    fi
  else
    echo "(gh CLI present but NOT authenticated in this scratch/throwaway cage -- no GH_TOKEN credential was mounted for this spike, this is an auth gap not a network/port-scoping finding. Skipping the gh-CLI sub-probe; the curl-based api.github.com probe above already stands as the real-data :443 reachability evidence for this host.)"
  fi
else
  echo "(gh CLI not present in this image -- curl-only probe above stands as the api.github.com evidence)"
fi

echo ""
echo "--- Gap A: doltremoteapi.dolthub.com (gRPC-over-HTTPS -- real bytes or real HTTP status expected, non-200 is fine, 000/0 is the sharp negative) ---"
DOLT_PROBE=$(msb exec "$CAGE_Q1" -- sh -c "curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://doltremoteapi.dolthub.com/" 2>/tmp/spike-uuh9-q1-dolt.err)
echo "curl result (verbatim): ${DOLT_PROBE}"
DOLT_CODE="${DOLT_PROBE%% *}"
DOLT_SIZE="${DOLT_PROBE##* }"
if [[ "$DOLT_CODE" != "000" ]] || [[ "$DOLT_SIZE" -gt 0 ]]; then
  pass "Gap-A doltremoteapi.dolthub.com: reached the host over :443 (code=${DOLT_CODE} size=${DOLT_SIZE} -- a non-000/non-zero result proves the port reaches the host even if curl can't fully speak the gRPC protocol)"
else
  fail "Gap-A doltremoteapi.dolthub.com: 000/0 -- SHARP NEGATIVE, host unreachable on :443 via plain HTTPS probe" "${DOLT_PROBE} err=$(cat /tmp/spike-uuh9-q1-dolt.err)"
fi

echo ""
echo "--- Gap A: post-probe denial-log check for the two newly-exercised hosts ---"
GAPA_DENIED_LINES=$(msb logs "$CAGE_Q1" --source system --trace 2>/dev/null | grep -o "denied by network policy domain=[^ ]*" || true)
echo "--- every denied-domain line seen after Gap-A probes (verbatim) ---"
if [[ -z "$GAPA_DENIED_LINES" ]]; then
  echo "(none)"
else
  echo "$GAPA_DENIED_LINES"
fi
echo "-----------------------------------------------------------------"
GAPA_HIT=$(echo "$GAPA_DENIED_LINES" | grep -E "domain=(api\.github\.com|doltremoteapi\.dolthub\.com)" || true)
if [[ -z "$GAPA_HIT" ]]; then
  pass "Gap-A denials: neither api.github.com nor doltremoteapi.dolthub.com appear in the denial log after being functionally exercised"
else
  fail "Gap-A denials: one of the newly-exercised hosts WAS denied" "$GAPA_HIT"
fi

msb remove -f "$CAGE_Q1" >/dev/null 2>&1 || true

# ===========================================================================
# Q2-baseline: example.com, ALL PORTS allowed (hand-built, spike-only host),
# :80 must deliver real data -- proves example.com:80 is a live service.
# ===========================================================================
echo ""
echo "=== Q2-baseline: example.com with allow@example.com (all ports), probing :80 ==="
if msb create "$IMAGE" --name "$CAGE_Q2_BASELINE" --log-level trace \
    --net-default deny --net-rule "allow@example.com" >/tmp/spike-uuh9-q2base-boot.err 2>&1; then
  pass "Q2-baseline setup: cage boots with allow@example.com (all ports)"
else
  fail "Q2-baseline setup: cage failed to boot" "$(cat /tmp/spike-uuh9-q2base-boot.err)"
fi
Q2_BASE_80=$(msb exec "$CAGE_Q2_BASELINE" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 http://example.com:80 2>/tmp/spike-uuh9-q2base-80.err)
echo "Q2-baseline example.com:80 result: ${Q2_BASE_80}"
Q2_BASE_80_CODE="${Q2_BASE_80%% *}"
Q2_BASE_80_SIZE="${Q2_BASE_80##* }"
if [[ "$Q2_BASE_80_CODE" == "200" && "$Q2_BASE_80_SIZE" -gt 0 ]]; then
  pass "Q2-baseline: example.com:80 delivered real bidirectional data under the all-ports allow rule (${Q2_BASE_80})"
else
  fail "Q2-baseline: expected real data from example.com:80 under the all-ports allow rule" "${Q2_BASE_80} err=$(cat /tmp/spike-uuh9-q2base-80.err)"
fi
msb remove -f "$CAGE_Q2_BASELINE" >/dev/null 2>&1 || true

# ===========================================================================
# Q2-scoped: example.com, :tcp:443 ONLY (hand-built). Positive control on
# :443 (must be real data) + block probe on :80 (must be zero bytes).
# ===========================================================================
echo ""
echo "=== Q2-scoped: example.com with allow@example.com:tcp:443 ==="
if msb create "$IMAGE" --name "$CAGE_Q2_SCOPED" --log-level trace \
    --net-default deny --net-rule "allow@example.com:tcp:443" >/tmp/spike-uuh9-q2scoped-boot.err 2>&1; then
  pass "Q2-scoped setup: cage boots with allow@example.com:tcp:443"
else
  fail "Q2-scoped setup: cage failed to boot" "$(cat /tmp/spike-uuh9-q2scoped-boot.err)"
fi

Q2_SCOPED_443=$(msb exec "$CAGE_Q2_SCOPED" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://example.com 2>/tmp/spike-uuh9-q2scoped-443.err)
echo "Q2-scoped example.com:443 (positive control) result: ${Q2_SCOPED_443}"
Q2_SCOPED_443_CODE="${Q2_SCOPED_443%% *}"
Q2_SCOPED_443_SIZE="${Q2_SCOPED_443##* }"
if [[ "$Q2_SCOPED_443_CODE" == "200" && "$Q2_SCOPED_443_SIZE" -gt 0 ]]; then
  pass "Q2-scoped-443-control: example.com:443 delivered real bidirectional data under the :443-scoped rule (${Q2_SCOPED_443}) -- host is reachable, isolating any :80 failure to the port"
else
  fail "Q2-scoped-443-control: expected real data from example.com:443 under the :443-scoped rule (positive control)" "${Q2_SCOPED_443} err=$(cat /tmp/spike-uuh9-q2scoped-443.err)"
fi

Q2_SCOPED_80=$(msb exec "$CAGE_Q2_SCOPED" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 http://example.com:80 2>/tmp/spike-uuh9-q2scoped-80.err)
Q2_SCOPED_80_CURL_RC=$?
echo "Q2-scoped example.com:80 (block probe) result: ${Q2_SCOPED_80} (curl rc=${Q2_SCOPED_80_CURL_RC})"
echo "Q2-scoped example.com:80 curl stderr (verbatim, from curl's OWN client-side perspective on the block): $(cat /tmp/spike-uuh9-q2scoped-80.err)"
Q2_SCOPED_80_SIZE="${Q2_SCOPED_80##* }"
if [[ "$Q2_SCOPED_80_SIZE" == "0" ]]; then
  pass "Q2-scoped-80-block: example.com:80 returned ZERO bytes under the :443-scoped rule (${Q2_SCOPED_80}) -- confirmed BLOCKED, not a dead network (baseline+443-control both delivered real data)"
else
  fail "Q2-scoped-80-block: expected zero bytes from example.com:80 under the :443-scoped rule" "${Q2_SCOPED_80}"
fi

# ===========================================================================
# Gap B: is a port-scoped block (an ALLOWED domain hit on the WRONG port)
# observable to the D4 repair loop? The fix-hint miner
# (_msb_denied_domains_from_trace_log, cli/lib/msb_runtime.sh:235-241) keys
# ONLY on the literal pattern
#   DNS query denied by network policy domain=
# A wrong-port drop resolves DNS fine (the domain IS allowed) and drops at
# the NIC/port-match stage -- it likely emits no such line and is INVISIBLE
# to the miner / rc doctor / rc reload fix-hints. Confirm empirically,
# right after the example.com:80 block probe above, on the SAME cage,
# BEFORE removing it.
# ===========================================================================
echo ""
echo "=== Gap B: is the example.com:80 wrong-port block visible to the D4 fix-hint miner? ==="

echo ""
echo "--- Gap B.1: full system-source log dump (msb logs \"\$CAGE_Q2_SCOPED\" --source system) ---"
GAPB_SYSTEM_LOG=$(msb logs "$CAGE_Q2_SCOPED" --source system --trace 2>/dev/null)
echo "$GAPB_SYSTEM_LOG"
echo "--- end system-source log dump ---"

echo ""
echo "--- Gap B.1b: attempting --source all (broader than system, in case a wrong-port drop lands elsewhere) ---"
GAPB_ALL_LOG=$(msb logs "$CAGE_Q2_SCOPED" --source all --trace 2>/dev/null)
echo "$GAPB_ALL_LOG"
echo "--- end --source all log dump ---"

echo ""
echo "--- Gap B.1c: does msb even expose a 'supervisor' log source? ---"
if msb logs "$CAGE_Q2_SCOPED" --source supervisor --trace >/tmp/spike-uuh9-q2-supervisor.err 2>&1; then
  echo "msb logs --source supervisor: accepted (output above would show it, none captured separately since 'all' already supersets known sources)"
else
  echo "msb logs --source supervisor: REJECTED by msb -- $(cat /tmp/spike-uuh9-q2-supervisor.err)"
  echo "(msb --help's --source enum for this msb version is stdout,stderr,output,system,all only -- 'supervisor' is not a valid source)"
fi

echo ""
echo "--- Gap B.2: grep for the miner's EXACT pattern 'DNS query denied by network policy domain=' ---"
MINER_PATTERN_HITS=$(printf '%s\n%s\n' "$GAPB_SYSTEM_LOG" "$GAPB_ALL_LOG" | grep -F "DNS query denied by network policy domain=" || true)
if [[ -z "$MINER_PATTERN_HITS" ]]; then
  pass "Gap-B miner-pattern: the miner's exact DNS-denial pattern is ABSENT for the example.com:80 wrong-port block (confirms the hypothesis -- a wrong-port drop is invisible to _msb_denied_domains_from_trace_log)"
else
  fail "Gap-B miner-pattern: the miner's exact DNS-denial pattern UNEXPECTEDLY matched for the wrong-port block" "$MINER_PATTERN_HITS"
fi

echo ""
echo "--- Gap B.3: grep the full log for ANY mention of the blocked connection (deny|denied|drop|reject|block|:80|port) ---"
GAPB_BROAD_HITS=$(printf '%s\n%s\n' "$GAPB_SYSTEM_LOG" "$GAPB_ALL_LOG" | grep -iE 'deny|denied|drop|reject|block|:80|port' || true)
echo "--- verbatim broad-grep matches (deliverable: what msb actually emits, if anything, for a port-scoped NIC drop) ---"
if [[ -z "$GAPB_BROAD_HITS" ]]; then
  echo "(NOTHING -- msb emits zero log lines of any kind mentioning deny/drop/reject/block/:80/port for this wrong-port connection attempt)"
else
  echo "$GAPB_BROAD_HITS"
fi
echo "----------------------------------------------------------------------------"

echo ""
echo "--- Gap B.3b: filtering out KNOWN non-network noise to surface any GENUINE msb-emitted network-deny candidate ---"
echo "    Noise categories excluded: virtio mmio[block] device-driver interrupts; the guest"
echo "    console device's 'port N' lifecycle lines; the DNS resolver's own UDP-bind 'port=N'"
echo "    line; and (found on inspection) the exec'd curl command's OWN client-side stderr"
echo "    ('curl: (7) Failed to connect to example.com port 80: Connection refused' -- this is"
echo "    my own test probe's stderr, captured ONLY because --source all includes the primary"
echo "    exec session's stdout/stderr; it is NOT an msb-emitted log line and does NOT appear"
echo "    in --source system, which is the only source the real fix-hint miner reads)."
GAPB_FILTERED_HITS=$(printf '%s\n' "$GAPB_BROAD_HITS" | grep -viE 'virtio::mmio\[block\]|virtio::console::(device|process_rx|process_tx)|hickory_proto::udp::udp_stream: binding UDP socket port=|curl: \(7\) Failed to|Connection refused' || true)
if [[ -z "$GAPB_FILTERED_HITS" ]]; then
  echo "(after filtering known non-network noise: ZERO remaining lines)"
  pass "Gap-B broad-scan: verbatim raw dump above is entirely KNOWN non-network noise (virtio block-device interrupts, guest console lifecycle lines, the DNS resolver's own UDP-bind log, and my own curl probe's client-side 'Connection refused' stderr caught only by --source all) -- once that noise is excluded, msb ITSELF emits ZERO log lines of any kind, on any source (system, all), attributable to the example.com:80 wrong-port block. The one substantive finding: curl's OWN client-side view of the wrong-port block is an immediate 'Connection refused' (rc=7) -- NOT a hang -- but that is curl's exec-session stderr, not an msb diagnostic, and is invisible on --source system. The D4 fix-hint miner's exact-pattern check (Gap-B.2, also PASS) already confirmed the miner sees nothing; this broader scan confirms there is no OTHER msb-emitted log line anywhere a smarter miner could key on either -- a wrong-port block on an allowed domain is genuinely invisible to msb's own log output at trace level, not just to the miner's specific DNS-domain pattern."
else
  echo "$GAPB_FILTERED_HITS"
  fail "Gap-B broad-scan: found line(s) NOT matching the known noise patterns -- inspect verbatim, this may be a genuine msb-emitted network-deny signal the miner's pattern misses" "$GAPB_FILTERED_HITS"
fi
echo "----------------------------------------------------------------------------"

msb remove -f "$CAGE_Q2_SCOPED" >/dev/null 2>&1 || true

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
  echo "=== spike-uuh9-port443.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== spike-uuh9-port443.sh: all ${TOTAL} probes passed ==="
