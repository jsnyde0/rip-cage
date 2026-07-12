#!/usr/bin/env bash
# tests/test-msb-runtime.sh -- real-effect tests for cli/lib/msb_runtime.sh,
# the msb-backed runtime primitives (rip-cage-rj68, S6 of the msb migration
# epic rip-cage-tsf2). These are the low-level building blocks cli/up.sh,
# cli/reload.sh, and cli/doctor.sh are rewired onto in this bead -- the
# functions here replace cli/lib/docker.sh's docker-backed equivalents for
# the lifecycle-verb code paths.
#
# Every claim below is a REAL msb effect (a real boot, a real label read
# back via `msb inspect`, a real command executed in-guest via `msb exec`)
# -- never a bare exit-code check on its own (msb-verification discipline,
# bd memory msb-netstack-fake-accepts-tcp-connect-not-egress; though that
# memory is about network fake-accepts specifically, the same "prove it,
# don't assume it" discipline applies to state/label reads here).
#
# NEEDS_MSB: requires a live msb binary + the rip-cage:latest image already
# loaded into msb's local cache (`msb image list`). Self-skips (exit 0,
# SKIP: ...) when missing -- never fakes a PASS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

NAME="rt-probe-$$"
cleanup() { msb remove --force "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# shellcheck source=/dev/null
source "$RC" 2>/dev/null

# ---------------------------------------------------------------------------
# R1: _msb_sandbox_state on an ABSENT sandbox -- empty string, non-zero return.
# ---------------------------------------------------------------------------
echo ""
echo "=== R1: _msb_sandbox_state on an absent sandbox ==="
R1_OUT=$(_msb_sandbox_state "$NAME"); R1_RC=$?
if [[ "$R1_RC" -ne 0 && -z "$R1_OUT" ]]; then
  pass "R1: absent sandbox -> empty state, non-zero return"
else
  fail "R1: expected empty+non-zero for absent sandbox" "rc=${R1_RC} out='${R1_OUT}'"
fi

# ---------------------------------------------------------------------------
# R2: create a real sandbox; state transitions running -> exited -> running.
# ---------------------------------------------------------------------------
echo ""
echo "=== R2: real state transitions across create/stop/start ==="
if msb create "$IMAGE" --name "$NAME" >/dev/null 2>&1; then
  pass "R2 setup: msb create succeeded"
else
  fail "R2 setup: msb create failed" "cannot continue"
  echo ""
  echo "=== test-msb-runtime.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

R2A=$(_msb_sandbox_state "$NAME")
if [[ "$R2A" == "running" ]]; then
  pass "R2a: freshly created sandbox reports state=running"
else
  fail "R2a: expected running" "got '${R2A}'"
fi

msb stop "$NAME" >/dev/null 2>&1
R2B=$(_msb_sandbox_state "$NAME")
if [[ "$R2B" == "exited" ]]; then
  pass "R2b: stopped sandbox reports state=exited"
else
  fail "R2b: expected exited" "got '${R2B}'"
fi

msb start "$NAME" >/dev/null 2>&1
R2C=$(_msb_sandbox_state "$NAME")
if [[ "$R2C" == "running" ]]; then
  pass "R2c: restarted sandbox reports state=running again"
else
  fail "R2c: expected running" "got '${R2C}'"
fi

# ---------------------------------------------------------------------------
# R3: _msb_label reads a real label back via `msb inspect`.
# ---------------------------------------------------------------------------
echo ""
echo "=== R3: _msb_label reads a real label ==="
msb remove --force "$NAME" >/dev/null 2>&1
if msb create "$IMAGE" --name "$NAME" --label "rc.source.path=/tmp/rt-probe-marker" >/dev/null 2>&1; then
  R3_VAL=$(_msb_label "$NAME" "rc.source.path")
  if [[ "$R3_VAL" == "/tmp/rt-probe-marker" ]]; then
    pass "R3a: _msb_label reads back the real label value"
  else
    fail "R3a: expected /tmp/rt-probe-marker" "got '${R3_VAL}'"
  fi
  R3_MISSING=$(_msb_label "$NAME" "rc.no-such-label")
  if [[ -z "$R3_MISSING" ]]; then
    pass "R3b: _msb_label on a missing key returns empty (not an error string)"
  else
    fail "R3b: expected empty for missing label" "got '${R3_MISSING}'"
  fi
else
  fail "R3 setup: msb create with label failed"
fi

# ---------------------------------------------------------------------------
# R4: _msb_exec runs a real command in-guest and returns real output.
# ---------------------------------------------------------------------------
echo ""
echo "=== R4: _msb_exec real in-guest execution ==="
# shellcheck disable=SC2016 # deliberately single-quoted: the arithmetic runs inside the GUEST shell
R4_OUT=$(_msb_exec "$NAME" -- sh -c 'echo rt-marker-$((21*2))')
if [[ "$R4_OUT" == "rt-marker-42" ]]; then
  pass "R4: _msb_exec returned the real computed in-guest value"
else
  fail "R4: expected rt-marker-42" "got '${R4_OUT}'"
fi

# ---------------------------------------------------------------------------
# R5: _msb_exists reflects real presence/absence.
# ---------------------------------------------------------------------------
echo ""
echo "=== R5: _msb_exists ==="
if _msb_exists "$NAME"; then
  pass "R5a: _msb_exists true for a real sandbox"
else
  fail "R5a: expected true for existing sandbox"
fi
msb remove --force "$NAME" >/dev/null 2>&1
if ! _msb_exists "$NAME"; then
  pass "R5b: _msb_exists false after real removal"
else
  fail "R5b: expected false after removal"
fi


# ---------------------------------------------------------------------------
# R6: image-digest readers (_up_image_drift_status's msb-side data source).
# ---------------------------------------------------------------------------
echo ""
echo "=== R6: image-digest readers ==="
if msb create "$IMAGE" --name "$NAME" >/dev/null 2>&1; then
  R6_SANDBOX_DIGEST=$(_msb_sandbox_image_digest "$NAME")
  R6_CURRENT_DIGEST=$(_msb_current_image_digest "$IMAGE")
  if [[ -n "$R6_SANDBOX_DIGEST" && "$R6_SANDBOX_DIGEST" == sha256:* ]]; then
    pass "R6a: _msb_sandbox_image_digest returns a real sha256 digest"
  else
    fail "R6a: expected a sha256:... digest" "got '${R6_SANDBOX_DIGEST}'"
  fi
  if [[ -n "$R6_CURRENT_DIGEST" && "$R6_CURRENT_DIGEST" == sha256:* ]]; then
    pass "R6b: _msb_current_image_digest returns a real sha256 digest"
  else
    fail "R6b: expected a sha256:... digest" "got '${R6_CURRENT_DIGEST}'"
  fi
  if [[ "$R6_SANDBOX_DIGEST" == "$R6_CURRENT_DIGEST" ]]; then
    pass "R6c: a freshly created sandbox's digest matches the current image's digest"
  else
    fail "R6c: expected matching digests" "sandbox=${R6_SANDBOX_DIGEST} current=${R6_CURRENT_DIGEST}"
  fi
  R6_ABSENT_DIGEST=$(_msb_current_image_digest "rip-cage:definitely-not-a-real-tag-$$")
  R6_ABSENT_RC=$?
  if [[ "$R6_ABSENT_RC" -ne 0 && -z "$R6_ABSENT_DIGEST" ]]; then
    pass "R6d: _msb_current_image_digest on an absent image returns empty, non-zero"
  else
    fail "R6d: expected empty+non-zero for an absent image" "rc=${R6_ABSENT_RC} got '${R6_ABSENT_DIGEST}'"
  fi
else
  fail "R6 setup: msb create failed"
fi


# ---------------------------------------------------------------------------
# R7: _msb_denied_domains_from_trace_log's own doc comment promises "Echoes
# empty (never errors) when the sandbox has no logs yet or no denials
# occurred." (rip-cage-5iti, S10 finding): its internal
# `msb logs | grep -o ... | sed ... | awk ...` pipe has grep exit 1 (no
# match) whenever there are zero denials -- the common/default case for a
# healthy cage. Under bare `set -uo pipefail` (this file's own mode) that's
# invisible (command substitution swallows it), but BOTH real call sites
# (cli/reload.sh cmd_reload, cli/doctor.sh's posture probe) run inside rc's
# real dispatch, which sets `set -euo pipefail` -- there, an unguarded
# `_rl_denied=$(_msb_denied_domains_from_trace_log "$name")` assignment
# aborts the whole command on the pipefail-propagated grep failure. Proven
# live below by reproducing that exact strict-mode context.
# ---------------------------------------------------------------------------
echo ""
echo "=== R7: _msb_denied_domains_from_trace_log never errors on zero denials (pipefail contract) ==="
if msb create "$IMAGE" --name "$NAME" --replace >/dev/null 2>&1; then
  R7_EXIT=0
  R7_OUT=$(bash -c '
    set -euo pipefail
    source "'"$RC"'" 2>/dev/null
    _rl_denied=$(_msb_denied_domains_from_trace_log "'"$NAME"'")
    echo "R7_REACHED_END:[${_rl_denied}]"
  ' 2>&1) || R7_EXIT=$?
  if [[ "$R7_EXIT" -eq 0 && "$R7_OUT" == *"R7_REACHED_END:[]"* ]]; then
    pass "R7a: zero-denial call under set -euo pipefail does not abort the caller (empty output, exit 0)"
  else
    fail "R7a: expected exit 0 and reaching the end marker with empty denied-list" "exit=${R7_EXIT} out='${R7_OUT}'"
  fi
else
  fail "R7 setup: msb create failed"
fi

echo ""
echo "=== test-msb-runtime.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
