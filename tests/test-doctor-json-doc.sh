#!/usr/bin/env bash
# tests/test-doctor-json-doc.sh -- static doc-vs-emitter consistency check for
# `rc doctor <name> --output json`'s top-level field set (rip-cage-bbjn).
#
# rip-cage-u625 added `source_path_missing_hint` to the doctor JSON but its
# criterion 3 ("document the field wherever the JSON fields are listed") was
# waived because no such listing existed anywhere under docs/ (brain:rip-cage
# driver raise 00065ab8858253971ccf4746, option (c)). rip-cage-bbjn adds the
# listing (docs/reference/cli-reference.md, "## `rc doctor --output json`
# fields" section) and this test, which keeps the two in sync going forward
# in BOTH directions:
#   - every key the emitter can produce is named in the doc section
#   - every key named in the doc section is actually emitted
#
# Host-only, no cage/docker required -- this is a pure text/static check
# against cli/doctor.sh and docs/reference/cli-reference.md.
#
# Scope note: cli/doctor.sh contains TWO distinct JSON emitters --
# `cmd_doctor`'s per-cage emitter (`rc doctor <name> --output json`, anchored
# below via its unique `'{` / `end)'` markers) and `_doctor_host`'s
# host-scope emitter (`rc doctor --host --output json`, a single-line `'{...}'`
# literal with an entirely different key set: scope/daemon/docker_info_rc/...).
# This test's contract is the per-cage emitter only -- the same scope the doc
# section documents and the bead's field inventory (name, state, uptime,
# source_path, source_path_missing_hint, labels{}, probes{}) describes. The
# anchor patterns below (`^ *'{$` and `end)'`) are chosen specifically because
# they match ONLY the per-cage emitter's block, not `_doctor_host`'s
# single-line literal -- verified interactively during authorship.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
DOCTOR_SH="${REPO_ROOT}/cli/doctor.sh"
DOC_FILE="${REPO_ROOT}/docs/reference/cli-reference.md"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== test-doctor-json-doc.sh: rc doctor --output json field doc consistency ==="

# ---------------------------------------------------------------------------
# Step 1: derive the EMITTED top-level key set from cli/doctor.sh.
#
# The per-cage JSON emitter builds one jq object literal (top-level keys at
# brace-depth 1, e.g. `name: $name`, `labels: { ... }`) plus a trailing
# `+ (if COND then {} else {source_path_missing_hint: ...} end)` merge whose
# else-branch key is ALSO at brace-depth 1 relative to its own `{` -- so a
# single generic brace-depth scan over the whole block correctly classifies
# both the always-present keys and the one conditionally-merged key as
# top-level, with no special-casing of the merge idiom required. Nested keys
# (inside `labels`/`probes`) land at depth 2 and are excluded.
# ---------------------------------------------------------------------------
_start_line=$(grep -n "^ *'{$" "$DOCTOR_SH" | head -1 | cut -d: -f1)
_end_line=$(grep -n "end)'" "$DOCTOR_SH" | head -1 | cut -d: -f1)

if [[ -z "$_start_line" || -z "$_end_line" ]]; then
  fail "could not locate cmd_doctor's JSON emitter block in $DOCTOR_SH (anchors \"^ *'{\$\" / \"end)'\" not found -- emitter shape changed?)"
  echo ""
  echo "=== Results ==="
  echo "1 test(s) failed"
  exit 1
fi

_emitted_flat=$(sed -n "${_start_line},${_end_line}p" "$DOCTOR_SH" | tr '\n' ' ')

_emitted_keys=$(printf '%s\n' "$_emitted_flat" | awk -v target=1 '
{
  s = $0
  pos = 1
  n = length(s)
  while (pos <= n) {
    rest = substr(s, pos)
    if (!match(rest, /("[^"]+"|[A-Za-z_][A-Za-z0-9_.-]*)[ \t]*:/)) break
    matchstart = pos + RSTART - 1
    matchlen = RLENGTH
    keytext = substr(s, matchstart, matchlen)
    prefix = substr(s, 1, matchstart - 1)
    opens = gsub(/\{/, "{", prefix)
    closes = gsub(/\}/, "}", prefix)
    depth = opens - closes
    key = keytext
    sub(/[ \t]*:$/, "", key)
    gsub(/"/, "", key)
    if (depth == target) print key
    pos = matchstart + matchlen
  }
}' | sort -u)

echo ""
echo "--- Emitted top-level keys (derived from cli/doctor.sh:${_start_line}-${_end_line}) ---"
echo "$_emitted_keys"

if [[ -z "$_emitted_keys" ]]; then
  fail "non-vacuity guard: derived EMITTED key set is empty -- the parse found zero keys, which would make the assertions below pass vacuously. cli/doctor.sh's emitter shape likely changed under this test's anchors."
fi

# ---------------------------------------------------------------------------
# Step 2: derive the DOCUMENTED key set from the doc section in
# docs/reference/cli-reference.md. Locate the section by its heading (must
# contain the words "rc doctor --output json"), scan until the next heading,
# and pull the first column of each `| `key` | ... |` table row.
# ---------------------------------------------------------------------------
_doc_heading_line=$(grep -n '^#\{1,6\} .*rc doctor --output json' "$DOC_FILE" | head -1 | cut -d: -f1)

if [[ -z "$_doc_heading_line" ]]; then
  fail "could not find a heading containing \"rc doctor --output json\" in $DOC_FILE"
  echo ""
  echo "=== Results ==="
  echo "1 test(s) failed"
  exit 1
fi

_documented_keys=$(awk -v start="$_doc_heading_line" '
  NR == start { found = 1; next }
  found && /^#/ { exit }
  found { print }
' "$DOC_FILE" | grep -E '^\| `[A-Za-z0-9_]+` \|' | sed -E 's/^\| `([A-Za-z0-9_]+)`.*/\1/' | sort -u)

echo ""
echo "--- Documented top-level keys (from \"$DOC_FILE\" heading at line ${_doc_heading_line}) ---"
echo "$_documented_keys"

if [[ -z "$_documented_keys" ]]; then
  fail "non-vacuity guard: derived DOCUMENTED key set is empty -- the doc-table parse found zero rows, which would make the assertions below pass vacuously. Check the '| \`key\` | ... |' table row format under the \"rc doctor --output json\" heading."
fi

# ---------------------------------------------------------------------------
# Step 3: both-direction assertion.
# ---------------------------------------------------------------------------
echo ""
echo "=== Direction 1: every EMITTED key is DOCUMENTED ==="
_missing_from_doc=""
while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  if ! grep -qxF "$_k" <<<"$_documented_keys"; then
    _missing_from_doc="${_missing_from_doc}${_k} "
  fi
done <<<"$_emitted_keys"

if [[ -z "$_missing_from_doc" ]]; then
  pass "every emitted top-level key is named in the doc section"
else
  fail "emitted key(s) NOT documented: ${_missing_from_doc}"
fi

echo ""
echo "=== Direction 2: every DOCUMENTED key is EMITTED ==="
_missing_from_emitter=""
while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  if ! grep -qxF "$_k" <<<"$_emitted_keys"; then
    _missing_from_emitter="${_missing_from_emitter}${_k} "
  fi
done <<<"$_documented_keys"

if [[ -z "$_missing_from_emitter" ]]; then
  pass "every documented top-level key is actually emitted"
else
  fail "documented key(s) NOT emitted: ${_missing_from_emitter}"
fi

echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
