#!/usr/bin/env bash
# Host-side tests for manifest seed-drift detection + reconcile (rip-cage-6vt9).
#
# ROOT CAUSE (rip-cage-6vt9): the operator manifest ~/.config/rip-cage/tools.yaml
# is composed once (typically by copying manifest/default-tools.yaml and adding
# custom entries) and never re-checked against the shipped defaults. When the
# maintainer-shipped manifest/default-tools.yaml's recipes change (e.g. a guard
# relocation), a frozen local manifest keeps baking the superseded layout on
# every `rc build`, with no signal. Sibling of rip-cage-jnvb (stale IMAGE
# blind-resumed on `rc up`) — same "stale artifact silently used, no
# drift-detection" family; jnvb = image-vs-image on resume, this =
# manifest-seed-vs-dist on build.
#
# DETECTION SUBSTRATE: a seed-provenance STAMP (`# rc-seed-fingerprint:
# sha256:<hash>` comment line), not a raw content-diff — a content-diff would
# false-fire on legitimate user customization (any hand-edit looks like
# drift). `rc manifest reconcile` writes the stamp with the CURRENT
# manifest/default-tools.yaml hash at reconcile time; `rc build` compares the
# recorded stamp to dist's CURRENT hash. Unstamped manifests (every manifest
# in the wild before this bead) get either silence (byte-identical to the
# floor-only in-repo default — nothing composed, nothing to reconcile) or a
# soft, distinctly-worded "provenance unknown" notice (never the hard
# "stale" wording) — least-noisy-honest option per repo philosophy (a
# warning firing on every healthy build is a cry-wolf; three were fixed in
# this repo already).
#
# Coverage:
#   D1  stale stamp (recorded hash != current dist hash) -> `rc build` warns
#       on stderr, naming the manifest file + pointing at `rc manifest
#       reconcile`.
#   D2  matching stamp (recorded hash == current dist hash) -> `rc build`
#       stays silent (no drift/reconcile wording on stderr).
#   D3  unstamped + customized (content differs from the in-repo floor
#       default) -> soft "provenance unknown" notice (distinct wording from
#       D1's hard warning).
#   D4  unstamped + byte-identical to the floor default (`_manifest_default_yaml`)
#       -> completely silent (no cry-wolf on a totally vanilla/unconfigured
#       manifest).
#   D5  RC_MANIFEST_GLOBAL pointed AT manifest/default-tools.yaml itself (the
#       CI/release compose path) -> drift check bypassed entirely (it IS
#       dist; comparing it to itself is meaningless, and CI must never see
#       this warning).
#   D6  RETIRED with the `rc manifest reconcile` verb (rip-cage-ely4.10).
#
# All `rc build` cases drive the REAL `cmd_build` end-to-end through a
# permissive fake-docker PATH shim (no real docker build/run) — proving the
# check is actually wired into `cmd_build`, not just callable in isolation
# (same rationale as the jnvb harness: a forgotten call site would stay
# green under an isolated-function test).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
DIST_MANIFEST="${REPO_ROOT}/manifest/default-tools.yaml"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

MSD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-seed-drift-XXXXXX")
trap 'rm -rf "$MSD_TMP"' EXIT

echo "=== test-manifest-seed-drift.sh (rip-cage-6vt9) ==="
echo ""

# Current dist hash, computed independently of rc's own hashing (same
# primitive, `shasum -a 256`, but used here only to build fixtures/oracles —
# the behavior under test is rc's comparison + warn logic, not sha256 itself).
DIST_HASH=$(shasum -a 256 "$DIST_MANIFEST" | awk '{print $1}')

# Fresh per-test sandbox dir + fake-docker PATH shim (permissive: every rc
# build touches only floor/bundled-shaped manifest entries in these fixtures,
# so no real docker build/run is ever required to observe the drift check).
_msd_new_stub_dir() {
  local dir
  dir=$(mktemp -d "${MSD_TMP}/stub-XXXXXX")
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

# ---------------------------------------------------------------------------
# D1: stale stamp -> `rc build` warns, naming the manifest + the reconcile
#     command.
# ---------------------------------------------------------------------------
echo "-- D1: stale seed-fingerprint stamp triggers a visible warning --"

D1_MANIFEST="${MSD_TMP}/d1-tools.yaml"
cat > "$D1_MANIFEST" <<'YAML'
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

D1_STUB_DIR=$(_msd_new_stub_dir)
D1_ERR_FILE="${MSD_TMP}/d1-err"
D1_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _msd_new_stub_dir's fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${D1_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$D1_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$D1_ERR_FILE" || D1_EXIT=$?
D1_ERR=$(cat "$D1_ERR_FILE" 2>/dev/null || true)

if [[ "$D1_EXIT" -eq 0 ]]; then
  pass "D1z build still succeeds (warning is informational, not blocking)"
else
  fail "D1z build still succeeds (warning is informational, not blocking)" "exit=$D1_EXIT stderr=$D1_ERR"
fi
if printf '%s' "$D1_ERR" | grep -qF "$D1_MANIFEST"; then
  pass "D1a warning names the drifted manifest file"
else
  fail "D1a warning names the drifted manifest file" "stderr=$D1_ERR"
fi
# The warning used to point at `rc manifest reconcile`; that verb retired with
# the six-verb thinning (rip-cage-ely4.10 / ADR-031 D3), so it points at the
# shipped defaults file the operator now edits against by hand. The property is
# unchanged: a drift warning must name where the fix lives.
if printf '%s' "$D1_ERR" | grep -q "manifest/default-tools.yaml"; then
  pass "D1b warning points at manifest/default-tools.yaml as the refresh source"
else
  fail "D1b warning points at manifest/default-tools.yaml as the refresh source" "stderr=$D1_ERR"
fi

echo ""

# ---------------------------------------------------------------------------
# D2: matching stamp -> `rc build` stays silent (no drift/reconcile wording).
# ---------------------------------------------------------------------------
echo "-- D2: matching seed-fingerprint stamp stays silent --"

D2_MANIFEST="${MSD_TMP}/d2-tools.yaml"
cat > "$D2_MANIFEST" <<YAML
# rc-seed-fingerprint: sha256:${DIST_HASH}
version: 1
tools:
  - name: beads
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - api.github.com
    mounts: []
YAML

D2_STUB_DIR=$(_msd_new_stub_dir)
D2_ERR_FILE="${MSD_TMP}/d2-err"
D2_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _msd_new_stub_dir's fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${D2_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$D2_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$D2_ERR_FILE" || D2_EXIT=$?
D2_ERR=$(cat "$D2_ERR_FILE" 2>/dev/null || true)

if [[ "$D2_EXIT" -eq 0 ]]; then
  pass "D2z build succeeds cleanly"
else
  fail "D2z build succeeds cleanly" "exit=$D2_EXIT stderr=$D2_ERR"
fi
if ! printf '%s' "$D2_ERR" | grep -qi "reconcile\|seed-fingerprint\|dist/default-tools"; then
  pass "D2 manifest matching current dist produces no drift/reconcile wording"
else
  fail "D2 manifest matching current dist produces no drift/reconcile wording" "stderr=$D2_ERR"
fi

echo ""

# ---------------------------------------------------------------------------
# D3: unstamped + ALL-CUSTOM (zero entries whose name intersects dist) -> soft
#     "provenance unknown" notice, distinct wording from D1's hard warning.
#     Deliberately zero dist-name overlap (rip-cage-6vt9 F1 review fold) so
#     this exercises the "nothing to compare" branch specifically, not the
#     intersecting-entries branches covered by D4B/D4C below.
# ---------------------------------------------------------------------------
echo "-- D3: unstamped + all-custom manifest (no dist-name overlap) gets a soft provenance-unknown notice --"

D3_MANIFEST="${MSD_TMP}/d3-tools.yaml"
cat > "$D3_MANIFEST" <<'YAML'
version: 1
tools:
  - name: my-custom-tool-a
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts: []

  - name: my-custom-tool-b
    archetype: TOOL
    version_pin: "bundled"
    egress: []
    mounts: []
YAML

D3_STUB_DIR=$(_msd_new_stub_dir)
D3_ERR_FILE="${MSD_TMP}/d3-err"
D3_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _msd_new_stub_dir's fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${D3_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$D3_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$D3_ERR_FILE" || D3_EXIT=$?
D3_ERR=$(cat "$D3_ERR_FILE" 2>/dev/null || true)

if [[ "$D3_EXIT" -eq 0 ]]; then
  pass "D3z build still succeeds (soft notice is informational, not blocking)"
else
  fail "D3z build still succeeds (soft notice is informational, not blocking)" "exit=$D3_EXIT stderr=$D3_ERR"
fi
if printf '%s' "$D3_ERR" | grep -q "manifest/default-tools.yaml"; then
  pass "D3a soft notice points at manifest/default-tools.yaml"
else
  fail "D3a soft notice points at manifest/default-tools.yaml" "stderr=$D3_ERR"
fi
if printf '%s' "$D3_ERR" | grep -qi "provenance\|no seed-fingerprint stamp"; then
  pass "D3b soft notice uses provenance-unknown wording"
else
  fail "D3b soft notice uses provenance-unknown wording" "stderr=$D3_ERR"
fi
if printf '%s' "$D3_ERR" | grep -q "was seeded/reconciled from an older"; then
  fail "D3c soft notice must NOT use D1's hard 'stale' wording (we don't know it's stale)" "stderr=$D3_ERR"
else
  pass "D3c soft notice wording is distinct from the hard stale-drift warning"
fi

echo ""

# ---------------------------------------------------------------------------
# D4: unstamped + byte-identical to the floor default -> completely silent.
# ---------------------------------------------------------------------------
echo "-- D4: unstamped vanilla floor-default manifest stays silent (no cry-wolf) --"

D4_MANIFEST="${MSD_TMP}/d4-tools.yaml"
bash -c "source '$RC' 2>/dev/null; _manifest_default_yaml" > "$D4_MANIFEST"

D4_STUB_DIR=$(_msd_new_stub_dir)
D4_ERR_FILE="${MSD_TMP}/d4-err"
D4_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _msd_new_stub_dir's fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${D4_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$D4_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$D4_ERR_FILE" || D4_EXIT=$?
D4_ERR=$(cat "$D4_ERR_FILE" 2>/dev/null || true)

if [[ "$D4_EXIT" -eq 0 ]]; then
  pass "D4z build succeeds cleanly"
else
  fail "D4z build succeeds cleanly" "exit=$D4_EXIT stderr=$D4_ERR"
fi
# rip-cage-auzj: scoped to drift/reconcile wording (the thing under test),
# not raw stderr emptiness -- an unrelated pre-existing cage triggers rc's
# own "created from a different image than the one just built" warning
# (cli/build.sh's _build_warn_stale_containers) on any host with a live
# cage whose pinned image digest predates this fixture's rebuild, which is
# not itself manifest drift. Same grep vocabulary as D2's assertion above,
# so a genuine drift/reconcile warning still fails this check (negative
# control retained).
if ! printf '%s' "$D4_ERR" | grep -qi "reconcile\|seed-fingerprint\|dist/default-tools"; then
  pass "D4 vanilla unconfigured manifest produces zero drift/reconcile wording on stderr"
else
  fail "D4 vanilla unconfigured manifest produces zero drift/reconcile wording on stderr" "stderr=$D4_ERR"
fi

echo ""

# ---------------------------------------------------------------------------
# D4B (rip-cage-6vt9 F1 review fold): unstamped, NOT byte-identical to the
#     floor default, but every entry whose name intersects dist byte-matches
#     dist's CURRENT content for that name -> SILENT (provably current; no
#     cry-wolf on a healthy composed manifest that just happens to lack a
#     stamp). Distinct from D4: this manifest has a custom entry too, so it
#     is not the narrow "whole-file matches the floor default" case.
# ---------------------------------------------------------------------------
echo "-- D4B: unstamped, intersecting entries all match dist -> silent --"

D4B_MANIFEST="${MSD_TMP}/d4b-tools.yaml"
D4B_DIST_GH_JSON=$(yq -o=json '.tools[] | select(.name == "gh")' "$DIST_MANIFEST" 2>/dev/null)
D4B_CUSTOM_JSON='{"name":"my-org-tool","archetype":"TOOL","version_pin":"bundled","egress":["example.internal"],"mounts":[]}'
jq -n --argjson gh "$D4B_DIST_GH_JSON" --argjson custom "$D4B_CUSTOM_JSON" \
  '{version: 1, tools: [$gh, $custom]}' \
  | yq -p=json -o=yaml '.' > "$D4B_MANIFEST"

D4B_STUB_DIR=$(_msd_new_stub_dir)
D4B_ERR_FILE="${MSD_TMP}/d4b-err"
D4B_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _msd_new_stub_dir's fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${D4B_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$D4B_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$D4B_ERR_FILE" || D4B_EXIT=$?
D4B_ERR=$(cat "$D4B_ERR_FILE" 2>/dev/null || true)

if [[ "$D4B_EXIT" -eq 0 ]]; then
  pass "D4Bz build succeeds cleanly"
else
  fail "D4Bz build succeeds cleanly" "exit=$D4B_EXIT stderr=$D4B_ERR"
fi
# rip-cage-auzj: same scoping as D4 above -- key on drift/reconcile
# vocabulary, not raw stderr emptiness, so an unrelated pre-existing cage's
# image-mismatch warning doesn't false-red this assertion.
if ! printf '%s' "$D4B_ERR" | grep -qi "reconcile\|seed-fingerprint\|dist/default-tools"; then
  pass "D4B intersecting-entries-all-match manifest produces zero drift/reconcile wording on stderr"
else
  fail "D4B intersecting-entries-all-match manifest produces zero drift/reconcile wording on stderr" "stderr=$D4B_ERR"
fi

echo ""

# ---------------------------------------------------------------------------
# D4C (rip-cage-6vt9 F1 review fold, THE BEAD'S OWN REPRO SHAPE): unstamped
#     manifest with ONE intersecting entry ('gh') whose content DIFFERS from
#     dist's current 'gh' entry (a stale egress list, standing in for "seeded
#     by an older rc whose recipes have since changed") -> the strengthened
#     warning: names the differing entry, states the staleness stake
#     (customized OR seeded-by-an-older-rc; a stale seed silently bakes
#     superseded recipe layouts), points at 'rc manifest reconcile'. Build
#     still exits 0 (informational, never blocking).
# ---------------------------------------------------------------------------
echo "-- D4C: unstamped, one intersecting entry differs from dist -> strengthened warning --"

D4C_MANIFEST="${MSD_TMP}/d4c-tools.yaml"
cat > "$D4C_MANIFEST" <<'YAML'
version: 1
tools:
  - name: gh
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - api.github.com
    mounts: []
YAML

D4C_STUB_DIR=$(_msd_new_stub_dir)
D4C_ERR_FILE="${MSD_TMP}/d4c-err"
D4C_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _msd_new_stub_dir's fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${D4C_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$D4C_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$D4C_ERR_FILE" || D4C_EXIT=$?
D4C_ERR=$(cat "$D4C_ERR_FILE" 2>/dev/null || true)

if [[ "$D4C_EXIT" -eq 0 ]]; then
  pass "D4Cz build still succeeds (strengthened warning is informational, not blocking)"
else
  fail "D4Cz build still succeeds (strengthened warning is informational, not blocking)" "exit=$D4C_EXIT stderr=$D4C_ERR"
fi
if printf '%s' "$D4C_ERR" | grep -q "gh"; then
  pass "D4Ca strengthened warning names the differing entry ('gh')"
else
  fail "D4Ca strengthened warning names the differing entry ('gh')" "stderr=$D4C_ERR"
fi
if printf '%s' "$D4C_ERR" | grep -qi "customized, or seeded by an older rc\|stale seed silently bakes superseded recipe layouts"; then
  pass "D4Cb strengthened warning names the staleness stake (not just 'provenance unknown')"
else
  fail "D4Cb strengthened warning names the staleness stake (not just 'provenance unknown')" "stderr=$D4C_ERR"
fi
if printf '%s' "$D4C_ERR" | grep -q "manifest/default-tools.yaml"; then
  pass "D4Cc strengthened warning points at manifest/default-tools.yaml as the refresh source"
else
  fail "D4Cc strengthened warning points at manifest/default-tools.yaml as the refresh source" "stderr=$D4C_ERR"
fi
if printf '%s' "$D4C_ERR" | grep -qi "^Notice:.*provenance"; then
  fail "D4Cd strengthened warning must NOT read as the plain 'provenance unknown' soft notice" "stderr=$D4C_ERR"
else
  pass "D4Cd strengthened warning is distinct from the plain 'provenance unknown' soft notice"
fi

echo ""

# ---------------------------------------------------------------------------
# D5: RC_MANIFEST_GLOBAL pointed AT manifest/default-tools.yaml itself -> the
#     drift check is bypassed entirely (it IS dist; this is the CI/release
#     compose path and must never warn, per ci.yml/release.yml).
# ---------------------------------------------------------------------------
echo "-- D5: RC_MANIFEST_GLOBAL=manifest/default-tools.yaml bypasses the check --"

D5_STUB_DIR=$(_msd_new_stub_dir)
D5_ERR_FILE="${MSD_TMP}/d5-err"
D5_EXIT=0
# rip-cage-d2bo kind-1 (harmless): PATH-prefixed with _msd_new_stub_dir's fake docker shim (defined above) -- no real docker build/run ever executes.
PATH="${D5_STUB_DIR}:$PATH" \
  RC_MANIFEST_GLOBAL="$DIST_MANIFEST" \
  bash "$RC" build >/dev/null 2>"$D5_ERR_FILE" || D5_EXIT=$?
D5_ERR=$(cat "$D5_ERR_FILE" 2>/dev/null || true)

if [[ "$D5_EXIT" -eq 0 ]]; then
  pass "D5z build succeeds cleanly against manifest/default-tools.yaml directly"
else
  fail "D5z build succeeds cleanly against manifest/default-tools.yaml directly" "exit=$D5_EXIT stderr=$D5_ERR"
fi
if ! printf '%s' "$D5_ERR" | grep -qi "reconcile\|seed-fingerprint\|provenance"; then
  pass "D5 RC_MANIFEST_GLOBAL=dist bypasses the drift check entirely (no warning/notice)"
else
  fail "D5 RC_MANIFEST_GLOBAL=dist bypasses the drift check entirely (no warning/notice)" "stderr=$D5_ERR"
fi

echo ""

# ---------------------------------------------------------------------------
# D6 RETIRED with `rc manifest reconcile` (rip-cage-ely4.10 / ADR-031 D3).
#
# It drove the verb end to end: preserve a custom entry, refresh a stale
# default-derived one, back the old file up, stamp the new one with the current
# dist hash, disclose that YAML comments do not survive the round-trip, and go
# quiet on the next `rc build`. The verb is deleted -- its successor is editing
# the file -- so every one of those is now the operator's own edit, and there is
# no rc behaviour left to assert.
#
# The DETECTION half, which is what this file is really for, is untouched:
# D1-D5 above still prove `rc build` warns on a stale stamp, stays silent on a
# matching one, soft-notices an unstamped file, and never warns when
# RC_MANIFEST_GLOBAL points at dist itself. The manifest layer retires whole in
# rip-cage-ely4.11 (ADR-031 D4), which is when the rest of this file goes.

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
