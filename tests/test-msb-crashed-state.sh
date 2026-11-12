#!/usr/bin/env bash
set -uo pipefail

# tests/test-msb-crashed-state.sh -- host-tier proof for rip-cage-4ev0: msb's
# "Crashed" sandbox status reads as the stopped state ("exited"), so rc up
# resumes it and rc up --replace recreates it like any stopped cage, instead of
# refusing it with CONTAINER_STATE_UNSUPPORTED. A status rc has never seen
# still reads "unknown" and is still refused. Runs the REAL rc behind the fake
# runtime (tests/_fake-runtime-lib.sh); no cage, no docker daemon, no msb.
#
#   C1  _msb_sandbox_state: Running->running, Stopped->exited, Crashed->exited,
#       Paused->unknown, absent->"" with non-zero return
#   C2  rc up --replace --dry-run (human and --output json) over a Crashed cage
#       plans the recreate, no CONTAINER_STATE_UNSUPPORTED, no msb stop/remove/create
#   C3  plain rc up --dry-run over a Crashed cage plans a resume, no refusal
#   C4  rc up --replace --dry-run over a Paused cage is still refused as
#       CONTAINER_STATE_UNSUPPORTED (the unknown fallback stays live)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

T=$(mktemp -d /tmp/rc-crashed-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
LOG="${T}/calls.log"
: > "$LOG"
FAKE_BIN=$(fake_runtime_bin "$LOG")
trap 'rm -rf "$T" "$FAKE_BIN"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
export PATH="${FAKE_BIN}:${PATH}"
unset RC_STATE_DIR RC_CAGE_CONF FAKE_MSB_INSPECT_FILE FAKE_MSB_IMAGE_LIST_FILE

PROJ="$T/ws"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$PROJ" "$T/cwd"
C="$T/cage.yaml"
{
  printf 'image: rip-cage:latest\nworkdir: /workspace\nmounts:\n  - "%s:/workspace"\n' "$PROJ"
  printf '  - "%s/.claude/projects:/home/agent/.claude/projects"\n  - "%s/.claude/sessions:/home/agent/.claude/sessions"\n' "$HOME" "$HOME"
  printf 'network:\n  policy: none\n  strict: false\n  allow:\n    - "api.anthropic.com:tcp:443"\n'
} > "$C"

sha_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf '[{"reference":"rip-cage:latest","digest":"%s"}]\n' "$DIGEST" > "$T/images.json"
mk_inspect() { # STATUS -> $T/inspect.json, an rc-made cage for $PROJ on the current config
  jq -n --arg st "$1" --arg dg "$DIGEST" --arg path "$PROJ" --arg sha "$(sha_of "$C")" '
    {status: $st, config: {manifest_digest: $dg, labels: {"rc.source.path": $path, "rc.cage-conf-sha": $sha, "rc.session.multiplexer": "none", "rc.host-tools": "absent"}, mounts: []}}' > "$T/inspect.json"
}
export FAKE_MSB_INSPECT_FILE="$T/inspect.json" FAKE_MSB_IMAGE_LIST_FILE="$T/images.json"

OUT=''; EX=0
run_up() { # ARGS... -> OUT, EX; the call log holds this run only
  : > "$LOG"
  rm -f "${T}/inspect.json.removed"
  OUT=$(cd "$T/cwd" && "$RC" "$@" 2>&1)
  EX=$?
}
mutating_calls() { grep -E '^msb (stop|remove|create|start)' "$LOG"; }

# ============================================================================
echo "=== C1: _msb_sandbox_state maps msb statuses ==="
# shellcheck source=cli/lib/msb_runtime.sh
source "${REPO_ROOT}/cli/lib/msb_runtime.sh"
for _pair in Running:running Stopped:exited Crashed:exited Paused:unknown; do
  mk_inspect "${_pair%%:*}"
  _got=$(_msb_sandbox_state any-name); _rc=$?
  if [[ "$_rc" -eq 0 && "$_got" == "${_pair#*:}" ]]; then pass "C1 ${_pair%%:*} -> ${_pair#*:}"; else fail "C1 ${_pair%%:*}: got '${_got}' rc=${_rc}, want '${_pair#*:}'"; fi
done
: > "$T/inspect.json.removed"
_got=$(_msb_sandbox_state any-name); _rc=$?
if [[ "$_rc" -ne 0 && -z "$_got" ]]; then pass "C1 absent -> '' non-zero"; else fail "C1 absent: got '${_got}' rc=${_rc}"; fi
rm -f "$T/inspect.json.removed"

# ============================================================================
echo "=== C2: rc up --replace --dry-run over a Crashed cage plans the recreate ==="
mk_inspect Crashed
run_up up --replace --dry-run --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 && "$OUT" == *"Would graceful-stop and recreate stopped cage"* && "$OUT" != *"unrecognized state"* ]] && ! mutating_calls >/dev/null; then
  pass "C2a human: plans recreate, no refusal, no msb stop/remove/create/start"
else fail "C2a (ex=${EX}): ${OUT} | calls: $(mutating_calls | tr '\n' ';')"; fi
run_up --output json up --replace --dry-run --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 && "$OUT" != *"CONTAINER_STATE_UNSUPPORTED"* ]] && ! mutating_calls >/dev/null; then
  pass "C2b --output json: no CONTAINER_STATE_UNSUPPORTED, exit 0"
else fail "C2b (ex=${EX}): ${OUT}"; fi

# ============================================================================
echo "=== C3: plain rc up --dry-run over a Crashed cage plans a resume ==="
mk_inspect Crashed
run_up up --dry-run --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 && "$OUT" != *"unrecognized state"* ]] && ! mutating_calls >/dev/null; then
  pass "C3 plain dry-run: no refusal, no mutating msb call"
else fail "C3 (ex=${EX}): ${OUT}"; fi

# ============================================================================
echo "=== C4: an unseen status (Paused) is still refused ==="
mk_inspect Paused
run_up --output json up --replace --dry-run --conf "$C" "$PROJ"
if [[ "$EX" -ne 0 && "$OUT" == *"CONTAINER_STATE_UNSUPPORTED"* && "$OUT" == *"state=unknown"* ]] && ! mutating_calls >/dev/null; then
  pass "C4 Paused: CONTAINER_STATE_UNSUPPORTED state=unknown, cage untouched"
else fail "C4 (ex=${EX}): ${OUT}"; fi

echo
if [[ "$FAILURES" -eq 0 ]]; then echo "All tests passed"; exit 0; fi
echo "${FAILURES} test(s) failed"; exit 1
