#!/usr/bin/env bash
# tests/golden-master/self-check.sh — the §2 two-directional scrub self-check
# (rip-cage-9oyh). Neither direction alone proves the scrub is trustworthy:
#
#   (a) UNDER-scrub: run capture.sh --record twice back-to-back on an
#       UNMODIFIED checkout, using two INDEPENDENT scratch roots (so a path
#       leaking through the scrub shows up as a diff between run 1's and
#       run 2's snapshot trees, rather than being masked by both runs
#       reusing the same literal path). Any diff = a missing scrub (a path,
#       timestamp, or other nondeterminism the harness would otherwise
#       false-RED on the very next commit).
#
#   (b) OVER-scrub: perturb a fixture so a verb's output genuinely,
#       semantically changes (the MUTATION CANARY), then run --check
#       against the run-1 baseline. It MUST go RED. A scrub broad enough to
#       swallow this is broad enough to false-GREEN a real regression
#       during the decomposition — exactly the failure mode this harness
#       exists to prevent.
#
# Usage: bash tests/golden-master/self-check.sh
# Exits 0 only if BOTH directions behave correctly.
set -uo pipefail

GM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${GM_DIR}/../.." && pwd)"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

WORK_A=$(mktemp -d "${TMPDIR:-/tmp}/rc-gm-selfcheck-a-XXXXXX")
WORK_B=$(mktemp -d "${TMPDIR:-/tmp}/rc-gm-selfcheck-b-XXXXXX")
# CANARY_ROOT is assigned later (part (b)); declared here (empty) so cleanup()
# can unconditionally reference it as a backstop even if the script exits
# before part (b) runs -- `rm -rf ""` is a safe no-op.
CANARY_ROOT=""
# UNDERSCRUB_DIFF is assigned below (part (a)) via mktemp, per-invocation
# (rip-cage-k13u: a fixed shared /tmp path here let 8 concurrent
# self-check.sh invocations race -- whoever finished first deleted the
# shared file out from under the others). Declared empty here for the same
# cleanup()-backstop reason as CANARY_ROOT above.
UNDERSCRUB_DIFF=""
cleanup() { rm -rf "$WORK_A" "$WORK_B" "$CANARY_ROOT" "$UNDERSCRUB_DIFF"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# (a) Under-scrub: two independent scratch roots, run --record into two
# separate snapshot trees, diff the trees. Empty diff = no missing scrub.
# ---------------------------------------------------------------------------
SNAP_A="${WORK_A}/snapshots"
SNAP_B="${WORK_B}/snapshots"
mkdir -p "$SNAP_A" "$SNAP_B"

GM_ROOT_OVERRIDE="${WORK_A}/gm-root" GM_SNAPSHOT_DIR_OVERRIDE="$SNAP_A" \
  bash "${GM_DIR}/capture.sh" --record >/dev/null
GM_ROOT_OVERRIDE="${WORK_B}/gm-root" GM_SNAPSHOT_DIR_OVERRIDE="$SNAP_B" \
  bash "${GM_DIR}/capture.sh" --record >/dev/null

UNDERSCRUB_DIFF=$(mktemp "${TMPDIR:-/tmp}/rc-gm-selfcheck-underscrub-diff-XXXXXX")
if diff -rq "$SNAP_A" "$SNAP_B" >"$UNDERSCRUB_DIFF" 2>&1; then
  pass "under-scrub: two independent scratch-root recordings are byte-identical"
else
  fail "under-scrub" "recordings differ (missing scrub) -- see:
$(cat "$UNDERSCRUB_DIFF")"
fi
rm -f "$UNDERSCRUB_DIFF"

# ---------------------------------------------------------------------------
# (b) Over-scrub / mutation canary: perturb one egress host in rc's inline
# default manifest, so the emitted `msb create` argv genuinely differs, then
# --check against the real (unmutated) baseline. Must go RED.
#
# IMPORTANT: reuse the SAME (default) GM_ROOT the real committed baseline was
# recorded under -- NOT a fresh override. A different scratch-root directory
# NAME would itself perturb every up/destroy case's container_name() (derived
# from the last two path components, not a full-path string a plain
# substring-scrub can catch),
# which is a self-check-harness artifact, not a real over-scrub gap (the
# production GM_ROOT literal is hardcoded in lib/sandbox.sh, so it never
# varies machine-to-machine in the first place).
#
# Mutation targets rc's INLINE default manifest (_manifest_default_yaml, in
# cli/lib/manifest_checks.sh), NOT the repo's manifest/default-tools.yaml. A
# fresh GM_HOME has no ~/.config/rip-cage/tools.yaml, so `rc up` seeds one from
# the inline copy -- measured 2026-09-16: perturbing the on-disk
# manifest/default-tools.yaml changes no surviving snapshot at all, so it would
# be a vacuous canary. The anchor is an EGRESS HOST, because that host is
# emitted into `up_dry_run_human_absent_create`'s "Would run: msb create ...
# --net-rule allow@<host>:tcp:443" line -- the same line the GM_ROOT/REPO_ROOT
# path scrub rewrites. A scrub broad enough to swallow real content would
# swallow this, which is exactly the failure mode this canary exists to catch.
#
# (The previous anchor was `rc manifest reconcile`, the one case that read
# manifest/default-tools.yaml. That verb retired with the six-verb thinning,
# rip-cage-ely4.10 / ADR-031 D3, taking its snapshot with it.)
#
# rip-cage-jmhn (S12 de-flake): mutating the REAL, repo-tracked
# manifest/default-tools.yaml in place (the original design) is a race under
# concurrency -- two overlapping self-check.sh invocations share the ONE
# file: one process's mutate can fire between another's setup grep and its
# own mutate (spurious "over-scrub setup" FAIL), and interleaved restores
# can leave the actual checkout corrupted in the working tree after both
# processes exit. A standing guard script must not have a failure mode that
# corrupts the repo it guards. Fix: copy the whole checkout into a PRIVATE,
# per-process scratch root (CANARY_ROOT) and mutate + reconcile-check
# THERE instead. `rc`'s own SCRIPT_DIR resolution then points inside the
# copy (${CANARY_ROOT}/rc resolves manifest/default-tools.yaml relative to
# itself), so the mutation and the read never touch anything a sibling
# self-check.sh (or a concurrent capture.sh) process can observe.
# tests/golden-master/snapshots/ comes along in the copy byte-identical to
# the committed baseline, so `capture.sh --check` run from the copy is
# equivalent to checking against the real tree.
# ---------------------------------------------------------------------------
CANARY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rc-gm-selfcheck-canary-XXXXXX")
rsync -a --exclude='.git' "${REPO_ROOT}/" "${CANARY_ROOT}/"
CANARY_FILE="${CANARY_ROOT}/cli/lib/manifest_checks.sh"

if grep -q 'doltremoteapi\.dolthub\.com' "$CANARY_FILE"; then
  sed -i.bak 's/doltremoteapi\.dolthub\.com/goldenmastercanary.invalid/' "$CANARY_FILE"
  rm -f "${CANARY_FILE}.bak"
else
  fail "over-scrub setup" "cli/lib/manifest_checks.sh did not contain the expected 'doltremoteapi.dolthub.com' egress anchor -- cannot mount the mutation canary"
  rm -rf "$CANARY_ROOT"
  echo ""
  echo "=== self-check.sh: ${FAILURES} failure(s) ==="
  exit "$FAILURES"
fi

CANARY_OUT=$(bash "${CANARY_ROOT}/tests/golden-master/capture.sh" --check 2>&1)
CANARY_EXIT=$?
rm -rf "$CANARY_ROOT"

if [[ "$CANARY_EXIT" -ne 0 ]] && echo "$CANARY_OUT" | grep -q "FAIL up_dry_run_human_absent_create"; then
  pass "over-scrub (mutation canary): perturbed inline-default egress host -> up_dry_run_human_absent_create snapshot goes RED"
else
  fail "over-scrub (mutation canary)" "expected capture.sh --check to go RED (and name up_dry_run_human_absent_create) on a genuinely-different egress host in the emitted msb create argv; got exit=${CANARY_EXIT}
$CANARY_OUT"
fi

echo ""
echo "=== self-check.sh: ${FAILURES} failure(s) ==="
exit "$FAILURES"
