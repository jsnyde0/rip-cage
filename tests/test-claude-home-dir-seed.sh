#!/usr/bin/env bash
# tests/test-claude-home-dir-seed.sh -- unit test for _seed_claude_home_dirs()
# (rip-cage-xuy8, S3 of the msb migration epic rip-cage-tsf2).
#
# ADR-029 D4 resume-path corollary / rip-cage-1ujn footgun: the mounted
# claude-home's projects/ and sessions/ dirs must exist BEFORE the cage's
# first mount, or Claude Code session-resume silently breaks with no error
# (the in-guest claude-session-wrapper.sh only symlinks ~/.claude/projects
# and ~/.claude/sessions into its per-session config dir if those dirs are
# ALREADY PRESENT at wrapper-run time; absent dirs make it seed fresh,
# ephemeral copies instead, so session state never lands on the host mount --
# docs/2026-07-09-msb-spike-session-resume.md "Surprises / footguns" #2).
#
# _seed_claude_home_dirs() (cli/up.sh) is the reusable, provisioning-time
# directory-seeding unit: both the current Docker up-path (T3 below) and the
# future msb create-path (S6) must call it, on the claude-home root, BEFORE
# that root is ever mounted into a cage.
#
# Unit-level only, host-side, no docker/msb required. The real msb
# plant->recreate->resume effect verification (the bead's harness target)
# lives in tests/test-msb-claude-home-resume.sh (drives msb directly, since
# S6's rc resume verb does not exist yet).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# T1: fresh (nonexistent) claude-home root -- projects/ and sessions/ dirs
# get created before any mount would happen.
FRESH_ROOT="${TMPROOT}/fresh-claude-home"
bash -c "source '${RC}'; _seed_claude_home_dirs '${FRESH_ROOT}'"
T1_RC=$?
if [[ "$T1_RC" -eq 0 ]]; then
  pass "T1: _seed_claude_home_dirs exits 0 on a nonexistent root"
else
  fail "T1: _seed_claude_home_dirs exited ${T1_RC} on a nonexistent root"
fi
if [[ -d "${FRESH_ROOT}/projects" ]]; then
  pass "T1b: projects/ dir created under a fresh claude-home root"
else
  fail "T1b: projects/ dir NOT created" "expected ${FRESH_ROOT}/projects to exist"
fi
if [[ -d "${FRESH_ROOT}/sessions" ]]; then
  pass "T1c: sessions/ dir created under a fresh claude-home root"
else
  fail "T1c: sessions/ dir NOT created" "expected ${FRESH_ROOT}/sessions to exist"
fi

# T2: idempotent -- calling again on a root that already has real content
# inside projects/ must not clobber or error (rc re-runs this on every up).
echo "PLANTED-MARKER-CONTENT" > "${FRESH_ROOT}/projects/marker.jsonl"
bash -c "source '${RC}'; _seed_claude_home_dirs '${FRESH_ROOT}'"
T2_RC=$?
if [[ "$T2_RC" -eq 0 ]]; then
  pass "T2: _seed_claude_home_dirs is idempotent (exits 0 on a pre-seeded root)"
else
  fail "T2: idempotent call exited ${T2_RC}"
fi
if [[ "$(cat "${FRESH_ROOT}/projects/marker.jsonl" 2>/dev/null)" == "PLANTED-MARKER-CONTENT" ]]; then
  pass "T2b: existing content inside projects/ survives a second call"
else
  fail "T2b: existing content was clobbered by a second call"
fi

# T3: production wiring -- cli/up.sh's _up_prepare_docker_mounts (the real
# provisioning site, dn2) must call _seed_claude_home_dirs rather than
# duplicating the mkdir -p inline (structural check guarding drift between
# this call site and the msb-side S6 sibling that will reuse the same helper).
# shellcheck disable=SC2016  # intentional: literal ${HOME}/.claude pattern in the grep needle
if grep -q '_seed_claude_home_dirs "\${HOME}/\.claude"' "${REPO_ROOT}/cli/up.sh"; then
  pass "T3: cli/up.sh's Docker provisioning path calls _seed_claude_home_dirs"
else
  fail "T3: cli/up.sh does not call _seed_claude_home_dirs at the claude-home provisioning site"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-claude-home-dir-seed.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-claude-home-dir-seed.sh: all ${TOTAL} tests passed ==="
