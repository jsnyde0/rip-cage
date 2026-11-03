#!/usr/bin/env bash
set -uo pipefail

# tests/test-guest-file-covers.sh -- host-tier proof for rip-cage-849o's guest
# half: share/rip-cage/guest-file-covers.sh, the script rc runs as root inside the
# cage (before init) to cover protected FILES inside read-only mounts.
#
# The real script calls `mount --bind -o ro`; here a stub `mount` on PATH
# stands in, so the script's own logic runs unchanged on the host:
#
#   G1  success: every target is covered, reads empty, and lands in the record;
#       the record and the empty source are not group/other writable
#   G2  zero targets: the record is written empty (a stale one never survives)
#   G3  mount fails: the script exits non-zero, names the file, never echoes
#       its content, and leaves no record listing it as covered
#   G4  mount "succeeds" but the file still reads non-empty: fail closed
#   G5  an absent target: fail closed, named
#
# Uses dummy file names only. No docker, no msb.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
COVER="${REPO_ROOT}/share/rip-cage/guest-file-covers.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

T=$(mktemp -d /tmp/rc-gfc-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

# Stub mount: MODE=ok copies the source over the target (the effect a bind of
# an empty file has on what reads see); MODE=fail exits 32 like a real failed
# mount; MODE=noop returns 0 and does nothing.
mkdir -p "$T/bin"
cat > "$T/bin/mount" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG}"
src="${@: -2:1}"; dst="${@: -1}"
case "${STUB_MODE}" in
  ok)   cat "$src" > "$dst" ;;
  fail) echo "mount: ${dst}: permission denied." >&2; exit 32 ;;
  noop) exit 0 ;;
esac
STUB
chmod +x "$T/bin/mount"

fixture() {
  rm -rf "${T:?}/mnt" "${T:?}/run" "${T:?}/log"
  mkdir -p "$T/mnt/p/pkg"
  printf 'MARKER\n' > "$T/mnt/p/rc-dummy-secret"
  printf 'MARKER\n' > "$T/mnt/p/pkg/rc-dummy-secret"
  printf 'visible\n' > "$T/mnt/p/visible.txt"
}
run() {  # MODE ARGS...
  local _mode="$1"; shift
  _out=$(PATH="$T/bin:$PATH" STUB_MODE="$_mode" STUB_LOG="$T/log" RC_GUEST_COVER_RUN_DIR="$T/run" \
    bash "$COVER" "$@" 2>&1); _rc=$?
}
REC="$T/run/file-covers"

# --- G1 --------------------------------------------------------------------
fixture
run ok "$T/mnt/p/rc-dummy-secret" "$T/mnt/p/pkg/rc-dummy-secret"
if [[ $_rc -eq 0 ]]; then pass "G1 exits 0 when every cover applies"; else fail "G1 exit $_rc: $_out"; fi
if [[ ! -s "$T/mnt/p/rc-dummy-secret" && ! -s "$T/mnt/p/pkg/rc-dummy-secret" ]]; then pass "G1 both targets read empty"; else fail "G1 a target still has content"; fi
if [[ "$(cat "$T/mnt/p/visible.txt")" == visible ]]; then pass "G1 the sibling is untouched"; else fail "G1 the sibling changed"; fi
if grep -q -- "--bind -o ro" "$T/log"; then pass "G1 uses mount --bind -o ro"; else fail "G1 mount args: $(cat "$T/log")"; fi
if [[ "$(cat "$REC" 2>/dev/null)" == "$T/mnt/p/rc-dummy-secret"$'\n'"$T/mnt/p/pkg/rc-dummy-secret" ]]; then pass "G1 the record lists both covered files"; else fail "G1 record: $(cat "$REC" 2>&1)"; fi
_perm=$(stat -c '%a' "$REC" 2>/dev/null)
if [[ -n "$_perm" && $(( 8#$_perm & 8#022 )) -eq 0 ]]; then pass "G1 the record is not group/other writable (0$_perm)"; else fail "G1 record mode 0$_perm"; fi
if printf '%s' "$_out" | grep -qF MARKER; then fail "G1 output echoed content"; else pass "G1 output never echoes content"; fi

# --- G2 --------------------------------------------------------------------
fixture
mkdir -p "$T/run"; printf 'stale\n' > "$REC"
run ok
if [[ $_rc -eq 0 && -f "$REC" && ! -s "$REC" ]]; then pass "G2 zero targets: exit 0 and the record is rewritten empty"; else fail "G2 rc $_rc, record: $(cat "$REC" 2>&1)"; fi

# --- G3 --------------------------------------------------------------------
fixture
run fail "$T/mnt/p/rc-dummy-secret"
if [[ $_rc -ne 0 ]]; then pass "G3 a failed mount exits non-zero ($_rc)"; else fail "G3 exited 0: $_out"; fi
if printf '%s' "$_out" | grep -qF "$T/mnt/p/rc-dummy-secret"; then pass "G3 the error names the file"; else fail "G3 error does not name the file: $_out"; fi
if printf '%s' "$_out" | grep -qF MARKER; then fail "G3 output echoed content"; else pass "G3 output never echoes content"; fi
if grep -qF "$T/mnt/p/rc-dummy-secret" "$REC" 2>/dev/null; then fail "G3 the record lists an uncovered file"; else pass "G3 no record lists the uncovered file"; fi

# --- G4 --------------------------------------------------------------------
fixture
run noop "$T/mnt/p/rc-dummy-secret"
if [[ $_rc -ne 0 ]] && printf '%s' "$_out" | grep -qF "$T/mnt/p/rc-dummy-secret"; then pass "G4 a cover that leaves content readable fails closed, named"; else fail "G4 rc $_rc: $_out"; fi

# --- G5 --------------------------------------------------------------------
fixture
run ok "$T/mnt/p/not-there"
if [[ $_rc -ne 0 ]] && printf '%s' "$_out" | grep -qF "$T/mnt/p/not-there"; then pass "G5 an absent target fails closed, named"; else fail "G5 rc $_rc: $_out"; fi

# --- G6 --------------------------------------------------------------------
# The floor probe reads this record; a listed file gone by probe time fails it
# (rip-cage-mq11). unshare -r makes the test-owned record read root:root.
_probe() { RC_FLOOR_COVERS_RECORD="$REC" unshare -r bash "${REPO_ROOT}/cage/floor/floor-probe.sh" 2>&1 | grep 'floor: file-covers' | head -1; }
if unshare -r true 2>/dev/null; then
  fixture
  run ok "$T/mnt/p/rc-dummy-secret" "$T/mnt/p/pkg/rc-dummy-secret"
  if [[ "$(_probe)" == PASS* ]]; then pass "G6 the probe passes an intact record"; else fail "G6 intact: $(_probe)"; fi
  rm -f "$T/mnt/p/pkg/rc-dummy-secret"
  _p=$(_probe)
  if [[ "$_p" == FAIL* && "$_p" == *"$T/mnt/p/pkg/rc-dummy-secret"* ]]; then pass "G6 a listed file gone by probe time fails the probe, named"; else fail "G6 absent: $_p"; fi
else
  echo "SKIP: G6 needs unshare -r"
fi

echo "=== test-guest-file-covers.sh: ${FAILURES} failure(s) ==="
[[ $FAILURES -eq 0 ]]
