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
#   T12 structural check (rip-cage-3vj2, S4 engine-deletion sweep): the
#       generator's emitted argv for a representative full config contains
#       NO engine call/reference -- no egress/credential/DNS/mediator engine
#       argv, env, or in-cage hook path (ADR-029 D2). This generator only
#       ever emitted msb primitives to begin with; this test is the
#       structural, permanent guard against that regressing.

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

# ---------------------------------------------------------------------------
# T12 (rip-cage-3vj2, S4 engine-deletion sweep, bead acceptance criterion 2):
# direct structural check that the generator's emitted argv for a
# representative full config contains NO engine call -- no egress/
# credential/DNS/mediator engine argv, env, or in-cage hook path reference
# remains. Covers every deleted-engine surface: the router/DNS/egress
# Python modules, iptables/ip6tables firewall init, the mediator launch
# machinery + its RC_MEDIATOR/--mediator-env channel, and the deleted
# MEDIATOR archetype name itself.
# ---------------------------------------------------------------------------
echo ""
echo "=== T12: structural check -- generated argv contains NO engine call (ADR-029 D2) ==="
T12_CFG='{"allowed_hosts": ["github.com", "api.anthropic.com"], "credentials": [{"source_env": "GH_TOKEN", "hosts": ["github.com", "api.github.com"]}], "possession_mounts": [{"host_path": "/h/.pi/agent/auth.json", "guest_path": "/g/.pi/agent/auth.json", "kind": "file"}], "mounts": [{"host_path": "/h/workspace", "guest_path": "/workspace"}], "tls_body_rewrite": true, "dind_volumes": [{"name": "docker-data", "guest_path": "/var/lib/docker", "size": "20G"}]}'
T12_OUT=$(_msb_flags_generate "$T12_CFG")
if [[ -n "$T12_OUT" ]]; then
  pass "T12 setup: generator produced non-empty argv for the representative full config"
else
  fail "T12 setup: generator produced no argv" ""
fi

# Each pattern names a distinct deleted-engine surface (case-insensitive).
T12_ENGINE_PATTERNS=(
  "rip_cage_router"
  "rip_cage_egress"
  "rip_cage_dns"
  "init-firewall"
  "init-mediator"
  "rip-proxy"
  "rip-dns-start"
  "iptables"
  "ip6tables"
  "RC_MEDIATOR"
  "mediator-env"
  "MEDIATOR"
  "egress-rules.yaml"
)
T12_ALL_CLEAN=1
for T12_PAT in "${T12_ENGINE_PATTERNS[@]}"; do
  T12_HIT=$(printf '%s\n' "$T12_OUT" | grep -iF "$T12_PAT" || true)
  if [[ -n "$T12_HIT" ]]; then
    T12_ALL_CLEAN=0
    fail "T12: generated argv contains a deleted-engine reference ('${T12_PAT}')" "$T12_HIT"
  fi
done
if [[ "$T12_ALL_CLEAN" -eq 1 ]]; then
  pass "T12: generated argv contains NO engine reference across all ${#T12_ENGINE_PATTERNS[@]} deleted-engine surfaces (router/egress/DNS Python modules, iptables/ip6tables firewall init, RC_MEDIATOR/--mediator-env channel, MEDIATOR archetype name, egress-rules.yaml in-cage path)"
fi

echo ""
echo "=== T13: _msb_flags_preflight_secret_env (rip-cage-rj68 S6 Fold b) ==="
# S6 Fold b: _msb_flags_prepare_secret_env (existing, untouched) exports the
# host source_env's CURRENT value under each synthesized name -- including
# an EMPTY STRING when the host var is unset, which would silently boot a
# cage carrying a placeholder-substituted empty secret with no error
# anywhere. _msb_flags_preflight_secret_env is the NEW guard a caller runs
# BEFORE invoking msb: it must fail loud, non-zero, naming the offending
# var, whenever a credential's source_env is unset OR set-empty in the host
# environment -- and succeed silently when every source_env is
# set-and-non-empty.
T13_CFG='{"credentials": [{"source_env": "T13_TOKEN_A", "hosts": ["a.example.com"]}, {"source_env": "T13_TOKEN_B", "hosts": ["b.example.com"]}]}'

# T13a: both source_envs set and non-empty -> succeeds silently, exit 0.
unset T13_TOKEN_A T13_TOKEN_B 2>/dev/null || true
export T13_TOKEN_A="real-value-a"
export T13_TOKEN_B="real-value-b"
T13A_OUT=$(_msb_flags_preflight_secret_env "$T13_CFG" 2>&1)
T13A_RC=$?
if [[ "$T13A_RC" -eq 0 && -z "$T13A_OUT" ]]; then
  pass "T13a: all source_envs set+non-empty -> exit 0, silent"
else
  fail "T13a: expected exit 0 + silent" "rc=$T13A_RC out='$T13A_OUT'"
fi
unset T13_TOKEN_A T13_TOKEN_B

# T13b: one source_env UNSET entirely -> non-zero exit, error names the var.
export T13_TOKEN_A="real-value-a"
unset T13_TOKEN_B 2>/dev/null || true
T13B_OUT=$(_msb_flags_preflight_secret_env "$T13_CFG" 2>&1)
T13B_RC=$?
if [[ "$T13B_RC" -ne 0 ]] && echo "$T13B_OUT" | grep -q "T13_TOKEN_B"; then
  pass "T13b: unset source_env -> non-zero exit, error names T13_TOKEN_B"
else
  fail "T13b: expected non-zero exit naming T13_TOKEN_B" "rc=$T13B_RC out='$T13B_OUT'"
fi
unset T13_TOKEN_A

# T13c: one source_env set to EMPTY STRING -> non-zero exit, error names the var
# (distinct from unset -- an exported empty var is the exact silent-empty-secret
# footgun _msb_flags_prepare_secret_env would otherwise carry through unnoticed).
export T13_TOKEN_A="real-value-a"
export T13_TOKEN_B=""
T13C_OUT=$(_msb_flags_preflight_secret_env "$T13_CFG" 2>&1)
T13C_RC=$?
if [[ "$T13C_RC" -ne 0 ]] && echo "$T13C_OUT" | grep -q "T13_TOKEN_B"; then
  pass "T13c: empty-string source_env -> non-zero exit, error names T13_TOKEN_B"
else
  fail "T13c: expected non-zero exit naming T13_TOKEN_B" "rc=$T13C_RC out='$T13C_OUT'"
fi
unset T13_TOKEN_A T13_TOKEN_B

# T13d: no credentials declared at all -> exit 0, silent (nothing to check).
T13D_OUT=$(_msb_flags_preflight_secret_env '{}' 2>&1)
T13D_RC=$?
if [[ "$T13D_RC" -eq 0 && -z "$T13D_OUT" ]]; then
  pass "T13d: no credentials declared -> exit 0, silent"
else
  fail "T13d: expected exit 0 + silent for empty config" "rc=$T13D_RC out='$T13D_OUT'"
fi

# T13e: never echoes the real value anywhere (even in the success/failure path).
export T13_TOKEN_A="super-secret-value-should-never-appear"
unset T13_TOKEN_B 2>/dev/null || true
T13E_OUT=$(_msb_flags_preflight_secret_env "$T13_CFG" 2>&1)
if ! echo "$T13E_OUT" | grep -q "super-secret-value-should-never-appear"; then
  pass "T13e: never echoes a real credential value, even alongside a failure"
else
  fail "T13e: real value leaked into preflight output" "$T13E_OUT"
fi
unset T13_TOKEN_A


# ---------------------------------------------------------------------------
# T14: target_env (rip-cage-9dlw) -- the guest-env bridge. A credential with a
# target_env list emits, IN ADDITION to its --secret flag, one `-e
# <TARGET>=$MSB_<synth>` per target name, so a tool that reads a FIXED env var
# (e.g. claude reads CLAUDE_CODE_OAUTH_TOKEN) receives the exact placeholder
# string msb watches for on the wire. <synth> is the SAME synthesized name the
# --secret flag uses for that credential's single host, so the two carry the
# identical placeholder. NO tool name is hardcoded in rc -- the operator's
# config names the target var (ADR-005 D12).
# ---------------------------------------------------------------------------
echo ""
echo "=== T14: target_env emits -e TARGET=\$MSB_<synth> bridging the fixed var ==="
T14_CFG='{"credentials": [{"source_env": "CCTOK", "hosts": ["api.anthropic.com"], "target_env": ["CLAUDE_CODE_OAUTH_TOKEN"]}]}'
T14_OUT=$(_msb_flags_generate "$T14_CFG")
T14_RC=$?
if [[ "$T14_RC" -eq 0 ]]; then
  pass "T14: exits 0"
else
  fail "T14: expected exit 0, got $T14_RC" "$T14_OUT"
fi
# The --secret flag still emits (bridge is additive, not a replacement).
if printf '%s\n' "$T14_OUT" | grep -A1 -- '^--secret$' | grep -qx 'CCTOK__1_API_ANTHROPIC_COM@api.anthropic.com'; then
  pass "T14b: --secret CCTOK__1_API_ANTHROPIC_COM@api.anthropic.com still emitted"
else
  fail "T14b: expected the --secret flag alongside the bridge" "$T14_OUT"
fi
T14_ENV_LINE=$(printf '%s\n' "$T14_OUT" | grep -A1 -- '^-e$' | tail -1)
# SC2016: the single quotes are INTENTIONAL -- the emitted value is the LITERAL
# string `$MSB_...` (msb's placeholder), which must NOT expand here.
# shellcheck disable=SC2016
if [[ "$T14_ENV_LINE" == 'CLAUDE_CODE_OAUTH_TOKEN=$MSB_CCTOK__1_API_ANTHROPIC_COM' ]]; then
  pass "T14c: -e line bridges the fixed var to the exact synth placeholder: '${T14_ENV_LINE}'"
else
  fail "T14c: bridge -e line mismatch" "expected 'CLAUDE_CODE_OAUTH_TOKEN=\$MSB_CCTOK__1_API_ANTHROPIC_COM' got '${T14_ENV_LINE}'"
fi
T14_E_COUNT=$(printf '%s\n' "$T14_OUT" | grep -cx -- '-e')
if [[ "$T14_E_COUNT" -eq 1 ]]; then
  pass "T14d: exactly one -e flag for one target_env name"
else
  fail "T14d: expected exactly 1 -e flag, got $T14_E_COUNT" "$T14_OUT"
fi

# T14e: two target names -> two -e bridge lines, both to the same synth.
T14E_CFG='{"credentials": [{"source_env": "CCTOK", "hosts": ["api.anthropic.com"], "target_env": ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"]}]}'
T14E_OUT=$(_msb_flags_generate "$T14E_CFG")
T14E_E_COUNT=$(printf '%s\n' "$T14E_OUT" | grep -cx -- '-e')
# shellcheck disable=SC2016  # literal $MSB_ placeholder must not expand (see T14c)
if [[ "$T14E_E_COUNT" -eq 2 ]] \
  && printf '%s\n' "$T14E_OUT" | grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=$MSB_CCTOK__1_API_ANTHROPIC_COM' \
  && printf '%s\n' "$T14E_OUT" | grep -qx 'ANTHROPIC_AUTH_TOKEN=$MSB_CCTOK__1_API_ANTHROPIC_COM'; then
  pass "T14e: two target names -> two -e bridge lines, both to the same synth placeholder"
else
  fail "T14e: expected two -e bridge lines to the same synth" "$T14E_OUT"
fi

# T14f: a credential with NO target_env emits zero -e flags (bridge is opt-in;
# git-PAT-style bindings that need no fixed-var bridge are unaffected).
T14F_CFG='{"credentials": [{"source_env": "GH_TOKEN", "hosts": ["github.com"]}]}'
T14F_OUT=$(_msb_flags_generate "$T14F_CFG")
if [[ "$(printf '%s\n' "$T14F_OUT" | grep -cx -- '-e')" -eq 0 ]]; then
  pass "T14f: no target_env -> zero -e flags (bridge is opt-in)"
else
  fail "T14f: expected zero -e flags without target_env" "$T14F_OUT"
fi


# ---------------------------------------------------------------------------
# T15: target_env on a MULTI-host credential is REJECTED at generation (fail
# whole, no flags). A fixed guest var can hold exactly ONE placeholder string;
# a credential bound to N hosts has N DISTINCT synth placeholders -- populating
# one target var from N of them is ambiguous and would silently swap correctly
# for only one host. Loud rejection, not a silent wrong-host bridge.
# ---------------------------------------------------------------------------
echo ""
echo "=== T15: target_env + multi-host -> REJECTED at generation (fail whole) ==="
T15_CFG='{"credentials": [{"source_env": "CCTOK", "hosts": ["api.anthropic.com", "mcp-proxy.anthropic.com"], "target_env": ["CLAUDE_CODE_OAUTH_TOKEN"]}]}'
T15_ERR=$(_msb_flags_generate "$T15_CFG" 2>&1 1>/dev/null)
T15_OUT=$(_msb_flags_generate "$T15_CFG" 2>/dev/null)
T15_RC=0
_msb_flags_generate "$T15_CFG" >/dev/null 2>&1 || T15_RC=$?
if [[ "$T15_RC" -ne 0 ]]; then
  pass "T15: exits non-zero on target_env + multi-host"
else
  fail "T15: expected non-zero exit" "rc=$T15_RC"
fi
if [[ -z "$T15_OUT" ]]; then
  pass "T15b: NO flags emitted at all (fail whole)"
else
  fail "T15b: expected empty stdout" "$T15_OUT"
fi
if [[ "$T15_ERR" == *"target_env"* ]]; then
  pass "T15c: error names target_env (actionable)"
else
  fail "T15c: expected an actionable error mentioning target_env" "$T15_ERR"
fi


# ---------------------------------------------------------------------------
# T16: source_file (rip-cage-9dlw) -- host token-file sourcing for autonomy. A
# credential may declare source_file instead of requiring a pre-exported host
# env var; rc reads the real value from that file host-side into msb's --secret
# machinery only (never guest FS/env, never printed). Sentinel values only --
# never a real token.
# ---------------------------------------------------------------------------
echo ""
echo "=== T16: source_file sourcing (prepare + preflight), sentinel values only ==="
T16_SENTINEL="sentinel-file-token-DO-NOT-LOG"
T16_FILE=$(mktemp)
printf '%s' "$T16_SENTINEL" > "$T16_FILE"
T16_CFG=$(jq -nc --arg f "$T16_FILE" '{"credentials": [{"source_env": "CCTOK", "source_file": $f, "hosts": ["api.anthropic.com"]}]}')

# T16a: prepare exports the synth var with the FILE's value (no host env var set).
unset CCTOK CCTOK__1_API_ANTHROPIC_COM 2>/dev/null || true
_msb_flags_prepare_secret_env "$T16_CFG"
if [[ "${CCTOK__1_API_ANTHROPIC_COM:-}" == "$T16_SENTINEL" ]]; then
  pass "T16a: prepare sources the value from source_file into the synth name"
else
  fail "T16a: synth var not populated from file" "got '${CCTOK__1_API_ANTHROPIC_COM:-<unset>}'"
fi
unset CCTOK__1_API_ANTHROPIC_COM 2>/dev/null || true

# T16b: preflight passes (exit 0, silent) when source_file exists + non-empty,
# even though the host env var CCTOK is unset.
unset CCTOK 2>/dev/null || true
T16B_OUT=$(_msb_flags_preflight_secret_env "$T16_CFG" 2>&1)
T16B_RC=$?
if [[ "$T16B_RC" -eq 0 && -z "$T16B_OUT" ]]; then
  pass "T16b: preflight passes on a non-empty source_file (no host env var needed)"
else
  fail "T16b: expected exit 0 + silent" "rc=$T16B_RC out='$T16B_OUT'"
fi

# T16c: preflight fails loud when source_file path does not exist; error names
# the PATH (a path is not secret), never a value.
T16C_MISSING="${T16_FILE}.does-not-exist"
T16C_CFG=$(jq -nc --arg f "$T16C_MISSING" '{"credentials": [{"source_env": "CCTOK", "source_file": $f, "hosts": ["api.anthropic.com"]}]}')
T16C_OUT=$(_msb_flags_preflight_secret_env "$T16C_CFG" 2>&1)
T16C_RC=$?
if [[ "$T16C_RC" -ne 0 ]] && printf '%s' "$T16C_OUT" | grep -qF "$T16C_MISSING"; then
  pass "T16c: missing source_file -> non-zero exit, error names the path"
else
  fail "T16c: expected non-zero exit naming the missing path" "rc=$T16C_RC out='$T16C_OUT'"
fi

# T16d: preflight fails loud when source_file exists but is EMPTY.
T16D_FILE=$(mktemp)  # empty
T16D_CFG=$(jq -nc --arg f "$T16D_FILE" '{"credentials": [{"source_env": "CCTOK", "source_file": $f, "hosts": ["api.anthropic.com"]}]}')
T16D_OUT=$(_msb_flags_preflight_secret_env "$T16D_CFG" 2>&1)
T16D_RC=$?
if [[ "$T16D_RC" -ne 0 ]]; then
  pass "T16d: empty source_file -> non-zero exit"
else
  fail "T16d: expected non-zero exit on empty source_file" "rc=$T16D_RC out='$T16D_OUT'"
fi

# T16e: neither prepare nor preflight ever echoes the file's value.
unset CCTOK__1_API_ANTHROPIC_COM 2>/dev/null || true
T16E_OUT=$( { _msb_flags_prepare_secret_env "$T16_CFG"; _msb_flags_preflight_secret_env "$T16_CFG"; } 2>&1 )
if ! printf '%s' "$T16E_OUT" | grep -qF "$T16_SENTINEL"; then
  pass "T16e: neither prepare nor preflight echoes the source_file value"
else
  fail "T16e: source_file value leaked into output" "$T16E_OUT"
fi
unset CCTOK__1_API_ANTHROPIC_COM 2>/dev/null || true
rm -f "$T16_FILE" "$T16D_FILE"


echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-flags-generator.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-flags-generator.sh: all ${TOTAL} tests passed ==="
