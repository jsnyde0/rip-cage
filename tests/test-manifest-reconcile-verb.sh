#!/usr/bin/env bash
# tests/test-manifest-reconcile-verb.sh — rip-cage-9oyh §4 gap-fill: `rc
# manifest reconcile` (the VERB, distinct from the existing dense manifest
# *validator* suite — coverage-gap inventory: "thin vs. the huge validator
# coverage; reconcile/backup path"). Byte-diff coverage of a single happy
# path lives in tests/golden-master/cases.sh (`manifest_reconcile`); this
# file adds explicit assertions on the backup-before-overwrite invariant
# (rip-cage-6vt9) and the validation-failure-abort path.
#
# Wired into tests/run-host.sh (host-only tier).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GM_LIB="${SCRIPT_DIR}/golden-master/lib"
# shellcheck source=golden-master/lib/sandbox.sh
source "${GM_LIB}/sandbox.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# R1: backup-before-overwrite -- a pre-existing local tools.yaml is copied
# to a .bak-<timestamp> file BEFORE being overwritten, with byte-identical
# content to the pre-reconcile original (the real recovery path).
# ---------------------------------------------------------------------------
gm_sandbox_reset
ORIGINAL_CONTENT='version: 1
tools:
  - name: my-custom-tool
    archetype: TOOL
    version_pin: "1.0.0"
    egress: []
    mounts: []
    install_cmd: "true"
'
printf '%s' "$ORIGINAL_CONTENT" > "${GM_XDG}/rip-cage/tools.yaml"

gm_capture manifest reconcile

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "R1: reconcile with a valid custom entry exits 0"
else
  fail "R1 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi

BACKUP_FILE=$(find "${GM_XDG}/rip-cage" -maxdepth 1 -name 'tools.yaml.bak-*' 2>/dev/null | head -1)
if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
  pass "R1b: a tools.yaml.bak-<TS> backup file was created"
else
  fail "R1b backup created" "no tools.yaml.bak-* file found under ${GM_XDG}/rip-cage"
fi

if [[ -n "$BACKUP_FILE" ]]; then
  # diff on the files directly (not `$(...)`-captured strings, which strip
  # trailing newlines and would mask a real trailing-newline regression).
  if diff -q <(printf '%s' "$ORIGINAL_CONTENT") "$BACKUP_FILE" >/dev/null 2>&1; then
    pass "R1c: the backup is byte-identical to the pre-reconcile original (the real recovery path -- comments/formatting untouched)"
  else
    fail "R1c backup fidelity" "backup content differs from the original pre-reconcile file:
$(diff <(printf '%s' "$ORIGINAL_CONTENT") "$BACKUP_FILE")"
  fi
fi

if grep -qF "my-custom-tool" "${GM_XDG}/rip-cage/tools.yaml"; then
  pass "R1d: the custom (non-default) entry is preserved in the reconciled manifest"
else
  fail "R1d preserved entry" "my-custom-tool missing from the post-reconcile manifest"
fi

if echo "$GM_ERR" | grep -qi "Backup of the previous manifest"; then
  pass "R1e: reconcile's stderr summary names the backup"
else
  fail "R1e backup message" "stderr did not mention the backup: $GM_ERR"
fi

# ---------------------------------------------------------------------------
# R2: no pre-existing local manifest -> no backup file, reconcile still
# succeeds (first-run case; backup is conditional on the local file existing
# per rc:9004 `if [[ -f "$_local_path" ]]`).
# ---------------------------------------------------------------------------
gm_sandbox_reset
rm -f "${GM_XDG}/rip-cage/tools.yaml"
gm_capture manifest reconcile

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "R2: reconcile with NO pre-existing local manifest exits 0"
else
  fail "R2 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi
BACKUP_COUNT=$(find "${GM_XDG}/rip-cage" -maxdepth 1 -name 'tools.yaml.bak-*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$BACKUP_COUNT" -eq 0 ]]; then
  pass "R2b: no backup file created when there was nothing to back up"
else
  fail "R2b no spurious backup" "found $BACKUP_COUNT backup file(s) despite no pre-existing manifest"
fi

# ---------------------------------------------------------------------------
# R3: an INVALID local manifest (custom TOOL entry missing required
# install_cmd) fails validation -- the original file is left UNTOUCHED (no
# backup, no overwrite; rc:8998's explicit "aborting; the original manifest
# ... is untouched" contract).
# ---------------------------------------------------------------------------
gm_sandbox_reset
INVALID_CONTENT='version: 1
tools:
  - name: broken-custom-tool
    archetype: TOOL
    version_pin: "1.0.0"
    egress: []
    mounts: []
'
printf '%s' "$INVALID_CONTENT" > "${GM_XDG}/rip-cage/tools.yaml"
gm_capture manifest reconcile

if [[ "$GM_EXIT" -ne 0 ]]; then
  pass "R3: reconcile with an invalid custom entry (missing install_cmd) exits non-zero"
else
  fail "R3 exit" "expected non-zero, got 0"
fi
if diff -q <(printf '%s' "$INVALID_CONTENT") "${GM_XDG}/rip-cage/tools.yaml" >/dev/null 2>&1; then
  pass "R3b: the original (invalid) manifest is left byte-identical after the aborted reconcile"
else
  fail "R3b original untouched" "the local manifest was modified despite validation failure:
$(diff <(printf '%s' "$INVALID_CONTENT") "${GM_XDG}/rip-cage/tools.yaml")"
fi
BACKUP_COUNT_R3=$(find "${GM_XDG}/rip-cage" -maxdepth 1 -name 'tools.yaml.bak-*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$BACKUP_COUNT_R3" -eq 0 ]]; then
  pass "R3c: no backup file is created on a validation-failure abort (nothing was changed)"
else
  fail "R3c no spurious backup on abort" "found $BACKUP_COUNT_R3 backup file(s) despite the reconcile aborting"
fi
if echo "$GM_ERR" | grep -qi "aborting"; then
  pass "R3d: stderr explains the abort"
else
  fail "R3d abort message" "stderr did not mention the abort: $GM_ERR"
fi

# ---------------------------------------------------------------------------
# R4: `rc manifest reconcile --help` prints usage and exits 0, having
# touched no file (rip-cage-xrcr DEFECT 1 -- an unrecognised trailing token,
# including --help, used to fall straight through into the real merge).
# ---------------------------------------------------------------------------
gm_sandbox_reset
R4_CONTENT='version: 1
tools:
  - name: my-custom-tool
    archetype: TOOL
    version_pin: "1.0.0"
    egress: []
    mounts: []
    install_cmd: "true"
'
printf '%s' "$R4_CONTENT" > "${GM_XDG}/rip-cage/tools.yaml"
R4_MTIME_BEFORE=$(stat -f "%m" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null || stat -c "%Y" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null)

gm_capture manifest reconcile --help

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "R4: reconcile --help exits 0"
else
  fail "R4 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi
if echo "$GM_OUT" | grep -qi "Usage: rc manifest reconcile"; then
  pass "R4b: reconcile --help prints a usage block on stdout"
else
  fail "R4b usage on stdout" "stdout did not contain usage text: $GM_OUT"
fi
R4_MTIME_AFTER=$(stat -f "%m" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null || stat -c "%Y" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null)
if [[ "$R4_MTIME_BEFORE" == "$R4_MTIME_AFTER" ]] && diff -q <(printf '%s' "$R4_CONTENT") "${GM_XDG}/rip-cage/tools.yaml" >/dev/null 2>&1; then
  pass "R4c: --help left the fixture manifest's mtime and bytes unchanged"
else
  fail "R4c untouched" "mtime before=$R4_MTIME_BEFORE after=$R4_MTIME_AFTER; diff:
$(diff <(printf '%s' "$R4_CONTENT") "${GM_XDG}/rip-cage/tools.yaml" 2>&1)"
fi

# ---------------------------------------------------------------------------
# R5: an unknown flag exits 2, having touched no file (rip-cage-xrcr DEFECT
# 1's negative control). NOTE: `--dry-run` itself is NOT usable for this
# case -- it's already intercepted by rc's OWN global flag parser (rc:127,
# pre-existing/unrelated to this bead) and rejected with exit 1 for any
# subcommand other than up/destroy/reload, before argv ever reaches
# _manifest_reconcile at all. `--bogus` is an ordinary unrecognised token
# that actually reaches _manifest_reconcile's new parsing loop.
# ---------------------------------------------------------------------------
gm_sandbox_reset
R5_CONTENT="$R4_CONTENT"
printf '%s' "$R5_CONTENT" > "${GM_XDG}/rip-cage/tools.yaml"
R5_MTIME_BEFORE=$(stat -f "%m" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null || stat -c "%Y" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null)

gm_capture manifest reconcile --bogus

if [[ "$GM_EXIT" -eq 2 ]]; then
  pass "R5: reconcile --bogus (unknown flag) exits 2"
else
  fail "R5 exit" "expected 2, got $GM_EXIT. stdout=$GM_OUT stderr=$GM_ERR"
fi
if echo "$GM_ERR" | grep -qi "unrecognised argument"; then
  pass "R5b: stderr names the unrecognised argument"
else
  fail "R5b unrecognised message" "stderr did not name the unrecognised argument: $GM_ERR"
fi
R5_MTIME_AFTER=$(stat -f "%m" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null || stat -c "%Y" "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null)
if [[ "$R5_MTIME_BEFORE" == "$R5_MTIME_AFTER" ]] && diff -q <(printf '%s' "$R5_CONTENT") "${GM_XDG}/rip-cage/tools.yaml" >/dev/null 2>&1; then
  pass "R5c: an unknown flag left the fixture manifest's mtime and bytes unchanged"
else
  fail "R5c untouched" "mtime before=$R5_MTIME_BEFORE after=$R5_MTIME_AFTER; diff:
$(diff <(printf '%s' "$R5_CONTENT") "${GM_XDG}/rip-cage/tools.yaml" 2>&1)"
fi
BACKUP_COUNT_R5=$(find "${GM_XDG}/rip-cage" -maxdepth 1 -name 'tools.yaml.bak-*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$BACKUP_COUNT_R5" -eq 0 ]]; then
  pass "R5d: no backup file is created when an unknown flag is refused"
else
  fail "R5d no spurious backup" "found $BACKUP_COUNT_R5 backup file(s) despite the unknown-flag refusal"
fi

# ---------------------------------------------------------------------------
# R6: the local manifest path is a SYMLINK under the temp XDG dir, pointing
# at a real file elsewhere under the temp HOME. After reconcile, the path is
# STILL a symlink (rip-cage-xrcr DEFECT 2 -- `mv` used to replace the
# symlink itself with a regular file) AND the link target's content changed
# (reconcile wrote THROUGH the link).
# ---------------------------------------------------------------------------
gm_sandbox_reset
R6_REAL_DIR="${GM_HOME}/real-manifest-store"
mkdir -p "$R6_REAL_DIR"
R6_REAL_TARGET="${R6_REAL_DIR}/tools.yaml"
R6_ORIGINAL_CONTENT='version: 1
tools:
  - name: my-symlinked-custom-tool
    archetype: TOOL
    version_pin: "1.0.0"
    egress: []
    mounts: []
    install_cmd: "true"
'
printf '%s' "$R6_ORIGINAL_CONTENT" > "$R6_REAL_TARGET"
rm -f "${GM_XDG}/rip-cage/tools.yaml"
ln -s "$R6_REAL_TARGET" "${GM_XDG}/rip-cage/tools.yaml"

gm_capture manifest reconcile

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "R6: reconcile against a symlinked local manifest exits 0"
else
  fail "R6 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi
if [[ -L "${GM_XDG}/rip-cage/tools.yaml" ]]; then
  pass "R6b: the local manifest path is STILL a symlink after reconcile"
else
  fail "R6b symlink survived" "${GM_XDG}/rip-cage/tools.yaml is no longer a symlink after reconcile"
fi
R6_LINK_TARGET=$(readlink "${GM_XDG}/rip-cage/tools.yaml" 2>/dev/null || true)
if [[ "$R6_LINK_TARGET" == "$R6_REAL_TARGET" ]]; then
  pass "R6c: the symlink still points at the same original real target"
else
  fail "R6c link target unchanged" "expected '$R6_REAL_TARGET', got '$R6_LINK_TARGET'"
fi
if [[ -f "$R6_REAL_TARGET" ]] && ! diff -q <(printf '%s' "$R6_ORIGINAL_CONTENT") "$R6_REAL_TARGET" >/dev/null 2>&1; then
  pass "R6d: the link target's content changed (reconcile wrote THROUGH the link)"
else
  fail "R6d target content changed" "the real target's content is unchanged (or missing) after reconcile"
fi
if grep -qF "my-symlinked-custom-tool" "$R6_REAL_TARGET" 2>/dev/null; then
  pass "R6e: the custom entry is preserved in the reconciled target content"
else
  fail "R6e preserved entry" "my-symlinked-custom-tool missing from the reconciled target"
fi

# ---------------------------------------------------------------------------
# R7: the local manifest path is a SYMLINK whose target resolves OUTSIDE
# $HOME (rip-cage-xrcr DEFECT 2's refuse branch -- R6 above covers the
# inside-$HOME write-through; this covers the other branch: reconcile must
# refuse rather than write to a file outside the sandbox, leaving both the
# symlink and its target untouched).
# ---------------------------------------------------------------------------
gm_sandbox_reset
R7_OUTSIDE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-xrcr-outside-home-XXXXXX")
R7_OUTSIDE_TARGET="${R7_OUTSIDE_DIR}/tools.yaml"
R7_ORIGINAL_CONTENT='version: 1
tools:
  - name: my-outside-custom-tool
    archetype: TOOL
    version_pin: "1.0.0"
    egress: []
    mounts: []
    install_cmd: "true"
'
printf '%s' "$R7_ORIGINAL_CONTENT" > "$R7_OUTSIDE_TARGET"
rm -f "${GM_XDG}/rip-cage/tools.yaml"
ln -s "$R7_OUTSIDE_TARGET" "${GM_XDG}/rip-cage/tools.yaml"

gm_capture manifest reconcile

if [[ "$GM_EXIT" -ne 0 ]]; then
  pass "R7: reconcile against a symlink resolving outside \$HOME refuses (non-zero exit)"
else
  fail "R7 exit" "expected non-zero, got 0"
fi
if [[ -L "${GM_XDG}/rip-cage/tools.yaml" ]]; then
  pass "R7b: the local manifest path is STILL a symlink after the refused reconcile"
else
  fail "R7b symlink survived" "${GM_XDG}/rip-cage/tools.yaml is no longer a symlink after reconcile"
fi
if [[ -f "$R7_OUTSIDE_TARGET" ]] && diff -q <(printf '%s' "$R7_ORIGINAL_CONTENT") "$R7_OUTSIDE_TARGET" >/dev/null 2>&1; then
  pass "R7c: the outside-\$HOME target's content is byte-identical to before the refused reconcile"
else
  fail "R7c target untouched" "the outside-\$HOME target changed (or is missing) after the refused reconcile:
$(diff <(printf '%s' "$R7_ORIGINAL_CONTENT") "$R7_OUTSIDE_TARGET" 2>&1)"
fi
# realpath, not the raw mktemp path: manifest.sh's refuse message names
# the REALPATH-resolved target (macOS /tmp -> /private/tmp symlink means
# these two strings legitimately differ on this OS).
R7_OUTSIDE_TARGET_REAL=$(realpath "$R7_OUTSIDE_TARGET" 2>/dev/null || echo "$R7_OUTSIDE_TARGET")
if echo "$GM_ERR" | grep -qF "$R7_OUTSIDE_TARGET_REAL"; then
  pass "R7d: stderr names the link target path"
else
  fail "R7d error names target" "stderr did not name the link target '${R7_OUTSIDE_TARGET_REAL}': $GM_ERR"
fi
rm -rf "$R7_OUTSIDE_DIR"

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
