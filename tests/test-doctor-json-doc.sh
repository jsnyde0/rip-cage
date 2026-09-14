#!/usr/bin/env bash
# tests/test-doctor-json-doc.sh -- static doc-vs-emitter consistency check for
# `rc doctor <name> --output json`'s top-level field set (rip-cage-bbjn), and
# for `rc doctor --host --output json`'s separate field set (rip-cage-pou6).
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
# This test's PART 1 covers the per-cage emitter only -- the same scope the
# doc section documents and the bead's field inventory (name, state, uptime,
# source_path, source_path_missing_hint, labels{}, probes{}) describes. The
# anchor patterns below (`^ *'{$` and `end)'`) are chosen specifically because
# they match ONLY the per-cage emitter's block, not `_doctor_host`'s
# single-line literal -- verified interactively during authorship.
#
# PART 2 (rip-cage-pou6) applies the same both-directions technique to
# `_doctor_host`'s single-line `'{...}'` emitter and its own doc section
# ("## `rc doctor --host --output json` fields"), anchored by the
# `_doctor_host() {` / matching `^}` function boundaries so it can never
# accidentally re-scan PART 1's block.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
DOCTOR_SH="${REPO_ROOT}/cli/doctor.sh"
DOC_FILE="${REPO_ROOT}/docs/reference/cli-reference.md"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== test-doctor-json-doc.sh: rc doctor --output json field doc consistency ==="
echo ""
echo "=== PART 1: rc doctor <name> --output json (per-cage emitter, cmd_doctor) ==="

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
echo "=== PART 2: rc doctor --host --output json (host-scope emitter, _doctor_host) ==="

# ---------------------------------------------------------------------------
# Step 1 (host): derive the EMITTED top-level key set from _doctor_host in
# cli/doctor.sh.
#
# _doctor_host's JSON emitter is a single `jq -nc ... '{k: $v, ...}'` call
# whose object literal lives on ONE line (no nesting, unlike cmd_doctor's
# multi-line block with a merge tail) -- so the key set is derived by first
# bounding the scan to _doctor_host's own function body (anchored by its
# `_doctor_host() {` definition and the next column-0 `^}` after it, so this
# can never drift into cmd_doctor's block), then picking out the one line
# inside that body matching the flat `'{...}'` literal shape, then reusing
# the same depth-1 key scan PART 1 uses above.
# ---------------------------------------------------------------------------
_host_start_line=$(grep -n "^_doctor_host() {" "$DOCTOR_SH" | head -1 | cut -d: -f1)

if [[ -z "$_host_start_line" ]]; then
  fail "could not locate _doctor_host's function definition in $DOCTOR_SH (anchor \"^_doctor_host() {\" not found -- function renamed or moved?)"
  echo ""
  echo "=== Results ==="
  echo "1 test(s) failed"
  exit 1
fi

_host_end_line=$(awk -v start="$_host_start_line" 'NR > start && /^}/ { print NR; exit }' "$DOCTOR_SH")

if [[ -z "$_host_end_line" ]]; then
  fail "could not locate _doctor_host's closing brace in $DOCTOR_SH after line ${_host_start_line}"
  echo ""
  echo "=== Results ==="
  echo "1 test(s) failed"
  exit 1
fi

_host_json_line=$(sed -n "${_host_start_line},${_host_end_line}p" "$DOCTOR_SH" | grep -E "^ *'\{.*\}'$" | head -1)

if [[ -z "$_host_json_line" ]]; then
  fail "could not locate _doctor_host's single-line '{...}' jq literal between lines ${_host_start_line}-${_host_end_line} of $DOCTOR_SH -- emitter shape changed?"
  echo ""
  echo "=== Results ==="
  echo "1 test(s) failed"
  exit 1
fi

_host_emitted_keys=$(printf '%s\n' "$_host_json_line" | awk -v target=1 '
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
echo "--- Emitted top-level keys (derived from _doctor_host, cli/doctor.sh:${_host_start_line}-${_host_end_line}) ---"
echo "$_host_emitted_keys"

if [[ -z "$_host_emitted_keys" ]]; then
  fail "non-vacuity guard: derived host-scope EMITTED key set is empty -- the parse found zero keys, which would make the assertions below pass vacuously. _doctor_host's emitter shape likely changed under this test's anchors."
fi

# ---------------------------------------------------------------------------
# Step 2 (host): derive the DOCUMENTED key set from the host-scope doc
# section in docs/reference/cli-reference.md. Located by a heading containing
# "rc doctor --host --output json" -- distinct text from PART 1's heading
# ("rc doctor --output json"), so the two `grep -n '^#...'` lookups can never
# collide.
# ---------------------------------------------------------------------------
_host_doc_heading_line=$(grep -n '^#\{1,6\} .*rc doctor --host --output json' "$DOC_FILE" | head -1 | cut -d: -f1)

if [[ -z "$_host_doc_heading_line" ]]; then
  fail "could not find a heading containing \"rc doctor --host --output json\" in $DOC_FILE"
  echo ""
  echo "=== Results ==="
  echo "$((FAILURES)) test(s) failed"
  exit 1
fi

_host_documented_keys=$(awk -v start="$_host_doc_heading_line" '
  NR == start { found = 1; next }
  found && /^#/ { exit }
  found { print }
' "$DOC_FILE" | grep -E '^\| `[A-Za-z0-9_]+` \|' | sed -E 's/^\| `([A-Za-z0-9_]+)`.*/\1/' | sort -u)

echo ""
echo "--- Documented top-level keys (from \"$DOC_FILE\" heading at line ${_host_doc_heading_line}) ---"
echo "$_host_documented_keys"

if [[ -z "$_host_documented_keys" ]]; then
  fail "non-vacuity guard: derived host-scope DOCUMENTED key set is empty -- the doc-table parse found zero rows, which would make the assertions below pass vacuously. Check the '| \`key\` | ... |' table row format under the \"rc doctor --host --output json\" heading."
fi

# ---------------------------------------------------------------------------
# Step 3 (host): both-direction assertion.
# ---------------------------------------------------------------------------
echo ""
echo "=== Direction 1 (host): every EMITTED key is DOCUMENTED ==="
_host_missing_from_doc=""
while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  if ! grep -qxF "$_k" <<<"$_host_documented_keys"; then
    _host_missing_from_doc="${_host_missing_from_doc}${_k} "
  fi
done <<<"$_host_emitted_keys"

if [[ -z "$_host_missing_from_doc" ]]; then
  pass "every host-scope emitted top-level key is named in the doc section"
else
  fail "host-scope emitted key(s) NOT documented: ${_host_missing_from_doc}"
fi

echo ""
echo "=== Direction 2 (host): every DOCUMENTED key is EMITTED ==="
_host_missing_from_emitter=""
while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  if ! grep -qxF "$_k" <<<"$_host_emitted_keys"; then
    _host_missing_from_emitter="${_host_missing_from_emitter}${_k} "
  fi
done <<<"$_host_documented_keys"

if [[ -z "$_host_missing_from_emitter" ]]; then
  pass "every host-scope documented top-level key is actually emitted"
else
  fail "host-scope documented key(s) NOT emitted: ${_host_missing_from_emitter}"
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
