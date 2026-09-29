#!/usr/bin/env bash
set -uo pipefail

# tests/test-no-verbatim-placeholder.sh -- no cage-visible doc spells an msb
# secret placeholder verbatim (rip-cage-ureo).
#
# msb drops any request whose body carries a bound secret's placeholder (a "$"
# then MSB_ then the secret's name) as a leak: superradcompany/microsandbox#1354,
# fix PR #1700 unmerged as of msb 0.7.4. The rip-cage checkout is commonly
# mounted into cages, so a caged agent that quoted such a doc would send the
# placeholder in every later model call and lose its session. Prose writes
# `$` + `MSB_<NAME>`; YAML writes "\x24MSB_<NAME>", which decodes to the same
# value (measured on msb 0.7.4).
#
# Scope: docs/reference, README.md, share/, .claude/skills -- the text a caged
# agent is pointed at. History docs, ADRs, cli/ comments and tests/ are judged
# on the bead, not guarded here.
#
# Remove this test when upstream #1354 ships in rip-cage's msb floor.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

# Built from parts so this file does not itself carry the string.
NEEDLE='$'"MSB_"

PATHS=(docs/reference README.md share .claude/skills)
for _p in "${PATHS[@]}"; do
  if [[ ! -e "${REPO_ROOT}/${_p}" ]]; then
    echo "FAIL: guarded path ${_p} is missing -- update PATHS, or this test checks nothing"
    exit 1
  fi
done

_rc=0
hits=$(cd "$REPO_ROOT" && grep -rnF -- "$NEEDLE" "${PATHS[@]}") || _rc=$?
if [[ "$_rc" -gt 1 ]]; then
  echo "FAIL: grep exited ${_rc} over the guarded paths"
  exit 1
fi
if [[ "$_rc" -eq 1 ]]; then
  echo "PASS: no verbatim msb placeholder in docs/reference, README.md, share/, .claude/skills"
  exit 0
fi
# shellcheck disable=SC2016  # literal backticks and dollar, printed as-is
printf '%s\n' 'FAIL: verbatim msb placeholder found (write `$` + `MSB_<NAME>` in prose, "\x24MSB_<NAME>" in YAML):'
printf '%s\n' "$hits"
exit 1
