#!/usr/bin/env bash
# tests/test-msb-flags-generator.sh -- unit tests for the config->msb-flags
# generator (rip-cage-kl4r, S2 of the msb migration epic rip-cage-tsf2).
#
# Pure-function tests: no live docker/msb daemon needed. The generator takes
# a normalized JSON intent structure (allowed_hosts, credentials, mounts,
# possession_mounts, tls_body_rewrite) and emits msb argv tokens -- one per
# line, mirroring tests/golden-master's up-run-args-*.argv convention -- so
# the output can be fed straight into `mapfile -t FLAGS < <(...)` and passed
# to `msb run "${FLAGS[@]}"`.
#
# Live effect-based proof (criteria 1-5 of the bead: real allow/deny data,
# secret wire-presence/guest-absence, possession-mount file presence,
# tls-intercept conditional) lives in tests/test-msb-flags-effect-probes.sh,
# which needs a live docker+msb+image and self-skips otherwise.
#
# This file covers:
#   T1  allowed_hosts only -> --net-default deny + one --net-rule allow@host
#       per host, in declared order
#   T2  empty config -> --net-default deny only (no rules, no crash)
#   T3  a single credential/single host -> one --secret <SYNTH>@<host> flag,
#       SYNTH is a bare token (no '=' in it) derived from source_env
#   T4  one credential -> two hosts emits two DISTINCT --secret ENV@HOST
#       flags (guards the silent double-block footgun -- D3 constraint 2)
#   T5  inline ENV=VALUE@HOST in source_env is REJECTED at generation --
#       non-zero exit, no --secret flag emitted, error text does not leak the
#       value portion (D3 constraint 1 / bead criterion 6)
#   T6  possession_mounts emits --mount-file SRC:DST (mixed posture, D5)
#   T7  mounts (kind=dir) emits --mount-dir SRC:DST
#   T8  tls_body_rewrite=true -> --tls-intercept emitted; absent/false -> not
#       emitted (bead criterion 5)
#   T9  determinism: same config run twice -> byte-identical output (bead
#       criterion 7)
#   T10 golden-master argv snapshot cases (à la up-run-args-*.argv) for a
#       representative full config -- byte-level regression net

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GEN="${REPO_ROOT}/cli/lib/msb_flags.sh"
SNAP_DIR="${SCRIPT_DIR}/golden-master/snapshots"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available -- skipping $(basename "$0")"
  exit 0
fi

# shellcheck disable=SC1090
source "$GEN"

# ---------------------------------------------------------------------------
# T1: allowed_hosts only
# ---------------------------------------------------------------------------
echo ""
echo "=== T1: allowed_hosts -> --net-default deny + --net-rule allow@host per host, in order ==="
T1_CFG='{"allowed_hosts": ["github.com", "api.anthropic.com"]}'
T1_OUT=$(_msb_flags_generate "$T1_CFG")
T1_RC=$?
T1_EXPECTED=$'--net-default\ndeny\n--net-rule\nallow@github.com\n--net-rule\nallow@api.anthropic.com'
if [[ "$T1_RC" -eq 0 ]]; then
  pass "T1: exits 0"
else
  fail "T1: expected exit 0, got $T1_RC" "$T1_OUT"
fi
if [[ "$T1_OUT" == "$T1_EXPECTED" ]]; then
  pass "T1b: emits --net-default deny + one --net-rule allow@host per host, in declared order"
else
  fail "T1b: argv mismatch" "expected:
$T1_EXPECTED
got:
$T1_OUT"
fi


# ---------------------------------------------------------------------------
# T2: empty config -> --net-default deny only (no rules, no crash)
# ---------------------------------------------------------------------------
echo ""
echo "=== T2: empty config -> --net-default deny only ==="
T2_OUT=$(_msb_flags_generate '{}')
T2_RC=$?
T2_EXPECTED=$'--net-default\ndeny'
if [[ "$T2_RC" -eq 0 ]]; then
  pass "T2: exits 0 on empty config"
else
  fail "T2: expected exit 0, got $T2_RC" "$T2_OUT"
fi
if [[ "$T2_OUT" == "$T2_EXPECTED" ]]; then
  pass "T2b: emits exactly --net-default deny, nothing else"
else
  fail "T2b: argv mismatch" "expected:
$T2_EXPECTED
got:
$T2_OUT"
fi


# ---------------------------------------------------------------------------
# T3: a single credential/single host -> one --secret <SYNTH>@<host> flag,
# SYNTH is a bare token derived from source_env (no '=' in it, contains the
# source_env name so it's debuggable in msb inspect/logs).
# ---------------------------------------------------------------------------
echo ""
echo "=== T3: single credential/single host -> one --secret SYNTH@host flag ==="
T3_CFG='{"credentials": [{"source_env": "GH_TOKEN", "hosts": ["github.com"]}]}'
T3_OUT=$(_msb_flags_generate "$T3_CFG")
T3_RC=$?
if [[ "$T3_RC" -eq 0 ]]; then
  pass "T3: exits 0"
else
  fail "T3: expected exit 0, got $T3_RC" "$T3_OUT"
fi
T3_SECRET_LINE=$(printf '%s\n' "$T3_OUT" | grep -A1 -- '^--secret$' | tail -1)
if [[ "$T3_SECRET_LINE" == GH_TOKEN*@github.com ]]; then
  pass "T3b: --secret value starts with GH_TOKEN and targets @github.com: '${T3_SECRET_LINE}'"
else
  fail "T3b: expected a --secret line shaped 'GH_TOKEN...@github.com'" "got: '${T3_SECRET_LINE}' full output: $T3_OUT"
fi
if [[ "$T3_SECRET_LINE" != *=* ]]; then
  pass "T3c: --secret value contains no '=' (bare ENV@HOST form only)"
else
  fail "T3c: --secret value must not contain '='" "$T3_SECRET_LINE"
fi


# ---------------------------------------------------------------------------
# T4: one credential -> two hosts emits two DISTINCT --secret ENV@HOST flags
# (guards the silent double-block footgun -- D3 constraint 2 / bead
# criterion 3's structural half; the live wire-delivery half is proven in
# the effect-probe suite).
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: one credential -> two hosts -> two DISTINCT --secret ENV@HOST flags ==="
T4_CFG='{"credentials": [{"source_env": "CCTOK", "hosts": ["api.anthropic.com", "mcp-proxy.anthropic.com"]}]}'
T4_OUT=$(_msb_flags_generate "$T4_CFG")
T4_SECRET_LINES=$(printf '%s\n' "$T4_OUT" | grep -A1 -- '^--secret$' | grep -v -- '^--secret$' | grep -v '^--$')
T4_COUNT=$(printf '%s\n' "$T4_SECRET_LINES" | grep -c .)
if [[ "$T4_COUNT" -eq 2 ]]; then
  pass "T4: exactly two --secret flags emitted for one credential bound to two hosts"
else
  fail "T4: expected 2 --secret lines, got $T4_COUNT" "$T4_OUT"
fi
T4_ENV1=$(printf '%s\n' "$T4_SECRET_LINES" | sed -n '1p' | cut -d@ -f1)
T4_ENV2=$(printf '%s\n' "$T4_SECRET_LINES" | sed -n '2p' | cut -d@ -f1)
if [[ -n "$T4_ENV1" && -n "$T4_ENV2" && "$T4_ENV1" != "$T4_ENV2" ]]; then
  pass "T4b: the two synthesized env-var names are DISTINCT: '${T4_ENV1}' != '${T4_ENV2}'"
else
  fail "T4b: expected two distinct env-var names" "env1='${T4_ENV1}' env2='${T4_ENV2}'"
fi
if printf '%s\n' "$T4_SECRET_LINES" | grep -qF '@api.anthropic.com' && printf '%s\n' "$T4_SECRET_LINES" | grep -qF '@mcp-proxy.anthropic.com'; then
  pass "T4c: both target hosts are present (api.anthropic.com AND mcp-proxy.anthropic.com)"
else
  fail "T4c: expected both hosts represented" "$T4_SECRET_LINES"
fi


# ---------------------------------------------------------------------------
# T5: inline ENV=VALUE@HOST in source_env is REJECTED at generation --
# non-zero exit, NO flags emitted at all (fail whole), and the error text
# does not leak the value portion of the malformed source_env (D3 constraint
# 1 / bead criterion 6).
# ---------------------------------------------------------------------------
echo ""
echo "=== T5: inline ENV=VALUE@HOST is REJECTED at generation ==="
T5_SECRET_LOOKING_VALUE="ghp_TOTALLYFAKESENTINELVALUE12345"
T5_CFG=$(jq -nc --arg v "GH_TOKEN=${T5_SECRET_LOOKING_VALUE}" '{"credentials": [{"source_env": $v, "hosts": ["github.com"]}]}')
T5_ERR=$(_msb_flags_generate "$T5_CFG" 2>&1 1>/dev/null)
T5_OUT=$(_msb_flags_generate "$T5_CFG" 2>/dev/null)
T5_RC=0
_msb_flags_generate "$T5_CFG" >/dev/null 2>&1 || T5_RC=$?
if [[ "$T5_RC" -ne 0 ]]; then
  pass "T5: exits non-zero on inline ENV=VALUE@HOST"
else
  fail "T5: expected non-zero exit" "rc=$T5_RC"
fi
if [[ -z "$T5_OUT" ]]; then
  pass "T5b: NO flags emitted at all (fail whole, not a partial flag set with the bad credential silently dropped)"
else
  fail "T5b: expected empty stdout" "$T5_OUT"
fi
if [[ "$T5_ERR" != *"$T5_SECRET_LOOKING_VALUE"* ]]; then
  pass "T5c: the error text does NOT contain the value-looking portion of the malformed source_env"
else
  fail "T5c: error text leaked the value portion -- this must never happen" "$T5_ERR"
fi
if [[ "$T5_ERR" == *"ENV=VALUE@HOST"* || "$T5_ERR" == *"="* ]]; then
  pass "T5d: error names the actual problem (actionable, not generic)"
else
  fail "T5d: expected an actionable error mentioning the rejected inline form" "$T5_ERR"
fi


# ---------------------------------------------------------------------------
# T6: possession_mounts emits --mount-file SRC:DST (D5 mixed posture -- pi
# keeps a real mounted auth.json even under a non-possession default
# elsewhere).
# ---------------------------------------------------------------------------
echo ""
echo "=== T6: possession_mounts -> --mount-file SRC:DST ==="
T6_CFG='{"possession_mounts": [{"host_path": "/Users/x/.pi/agent/auth.json", "guest_path": "/home/agent/.pi/agent/auth.json", "kind": "file"}]}'
T6_OUT=$(_msb_flags_generate "$T6_CFG")
T6_EXPECTED_TAIL=$'--mount-file\n/Users/x/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json'
if [[ "$T6_OUT" == *"$T6_EXPECTED_TAIL"* ]]; then
  pass "T6: emits --mount-file /Users/x/.pi/agent/auth.json:/home/agent/.pi/agent/auth.json"
else
  fail "T6: expected --mount-file line pair" "$T6_OUT"
fi


# ---------------------------------------------------------------------------
# T7: general mounts (kind=dir, default) emits --mount-dir SRC:DST, and
# possession_mounts are emitted BEFORE general mounts (fixed section order).
# ---------------------------------------------------------------------------
echo ""
echo "=== T7: mounts (kind=dir) -> --mount-dir SRC:DST; ordered after possession_mounts ==="
T7_CFG='{"possession_mounts": [{"host_path": "/h/auth.json", "guest_path": "/g/auth.json", "kind": "file"}], "mounts": [{"host_path": "/h/workspace", "guest_path": "/workspace"}]}'
T7_OUT=$(_msb_flags_generate "$T7_CFG")
T7_EXPECTED=$'--net-default\ndeny\n--mount-file\n/h/auth.json:/g/auth.json\n--mount-dir\n/h/workspace:/workspace'
if [[ "$T7_OUT" == "$T7_EXPECTED" ]]; then
  pass "T7: possession_mounts then mounts, --mount-dir for default kind"
else
  fail "T7: argv mismatch" "expected:
$T7_EXPECTED
got:
$T7_OUT"
fi


# ---------------------------------------------------------------------------
# T8: tls_body_rewrite=true -> --tls-intercept emitted (as the LAST token);
# absent/false -> --tls-intercept never appears (bead criterion 5).
# ---------------------------------------------------------------------------
echo ""
echo "=== T8: --tls-intercept emitted ONLY when tls_body_rewrite is true ==="
T8_TRUE_OUT=$(_msb_flags_generate '{"tls_body_rewrite": true}')
if printf '%s\n' "$T8_TRUE_OUT" | grep -qxF -- '--tls-intercept'; then
  pass "T8: tls_body_rewrite=true emits --tls-intercept"
else
  fail "T8: expected --tls-intercept in output" "$T8_TRUE_OUT"
fi
T8_FALSE_OUT=$(_msb_flags_generate '{"tls_body_rewrite": false}')
if ! printf '%s\n' "$T8_FALSE_OUT" | grep -qxF -- '--tls-intercept'; then
  pass "T8b: tls_body_rewrite=false does NOT emit --tls-intercept"
else
  fail "T8b: --tls-intercept must not appear when tls_body_rewrite=false" "$T8_FALSE_OUT"
fi
T8_ABSENT_OUT=$(_msb_flags_generate '{}')
if ! printf '%s\n' "$T8_ABSENT_OUT" | grep -qxF -- '--tls-intercept'; then
  pass "T8c: tls_body_rewrite absent (default) does NOT emit --tls-intercept"
else
  fail "T8c: --tls-intercept must not appear when tls_body_rewrite is absent" "$T8_ABSENT_OUT"
fi


# ---------------------------------------------------------------------------
# T9: determinism -- the same config run twice (fresh process each time, no
# shared state) produces byte-identical output (bead criterion 7).
# ---------------------------------------------------------------------------
echo ""
echo "=== T9: determinism -- identical config -> byte-identical output across repeated runs ==="
T9_CFG='{"allowed_hosts": ["github.com", "api.anthropic.com", "mcp-proxy.anthropic.com"], "credentials": [{"source_env": "GH_TOKEN", "hosts": ["github.com", "api.github.com"]}, {"source_env": "CCTOK", "hosts": ["api.anthropic.com"]}], "possession_mounts": [{"host_path": "/h/.pi/agent/auth.json", "guest_path": "/g/.pi/agent/auth.json", "kind": "file"}], "mounts": [{"host_path": "/h/workspace", "guest_path": "/workspace"}], "tls_body_rewrite": true}'
T9_RUN1=$(bash -c "source '${GEN}'; _msb_flags_generate '${T9_CFG}'")
T9_RUN2=$(bash -c "source '${GEN}'; _msb_flags_generate '${T9_CFG}'")
T9_RUN3=$(bash -c "source '${GEN}'; _msb_flags_generate '${T9_CFG}'")
if [[ "$T9_RUN1" == "$T9_RUN2" && "$T9_RUN2" == "$T9_RUN3" ]]; then
  pass "T9: three independent process runs of the same config produce byte-identical argv"
else
  fail "T9: output differs across repeated runs of the same config" "run1:
$T9_RUN1
run2:
$T9_RUN2
run3:
$T9_RUN3"
fi

# ---------------------------------------------------------------------------
# T10: golden-master argv snapshot cases (à la tests/golden-master's
# up-run-args-*.argv) -- byte-level regression net for the msb flag surface
# during the cutover-branch window (bead criterion 7). Snapshot files live
# under tests/golden-master/snapshots/msb-flags-<case>.argv (distinct
# filename prefix from the existing docker-argv up-run-args-*.argv cases --
# additive only, this suite never touches the existing capture.sh/cases.sh
# framework or its snapshot files).
#
# Run with GM_RECORD=1 to (re-)record the baseline after a deliberate,
# reviewed change to the generator's output shape.
# ---------------------------------------------------------------------------
echo ""
echo "=== T10: golden-master argv snapshot cases ==="
mkdir -p "$SNAP_DIR"

gm_check_case() {
  local case_name="$1" cfg="$2"
  local snap_file="${SNAP_DIR}/msb-flags-${case_name}.argv"
  local out
  out=$(_msb_flags_generate "$cfg")
  if [[ "${GM_RECORD:-0}" == "1" ]]; then
    printf '%s\n' "$out" > "$snap_file"
    pass "T10 [${case_name}]: RECORDED baseline at ${snap_file}"
    return
  fi
  if [[ ! -f "$snap_file" ]]; then
    fail "T10 [${case_name}]: no recorded snapshot -- run with GM_RECORD=1 first" "expected: $snap_file"
    return
  fi
  local expected
  expected=$(cat "$snap_file")
  if [[ "$out" == "$expected" ]]; then
    pass "T10 [${case_name}]: argv matches recorded golden-master snapshot byte-for-byte"
  else
    fail "T10 [${case_name}]: argv DRIFTED from recorded snapshot" "$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$out"))"
  fi
}

# Case: full-chain -- allowed_hosts + multi-host credential + possession
# mount + general mount + tls-intercept, representative of a real cage.
GM_FULL_CFG='{"allowed_hosts": ["github.com", "api.anthropic.com"], "credentials": [{"source_env": "GH_TOKEN", "hosts": ["github.com", "api.github.com"]}], "possession_mounts": [{"host_path": "/h/.pi/agent/auth.json", "guest_path": "/g/.pi/agent/auth.json", "kind": "file"}], "mounts": [{"host_path": "/h/workspace", "guest_path": "/workspace"}], "tls_body_rewrite": true}'
gm_check_case "full-chain" "$GM_FULL_CFG"

# Case: minimal -- empty config (the S1-boot-only floor: default-deny, nothing else).
gm_check_case "minimal" '{}'

# Case: secret-only-nonpossession -- D5 default posture, single host binding.
GM_SECRET_CFG='{"allowed_hosts": ["api.anthropic.com"], "credentials": [{"source_env": "CCTOK", "hosts": ["api.anthropic.com"]}]}'
gm_check_case "secret-nonpossession" "$GM_SECRET_CFG"


# ---------------------------------------------------------------------------
# T11: _msb_flags_prepare_secret_env -- the companion that makes the emitted
# --secret flags actually FUNCTIONAL. msb reads a secret's real value from a
# host env var whose name is the ENV half of ENV@HOST, at `msb run` start
# time. Since this generator always SYNTHESIZES a distinct ENV name per
# (credential, host) pair (never the bare source_env), the host environment
# must be populated under each synthesized name too -- this helper does
# that, by copying the CURRENT value of source_env into each synthesized
# name. MUST be invoked in the same shell as the eventual `msb run` (never
# via command substitution, which would export into a throwaway subshell).
# ---------------------------------------------------------------------------
echo ""
echo "=== T11: _msb_flags_prepare_secret_env exports the source value under every synthesized name ==="
# NOTE: this is a structural placeholder-shaped string, never a real
# credential -- exercising the export mechanism only.
export T11_SOURCE_VAR="placeholder-test-value-not-a-real-secret"
T11_CFG='{"credentials": [{"source_env": "T11_SOURCE_VAR", "hosts": ["host-a.example.com", "host-b.example.com"]}]}'
_msb_flags_prepare_secret_env "$T11_CFG"
T11_NAME_A=$(_msb_flags_synth_secret_env_name "T11_SOURCE_VAR" "1" "host-a.example.com")
T11_NAME_B=$(_msb_flags_synth_secret_env_name "T11_SOURCE_VAR" "2" "host-b.example.com")
T11_VAL_A="${!T11_NAME_A:-}"
T11_VAL_B="${!T11_NAME_B:-}"
if [[ "$T11_VAL_A" == "placeholder-test-value-not-a-real-secret" && "$T11_VAL_B" == "placeholder-test-value-not-a-real-secret" ]]; then
  pass "T11: both synthesized env vars hold the source value in the CURRENT shell"
else
  fail "T11: expected both synthesized vars to hold the source value" "val_a='${T11_VAL_A}' val_b='${T11_VAL_B}'"
fi
unset T11_SOURCE_VAR "$T11_NAME_A" "$T11_NAME_B"

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-flags-generator.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-flags-generator.sh: all ${TOTAL} tests passed ==="
