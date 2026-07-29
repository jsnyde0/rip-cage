#!/usr/bin/env bash
# Host-side tests for `rc allowlist` subcommand (rip-cage-hhh.6).
#
# Coverage:
#   A1  allowlist add appends a host to .rip-cage.yaml (new file created)
#   A2  allowlist add is idempotent — adding the same host twice = one entry
#   A3  allowlist add --output json shape: {action, host, config_file}
#   A4  allowlist add --output json with skipped host: action=skipped
#   A5  allowlist show lists configured network.allowed_hosts
#   A6  allowlist show --observed is retired: exits non-zero + prints the
#       retirement message to stderr (rip-cage-tsf2.2 loud-fail stub — the
#       in-cage egress log producer was deleted in the msb migration, so
#       this flag can no longer silently report "(none)")
#   A7  allowlist show --observed retirement message names ADR-029 and the
#       fast-follow bead rip-cage-tsf2.2
#   A8  allowlist promote --from-observed is retired: exits non-zero + prints
#       the retirement message to stderr
#   A9  allowlist promote --from-observed retirement message names ADR-029
#       and the fast-follow bead rip-cage-tsf2.2
#   A10 allowlist promote --from-observed never mutates .rip-cage.yaml — the
#       retirement guard fires before any log read or config write, so there
#       is no silent partial apply
#   A11 add refuses when /etc/rip-cage/release present (simulated D10 host-side-only guard)
#   A12 promote refuses when /etc/rip-cage/release present (simulated D10 guard)
#   A13 allowlist show --output json shape: {allowed_hosts: [...]}
#
# Tests run entirely host-side (no docker required). D10 guard simulated by
# setting RC_TEST_FAKE_CAGE_MARKER=1 (same pattern as test-rc-reload.sh would use
# for the in-cage environment detection).
#
# ADRs: ADR-003 D1/D4/D5 (agent-first CLI), ADR-021 D4 (effective-config provenance),
#        ADR-022 D6 (host-side-only pattern), epic D10/D11.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0
TEST_HOME=""

pass() { echo "PASS A$1: $2"; }
fail() { echo "FAIL A$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build a sandbox HOME and workspace.
# Globals set: TEST_HOME, WS
setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-allowlist-test-XXXXXX")
  WS="${TEST_HOME}/workspace"
  mkdir -p "$WS"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" WS=""
}

# Run rc with sandboxed HOME.
run_rc() {
  HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    "$RC" "$@"
}

# Run rc with fake in-cage-marker detection (simulates in-cage).
run_rc_in_cage() {
  HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_TEST_FAKE_CAGE_MARKER=1 \
    "$RC" "$@"
}

# Write a synthetic egress log with deny/would-block and allow events.
write_egress_log() {
  local log_path="$1"
  mkdir -p "$(dirname "$log_path")"
  cat > "$log_path" <<'JSONL'
{"timestamp":"2026-05-27T10:00:00Z","event":"deny","rule_id":"not-whitelisted","method":"GET","host":"registry.example.com","path":"/","container_hostname":"cage1","pattern":"allowed_hosts","target":"registry.example.com","why":"Host not in allowed_hosts","fix_command":"rc allowlist add registry.example.com","config_file":".rip-cage.yaml","config_path":"network.allowed_hosts"}
{"timestamp":"2026-05-27T10:01:00Z","event":"allow","rule_id":"","method":"GET","host":"api.anthropic.com","path":"/","container_hostname":"cage1","pattern":null,"target":"api.anthropic.com","why":null,"fix_command":null,"config_file":null,"config_path":null}
{"timestamp":"2026-05-27T10:02:00Z","event":"would-block","rule_id":"not-whitelisted","method":"POST","host":"cdn.staging.myapp.io","path":"/upload","container_hostname":"cage1","pattern":"allowed_hosts","target":"cdn.staging.myapp.io","why":"Host not in allowed_hosts","fix_command":"rc allowlist add cdn.staging.myapp.io","config_file":".rip-cage.yaml","config_path":"network.allowed_hosts"}
{"timestamp":"2026-05-27T10:03:00Z","event":"deny","rule_id":"not-whitelisted","method":"GET","host":"registry.example.com","path":"/v2","container_hostname":"cage1","pattern":"allowed_hosts","target":"registry.example.com","why":"Host not in allowed_hosts","fix_command":"rc allowlist add registry.example.com","config_file":".rip-cage.yaml","config_path":"network.allowed_hosts"}
JSONL
}

# Create a PATH-shim `msb` stub in $1 that answers `msb inspect <cage>` with a
# recorded rc.source.path label = $3 (workspace) and status $4 (default Stopped,
# so the auto-reload sub-call early-exits cleanly rather than recreating).
# Any cage name != $2 -> inspect fails (not found). rip-cage-e25p.
make_msb_stub() {
  local stubdir="$1" cage="$2" ws="$3" status="${4:-Stopped}"
  mkdir -p "$stubdir"
  cat > "${stubdir}/msb" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" inspect "*)
    if printf '%s ' "\$@" | grep -q -- "${cage}"; then
      printf '%s\n' '{"status":"${status}","config":{"labels":{"rc.source.path":"${ws}"}}}'
      exit 0
    fi
    exit 1 ;;
  *) echo "stub msb: unhandled: \$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "${stubdir}/msb"
}

# Run rc from a given CWD with the msb-stub dir prepended to PATH (child
# `rc reload` inherits both). Globals: TEST_HOME.
run_rc_from() {
  local cwd="$1" stubdir="$2"; shift 2
  ( cd "$cwd" && HOME="$TEST_HOME" \
      XDG_CONFIG_HOME="${TEST_HOME}/.config" \
      PATH="${stubdir}:$PATH" \
      "$RC" "$@" )
}

# ---------------------------------------------------------------------------
# A1: allowlist add appends a host to .rip-cage.yaml (new file created)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a1_out=$(run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>&1)
a1_exit=$?
a1_ok=true a1_reason=""
[[ "$a1_exit" -ne 0 ]] && a1_ok=false && a1_reason="exit $a1_exit; output: $a1_out"
if [[ "$a1_ok" == "true" ]]; then
  if ! grep -q "cdn.example.com" "${WS}/.rip-cage.yaml" 2>/dev/null; then
    a1_ok=false; a1_reason="cdn.example.com not found in .rip-cage.yaml"
  fi
fi
if [[ "$a1_ok" == "true" ]]; then pass 1 "allowlist add creates .rip-cage.yaml with host"
else fail 1 "allowlist add" "$a1_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A2: allowlist add is idempotent — adding same host twice = one entry
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
a2_count=$(grep -c "cdn.example.com" "${WS}/.rip-cage.yaml" 2>/dev/null || echo 0)
a2_ok=true a2_reason=""
[[ "$a2_count" -ne 1 ]] && a2_ok=false && a2_reason="host appears $a2_count times (want 1)"
if [[ "$a2_ok" == "true" ]]; then pass 2 "allowlist add idempotent (two adds = one entry)"
else fail 2 "allowlist add idempotent" "$a2_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A3: allowlist add --output json shape: {action, host, config_file}
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a3_out=$(run_rc --output json allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a3_exit=$?
a3_ok=true a3_reason=""
[[ "$a3_exit" -ne 0 ]] && a3_ok=false && a3_reason="exit $a3_exit"
if [[ "$a3_ok" == "true" ]]; then
  a3_action=$(echo "$a3_out" | jq -r '.action' 2>/dev/null)
  a3_host=$(echo "$a3_out" | jq -r '.host' 2>/dev/null)
  a3_cf=$(echo "$a3_out" | jq -r '.config_file' 2>/dev/null)
  [[ "$a3_action" != "added" ]] && a3_ok=false && a3_reason="action=${a3_action} (want 'added')"
  [[ "$a3_host" != "cdn.example.com" ]] && a3_ok=false && a3_reason="${a3_reason:+$a3_reason; }host=${a3_host}"
  [[ -z "$a3_cf" || "$a3_cf" == "null" ]] && a3_ok=false && a3_reason="${a3_reason:+$a3_reason; }config_file missing"
fi
if [[ "$a3_ok" == "true" ]]; then pass 3 "allowlist add --output json shape: action=added, host, config_file"
else fail 3 "allowlist add json shape" "$a3_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A4: allowlist add --output json with skipped host: action=skipped
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

run_rc allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
a4_out=$(run_rc --output json allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a4_exit=$?
a4_ok=true a4_reason=""
[[ "$a4_exit" -ne 0 ]] && a4_ok=false && a4_reason="exit $a4_exit"
if [[ "$a4_ok" == "true" ]]; then
  a4_action=$(echo "$a4_out" | jq -r '.action' 2>/dev/null)
  [[ "$a4_action" != "skipped" ]] && a4_ok=false && a4_reason="action=${a4_action} (want 'skipped')"
fi
if [[ "$a4_ok" == "true" ]]; then pass 4 "allowlist add --output json: action=skipped when already present"
else fail 4 "allowlist add skipped json" "$a4_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A5: allowlist show lists configured network.allowed_hosts
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 2
network:
  allowed_hosts:
    - registry.npmjs.org
    - example.org
YML
a5_out=$(run_rc --output json allowlist show --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a5_exit=$?
a5_ok=true a5_reason=""
[[ "$a5_exit" -ne 0 ]] && a5_ok=false && a5_reason="exit $a5_exit"
if [[ "$a5_ok" == "true" ]]; then
  a5_count=$(echo "$a5_out" | jq -r '.allowed_hosts | length' 2>/dev/null)
  [[ "$a5_count" -ne 2 ]] && a5_ok=false && a5_reason="allowed_hosts count=${a5_count} (want 2)"
  echo "$a5_out" | jq -r '.allowed_hosts[]' 2>/dev/null | grep -q "registry.npmjs.org" || {
    a5_ok=false; a5_reason="${a5_reason:+$a5_reason; }registry.npmjs.org not in list"; }
fi
if [[ "$a5_ok" == "true" ]]; then pass 5 "allowlist show --output json lists configured network.allowed_hosts"
else fail 5 "allowlist show json" "$a5_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A6: allowlist show --observed is retired -- exits non-zero, prints message to stderr
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

write_egress_log "${WS}/.rip-cage/egress.log"
a6_err=$(mktemp)
a6_out=$(run_rc --output json allowlist show --observed --log-file "${WS}/.rip-cage/egress.log" 2>"$a6_err")
a6_exit=$?
a6_ok=true a6_reason=""
[[ "$a6_exit" -eq 0 ]] && a6_ok=false && a6_reason="exit 0 (want non-zero -- --observed must fail loud, not silently report)"
[[ -z "$(cat "$a6_err")" ]] && a6_ok=false && a6_reason="${a6_reason:+$a6_reason; }no stderr output emitted"
if [[ "$a6_ok" == "true" ]]; then pass 6 "allowlist show --observed exits non-zero + writes to stderr (retired)"
else fail 6 "allowlist show --observed retirement" "$a6_reason -- stdout: $a6_out stderr: $(cat "$a6_err")"; fi
rm -f "$a6_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A7: allowlist show --observed retirement message names ADR-029 + fast-follow bead
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a7_err=$(mktemp)
run_rc allowlist show --observed >/dev/null 2>"$a7_err"
a7_ok=true a7_reason=""
grep -qi "retired" "$a7_err" || { a7_ok=false; a7_reason="stderr does not say 'retired'"; }
grep -q "ADR-029" "$a7_err" || { a7_ok=false; a7_reason="${a7_reason:+$a7_reason; }stderr does not cite ADR-029"; }
grep -q "rip-cage-tsf2.2" "$a7_err" || { a7_ok=false; a7_reason="${a7_reason:+$a7_reason; }stderr does not point at fast-follow bead rip-cage-tsf2.2"; }
if [[ "$a7_ok" == "true" ]]; then pass 7 "allowlist show --observed message names ADR-029 + rip-cage-tsf2.2"
else fail 7 "allowlist show --observed message content" "$a7_reason -- stderr: $(cat "$a7_err")"; fi
rm -f "$a7_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A8: allowlist promote --from-observed is retired -- exits non-zero, prints message to stderr
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 2
network:
  allowed_hosts:
    - already.allowed.com
  mode: observe
YML
write_egress_log "${WS}/.rip-cage/egress.log"

a8_err=$(mktemp)
run_rc allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" >/dev/null 2>"$a8_err"
a8_exit=$?
a8_ok=true a8_reason=""
[[ "$a8_exit" -eq 0 ]] && a8_ok=false && a8_reason="exit 0 (want non-zero -- --from-observed must fail loud, not silently apply nothing)"
[[ -z "$(cat "$a8_err")" ]] && a8_ok=false && a8_reason="${a8_reason:+$a8_reason; }no stderr output emitted"
if [[ "$a8_ok" == "true" ]]; then pass 8 "allowlist promote --from-observed exits non-zero + writes to stderr (retired)"
else fail 8 "allowlist promote --from-observed retirement" "$a8_reason -- stderr: $(cat "$a8_err")"; fi
rm -f "$a8_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A9: allowlist promote --from-observed retirement message names ADR-029 + fast-follow bead
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a9_err=$(mktemp)
run_rc allowlist promote --from-observed --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>"$a9_err"
a9_ok=true a9_reason=""
grep -qi "retired" "$a9_err" || { a9_ok=false; a9_reason="stderr does not say 'retired'"; }
grep -q "ADR-029" "$a9_err" || { a9_ok=false; a9_reason="${a9_reason:+$a9_reason; }stderr does not cite ADR-029"; }
grep -q "rip-cage-tsf2.2" "$a9_err" || { a9_ok=false; a9_reason="${a9_reason:+$a9_reason; }stderr does not point at fast-follow bead rip-cage-tsf2.2"; }
if [[ "$a9_ok" == "true" ]]; then pass 9 "allowlist promote --from-observed message names ADR-029 + rip-cage-tsf2.2"
else fail 9 "allowlist promote --from-observed message content" "$a9_reason -- stderr: $(cat "$a9_err")"; fi
rm -f "$a9_err"
teardown_sandbox

# ---------------------------------------------------------------------------
# A10: allowlist promote --from-observed never mutates .rip-cage.yaml (no silent partial apply)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 2
network:
  allowed_hosts:
    - already.allowed.com
  mode: observe
YML
write_egress_log "${WS}/.rip-cage/egress.log"
a10_before=$(cat "${WS}/.rip-cage.yaml")

run_rc allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" >/dev/null 2>&1

a10_after=$(cat "${WS}/.rip-cage.yaml")
a10_ok=true a10_reason=""
[[ "$a10_before" != "$a10_after" ]] && a10_ok=false && a10_reason=".rip-cage.yaml was mutated by a retired flag (silent partial apply)"
if [[ "$a10_ok" == "true" ]]; then pass 10 "allowlist promote --from-observed never mutates .rip-cage.yaml"
else fail 10 "allowlist promote --from-observed no-mutation" "$a10_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A11: allowlist add refuses when RC_TEST_FAKE_CAGE_MARKER=1 (D10 host-side-only guard)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a11_out=$(run_rc_in_cage allowlist add "cdn.example.com" --config-file "${WS}/.rip-cage.yaml" 2>&1)
a11_exit=$?
a11_ok=true a11_reason=""
[[ "$a11_exit" -eq 0 ]] && a11_ok=false && a11_reason="exit 0 (want non-zero — should refuse in-cage)"
echo "$a11_out" | grep -qi "host.*tool\|host.only\|inside.*container\|in-cage\|dockerenv" || {
  a11_ok=false; a11_reason="${a11_reason:+$a11_reason; }no host-only message in: $a11_out"; }
if [[ "$a11_ok" == "true" ]]; then pass 11 "allowlist add refuses when in-cage (D10 guard)"
else fail 11 "allowlist add D10 guard" "$a11_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A12: allowlist promote refuses when RC_TEST_FAKE_CAGE_MARKER=1 (D10 guard)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

a12_out=$(run_rc_in_cage allowlist promote --from-observed \
  --config-file "${WS}/.rip-cage.yaml" \
  --log-file "${WS}/.rip-cage/egress.log" 2>&1)
a12_exit=$?
a12_ok=true a12_reason=""
[[ "$a12_exit" -eq 0 ]] && a12_ok=false && a12_reason="exit 0 (want non-zero — should refuse in-cage)"
echo "$a12_out" | grep -qi "host.*tool\|host.only\|inside.*container\|in-cage\|dockerenv" || {
  a12_ok=false; a12_reason="${a12_reason:+$a12_reason; }no host-only message in: $a12_out"; }
if [[ "$a12_ok" == "true" ]]; then pass 12 "allowlist promote refuses when in-cage (D10 guard)"
else fail 12 "allowlist promote D10 guard" "$a12_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A13: allowlist show --output json shape: has allowed_hosts array key
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox

cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 2
network:
  allowed_hosts:
    - test.example.com
YML
a13_out=$(run_rc --output json allowlist show --config-file "${WS}/.rip-cage.yaml" 2>/dev/null)
a13_exit=$?
a13_ok=true a13_reason=""
[[ "$a13_exit" -ne 0 ]] && a13_ok=false && a13_reason="exit $a13_exit"
if [[ "$a13_ok" == "true" ]]; then
  if ! echo "$a13_out" | jq -e 'has("allowed_hosts")' >/dev/null 2>&1; then
    a13_ok=false; a13_reason="no allowed_hosts key in JSON output: $a13_out"
  fi
fi
if [[ "$a13_ok" == "true" ]]; then pass 13 "allowlist show --output json has allowed_hosts key"
else fail 13 "allowlist show json shape" "$a13_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A14: allowlist add --cage resolves the cage's WORKSPACE config, NOT CWD
#      (rip-cage-e25p). Run from a CWD that is NOT the workspace; the host must
#      land in <workspace>/.rip-cage.yaml and NO stray <CWD>/.rip-cage.yaml is
#      created.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
STUBDIR="${TEST_HOME}/stub"
CWD_DIR="${TEST_HOME}/elsewhere"; mkdir -p "$CWD_DIR"
make_msb_stub "$STUBDIR" "cage1" "$WS" "Stopped"

a14_out=$(run_rc_from "$CWD_DIR" "$STUBDIR" allowlist add "httpbin.org" --cage cage1 2>&1)
a14_exit=$?
a14_ok=true a14_reason=""
[[ "$a14_exit" -ne 0 ]] && a14_ok=false && a14_reason="exit $a14_exit; out: $a14_out"
if [[ "$a14_ok" == "true" ]]; then
  grep -q "httpbin.org" "${WS}/.rip-cage.yaml" 2>/dev/null || {
    a14_ok=false; a14_reason="httpbin.org NOT in cage workspace config ${WS}/.rip-cage.yaml"; }
fi
if [[ "$a14_ok" == "true" && -f "${CWD_DIR}/.rip-cage.yaml" ]]; then
  a14_ok=false; a14_reason="stray CWD config created at ${CWD_DIR}/.rip-cage.yaml (the e25p bug)"
fi
if [[ "$a14_ok" == "true" ]]; then pass 14 "allowlist add --cage edits cage workspace config regardless of CWD"
else fail 14 "allowlist add --cage workspace resolution" "$a14_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A15: the resolved edit target matches rc reload's diff source — the JSON
#      config_file field points at <workspace>/.rip-cage.yaml (same file the
#      reload diffs), not CWD. (edit-target == diff-source alignment.)
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
STUBDIR="${TEST_HOME}/stub"
CWD_DIR="${TEST_HOME}/elsewhere"; mkdir -p "$CWD_DIR"
make_msb_stub "$STUBDIR" "cage1" "$WS" "Stopped"

a15_out=$(run_rc_from "$CWD_DIR" "$STUBDIR" --output json allowlist add "httpbin.org" --cage cage1 2>/dev/null)
a15_cf=$(echo "$a15_out" | jq -r '.config_file' 2>/dev/null)
a15_ok=true a15_reason=""
# Canonicalize both for a robust compare (WS may contain symlinked tmp on macOS).
a15_want=$(cd "$WS" && pwd -P)/.rip-cage.yaml
a15_got_dir=$(cd "$(dirname "$a15_cf")" 2>/dev/null && pwd -P || echo "?")
a15_got="${a15_got_dir}/$(basename "$a15_cf")"
[[ "$a15_got" != "$a15_want" ]] && a15_ok=false && a15_reason="config_file=$a15_got (want $a15_want)"
if [[ "$a15_ok" == "true" ]]; then pass 15 "allowlist add --cage reports cage workspace config as the edit target (== reload diff source)"
else fail 15 "allowlist add --cage edit-target report" "$a15_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A16: --cage + a DIVERGENT --config-file fails loud (the edit would land where
#      rc reload's diff can't see it — the e25p failure class). rip-cage-e25p.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
STUBDIR="${TEST_HOME}/stub"
OTHER_DIR="${TEST_HOME}/other"; mkdir -p "$OTHER_DIR"
make_msb_stub "$STUBDIR" "cage1" "$WS" "Stopped"

a16_out=$(run_rc_from "$TEST_HOME" "$STUBDIR" allowlist add "httpbin.org" \
  --cage cage1 --config-file "${OTHER_DIR}/.rip-cage.yaml" 2>&1)
a16_exit=$?
a16_ok=true a16_reason=""
[[ "$a16_exit" -eq 0 ]] && a16_ok=false && a16_reason="exit 0 (want non-zero — divergent edit-target vs diff-source must fail loud)"
echo "$a16_out" | grep -qi "different file\|diverge\|reload" || {
  a16_ok=false; a16_reason="${a16_reason:+$a16_reason; }no divergence message in: $a16_out"; }
# And it must NOT have written the divergent file (no silent partial edit).
if [[ "$a16_ok" == "true" && -f "${OTHER_DIR}/.rip-cage.yaml" ]]; then
  a16_ok=false; a16_reason="divergent --config-file was edited despite the fail-loud"
fi
if [[ "$a16_ok" == "true" ]]; then pass 16 "allowlist add --cage + divergent --config-file fails loud (no silent no-op)"
else fail 16 "allowlist add divergence guard" "$a16_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A17: --cage + --config-file pointing at the SAME file (the cage's own
#      workspace config) is allowed — no false divergence error.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
STUBDIR="${TEST_HOME}/stub"
make_msb_stub "$STUBDIR" "cage1" "$WS" "Stopped"

a17_out=$(run_rc_from "$TEST_HOME" "$STUBDIR" allowlist add "httpbin.org" \
  --cage cage1 --config-file "${WS}/.rip-cage.yaml" 2>&1)
a17_exit=$?
a17_ok=true a17_reason=""
[[ "$a17_exit" -ne 0 ]] && a17_ok=false && a17_reason="exit $a17_exit (same-file should NOT trip the divergence guard); out: $a17_out"
if [[ "$a17_ok" == "true" ]]; then
  grep -q "httpbin.org" "${WS}/.rip-cage.yaml" 2>/dev/null || {
    a17_ok=false; a17_reason="host not added to the cage config"; }
fi
if [[ "$a17_ok" == "true" ]]; then pass 17 "allowlist add --cage + matching --config-file is allowed (no false divergence)"
else fail 17 "allowlist add same-file allowed" "$a17_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A18 (rip-cage-syzk, adversarial-review finding F6): allowlist add --cage
# on a STOPPED cage does NOT auto-apply via `rc reload` -- as of rip-cage-syzk,
# `rc reload` on a stopped+drifted cage cold-recreates it and leaves it
# RUNNING (a lifecycle side effect this convenience call must not trigger).
# Before rip-cage-syzk, a stopped cage's `rc reload` sub-call was always an
# exit-2 no-op; this preserves that observable behavior (the edit is still
# saved, but the cage itself is left untouched -- no "Running rc reload"
# attempt at all, only a message explaining the edit was saved but not
# auto-applied).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
STUBDIR="${TEST_HOME}/stub"
make_msb_stub "$STUBDIR" "cage1" "$WS" "Stopped"

a18_out=$(run_rc_from "$TEST_HOME" "$STUBDIR" allowlist add "httpbin.org" --cage cage1 2>&1)
a18_exit=$?
a18_ok=true a18_reason=""
[[ "$a18_exit" -ne 0 ]] && a18_ok=false && a18_reason="exit $a18_exit; out: $a18_out"
if [[ "$a18_ok" == "true" ]]; then
  grep -q "httpbin.org" "${WS}/.rip-cage.yaml" 2>/dev/null || {
    a18_ok=false; a18_reason="host not added to the cage config despite the cage being stopped"; }
fi
echo "$a18_out" | grep -qi "Running rc reload" && {
  a18_ok=false; a18_reason="${a18_reason:+$a18_reason; }auto-reload was attempted on a STOPPED cage (F6 regression -- would now cold-recreate + boot it)"; }
echo "$a18_out" | grep -qi "not running\|not auto-applied" || {
  a18_ok=false; a18_reason="${a18_reason:+$a18_reason; }no message explaining the edit was saved but not auto-applied"; }
if [[ "$a18_ok" == "true" ]]; then pass 18 "allowlist add --cage on a STOPPED cage saves the edit but does NOT auto-reload (F6: no hidden boot)"
else fail 18 "allowlist add --cage stopped-cage no-op" "$a18_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# A19: positive control -- allowlist add --cage on a RUNNING cage still
# attempts the auto-reload apply (pre-existing behavior, unchanged by F6's
# fix -- the state check must not suppress the RUNNING case too).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
STUBDIR="${TEST_HOME}/stub"
make_msb_stub "$STUBDIR" "cage1" "$WS" "Running"

a19_out=$(run_rc_from "$TEST_HOME" "$STUBDIR" allowlist add "httpbin.org" --cage cage1 2>&1)
a19_ok=true a19_reason=""
echo "$a19_out" | grep -qi "Running rc reload" || {
  a19_ok=false; a19_reason="auto-reload was NOT attempted on a RUNNING cage (positive control regressed)"; }
if [[ "$a19_ok" == "true" ]]; then pass 19 "allowlist add --cage on a RUNNING cage still attempts auto-reload (positive control)"
else fail 19 "allowlist add --cage running-cage auto-reload" "$a19_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
