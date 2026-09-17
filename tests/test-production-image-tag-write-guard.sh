#!/usr/bin/env bash
# tests/test-production-image-tag-write-guard.sh — rip-cage-lh62's recurrence guard.
#
# THE RULE: no test file may WRITE the operator's production image tag.
#
# `rip-cage:latest` (docker) and its entry in msb's image cache are host-global
# singletons. Every cage on the machine boots from them, and the operator's
# only way to know what their cages run is to inspect them. A test that swaps a
# stub onto that tag "just for a moment" and tags the real image back is not
# safe, however careful the restore:
#
#   * a kill inside the window leaves the stub installed, and nothing says so.
#     The OS low-memory reaper killed tests/run-host.sh twice on 2026-09-14 --
#     this is a routine event on a shared host, not a freak one. `docker tag`
#     also does not fire the EXIT trap's restore when the shell dies on SIGKILL.
#   * two suite runs on one host race on the same tag, so each can restore the
#     OTHER's stub as if it were the real image.
#
# A test never needs the write. `rc` resolves its image through
# `IMAGE="${RC_IMAGE:-rip-cage:latest}"` (rc:69), so a test points rc at its own
# fixture tag with RC_IMAGE and asserts exactly the same behaviour with no
# window and no restore step.
#
# HISTORY. rip-cage-d2bo.2 removed the msb-cache half of this shape (a
# save/`msb load`/restore dance around the live cache) after it was traced to
# an accidental rip-cage:latest digest change on 2026-09-04. rip-cage-lh62
# removed the docker half: tests/test-rc-commands.sh Tests 14/19/20 each built
# a stub and `docker tag`ged it onto rip-cage:latest, ungated -- they ran on
# every default `bash tests/run-host.sh`, needing neither RC_E2E nor a daemon
# opt-in. This file keeps both halves closed.
#
# WHAT IS NOT COVERED, deliberately:
#
#   * A bare `rc build` with no `-t` and no RC_IMAGE also lands on the
#     production tag. Several suites do that ON PURPOSE
#     (tests/test-manifest-security.sh's untag-on-violation cases,
#     tests/test-multiplexer-lifecycle.sh, tests/test-multiplexer-agent-e2e.sh,
#     tests/test-e2e-lifecycle.sh) and every one is behind an explicit RC_E2E /
#     RC_E2E_REBUILD opt-in, so a default suite run never reaches them. GATING
#     is the contract there -- and T6 below holds the gate in place for the one
#     allowlisted file. This guard is for the UNGATED direct writes, which have
#     no legitimate form.
#
#   * `msb load --tag rip-cage:latest`. A string scan cannot tell that
#     invocation apart from the many assertions that grep a call log for the
#     same text (tests/test-build-msb-load.sh, tests/test-up-msb-load-wiring.sh
#     are full of them, all against a fake msb on PATH). rip-cage-d2bo.2 owns
#     that surface and closed it by removing the mechanism, not by a scan.
#     rip-cage-ely4.7.9 re-decided this and kept the exclusion: a scan here
#     would fire on every one of those assertion lines while still missing the
#     write it is after. msb's cache is guarded at RUNTIME instead, by
#     tests/test-run-host-image-identity-gate.sh and the identity comparison
#     it holds run-host.sh to -- which catches the write whatever spelled it.
#
#   * A test that makes **rc** provision onto the tag. This is the one that got
#     us (rip-cage-ely4.7.9): no test text held `docker tag`, so every case in
#     this file passed, while tests/test-rc-commands.sh reached an rc path that
#     read the local image's version label, judged it stale, pulled the release
#     and tagged it onto rip-cage:latest -- then saved it into msb's cache. A
#     static scan of tests/ cannot see a write that happens inside cli/. The
#     lever is RC_IMAGE, the runtime gate is the backstop, and neither is a
#     scan; that is why this file stays narrow rather than growing heuristics.
#
# Host-only, static. No docker, no msb, no cage.
#
# Coverage:
#   T1  no tests/ file `docker tag`s anything ONTO rip-cage:latest
#   T2  no tests/ file `docker build -t rip-cage:latest`
#   T3  NEGATIVE CONTROL: the same scanner, pointed at a planted fixture that
#       does both, finds both (so T1/T2 are not vacuous)
#   T4  rip-cage:latest as a READ source (`docker tag rip-cage:latest <other>`)
#       is still allowed -- the guard bans writes, not reads
#   T5  every allowlisted file is still on disk (a rename must re-open the
#       question, not silently widen the allowlist)
#   T6  every allowlisted file still gates its write behind RC_E2E -- deleting
#       that gate reddens this guard

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

PROD_TAG='rip-cage:latest'

# ALLOWLIST -- the ONLY files permitted to write the production tag, each with
# the reason it is allowed and the gate that keeps it harmless. Adding a name
# here is a decision, not a formality: the write is only acceptable because a
# default `bash tests/run-host.sh` with no env overrides never reaches it. T5
# and T6 below hold both halves of that claim.
#
# THE LIST IS EMPTY, AND THAT IS THE DECISION (rip-cage-ely4.7.3, re-deciding
# what T5 below asked to be re-decided). Its one entry was the manifest
# security suite, allowed because its hostile arms built onto the default tag
# on purpose, to prove cmd_build's own untag-on-violation safety net fired on
# the real production tag. That suite retired with the manifest it tested
# (rip-cage-ely4.11), and no surviving file has a reason to write the
# production tag. So the rule is now unqualified: nothing under tests/ writes
# it. Re-adding a name is a decision, not a formality -- the write is only
# ever acceptable while a default `bash tests/run-host.sh` with no env
# overrides cannot reach it, and T5/T6 below hold both halves of that claim.
_ALLOWLIST=""

# _scan_writes <dir> <exclude-basename> <apply-allowlist:0|1>
# Prints one "file:line:text" per offending line. Two patterns, each written so
# the production tag must be the DESTINATION:
#   docker tag <source> rip-cage:latest   (2nd positional = destination)
#   docker build ... -t rip-cage:latest
# Comment-only lines are dropped first, so the prose above -- and every file's
# own rationale -- never trips its own guard.
_scan_writes() {
  local _dir="$1"
  local _exclude="$2"
  local _use_allowlist="${3:-1}"
  local _f _base
  for _f in "${_dir}"/*.sh; do
    [[ -f "$_f" ]] || continue
    _base="$(basename "$_f")"
    [[ "$_base" == "$_exclude" ]] && continue
    if [[ "$_use_allowlist" -eq 1 ]] && echo "$_ALLOWLIST" | grep -qw "$_base"; then
      continue
    fi
    # `docker image tag` and `docker image build` are the same commands under
    # docker's newer management-verb spelling; a scan that only knows the
    # short form is one rename away from blind (rip-cage-ely4.7.9).
    grep -nE \
      -e "docker[[:space:]]+(image[[:space:]]+)?tag[[:space:]]+[^[:space:]]+[[:space:]]+[\"']?${PROD_TAG}" \
      -e "docker[[:space:]]+(image[[:space:]]+)?build[^#]*-t[[:space:]]+[\"']?${PROD_TAG}" \
      "$_f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | sed "s|^|${_base}:|"
  done
}

HITS=$(_scan_writes "$SCRIPT_DIR" "$SELF" 1)

echo "=== T1/T2: no un-allowlisted tests/ file writes ${PROD_TAG} ==="
t1=$(echo "$HITS" | grep -E "docker[[:space:]]+tag" || true)
if [[ -z "$t1" ]]; then
  pass "T1: nothing 'docker tag's a stub onto ${PROD_TAG}"
else
  fail "T1: a test writes the production tag via docker tag" "$t1"
fi

t2=$(echo "$HITS" | grep -E "docker[[:space:]]+build" || true)
if [[ -z "$t2" ]]; then
  pass "T2: nothing 'docker build -t ${PROD_TAG}'s"
else
  fail "T2: a test writes the production tag via docker build -t" "$t2"
fi

echo ""
echo "=== T3 (NEGATIVE CONTROL): the scanner finds each shape when it IS present ==="
PLANT=$(mktemp -d "${TMPDIR:-/tmp}/rc-lh62-plant-XXXXXX")
cat > "${PLANT}/test-planted-violation.sh" <<PLANTEOF
#!/usr/bin/env bash
# This comment mentions docker tag STUB ${PROD_TAG} and must NOT be counted.
docker tag "\$STUB" ${PROD_TAG}
docker build -q -t ${PROD_TAG} - < Dockerfile
docker image tag "\$STUB" ${PROD_TAG}
PLANTEOF
PLANT_HITS=$(_scan_writes "$PLANT" "$SELF" 1)

if echo "$PLANT_HITS" | grep -qE "docker[[:space:]]+tag"; then
  pass "T3a: the docker-tag shape is detected (T1 is load-bearing)"
else
  fail "T3a: scanner missed a planted 'docker tag ... ${PROD_TAG}'" "$PLANT_HITS"
fi
if echo "$PLANT_HITS" | grep -qE "docker[[:space:]]+build"; then
  pass "T3b: the docker-build-t shape is detected (T2 is load-bearing)"
else
  fail "T3b: scanner missed a planted 'docker build -t ${PROD_TAG}'" "$PLANT_HITS"
fi

# rip-cage-ely4.7.9: the management-verb spelling is the same write. A scanner
# that knows only `docker tag` passes a file that spells it `docker image tag`.
if echo "$PLANT_HITS" | grep -qE "docker[[:space:]]+image[[:space:]]+tag"; then
  pass "T3d: the 'docker image tag' spelling is detected too"
else
  fail "T3d: scanner missed a planted 'docker image tag ... ${PROD_TAG}'" "$PLANT_HITS"
fi
# Three planted writes, one planted comment. The count is asserted exactly so
# an over-broad scanner that starts counting the comment line shows up here
# rather than as a mysterious red in T1/T2 (third write added ely4.7.9).
if [[ "$(echo "$PLANT_HITS" | grep -c . )" -eq 3 ]]; then
  pass "T3c: exactly 3 hits — the comment line naming the same shape was not counted"
else
  fail "T3c: expected exactly 3 hits, got $(echo "$PLANT_HITS" | grep -c .)" "$PLANT_HITS"
fi

echo ""
echo "=== T4: reading ${PROD_TAG} is still allowed ==="
READOK=$(mktemp -d "${TMPDIR:-/tmp}/rc-lh62-read-XXXXXX")
cat > "${READOK}/test-reads-only.sh" <<READEOF
#!/usr/bin/env bash
docker tag ${PROD_TAG} rip-cage-test-fixture:smoke
docker image inspect ${PROD_TAG} --format '{{.Id}}'
READEOF
READ_HITS=$(_scan_writes "$READOK" "$SELF" 1)
if [[ -z "$READ_HITS" ]]; then
  pass "T4: ${PROD_TAG} as a tag SOURCE / inspect target is not flagged"
else
  fail "T4: the guard is over-broad — it flagged a read-only use" "$READ_HITS"
fi

echo ""
echo "=== T5/T6: every allowlisted file still exists and still gates its write ==="
# An empty allowlist makes the loop below iterate zero times, which would let
# this whole section report nothing at all and read as green. Say the state out
# loud instead: no exception is currently granted, which is the strictest
# posture this guard can be in.
if [[ -z "$_ALLOWLIST" ]]; then
  pass "T5/T6: the allowlist is empty — no file is granted an exception to the no-production-tag-write rule"
fi
for _al in $_ALLOWLIST; do
  if [[ -f "${SCRIPT_DIR}/${_al}" ]]; then
    pass "T5: allowlisted file ${_al} is still on disk"
  else
    fail "T5: allowlisted file ${_al} is gone — remove it from _ALLOWLIST and re-decide" ""
    continue
  fi
  # The allowlist entry is only defensible while the write stays behind an
  # opt-in. Deleting the gate must redden this guard, not go unnoticed.
  if grep -qE 'RC_E2E' "${SCRIPT_DIR}/${_al}"; then
    pass "T6: ${_al} still gates its production-tag write behind RC_E2E"
  else
    fail "T6: ${_al} writes ${PROD_TAG} with NO RC_E2E gate — it now runs on a default suite run" ""
  fi
  # Sanity: the entry must still be earning its place. An allowlisted file
  # with no write left should be dropped from the list.
  if [[ -n "$(_scan_writes "$SCRIPT_DIR" "$SELF" 0 | grep "^${_al}:" || true)" ]]; then
    pass "T6b: ${_al} does still write the tag (the allowlist entry is not dead weight)"
  else
    fail "T6b: ${_al} no longer writes ${PROD_TAG} — drop it from _ALLOWLIST" ""
  fi
done

echo ""
echo "=== Summary: $FAILURES/$TOTAL failed ==="
echo "TOTALS: PASS=$((TOTAL - FAILURES)) FAIL=${FAILURES}"
[[ "$FAILURES" -eq 0 ]] || exit 1
exit 0
