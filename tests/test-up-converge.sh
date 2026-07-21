#!/usr/bin/env bash
# Host-side tests for `rc up` converge-on-up (rip-cage-tsf2.9, DEFAULT-ON flip
# rip-cage-y0u0, 2026-07-21 human sign-off). `rc up` converges a drifted
# STOPPED cage to current config (compose-style) BY DEFAULT, loudly, without
# breaking rip-cage's abort-loud posture:
#
#   - Plain `rc up` on a STOPPED cage with eligible drift: the existing
#     cold-recreate pipeline (graceful stop -> remove -> recreate against the
#     now-current .rip-cage.yaml) runs automatically, with a loud announcement
#     naming what's cold-recreated, what survives (workspace + ~/.claude/
#     {projects,sessions} mounts + named volumes rc-state-*/rc-history-*/
#     rc-mise-cache), what's lost (only the guest's ephemeral rootfs scratch),
#     and how to opt out (--no-reload). No drift -> a harmless plain `up`.
#     ADR-029 D4 (reload=cold-recreate).
#   - `--no-reload`: opts OUT of the default for this invocation — resumes
#     stale with the existing drift hint (old tsf2.9-shipped behavior).
#   - `--reload`: kept as an explicit-intent synonym for the default on a
#     stopped cage; on a RUNNING cage it (alone, not the default path)
#     triggers the "NOT auto-recreating" notice — a plain `rc up` on a running
#     cage with drift stays hint-only, same as before the flip.
#   - `--reload` + `--no-reload` together: error out loud (mutually exclusive).
#   - RC_UP_CONVERGE is RETIRED — no longer read anywhere (inert env var).
#   - A RUNNING cage is NEVER auto-recreated regardless (agent autonomy).
#
# The converge DECISION is a pure function, `_up_eligible_drift_paths NAME WS`,
# gated on the SAME comparator `rc reload` uses -- the config-applied.json
# snapshot diff (_config_read_applied -> _config_diff_paths), NEVER msb inspect
# (F1: inspect cannot read back secret bindings). It echoes the drifted paths
# and returns 0 IFF there is drift AND every drifted path is reload-eligible
# (network.* today, _RC_RELOAD_ELIGIBLE_PATHS); otherwise returns 1 (echoes
# nothing) so the caller falls through to the existing emit_hint / abort-loud
# guards -- non-eligible drift is NEVER double-handled here (review F4). This
# decision function and its gating by drift-eligibility are UNCHANGED by the
# default-on flip — only the flag/env gate around the CALL site changed (from
# "only if --reload/RC_UP_CONVERGE" to "unless --no-reload").
#
# Coverage:
#   U1  Eligible drift (network.allowed_hosts added) -> exit 0, echoes path
#   U2  No drift (snapshot == live)                  -> exit 1, silent
#   U3  Non-eligible drift (egress.mode)             -> exit 1, silent
#          (converge must NOT swallow a guarded/non-eligible field -- it stays
#           on the abort-loud / emit-hint path)
#   U4  No applied snapshot (legacy cage)            -> exit 1, silent
#   U5  Guard family present (representative) — the four abort-loud resume
#          guard functions are still DEFINED after sourcing rc AND still
#          INVOKED on both resume branches (source-grep, >=2 call sites each).
#          NOTE: this checks presence + wiring, NOT the guard bodies. Byte-
#          identity of the guard implementations is enforced by diff review,
#          not by this test (a body-fingerprint golden would be brittle across
#          bash versions — see code-review F2 ruling).
#   U6  dry-run/real ORDER mirror (code-review F1) — the converge step precedes
#          the abort-loud guards in BOTH the dry-run and the real stopped
#          branches, so an eligible-drift converge preempts (previews-not-
#          aborts) even when non-config image drift coexists. Structural
#          assertion, same idiom as test-dry-run-resume-guards.sh P1a (a full
#          in-process cmd_up drive is environment-fragile — realpath/name
#          disambiguation — so the ordering invariant is locked structurally;
#          the behavioral dry-run preview is covered by live L4).
#   U7  `--reload` + `--no-reload` together -> exit non-zero, mutually-
#          exclusive error message (rip-cage-y0u0 point 4). Flag-parse-level
#          check reached before any docker/msb work — host-only, no live cage.
#   L1  LIVE: stopped cage + new allowed host + PLAIN `rc up` (no flags, the
#          new default) cold-recreates; msb inspect rule domains include the
#          new host; snapshot updated. A SECOND plain `rc up` right after (now
#          zero drift) is a no-op resume (no re-announce, no snapshot churn) —
#          folds in tsf2.9's old "zero-drift is a plain resume" acceptance.
#   L2  LIVE: `rc up --no-reload` on a stopped cage with eligible drift opts
#          OUT of the default -> plain resume (no recreate, no live-rule
#          update), and the drift hint still fires.
#   L3  LIVE: RUNNING cage + new allowed host: plain `rc up` (default, no
#          flags) -> NEVER recreates, hint-only, NO "not auto-recreating"
#          notice (default doesn't claim it would have converged); a
#          follow-up `rc up --reload` on the same still-running, still-drifted
#          cage -> NEVER recreates either, but DOES print the explicit-intent
#          "not auto-recreating despite --reload" notice (review F7 asymmetry).
#   L4  LIVE: PLAIN `rc up --dry-run` (no flags) on a stopped drifted cage
#          previews a converge (not "would resume") and mutates nothing (F1
#          behavioral); `rc up --no-reload --dry-run` on the same cage
#          previews a plain resume instead, still mutating nothing.
#
# U1-U7 stub `msb` via PATH shim (no real daemon), read the source directly,
# or invoke the real `rc` binary for flag-parse-only checks (U7, reached
# before any docker/msb call — same idiom as the --new/--session mutex check
# in tests/test-rc-commands.sh Test 22). L1-L4 are docker+msb+image
# conditional and self-skip honestly (same idiom as tests/test-rc-reload.sh
# C1/C6/C10).
#
# ADRs: ADR-029 D4 (reload=cold-recreate), ADR-021 D4a/D5 (abort-loud config
# anchoring), rip-cage-tsf2.9 (shipped opt-in), rip-cage-y0u0 (this bead —
# default-on flip).

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
version: 2
network:
  allowed_hosts:
    - switch.berlin
YML
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
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
version: 2
network:
  allowed_hosts:
    - switch.berlin
YML
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":2,"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":["switch.berlin"]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
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
version: 2
network:
  allowed_hosts: []
YML
make_msb_stub "$STUB_DIR" "$CNAME" "exited" "$WS"
write_snapshot '{"version":2,"egress":{"mode":"denylist"},"mounts":{"denylist":[],"allow_risky":null,"symlinks":{"on_dangling":"follow","scope":"file","mode":"rw"}},"network":{"allowed_hosts":[]},"dcg":{"packs":[],"custom_rule_paths":[]},"session":{"multiplexer":"none"}}'
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
version: 2
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
# U5: Abort-loud guard family present + wired (representative). The four
#     resume-guard functions must still be DEFINED after sourcing rc, AND still
#     be INVOKED on both resume branches (>=2 source call sites each). This
#     checks presence + wiring only — NOT the guard bodies. Byte-identity of the
#     implementations is enforced by diff review, not here (a body-fingerprint
#     golden via `declare -f` would be brittle across bash versions — code-
#     review F2 ruling).
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

# ---------------------------------------------------------------------------
# U6: dry-run/real ORDER mirror (code-review F1). The converge step must precede
#     the abort-loud guards in BOTH the dry-run stopped sub-branch and the real
#     stopped branch. If it does, an eligible-drift converge preempts the guards
#     (a stopped cage with an eligible allowed_hosts edit AND non-config image
#     drift converges/previews-a-converge, it does NOT hit the image-drift abort
#     — the cold-recreate lands on the current image, resolving the drift).
#     Structural assertion (same idiom as test-dry-run-resume-guards.sh P1a) —
#     a full in-process cmd_up --dry-run drive is environment-fragile
#     (realpath/name disambiguation), so the ordering invariant is locked here;
#     the behavioral "preview names converge" is covered by live L4.
#     Non-vacuous: reverting F1 (moving the dry-run converge back below the
#     guards) makes the dry-run converge line fall AFTER the guards marker -> red.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
_up_sh="${REPO_ROOT}/cli/up.sh"
# dry-run branch: `would_action="would_converge"` (the preview) vs the guards
# BEGIN marker; real branch: the converge action `_up_announce_converge` vs the
# guards BEGIN marker. First match of each is the one in the relevant branch.
u6_dry_converge=$(grep -n 'would_action="would_converge"' "$_up_sh" | head -1 | cut -d: -f1)
u6_dry_guards=$(grep -n 'RESUME-GUARDS-DRY-RUN-STOPPED BEGIN' "$_up_sh" | head -1 | cut -d: -f1)
# Anchor on the CALL (`_up_announce_converge "...`), not the `_up_announce_converge() {`
# definition (which lives earlier in the file) — the space+quote disambiguates.
u6_real_converge=$(grep -n '_up_announce_converge "' "$_up_sh" | head -1 | cut -d: -f1)
u6_real_guards=$(grep -n 'RESUME-GUARDS-REAL-STOPPED BEGIN' "$_up_sh" | head -1 | cut -d: -f1)
u6_ok=true u6_reason=""
for _pair in "dry:$u6_dry_converge:$u6_dry_guards" "real:$u6_real_converge:$u6_real_guards"; do
  _br=${_pair%%:*}; _rest=${_pair#*:}; _cv=${_rest%%:*}; _gd=${_rest#*:}
  if [[ -z "$_cv" || -z "$_gd" ]]; then
    u6_ok=false; u6_reason="${u6_reason:+$u6_reason; }${_br}: missing anchor (converge=$_cv guards=$_gd)"
  elif [[ "$_cv" -ge "$_gd" ]]; then
    u6_ok=false; u6_reason="${u6_reason:+$u6_reason; }${_br}: converge (L$_cv) not before guards (L$_gd)"
  fi
done
if [[ "$u6_ok" == "true" ]]; then pass 6 "converge precedes abort-loud guards in BOTH dry-run and real stopped branches (F1 order mirror)"
else fail 6 "dry-run/real converge order mirror" "$u6_reason"; fi

# ---------------------------------------------------------------------------
# U7: --reload + --no-reload together is an error (mutually exclusive) —
#     rip-cage-y0u0 point 4. This is a flag-parse-level check reached BEFORE
#     any docker/msb work (mirrors the existing --new/--session mutex idiom,
#     cli/up.sh, and test-rc-commands.sh Test 22) — host-only, no live cage,
#     no msb stub needed (the real `rc` binary is invoked directly).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
setup_sandbox
mkdir -p "${WS}/.git"
# Isolated XDG_CONFIG_HOME/HOME (like every other test here) — this repo's host
# can have OTHER concurrent sessions/agents touching the real
# ~/.config/rip-cage/config.yaml; the mutex check must not depend on that file
# at all (it fires at flag-parse time, before any config read), but isolating
# keeps this test deterministic regardless of implementation position.
u7_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" "$RC" up --dry-run --reload --no-reload "$WS" 2>&1)
u7_exit=$?
u7_ok=true u7_reason=""
[[ "$u7_exit" -eq 0 ]] && u7_ok=false && u7_reason="exit 0 (want non-zero)"
echo "$u7_out" | grep -qi "mutually exclusive" || { u7_ok=false; u7_reason="${u7_reason:+$u7_reason; }no mutually-exclusive message (got: $u7_out)"; }
if [[ "$u7_ok" == "true" ]]; then pass 7 "rc up --reload --no-reload errors out loud (mutually exclusive)"
else fail 7 "reload/no-reload mutex" "$u7_reason"; fi
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
version: 2
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
version: 2
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
# L1: STOPPED cage + new allowed host + PLAIN `rc up` (no flags — the new
#     default) -> cold-recreate; live rule domains include the new host;
#     snapshot updated. A SECOND plain `rc up` right after (now zero drift)
#     must be a no-op resume (no re-announce, no snapshot churn) — folds in
#     tsf2.9's old "zero-drift is a plain resume" acceptance criterion.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 8 "LIVE default-converge — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage stopped || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 8 "LIVE default-converge" "live setup failed (rc up)"
  else
    _live_add_host
    l1_out=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up "$RCL_WS" 2>&1) || true
    l1_ok=true l1_reason=""
    _live_inspect_has_host "$RCL_CAGE" "example.com" || { l1_ok=false; l1_reason="new host not in live net rules after plain 'rc up'"; }
    echo "$l1_out" | grep -qi "converging" || { l1_ok=false; l1_reason="${l1_reason:+$l1_reason; }no converge announcement on plain 'rc up' with eligible drift"; }
    L1_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    jq -e '.network.allowed_hosts | index("example.com")' "$L1_SNAP" >/dev/null 2>&1 || { l1_ok=false; l1_reason="${l1_reason:+$l1_reason; }snapshot not updated to live"; }
    # Second plain `rc up`: zero drift now -> must be a silent no-op resume.
    l1_snap_pre=$(shasum "$L1_SNAP" 2>/dev/null | awk '{print $1}')
    l1_out2=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up "$RCL_WS" 2>&1) || true
    l1_snap_post=$(shasum "$L1_SNAP" 2>/dev/null | awk '{print $1}')
    echo "$l1_out2" | grep -qi "converging" && { l1_ok=false; l1_reason="${l1_reason:+$l1_reason; }second plain 'rc up' re-announced a converge on zero-drift"; }
    [[ "$l1_snap_pre" != "$l1_snap_post" ]] && { l1_ok=false; l1_reason="${l1_reason:+$l1_reason; }snapshot churned on zero-drift second 'rc up'"; }
    if [[ "$l1_ok" == "true" ]]; then pass 8 "LIVE: plain 'rc up' (default) cold-recreates stopped ${RCL_CAGE} on eligible drift; zero-drift re-up is a no-op"
    else fail 8 "LIVE default-converge" "$l1_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "${RCL_CAGE:-}" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "${RCL_HOME:-}"
fi

# ---------------------------------------------------------------------------
# L2: `rc up --no-reload` on a STOPPED cage with eligible drift opts OUT of
#     the default -> plain resume (no recreate, live rules NOT updated,
#     snapshot NOT updated), and the drift hint still fires (old tsf2.9
#     resume-with-a-hint behavior, now reached via --no-reload instead of
#     "no flag").
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 9 "LIVE --no-reload opt-out — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage stopped || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 9 "LIVE --no-reload opt-out" "live setup failed (rc up)"
  else
    _live_add_host
    L2_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    l2_snap_pre=$(shasum "$L2_SNAP" 2>/dev/null | awk '{print $1}')
    l2_out=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up --no-reload "$RCL_WS" 2>&1) || true
    l2_snap_post=$(shasum "$L2_SNAP" 2>/dev/null | awk '{print $1}')
    l2_ok=true l2_reason=""
    if _live_inspect_has_host "$RCL_CAGE" "example.com"; then
      l2_ok=false; l2_reason="new host applied live despite --no-reload (opt-out leaked!)"
    fi
    echo "$l2_out" | grep -qi "converging" && { l2_ok=false; l2_reason="${l2_reason:+$l2_reason; }announced a converge despite --no-reload"; }
    [[ "$l2_snap_pre" != "$l2_snap_post" ]] && { l2_ok=false; l2_reason="${l2_reason:+$l2_reason; }snapshot changed despite --no-reload"; }
    echo "$l2_out" | grep -qi "reload-eligible\|rc reload" || { l2_ok=false; l2_reason="${l2_reason:+$l2_reason; }no drift hint on --no-reload resume"; }
    if [[ "$l2_ok" == "true" ]]; then pass 9 "LIVE: rc up --no-reload opts out of the default (plain resume + hint, no recreate)"
    else fail 9 "LIVE --no-reload opt-out" "$l2_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "${RCL_CAGE:-}" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "${RCL_HOME:-}"
fi

# ---------------------------------------------------------------------------
# L3: RUNNING cage + new allowed host: PLAIN `rc up` (default, no flags) ->
#     NEVER recreates, hint-only, NO "not auto-recreating" notice (the
#     default doesn't claim it would have converged — point 3). A follow-up
#     `rc up --reload` on the SAME still-running, still-drifted cage -> also
#     NEVER recreates, but DOES print the explicit-intent "not auto-recreating
#     despite --reload" notice (review F7 stopped/running asymmetry).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 10 "LIVE running never-recreates — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage running || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 10 "LIVE running never-recreates" "live setup failed (rc up)"
  else
    _live_add_host
    l3_ok=true l3_reason=""
    # Plain `rc up` (default) on a RUNNING cage with drift: never recreates,
    # and must NOT print the explicit-intent "not auto-recreating" notice.
    l3_out_plain=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up "$RCL_WS" 2>&1) || true
    if _live_inspect_has_host "$RCL_CAGE" "example.com"; then
      l3_ok=false; l3_reason="running cage was recreated by a plain 'rc up' (auto-recreate leaked!)"
    fi
    echo "$l3_out_plain" | grep -qi "not auto-recreating" && { l3_ok=false; l3_reason="${l3_reason:+$l3_reason; }plain 'rc up' printed the explicit-intent notice (should be hint-only)"; }
    echo "$l3_out_plain" | grep -qi "reload-eligible\|rc reload" || { l3_ok=false; l3_reason="${l3_reason:+$l3_reason; }plain 'rc up' on running+drift didn't hint"; }
    # Explicit `rc up --reload` on the SAME running+drifted cage: still never
    # recreates, but NOW prints the "not auto-recreating despite --reload" notice.
    l3_out_reload=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --output json up --reload "$RCL_WS" 2>&1) || true
    if _live_inspect_has_host "$RCL_CAGE" "example.com"; then
      l3_ok=false; l3_reason="${l3_reason:+$l3_reason; }running cage was recreated by 'rc up --reload' (auto-recreate leaked!)"
    fi
    echo "$l3_out_reload" | grep -qi "not auto-recreating.*--reload\|not auto-recreating despite" || { l3_ok=false; l3_reason="${l3_reason:+$l3_reason; }explicit --reload on running cage didn't print the asymmetry notice"; }
    if [[ "$l3_ok" == "true" ]]; then pass 10 "LIVE: RUNNING cage never auto-recreates (plain 'rc up' hint-only; explicit --reload prints the asymmetry notice)"
    else fail 10 "LIVE running never-recreates" "$l3_reason"; fi
    rm -rf "${HOME}/.cache/rip-cage/${RCL_CAGE}" 2>/dev/null || true
  fi
  [[ -n "${RCL_CAGE:-}" ]] && msb remove --force "$RCL_CAGE" >/dev/null 2>&1
  rm -rf "${RCL_HOME:-}"
fi

# ---------------------------------------------------------------------------
# L4: dry-run preview fidelity (review F1, default-on). PLAIN `rc up --dry-run`
#     (no flags) on a STOPPED cage with eligible drift must PREVIEW a
#     converge/cold-recreate (not a misleading "would resume") AND mutate
#     nothing (snapshot unchanged, cage still stopped). `rc up --no-reload
#     --dry-run` on the SAME cage must preview a plain resume instead (opt-out
#     mirrored in the preview), still mutating nothing.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1))
if [[ "$_RC_CONVERGE_HAS_LIVE_RUNTIME" != "true" ]]; then
  skip 11 "LIVE dry-run converge preview — needs docker+msb+pre-built rip-cage:latest image"
else
  _live_setup_cage stopped || true
  if [[ -z "$RCL_CAGE" ]]; then
    fail 11 "LIVE dry-run converge preview" "live setup failed (rc up)"
  else
    _live_add_host
    L4_SNAP="${HOME}/.cache/rip-cage/${RCL_CAGE}/config-applied.json"
    l4_snap_pre=$(shasum "$L4_SNAP" 2>/dev/null | awk '{print $1}')
    l4_out=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --dry-run up "$RCL_WS" 2>&1) || true
    l4_snap_mid=$(shasum "$L4_SNAP" 2>/dev/null | awk '{print $1}')
    l4_ok=true l4_reason=""
    # NOTE: match anchored on "^Would converge"/"^Would resume" (the literal
    # would_action preview line), NOT a bare substring — the live-cage mktemp
    # template itself is named "rc-converge-live-XXXXXX", so an unanchored
    # `grep -qi converge` false-matches on the cage/path name embedded in the
    # mount-list lines regardless of which action was actually previewed.
    echo "$l4_out" | grep -qE "^Would converge container" || { l4_ok=false; l4_reason="plain --dry-run preview didn't name converge (got: $(echo "$l4_out" | tr '\n' '|'))"; }
    echo "$l4_out" | grep -qE "^Would resume container" && { l4_ok=false; l4_reason="${l4_reason:+$l4_reason; }plain --dry-run preview misreports a plain resume"; }
    [[ "$l4_snap_pre" != "$l4_snap_mid" ]] && l4_ok=false && l4_reason="${l4_reason:+$l4_reason; }plain --dry-run mutated the snapshot"
    # --no-reload --dry-run on the SAME cage: opt-out mirrored in the preview.
    l4_out_noreload=$(XDG_CONFIG_HOME="${RCL_HOME}/.config" RC_ALLOWED_ROOTS="$RCL_WS" "$RC" --dry-run up --no-reload "$RCL_WS" 2>&1) || true
    l4_snap_post=$(shasum "$L4_SNAP" 2>/dev/null | awk '{print $1}')
    echo "$l4_out_noreload" | grep -qE "^Would resume container" || { l4_ok=false; l4_reason="${l4_reason:+$l4_reason; }--no-reload --dry-run didn't preview a plain resume (got: $(echo "$l4_out_noreload" | tr '\n' '|'))"; }
    echo "$l4_out_noreload" | grep -qE "^Would converge container" && { l4_ok=false; l4_reason="${l4_reason:+$l4_reason; }--no-reload --dry-run still previewed a converge"; }
    [[ "$l4_snap_mid" != "$l4_snap_post" ]] && l4_ok=false && l4_reason="${l4_reason:+$l4_reason; }--no-reload --dry-run mutated the snapshot"
    [[ "$(msb inspect "$RCL_CAGE" --format json 2>/dev/null | jq -r '.status')" == "Stopped" ]] || { l4_ok=false; l4_reason="${l4_reason:+$l4_reason; }dry-run changed cage state"; }
    if [[ "$l4_ok" == "true" ]]; then pass 11 "LIVE: plain 'rc up --dry-run' previews a converge honestly; --no-reload --dry-run previews the opt-out; neither mutates"
    else fail 11 "LIVE dry-run converge preview" "$l4_reason"; fi
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
