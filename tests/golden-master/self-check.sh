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
cleanup() { rm -rf "$WORK_A" "$WORK_B"; }
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
# (b) Over-scrub / mutation canary: perturb dist/default-tools.yaml's first
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
# Mutation is applied to the real checkout's dist/default-tools.yaml
# (generate-dockerfile's BUNDLED case reads rc's own inline
# _manifest_default_yaml, not dist/default-tools.yaml -- `rc manifest
# reconcile` is the case that actually reads dist/default-tools.yaml, so it
# is the correct, load-bearing canary target). Restored unconditionally.
# ---------------------------------------------------------------------------
CANARY_FILE="${REPO_ROOT}/dist/default-tools.yaml"
CANARY_BACKUP=$(mktemp)
cp "$CANARY_FILE" "$CANARY_BACKUP"
restore_canary() { cp "$CANARY_BACKUP" "$CANARY_FILE"; rm -f "$CANARY_BACKUP"; }

if grep -q '^  - name: beads$' "$CANARY_FILE"; then
  sed -i.bak 's/^  - name: beads$/  - name: beadsGOLDENMASTERCANARY/' "$CANARY_FILE"
  rm -f "${CANARY_FILE}.bak"
else
  fail "over-scrub setup" "dist/default-tools.yaml did not contain the expected 'name: beads' anchor line -- cannot mount the mutation canary"
  restore_canary
  echo ""
  echo "=== self-check.sh: ${FAILURES} failure(s) ==="
  exit "$FAILURES"
fi

CANARY_OUT=$(bash "${GM_DIR}/capture.sh" --check 2>&1)
CANARY_EXIT=$?
restore_canary

if [[ "$CANARY_EXIT" -ne 0 ]] && echo "$CANARY_OUT" | grep -q "FAIL manifest_reconcile"; then
  pass "over-scrub (mutation canary): perturbed dist/default-tools.yaml -> manifest_reconcile snapshot goes RED"
else
  fail "over-scrub (mutation canary)" "expected capture.sh --check to go RED (and name manifest_reconcile) on a genuinely-different reconcile summary; got exit=${CANARY_EXIT}
$CANARY_OUT"
fi

echo ""
echo "=== self-check.sh: ${FAILURES} failure(s) ==="
exit "$FAILURES"
