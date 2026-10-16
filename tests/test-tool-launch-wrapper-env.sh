#!/usr/bin/env bash
# test-tool-launch-wrapper-env.sh -- the launch wrapper reads the FIXED boot
# descriptor and ignores a caller-set RC_BOOT_DESCRIPTOR (rip-cage-5ndd).
#
# WHY THIS FILE EXISTS. The agent's interactive zsh runs `mise activate`, and
# mise auto-trusts /workspace (ADR-015 D4). A workspace .mise.toml with
# [env] RC_BOOT_DESCRIPTOR="/nonexistent" therefore lands in the environment of
# every `pi` the agent starts. When cage/boot/tool-launch-wrapper honoured that
# variable it found no descriptor, dropped the launch line, and exec'd pi-real
# without the DCG guard extension -- a workspace-file prompt-injection channel
# (ADR-024) to an unguarded agent, needing no agent action at all.
#
#   W1  no RC_BOOT_DESCRIPTOR: the fixed descriptor's launch line runs, with
#       the caller's arguments appended; no stderr note.
#   W2  RC_BOOT_DESCRIPTOR=/nonexistent: the launch line STILL runs, and one
#       stderr note names the ignored value.
#   W3  RC_BOOT_DESCRIPTOR=<agent-writable file whose launch line is hostile>:
#       the fixed launch line runs, the hostile one does not.
#   W4  RC_BOOT_DESCRIPTOR set to the fixed path itself: no note.
#   W5  no descriptor at the fixed path: <tool>-real runs directly (the base
#       image's own behaviour, unchanged).
#
# Tier: host-only, hermetic. The wrapper hardcodes two absolute paths (the real
# binary dir and the descriptor). This test copies the REPO's wrapper and
# rewrites exactly those two literals into a temp tree, asserting first that
# each appears exactly once -- so a rewrite that misses one fails here rather
# than silently testing a different script.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="${RC_TLW_WRAPPER:-${SCRIPT_DIR}/../cage/boot/tool-launch-wrapper}"

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required (the wrapper reads the descriptor with it)" >&2
  exit 1
fi

REAL_DIR_LIT="/usr/local/lib/rip-cage/bin/"
DESC_LIT="/etc/rip-cage/boot.json"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

# Each literal must appear exactly once outside comments, or the rewrite below
# is not testing the shipped wrapper.
for _lit in "$REAL_DIR_LIT" "$DESC_LIT"; do
  _n=$(grep -v '^[[:space:]]*#' "$WRAPPER_SRC" | grep -cF "$_lit")
  if [ "$_n" != "1" ]; then
    echo "FAIL: expected exactly one non-comment occurrence of ${_lit} in ${WRAPPER_SRC}, found ${_n}" >&2
    exit 1
  fi
done

mkdir -p "${TMP}/bin" "${TMP}/lib/bin" "${TMP}/etc" "${TMP}/ws"
FIXED_DESC="${TMP}/etc/boot.json"

# Rewrite the literals only on non-comment lines, so comments stay untouched.
sed -e "/^[[:space:]]*#/!s|${REAL_DIR_LIT}|${TMP}/lib/bin/|" \
    -e "/^[[:space:]]*#/!s|${DESC_LIT}|${FIXED_DESC}|" \
    "$WRAPPER_SRC" >"${TMP}/bin/pi"
chmod 0755 "${TMP}/bin/pi"

printf '#!/bin/sh\necho "REAL $*"\n' >"${TMP}/lib/bin/pi-real"
printf '#!/bin/sh\necho "GUARD $*"\n' >"${TMP}/guard.sh"
printf '#!/bin/sh\necho "EVIL $*"\n' >"${TMP}/ws/evil.sh"
chmod 0755 "${TMP}/lib/bin/pi-real" "${TMP}/guard.sh" "${TMP}/ws/evil.sh"

jq -n --arg l "${TMP}/guard.sh" '{tools: [{name: "pi", launch: $l}]}' >"$FIXED_DESC"
jq -n --arg l "${TMP}/ws/evil.sh" '{tools: [{name: "pi", launch: $l}]}' >"${TMP}/ws/boot.json"

# run_wrapper <env-assignment-or-empty> -- sets OUT and ERR.
run_wrapper() {
  if [ -n "$1" ]; then
    env "$1" "${TMP}/bin/pi" --help a b >"${TMP}/out" 2>"${TMP}/err"
  else
    env -u RC_BOOT_DESCRIPTOR "${TMP}/bin/pi" --help a b >"${TMP}/out" 2>"${TMP}/err"
  fi
  OUT=$(cat "${TMP}/out")
  ERR=$(cat "${TMP}/err")
}

echo "W1 no override"
run_wrapper ""
if [ "$OUT" = "GUARD --help a b" ]; then pass "launch line runs with args"; else fail "W1 stdout: '${OUT}'"; fi
if [ -z "$ERR" ]; then pass "no stderr note"; else fail "W1 stderr: '${ERR}'"; fi

echo "W2 RC_BOOT_DESCRIPTOR=/nonexistent"
run_wrapper "RC_BOOT_DESCRIPTOR=/nonexistent"
if [ "$OUT" = "GUARD --help a b" ]; then pass "launch line still runs"; else fail "W2 stdout: '${OUT}' (guard dropped)"; fi
if printf '%s' "$ERR" | grep -qF "/nonexistent" && [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = "1" ]; then
  pass "one stderr note names the ignored value"
else
  fail "W2 stderr: '${ERR}'"
fi

echo "W3 RC_BOOT_DESCRIPTOR=<agent-writable hostile descriptor>"
run_wrapper "RC_BOOT_DESCRIPTOR=${TMP}/ws/boot.json"
if [ "$OUT" = "GUARD --help a b" ]; then pass "fixed launch line runs, hostile one does not"; else fail "W3 stdout: '${OUT}'"; fi
if printf '%s' "$ERR" | grep -qF "${TMP}/ws/boot.json"; then pass "stderr note names the ignored value"; else fail "W3 stderr: '${ERR}'"; fi

echo "W4 RC_BOOT_DESCRIPTOR equal to the fixed path"
run_wrapper "RC_BOOT_DESCRIPTOR=${FIXED_DESC}"
if [ "$OUT" = "GUARD --help a b" ]; then pass "launch line runs"; else fail "W4 stdout: '${OUT}'"; fi
if [ -z "$ERR" ]; then pass "no stderr note"; else fail "W4 stderr: '${ERR}'"; fi

echo "W5 no descriptor at the fixed path"
rm -f "$FIXED_DESC"
run_wrapper ""
if [ "$OUT" = "REAL --help a b" ]; then pass "<tool>-real runs directly"; else fail "W5 stdout: '${OUT}'"; fi

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: ${FAILURES} check(s) failed"
  exit 1
fi
echo "PASS: tool-launch-wrapper ignores a caller-set RC_BOOT_DESCRIPTOR"
