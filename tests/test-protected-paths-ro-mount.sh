#!/usr/bin/env bash
set -uo pipefail

# tests/test-protected-paths-ro-mount.sh -- host-tier proof for rip-cage-849o
# (was rip-cage-dnwv's refusal test, updated in place).
#
# A protected FILE inside a READ-ONLY bind mount cannot be covered by msb: it
# must create the --mount-file bind target inside the ro virtiofs share, and
# agentd dies at boot ("failed to create bind target ...: Read-only file
# system"; msb 0.7.4-0.7.13, rip-cage-dnwv / rip-cage-2wsi, upstream
# superradcompany/microsandbox#2000). rc used to refuse that config. Now
# _protected_paths_enforce emits no msb flag for such a file and instead names
# it as an IN-GUEST cover target (the "--rc-guest-file-cover GUEST" token pair),
# which rc applies as root before init (share/rip-cage/guest-file-covers.sh). A
# protected DIRECTORY inside an ro mount still covers natively (--tmpfs over an
# existing dir boots), and every rw cover is unchanged.
#
#   R1  string-form ":ro" mount holding the file      -> guest cover, no refusal
#   R2  map-form "readonly: true" mount holding it    -> guest cover
#   R3  ro mount holding it two levels down           -> guest cover (scan depth)
#   R4  any readonly value but absent/false is ro     -> guest cover (fail closed)
#   R5  a guest target carrying a newline             -> refused (one token per line)
#   D1  ro mount holding only a protected DIRECTORY   -> tmpfs cover, no guest cover
#   D2  ro mount: file under a covered protected dir  -> no guest cover (the dir
#       cover already hides it; no nested cover)
#   W1  rw string-form mount holding the file         -> --mount-file cover
#   W2  map-form mount without readonly               -> --mount-file cover
#
# Uses a temp protected-paths list with dummy names, never a real credential
# name. Sources cli/lib/protected_paths.sh directly; no docker, no msb.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T=$(mktemp -d /tmp/rc-pp-ro-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

S=rc-dummy-secret
printf '%s\n' "$S" rc-dummy-dir rc-dummy-keydir > "$T/protected-paths"
export RC_PROTECTED_PATHS="$T/protected-paths"
# Pinned: R3 plants the file two levels down and relies on the default depth.
export RC_PROTECTED_SCAN_DEPTH=2
export HOME="${T}/home"   # the cover breadcrumb lands under $HOME/.cache/rc
mkdir -p "$HOME"
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"

# Fixture trees.
mkdir -p "$T/envtree" "$T/deeptree/pkg/sub" "$T/dirtree/rc-dummy-dir" "$T/nestedtree/rc-dummy-keydir"
printf 'MARKER\n' > "$T/envtree/$S"
printf 'ok\n' > "$T/envtree/visible.txt"
printf 'MARKER\n' > "$T/deeptree/pkg/$S"
printf 'x\n' > "$T/dirtree/rc-dummy-dir/config"
printf 'x\n' > "$T/nestedtree/rc-dummy-keydir/$S"

conf() { printf 'image: rip-cage:latest\nmounts:\n%s\n' "$2" > "$1"; }
run() { _out=$(_protected_paths_enforce "$1" 2>"$T/err"); _rc=$?; _err=$(cat "$T/err"); }
# guest_cover GUEST -- the output carries the token pair for GUEST.
guest_cover() { printf '%s\n' "$_out" | grep -A1 -x -- '--rc-guest-file-cover' | grep -qxF -- "$1"; }

# --- R1 --------------------------------------------------------------------
conf "$T/r1.yaml" "  - \"$T/envtree:/mnt/p:ro\""
run "$T/r1.yaml"
if [[ $_rc -eq 0 ]]; then pass "R1 ro mount holding a protected file is no longer refused"; else fail "R1 ro mount was refused (rc $_rc, err: $_err)"; fi
if guest_cover "/mnt/p/$S"; then pass "R1 the file is named as an in-guest cover target"; else fail "R1 no in-guest cover for /mnt/p/$S (out: $_out)"; fi
if printf '%s' "$_out" | grep -q -- "--mount-file"; then fail "R1 an msb file cover was emitted inside the ro mount (out: $_out)"; else pass "R1 no msb file cover inside the ro mount"; fi
if printf '%s' "$_out" | grep -q "visible.txt"; then fail "R1 the unprotected sibling got a cover (out: $_out)"; else pass "R1 the sibling gets no cover"; fi

# --- R2 --------------------------------------------------------------------
conf "$T/r2.yaml" "  - bind: $T/envtree
    target: /mnt/p
    readonly: true"
run "$T/r2.yaml"
if [[ $_rc -eq 0 ]] && guest_cover "/mnt/p/$S"; then pass "R2 map-form readonly mount gets an in-guest cover"; else fail "R2 map-form readonly (rc $_rc, out: $_out, err: $_err)"; fi

# --- R4: any readonly value but absent/false is ro (fail closed) -----------
for _ro in '"yes"' '"true"' 'yes'; do
  conf "$T/r4.yaml" "  - bind: $T/envtree
    target: /mnt/p
    readonly: ${_ro}"
  run "$T/r4.yaml"
  if [[ $_rc -eq 0 ]] && guest_cover "/mnt/p/$S"; then pass "R4 map-form readonly: ${_ro} classifies as ro and gets an in-guest cover"; else fail "R4 readonly: ${_ro} (rc $_rc, out: $_out)"; fi
done
conf "$T/r4f.yaml" "  - bind: $T/envtree
    target: /mnt/p
    readonly: false"
run "$T/r4f.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/mnt/p/$S:ro$" && ! guest_cover "/mnt/p/$S"; then pass "R4 map-form readonly: false stays rw and gets an msb file cover"; else fail "R4 readonly: false (rc $_rc, out: $_out, err: $_err)"; fi

# --- R3 --------------------------------------------------------------------
conf "$T/r3.yaml" "  - \"$T/deeptree:/mnt/p:ro\""
run "$T/r3.yaml"
if [[ $_rc -eq 0 ]] && guest_cover "/mnt/p/pkg/$S"; then pass "R3 nested file inside an ro mount gets an in-guest cover"; else fail "R3 nested file (rc $_rc, out: $_out, err: $_err)"; fi

# --- R5: a control character in a guest target is refused ------------------
mkdir -p "$T/ctltree/a"$'\n'"b"
printf 'MARKER\n' > "$T/ctltree/a"$'\n'"b/$S"
conf "$T/r5.yaml" "  - \"$T/ctltree:/mnt/p:ro\""
run "$T/r5.yaml"
if [[ $_rc -ne 0 ]] && [[ -z "$_out" ]]; then pass "R5 a guest cover target with a newline is refused, nothing emitted (exit $_rc)"; else fail "R5 control character (rc $_rc, out: $_out, err: $_err)"; fi
if printf '%s' "$_err" | grep -qF "MARKER"; then fail "R5 message echoed file contents"; else pass "R5 message never echoes contents"; fi

# --- D1 --------------------------------------------------------------------
conf "$T/d1.yaml" "  - \"$T/dirtree:/mnt/p:ro\""
run "$T/d1.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -qx -- "/mnt/p/rc-dummy-dir" && ! printf '%s' "$_out" | grep -q -- "--rc-guest-file-cover"; then pass "D1 protected dir inside an ro mount still gets a tmpfs cover, no guest cover"; else fail "D1 (rc $_rc, out: $_out, err: $_err)"; fi

# --- D2 --------------------------------------------------------------------
conf "$T/d2.yaml" "  - \"$T/nestedtree:/mnt/p:ro\""
run "$T/d2.yaml"
if [[ $_rc -eq 0 ]] && ! guest_cover "/mnt/p/rc-dummy-keydir/$S"; then pass "D2 file under a covered protected dir in an ro mount gets no nested cover"; else fail "D2 (rc $_rc, out: $_out, err: $_err)"; fi

# --- W1 --------------------------------------------------------------------
conf "$T/w1.yaml" "  - \"$T/envtree:/mnt/p\""
run "$T/w1.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/mnt/p/$S:ro$" && ! guest_cover "/mnt/p/$S"; then pass "W1 rw mount holding the file still gets a read-only msb file cover"; else fail "W1 (rc $_rc, out: $_out, err: $_err)"; fi

# --- W2 --------------------------------------------------------------------
conf "$T/w2.yaml" "  - bind: $T/envtree
    target: /mnt/p"
run "$T/w2.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/mnt/p/$S:ro$"; then pass "W2 map-form rw mount holding the file still gets an msb file cover"; else fail "W2 (rc $_rc, out: $_out, err: $_err)"; fi

# --- E1: rc up --dry-run on an ro mount holding the file -------------------
# Not refused; the preview names the in-guest cover. Fake docker + msb keep it
# off this host (tests/_fake-runtime-lib.sh).
# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"
_FAKE_RT=$(fake_runtime_bin "$T/calls.log")
trap 'rm -rf "$T" "$_FAKE_RT"' EXIT
mkdir -p "$T/ws" "$T/xdg"
printf 'image: rip-cage:latest\nnetwork:\n  policy: none\n  allow:\n    - "api.anthropic.com:tcp:443"\nmounts:\n  - "%s:/workspace"\n  - "%s:/mnt/p:ro"\n' "$T/ws" "$T/envtree" > "$T/e1.yaml"
_e1=$(PATH="${_FAKE_RT}:${PATH}" XDG_CONFIG_HOME="$T/xdg" RC_CAGE_CONF="$T/e1.yaml" "${REPO_ROOT}/rc" up --dry-run "$T/ws" 2>&1); _e1_rc=$?
if [[ $_e1_rc -eq 0 ]]; then pass "E1 rc up --dry-run accepts the ro mount holding a protected file"; else fail "E1 exit $_e1_rc: $_e1"; fi
if grep -qF "Would cover /mnt/p/$S in-guest" <<<"$_e1"; then pass "E1 the preview names the in-guest cover"; else fail "E1 no in-guest cover line: $_e1"; fi
if grep -qF "PROTECTED_PATH_REFUSED" <<<"$_e1"; then fail "E1 still refused"; else pass "E1 not refused"; fi

# --- I1/I2: the in-guest cover runs as root BEFORE init, fail closed --------
# _up_init_container with _msb_exec stubbed: each call is logged; the root
# call fails when STUB_COVER_FAIL is set.
_init_case() {  # LOG [FAIL]
  ( export STUB_LOG="$1" STUB_COVER_FAIL="${2:-}"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/rc" >/dev/null 2>&1
    # shellcheck disable=SC2329,SC2034  # called by _up_init_container, which reads OUTPUT_FORMAT
    _msb_exec() {
      local _n="$1"; shift
      printf '%s\n' "$*" | head -c 200 | tr '\n' ' ' >> "$STUB_LOG"; echo >> "$STUB_LOG"
      if [[ "$1" == "-u" && "$2" == root ]]; then
        [[ -n "$STUB_COVER_FAIL" ]] && return 1
        # The targets ride argv after the script text and the $0 placeholder.
        local _a; for _a in "${@:6}"; do echo "TARGET $_a" >> "$STUB_LOG"; done
      fi
      return 0
    }
    # shellcheck disable=SC2034 # read by _up_init_container (sourced)
    OUTPUT_FORMAT=text
    _UP_GUEST_FILE_COVERS=("/mnt/p/$S" "/mnt/p/pkg/$S")
    _up_init_container fake-cage >/dev/null 2>&1
    echo "INIT_OK $_UP_INIT_OK" >> "$STUB_LOG" )
}
_init_case "$T/i1.log"
_first=$(head -1 "$T/i1.log")
if [[ "$_first" == "-u root -- bash -c "* ]]; then pass "I1 the first exec is the root cover"; else fail "I1 first exec: $_first"; fi
if grep -q -- "init-rip-cage.sh" "$T/i1.log" && [[ $(grep -n "init-rip-cage.sh" "$T/i1.log" | head -1 | cut -d: -f1) -gt 1 ]]; then pass "I1 init runs after the cover"; else fail "I1 init order: $(cat "$T/i1.log")"; fi
if grep -qxF "TARGET /mnt/p/$S" "$T/i1.log" && grep -qxF "TARGET /mnt/p/pkg/$S" "$T/i1.log"; then pass "I1 both targets reach the cover as argv"; else fail "I1 targets: $(cat "$T/i1.log")"; fi
if grep -qx "INIT_OK true" "$T/i1.log"; then pass "I1 init reports success"; else fail "I1 $(tail -1 "$T/i1.log")"; fi
_init_case "$T/i2.log" fail
if grep -qx "INIT_OK false" "$T/i2.log"; then pass "I2 a failed cover marks init failed (the caller stops the cage)"; else fail "I2 $(cat "$T/i2.log")"; fi
if grep -q -- "init-rip-cage.sh" "$T/i2.log"; then fail "I2 init ran beside an uncovered file"; else pass "I2 init never runs after a failed cover"; fi

echo "=== test-protected-paths-ro-mount.sh: ${FAILURES} failure(s) ==="
[[ $FAILURES -eq 0 ]]
