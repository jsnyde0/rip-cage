#!/usr/bin/env bash
# tests/test-doctor-transcript-persistence.sh -- unit tests for
# `rc doctor`'s transcript-persistence probe (rip-cage-aa4t):
# _doctor_format_transcript_persistence_probe NAME (cli/doctor.sh).
#
# Reports whether a cage's ~/.claude/projects is host-bound. Non-fatal
# either way (this is a legacy/edge state, not a broken cage) -- PASS
# (well, OK) when host-bound, WARN (never FAIL) when not, matching the
# existing probe-severity convention in this file (e.g.
# _doctor_format_auth_probe, _doctor_format_dead_mounts).
#
# `msb` is stubbed via a PATH shim -- host-only, no live cage required,
# same idiom as tests/test-doctor-dead-mount.sh /
# tests/test-cage-claude-projects-host-bound.sh. This file's subshell
# sources cli/lib/msb_runtime.sh directly (defines the `_msb_*`/
# `_cage_claude_projects_host_bound` primitives the awk-extracted doctor.sh
# formatter calls into) and awk-extracts just
# _doctor_format_transcript_persistence_probe from cli/doctor.sh.
#
# Coverage:
#   T1  host-bound projects mount -> OK, names host persistence
#   T2  not host-bound (legacy cage) -> WARN (not FAIL), names the
#       `rc up` recreate remedy AND the `--allow-transcript-loss` override
#   T3  msb inspect fails (couldn't check) -> INFO, not WARN/FAIL (a
#       transient inspect hiccup must not read as "this cage lost
#       persistence")

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../cli/doctor.sh"
MSB_LIB="${SCRIPT_DIR}/../cli/lib/msb_runtime.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== test-doctor-transcript-persistence.sh ==="
echo ""

extract_probe() {
  awk '
    /^_doctor_format_transcript_persistence_probe\(\)/ { found=1 }
    found { print }
    found && /^\}$/ { exit }
  ' "$RC"
}

# ---------------------------------------------------------------------------
# T1: host-bound.
# ---------------------------------------------------------------------------
echo "-- T1: host-bound projects mount --"

T1_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dtp-t1-stub-XXXXXX")
cat > "${T1_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) echo '{"status":"Running","config":{"mounts":[{"type":"bind","host":"/Users/jonatanpi/.claude/projects","guest":"/home/agent/.claude/projects"}]}}'; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${T1_STUB_DIR}/msb"

T1_OUT=$(PATH="${T1_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  $(extract_probe)
  _doctor_format_transcript_persistence_probe 't1-cage'
")
if [[ "$T1_OUT" == OK* ]]; then
  pass "T1a host-bound -> OK"
else
  fail "T1a host-bound -> OK" "got: $T1_OUT"
fi
if [[ "$T1_OUT" == *"host-bound"* ]]; then
  pass "T1b names host-bound state"
else
  fail "T1b names host-bound state" "got: $T1_OUT"
fi
rm -rf "${T1_STUB_DIR}"

# ---------------------------------------------------------------------------
# T2: not host-bound (legacy cage).
# ---------------------------------------------------------------------------
echo ""
echo "-- T2: not host-bound (legacy cage) --"

T2_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dtp-t2-stub-XXXXXX")
cat > "${T2_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) echo '{"status":"Running","config":{"mounts":[{"type":"bind","host":"/some/workspace","guest":"/workspace"}]}}'; exit 0 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${T2_STUB_DIR}/msb"

T2_OUT=$(PATH="${T2_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  $(extract_probe)
  _doctor_format_transcript_persistence_probe 't2-cage'
")
if [[ "$T2_OUT" == WARN* ]]; then
  pass "T2a not host-bound -> WARN (never FAIL)"
else
  fail "T2a not host-bound -> WARN" "got: $T2_OUT"
fi
if [[ "$T2_OUT" == *"rc up"* ]]; then
  pass "T2b names the 'rc up' recreate remedy"
else
  fail "T2b names the 'rc up' recreate remedy" "got: $T2_OUT"
fi
if [[ "$T2_OUT" == *"--allow-transcript-loss"* ]]; then
  pass "T2c names the --allow-transcript-loss override"
else
  fail "T2c names the --allow-transcript-loss override" "got: $T2_OUT"
fi
rm -rf "${T2_STUB_DIR}"

# ---------------------------------------------------------------------------
# T3: msb inspect fails -- couldn't check.
# ---------------------------------------------------------------------------
echo ""
echo "-- T3: msb inspect fails (couldn't check) --"

T3_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dtp-t3-stub-XXXXXX")
cat > "${T3_STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" inspect "*) exit 1 ;;
  *) echo "stub: unhandled args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "${T3_STUB_DIR}/msb"

T3_OUT=$(PATH="${T3_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  $(extract_probe)
  _doctor_format_transcript_persistence_probe 't3-cage'
")
if [[ "$T3_OUT" == INFO* ]]; then
  pass "T3 couldn't-check -> INFO (not WARN/FAIL)"
else
  fail "T3 couldn't-check -> INFO" "got: $T3_OUT"
fi
rm -rf "${T3_STUB_DIR}"

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
