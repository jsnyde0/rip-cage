#!/usr/bin/env bash
set -uo pipefail

# tests/test-protected-paths-trailing-slash.sh -- host-tier proof for rip-cage-rsh9.3.
#
# _protected_paths_enforce strips the mount source off each finding to build
# the guest-side cover target. A mount source written with a trailing slash
# (proj/:/w) made that strip pattern proj//, which never matched, and every
# finding was skipped: rc=0, nothing covered -- fail OPEN (ADR-031 D2b/c).
#
#   S1  proj, proj/ and proj// mounts emit identical cover output
#   S2  that output actually covers the planted .ssh dir and .env file
#   S3  a forced strip failure (a finding outside the mount) is a refusal,
#       never a silent skip
#
# Sources cli/lib/protected_paths.sh directly; no docker, no msb.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T=$(mktemp -d /private/tmp/rc-pp-slash-XXXXXX)
trap 'rm -rf "$T"' EXIT

export RC_PROTECTED_PATHS="${REPO_ROOT}/share/rip-cage/protected-paths"
export RC_PROTECTED_SCAN_DEPTH=2
export HOME="${T}/home"   # the cover breadcrumb lands under $HOME/.cache/rc
mkdir -p "$HOME"
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"

mkdir -p "$T/proj/.ssh"
printf 'x\n' > "$T/proj/.ssh/id_ed25519"
printf 'MARKER\n' > "$T/proj/.env"
printf 'ok\n' > "$T/proj/visible.txt"

conf() { printf 'image: rip-cage:latest\nmounts:\n%s\n' "$2" > "$1"; }
run() { _out=$(_protected_paths_enforce "$1" 2>"$T/err"); _rc=$?; _err=$(cat "$T/err"); }

# --- S1 / S2 -----------------------------------------------------------------
conf "$T/c0.yaml" "  - \"$T/proj:/w\""
run "$T/c0.yaml"; _base="$_out"; _base_rc=$_rc
if [[ $_base_rc -eq 0 ]] && printf '%s\n' "$_base" | grep -qxF -- "/w/.ssh" \
   && printf '%s\n' "$_base" | grep -qF -- ":/w/.env:ro"; then
  pass "S2 plain mount covers /w/.ssh and /w/.env"
else
  fail "S2 plain mount did not cover both (rc $_base_rc, out: $_base, err: $_err)"
fi

for _variant in "proj/" "proj//"; do
  conf "$T/cv.yaml" "  - \"$T/${_variant}:/w\""
  run "$T/cv.yaml"
  if [[ $_rc -eq 0 && "$_out" == "$_base" ]]; then
    pass "S1 mount source '${_variant}' emits the same covers as 'proj'"
  else
    fail "S1 mount source '${_variant}' differs (rc $_rc, out: [$_out], want: [$_base], err: $_err)"
  fi
done

# --- S3 ----------------------------------------------------------------------
# Shadow find so it reports a finding outside the mount: the strip fails, and
# that must refuse rather than skip.
find() { printf '%s\n' "$T/elsewhere/.env"; }
conf "$T/c3.yaml" "  - \"$T/proj:/w\""
run "$T/c3.yaml"
unset -f find
if [[ $_rc -ne 0 && -z "$_out" ]]; then
  pass "S3 a strip failure refuses (exit $_rc) and emits no covers"
else
  fail "S3 a strip failure did not refuse (rc $_rc, out: $_out)"
fi

echo
if [[ $FAILURES -gt 0 ]]; then
  echo "FAILED: $FAILURES check(s)"
  exit 1
fi
echo "All checks passed."
