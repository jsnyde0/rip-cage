#!/usr/bin/env bash
# tests/test-cage-claude-projects-host-bound.sh -- unit tests for
# _cage_claude_projects_host_bound (cli/lib/msb_runtime.sh), the pre-reload
# transcript-persistence predicate (rip-cage-aa4t).
#
# `rc reload` cold-recreates a cage (stop -> remove -> cmd_up). On a
# genuinely-old cage created by a pre-2026-07-08 `rc` (current `rc up`
# always host-binds ~/.claude/projects -- cli/up.sh:999), the guest's
# caged-claude conversation transcripts live only on the ephemeral rootfs
# overlay and are DESTROYED by the recreate. This predicate distinguishes
# "host-bound" (persistence survives the recreate) from "not host-bound"
# (recreate would silently lose in-flight conversations) from "couldn't
# check" (msb inspect itself failed -- e.g. cage gone/unresponsive; callers
# must not treat this the same as "not host-bound", or a flaky inspect call
# would spuriously block every reload).
#
# `msb` is stubbed via a PATH shim -- host-only, no live cage required,
# matching tests/test-doctor-dead-mount.sh's idiom.
#
# Coverage:
#   R1  mounts[] contains a host-bind entry for /home/agent/.claude/projects
#       -> return 0 (host-bound)
#   R2  mounts[] present but no such entry (legacy cage, no host bind) ->
#       return 1 (not host-bound)
#   R3  mounts[] is empty -> return 1 (not host-bound)
#   R4  msb inspect itself fails (cage absent/unresponsive) -> return 2
#       (distinct "couldn't check" -- not 1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSB_LIB="${SCRIPT_DIR}/../cli/lib/msb_runtime.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== test-cage-claude-projects-host-bound.sh ==="
echo ""

# ---------------------------------------------------------------------------
# R1: host-bound -- mounts[] has the projects guest path with a host source.
# ---------------------------------------------------------------------------
echo "-- R1: host-bound projects mount present --"

R1_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-cpb-r1-stub-XXXXXX")
cat > "${R1_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) echo '{"status":"Running","config":{"mounts":[{"type":"bind","host":"/Users/jonatanpi/.claude/projects","guest":"/home/agent/.claude/projects"}]}}'; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${R1_STUB_DIR}/msb"

R1_RC=0
PATH="${R1_STUB_DIR}:$PATH" bash -c "source '$MSB_LIB'; _cage_claude_projects_host_bound 'r1-cage'" || R1_RC=$?
if [[ "$R1_RC" -eq 0 ]]; then
  pass "R1 host-bound mount -> return 0"
else
  fail "R1 host-bound mount -> return 0" "got exit $R1_RC"
fi
rm -rf "${R1_STUB_DIR}"

# ---------------------------------------------------------------------------
# R2: mounts[] present, but no projects entry (legacy cage).
# ---------------------------------------------------------------------------
echo ""
echo "-- R2: mounts present, no projects entry --"

R2_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-cpb-r2-stub-XXXXXX")
cat > "${R2_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) echo '{"status":"Running","config":{"mounts":[{"type":"bind","host":"/some/workspace","guest":"/workspace"}]}}'; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${R2_STUB_DIR}/msb"

R2_RC=0
PATH="${R2_STUB_DIR}:$PATH" bash -c "source '$MSB_LIB'; _cage_claude_projects_host_bound 'r2-cage'" || R2_RC=$?
if [[ "$R2_RC" -eq 1 ]]; then
  pass "R2 no projects entry -> return 1 (not host-bound)"
else
  fail "R2 no projects entry -> return 1" "got exit $R2_RC"
fi
rm -rf "${R2_STUB_DIR}"

# ---------------------------------------------------------------------------
# R3: mounts[] empty.
# ---------------------------------------------------------------------------
echo ""
echo "-- R3: mounts empty --"

R3_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-cpb-r3-stub-XXXXXX")
cat > "${R3_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) echo '{"status":"Running","config":{"mounts":[]}}'; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${R3_STUB_DIR}/msb"

R3_RC=0
PATH="${R3_STUB_DIR}:$PATH" bash -c "source '$MSB_LIB'; _cage_claude_projects_host_bound 'r3-cage'" || R3_RC=$?
if [[ "$R3_RC" -eq 1 ]]; then
  pass "R3 empty mounts -> return 1 (not host-bound)"
else
  fail "R3 empty mounts -> return 1" "got exit $R3_RC"
fi
rm -rf "${R3_STUB_DIR}"

# ---------------------------------------------------------------------------
# R4: msb inspect itself fails (cage absent/unresponsive) -- distinct "couldn't
# check" return (2), not conflated with "not host-bound" (1).
# ---------------------------------------------------------------------------
echo ""
echo "-- R4: msb inspect fails --"

R4_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-cpb-r4-stub-XXXXXX")
cat > "${R4_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) exit 1 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${R4_STUB_DIR}/msb"

R4_RC=0
PATH="${R4_STUB_DIR}:$PATH" bash -c "source '$MSB_LIB'; _cage_claude_projects_host_bound 'r4-cage'" || R4_RC=$?
if [[ "$R4_RC" -eq 2 ]]; then
  pass "R4 msb inspect failure -> return 2 (couldn't check, distinct from not-host-bound)"
else
  fail "R4 msb inspect failure -> return 2" "got exit $R4_RC"
fi
rm -rf "${R4_STUB_DIR}"

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
