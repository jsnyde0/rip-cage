#!/usr/bin/env bash
set -uo pipefail

# tests/test-protected-paths-colon-mount.sh -- host-tier proof for rip-cage-3nzx.
#
# rc's mount reader split a string-form mount on its FIRST ':', so
# "/x/a:b:/ref/a:b:ro" was read as host /x/a -- a dir that need not exist --
# and the protected-paths scan never saw /x/a:b/.env. rc --dry-run up said
# would_create: fail OPEN. msb 0.7.8 itself refuses every ':' shape at
# validation, with no escape syntax (measured, verbatim on the bead), so rc now
# refuses the same strings by name before any msb call rather than guessing.
#
#   C1  the reported string, its .env inside a ':' host dir -> refused, named
#   C2  ':' in the host only, guest plain                   -> refused
#   C3  ':' in the guest only                               -> refused
#   C4  map form, ':' in bind                               -> refused
#   C5  map form, ':' in target                             -> refused
#   C6  relative guest ("/x/a:b:ro")                        -> refused
#   C7  every reader caller fails closed on it (conf-outside, secrets-dir,
#       git covers), not only _protected_paths_enforce
#   O1  ":ro,uid=1000,gid=1000" classifies as ro (a real msb ro mount)
#   O2  ":uid=1000,gid=1000" classifies as rw, guest unpolluted
#   K1  plain "host:/guest" and "host:/guest:ro" read unchanged
#
# Sources cli/lib/protected_paths.sh directly; no docker, no msb.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T=$(mktemp -d /tmp/rc-pp-colon-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot resolve the temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

export RC_PROTECTED_PATHS="${REPO_ROOT}/share/rip-cage/protected-paths"
export RC_PROTECTED_SCAN_DEPTH=2
export HOME="${T}/home"   # the cover breadcrumb lands under $HOME/.cache/rc
export XDG_CONFIG_HOME="${T}/xdg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"

mkdir -p "$T/x/a:b" "$T/x/a" "$T/plain"
printf 'MARKER\n' > "$T/x/a:b/.env"
printf 'ok\n' > "$T/plain/visible.txt"

conf() { printf 'image: rip-cage:latest\nnetwork:\n  policy: none\n  allow:\n    - "api.anthropic.com:tcp:443"\nmounts:\n%s\n' "$2" > "$1"; }
run() { _out=$(_protected_paths_enforce "$1" 2>"$T/err"); _rc=$?; _err=$(cat "$T/err"); }

refused() {  # NAME CONF_FILE
  run "$2"
  if [[ $_rc -ne 0 ]] && printf '%s' "$_err" | grep -qF "':'" && [[ -z "$_out" ]]; then
    pass "$1 refused with the ':' error (exit $_rc)"
  else
    fail "$1 not refused by name (rc $_rc, out: $_out, err: $_err)"
  fi
}

# --- C1 --------------------------------------------------------------------
conf "$T/c1.yaml" "  - \"$T/x/a:b:/ref/a:b:ro\""
refused "C1 reported string" "$T/c1.yaml"
if printf '%s' "$_err" | grep -qF "$T/x/a:b:/ref/a:b:ro"; then pass "C1 message names the mount line verbatim"; else fail "C1 message does not name the mount (err: $_err)"; fi
if printf '%s' "$_err" | grep -qF "MARKER"; then fail "C1 message echoed file contents"; else pass "C1 message never echoes contents"; fi

# --- C2..C6 ----------------------------------------------------------------
conf "$T/c2.yaml" "  - \"$T/x/a:b:/ref:ro\"";      refused "C2 ':' in host" "$T/c2.yaml"
conf "$T/c2b.yaml" "  - \"$T/x/a:b:/ref\"";        refused "C2b ':' in host, no options" "$T/c2b.yaml"
conf "$T/c3.yaml" "  - \"$T/plain:/ref/a:b\"";     refused "C3 ':' in guest" "$T/c3.yaml"
conf "$T/c3b.yaml" "  - \"$T/plain:/ref:b:ro\"";   refused "C3b ':' in guest, with options" "$T/c3b.yaml"
conf "$T/c4.yaml" "  - bind: \"$T/x/a:b\"
    target: /ref
    readonly: true";                               refused "C4 map form ':' in bind" "$T/c4.yaml"
conf "$T/c5.yaml" "  - bind: \"$T/plain\"
    target: \"/ref/a:b\"";                         refused "C5 map form ':' in target" "$T/c5.yaml"
conf "$T/c6.yaml" "  - \"$T/x/a:b:ro\"";           refused "C6 relative guest" "$T/c6.yaml"

# --- C7: every reader caller fails closed ----------------------------------
for _fn in _protected_paths_conf_outside_mounts _protected_paths_conf_secrets_dir_mount _git_exec_covers _protected_paths_conf_bind_mounts; do
  _o=$("$_fn" "$T/c2.yaml" 2>/dev/null); _r=$?
  if [[ $_r -ne 0 ]]; then pass "C7 ${_fn} fails closed on a ':' mount"; else fail "C7 ${_fn} returned 0 (out: $_o)"; fi
done

# --- O1 / O2: the option field ---------------------------------------------
conf "$T/o1.yaml" "  - \"$T/plain:/ref:ro,uid=1000,gid=1000\""
_rows=$(_protected_paths_conf_bind_mounts "$T/o1.yaml")
if [[ "$_rows" == "$T/plain"$'\t'"/ref"$'\t'"ro" ]]; then pass "O1 ro,uid=,gid= reads as ro at /ref"; else fail "O1 misread: $_rows"; fi
conf "$T/o2.yaml" "  - \"$T/plain:/ref:uid=1000,gid=1000\""
_rows=$(_protected_paths_conf_bind_mounts "$T/o2.yaml")
if [[ "$_rows" == "$T/plain"$'\t'"/ref"$'\t'"rw" ]]; then pass "O2 uid=,gid= reads as rw at /ref"; else fail "O2 misread: $_rows"; fi

# --- K1: plain shapes unchanged --------------------------------------------
conf "$T/k1.yaml" "  - \"$T/plain:/w\"
  - \"$T/plain:/r:ro\"
  - \"$T/plain:/v:rw\""
_rows=$(_protected_paths_conf_bind_mounts "$T/k1.yaml")
_want="$T/plain"$'\t'"/w"$'\t'"rw"$'\n'"$T/plain"$'\t'"/r"$'\t'"ro"$'\n'"$T/plain"$'\t'"/v"$'\t'"rw"
if [[ "$_rows" == "$_want" ]]; then pass "K1 plain host:/guest[:ro|rw] rows unchanged"; else fail "K1 rows changed: $_rows"; fi

# --- E1: the reported repro, end to end ------------------------------------
# rc --output json up --dry-run on the reported config: refused with its own
# code before any msb create, never action would_create. Fake docker + msb
# (tests/_fake-runtime-lib.sh) and a sandboxed HOME keep it off this host.
# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"
_FAKE_RT=$(fake_runtime_bin "$T/calls.log")
trap 'rm -rf "$T" "$_FAKE_RT"' EXIT
mkdir -p "$T/ws"
printf 'image: rip-cage:latest\nnetwork:\n  policy: none\n  allow:\n    - "api.anthropic.com:tcp:443"\nmounts:\n  - "%s:/workspace"\n  - "%s:/ref/a:b:ro"\n' "$T/ws" "$T/x/a:b" > "$T/e1.yaml"
_e1=$(PATH="${_FAKE_RT}:${PATH}" RC_CAGE_CONF="$T/e1.yaml" "${REPO_ROOT}/rc" --output json up --dry-run "$T/ws" 2>"$T/e1.err"); _e1_rc=$?
if [[ $_e1_rc -ne 0 ]] && grep -q '"MOUNT_PATH_AMBIGUOUS"' <<<"$_e1"; then
  pass "E1 rc up --dry-run refuses the reported config with MOUNT_PATH_AMBIGUOUS (exit $_e1_rc)"
else
  fail "E1 rc up --dry-run did not refuse by code (rc $_e1_rc, out: $_e1, err: $(cat "$T/e1.err"))"
fi
if grep -q 'would_create' <<<"$_e1"; then fail "E1 still reports would_create"; else pass "E1 no would_create"; fi
if grep -q '^msb create' "$T/calls.log" 2>/dev/null; then fail "E1 reached msb create"; else pass "E1 no msb create call"; fi

echo ""
if [[ $FAILURES -eq 0 ]]; then echo "All checks passed."; exit 0; fi
echo "${FAILURES} check(s) failed."; exit 1
