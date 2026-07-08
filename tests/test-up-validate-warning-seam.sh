#!/usr/bin/env bash
# tests/test-up-validate-warning-seam.sh — rip-cage-9oyh §3(iii): the
# RC_VALIDATE_WARNING write (validate_path, rc:601 non-interactive minimum-
# grant path) -> read (_up_json_output, rc:4769) seam. This is a dedicated,
# independently-inspectable assertion on top of the byte-diff coverage
# already folded into tests/golden-master/cases.sh's
# `up_validate_warning_seam` case (per harness spec §3(iii): "Folds into
# §1(a)'s dry-run-json matrix").
#
# Reachability preconditions (harness spec §3(iii), F3): RC_ALLOWED_ROOTS
# must be UNSET (not merely empty) and non-interactive (no TTY) so
# validate_path's rc:601 branch fires and sets RC_VALIDATE_WARNING; a
# RUNNING container (would_attach) reaches the `_up_json_output` branch that
# reads it back unconditionally (the `would_create && image_absent` skip
# only applies to the would_create action).
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

gm_sandbox_reset

WS=$(gm_ws_realpath)
GM_NO_ALLOWED_ROOTS=1 \
GM_DOCKER_STATE=running \
GM_DOCKER_LABEL_SOURCE_PATH="$WS" \
GM_DOCKER_LABEL_EGRESS=on \
GM_DOCKER_LABEL_FWD_SSH=off \
GM_DOCKER_IMAGE_VERSION="$(gm_read_version)" \
  gm_capture --dry-run --output json up "$WS"

EXPECTED_WARNING="RC_ALLOWED_ROOTS unset — allowing ${WS} only."

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "seam reachable: rc --dry-run --output json up exits 0 (would_attach, not an error path)"
else
  fail "seam reachable" "expected exit 0, got $GM_EXIT. stdout=$GM_OUT stderr=$GM_ERR"
fi

ACTUAL_WARNING=$(printf '%s' "$GM_OUT" | jq -r '.warning // empty' 2>/dev/null || true)
if [[ "$ACTUAL_WARNING" == "$EXPECTED_WARNING" ]]; then
  pass "RC_VALIDATE_WARNING write (rc:601) -> JSON 'warning' field read (rc:4769): exact string propagates"
else
  fail "warning field exact string" "expected: [$EXPECTED_WARNING]
got:      [$ACTUAL_WARNING]
full stdout: $GM_OUT"
fi

# Negative control: with RC_ALLOWED_ROOTS explicitly set (the seam's write
# side never fires), the JSON output must NOT carry a 'warning' field at
# all -- proves the assertion above isn't a vacuous always-present field.
gm_sandbox_reset
GM_DOCKER_STATE=running \
GM_DOCKER_LABEL_SOURCE_PATH="$(gm_ws_realpath)" \
GM_DOCKER_LABEL_EGRESS=on \
GM_DOCKER_LABEL_FWD_SSH=off \
GM_DOCKER_IMAGE_VERSION="$(gm_read_version)" \
  gm_capture --dry-run --output json up "$(gm_ws_realpath)"

if printf '%s' "$GM_OUT" | jq -e 'has("warning") | not' >/dev/null 2>&1; then
  pass "negative control: RC_ALLOWED_ROOTS set -> no 'warning' field (not vacuously present)"
else
  fail "negative control" "expected no 'warning' field when RC_ALLOWED_ROOTS is set; got: $GM_OUT"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
