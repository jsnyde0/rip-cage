#!/usr/bin/env bash
# tests/test-golden-master-sandbox-isolation.sh — rip-cage-6qxs: regression
# net for the golden-master sandbox's process-unscoped scratch root.
# tests/golden-master/lib/sandbox.sh:32 hardcoded a single FIXED GM_ROOT
# shared by every process; gm_sandbox_reset() (sandbox.sh:43-54) does an
# unconditional, unlocked `rm -rf "$GM_ROOT"; mkdir -p` per case. Seven
# scripts source sandbox.sh and all default to that identical path
# (capture.sh + test-attach-exec-errors, test-generate-dockerfile,
# test-rc-setup, test-rc-install, test-manifest-reconcile-verb,
# test-up-validate-warning-seam), so any two overlapping processes race —
# one script's rm -rf fires mid-case of another, producing missing-file /
# torn-write / spurious-or-missing-backup / wrong-exit failures on an
# unpredictable, run-varying subset. See rip-cage-6qxs notes for the full
# root-cause spike diagnosis (the "host-state-sensitive even serially"
# symptom is a phantom — it was always a second process sharing the root).
#
# S1: a DETERMINISTIC structural check — two independent processes each
# source sandbox.sh with GM_ROOT_OVERRIDE unset and must compute DIFFERENT
# default GM_ROOT values (process-scoped, not shared). Always-red-without-
# fix / always-green-with-fix; not itself flaky.
#
# S2: a CONCURRENCY-STRESS reproduction of the actual race — several
# sandbox-sourcing worker processes hammer gm_sandbox_reset plus a
# canary-file round-trip against the DEFAULT (un-overridden) root, in
# parallel, and the test asserts zero cross-contamination. Pre-fix this
# reliably goes RED (shared root, unlocked rm -rf mid-write); post-fix it
# is deterministically GREEN (every worker gets its own root, so no two
# processes ever touch the same directory).
#
# S3 (rip-cage-9odv): an AMBIENT-ENV-LEAK regression check, orthogonal to
# S1/S2's scratch-root race. gm_capture() (sandbox.sh) launches the child
# `rc` with plain `env` (whitelist-APPEND, not clean-slate `env -i`), so an
# ambient RC_CONFIG_GLOBAL / RC_MANIFEST_GLOBAL exported by the calling
# process (e.g. tests/run-host.sh's own driver fixture, ~line 193) leaks
# into every sandboxed `rc` invocation and corrupts the config the
# golden-master cases resolve against. capture.sh --check is 55/55 when run
# standalone (no ambient var) but was 5-7/55 red when run inside the full
# run-host.sh suite. S3 exports a bogus RC_CONFIG_GLOBAL and RC_MANIFEST_GLOBAL
# in THIS process's environment and asserts capture.sh --check is still
# 55/55 -- i.e. the golden-master outcome must be independent of ambient
# RC_*/RIP_CAGE_* vars.
#
# S4 (rip-cage-qt4k): an AMBIENT-LOCALE-LEAK regression check, orthogonal to
# S1/S2/S3. gm_capture launches the child `rc` with plain `env` (not env -i),
# so it inherits the caller's LANG/LC_ALL/LC_COLLATE; rc's allowlist
# --observed path pipes through `sort -u`, whose ordering is collation-
# dependent, so a non-C ambient locale could break byte-identity across
# machines. S4 exports a hostile non-C LC_ALL, overrides RC with a locale
# probe, and asserts the sandboxed child still sees LC_ALL=C (the pin wins
# over the inherited locale). Latent today (no GM case exercises sort -u) but
# guarded ahead of the msb migration running the net on a different-locale CI.
#
# Wired into tests/run-host.sh (host-only tier).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GM_LIB="${SCRIPT_DIR}/golden-master/lib"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# S1: two independent processes, GM_ROOT_OVERRIDE unset, must compute
# different default GM_ROOT values.
# ---------------------------------------------------------------------------
ROOT_1=$(env -u GM_ROOT_OVERRIDE bash -c "source '${GM_LIB}/sandbox.sh'; printf '%s' \"\$GM_ROOT\"")
ROOT_2=$(env -u GM_ROOT_OVERRIDE bash -c "source '${GM_LIB}/sandbox.sh'; printf '%s' \"\$GM_ROOT\"")

if [[ -n "$ROOT_1" && "$ROOT_1" != "$ROOT_2" ]]; then
  pass "S1: two independent processes compute different default GM_ROOT values ($ROOT_1 vs $ROOT_2)"
else
  fail "S1 GM_ROOT process-uniqueness" "expected two different non-empty GM_ROOT values, got ROOT_1='$ROOT_1' ROOT_2='$ROOT_2' -- concurrent processes sharing one root can rm -rf/mkdir-race each other's fixtures"
fi

# ---------------------------------------------------------------------------
# S2: concurrency-stress reproduction. WORKERS processes each source
# sandbox.sh with the DEFAULT (un-overridden) root, then loop ITERS times:
# gm_sandbox_reset, write a worker+iteration-tagged canary file into the
# fixture workspace, a tiny sleep to widen the race window, then read the
# canary back. Any mismatch (missing file, or another worker's tag) is
# cross-contamination -- recorded in this worker's own results file (an
# orchestration-only mktemp dir, NOT the shared GM_ROOT under test -- this
# test never leaks into or depends on a shared fixed root itself).
# ---------------------------------------------------------------------------
WORKERS=6
ITERS=25

STRESS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-gm-isolation-stress-XXXXXX")
cleanup_stress() { rm -rf "$STRESS_DIR"; }
trap cleanup_stress EXIT

WORKER_SCRIPT="${STRESS_DIR}/worker.sh"
cat > "$WORKER_SCRIPT" <<'WORKER'
#!/usr/bin/env bash
set -u
GM_LIB="$1"
WORKER_ID="$2"
ITERS="$3"
RESULT_FILE="$4"

# shellcheck source=/dev/null
source "${GM_LIB}/sandbox.sh"

CORRUPT=0
i=1
while [[ "$i" -le "$ITERS" ]]; do
  gm_sandbox_reset
  TAG="worker=${WORKER_ID} iter=${i}"
  printf '%s' "$TAG" > "${GM_WS}/canary"
  # Tiny sleep widens the race window without making the loop slow.
  sleep 0.01
  GOT=$(cat "${GM_WS}/canary" 2>/dev/null || echo "<MISSING>")
  if [[ "$GOT" != "$TAG" ]]; then
    CORRUPT=$((CORRUPT + 1))
    echo "CORRUPT iter=${i} expected='${TAG}' got='${GOT}'" >> "$RESULT_FILE"
  fi
  i=$((i + 1))
done

echo "DONE corrupt=${CORRUPT}" >> "$RESULT_FILE"
WORKER
chmod +x "$WORKER_SCRIPT"

PIDS=()
w=1
while [[ "$w" -le "$WORKERS" ]]; do
  RESULT_FILE="${STRESS_DIR}/worker-${w}.result"
  : > "$RESULT_FILE"
  bash "$WORKER_SCRIPT" "$GM_LIB" "$w" "$ITERS" "$RESULT_FILE" &
  PIDS+=("$!")
  w=$((w + 1))
done

for pid in "${PIDS[@]}"; do
  wait "$pid"
done

TOTAL_CORRUPT=0
w=1
while [[ "$w" -le "$WORKERS" ]]; do
  RESULT_FILE="${STRESS_DIR}/worker-${w}.result"
  if ! grep -q '^DONE ' "$RESULT_FILE" 2>/dev/null; then
    fail "S2 worker ${w} completion" "worker did not report DONE (crashed?): $(cat "$RESULT_FILE" 2>/dev/null)"
  fi
  WORKER_CORRUPT=$(grep -c '^CORRUPT ' "$RESULT_FILE" 2>/dev/null)
  WORKER_CORRUPT="${WORKER_CORRUPT:-0}"
  TOTAL_CORRUPT=$((TOTAL_CORRUPT + WORKER_CORRUPT))
  w=$((w + 1))
done

if [[ "$TOTAL_CORRUPT" -eq 0 ]]; then
  pass "S2: ${WORKERS} concurrent sandbox-sourcing workers x ${ITERS} resets each -- zero cross-contamination"
else
  fail "S2 concurrency isolation" "${TOTAL_CORRUPT} cross-contamination event(s) across ${WORKERS} concurrent workers -- see ${STRESS_DIR}/worker-*.result (removed on exit; rerun to inspect)"
fi

# ---------------------------------------------------------------------------
# S3: ambient RC_CONFIG_GLOBAL / RC_MANIFEST_GLOBAL must not leak into the
# sandboxed `rc` child that gm_capture() launches. Run capture.sh --check
# with bogus values of both exported in this process's environment; it must
# report 0 failure(s), same as a clean run.
# ---------------------------------------------------------------------------
CAPTURE_SH="${SCRIPT_DIR}/golden-master/capture.sh"
S3_OUT=$(RC_CONFIG_GLOBAL=/tmp/bogus-leak-9odv/config.yaml \
  RC_MANIFEST_GLOBAL=/tmp/bogus-leak-9odv/manifest.yaml \
  bash "$CAPTURE_SH" --check 2>&1)
S3_SUMMARY=$(printf '%s\n' "$S3_OUT" | grep -E '^=== capture\.sh \(check\):' || true)

if printf '%s' "$S3_SUMMARY" | grep -q ', 0 failure(s)'; then
  pass "S3: ambient RC_CONFIG_GLOBAL/RC_MANIFEST_GLOBAL does not leak into sandboxed rc (${S3_SUMMARY})"
else
  fail "S3 ambient env-leak isolation" "capture.sh --check with ambient RC_CONFIG_GLOBAL/RC_MANIFEST_GLOBAL set did not report 0 failure(s): ${S3_SUMMARY:-<no summary line found>}"
fi

# ---------------------------------------------------------------------------
# S4 (rip-cage-qt4k): gm_capture must pin LC_ALL=C in the sandboxed child
# regardless of the invoking shell's ambient locale, so `sort -u`-driven
# output (rc's allowlist --observed path) is collation-deterministic across
# machines. A `capture.sh --check` assertion would be VACUOUS here: no current
# golden-master case exercises the sort -u path, so it stays 55/55 with OR
# without the pin (assert-negative vacuity). Instead assert the pin DIRECTLY
# and discriminatingly: override RC with a locale probe, export a HOSTILE
# non-C ambient LC_ALL, and confirm the child still sees LC_ALL=C. Mutation-
# verified: drop the LC_ALL=C line from sandbox.sh:_env and this goes RED
# (child sees the leaked en_US.UTF-8), pass with the pin.
# ---------------------------------------------------------------------------
S4_PROBE="${STRESS_DIR}/lc-probe.sh"
cat > "$S4_PROBE" <<'PROBE'
#!/usr/bin/env bash
printf 'PROBE_LC_ALL=%s\n' "${LC_ALL:-<unset>}"
PROBE
chmod +x "$S4_PROBE"

S4_OUT=$(
  export LC_ALL=en_US.UTF-8
  # shellcheck source=/dev/null
  source "${GM_LIB}/sandbox.sh"
  RC="$S4_PROBE"          # gm_capture runs "$RC"; point it at the probe
  gm_capture noop
  printf '%s' "$GM_OUT"
)

if printf '%s' "$S4_OUT" | grep -q '^PROBE_LC_ALL=C$'; then
  pass "S4: gm_capture pins LC_ALL=C in the child regardless of ambient LC_ALL (collation determinism)"
else
  fail "S4 LC_ALL collation pin" "with ambient LC_ALL=en_US.UTF-8 exported, the sandboxed child saw '${S4_OUT:-<no output>}' -- expected 'PROBE_LC_ALL=C' (rip-cage-qt4k pin not applied / not winning over the inherited locale)"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
