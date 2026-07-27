#!/usr/bin/env bash
# tests/test-denial-visibility.sh -- rip-cage-jlu4: denial-visibility
# disambiguation. msb's egress denials and its SECRET-VIOLATION blocks
# (a caught credential-misdirection / exfil attempt -- a substituted
# secret's placeholder sent toward a DISALLOWED host, blocked by
# `--on-secret-violation block-and-log`) are in-guest indistinguishable,
# and both land in the host-side msb trace log. The trace-log miner
# (_msb_denied_domains_from_trace_log, cli/lib/msb_runtime.sh) mines only
# DNS-policy denials and turns them into "add <host> to the allowlist"
# fix-hints. If a secret-violation line were mined the same way, an
# operator following the hint would CONVERT A CAUGHT EXFIL INTO AN ALLOWED
# ONE. This file proves BOTH denial kinds are mined DISTINCTLY, and that
# BOTH consumers (cli/doctor.sh, cli/reload.sh) present a secret-violation
# as a WARNING, NEVER an allowlist suggestion.
#
# Exact log-line shapes (host-tier synthetic fixtures, no live cage) are
# taken VERBATIM from the confirmed spikes (not guessed):
#   DNS-policy denial (docs/2026-07-09-msb-spike-egress-observability.md §3):
#     {"d":"DEBUG microsandbox_network::dns::forwarder: DNS query denied by
#     network policy domain=www.wikipedia.org\n", "s":"system", "t":"..."}
#   Secret violation (same doc §3 AND
#     history/2026-07-26-secret-posture-spikes.md S3):
#     {"d":"WARN microsandbox_network::secrets::handler: secret violation:
#     placeholder detected for disallowed host action=block-and-log
#     secret_env_var=MSB_SPIKE_TOKEN placeholder=$MSB_MSB_SPIKE_TOKEN
#     protocol=http/1.1 sni=example.org host=example.org method=GET path=/
#     location=header match_form=raw guest_dst=172.66.157.237:443
#     http2_stream_id=\n", "s":"system", "t":"..."}
#
# Coverage:
#   M1  Miner: _msb_denied_domains_from_trace_log, fed a log with BOTH
#       lines, returns ONLY the DNS-denied domain (never the
#       secret-violation host).
#   M2  Miner: _msb_secret_violations_from_trace_log (new sibling miner),
#       fed the SAME mixed log, returns ONLY the secret-violation host
#       (never the DNS-denied domain).
#   M3  Miner: zero-violation log -> _msb_secret_violations_from_trace_log
#       echoes empty, exit 0 (same pipefail-safety contract as the DNS
#       miner -- rip-cage-5iti R7's regression class).
#   D1  cli/doctor.sh's _doctor_format_posture_probe, given the mixed log,
#       prints the DNS domain as the existing allowlist-add fix-hint AND a
#       DISTINCT WARNING naming the secret-violation host, and the
#       WARNING clause never contains an "rc allowlist add <violation
#       host>" suggestion.
#   R1  cli/reload.sh's `rc reload --dry-run`, given the mixed log, prints
#       the existing "Fix-hint: recently denied domain(s)" block for the
#       DNS domain AND a distinct WARNING line naming the secret-violation
#       host, and never suggests allowlisting the secret-violation host.
#
# Wired into tests/run-host.sh (host-only tier, no live cage needed).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
MSB_LIB="${REPO_ROOT}/cli/lib/msb_runtime.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== test-denial-visibility.sh ==="
echo ""

DV_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rc-denial-visibility-XXXXXX")
cleanup() { rm -rf "$DV_TMP"; }
trap cleanup EXIT

# The mixed synthetic trace log: ONE DNS-policy denial line (domain=
# denied-dns.example.invalid) + ONE secret-violation line (host=
# secret-violated.example.invalid), verbatim-shaped per the spikes cited
# above. Reused by every case below.
# shellcheck disable=SC2016 # deliberately single-quoted: $MSB_SPIKE_TOKEN is
# literal text from the real log line, not a shell expansion here.
MIXED_LOG_JSON='{"d":"DEBUG microsandbox_network::dns::forwarder: DNS query denied by network policy domain=denied-dns.example.invalid\n", "s":"system", "t":"2026-07-26T00:00:00.000Z"}
{"d":"WARN microsandbox_network::secrets::handler: secret violation: placeholder detected for disallowed host action=block-and-log secret_env_var=SPIKE_TOKEN placeholder=$MSB_SPIKE_TOKEN protocol=http/1.1 sni=secret-violated.example.invalid host=secret-violated.example.invalid method=GET path=/ location=header match_form=raw guest_dst=172.66.147.243:443 http2_stream_id=\n", "s":"system", "t":"2026-07-26T00:00:01.000Z"}'

# msb stub whose `logs` subcommand echoes the mixed log above, regardless
# of sandbox name (single-fixture stub -- every case below uses ONE cage
# name, "dv-cage").
MIXED_STUB_DIR="${DV_TMP}/mixed-stub"
mkdir -p "$MIXED_STUB_DIR"
cat > "${MIXED_STUB_DIR}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) cat <<'LOG'
${MIXED_LOG_JSON}
LOG
    exit 0 ;;
  inspect)
    echo '{"status":"Running","config":{"labels":{"rc.source.path":""},"network":{"policy":{"default_egress":"deny","rules":[]}}},"updated_at":""}'
    exit 0 ;;
esac
echo "stub: unhandled msb args: \$*" >&2
exit 1
STUB
chmod +x "${MIXED_STUB_DIR}/msb"

# ---------------------------------------------------------------------------
# M1/M2/M3: the two miners, called directly against the mixed-log stub.
# ---------------------------------------------------------------------------
echo "-- M1/M2/M3: miner-level extraction, mixed synthetic trace log --"

M1_OUT=$(PATH="${MIXED_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  _msb_denied_domains_from_trace_log 'dv-cage'
")
if [[ "$M1_OUT" == "denied-dns.example.invalid" ]]; then
  pass "M1a: DNS miner returns exactly the DNS-denied domain"
else
  fail "M1a: DNS miner returns exactly the DNS-denied domain" "got: '$M1_OUT'"
fi
if [[ "$M1_OUT" != *"secret-violated"* ]]; then
  pass "M1b: DNS miner does NOT leak the secret-violation host"
else
  fail "M1b: DNS miner does NOT leak the secret-violation host" "got: '$M1_OUT'"
fi

M2_OUT=$(PATH="${MIXED_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  _msb_secret_violations_from_trace_log 'dv-cage'
")
if [[ "$M2_OUT" == "secret-violated.example.invalid" ]]; then
  pass "M2a: secret-violation miner returns exactly the violation host"
else
  fail "M2a: secret-violation miner returns exactly the violation host" "got: '$M2_OUT'"
fi
if [[ "$M2_OUT" != *"denied-dns"* ]]; then
  pass "M2b: secret-violation miner does NOT leak the DNS-denied domain"
else
  fail "M2b: secret-violation miner does NOT leak the DNS-denied domain" "got: '$M2_OUT'"
fi

# M3: zero-violation log -- empty output, exit 0 under set -euo pipefail
# (same contract as the DNS miner's rip-cage-5iti R7 regression guard).
EMPTY_STUB_DIR="${DV_TMP}/empty-stub"
mkdir -p "$EMPTY_STUB_DIR"
cat > "${EMPTY_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) exit 0 ;;
esac
echo "stub: unhandled msb args: $*" >&2
exit 1
STUB
chmod +x "${EMPTY_STUB_DIR}/msb"

M3_EXIT=0
M3_OUT=$(PATH="${EMPTY_STUB_DIR}:$PATH" bash -c '
  set -euo pipefail
  source "'"$MSB_LIB"'"
  _v=$(_msb_secret_violations_from_trace_log "dv-cage")
  echo "M3_REACHED_END:[${_v}]"
' 2>&1) || M3_EXIT=$?
if [[ "$M3_EXIT" -eq 0 && "$M3_OUT" == *"M3_REACHED_END:[]"* ]]; then
  pass "M3: zero-violation call under set -euo pipefail does not abort the caller (empty output, exit 0)"
else
  fail "M3: zero-violation call under set -euo pipefail does not abort the caller" "exit=${M3_EXIT} out='${M3_OUT}'"
fi

echo ""

# ---------------------------------------------------------------------------
# D1: cli/doctor.sh's _doctor_format_posture_probe, mixed log.
# ---------------------------------------------------------------------------
echo "-- D1: rc doctor's posture probe distinguishes the two denial kinds --"

DOCTOR_RC="${REPO_ROOT}/cli/doctor.sh"
D1_OUT=$(PATH="${MIXED_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  source '$DOCTOR_RC'
  _doctor_format_posture_probe 'dv-cage' ''
")

if [[ "$D1_OUT" == *"denied-dns.example.invalid"* ]]; then
  pass "D1a: posture probe still surfaces the DNS-denied domain"
else
  fail "D1a: posture probe still surfaces the DNS-denied domain" "got: $D1_OUT"
fi
if [[ "$D1_OUT" == *"secret-violated.example.invalid"* ]]; then
  pass "D1b: posture probe names the secret-violation host"
else
  fail "D1b: posture probe names the secret-violation host" "got: $D1_OUT"
fi
if echo "$D1_OUT" | grep -qi "WARN"; then
  pass "D1c: posture probe marks the secret-violation clause as a WARNING"
else
  fail "D1c: posture probe marks the secret-violation clause as a WARNING" "got: $D1_OUT"
fi
if [[ "$D1_OUT" != *"allowlist add secret-violated.example.invalid"* ]]; then
  pass "D1d: posture probe NEVER suggests 'rc allowlist add' for the secret-violation host"
else
  fail "D1d: posture probe NEVER suggests 'rc allowlist add' for the secret-violation host" "got: $D1_OUT"
fi

echo ""

# ---------------------------------------------------------------------------
# R1: cli/reload.sh's `rc reload --dry-run`, mixed log.
# ---------------------------------------------------------------------------
echo "-- R1: rc reload --dry-run distinguishes the two denial kinds --"

R1_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-denial-visibility-reload-XXXXXX")
R1_WS="${R1_HOME}/workspace"
R1_CNAME="dv-reload-cage"
R1_CACHE_DIR="${R1_HOME}/.cache/rip-cage/${R1_CNAME}"
mkdir -p "$R1_WS" "${R1_HOME}/.config/rip-cage" "$R1_CACHE_DIR"

cat > "${R1_WS}/.rip-cage.yaml" <<'YML'
version: 2
network:
  allowed_hosts: [switch.berlin]
YML

# msb stub for the reload invocation: `inspect` must report a RUNNING cage
# whose rc.source.path label resolves to R1_WS (cmd_reload's live gates),
# `logs` echoes the SAME mixed log as above.
R1_STUB_DIR="${R1_HOME}/stub"
mkdir -p "$R1_STUB_DIR"
cat > "${R1_STUB_DIR}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) cat <<'LOG'
${MIXED_LOG_JSON}
LOG
    exit 0 ;;
esac
case " \$* " in
  *" inspect "*"${R1_CNAME}"*)
    echo '{"status":"Running","config":{"labels":{"rc.source.path":"${R1_WS}"}}}'
    exit 0 ;;
  *)
    echo "stub: unhandled msb args: \$*" >&2
    exit 1 ;;
esac
STUB
chmod +x "${R1_STUB_DIR}/msb"

# Snapshot with no allowed_hosts yet, so the dry-run has a real diff to
# print (mirrors test-rc-reload.sh's C4 dry-run fixture pattern).
cat > "${R1_CACHE_DIR}/config-applied.json" <<'JSON'
{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}
JSON

R1_OUT=$(PATH="${R1_STUB_DIR}:$PATH" HOME="$R1_HOME" XDG_CONFIG_HOME="${R1_HOME}/.config" "$RC" reload "$R1_CNAME" --dry-run 2>&1)
R1_EXIT=$?

if [[ "$R1_EXIT" -eq 0 ]]; then
  pass "R1a: rc reload --dry-run exits 0 against the mixed-log stub"
else
  fail "R1a: rc reload --dry-run exits 0 against the mixed-log stub" "exit=${R1_EXIT} out: $R1_OUT"
fi
if echo "$R1_OUT" | grep -q "domain=denied-dns.example.invalid"; then
  pass "R1b: reload dry-run still prints the existing DNS-denied fix-hint"
else
  fail "R1b: reload dry-run still prints the existing DNS-denied fix-hint" "got: $R1_OUT"
fi
if echo "$R1_OUT" | grep -q "secret-violated.example.invalid"; then
  pass "R1c: reload dry-run names the secret-violation host"
else
  fail "R1c: reload dry-run names the secret-violation host" "got: $R1_OUT"
fi
if echo "$R1_OUT" | grep -qi "WARNING"; then
  pass "R1d: reload dry-run marks the secret-violation line as a WARNING"
else
  fail "R1d: reload dry-run marks the secret-violation line as a WARNING" "got: $R1_OUT"
fi
if [[ "$R1_OUT" != *"allowlist add secret-violated.example.invalid"* ]]; then
  pass "R1e: reload dry-run NEVER suggests 'rc allowlist add' for the secret-violation host"
else
  fail "R1e: reload dry-run NEVER suggests 'rc allowlist add' for the secret-violation host" "got: $R1_OUT"
fi

rm -rf "$R1_HOME"

echo ""
echo "=== test-denial-visibility.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
