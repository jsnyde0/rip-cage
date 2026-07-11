#!/usr/bin/env bash
# tests/test-msb-flags-effect-probes.sh -- LIVE effect-based proof for the
# config->msb-flags generator (rip-cage-kl4r, S2 of the msb migration epic
# rip-cage-tsf2, cli/lib/msb_flags.sh).
#
# Applies the GENERATOR's emitted flags DIRECTLY via `msb run` (NOT through
# rc's create verb -- that's S6's job; this is the S4<->S6 non-circularity
# pattern documented in docs/2026-07-10-tsf2-decomposition.md). Proves the
# generator's output actually WORKS as containment, not merely that it
# parses -- per the msb fake-accept confound (bd memory
# msb-netstack-fake-accepts-tcp-connect-not-egress) every assertion here is
# real bidirectional application data or its documented absence, NEVER
# connect()-success or a rule appearing in `msb inspect`.
#
# No real secrets are used anywhere -- all "credential" values are synthetic
# sentinel strings generated at run time (grep-safe, never a live token).
#
# Coverage (mirrors the bead's acceptance criteria):
#   C1  allowed host -> REAL bidirectional data; denied host -> ZERO bytes
#       (not connect-success) [criterion 1]
#   C2  a secret bound to host X delivers the real value only on the wire
#       toward X, is absent from guest env/proc/disk; a placeholder toward
#       an unbound-but-allowed host is blocked-and-logged [criterion 2]
#   C3  one credential -> two hosts emits two DISTINCT env-var names and
#       BOTH hosts actually receive the real value on the wire [criterion 3]
#   C4  a possession-mount cage has the real credential file PRESENT
#       in-guest (mixed posture, D5) [criterion 4]
#
# Criterion 5 (--tls-intercept emitted only when body-rewrite declared) and
# criterion 6 (inline ENV=VALUE@HOST rejected at generation) are pure
# generator-output assertions with no live-cage dependency -- already proven
# in tests/test-msb-flags-generator.sh (T8, T5) and not repeated here.
# Criterion 7 (deterministic argv + golden-master snapshots) is also proven
# in test-msb-flags-generator.sh (T9, T10).
#
# NEEDS_CONTAINER + NEEDS_MSB + a live network path to httpbin.org /
# postman-echo.com / example.com / example.org. Self-skips (exit 0, SKIP:
# ...) when any prerequisite is missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GEN="${REPO_ROOT}/cli/lib/msb_flags.sh"
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

# shellcheck disable=SC1090
source "$GEN"

CAGE_C1="kl4r-probe-c1-${RUN_ID}"
CAGE_C23="kl4r-probe-c23-${RUN_ID}"
CAGE_C4="kl4r-probe-c4-${RUN_ID}"
SCRATCH_DIR=$(mktemp -d)

cleanup() {
  msb remove -f "$CAGE_C1" >/dev/null 2>&1 || true
  msb remove -f "$CAGE_C23" >/dev/null 2>&1 || true
  msb remove -f "$CAGE_C4" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH_DIR"
  rm -f /tmp/kl4r-*.err
}
trap cleanup EXIT

# ===========================================================================
# C1: allowed host -> real bidirectional data; denied host -> zero bytes
# ===========================================================================
echo ""
echo "=== C1: generator flags for allowed_hosts=[example.com] -> real data; denied host -> zero bytes ==="
C1_CFG='{"allowed_hosts": ["example.com"]}'
mapfile -t C1_FLAGS < <(_msb_flags_generate "$C1_CFG")
C1_RC=$?
if [[ "$C1_RC" -eq 0 && "${#C1_FLAGS[@]}" -gt 0 ]]; then
  pass "C1 setup: generator produced flags for allowed_hosts config"
else
  fail "C1 setup: generator failed" "rc=$C1_RC flags=${C1_FLAGS[*]:-<empty>}"
fi

if msb run -d --name "$CAGE_C1" --replace "${C1_FLAGS[@]}" "$IMAGE" -- sleep 300 >/tmp/kl4r-c1-boot.err 2>&1; then
  pass "C1 setup: cage boots from generator-emitted flags"
else
  fail "C1 setup: cage failed to boot" "$(cat /tmp/kl4r-c1-boot.err)"
fi

C1_ALLOW_OUT=$(msb exec "$CAGE_C1" -- sh -c 'curl -s --max-time 10 http://example.com/' 2>/tmp/kl4r-c1-allow.err)
if [[ "$C1_ALLOW_OUT" == *"Example Domain"* ]]; then
  pass "C1: allowed host (example.com) returned REAL application data (matched known page content 'Example Domain')"
else
  fail "C1: expected real 'Example Domain' content from allowed host" "got: '${C1_ALLOW_OUT}' stderr: $(cat /tmp/kl4r-c1-allow.err)"
fi

C1_DENY_OUT=$(msb exec "$CAGE_C1" -- sh -c 'curl -s --max-time 8 http://icanhazip.com/' 2>/tmp/kl4r-c1-deny.err)
if [[ -z "$C1_DENY_OUT" ]]; then
  pass "C1: denied host (icanhazip.com, not in allowed_hosts) returned ZERO bytes (not connect-success)"
else
  fail "C1: expected zero bytes from denied host" "got: '${C1_DENY_OUT}'"
fi

msb remove -f "$CAGE_C1" >/dev/null 2>&1 || true

# ===========================================================================
# C2 + C3: secrets -- wire-presence toward bound host(s), guest absence,
# unbound-host block-and-log, and the two-distinct-names footgun guard
# ===========================================================================
echo ""
echo "=== C2+C3: one credential -> two hosts -> two distinct --secret flags, both deliver real value on the wire ==="

# Synthetic sentinel -- never a real credential. Timestamp+pid makes it
# trivially greppable and trivially distinguishable from any real secret.
SENTINEL_VALUE="rc-kl4r-sentinel-$(date +%s)-${RUN_ID}-not-a-real-secret"
export RC_KL4R_SENTINEL="$SENTINEL_VALUE"

C23_CFG='{"allowed_hosts": ["httpbin.org", "postman-echo.com", "example.org"], "credentials": [{"source_env": "RC_KL4R_SENTINEL", "hosts": ["httpbin.org", "postman-echo.com"]}]}'
mapfile -t C23_FLAGS < <(_msb_flags_generate "$C23_CFG")
if [[ "${#C23_FLAGS[@]}" -gt 0 ]]; then
  pass "C2+C3 setup: generator produced flags for the two-host credential config"
else
  fail "C2+C3 setup: generator produced no flags" ""
fi

SYNTH_HTTPBIN=$(_msb_flags_synth_secret_env_name "RC_KL4R_SENTINEL" "1" "httpbin.org")
SYNTH_POSTMAN=$(_msb_flags_synth_secret_env_name "RC_KL4R_SENTINEL" "2" "postman-echo.com")
if [[ "$SYNTH_HTTPBIN" != "$SYNTH_POSTMAN" ]]; then
  pass "C3: the generator synthesized two DISTINCT env-var names for one credential bound to two hosts: '${SYNTH_HTTPBIN}' != '${SYNTH_POSTMAN}'"
else
  fail "C3: expected distinct synthesized names" "both='${SYNTH_HTTPBIN}'"
fi

# Prepare host env under BOTH synthesized names -- MUST be done in this same
# shell (not command substitution) so the exports are visible to `msb run`.
_msb_flags_prepare_secret_env "$C23_CFG"

if msb run -d --name "$CAGE_C23" --replace "${C23_FLAGS[@]}" --on-secret-violation block-and-log "$IMAGE" -- sleep 300 >/tmp/kl4r-c23-boot.err 2>&1; then
  pass "C2+C3 setup: cage boots from generator-emitted secret flags"
else
  fail "C2+C3 setup: cage failed to boot" "$(cat /tmp/kl4r-c23-boot.err)"
fi

# --- guest-side absence: env holds only the placeholder ---
C2_GUEST_ENV=$(msb exec "$CAGE_C23" -- sh -c "eval echo \\\$${SYNTH_HTTPBIN}")
if [[ "$C2_GUEST_ENV" == "\$MSB_"* && "$C2_GUEST_ENV" != *"$SENTINEL_VALUE"* ]]; then
  pass "C2: guest env holds only the placeholder ('${C2_GUEST_ENV}'), never the real sentinel value"
else
  fail "C2: expected guest env to show a \$MSB_ placeholder, not the real value" "$C2_GUEST_ENV"
fi

# --- guest-side absence: /proc/1/environ unreadable or placeholder-only ---
C2_PROC_OUT=$(msb exec "$CAGE_C23" -- sh -c "grep -a '${SENTINEL_VALUE}' /proc/1/environ" 2>&1)
if [[ "$C2_PROC_OUT" != *"$SENTINEL_VALUE"* ]]; then
  pass "C2: /proc/1/environ does not expose the real sentinel value (unreadable or no match)"
else
  fail "C2: real sentinel value found in /proc/1/environ" "$C2_PROC_OUT"
fi

# --- guest-side absence: no copy of the real value on guest disk ---
C2_DISK_OUT=$(msb exec "$CAGE_C23" -- sh -c "grep -ra '${SENTINEL_VALUE}' / --exclude-dir=proc" 2>/dev/null)
if [[ -z "$C2_DISK_OUT" ]]; then
  pass "C2: no guest-disk file contains the real sentinel value"
else
  fail "C2: real sentinel value found on guest disk" "$C2_DISK_OUT"
fi

# --- wire-presence toward BOTH bound hosts (criterion 3's live half) ---
C3_HTTPBIN_RESP=$(msb exec "$CAGE_C23" -- sh -c "curl -sS --max-time 10 https://httpbin.org/headers -H \"X-Sentinel: \$${SYNTH_HTTPBIN}\"" 2>/tmp/kl4r-c3-httpbin.err)
if [[ "$C3_HTTPBIN_RESP" == *"$SENTINEL_VALUE"* ]]; then
  pass "C3: httpbin.org (host X) received the REAL sentinel value on the wire (echoed back in its response)"
else
  fail "C3: expected the real sentinel value echoed back by httpbin.org" "resp='${C3_HTTPBIN_RESP}' stderr=$(cat /tmp/kl4r-c3-httpbin.err)"
fi

C3_POSTMAN_RESP=$(msb exec "$CAGE_C23" -- sh -c "curl -sS --max-time 10 https://postman-echo.com/get -H \"X-Sentinel: \$${SYNTH_POSTMAN}\"" 2>/tmp/kl4r-c3-postman.err)
if [[ "$C3_POSTMAN_RESP" == *"$SENTINEL_VALUE"* ]]; then
  pass "C3: postman-echo.com (host Y) ALSO received the REAL sentinel value on the wire (guards the silent double-block footgun -- both hosts actually work)"
else
  fail "C3: expected the real sentinel value echoed back by postman-echo.com" "resp='${C3_POSTMAN_RESP}' stderr=$(cat /tmp/kl4r-c3-postman.err)"
fi

# --- unbound-host negative control: send the httpbin-bound placeholder
# toward example.org (allowed at the network layer, but NOT secret-bound)
# -> blocked, and a WARN secret-violation log line names the disallowed host.
C2_UNBOUND_OUT=$(msb exec "$CAGE_C23" -- sh -c "curl -sS -o /dev/null -w 'HTTP_CODE=%{http_code}' --max-time 10 https://example.org/ -H \"X-Sentinel: \$${SYNTH_HTTPBIN}\"" 2>&1)
if [[ "$C2_UNBOUND_OUT" == *"HTTP_CODE=000"* || "$C2_UNBOUND_OUT" == *"curl:"* ]]; then
  pass "C2: sending the placeholder toward an unbound-but-allowed host (example.org) is BLOCKED (no successful response)"
else
  fail "C2: expected the unbound-host request to be blocked" "$C2_UNBOUND_OUT"
fi

C2_LOG=$(msb logs "$CAGE_C23" --source system --json 2>/dev/null | grep -i "secret violation" | grep -F "example.org" || true)
if [[ -n "$C2_LOG" ]]; then
  pass "C2: host-side WARN secret-violation log line names the disallowed host (example.org): captured"
else
  fail "C2: expected a secret-violation WARN log line naming example.org" "$(msb logs "$CAGE_C23" --source system --json 2>/dev/null | grep -i secret || echo '<no secret log lines found>')"
fi

msb remove -f "$CAGE_C23" >/dev/null 2>&1 || true
unset RC_KL4R_SENTINEL "$SYNTH_HTTPBIN" "$SYNTH_POSTMAN"

# ===========================================================================
# C4: possession mount -- the real credential file is PRESENT in-guest
# (D5 mixed posture: pi keeps a real mounted auth.json even under a
# non-possession default elsewhere)
# ===========================================================================
echo ""
echo "=== C4: possession_mounts -> real credential file present in-guest (mixed posture, D5) ==="
POSSESSION_CONTENT='{"fake_credential": "not-a-real-secret-rc-kl4r-possession-test"}'
printf '%s' "$POSSESSION_CONTENT" > "${SCRATCH_DIR}/auth.json"

C4_CFG=$(jq -nc --arg hp "${SCRATCH_DIR}/auth.json" '{"possession_mounts": [{"host_path": $hp, "guest_path": "/home/agent/.pi/agent/auth.json", "kind": "file"}]}')
mapfile -t C4_FLAGS < <(_msb_flags_generate "$C4_CFG")
if [[ "${#C4_FLAGS[@]}" -gt 0 ]]; then
  pass "C4 setup: generator produced --mount-file flags for the possession-mount config"
else
  fail "C4 setup: generator produced no flags" ""
fi

if msb run -d --name "$CAGE_C4" --replace "${C4_FLAGS[@]}" "$IMAGE" -- sleep 300 >/tmp/kl4r-c4-boot.err 2>&1; then
  pass "C4 setup: cage boots from generator-emitted possession-mount flags"
else
  fail "C4 setup: cage failed to boot" "$(cat /tmp/kl4r-c4-boot.err)"
fi

C4_GUEST_CONTENT=$(msb exec "$CAGE_C4" -- sh -c 'cat /home/agent/.pi/agent/auth.json' 2>/tmp/kl4r-c4-cat.err)
if [[ "$C4_GUEST_CONTENT" == "$POSSESSION_CONTENT" ]]; then
  pass "C4: the REAL credential file content is present in-guest at the declared possession-mount path (mixed posture preserved)"
else
  fail "C4: expected the real mounted file content in-guest" "got: '${C4_GUEST_CONTENT}' stderr: $(cat /tmp/kl4r-c4-cat.err)"
fi

msb remove -f "$CAGE_C4" >/dev/null 2>&1 || true

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-flags-effect-probes.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-flags-effect-probes.sh: all ${TOTAL} tests passed ==="
