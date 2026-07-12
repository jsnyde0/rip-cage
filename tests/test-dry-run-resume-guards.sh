#!/usr/bin/env bash
# test-dry-run-resume-guards.sh — rip-cage-3y9g: `rc up --dry-run` must run
# the same _up_resolve_resume_* guard SET, in the same ORDER, as a real
# resume — so a config/label mismatch that a REAL resume refuses loudly is
# also visible under --dry-run (the dry-run block's own comment says
# "surface the same hard stop the actual resume would hit", but before this
# bead the stopped sub-branch skipped 6 of the 10 real guards, and the
# running sub-branch (would_attach) skipped all 5 of the real ones).
#
# Semantics (per bd show rip-cage-3y9g DESIGN, supersedes the description's
# "would_refuse + reason" phrasing): guards abort loud with the SAME error a
# real resume would emit. There is no new would_refuse JSON field — the hard
# stop IS the surfacing.
#
# Coverage:
#   P1a — parity: dry-run STOPPED sub-branch guard-call list (function names,
#         in order) == real STOPPED branch guard-call list.
#   P1b — parity: dry-run RUNNING sub-branch (would_attach) guard-call list
#         == real RUNNING branch guard-call list.
#   B1  — behavioral: _up_resolve_resume_config_mode (one of the guards newly
#         wired into BOTH dry-run sub-branches by this bead) aborts loud on a
#         label/config mismatch and returns 0 when they agree. Same
#         source-level snippet pattern as tests/test-mediator-lifecycle.sh
#         R1-R4 / tests/test-credential-mounts.sh CM8-CM10: source rc, stub
#         `docker` on PATH for the label lookup, stub _load_effective_config
#         for the "current effective config" side, call the resolver
#         directly — this is exactly the call the dry-run branch now makes.
#
# Non-vacuity (P1a/P1b): the four call-lists are extracted from BEGIN/END
# marker comments (`rip-cage-3y9g: RESUME-GUARDS-* BEGIN/END`) bracketing
# each of the four call-sites in rc's cmd_up (two dry-run sub-branches, two
# real branches). Removing a guard call from a dry-run block changes that
# block's list; adding a guard call to a real block only (and not mirroring
# it into dry-run) changes the real block's list — either way the two lists
# stop matching and P1a/P1b go red. Proven manually during implementation:
# commenting out one wired dry-run guard call flips the corresponding P1
# case red; restoring it flips back green.
#
# Wired into tests/run-host.sh (host-only tier — no docker daemon required;
# only a PATH-stubbed `docker` shell function via source-rc + stub, same
# idiom as test-mediator-lifecycle.sh / test-credential-mounts.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
# The RESUME-GUARDS marker regions this test greps are inside cmd_up, which
# lives in cli/up.sh post-decomposition (rip-cage-gto1), not the rc shim.
RC="${REPO_ROOT}/cli/up.sh"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

echo "=== test-dry-run-resume-guards.sh — rip-cage-3y9g ==="
echo ""

# ---------------------------------------------------------------------------
# P1: source-level parity assertion
# ---------------------------------------------------------------------------
echo "--- P1: dry-run vs real resume-guard parity ---"

# _extract_guards <begin-marker> <end-marker> -- print the ordered list of
# _up_resolve_resume_* function-call names found between the two marker
# comments in rc (one name per line, in source order, duplicates preserved).
#
# Known limits (accepted at rip-cage-3y9g impl-review): (1) parity compares
# function NAMES only, not call arguments — an arg divergence between the
# dry-run and real call of the same guard passes silently; (2) only calls
# INSIDE the BEGIN/END marker regions are seen — a future guard added to a
# real branch OUTSIDE its markers is invisible to parity. Keep new guard
# calls inside the marked regions and mirror args byte-for-byte.
_extract_guards() {
  local _begin="$1" _end="$2"
  awk -v b="$_begin" -v e="$_end" '
    index($0, b) { flag=1; next }
    index($0, e) { flag=0 }
    # Skip full-line comments (first non-whitespace char is #) so a guard
    # call that was commented out (not actually removed) is NOT silently
    # still counted as present — non-vacuity requires the parity check to
    # react to a disabled/removed call, not just its lingering text.
    flag && $0 !~ /^[[:space:]]*#/ { print }
  ' "$RC" | grep -oE '_up_resolve_resume_[A-Za-z_]+'
}

DRY_STOPPED=$(_extract_guards "rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-STOPPED BEGIN" "rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-STOPPED END")
REAL_STOPPED=$(_extract_guards "rip-cage-3y9g: RESUME-GUARDS-REAL-STOPPED BEGIN" "rip-cage-3y9g: RESUME-GUARDS-REAL-STOPPED END")
DRY_RUNNING=$(_extract_guards "rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-RUNNING BEGIN" "rip-cage-3y9g: RESUME-GUARDS-DRY-RUN-RUNNING END")
REAL_RUNNING=$(_extract_guards "rip-cage-3y9g: RESUME-GUARDS-REAL-RUNNING BEGIN" "rip-cage-3y9g: RESUME-GUARDS-REAL-RUNNING END")

_fmt_list() { echo "$1" | tr '\n' ',' | sed 's/,$//'; }

if [[ -z "$REAL_STOPPED" ]]; then
  fail "P1a-setup" "could not extract any guard calls from the REAL stopped branch (markers missing/moved in rc) -- test is not exercising real code"
elif [[ "$DRY_STOPPED" == "$REAL_STOPPED" ]]; then
  _n=$(echo "$REAL_STOPPED" | grep -c .)
  pass "P1a dry-run STOPPED sub-branch guard set/order matches real STOPPED branch (${_n} guards)"
else
  fail "P1a dry-run vs real STOPPED guard parity" "dry-run=[$(_fmt_list "$DRY_STOPPED")] real=[$(_fmt_list "$REAL_STOPPED")]"
fi

if [[ -z "$REAL_RUNNING" ]]; then
  fail "P1b-setup" "could not extract any guard calls from the REAL running branch (markers missing/moved in rc) -- test is not exercising real code"
elif [[ "$DRY_RUNNING" == "$REAL_RUNNING" ]]; then
  _n=$(echo "$REAL_RUNNING" | grep -c .)
  pass "P1b dry-run RUNNING sub-branch (would_attach) guard set/order matches real RUNNING branch (${_n} guards)"
else
  fail "P1b dry-run vs real RUNNING guard parity" "dry-run=[$(_fmt_list "$DRY_RUNNING")] real=[$(_fmt_list "$REAL_RUNNING")]"
fi

echo ""

# ---------------------------------------------------------------------------
# P2 (rip-cage-7gr9 finding 1): a mount-shape resume guard must be present in
# BOTH running-branch guard lists, not merely absent from both in lockstep.
# P1b parity alone is non-vacuous only for a REMOVAL from an already-matching
# pair — it would also report PASS if both running branches identically
# omitted a guard (the bug rip-cage-7gr9 fixed). Assert presence directly so
# a future regression that drops a guard from both branches together cannot
# hide behind a green P1b.
#
# Originally asserted _up_resolve_resume_ssh_key_filter; that guard (and the
# ssh.allowed_keys mount-shape it protected) retired with the entire ssh
# cluster at the msb cutover (ADR-029 D3, rip-cage-f1qo S5). Re-pointed to
# _up_resolve_resume_config_mode, a still-surviving mount-shape guard with
# the identical running-branch-inclusion property (also proven behaviorally
# by B1 below).
# ---------------------------------------------------------------------------
echo "--- P2: mount-shape guard present in RUNNING branches (rip-cage-7gr9) ---"

if echo "$DRY_RUNNING" | grep -qx "_up_resolve_resume_config_mode"; then
  pass "P2a _up_resolve_resume_config_mode present in DRY-RUN-RUNNING guard list"
else
  fail "P2a config_mode guard missing from DRY-RUN-RUNNING" "guard list=[$(_fmt_list "$DRY_RUNNING")]"
fi

if echo "$REAL_RUNNING" | grep -qx "_up_resolve_resume_config_mode"; then
  pass "P2b _up_resolve_resume_config_mode present in REAL-RUNNING guard list"
else
  fail "P2b config_mode guard missing from REAL-RUNNING" "guard list=[$(_fmt_list "$REAL_RUNNING")]"
fi

echo ""

# ---------------------------------------------------------------------------
# B1: behavioral proof for a newly-wired guard (_up_resolve_resume_config_mode)
# ---------------------------------------------------------------------------
echo "--- B1: behavioral proof (_up_resolve_resume_config_mode) ---"

# rip-cage-5iti (S10, msb migration test-suite port): the resolver reads
# `msb inspect NAME --format json` via cli/lib/msb_runtime.sh's `_msb_label`
# (rip-cage-rj68 S6 rewrote it onto msb), not `docker inspect --format`; the
# stub below is retargeted onto `msb` accordingly (same idiom as
# test-config-ro-mount.sh M6-M8 / test-credential-mounts.sh's
# `_write_msb_inspect_stub`).
_run_resume_config_mode() {
  local _label="$1" _eff_json="$2" _out_err="$3" _out_exit="$4"
  local _stub_dir
  _stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-dryrun-cm-stub-XXXXXX")
  cat > "${_stub_dir}/msb" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" inspect "*) echo '{"config":{"labels":{"rc.config-mode":"${_label}"}}}'; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "${_stub_dir}/msb"

  local _exit=0
  # No `set -e` re-enable afterward: this file only sets `set -uo pipefail`
  # (mirrors test-mediator-lifecycle.sh's rationale — reactivating errexit
  # here would leak past this function for the rest of the script).
  set +e
  PATH="${_stub_dir}:$PATH" bash -c "
    source '${REPO_ROOT}/cli/lib/msb_runtime.sh' 2>/dev/null
    source '$RC' 2>/dev/null
    _load_effective_config() { echo '${_eff_json}'; }
    _up_resolve_resume_config_mode 'rc-dryrun-cm-test' '/tmp/stub-workspace'
  " >/tmp/rc-dryrun-cm-out 2>/tmp/rc-dryrun-cm-err
  _exit=$?
  eval "${_out_err}=\$(cat /tmp/rc-dryrun-cm-err 2>/dev/null || true)"
  eval "${_out_exit}=${_exit}"
  rm -rf "${_stub_dir}" /tmp/rc-dryrun-cm-out /tmp/rc-dryrun-cm-err
}

# B1a — negative control: container created with rc.config-mode=ro, current
# effective config now has mounts.config_mode=rw -> abort loud. Before this
# bead's fix, this exact mismatch was invisible under `rc up --dry-run`
# (config_mode was never wired into either dry-run sub-branch).
_b1a_err="" _b1a_exit=0
_run_resume_config_mode "ro" '{"config":{"mounts":{"config_mode":"rw"}}}' _b1a_err _b1a_exit

_b1a_ok=true _b1a_reason=""
if [[ "$_b1a_exit" -eq 0 ]]; then
  _b1a_ok=false; _b1a_reason="resolver returned 0 (should abort -- label=ro but current config_mode=rw)"
fi
if ! echo "$_b1a_err" | grep -qi "rc.config-mode"; then
  _b1a_ok=false; _b1a_reason="${_b1a_reason:+$_b1a_reason; }error did not name the label rc.config-mode"
fi
if ! echo "$_b1a_err" | grep -qi "rc destroy"; then
  _b1a_ok=false; _b1a_reason="${_b1a_reason:+$_b1a_reason; }error did not include 'rc destroy' remediation"
fi
if [[ "$_b1a_ok" == "true" ]]; then
  pass "B1a config-mode mismatch (ro->rw): resume guard aborts loud with recreate instructions"
else
  fail "B1a config-mode mismatch" "$_b1a_reason (exit=$_b1a_exit, stderr=$_b1a_err)"
fi

# B1b — positive control: label matches current effective config -> exit 0.
_b1b_err="" _b1b_exit=0
_run_resume_config_mode "rw" '{"config":{"mounts":{"config_mode":"rw"}}}' _b1b_err _b1b_exit

if [[ "$_b1b_exit" -eq 0 ]]; then
  pass "B1b config-mode match (rw==rw): resume guard returns 0 (no abort)"
else
  fail "B1b config-mode match" "expected exit 0, got $_b1b_exit (stderr=$_b1b_err)"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
[[ $FAILURES -eq 0 ]] || exit 1
