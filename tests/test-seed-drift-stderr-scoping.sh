#!/usr/bin/env bash
# tests/test-seed-drift-stderr-scoping.sh — regression test for rip-cage-auzj
# (test-manifest-seed-drift.sh's D4/D4B assertions asserted `rc build`'s
# stderr was entirely EMPTY, so any unrelated warning on that channel
# false-reds the manifest-drift assertion they exist to make; fixed in
# commit a4104435577e5223ad0e5d6729f773a09a91bad3 by rescoping D4/D4B to
# grep for drift/reconcile vocabulary instead of raw emptiness).
#
# rip-cage-auzj's own ship-record proved the fix with a synthetic, ad-hoc
# PATH-stubbed msb/docker in a temp dir that no longer exists, with no
# re-runnable command recorded. This file is that proof, made permanent and
# host-only (no live msb, no live cage, no docker daemon, no network).
#
# THREE THINGS THIS FILE MUST PROVE, matching the ship-record's promise:
#   SDS-POS   stderr carrying ONLY the unrelated stale-container warning
#             ("...was created from a different image than the one just
#             built...", cli/build.sh's _build_warn_stale_containers) and NO
#             drift wording -> today's scoped D4/D4B assertion PASSES. This
#             is the regression rip-cage-auzj fixed.
#   SDS-NEG   stderr carrying GENUINE manifest-drift wording (reconcile /
#             seed-fingerprint / dist/default-tools, from the real
#             _manifest_check_seed_drift warning) -> today's assertion still
#             FAILS. The load-bearing negative control: without this, the
#             fix would be a tautology that can never catch real drift.
#   SDS-REGR  the OLD pre-fix logic ([[ -z "$D4_ERR" ]]) would have FAILED
#             on the SDS-POS stderr -- documenting WHY the change was
#             needed, not just that today's code happens to work.
#
# HOW THE ASSERTION LOGIC IS OBTAINED (no hand-copied grep vocabulary):
# tests/test-manifest-seed-drift.sh's D4 check is an inline `if`, not a
# standalone function -- there is nothing to `source` in isolation without
# also executing the whole file's top-level test body (which runs D1-D6 for
# real as a side effect of sourcing, including its own EXIT trap). Instead:
#   - the CURRENT predicate's grep vocabulary is extracted at run time
#     (awk, below) directly from the shipped file's D4 `if` line, anchored
#     on the rip-cage-auzj comment immediately above it, so if that
#     vocabulary ever changes, this file's check changes with it -- it can
#     never silently drift out of sync.
#   - as the strongest possible corroboration, SDS-POS-E2E additionally runs
#     the REAL, unmodified tests/test-manifest-seed-drift.sh end-to-end
#     under the forced-warning PATH stub and reads ITS OWN printed PASS/FAIL
#     line for D4/D4B -- zero extraction, zero duplication, the actual
#     shipped file actually executing.
#   - SDS-REGR-E2E does the same for the OLD logic, but on a verbatim git-
#     history snapshot of the pre-fix file (commit a4104435's parent) rather
#     than a hand-typed reconstruction of "what the old code used to say".
#
# Idiom: content-keyed fake docker/msb on PATH, matching
# tests/test-image-drift-resume.sh and tests/test-build-msb-load.sh. Host-
# only: never touches a real docker daemon, real msb, or the real
# code-personal cage -- the fake docker/msb stubs fully shadow the real
# binaries within each PATH-scoped invocation below.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
MSD_SCRIPT="${SCRIPT_DIR}/test-manifest-seed-drift.sh"

# The exact pre-fix commit named in rip-cage-auzj's ship-record. Pinned
# deliberately -- this file is proving a fact about a specific historical
# regression, not "whatever tests/test-manifest-seed-drift.sh's git blame
# currently says". If this commit is ever rewritten out of history (rebase/
# squash), SDS-REGR-E2E below fails loud naming the missing SHA rather than
# silently skipping.
PRE_FIX_COMMIT="a4104435577e5223ad0e5d6729f773a09a91bad3"

FAILURES=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; }

echo "=== test-seed-drift-stderr-scoping.sh (rip-cage-auzj) ==="
echo ""

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rc-seed-drift-stderr-scoping-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Extract the CURRENT (post-fix) predicate's grep vocabulary directly from
# the shipped file -- never hand-copied, so it can't silently drift out of
# sync with what tests/test-manifest-seed-drift.sh actually asserts.
# ---------------------------------------------------------------------------
D4_LINE=$(awk '/rip-cage-auzj: scoped to drift\/reconcile wording/{f=1} f && /^if ! printf/{print; exit}' "$MSD_SCRIPT")
if [[ -z "$D4_LINE" ]]; then
  echo "FATAL: could not locate rip-cage-auzj's D4 predicate line in ${MSD_SCRIPT} -- its structure changed; update the awk anchor above." >&2
  exit 1
fi
# Generalize onto our own variable name; the vocabulary/structure inside is
# byte-identical to what shipped (extracted, not retyped).
CURRENT_PREDICATE_LINE="${D4_LINE//\$D4_ERR/\$_SDS_INPUT}"

_current_shipped_predicate() {  # $1 = candidate stderr; 0 = shipped D4 assertion would PASS, 1 = would FAIL
  local _SDS_INPUT="$1"
  eval "$CURRENT_PREDICATE_LINE return 0; else return 1; fi"
}

# ---------------------------------------------------------------------------
# Extract the OLD (pre-fix) predicate from git history -- the real removed
# code, not a reconstruction from memory.
# ---------------------------------------------------------------------------
OLD_MSD_SCRIPT="${WORK}/old-test-manifest-seed-drift.sh"
if ! git -C "$REPO_ROOT" show "${PRE_FIX_COMMIT}^:tests/test-manifest-seed-drift.sh" > "$OLD_MSD_SCRIPT" 2>/dev/null; then
  echo "FATAL: could not retrieve tests/test-manifest-seed-drift.sh as of ${PRE_FIX_COMMIT}^ from git history -- history rewritten? update PRE_FIX_COMMIT." >&2
  exit 1
fi
chmod +x "$OLD_MSD_SCRIPT"
# shellcheck disable=SC2016 # intentional literal regex (matches literal "$D4_ERR" text), not an expansion
OLD_D4_LINE=$(grep -m1 -E '^if \[\[ -z "\$D4_ERR" \]\]; then$' "$OLD_MSD_SCRIPT")
if [[ -z "$OLD_D4_LINE" ]]; then
  echo "FATAL: could not locate the pre-fix D4 predicate line in the ${PRE_FIX_COMMIT}^ snapshot." >&2
  exit 1
fi
OLD_PREDICATE_LINE="${OLD_D4_LINE//\$D4_ERR/\$_SDS_INPUT}"

_old_predicate() {  # $1 = candidate stderr; 0 = OLD assertion would PASS, 1 = would FAIL
  local _SDS_INPUT="$1"
  eval "$OLD_PREDICATE_LINE return 0; else return 1; fi"
}

# ---------------------------------------------------------------------------
# Fake docker: permissive, same shape as test-manifest-seed-drift.sh's own
# _msd_new_stub_dir (matches the established idiom; `save` deliberately
# falls to the catch-all so any docker-save-dependent step downstream stays
# a silent no-op -- see tests/test-build-msb-load.sh T5).
# ---------------------------------------------------------------------------
_new_docker_stub_dir() {
  local dir
  dir=$(mktemp -d "${WORK}/dockerstub-XXXXXX")
  cat > "${dir}/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  build) exit 0 ;;
  image)
    case "$2" in
      inspect) echo "sha256:deadbeefdeadbeef"; exit 0 ;;
      rm) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  inspect) echo "sha256:deadbeefdeadbeef"; exit 0 ;;
  ps) exit 0 ;;
  run) echo "root 755"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${dir}/docker"
  echo "$dir"
}

# Fake msb that unconditionally forces cli/build.sh's
# _build_warn_stale_containers into its warning branch: `msb image list`
# reports the just-built image's digest, `msb list` reports one rc-managed
# sandbox, and that sandbox's own `msb inspect` digest deliberately
# mismatches -- reproducing the exact warning shape rip-cage-auzj's
# ship-record captured live.
_add_stale_container_msb() {
  local dir="$1"
  cat > "${dir}/msb" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  image)
    if [[ "${2:-}" == "list" ]]; then
      echo '[{"reference":"rip-cage:latest","digest":"sha256:cafefeedcafefeedcafefeedcafefeedcafefeedcafefeedcafefeedcafefeed"}]'
      exit 0
    fi
    exit 0
    ;;
  list)
    echo '[{"name":"sds-fake-stale-cage"}]'
    exit 0
    ;;
  inspect)
    echo '{"status":"Stopped","config":{"manifest_digest":"sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","labels":{"rc.source.path":"/tmp/fake-workspace"}}}'
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${dir}/msb"
}

# ---------------------------------------------------------------------------
# SDS-POS: real `rc build` stderr forced into "stale-container warning only,
# no drift wording" -- same vanilla-manifest fixture shape as D4 itself
# (_manifest_default_yaml), driven through the real cmd_build end-to-end.
# ---------------------------------------------------------------------------
echo "-- SDS-POS: forced stale-container warning, no drift wording --"

POS_STUB_DIR=$(_new_docker_stub_dir)
_add_stale_container_msb "$POS_STUB_DIR"

VANILLA_MANIFEST="${WORK}/vanilla-tools.yaml"
bash -c "source '$RC' 2>/dev/null; _manifest_default_yaml" > "$VANILLA_MANIFEST"

POS_ERR_FILE="${WORK}/pos-err"
POS_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _new_docker_stub_dir's
# fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${POS_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$VANILLA_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$POS_ERR_FILE" || POS_EXIT=$?
POS_ERR=$(cat "$POS_ERR_FILE" 2>/dev/null || true)

if [[ "$POS_EXIT" -eq 0 ]]; then
  pass "SDS-POSz build succeeds cleanly under the forced-warning stub"
else
  fail "SDS-POSz build succeeds cleanly under the forced-warning stub" "exit=$POS_EXIT stderr=$POS_ERR"
fi
if printf '%s' "$POS_ERR" | grep -qF "was created from a different image than the one just built"; then
  pass "SDS-POSa fixture genuinely reproduces the unrelated stale-container warning"
else
  fail "SDS-POSa fixture genuinely reproduces the unrelated stale-container warning" "stderr=$POS_ERR"
fi
if ! printf '%s' "$POS_ERR" | grep -qi "reconcile\|seed-fingerprint\|dist/default-tools"; then
  pass "SDS-POSb fixture stderr carries no drift/reconcile wording (isolates the unrelated-warning case)"
else
  fail "SDS-POSb fixture stderr carries no drift/reconcile wording (isolates the unrelated-warning case)" "stderr=$POS_ERR"
fi
if _current_shipped_predicate "$POS_ERR"; then
  pass "SDS-POSc today's shipped D4 predicate PASSES on this stderr (the regression rip-cage-auzj fixed)"
else
  fail "SDS-POSc today's shipped D4 predicate PASSES on this stderr (the regression rip-cage-auzj fixed)" "predicate said FAIL; stderr=$POS_ERR"
fi

echo ""

# ---------------------------------------------------------------------------
# SDS-POS-E2E: strongest corroboration of SDS-POS -- run the REAL, unmodified
# tests/test-manifest-seed-drift.sh end-to-end under the same forced-warning
# stub and read its own printed PASS/FAIL lines for D4/D4B. Zero extraction,
# zero duplication -- the shipped file actually executing.
# ---------------------------------------------------------------------------
echo "-- SDS-POS-E2E: the real shipped script's own D4/D4B lines, run live under the forced warning --"

E2E_OUT_FILE="${WORK}/e2e-out"
E2E_EXIT=0
PATH="${POS_STUB_DIR}:$PATH" bash "$MSD_SCRIPT" >"$E2E_OUT_FILE" 2>&1 || E2E_EXIT=$?

if [[ "$E2E_EXIT" -eq 0 ]]; then
  pass "SDS-E2Ez the real test-manifest-seed-drift.sh still exits 0 under the forced warning"
else
  fail "SDS-E2Ez the real test-manifest-seed-drift.sh still exits 0 under the forced warning" "exit=$E2E_EXIT; see ${E2E_OUT_FILE}"
fi
if grep -qE '^PASS.*D4 vanilla unconfigured manifest produces zero drift/reconcile wording on stderr' "$E2E_OUT_FILE"; then
  pass "SDS-E2Ea the real script's own D4 line PASSES live under the forced warning"
else
  fail "SDS-E2Ea the real script's own D4 line PASSES live under the forced warning" "$(grep -E 'D4[^C]' "$E2E_OUT_FILE" || true)"
fi
if grep -qE '^PASS.*D4B intersecting-entries-all-match manifest produces zero drift/reconcile wording on stderr' "$E2E_OUT_FILE"; then
  pass "SDS-E2Eb the real script's own D4B line PASSES live under the forced warning"
else
  fail "SDS-E2Eb the real script's own D4B line PASSES live under the forced warning" "$(grep -E 'D4B' "$E2E_OUT_FILE" || true)"
fi

echo ""

# ---------------------------------------------------------------------------
# SDS-NEG (load-bearing negative control): real `rc build` stderr carrying
# GENUINE manifest-drift wording (a real stale seed-fingerprint stamp,
# driven through the real _manifest_check_seed_drift) -- today's assertion
# must still FAIL. Without this, the fix would be a tautology.
# ---------------------------------------------------------------------------
echo "-- SDS-NEG: genuine manifest-drift wording must still fail the assertion --"

NEG_STUB_DIR=$(_new_docker_stub_dir)   # no msb needed for this branch

STALE_MANIFEST="${WORK}/stale-tools.yaml"
cat > "$STALE_MANIFEST" <<'YAML'
# rc-seed-fingerprint: sha256:0000000000000000000000000000000000000000000000000000000000000
version: 1
tools:
  - name: beads
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - api.github.com
    mounts: []
YAML

NEG_ERR_FILE="${WORK}/neg-err"
NEG_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _new_docker_stub_dir's
# fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${NEG_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$STALE_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$NEG_ERR_FILE" || NEG_EXIT=$?
NEG_ERR=$(cat "$NEG_ERR_FILE" 2>/dev/null || true)

if [[ "$NEG_EXIT" -eq 0 ]]; then
  pass "SDS-NEGz build succeeds cleanly (drift warning is informational, not blocking)"
else
  fail "SDS-NEGz build succeeds cleanly (drift warning is informational, not blocking)" "exit=$NEG_EXIT stderr=$NEG_ERR"
fi
if printf '%s' "$NEG_ERR" | grep -qi "reconcile\|seed-fingerprint"; then
  pass "SDS-NEGa fixture genuinely reproduces real manifest-drift wording"
else
  fail "SDS-NEGa fixture genuinely reproduces real manifest-drift wording" "stderr=$NEG_ERR"
fi
if ! _current_shipped_predicate "$NEG_ERR"; then
  pass "SDS-NEGb today's shipped D4 predicate correctly FAILS on genuine drift wording (negative control holds -- not a tautology)"
else
  fail "SDS-NEGb today's shipped D4 predicate correctly FAILS on genuine drift wording (negative control holds -- not a tautology)" "predicate said PASS; stderr=$NEG_ERR"
fi

echo ""

# ---------------------------------------------------------------------------
# SDS-REGR: the OLD pre-fix predicate on the SDS-POS stderr -- proves the
# fix was necessary, not just that today's code happens to work.
# ---------------------------------------------------------------------------
echo "-- SDS-REGR: the OLD raw-stderr-emptiness logic reds on the exact case the fix addresses --"

if ! _old_predicate "$POS_ERR"; then
  pass "SDS-REGRa the OLD predicate ([[ -z \"\$D4_ERR\" ]]) FAILS on the SDS-POS stderr -- the old logic would have false-red D4/D4B on this warning"
else
  fail "SDS-REGRa the OLD predicate ([[ -z \"\$D4_ERR\" ]]) FAILS on the SDS-POS stderr" "old predicate said PASS (unexpected); stderr=$POS_ERR"
fi

# SDS-REGR-E2E: run the VERBATIM pre-fix file (git history, not retyped) end
# to end under the identical forced-warning stub and confirm its own D4/D4B
# lines FAIL live. Needs the old script's ../rc, ../manifest, ../cli, ../cage
# relative lookups to resolve -- symlink them alongside the extracted copy.
OLD_RUN_DIR="${WORK}/old-run"
mkdir -p "${OLD_RUN_DIR}/tests"
cp "$OLD_MSD_SCRIPT" "${OLD_RUN_DIR}/tests/test-manifest-seed-drift.sh"
ln -s "${REPO_ROOT}/rc" "${OLD_RUN_DIR}/rc"
ln -s "${REPO_ROOT}/manifest" "${OLD_RUN_DIR}/manifest"
ln -s "${REPO_ROOT}/cli" "${OLD_RUN_DIR}/cli"
ln -s "${REPO_ROOT}/cage" "${OLD_RUN_DIR}/cage"

OLD_E2E_OUT_FILE="${WORK}/old-e2e-out"
OLD_E2E_EXIT=0
PATH="${POS_STUB_DIR}:$PATH" bash "${OLD_RUN_DIR}/tests/test-manifest-seed-drift.sh" >"$OLD_E2E_OUT_FILE" 2>&1 || OLD_E2E_EXIT=$?

if [[ "$OLD_E2E_EXIT" -ne 0 ]]; then
  pass "SDS-REGR-E2Ez the verbatim pre-fix script exits non-zero live under the forced warning"
else
  fail "SDS-REGR-E2Ez the verbatim pre-fix script exits non-zero live under the forced warning" "expected non-zero, got 0; see ${OLD_E2E_OUT_FILE}"
fi
if grep -qE '^FAIL.*D4 vanilla unconfigured manifest produces zero drift-related stderr output' "$OLD_E2E_OUT_FILE"; then
  pass "SDS-REGR-E2Ea the verbatim pre-fix script's own D4 line FAILS live under the forced warning"
else
  fail "SDS-REGR-E2Ea the verbatim pre-fix script's own D4 line FAILS live under the forced warning" "$(grep -E 'D4[^C]' "$OLD_E2E_OUT_FILE" || true)"
fi
if grep -qE '^FAIL.*D4B intersecting-entries-all-match manifest produces zero drift-related stderr output' "$OLD_E2E_OUT_FILE"; then
  pass "SDS-REGR-E2Eb the verbatim pre-fix script's own D4B line FAILS live under the forced warning"
else
  fail "SDS-REGR-E2Eb the verbatim pre-fix script's own D4B line FAILS live under the forced warning" "$(grep -E 'D4B' "$OLD_E2E_OUT_FILE" || true)"
fi

echo ""
echo "=== $TOTAL checks, $FAILURES failed ==="
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  exit 1
fi
