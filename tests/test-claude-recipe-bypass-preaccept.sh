#!/usr/bin/env bash
# tests/test-claude-recipe-bypass-preaccept.sh -- HOST-ONLY unit test for the
# startup-dialog pre-answers in the examples/claude recipe's session wrapper
# (examples/claude/claude-session-wrapper.sh; rip-cage-k8vi, rip-cage-jimf).
#
# SCOPE: this is the RECIPE's unit test. The wrapper reaches an image only
# when an operator composes examples/claude; the base image never runs it.
# What the BASE image does at claude startup is proven on a built image by
# tests/test-claude-unattended-start-live.sh (rip-cage-jimf). A second pass
# runs the same cases against the unshipped cage/substrate twin.
#
# WHY: under the recipe claude reads CLAUDE_CONFIG_DIR=~/.claude-sessions/<id>.
# Two startup dialogs stop an unattended spawn there: the bypass-permissions
# accept dialog (cleared by skipDangerousModePermissionPrompt in the floor's
# settings.json, which the wrapper symlinks into the session dir) and the
# "make auto mode your default?" nudge (answered by hasSeenAutoDefaultNudge in
# the session's WRITABLE .claude.json -- the host ~/.claude.json is read-only,
# so the answer can never persist there).
#
# This test drives the real wrapper on the HOST (no container) by copying it
# to a tmp file and sed-patching REAL_CLAUDE to an argv-recording stub, with
# RC_P1P_JSON_BASE=<fixture> as the seed source.
#
# Cases:
#   C1  positive sentinel   -- the fixture does NOT carry hasSeenAutoDefaultNudge
#   C2  fresh seed          -- a fresh session dir gets hasSeenAutoDefaultNudge=true
#   C3  content preserved   -- an unrelated fixture key survives the field-set
#   C4  retrofit resume     -- a PRE-EXISTING session .claude.json without the
#                              field still gets it (every-invocation retrofit)
#   C5  idempotent          -- a second run leaves valid JSON, field still true
#   C6/C7 argv flag         -- --dangerously-skip-permissions injected, never doubled
#   C8  floor key reaches   -- the session dir's settings.json resolves to the
#                              floor file, carrying skipDangerousModePermissionPrompt
#
# Hard rules (repo lessons): FAILURES counter + exit $FAILURES; every absence
# assertion gated on a positive sentinel; no "fail via prose + exit 0".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${RC_WRAPPER_UNDER_TEST:-${SCRIPT_DIR}/../examples/claude/claude-session-wrapper.sh}"
FLOOR_SETTINGS="${SCRIPT_DIR}/../cage/agent/settings.json"

FAILURES=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1${2:+ -- $2}"; }

echo "=== test-claude-recipe-bypass-preaccept.sh (${WRAPPER#"${SCRIPT_DIR}/../"}) ==="

# ---------------------------------------------------------------------------
# Guards: jq is required (the wrapper's field-set uses it); the wrapper exists.
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (wrapper field-set requires jq)"
  exit 0
fi
if [[ ! -f "$WRAPPER" ]]; then
  echo "SKIP: wrapper not found at $WRAPPER"
  exit 0
fi

# Scratch HOME so the wrapper's ~/.claude-sessions / ~/.claude live in a sandbox.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rc-k8vi-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.claude"
cp "$FLOOR_SETTINGS" "$WORK/.claude/settings.json"

# A harmless real-claude stub (never touches the network); the patched wrapper's
# final `exec` lands here so the invocation exits cleanly. It records the argv it
# was exec'd with so we can assert the wrapper's flag injection (rip-cage-k8vi).
STUB_CLAUDE="$WORK/stub-claude"
STUB_ARGS="$WORK/stub-args.txt"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n' "$STUB_ARGS" > "$STUB_CLAUDE"
chmod +x "$STUB_CLAUDE"

# Copy the canonical wrapper and patch ONLY REAL_CLAUDE to the stub (source
# untouched), matching the sibling tests' idiom.
WRAPPER_UNDER_TEST="$WORK/wrapper-under-test.sh"
cp "$WRAPPER" "$WRAPPER_UNDER_TEST"
sed -i.bak "s#^REAL_CLAUDE=.*#REAL_CLAUDE=${STUB_CLAUDE}#" "$WRAPPER_UNDER_TEST"
chmod +x "$WRAPPER_UNDER_TEST"
if ! grep -q "^REAL_CLAUDE=${STUB_CLAUDE}$" "$WRAPPER_UNDER_TEST"; then
  fail "setup: REAL_CLAUDE patch did not match (wrapper's REAL_CLAUDE line changed shape?)" ""
  echo "=== aborting: cannot exercise the wrapper without a working exec stub ==="
  exit "$FAILURES"
fi

# Fixture seed: a minimal .claude.json WITHOUT hasSeenAutoDefaultNudge,
# plus an unrelated sentinel key we assert survives.
FIXTURE="$WORK/fixture.claude.json"
cat > "$FIXTURE" <<'EOF'
{"hasCompletedOnboarding": true, "theme": "dark", "k8viSentinel": "keep-me"}
EOF

# Run the wrapper against a named session dir. Returns via the seeded file.
# $1 = session dir name under $WORK/.claude-sessions; $2.. = claude args
# (default: --version). The stub records its exec'd argv into $STUB_ARGS.
run_wrapper() {
  local _sess="$1"; shift
  local _args=("$@"); [[ ${#_args[@]} -eq 0 ]] && _args=(--version)
  HOME="$WORK" \
  RC_P1P_JSON_BASE="$FIXTURE" \
  CLAUDE_CONFIG_DIR="$WORK/.claude-sessions/$_sess" \
  TMUX="" HERDR_SESSION="" \
  "$WRAPPER_UNDER_TEST" "${_args[@]}" >/dev/null 2>&1
}

field_of() { jq -r '.hasSeenAutoDefaultNudge // "ABSENT"' "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# C1: positive sentinel -- the fixture must NOT already carry the field.
# ---------------------------------------------------------------------------
if [[ "$(field_of "$FIXTURE")" == "ABSENT" ]]; then
  pass "C1 fixture lacks hasSeenAutoDefaultNudge (positive sentinel: test can catch a no-op)"
else
  fail "C1 fixture already has the field -- test is vacuous" "got: $(field_of "$FIXTURE")"
fi

# ---------------------------------------------------------------------------
# C2 + C3: fresh seed sets the field true AND preserves unrelated content.
# ---------------------------------------------------------------------------
run_wrapper "fresh"
FRESH_JSON="$WORK/.claude-sessions/fresh/.claude.json"
if [[ -f "$FRESH_JSON" ]]; then
  if [[ "$(field_of "$FRESH_JSON")" == "true" ]]; then
    pass "C2 fresh session .claude.json has hasSeenAutoDefaultNudge=true"
  else
    fail "C2 fresh session .claude.json field not true" "got: $(field_of "$FRESH_JSON")"
  fi
  if [[ "$(jq -r '.k8viSentinel // "GONE"' "$FRESH_JSON" 2>/dev/null)" == "keep-me" ]]; then
    pass "C3 unrelated seeded key survived the field-set (config not clobbered)"
  else
    fail "C3 unrelated seeded key lost after field-set" "k8viSentinel: $(jq -r '.k8viSentinel // "GONE"' "$FRESH_JSON" 2>/dev/null)"
  fi
else
  fail "C2 fresh session .claude.json was not created" "expected $FRESH_JSON"
  fail "C3 skipped -- no seeded file to inspect"
fi

# ---------------------------------------------------------------------------
# C4: retrofit a PRE-EXISTING session dir. The wrapper skips re-seeding when
# .claude.json already exists (idempotent seed-once), so this proves the
# field-set runs OUTSIDE that block and retrofits resumed/already-seeded dirs.
# ---------------------------------------------------------------------------
RESUME_DIR="$WORK/.claude-sessions/resume"
mkdir -p "$RESUME_DIR"
# Pre-existing config WITHOUT the field (as an old-wrapper boot would have left it).
echo '{"hasCompletedOnboarding": true, "preExisting": "yes"}' > "$RESUME_DIR/.claude.json"
if [[ "$(field_of "$RESUME_DIR/.claude.json")" == "ABSENT" ]]; then
  run_wrapper "resume"
  if [[ "$(field_of "$RESUME_DIR/.claude.json")" == "true" ]]; then
    pass "C4 pre-existing (resumed) session .claude.json retrofitted with the field"
  else
    fail "C4 retrofit did not set the field on a pre-existing session dir" "got: $(field_of "$RESUME_DIR/.claude.json")"
  fi
  # The pre-existing unrelated key must survive (retrofit edits in place, no re-seed).
  if [[ "$(jq -r '.preExisting // "GONE"' "$RESUME_DIR/.claude.json" 2>/dev/null)" == "yes" ]]; then
    pass "C4b retrofit preserved the pre-existing config (no re-seed clobber)"
  else
    fail "C4b retrofit clobbered the pre-existing config" ""
  fi
else
  fail "C4 setup broken -- pre-existing file already had the field" ""
fi

# ---------------------------------------------------------------------------
# C5: idempotent -- second run leaves valid JSON with the field still true.
# ---------------------------------------------------------------------------
run_wrapper "fresh"  # re-run against the already-set fresh dir
if jq -e . "$FRESH_JSON" >/dev/null 2>&1 && [[ "$(field_of "$FRESH_JSON")" == "true" ]]; then
  pass "C5 second wrapper run is idempotent (valid JSON, field still true)"
else
  fail "C5 second run produced invalid JSON or lost the field" "field: $(field_of "$FRESH_JSON")"
fi

# ---------------------------------------------------------------------------
# C6: argv-level flag injection (rip-cage-k8vi ruling) -- the wrapper must pass
# --dangerously-skip-permissions to the exec'd claude so the interactive dialog
# is killed HYPOTHESIS-INDEPENDENTLY (works even if the per-session field isn't
# honored / the launcher bypasses CLAUDE_CONFIG_DIR).
# ---------------------------------------------------------------------------
rm -f "$STUB_ARGS"
run_wrapper "flagcase"
if [[ -f "$STUB_ARGS" ]] && grep -qx -- '--dangerously-skip-permissions' "$STUB_ARGS"; then
  pass "C6 wrapper injects --dangerously-skip-permissions into the exec'd claude argv"
else
  fail "C6 flag not injected" "stub argv: $(tr '\n' ' ' < "$STUB_ARGS" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# C7: idempotent -- when the caller already passes the flag, it is NOT doubled.
# ---------------------------------------------------------------------------
rm -f "$STUB_ARGS"
run_wrapper "flagcase" --dangerously-skip-permissions -p "hi"
_flag_count=$(grep -cx -- '--dangerously-skip-permissions' "$STUB_ARGS" 2>/dev/null)
if [[ "$_flag_count" -eq 1 ]]; then
  pass "C7 caller-supplied --dangerously-skip-permissions is not doubled"
else
  fail "C7 flag doubled or missing (count=$_flag_count)" "stub argv: $(tr '\n' ' ' < "$STUB_ARGS" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# C8: the floor's dialog-1 key reaches the session dir. The wrapper symlinks
# ~/.claude/settings.json into the session dir; claude reads it from there.
# Positive sentinel first: the floor file itself must carry the key.
# ---------------------------------------------------------------------------
if [[ "$(jq -r '.skipDangerousModePermissionPrompt // false' "$FLOOR_SETTINGS" 2>/dev/null)" != "true" ]]; then
  fail "C8 cage/agent/settings.json lacks skipDangerousModePermissionPrompt=true" "$FLOOR_SETTINGS"
elif [[ "$(jq -r '.skipDangerousModePermissionPrompt // false' "$WORK/.claude-sessions/fresh/settings.json" 2>/dev/null)" == "true" ]]; then
  pass "C8 session settings.json carries the floor's skipDangerousModePermissionPrompt=true"
else
  fail "C8 session settings.json does not carry skipDangerousModePermissionPrompt" "$(ls -l "$WORK/.claude-sessions/fresh/settings.json" 2>&1)"
fi

echo ""
echo "=== test-claude-recipe-bypass-preaccept.sh complete: $((TOTAL - FAILURES))/$TOTAL passed ==="

# Second pass: the cage/substrate twin gets the same cases.
if [[ -z "${RC_WRAPPER_UNDER_TEST:-}" ]]; then
  # The child SKIPs (exit 0) on a missing file; name that as a failure here.
  [[ -f "${SCRIPT_DIR}/../cage/substrate/claude-session-wrapper.sh" ]] \
    || { echo "FAIL  cage/substrate/claude-session-wrapper.sh missing -- twin pass cannot run"; FAILURES=$((FAILURES + 1)); }
  RC_WRAPPER_UNDER_TEST="${SCRIPT_DIR}/../cage/substrate/claude-session-wrapper.sh" bash "$0"
  FAILURES=$((FAILURES + $?))
fi
exit "$FAILURES"
