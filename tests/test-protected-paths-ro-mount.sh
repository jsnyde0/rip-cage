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
#   S1  depth-4 file in a rw mount, RC_PROTECTED_SCAN_DEPTH unset -> covered
#   S2  the same with RC_PROTECTED_SCAN_DEPTH=2                -> not reached
#   V1  RC_PROTECTED_SCAN_DEPTH not a positive integer -> refused, nothing emitted
#   F1  a file:NAME entry covers a FILE so named, never a DIRECTORY (whose
#       contents are still scanned)
#   P1  a prune:NAME entry stops the scan descending into a dir so named; a
#       mount whose root has that name is still scanned
#   L1  the shipped list: credentials is file-only and dependency trees are
#       pruned (an SDK's lib/credentials/ dir stays visible; ~/.aws/credentials
#       shapes are covered)
#   R4  any readonly value but absent/false is ro     -> guest cover (fail closed)
#   R5  a guest target carrying a newline             -> refused (one token per line)
#   O1  rw tree with a ro mount on top: under the overlay only the in-guest
#       cover, never a --mount-file inside the ro share (round 3 B1)
#   O2  ro tree with a rw mount on top: under it only the --mount-file cover
#   M1  malformed list lines refuse: bare/space-after-colon/unknown prefix,
#       a prune: glob, and a list of only prune: lines
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

# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
T=$(_host_scratch_mktemp_d rc-pp-ro) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

S=rc-dummy-secret
printf '%s\n' "$S" rc-dummy-dir rc-dummy-keydir > "$T/protected-paths"
export RC_PROTECTED_PATHS="$T/protected-paths"
# Pinned to 2 for every case but S1, which unsets it to prove the default.
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

# --- S1/S2: scan depth (rip-cage-npbb) -------------------------------------
# A workbench cage mounting ~/code holds its secrets at ~/code/<group>/<repo>/,
# depth 3+. Unset RC_PROTECTED_SCAN_DEPTH means no depth cap; a set value caps.
mkdir -p "$T/benchtree/a/b/c"
printf 'MARKER\n' > "$T/benchtree/a/b/c/$S"
conf "$T/s1.yaml" "  - \"$T/benchtree:/w\""
_saved_depth="$RC_PROTECTED_SCAN_DEPTH"
unset RC_PROTECTED_SCAN_DEPTH
run "$T/s1.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/w/a/b/c/$S:ro$"; then pass "S1 depth unset: a protected file at depth 4 is covered"; else fail "S1 depth unset: depth-4 file not covered (rc $_rc, out: $_out, err: $_err)"; fi
export RC_PROTECTED_SCAN_DEPTH=2
run "$T/s1.yaml"
if [[ $_rc -eq 0 ]] && ! printf '%s\n' "$_out" | grep -q -- "/w/a/b/c/$S"; then pass "S2 RC_PROTECTED_SCAN_DEPTH=2 still caps: the depth-4 file is not reached"; else fail "S2 depth 2 did not cap (rc $_rc, out: $_out, err: $_err)"; fi
export RC_PROTECTED_SCAN_DEPTH="$_saved_depth"

# --- V1: the depth override must be a positive integer (R5 of the review) ---
for _d in 0 -1 abc unlimited 2.5; do
  export RC_PROTECTED_SCAN_DEPTH="$_d"
  run "$T/s1.yaml"
  if [[ $_rc -ne 0 && -z "$_out" ]] && grep -q 'positive integer' <<<"$_err"; then pass "V1 RC_PROTECTED_SCAN_DEPTH=${_d} refuses, naming the valid values"; else fail "V1 RC_PROTECTED_SCAN_DEPTH=${_d} (rc $_rc, out: $_out, err: $_err)"; fi
done
export RC_PROTECTED_SCAN_DEPTH=3
run "$T/s1.yaml"
if [[ $_rc -eq 0 ]]; then pass "V1 RC_PROTECTED_SCAN_DEPTH=3 is accepted"; else fail "V1 depth 3 refused (err: $_err)"; fi
export RC_PROTECTED_SCAN_DEPTH="$_saved_depth"

# --- F1/P1: file-only and prune entries (B2 of the review) ------------------
unset RC_PROTECTED_SCAN_DEPTH   # whole tree, the default; restored after L1
printf '%s\n' "$S" "file:rc-dummy-cred" "prune:rc-dummy-deps" > "$T/protected-paths-fp"
mkdir -p "$T/fptree/src/rc-dummy-cred" "$T/fptree/cfg" "$T/fptree/rc-dummy-deps/pkg" "$T/rc-dummy-deps"
printf 'code\n' > "$T/fptree/src/rc-dummy-cred/client.py"
printf 'MARKER\n' > "$T/fptree/src/rc-dummy-cred/$S"
printf 'MARKER\n' > "$T/fptree/cfg/rc-dummy-cred"
printf 'MARKER\n' > "$T/fptree/rc-dummy-deps/pkg/$S"
printf 'MARKER\n' > "$T/rc-dummy-deps/$S"
conf "$T/fp.yaml" "  - \"$T/fptree:/w\""
RC_PROTECTED_PATHS="$T/protected-paths-fp" run "$T/fp.yaml"
if [[ $_rc -eq 0 ]] && ! printf '%s\n' "$_out" | grep -qx -- "/w/src/rc-dummy-cred"; then pass "F1 a directory named by a file: entry gets no tmpfs cover"; else fail "F1 file: entry covered a directory (rc $_rc, out: $_out, err: $_err)"; fi
if printf '%s\n' "$_out" | grep -q -- ":/w/cfg/rc-dummy-cred:ro$"; then pass "F1 a file named by a file: entry is covered"; else fail "F1 file: entry missed the file (out: $_out)"; fi
if printf '%s\n' "$_out" | grep -q -- ":/w/src/rc-dummy-cred/$S:ro$"; then pass "F1 the scan still descends into that directory"; else fail "F1 the file-only dir's contents were not scanned (out: $_out)"; fi
if ! printf '%s\n' "$_out" | grep -q -- "/w/rc-dummy-deps"; then pass "P1 nothing under a prune: dir is covered"; else fail "P1 the prune: dir was scanned (out: $_out)"; fi
conf "$T/fp2.yaml" "  - \"$T/rc-dummy-deps:/d\""
RC_PROTECTED_PATHS="$T/protected-paths-fp" run "$T/fp2.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/d/$S:ro$"; then pass "P1 a mount whose root has a prune: name is still scanned"; else fail "P1 mount root pruned (rc $_rc, out: $_out, err: $_err)"; fi
_pm=$(RC_PROTECTED_PATHS="$T/protected-paths-fp" _protected_paths_path_match "$T/fptree/rc-dummy-deps/pkg") && _pmr=0 || _pmr=1
if [[ $_pmr -eq 1 ]]; then pass "P1 a prune: entry protects nothing (no path match)"; else fail "P1 prune: entry matched a path ($_pm)"; fi
_pm=$(RC_PROTECTED_PATHS="$T/protected-paths-fp" _protected_paths_path_match "$T/fptree/src/rc-dummy-cred") && _pmr=0 || _pmr=1
if [[ $_pmr -eq 1 ]]; then pass "F1 a file: entry does not match a directory path"; else fail "F1 file: entry matched a directory ($_pm)"; fi
_pm=$(RC_PROTECTED_PATHS="$T/protected-paths-fp" _protected_paths_path_match "$T/fptree/cfg/rc-dummy-cred") && _pmr=0 || _pmr=1
if [[ $_pmr -eq 0 ]]; then pass "F1 a file: entry matches a file path"; else fail "F1 file: entry missed a file path"; fi

# --- L1: the shipped list carries the ruling --------------------------------
L="$T/ltree"
mkdir -p "$L/.venv/lib/python3.12/site-packages/anthropic/lib/credentials" "$L/node_modules/pkg" \
         "$L/svc/src/credentials" "$L/aws" "$L/lib/venv/x" "$L/py/site-packages/y"
printf 'code\n' > "$L/.venv/lib/python3.12/site-packages/anthropic/lib/credentials/__init__.py"
printf 'x\n' > "$L/node_modules/pkg/.env"
printf 'x\n' > "$L/lib/venv/x/.env"
printf 'x\n' > "$L/py/site-packages/y/.env"
printf 'code\n' > "$L/svc/src/credentials/mod.ts"
printf 'x\n' > "$L/aws/credentials"
conf "$T/l1.yaml" "  - \"$L:/w\""
RC_PROTECTED_PATHS="${REPO_ROOT}/share/rip-cage/protected-paths" run "$T/l1.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/w/aws/credentials:ro$"; then pass "L1 shipped list covers a credentials FILE"; else fail "L1 credentials file not covered (rc $_rc, out: $_out, err: $_err)"; fi
if ! printf '%s\n' "$_out" | grep -qx -- "/w/svc/src/credentials" && ! printf '%s\n' "$_out" | grep -q -- "lib/credentials$"; then pass "L1 shipped list leaves credentials DIRECTORIES visible"; else fail "L1 a credentials directory was covered (out: $_out)"; fi
if ! printf '%s\n' "$_out" | grep -qE -- "/(node_modules|\.venv|venv|site-packages)/"; then pass "L1 shipped list prunes node_modules, .venv, venv, site-packages"; else fail "L1 a dependency tree was scanned (out: $_out)"; fi
export RC_PROTECTED_SCAN_DEPTH="$_saved_depth"

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

# --- O1/O2: overlapping mounts -- the deepest mount owns its subtree --------
# The workbench shape (rip-cage-npbb round 3, B1): ~/code rw at /code, with a
# repo inside it mounted :ro on top. The guest sees the ro mount there, so a
# --mount-file cover from the rw mount's scan would land inside the ro share
# and kill agentd at boot. Only the ro mount's own (in-guest) cover may be
# emitted. And the reverse (O2): a rw mount on top of a ro one gets the
# --mount-file cover, not an in-guest one from the ro mount below.
mkdir -p "$T/otree/grp/repo/sub" "$T/otree/grp/repo/rc-dummy-dir"
printf 'MARKER\n' > "$T/otree/grp/repo/$S"
printf 'MARKER\n' > "$T/otree/grp/repo/sub/$S"
printf 'MARKER\n' > "$T/otree/$S"
unset RC_PROTECTED_SCAN_DEPTH
conf "$T/o1.yaml" "  - \"$T/otree:/code\"
  - \"$T/otree/grp/repo:/code/grp/repo:ro\""
run "$T/o1.yaml"
if [[ $_rc -eq 0 ]] && guest_cover "/code/grp/repo/$S" && guest_cover "/code/grp/repo/sub/$S"; then pass "O1 a file under the ro overlay gets the in-guest cover"; else fail "O1 no in-guest cover under the ro overlay (rc $_rc, out: $_out, err: $_err)"; fi
if ! printf '%s\n' "$_out" | grep -q -- ":/code/grp/repo/.*:ro$"; then pass "O1 no --mount-file cover lands inside the ro overlay"; else fail "O1 a --mount-file cover targets the ro overlay (out: $_out)"; fi
if [[ $(printf '%s\n' "$_out" | grep -cx -- "/code/grp/repo/rc-dummy-dir") -eq 1 ]]; then pass "O1 a protected dir under the ro overlay is covered exactly once"; else fail "O1 dir cover count under the ro overlay (out: $_out)"; fi
if printf '%s\n' "$_out" | grep -q -- ":/code/$S:ro$"; then pass "O1 the rw mount still covers its own file outside the overlay"; else fail "O1 the rw mount's own file lost its cover (out: $_out)"; fi
conf "$T/o2.yaml" "  - \"$T/otree:/code:ro\"
  - \"$T/otree/grp/repo:/code/grp/repo\""
run "$T/o2.yaml"
if [[ $_rc -eq 0 ]] && printf '%s\n' "$_out" | grep -q -- ":/code/grp/repo/$S:ro$" && ! guest_cover "/code/grp/repo/$S"; then pass "O2 a rw mount on top of a ro one gets the --mount-file cover only"; else fail "O2 rw-over-ro (rc $_rc, out: $_out, err: $_err)"; fi
if guest_cover "/code/$S"; then pass "O2 the ro mount still covers its own file in-guest"; else fail "O2 the ro mount's own file lost its cover (out: $_out)"; fi
export RC_PROTECTED_SCAN_DEPTH="$_saved_depth"

# --- M1: malformed list lines refuse (round 3, R7/R8/R9) --------------------
# A prefixed line that names nothing, an unknown prefix, a space after the
# colon, or a prune: glob would otherwise protect nothing (or prune everything)
# in silence.
for _bad in 'file:' 'prune:' 'file: rc-dummy-x' 'prune: rc-dummy-x' 'frob:rc-dummy-x' 'prune:*' 'prune:rc-*' 'prune:rc-dumm?' 'prune:[r]c'; do
  printf '%s\n' "$S" "$_bad" > "$T/protected-paths-bad"
  RC_PROTECTED_PATHS="$T/protected-paths-bad" run "$T/w1.yaml"
  if [[ $_rc -ne 0 && -z "$_out" ]] && grep -qF -- "$_bad" <<<"$_err"; then pass "M1 list line '${_bad}' refuses, naming the line"; else fail "M1 list line '${_bad}' (rc $_rc, out: $_out, err: $_err)"; fi
done
printf '%s\n' "prune:rc-dummy-deps" "prune:rc-dummy-more" > "$T/protected-paths-pruneonly"
RC_PROTECTED_PATHS="$T/protected-paths-pruneonly" run "$T/w1.yaml"
if [[ $_rc -ne 0 && -z "$_out" ]] && grep -q 'only prune: lines' <<<"$_err"; then pass "M1 a list of only prune: lines refuses"; else fail "M1 prune-only list (rc $_rc, out: $_out, err: $_err)"; fi
printf '%s\n' "$S" "file:rc-dummy-cred" "prune:rc-dummy-deps" > "$T/protected-paths-good"
RC_PROTECTED_PATHS="$T/protected-paths-good" run "$T/w1.yaml"
if [[ $_rc -eq 0 ]]; then pass "M1 well-formed file:/prune: lines are accepted"; else fail "M1 well-formed list refused (err: $_err)"; fi

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
_INIT_RE='^-- /usr/local/bin/init-rip-cage\.sh'  # the non-root init exec, not the cover text that names it
if grep -q -- "$_INIT_RE" "$T/i1.log" && [[ $(grep -n -- "$_INIT_RE" "$T/i1.log" | head -1 | cut -d: -f1) -gt 1 ]]; then pass "I1 init runs after the cover"; else fail "I1 init order: $(cat "$T/i1.log")"; fi
if grep -qxF "TARGET /mnt/p/$S" "$T/i1.log" && grep -qxF "TARGET /mnt/p/pkg/$S" "$T/i1.log"; then pass "I1 both targets reach the cover as argv"; else fail "I1 targets: $(cat "$T/i1.log")"; fi
if grep -qx "INIT_OK true" "$T/i1.log"; then pass "I1 init reports success"; else fail "I1 $(tail -1 "$T/i1.log")"; fi
_init_case "$T/i2.log" fail
if grep -qx "INIT_OK false" "$T/i2.log"; then pass "I2 a failed cover marks init failed (the caller stops the cage)"; else fail "I2 $(cat "$T/i2.log")"; fi
if grep -q -- "$_INIT_RE" "$T/i2.log"; then fail "I2 init ran beside an uncovered file"; else pass "I2 init never runs after a failed cover"; fi

echo "=== test-protected-paths-ro-mount.sh: ${FAILURES} failure(s) ==="
[[ $FAILURES -eq 0 ]]
