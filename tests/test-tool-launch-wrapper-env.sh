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
#   W6  hostile PATH (a workspace .mise.toml [env] _.path can prepend one):
#       fake jq, sh and basename first on PATH -- the fixed launch line still
#       runs, never the real tool unguarded and never a fake.
#   W7  the descriptor is unreadable by jq (malformed): the launch is REFUSED
#       (non-zero, one stderr reason line), never the real tool unguarded.
#   W8  the wrapper's jq is missing: the launch is refused the same way.
#   W9  the stderr note prints the caller's value verbatim, never interpreting
#       backslash escapes (dash's and zsh's echo do; the image's /bin/sh is
#       dash). Runs the wrapper under dash or zsh, whichever the host has.
#
# Tier: host-only, hermetic. The wrapper hardcodes absolute paths (the real
# binary dir, the descriptor, jq). This test copies the REPO's wrapper and
# rewrites exactly those literals into a temp tree, asserting first that each
# appears exactly once -- so a rewrite that misses one fails here rather than
# silently testing a different script.
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

mkdir -p "${TMP}/bin" "${TMP}/nojq/bin" "${TMP}/lib/bin" "${TMP}/etc" "${TMP}/ws" "${TMP}/hostile"
FIXED_DESC="${TMP}/etc/boot.json"
HOST_JQ=$(command -v jq)

# The image installs jq at /usr/bin/jq; the wrapper must name it absolutely.
# Counted, not required, so a wrapper that resolves jq from PATH still runs the
# cases below and fails on behaviour (W6) rather than here.
JQ_LIT="/usr/bin/jq"
_jq_n=$(grep -v '^[[:space:]]*#' "$WRAPPER_SRC" | grep -cF "$JQ_LIT")

# Rewrite the literals only on non-comment lines, so comments stay untouched.
# bin/pi gets the host's jq; nojq/bin/pi gets a jq path that does not exist.
sed -e "/^[[:space:]]*#/!s|${REAL_DIR_LIT}|${TMP}/lib/bin/|" \
    -e "/^[[:space:]]*#/!s|${DESC_LIT}|${FIXED_DESC}|" \
    -e "/^[[:space:]]*#/!s|${JQ_LIT}|${HOST_JQ}|" \
    "$WRAPPER_SRC" >"${TMP}/bin/pi"
sed -e "/^[[:space:]]*#/!s|${REAL_DIR_LIT}|${TMP}/lib/bin/|" \
    -e "/^[[:space:]]*#/!s|${DESC_LIT}|${FIXED_DESC}|" \
    -e "/^[[:space:]]*#/!s|${JQ_LIT}|${TMP}/nojq/jq|" \
    "$WRAPPER_SRC" >"${TMP}/nojq/bin/pi"
chmod 0755 "${TMP}/bin/pi" "${TMP}/nojq/bin/pi"

# Hostile PATH entries: a jq that answers "no launch line", an sh and a
# basename that would each run something other than the guard.
printf '#!/bin/sh\nexit 0\n' >"${TMP}/hostile/jq"
printf '#!/bin/sh\necho "FAKE-SH $*"\n' >"${TMP}/hostile/sh"
printf '#!/bin/sh\necho claude\n' >"${TMP}/hostile/basename"
chmod 0755 "${TMP}/hostile/jq" "${TMP}/hostile/sh" "${TMP}/hostile/basename"

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
  RC=$?
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

echo "W6 hostile PATH: fake jq, sh, basename first"
env -u RC_BOOT_DESCRIPTOR PATH="${TMP}/hostile:${PATH}" "${TMP}/bin/pi" --help a b >"${TMP}/out" 2>"${TMP}/err"
OUT=$(cat "${TMP}/out")
if [ "$OUT" = "GUARD --help a b" ]; then pass "fixed launch line still runs"; else fail "W6 stdout: '${OUT}' (guard dropped or a fake ran)"; fi
if [ "$_jq_n" = "1" ]; then pass "wrapper names jq once, at ${JQ_LIT}"; else fail "W6 wrapper names ${JQ_LIT} ${_jq_n} times (expected 1)"; fi

echo "W7 malformed descriptor at the fixed path"
cp "$FIXED_DESC" "${TMP}/good.json"
printf '{"tools": [' >"$FIXED_DESC"
run_wrapper ""
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then pass "launch refused (exit ${RC}), nothing ran"; else fail "W7 exit ${RC}, stdout: '${OUT}' (fail-open)"; fi
if [ -n "$ERR" ] && [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = "1" ]; then pass "one stderr reason line"; else fail "W7 stderr: '${ERR}'"; fi
cp "${TMP}/good.json" "$FIXED_DESC"

echo "W8 the wrapper's jq is missing"
env -u RC_BOOT_DESCRIPTOR "${TMP}/nojq/bin/pi" --help a b >"${TMP}/out" 2>"${TMP}/err"
RC=$?
OUT=$(cat "${TMP}/out")
ERR=$(cat "${TMP}/err")
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then pass "launch refused (exit ${RC}), nothing ran"; else fail "W8 exit ${RC}, stdout: '${OUT}' (fail-open)"; fi
if [ -n "$ERR" ]; then pass "stderr names the reason"; else fail "W8 stderr empty"; fi

echo "W9 the stderr note prints the caller's value verbatim"
_esc_sh=""
for _s in dash zsh; do
  if command -v "$_s" >/dev/null 2>&1; then _esc_sh=$_s; break; fi
done
if [ -n "$_esc_sh" ]; then
  _val='/x\tz'   # the backslash is the payload
  env RC_BOOT_DESCRIPTOR="$_val" "$_esc_sh" "${TMP}/bin/pi" --help >"${TMP}/out" 2>"${TMP}/err"
  ERR=$(cat "${TMP}/err")
  if printf '%s' "$ERR" | grep -qF "RC_BOOT_DESCRIPTOR=${_val} "; then pass "value verbatim under ${_esc_sh}"; else fail "W9 (${_esc_sh}) stderr: '${ERR}'"; fi
else
  echo "  NOTE: W9 not run -- neither dash nor zsh on this host"
fi

echo "W5 no descriptor at the fixed path"
rm -f "$FIXED_DESC"
run_wrapper ""
if [ "$OUT" = "REAL --help a b" ]; then pass "<tool>-real runs directly"; else fail "W5 stdout: '${OUT}'"; fi

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: ${FAILURES} check(s) failed"
  exit 1
fi
echo "PASS: tool-launch-wrapper ignores a caller-set RC_BOOT_DESCRIPTOR"
