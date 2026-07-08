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

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
