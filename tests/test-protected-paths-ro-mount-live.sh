#!/usr/bin/env bash
# tests/test-protected-paths-ro-mount-live.sh -- container-tier proof for
# rip-cage-849o (was rip-cage-dnwv's refusal test, updated in place): a
# read-only mount whose source holds a protected FILE.
#
# msb cannot cover such a file (rip-cage-2wsi, superradcompany/microsandbox
# #2000), so rc covers it in-guest, as root, before init. A REAL `rc up` (no
# --dry-run) on a config that ro-mounts a scratch dir holding a dummy protected
# file with a marker value, plus a sibling:
#
#   C1  the cage boots; no agentd init failure anywhere
#   C2  in the guest the protected file reads empty, never the marker
#   C3  the sibling reads its content
#   C4  a write into the mount fails, even as guest root
#   C5  the guest's cover record lists the file; when the image's floor probe
#       knows the file-covers check, init printed it PASS
#   C7  guest root can umount the cover (the stated strength), and then the
#       floor probe's file-covers check FAILs (only on an image that has it)
#   C6  resume (a fresh boot) re-applies the cover: empty again
#   F1  FORCED FAILURE: the protected file is a symlink to a host-only path, so
#       the in-guest bind cannot land. rc up exits non-zero naming the file,
#       init never starts, and the cage is left stopped
#   P   the rest of the shipped list, each name planted as a FILE in an ro
#       mount, through `rc up --dry-run`: none is refused, each is named as an
#       in-guest cover (the .env family is skipped: hooks block reading them)
#
# A temp protected-paths list with a dummy name drives C1-F1; no real
# credential name or value is used. NEEDS_CONTAINER: docker + msb +
# rip-cage:latest (RC_TEST_IMAGE) in msb's image cache. Self-skips otherwise.
# One cage at a time, RC_TEST_MEMORY (1G).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="${RC_TEST_IMAGE:-rip-cage:latest}"
MEMORY="${RC_TEST_MEMORY:-1G}"
SHIPPED_LIST="${REPO_ROOT}/share/rip-cage/protected-paths"
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

# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"

# The WORKSPACE comes from the short scratch root, so the cage name rc derives
# from it is rc-t-* -- the only shape _scratch_cage_name_is_ours will sweep
# after a SIGKILL. The fixtures live apart from it under /tmp, resolved with
# pwd -P (msb does not follow a host-side symlink in a mount source).
WS=$(_host_scratch_mktemp_d 849o)
T=$(mktemp -d /tmp/rc-849o-live-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
# F1 builds a scratch image under F_TAG; it is removed with the fixtures.
F_TAG="rip-cage-x-849o-nomount:1"
cleanup() { msb image remove -f "$F_TAG" >/dev/null 2>&1; docker image rm -f "$F_TAG" >/dev/null 2>&1; rm -rf "$T" "$WS"; }
trap cleanup EXIT

S=rc-dummy-secret
printf '%s\n' "$S" > "${T}/protected-paths"
RO="${T}/ro-src"
MARKER="RC_849O_MARKER_$$"
mkdir -p "$RO" "${T}/xdg"
printf '%s\n' "$MARKER" > "${RO}/${S}"
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

run_rc() {  # CONF LIST ARGS...
  XDG_CONFIG_HOME="${T}/xdg" RC_CAGE_CONF="$1" RC_PROTECTED_PATHS="$2" RC_MULTIPLEXER=none \
    perl -e 'alarm 300; exec @ARGV' "$RC" up "${@:3}"
}
gexec() { perl -e 'alarm 60; exec @ARGV' msb exec "$NAME" "$@" </dev/null 2>&1; }
status() { msb inspect "$NAME" --format json 2>/dev/null | jq -r '.status // empty'; }
AGENTD_RE='agentd: init failed|failed to create bind target'

# --- C1..C5: a real rc up ----------------------------------------------------
UP_LOG="${T}/up.log"
run_rc "$CONF" "${T}/protected-paths" "$WS" </dev/null >"$UP_LOG" 2>&1
UP_RC=$?
echo "--- rc up exit ${UP_RC}; output:"
sed "s/^/    /" "$UP_LOG"
if msb inspect "$NAME" --format json >/dev/null 2>&1; then
  scratch_cage_register "$NAME"
  msb logs --source system "$NAME" </dev/null >>"$UP_LOG" 2>&1
fi

if grep -qE "$AGENTD_RE" "$UP_LOG"; then
  fail "C1 no agentd init failure" "$(grep -E "$AGENTD_RE" "$UP_LOG" | head -2)"
elif [[ "$(status)" == "Running" ]]; then
  pass "C1 the cage booted with an ro mount holding a protected file (rc up exit ${UP_RC})"
else
  fail "C1 the cage is not running" "status '$(status)', rc up exit ${UP_RC}"
fi

_cat=$(gexec -- cat "/mnt/ro/${S}"); _bytes=$(gexec -- sh -c "wc -c < /mnt/ro/${S}")
if printf '%s' "$_cat" | grep -qF "$MARKER"; then
  fail "C2 the protected file reads empty in the guest" "the marker is readable"
elif [[ "${_bytes//[[:space:]]/}" == "0" ]]; then
  pass "C2 the protected file reads empty in the guest (0 bytes)"
else
  fail "C2 the protected file reads empty in the guest" "wc -c: '${_bytes}', cat: '${_cat}'"
fi

_sib=$(gexec -- cat /mnt/ro/visible.txt)
if [[ "$_sib" == "visible" ]]; then pass "C3 the sibling reads its content"; else fail "C3 the sibling reads its content" "'${_sib}'"; fi

_w=$(gexec -u root -- sh -c 'echo x > /mnt/ro/written-by-guest && echo WROTE');
if [[ "$_w" != *WROTE* && ! -e "${RO}/written-by-guest" ]]; then
  pass "C4 a write into the ro mount fails, even as guest root"
else
  fail "C4 a write into the ro mount fails" "'${_w}'"
fi

_rec=$(gexec -- cat /run/rip-cage/file-covers)
if [[ "$_rec" == "/mnt/ro/${S}" ]]; then pass "C5 the guest's cover record lists the file"; else fail "C5 cover record" "'${_rec}'"; fi
if grep -q "floor: file-covers" "$UP_LOG"; then
  if grep -qE "^PASS .*floor: file-covers" "$UP_LOG"; then
    pass "C5 the floor probe's file-covers check passed in init"
  else
    fail "C5 the floor probe's file-covers check passed in init" "$(grep "floor: file-covers" "$UP_LOG" | head -1)"
  fi
else
  echo "--- note: ${IMAGE}'s floor probe predates the file-covers check; C5's probe half not exercised"
fi

# --- C7: guest root can undo the cover, and the floor probe sees it ----------
# The stated strength (a visibility default, not a boundary), measured, and the
# probe's check proven non-vacuous. C6's resume then restores the cover.
if grep -q "floor: file-covers" "$UP_LOG"; then
  _um=$(gexec -u root -- umount "/mnt/ro/${S}")
  _probe=$(gexec -- /usr/local/lib/rip-cage/floor-probe.sh)
  if gexec -- cat "/mnt/ro/${S}" | grep -qF "$MARKER" \
     && printf '%s\n' "$_probe" | grep -qE "^FAIL .*floor: file-covers"; then
    pass "C7 after guest root umounts the cover, the content shows and the floor probe's file-covers check FAILs"
  else
    fail "C7 undo + probe" "umount: '${_um}'; probe: $(printf '%s\n' "$_probe" | grep file-covers)"
  fi
fi

# --- C6: resume is a fresh boot; the cover must come back --------------------
perl -e 'alarm 120; exec @ARGV' msb stop "$NAME" </dev/null >/dev/null 2>&1
RES_LOG="${T}/resume.log"
run_rc "$CONF" "${T}/protected-paths" "$WS" </dev/null >"$RES_LOG" 2>&1
_bytes=$(gexec -- sh -c "wc -c < /mnt/ro/${S}")
if [[ "$(status)" == "Running" && "${_bytes//[[:space:]]/}" == "0" ]]; then
  pass "C6 after a resume the protected file still reads empty"
else
  fail "C6 after a resume the protected file still reads empty" "status '$(status)', wc -c '${_bytes}'; $(tail -3 "$RES_LOG")"
fi

perl -e 'alarm 120; exec @ARGV' "$RC" destroy "$NAME" </dev/null >/dev/null 2>&1 && scratch_cage_deregister "$NAME"

# --- F1: forced failure -------------------------------------------------------
# A scratch extension of the image whose `mount` always fails, so the in-guest
# bind cannot land. (A symlinked protected file is NOT a failure case: msb's
# share resolves it host-side and the cover lands -- measured 2026-11-02.)
# Scratch tag only; rip-cage:latest is never rebuilt or reloaded.
mkdir -p "${T}/nomount"
cat > "${T}/nomount/Dockerfile" <<DOCKER
FROM ${IMAGE}
USER root
RUN for _m in /usr/bin/mount /bin/mount; do [ -e "\$_m" ] && ! [ -L "\$_m" ] && printf '#!/bin/sh\necho "mount: forced failure (rip-cage-849o test)" >&2\nexit 32\n' > "\$_m" && chmod 0755 "\$_m"; done; true
USER agent
DOCKER
if ! RC_IMAGE="$F_TAG" "$RC" build --file "${T}/nomount/Dockerfile" >"${T}/nomount-build.log" 2>&1 \
   || ! docker save "$F_TAG" -o "${T}/nomount.tar" >/dev/null 2>&1 \
   || ! msb load --tag "$F_TAG" -i "${T}/nomount.tar" >/dev/null 2>&1; then
  fail "F1 setup: building/loading the failing-mount image" "$(tail -5 "${T}/nomount-build.log")"
else
  rm -f "${T}/nomount.tar"
  sed "s|^image: .*|image: ${F_TAG}|" "$CONF" > "${T}/broken.yaml"
  F_LOG="${T}/forced.log"
  RC_IMAGE="$F_TAG" run_rc "${T}/broken.yaml" "${T}/protected-paths" "$WS" </dev/null >"$F_LOG" 2>&1
  F_RC=$?
  echo "--- forced-failure rc up exit ${F_RC}; output:"
  sed "s/^/    /" "$F_LOG"
  msb inspect "$NAME" --format json >/dev/null 2>&1 && scratch_cage_register "$NAME"
  if [[ "$F_RC" -ne 0 ]] && grep -qF "could not cover the protected file /mnt/ro/${S}" "$F_LOG"; then
    pass "F1 rc up fails loudly naming the file it could not cover (exit ${F_RC})"
  else
    fail "F1 rc up fails loudly naming the file" "exit ${F_RC}"
  fi
  if grep -qF "[rip-cage] Initializing..." "$F_LOG"; then fail "F1 init never starts" "init ran"; else pass "F1 init never starts after a failed cover"; fi
  if [[ "$(status)" != "Running" ]]; then pass "F1 the cage is not left running ('$(status)')"; else fail "F1 the cage is not left running" "Running"; fi
  if grep -qF "$MARKER" "$F_LOG"; then fail "F1 output never echoes the marker"; else pass "F1 output never echoes the marker"; fi
  perl -e 'alarm 120; exec @ARGV' "$RC" destroy "$NAME" </dev/null >/dev/null 2>&1 && scratch_cage_deregister "$NAME"
fi

# --- P: every other shipped name, as a file in an ro mount -------------------
# shellcheck disable=SC2094  # rc only reads the list it is handed; nothing writes it
while IFS= read -r _entry; do
  _entry="${_entry#"${_entry%%[![:space:]]*}"}"; _entry="${_entry%"${_entry##*[![:space:]]}"}"
  [[ -z "$_entry" || "$_entry" == \#* || "$_entry" == .env* ]] && continue
  _src="${T}/p-src-${_entry#.}"
  mkdir -p "$_src"
  printf '%s\n' "$MARKER" > "${_src}/${_entry}"
  write_conf "${T}/p.yaml" "$_src"
  _out=$(run_rc "${T}/p.yaml" "$SHIPPED_LIST" --dry-run "$WS" </dev/null 2>&1); _rc=$?
  if [[ "$_rc" -eq 0 ]] && printf '%s' "$_out" | grep -qF "Would cover /mnt/ro/${_entry} in-guest"; then
    pass "P '${_entry}' as a file in an ro mount is accepted and named as an in-guest cover"
  else
    fail "P '${_entry}' as a file in an ro mount" "exit ${_rc}: $(printf '%s' "$_out" | tail -2)"
  fi
done < "$SHIPPED_LIST"

echo "=== test-protected-paths-ro-mount-live.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
