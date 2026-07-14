#!/usr/bin/env bash
# tests/test-rc-install.sh — rip-cage-9oyh §4 gap-fill: `rc install`
# (coverage-gap inventory: "2 incidental refs; installer/symlink path has
# no dedicated master"). Byte-diff coverage of the `--yes` happy path lives
# in tests/golden-master/cases.sh (`install_yes`); this file adds
# idempotency + --force + non-interactive-without---yes assertions.
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
# I1: no existing config.yaml -> --yes writes the proposed default denylist,
# exit 0.
# ---------------------------------------------------------------------------
gm_sandbox_reset
rm -f "${GM_XDG}/rip-cage/config.yaml"
gm_capture install --yes

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "I1: install --yes (no pre-existing config) exits 0"
else
  fail "I1 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi
if [[ -f "${GM_XDG}/rip-cage/config.yaml" ]]; then
  pass "I1b: config.yaml was written"
else
  fail "I1b file written" "config.yaml missing after install --yes"
fi
if grep -q '\.ssh' "${GM_XDG}/rip-cage/config.yaml"; then
  pass "I1c: written config contains the default denylist (.ssh present)"
else
  fail "I1c denylist content" "written config.yaml does not contain the expected default denylist"
fi

# ---------------------------------------------------------------------------
# I2: idempotency -- running install --yes AGAIN once the file already
# matches the proposal is a no-op (exit 0, "nothing to do", content
# unchanged -- content-equality, not mtime, per the rip-cage-woow lesson).
# ---------------------------------------------------------------------------
BEFORE=$(cat "${GM_XDG}/rip-cage/config.yaml")
gm_capture install --yes
AFTER=$(cat "${GM_XDG}/rip-cage/config.yaml")

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "I2: idempotent second install --yes exits 0"
else
  fail "I2 exit" "expected 0, got $GM_EXIT"
fi
if echo "$GM_OUT" | grep -qi "already matches\|nothing to do"; then
  pass "I2b: idempotent second run reports nothing-to-do"
else
  fail "I2b message" "expected a 'nothing to do' message; got: $GM_OUT"
fi
if [[ "$BEFORE" == "$AFTER" ]]; then
  pass "I2c: idempotent second run does not rewrite the file (content-equality)"
else
  fail "I2c content-equality" "config.yaml content changed across an idempotent re-run"
fi

# ---------------------------------------------------------------------------
# I3: a DIFFERENT existing config.yaml -> install --yes shows a diff and
# OVERWRITES it (install always writes when content differs, regardless of
# --force -- --force only matters when content ALREADY matches).
# ---------------------------------------------------------------------------
gm_sandbox_reset
cat > "${GM_XDG}/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist:
    - .custom-only-entry
  allow_risky: null
YAML
gm_capture install --yes

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "I3: install --yes over a DIFFERING existing config exits 0"
else
  fail "I3 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi
if echo "$GM_OUT" | grep -qi "differs from proposed"; then
  pass "I3b: differing existing config surfaces a diff message"
else
  fail "I3b diff message" "expected a 'differs from proposed' message; got: $GM_OUT"
fi
if ! grep -q '.custom-only-entry' "${GM_XDG}/rip-cage/config.yaml"; then
  pass "I3c: the differing file was overwritten with the proposed default"
else
  fail "I3c overwrite" "custom entry still present after install --yes -- file was not overwritten"
fi

# ---------------------------------------------------------------------------
# I4: without --yes and a non-TTY stdin, install refuses (fail-loud, no
# accidental unattended write).
# ---------------------------------------------------------------------------
gm_sandbox_reset
rm -f "${GM_XDG}/rip-cage/config.yaml"
gm_capture install

if [[ "$GM_EXIT" -ne 0 ]]; then
  pass "I4: install without --yes on non-TTY stdin exits non-zero"
else
  fail "I4 exit" "expected non-zero, got 0"
fi
if [[ ! -f "${GM_XDG}/rip-cage/config.yaml" ]]; then
  pass "I4b: no file was written without --yes on non-TTY"
else
  fail "I4b no unattended write" "config.yaml was written despite no --yes and no TTY"
fi
if echo "$GM_ERR" | grep -qi "tty\|--yes"; then
  pass "I4c: stderr explains the --yes requirement"
else
  fail "I4c message" "stderr did not mention --yes/TTY: $GM_ERR"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
