#!/usr/bin/env bash
# tests/test-protected-paths-ro-mount-live.sh -- container-tier proof for
# rip-cage-dnwv: a read-only mount whose source holds a protected file.
#
# A REAL `rc up` (no --dry-run) on a cage config that mounts a scratch dir
# read-only, the dir holding a .env with a marker value. Exactly one outcome is
# green, and the test says which one it saw:
#   (a) rc up refuses before boot, naming the .env host path, and no sandbox
#       exists afterwards;
#   (b) the cage boots, and an in-cage cat of the mounted .env does not print
#       the marker.
# Never green: an agentd init failure anywhere in rc up's output, or the marker
# readable in the cage. The shipped fix is (a) -- msb 0.7.4 cannot create a
# file-cover bind target inside a read-only mount (measured on the bead).
#
# P  the rest of the shipped protected-paths list, each name planted as a FILE
#    in an ro mount, through `rc up --dry-run` (same validation, no VM): each
#    is refused naming the file. Runs only when the .env leg took (a).
#
# NEEDS_CONTAINER: docker + msb + rip-cage:latest (RC_TEST_IMAGE) in msb's
# image cache. Self-skips otherwise. One cage at most, RC_TEST_MEMORY (1G).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="${RC_TEST_IMAGE:-rip-cage:latest}"
MEMORY="${RC_TEST_MEMORY:-1G}"
LIST="${REPO_ROOT}/share/rip-cage/protected-paths"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker not available/responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"

# /private/tmp, never /tmp: msb does not follow a host-side symlink in a mount
# source, and /tmp is one on macOS.
T=$(mktemp -d /private/tmp/rc-dnwv-live-XXXXXX)
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

WS="${T}/ws"
RO="${T}/ro-src"
MARKER="RC_DNWV_MARKER_$$"
mkdir -p "$WS" "$RO" "${T}/xdg"
printf '%s\n' "$MARKER" > "${RO}/.env"
printf 'visible\n' > "${RO}/visible.txt"

write_conf() {  # $1 = conf path, $2 = ro source
  cat > "$1" <<CONF
image: ${IMAGE}
workdir: /workspace
memory: ${MEMORY}
mounts:
  - "${WS}:/workspace"
  - "${2}:/mnt/ro:ro"
network:
  policy: none
  strict: false
  allow:
    - "api.anthropic.com:tcp:443"
CONF
}
CONF="${T}/cage.yaml"
write_conf "$CONF" "$RO"

NAME=$(bash -c "source '${RC}' 2>/dev/null; container_name '${WS}'")
if [[ -z "$NAME" ]]; then
  fail "setup: could not derive the cage name for ${WS}"
  echo "=== test-protected-paths-ro-mount-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi

run_rc() {
  XDG_CONFIG_HOME="${T}/xdg" RC_CAGE_CONF="$1" perl -e 'alarm 300; exec @ARGV' "$RC" up "${@:2}"
}

# --- the .env leg: a real rc up --------------------------------------------
UP_LOG="${T}/up.log"
run_rc "$CONF" "$WS" </dev/null >"$UP_LOG" 2>&1
UP_RC=$?
echo "--- rc up exit ${UP_RC}; output:"
sed "s/^/    /" "$UP_LOG"

# rc up's own output does not carry agentd's line -- msb reports only "sandbox
# process exited ... before agent relay became available" -- so the system log
# of any sandbox rc created is read too (measured: the pre-fix run).
AGENTD_RE='agentd: init failed|failed to create bind target'
# Registered for destroy only once it exists: the green outcome (a) creates
# none, and a destroy of an absent cage is a loud leak warning. rc up is
# bounded by its alarm above, so the unregistered window is that call only.
if msb inspect "$NAME" --format json >/dev/null 2>&1; then
  scratch_cage_register "$NAME"
  msb logs --source system "$NAME" </dev/null >>"$UP_LOG" 2>&1
fi
if grep -qE "$AGENTD_RE" "$UP_LOG"; then
  fail "never: an agentd init failure (rc up output + msb system log)" "$(grep -E "$AGENTD_RE" "$UP_LOG" | head -2)"
else
  pass "never: no agentd init failure in rc up's output or msb's system log"
fi

if msb inspect "$NAME" --format json >/dev/null 2>&1; then
  echo "--- outcome (b): a sandbox named ${NAME} exists"
  CAT_OUT=$(perl -e 'alarm 60; exec @ARGV' msb exec "$NAME" -- cat /mnt/ro/.env </dev/null 2>&1)
  echo "--- in-cage cat /mnt/ro/.env: '${CAT_OUT}'"
  if printf '%s' "$CAT_OUT" | grep -qF "$MARKER"; then
    fail "(b) the marker is readable inside the cage" "$CAT_OUT"
  elif msb inspect "$NAME" --format json 2>/dev/null | jq -e '.status == "Running"' >/dev/null 2>&1; then
    pass "(b) the cage booted and the mounted .env does not print the marker"
  else
    fail "(b) a sandbox exists but is not running -- the boot died" "$(msb inspect "$NAME" --format json 2>/dev/null | jq -r '.status')"
  fi
else
  echo "--- outcome (a): no sandbox named ${NAME} exists"
  if [[ "$UP_RC" -ne 0 ]] && grep -qF "${RO}/.env" "$UP_LOG"; then
    pass "(a) rc up refused before boot (exit ${UP_RC}), naming ${RO}/.env"
  else
    fail "(a) no sandbox, but rc up did not refuse naming ${RO}/.env" "exit ${UP_RC}"
  fi

  # --- P: every other listed name, planted as a file in an ro mount ---------
  while IFS= read -r _entry; do
    _entry="${_entry#"${_entry%%[![:space:]]*}"}"; _entry="${_entry%"${_entry##*[![:space:]]}"}"
    [[ -z "$_entry" || "$_entry" == \#* || "$_entry" == ".env" ]] && continue
    _src="${T}/p-src-${_entry#.}"
    mkdir -p "$_src"
    printf '%s\n' "$MARKER" > "${_src}/${_entry}"
    write_conf "${T}/p.yaml" "$_src"
    _out=$(run_rc "${T}/p.yaml" --dry-run "$WS" </dev/null 2>&1); _rc=$?
    if [[ "$_rc" -ne 0 ]] && printf '%s' "$_out" | grep -qF "${_src}/${_entry}"; then
      pass "P '${_entry}' as a file in an ro mount is refused, naming it"
    else
      fail "P '${_entry}' as a file in an ro mount was not refused naming it" "exit ${_rc}: $(printf '%s' "$_out" | tail -2)"
    fi
  done < "$LIST"
fi

echo "=== test-protected-paths-ro-mount-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
