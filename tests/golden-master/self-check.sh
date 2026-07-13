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
cleanup() { rm -rf "$WORK_A" "$WORK_B" "$CANARY_ROOT"; }
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

if diff -rq "$SNAP_A" "$SNAP_B" >/tmp/rc-gm-selfcheck-underscrub.diff 2>&1; then
  pass "under-scrub: two independent scratch-root recordings are byte-identical"
else
  fail "under-scrub" "recordings differ (missing scrub) -- see:
$(cat /tmp/rc-gm-selfcheck-underscrub.diff)"
fi
rm -f /tmp/rc-gm-selfcheck-underscrub.diff

# ---------------------------------------------------------------------------
# (b) Over-scrub / mutation canary: perturb manifest/default-tools.yaml's first
# tool entry's name, so `rc manifest reconcile`'s "Added (new in dist): ..."
# summary genuinely differs, then --check against the real (unmutated)
# baseline. Must go RED. IMPORTANT: reuse the SAME (default) GM_ROOT the
# real committed baseline was recorded under -- NOT a fresh override. A
# different scratch-root directory NAME would itself perturb every
# up/destroy/reload case's container_name() (derived from the last two path
# components, not a full-path string a plain substring-scrub can catch),
# which is a self-check-harness artifact, not a real over-scrub gap (the
# production GM_ROOT literal is hardcoded in lib/sandbox.sh, so it never
# varies machine-to-machine in the first place).
#
# Mutation targets manifest/default-tools.yaml (generate-dockerfile's
# BUNDLED case reads rc's own inline _manifest_default_yaml, not
# manifest/default-tools.yaml -- `rc manifest reconcile` is the case that
# actually reads manifest/default-tools.yaml, so it is the correct,
# load-bearing canary target).
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
CANARY_FILE="${CANARY_ROOT}/manifest/default-tools.yaml"

if grep -q '^  - name: beads$' "$CANARY_FILE"; then
  sed -i.bak 's/^  - name: beads$/  - name: beadsGOLDENMASTERCANARY/' "$CANARY_FILE"
  rm -f "${CANARY_FILE}.bak"
else
  fail "over-scrub setup" "manifest/default-tools.yaml did not contain the expected 'name: beads' anchor line -- cannot mount the mutation canary"
  rm -rf "$CANARY_ROOT"
  echo ""
  echo "=== self-check.sh: ${FAILURES} failure(s) ==="
  exit "$FAILURES"
fi

CANARY_OUT=$(bash "${CANARY_ROOT}/tests/golden-master/capture.sh" --check 2>&1)
CANARY_EXIT=$?
rm -rf "$CANARY_ROOT"

if [[ "$CANARY_EXIT" -ne 0 ]] && echo "$CANARY_OUT" | grep -q "FAIL manifest_reconcile"; then
  pass "over-scrub (mutation canary): perturbed manifest/default-tools.yaml -> manifest_reconcile snapshot goes RED"
else
  fail "over-scrub (mutation canary)" "expected capture.sh --check to go RED (and name manifest_reconcile) on a genuinely-different reconcile summary; got exit=${CANARY_EXIT}
$CANARY_OUT"
fi

echo ""
echo "=== self-check.sh: ${FAILURES} failure(s) ==="
exit "$FAILURES"
