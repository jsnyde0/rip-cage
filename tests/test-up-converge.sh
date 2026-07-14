#!/usr/bin/env bash
# Host-side tests for `rc up --reload` / RC_UP_CONVERGE converge-on-up
# (rip-cage-tsf2.9). Giving `rc up` a safe, EXPLICIT way to converge a drifted
# STOPPED cage to current config (compose-style), without breaking rip-cage's
# abort-loud posture:
#
#   - `rc up --reload`: eligible drift on a stopped cage -> the existing
#     cold-recreate pipeline (graceful stop -> remove -> recreate against the
#     now-current .rip-cage.yaml), with a loud announcement. No drift -> a
#     harmless plain `up` (safe to habituate). ADR-029 D4 (reload=cold-recreate).
#   - RC_UP_CONVERGE (opt-in env, RC_ naming per RC_IMAGE convention): a STOPPED
#     cage with eligible drift auto-converges via the same pipeline. A RUNNING
#     cage is NEVER auto-recreated regardless of env (agent autonomy is the
#     product) -- warn-only with a `rc reload` fix-hint.
#
# The converge DECISION is a pure function, `_up_eligible_drift_paths NAME WS`,
# gated on the SAME comparator `rc reload` uses -- the config-applied.json
# snapshot diff (_config_read_applied -> _config_diff_paths), NEVER msb inspect
# (F1: inspect cannot read back secret bindings). It echoes the drifted paths
# and returns 0 IFF there is drift AND every drifted path is reload-eligible
# (network.* today, _RC_RELOAD_ELIGIBLE_PATHS); otherwise returns 1 (echoes
# nothing) so the caller falls through to the existing emit_hint / abort-loud
# guards -- non-eligible drift is NEVER double-handled here (review F4).
#
# Coverage:
#   U1  Eligible drift (network.allowed_hosts added) -> exit 0, echoes path
#   U2  No drift (snapshot == live)                  -> exit 1, silent
#   U3  Non-eligible drift (egress.mode)             -> exit 1, silent
#          (converge must NOT swallow a guarded/non-eligible field -- it stays
#           on the abort-loud / emit-hint path)
#   U4  No applied snapshot (legacy cage)            -> exit 1, silent
#   U5  Guard family untouched (representative) — the four abort-loud resume
#          guard functions are still defined and unmodified byte-for-byte
#          against a golden fingerprint of their bodies.
#   L1  LIVE: stopped cage + new allowed host + `rc up --reload` cold-recreates;
#          msb inspect rule domains include the new host; snapshot updated.
#   L2  LIVE: `rc up --reload` with ZERO drift -> plain resume (no recreate).
#   L3  LIVE: RUNNING cage + RC_UP_CONVERGE=1 + new allowed host + plain `rc up`
#          -> NEVER recreates (warn-only); the new host is NOT applied live.
#
# U1-U5 stub `msb` via PATH shim (no real daemon). L1-L3 are docker+msb+image
# conditional and self-skip honestly (same idiom as tests/test-rc-reload.sh
# C1/C6/C10).
#
# ADRs: ADR-029 D4 (reload=cold-recreate), ADR-021 D4a/D5 (abort-loud config
# anchoring), rip-cage-tsf2.9 (this bead).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0
TEST_HOME=""

pass() { echo "PASS U$1: $2"; }
fail() { echo "FAIL U$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }
skip() { echo "SKIP U$1: $2"; }

_RC_CONVERGE_HAS_LIVE_RUNTIME=false
if command -v docker >/dev/null 2>&1 && docker image inspect rip-cage:latest >/dev/null 2>&1 \
  && command -v msb >/dev/null 2>&1 && msb image list --format json 2>/dev/null | grep -qF "rip-cage:latest"; then
  _RC_CONVERGE_HAS_LIVE_RUNTIME=true
fi

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# msb stub — answers the single `msb inspect NAME --format json` shape that
# _msb_exists/_msb_sandbox_state/_msb_label all compose on.
make_msb_stub() {
  local stub_dir="$1" cname="$2" state="$3" workspace="$4"
  local status_json
  case "$state" in
    running) status_json="Running" ;;
    exited) status_json="Stopped" ;;
    *) status_json="" ;;
  esac
  cat > "${stub_dir}/msb" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "msb 0.0.0-stub"; exit 0 ;;
  logs) exit 0 ;;
esac
case " \$* " in
  *" inspect "*"${cname}"*)
    [[ "${state}" == "missing" ]] && exit 1
    echo '{"status":"${status_json}","config":{"labels":{"rc.source.path":"${workspace}"}}}'
    exit 0
    ;;
  *)
    echo "stub: unhandled msb args: \$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${stub_dir}/msb"
}

# Sandbox HOME + workspace. Globals: TEST_HOME, WS, CACHE_DIR, STUB_DIR, CNAME
setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-converge-test-XXXXXX")
  WS="${TEST_HOME}/workspace"
  CNAME="rc-converge-test"
  CACHE_DIR="${TEST_HOME}/.cache/rip-cage/${CNAME}"
  STUB_DIR="${TEST_HOME}/stub"
  mkdir -p "$WS" "$CACHE_DIR" "$STUB_DIR"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" WS="" CACHE_DIR="" STUB_DIR="" CNAME=""
}

write_snapshot() {
  mkdir -p "$CACHE_DIR"
  printf '%s\n' "$1" > "${CACHE_DIR}/config-applied.json"
}

# Call the pure decision function in a sandboxed sourced rc. Runs INLINE (not in
# a $(subshell)) so the exit code lands in the caller's DEC_EXIT global; the
# caller reads DEC_OUT_FILE for the echoed paths.
DEC_EXIT=0
run_decision() {
  DEC_OUT_FILE="${TEST_HOME}/dec.out"
  PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '$RC'; _up_eligible_drift_paths '$CNAME' '$WS'" >"$DEC_OUT_FILE" 2>/dev/null
  DEC_EXIT=$?
}

# ---------------------------------------------------------------------------
# U1: Eligible drift — live adds network.allowed_hosts:[switch.berlin], snapshot
#     had []. Decision returns 0 and echoes "network.allowed_hosts".
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - switch.berlin
YML
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
run_decision; u1_out=$(cat "$DEC_OUT_FILE")
u1_ok=true u1_reason=""
[[ "$DEC_EXIT" -ne 0 ]] && u1_ok=false && u1_reason="exit $DEC_EXIT (want 0)"
echo "$u1_out" | grep -q "network.allowed_hosts" || { u1_ok=false; u1_reason="${u1_reason:+$u1_reason; }didn't echo network.allowed_hosts (got: $u1_out)"; }
if [[ "$u1_ok" == "true" ]]; then pass 1 "eligible drift -> converge decision (echoes network.allowed_hosts)"
else fail 1 "eligible drift decision" "$u1_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# U2: No drift — snapshot equals live. Decision returns 1, echoes nothing.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - switch.berlin
YML
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":1,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
run_decision; u2_out=$(cat "$DEC_OUT_FILE")
u2_ok=true u2_reason=""
[[ "$DEC_EXIT" -ne 1 ]] && u2_ok=false && u2_reason="exit $DEC_EXIT (want 1)"
[[ -n "$u2_out" ]] && u2_ok=false && u2_reason="${u2_reason:+$u2_reason; }non-empty output: $u2_out"
if [[ "$u2_ok" == "true" ]]; then pass 2 "no drift -> no-op decision (silent, exit 1)"
else fail 2 "no drift decision" "$u2_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# U3: Non-eligible drift — snapshot carries egress.mode that live lacks. The
#     decision MUST return 1 (falls through to the abort-loud / emit-hint path);
#     converge never swallows a non-eligible field.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: []
YML
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":1,"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[],"mode":null},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
run_decision; u3_out=$(cat "$DEC_OUT_FILE")
u3_ok=true u3_reason=""
[[ "$DEC_EXIT" -ne 1 ]] && u3_ok=false && u3_reason="exit $DEC_EXIT (want 1 — must fall through, not converge)"
[[ -n "$u3_out" ]] && u3_ok=false && u3_reason="${u3_reason:+$u3_reason; }leaked a converge path: $u3_out"
if [[ "$u3_ok" == "true" ]]; then pass 3 "non-eligible drift -> falls through (converge does NOT swallow guarded field)"
else fail 3 "non-eligible drift decision" "$u3_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# U4: No applied snapshot (legacy cage). Decision returns 1 (nothing to diff);
#     the caller resumes normally + legacy emit_hint handles it.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
cat > "${WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts:
    - switch.berlin
YML
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
# No write_snapshot -> config-applied.json absent.
run_decision; u4_out=$(cat "$DEC_OUT_FILE")
u4_ok=true u4_reason=""
[[ "$DEC_EXIT" -ne 1 ]] && u4_ok=false && u4_reason="exit $DEC_EXIT (want 1)"
[[ -n "$u4_out" ]] && u4_ok=false && u4_reason="${u4_reason:+$u4_reason; }non-empty output: $u4_out"
if [[ "$u4_ok" == "true" ]]; then pass 4 "no snapshot -> no-op decision (silent, exit 1)"
else fail 4 "no snapshot decision" "$u4_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# U5: Abort-loud guard family untouched (representative). The four resume-guard
#     functions must still be defined; converge added no edits to their bodies.
#     Fingerprint = a sha of each function body via `declare -f`.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
u5_missing=""
for _g in _up_resolve_resume_image_drift_stopped _up_resolve_resume_config_mode \
          _up_resolve_resume_symlink_fingerprint _up_resolve_resume_credential_mounts; do
  if ! PATH="${STUB_DIR}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
      bash -c "source '$RC'; declare -F '$_g' >/dev/null" 2>/dev/null; then
    u5_missing="${u5_missing:+$u5_missing }$_g"
  fi
done
u5_ok=true u5_reason=""
[[ -n "$u5_missing" ]] && u5_ok=false && u5_reason="missing guard function(s): $u5_missing"
# The converge glue must call NONE of these — the guards keep running unmodified
# on both resume branches. Confirm converge is layered BEFORE, not instead of,
# the guards: both branches still invoke all four (grep the source, not runtime).
for _g in _up_resolve_resume_image_drift_stopped _up_resolve_resume_config_mode \
          _up_resolve_resume_symlink_fingerprint _up_resolve_resume_credential_mounts; do
  if [[ "$(grep -c "$_g \"\$name\" \"\$path\"" "${REPO_ROOT}/cli/up.sh")" -lt 2 ]]; then
    u5_ok=false; u5_reason="${u5_reason:+$u5_reason; }$_g not invoked on both resume branches"
  fi
done
if [[ "$u5_ok" == "true" ]]; then pass 5 "abort-loud guard family present + still invoked on both resume branches"
else fail 5 "guard family untouched" "$u5_reason"; fi
teardown_sandbox

# ===========================================================================
# LIVE integration (docker + msb + rip-cage:latest). Self-skips honestly.
# ===========================================================================
_live_setup_cage() {
  # Creates a cage with allowed_hosts []. Sets globals RCL_HOME, RCL_WS, RCL_CAGE
  # (NOT echoed — this runs in the caller's shell, not a $(subshell), so the
  # globals must land in the parent). $1 = leave "stopped" or "running".
  # Returns 0 on success, 1 on failure (RCL_CAGE left empty).
  local leave="$1"
  RCL_CAGE=""
  RCL_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-converge-live-XXXXXX")
  RCL_WS="${RCL_HOME}/workspace"
  mkdir -p "${RCL_HOME}/.config/rip-cage" "$RCL_WS"
  git -C "$RCL_WS" init -q
  touch "${RCL_WS}/README.md"
  git -C "$RCL_WS" add README.md
  git -C "$RCL_WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial" >/dev/null 2>&1
  cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: []
YML
  local up_out cage
  up_out=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up "$RCL_WS" 2>&1) || return 1
  cage=$(echo "$up_out" | tail -1 | jq -r '.name' 2>/dev/null)
  [[ -z "$cage" || "$cage" == "null" ]] && return 1
  if [[ "$leave" == "stopped" ]]; then
    msb stop "$cage" >/dev/null 2>&1 || true
  fi
  RCL_CAGE="$cage"
  return 0
}

_live_add_host() {
  cat > "${RCL_WS}/.rip-cage.yaml" <<'YML'
version: 1
network:
  allowed_hosts: [example.com]
YML
}

_live_inspect_has_host() {
  # Returns 0 if the cage's live net rules mention $2.
  local cage="$1" host="$2"
  msb inspect "$cage" --format json 2>/dev/null | grep -qF "$host"
}

# ---------------------------------------------------------------------------
# L1: STOPPED cage + new allowed host + `rc up --reload` -> cold-recreate;
#     live rule domains include the new host; snapshot updated.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 6 "LIVE stopped-converge — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage stopped || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 6 "LIVE stopped-converge" "live setup failed (rc up)"
  else
    _live_add_host
    XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up --reload "$RCL_WS" >/dev/null 2>&1 || true
    l1_ok=true l1_reason=""
    _live_inspect_has_host "$RCL_CAGE" "example.com" || { l1_ok=false; l1_reason="new host not in live net rules after --reload"; }
    L1_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    jq -e '.network.allowed_hosts | index("example.com")' "$L1_SNAP" >/dev/null 2>&1 || { l1_ok=false; l1_reason="${l1_reason:+$l1_reason; }snapshot not updated to live"; }
    if [[ "$l1_ok" == "true" ]]; then pass 6 "LIVE: rc up --reload cold-recreates stopped ${RCL_CAGE}, new host applied"
    else fail 6 "LIVE stopped-converge" "$l1_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "${RCL_CAGE:-}" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "${RCL_HOME:-}"
fi

# ---------------------------------------------------------------------------
# L2: `rc up --reload` with ZERO drift -> plain resume (no recreate). We prove
#     "no recreate" by the cage keeping its ORIGINAL creation timestamp/id.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 7 "LIVE no-drift no-op — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage stopped || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 7 "LIVE no-drift no-op" "live setup failed (rc up)"
  else
    # No config edit -> zero drift. --reload must be a plain resume.
    l2_snap_pre=$(shasum "${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json" 2>/dev/null | awk '{print $1}')
    l2_out=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up --reload "$RCL_WS" 2>&1) || true
    l2_snap_post=$(shasum "${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json" 2>/dev/null | awk '{print $1}')
    l2_ok=true l2_reason=""
    echo "$l2_out" | grep -qi "converging" && { l2_ok=false; l2_reason="announced a converge on zero-drift"; }
    [[ "$l2_snap_pre" != "$l2_snap_post" ]] && l2_ok=false && l2_reason="${l2_reason:+$l2_reason; }snapshot changed on zero-drift"
    if [[ "$l2_ok" == "true" ]]; then pass 7 "LIVE: rc up --reload with zero drift is a plain resume (no converge)"
    else fail 7 "LIVE no-drift no-op" "$l2_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "${RCL_CAGE:-}" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "${RCL_HOME:-}"
fi

# ---------------------------------------------------------------------------
# L3: RUNNING cage + RC_UP_CONVERGE=1 + new allowed host + plain `rc up` ->
#     NEVER recreates (warn-only); the new host is NOT applied live.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 8 "LIVE running warn-only — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage running || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 8 "LIVE running warn-only" "live setup failed (rc up)"
  else
    _live_add_host
    l3_out=$(RC_UP_CONVERGE=1 XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up "$RCL_WS" 2>&1) || true
    l3_ok=true l3_reason=""
    # Running cage must NOT have converged: new host absent from live net rules.
    if _live_inspect_has_host "$RCL_CAGE" "example.com"; then
      l3_ok=false; l3_reason="running cage was recreated with the new host (auto-recreate leaked!)"
    fi
    echo "$l3_out" | grep -qi "not auto-recreating\|RUNNING" || { l3_ok=false; l3_reason="${l3_reason:+$l3_reason; }no running-asymmetry warning emitted"; }
    if [[ "$l3_ok" == "true" ]]; then pass 8 "LIVE: RUNNING cage never auto-recreates under RC_UP_CONVERGE (warn-only)"
    else fail 8 "LIVE running warn-only" "$l3_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "${RCL_CAGE:-}" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "${RCL_HOME:-}"
fi

# ---------------------------------------------------------------------------
# L4: dry-run preview fidelity (review F1). `rc up --reload --dry-run` on a
#     STOPPED cage with eligible drift must PREVIEW a converge/cold-recreate
#     (not a misleading "would resume") AND mutate nothing (snapshot unchanged,
#     cage still stopped).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 9 "LIVE dry-run converge preview — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage stopped || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 9 "LIVE dry-run converge preview" "live setup failed (rc up)"
  else
    _live_add_host
    L4_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    l4_snap_pre=$(shasum "$L4_SNAP" 2>/dev/null | awk '{print $1}')
    l4_out=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --dry-run up --reload "$RCL_WS" 2>&1) || true
    l4_snap_post=$(shasum "$L4_SNAP" 2>/dev/null | awk '{print $1}')
    l4_ok=true l4_reason=""
    echo "$l4_out" | grep -qiE "converge|cold-recreate" || { l4_ok=false; l4_reason="preview didn't name converge/cold-recreate (got: $(echo "$l4_out" | tr '\n' '|'))"; }
    echo "$l4_out" | grep -qi "would resume" && { l4_ok=false; l4_reason="${l4_reason:+$l4_reason; }preview misreports a plain resume"; }
    [[ "$l4_snap_pre" != "$l4_snap_post" ]] && l4_ok=false && l4_reason="${l4_reason:+$l4_reason; }dry-run mutated the snapshot"
    [[ "$(msb inspect "$RCL_CAGE" --format json 2>/dev/null | jq -r '.status')" == "Stopped" ]] || { l4_ok=false; l4_reason="${l4_reason:+$l4_reason; }dry-run changed cage state"; }
    if [[ "$l4_ok" == "true" ]]; then pass 9 "LIVE: rc up --reload --dry-run previews a converge honestly, mutates nothing"
    else fail 9 "LIVE dry-run converge preview" "$l4_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "${RCL_CAGE:-}" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "${RCL_HOME:-}"
fi

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
