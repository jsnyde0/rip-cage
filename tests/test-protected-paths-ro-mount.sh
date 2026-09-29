#!/usr/bin/env bash
set -uo pipefail

# tests/test-protected-paths-ro-mount.sh -- host-tier proof for rip-cage-dnwv.
#
# A protected FILE inside a READ-ONLY bind mount cannot be covered: msb 0.7.4
# must create the --mount-file bind target inside the ro virtiofs share, and
# agentd dies at boot ("failed to create bind target ...: Read-only file
# system"). A protected DIRECTORY inside an ro mount covers fine (--tmpfs over
# an existing dir boots). Measured on the bead's notes. So
# _protected_paths_enforce refuses the file case before any msb call, naming
# the file and the mount line, and leaves every other case as it was.
#
#   R1  string-form ":ro" mount holding .env         -> refused, names both
#   R2  map-form "readonly: true" mount holding .env -> refused
#   R3  ro mount holding .env two levels down        -> refused (scan depth)
#   D1  ro mount holding only a protected DIRECTORY  -> tmpfs cover, no refusal
#   D2  ro mount: file under a covered protected dir -> no refusal (the dir
#       cover already hides it; no nested cover)
#   W1  rw string-form mount holding .env            -> --mount-file cover
#   W2  map-form mount without readonly              -> --mount-file cover
#
# Sources cli/lib/protected_paths.sh directly; no docker, no msb.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T=$(mktemp -d /private/tmp/rc-pp-ro-XXXXXX)
trap 'rm -rf "$T"' EXIT

export RC_PROTECTED_PATHS="${REPO_ROOT}/share/rip-cage/protected-paths"
# Pinned: R3 plants .env two levels down and relies on the default depth.
export RC_PROTECTED_SCAN_DEPTH=2
export HOME="${T}/home"   # the cover breadcrumb lands under $HOME/.cache/rc
mkdir -p "$HOME"
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"

# Fixture trees.
mkdir -p "$T/envtree" "$T/deeptree/pkg/sub" "$T/dirtree/.aws" "$T/nestedtree/.ssh"
printf 'MARKER\n' > "$T/envtree/.env"
printf 'ok\n' > "$T/envtree/visible.txt"
printf 'MARKER\n' > "$T/deeptree/pkg/.env"
printf 'x\n' > "$T/dirtree/.aws/config"
printf 'x\n' > "$T/nestedtree/.ssh/id_ed25519"

conf() { printf 'image: rip-cage:latest\nmounts:\n%s\n' "$2" > "$1"; }
run() { _out=$(_protected_paths_enforce "$1" 2>"$T/err"); _rc=$?; _err=$(cat "$T/err"); }

# --- R1 --------------------------------------------------------------------
conf "$T/r1.yaml" "  - \"$T/envtree:/mnt/p:ro\""
run "$T/r1.yaml"
if [[ $_rc -ne 0 ]]; then pass "R1 ro mount holding .env is refused (exit $_rc)"; else fail "R1 ro mount holding .env was not refused (out: $_out)"; fi
if printf '%s' "$_err" | grep -qF "$T/envtree/.env"; then pass "R1 message names the protected file's host path"; else fail "R1 message does not name $T/envtree/.env (err: $_err)"; fi
if printf '%s' "$_err" | grep -qF "$T/envtree:/mnt/p"; then pass "R1 message names the mount line"; else fail "R1 message does not name the mount (err: $_err)"; fi
if printf '%s' "$_err" | grep -qi "narrow"; then pass "R1 message suggests a narrower mount"; else fail "R1 message suggests no narrower mount (err: $_err)"; fi
if [[ -z "$_out" ]]; then pass "R1 no cover flags emitted on refusal"; else fail "R1 emitted flags despite refusing: $_out"; fi

# --- R2 --------------------------------------------------------------------
conf "$T/r2.yaml" "  - bind: $T/envtree
    target: /mnt/p
    readonly: true"
run "$T/r2.yaml"
if [[ $_rc -ne 0 ]] && printf '%s' "$_err" | grep -qF "$T/envtree/.env"; then pass "R2 map-form readonly mount holding .env is refused, naming the file"; else fail "R2 map-form readonly not refused (rc $_rc, out: $_out, err: $_err)"; fi

# --- R4: any readonly value but absent/false is ro (fail closed) -----------
for _ro in '"yes"' '"true"' 'yes'; do
  conf "$T/r4.yaml" "  - bind: $T/envtree
    target: /mnt/p
    readonly: ${_ro}"
  run "$T/r4.yaml"
  if [[ $_rc -ne 0 ]]; then pass "R4 map-form readonly: ${_ro} classifies as ro and is refused"; else fail "R4 readonly: ${_ro} classified rw (out: $_out)"; fi
done
conf "$T/r4f.yaml" "  - bind: $T/envtree
    target: /mnt/p
    readonly: false"
run "$T/r4f.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/mnt/p/.env:ro$"; then pass "R4 map-form readonly: false stays rw and gets a file cover"; else fail "R4 readonly: false (rc $_rc, out: $_out, err: $_err)"; fi

# --- R5: rc's message names no recipe (ADR-005 D12) ------------------------
conf "$T/r5.yaml" "  - \"$T/envtree:/mnt/p:ro\""
run "$T/r5.yaml"
if printf '%s' "$_err" | grep -q 'dotpi'; then fail "R5 refusal names a specific recipe inside cli/ (err: $_err)"; else pass "R5 refusal names no specific recipe"; fi

# --- R3 --------------------------------------------------------------------
conf "$T/r3.yaml" "  - \"$T/deeptree:/mnt/p:ro\""
run "$T/r3.yaml"
if [[ $_rc -ne 0 ]] && printf '%s' "$_err" | grep -qF "$T/deeptree/pkg/.env"; then pass "R3 nested .env inside an ro mount is refused, naming it"; else fail "R3 nested .env not refused (rc $_rc, out: $_out, err: $_err)"; fi

# --- D1 --------------------------------------------------------------------
conf "$T/d1.yaml" "  - \"$T/dirtree:/mnt/p:ro\""
run "$T/d1.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -qx -- "/mnt/p/.aws"; then pass "D1 protected dir inside an ro mount still gets a tmpfs cover"; else fail "D1 (rc $_rc, out: $_out, err: $_err)"; fi

# --- D2 --------------------------------------------------------------------
conf "$T/d2.yaml" "  - \"$T/nestedtree:/mnt/p:ro\""
run "$T/d2.yaml"
if [[ $_rc -eq 0 ]] && ! printf '%s' "$_out" | grep -q "id_ed25519"; then pass "D2 file under a covered protected dir in an ro mount is not refused and gets no nested cover"; else fail "D2 (rc $_rc, out: $_out, err: $_err)"; fi

# --- W1 --------------------------------------------------------------------
conf "$T/w1.yaml" "  - \"$T/envtree:/mnt/p\""
run "$T/w1.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/mnt/p/.env:ro$"; then pass "W1 rw mount holding .env still gets a read-only file cover"; else fail "W1 (rc $_rc, out: $_out, err: $_err)"; fi

# --- W2 --------------------------------------------------------------------
conf "$T/w2.yaml" "  - bind: $T/envtree
    target: /mnt/p"
run "$T/w2.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/mnt/p/.env:ro$"; then pass "W2 map-form rw mount holding .env still gets a file cover"; else fail "W2 (rc $_rc, out: $_out, err: $_err)"; fi

echo "=== test-protected-paths-ro-mount.sh: ${FAILURES} failure(s) ==="
[[ $FAILURES -eq 0 ]]
