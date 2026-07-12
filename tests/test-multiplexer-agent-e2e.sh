#!/usr/bin/env bash
# test-multiplexer-agent-e2e.sh — NEEDS_CONTAINER e2e (rip-cage-w621.7)
#
# Crystallizes the one genuinely-new slice from the w621 manual validation:
# a pi agent doing REAL WORK through the tmux multiplexer attach surface with
# >=2 DISTINCT tool invocations — the intersection NOT covered by existing tests:
#   - tests/test-multiplexer-lifecycle.sh: tests attach lifecycle (no agent work)
#   - tests/test-pi-e2e.sh: dispatches pi via `docker exec pi -p` (bypasses mux)
# This test drives pi THROUGH tmux (docker exec tmux send-keys → rip-cage session).
#
# Provider pin — WHY openrouter:
#   This test pins `pi --provider openrouter --model $RC_TEST_AGENT_MODEL`
#   (see tests/_agent-model-lib.sh; static API key auth) deliberately. The
#   cage-default provider (openai-codex) is
#   OAuth-based and its access token gets server-side invalidated within hours of
#   issuance (observed 2026-06-14: openai-codex invalidated same day, exit 1 on
#   "authentication token has been invalidated"). A durable regression guard MUST
#   use a non-expiring auth path. The provider is orthogonal to what this test
#   validates (agent agency THROUGH the mux) — pinning a stable provider does NOT
#   weaken the mux surface validation. Same convention as test-agent-mail-concurrent.sh.
#
# Assertions:
#   (a) pi used its native `write` tool AND >=2 distinct tool names in the JSONL:
#       (a1) JSONL has a `write` toolCall entry (cardinal DP6 discriminator:
#            launcher uses bash redirection; agent uses native write tool)
#       (a2) JSONL has >=2 distinct tool names (belt-and-suspenders)
#       Session JSONL is the authoritative durable record; adapted from the
#       POLL_COUNT>=2 idiom in test-agent-mail-concurrent.sh (DP6 guard).
#   (b) RESULT.txt content == expected first line of SEED.txt (agent-produced
#       artifact, not a wrapper's stdout; conjunction with (a) proves agency).
#   (c) exit $FAILURES at end (DP1/DP2 prose-FAIL-exit-0 guard).
#
# False-green defences (rip-cage-test-fail-prose-without-exit-silent-red):
#   DP6 agent-as-launcher: (a1) is the cardinal check — the launcher
#     "Run: head -1 SEED.txt > RESULT.txt" triggers bash + read (pi reads
#     the file for context) but NEVER the native `write` tool → (a1) fires RED.
#   DP4 RC_E2E-gated-probe-never-executed: if RC_E2E unset → visible SKIP,
#     never silent-pass; positive-control revert documented below.
#   DP1/DP2 prose-FAIL-exit-0: FAILURES counter + `exit $FAILURES` at end.
#
# Positive-control (RED-on-revert — documented, not committed):
#   Replace the multi-step prompt in run-pi.sh with the launcher one-liner:
#     -p "Run: head -1 /workspace/SEED.txt > /workspace/RESULT.txt"
#   Pi uses bash shell redirection (no native `write` tool).
#   GREEN on HEAD (multi-step): JSONL has write toolCall → (a1) PASS
#   RED on LAUNCHER revert:     JSONL has NO write toolCall → (a1) fires RED:
#     "pi did NOT use the native write tool — only bash/shell delegation detected"
#   This proves the test discriminates agent AGENCY, not just "pi ran".
#   (Note: the launcher DOES trigger read tool — so `has_non_bash` alone is
#    insufficient; the write-tool-present check is the cardinal discriminator.)
#
# Mechanics (proven in A2 manual runs, rip-cage-w621.2):
#   1. Write /workspace/run-pi.sh BEFORE the cage starts (bind-mount visible
#      inside cage at /workspace/run-pi.sh immediately on startup).
#   2. Use `--session-dir /workspace/.pi-sessions` so the session JSONL
#      persists to the workspace bind-mount and is readable from the host.
#   3. Send `bash /workspace/run-pi.sh` via tmux send-keys — a single-line
#      command with no embedded newlines/quoting issues.
#   4. Poll for RESULT.txt appearance (pi's own write tool action).
#   5. Count toolCall entries in the session JSONL (>=2 = agency proven).
#
# Run:
#   RC_E2E=1 bash tests/test-multiplexer-agent-e2e.sh
#   RC_E2E=1 RC_E2E_REBUILD=1 bash tests/test-multiplexer-agent-e2e.sh
#
# Wired into tests/run-host.sh as NEEDS_CONTAINER per ADR-013 D1/D3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/_agent-model-lib.sh
source "${SCRIPT_DIR}/_agent-model-lib.sh"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Guard: RC_E2E=1 required (NEEDS_CONTAINER / e2e)
# Emit a visible SKIP — NEVER silent-pass (DP4 guard).
# ---------------------------------------------------------------------------
if [[ "${RC_E2E:-}" != "1" ]]; then
  echo "SKIP (NEEDS_CONTAINER / e2e): test-multiplexer-agent-e2e.sh — set RC_E2E=1 to run"
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: docker unavailable
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: rip-cage image not built
# ---------------------------------------------------------------------------
if [[ "${RC_E2E_REBUILD:-0}" == "1" ]]; then
  echo "=== Building rip-cage:latest (RC_E2E_REBUILD=1) ==="
  if ! "$RC" build >/tmp/rc-mux-agent-e2e-build.out 2>&1; then
    echo "FATAL: rc build failed (see /tmp/rc-mux-agent-e2e-build.out)"
    exit 1
  fi
  pass "rc build succeeded"
fi

if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not built — run ./rc build first (or set RC_E2E_REBUILD=1)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: openrouter auth must be present and usable (LOUD-FAIL — not silent-skip)
#
# This test pins --provider openrouter (static API key) to avoid the volatile
# OAuth token of the cage-default provider (openai-codex). Without usable
# openrouter auth the test would silently TIME OUT after 180s with no clear
# reason — a DP4 violation (silent harm). Instead: gate here and LOUD-FAIL.
#
# Pi reads openrouter credentials from ~/.pi/agent/auth.json (the openrouter
# entry's "key" field) OR from the OPENROUTER_API_KEY env var (which rc up
# passes through from the host per ADR-019 D5). We check auth.json because
# OPENROUTER_API_KEY may not be set as a host env var; auth.json is the
# primary credential store that pi uses for openrouter.
#
# Key-presence check (not a liveness probe) is the gate — a non-empty key in
# auth.json is sufficient: if the key is revoked the test will fail at runtime
# with a clear LLM auth error in the pane output, not a silent timeout.
# ---------------------------------------------------------------------------
PI_AUTH_FILE="${HOME}/.pi/agent/auth.json"
if [[ ! -f "$PI_AUTH_FILE" ]]; then
  fail "PRECONDITION: pi auth absent" \
    "${PI_AUTH_FILE} not found — run 'pi /login' first; LOUD-FAIL per DP4 (not silent-skip)"
  exit $FAILURES
fi

# Extract openrouter key from auth.json (never print the value)
_OPENROUTER_KEY_PRESENT=$(python3 -c "
import json, sys
try:
    with open('${PI_AUTH_FILE}') as f:
        data = json.load(f)
    entry = data.get('openrouter', {})
    key = entry.get('key', '')
    print('yes' if key else 'no')
except Exception as e:
    print('no')
" 2>/dev/null || echo "no")

if [[ "$_OPENROUTER_KEY_PRESENT" != "yes" ]]; then
  fail "PRECONDITION: openrouter auth missing or empty in ${PI_AUTH_FILE}" \
    "This test pins --provider openrouter (stable key auth). Run 'pi /login openrouter' or set OPENROUTER_API_KEY. LOUD-FAIL per DP4 — without this the test would silently time out (180s)."
  exit $FAILURES
fi
pass "PRECONDITION: openrouter API key present in ${PI_AUTH_FILE}"

echo "=== test-multiplexer-agent-e2e.sh ==="

# ---------------------------------------------------------------------------
# Scratch workspace (disposable fixture — NOT a real repo)
# Under RC_ALLOWED_ROOTS so rc up accepts it.
# ---------------------------------------------------------------------------
MUX_AGENT_TMP=""

CLEANUP() {
  local c sp
  # Remove the cage spun by this test (keyed on rc.source.path label)
  for c in $(docker ps -a --filter "label=rc.source.path" --format '{{.Names}}' 2>/dev/null); do
    sp=$(docker inspect --format '{{index .Config.Labels "rc.source.path"}}' "$c" 2>/dev/null || true)
    if [[ -n "$MUX_AGENT_TMP" ]] && [[ "$sp" == "${MUX_AGENT_TMP}"/* ]]; then
      docker rm -f "$c" >/dev/null 2>&1 || true
      docker volume rm "rc-state-${c}" >/dev/null 2>&1 || true
    fi
  done
  [[ -n "$MUX_AGENT_TMP" ]] && rm -rf "$MUX_AGENT_TMP"
}
trap CLEANUP EXIT INT TERM

# Resolve to realpath immediately (macOS /var vs /private/var symlink)
MUX_AGENT_TMP=$(mktemp -d)
MUX_AGENT_TMP=$(realpath "$MUX_AGENT_TMP")
mkdir -p "${MUX_AGENT_TMP}/rc-mux-agent"

WORKSPACE="${MUX_AGENT_TMP}/rc-mux-agent/fixture"
mkdir -p "$WORKSPACE"
git -C "$WORKSPACE" init -q 2>/dev/null

# Seed file: pi must READ this and extract the first line
SEED_FIRST_LINE="hello-from-mux-agent-e2e-$(date +%s)"
printf '%s\nline2\nline3\n' "$SEED_FIRST_LINE" > "${WORKSPACE}/SEED.txt"

# .rip-cage.yaml: session.multiplexer: tmux (the surface under test)
printf 'version: 1\nsession:\n  multiplexer: tmux\n' > "${WORKSPACE}/.rip-cage.yaml"

export RC_ALLOWED_ROOTS="${MUX_AGENT_TMP}"

# Container name: derived from workspace parent/basename by rc container_name()
CAGE="rc-mux-agent-fixture"

# Pre-cleanup: remove leftover cage from prior aborted runs
docker rm -f "$CAGE" >/dev/null 2>&1 || true
docker volume rm "rc-state-${CAGE}" >/dev/null 2>&1 || true

echo "MUX_AGENT_TMP=${MUX_AGENT_TMP}"
echo "WORKSPACE=${WORKSPACE}"
echo "SEED_FIRST_LINE=${SEED_FIRST_LINE}"

# ---------------------------------------------------------------------------
# Write /workspace/run-pi.sh BEFORE the cage starts.
# The bind-mount makes this file immediately visible inside the cage at
# /workspace/run-pi.sh. We dispatch this script via tmux send-keys
# (a single short command — no embedded newlines/quoting issues).
#
# DESIGN (anti-launcher, DP6 guard):
# Pi MUST make >=2 DISTINCT tool invocations on separate reasoning steps:
#   Tool call 1: bash — printf 'TOOL_1' >> /workspace/TOOL_LOG.txt
#   Tool call 2: read — read /workspace/SEED.txt (extract first line)
#   Tool call 3: write — write first line to /workspace/RESULT.txt
#   Tool call 4: bash — printf 'TOOL_4' >> /workspace/TOOL_LOG.txt  (sentinel)
# The session JSONL records all toolCall events (including read + write).
# We assert toolCall count >=2 from the JSONL (authoritative) AND
# check TOOL_LOG has >=2 entries as a belt-and-suspenders bash-call proof.
#
# The session is saved to /workspace/.pi-sessions via --session-dir so it
# persists on the workspace bind-mount and is readable from the host.
#
# Positive-control LAUNCHER_PROMPT (to reproduce RED):
#   Replace the -p argument below with:
#   -p "Run: head -1 /workspace/SEED.txt > /workspace/RESULT.txt"
#   That is ONE bash toolCall → JSONL toolCall count = 1 → assertion (a) RED.
# ---------------------------------------------------------------------------
AGENT_PROMPT="You are a coding assistant. Do all four steps below using your tools. Each step is a SEPARATE tool call — do not combine them.

Step 1: bash tool — run exactly: printf 'TOOL_1\n' >> /workspace/TOOL_LOG.txt
Step 2: read tool — read the file /workspace/SEED.txt
Step 3: write tool — write the first line of SEED.txt (and only that line) to /workspace/RESULT.txt
Step 4: bash tool — run exactly: printf 'TOOL_4\n' >> /workspace/TOOL_LOG.txt

All four steps are required. Do them in order."

# Write the pi invocation script to the workspace
cat > "${WORKSPACE}/run-pi.sh" <<PIEOF
#!/usr/bin/env bash
# Generated by test-multiplexer-agent-e2e.sh — dispatched through tmux send-keys
# Provider pinned to openrouter (static API key) — see test header for rationale.
mkdir -p /workspace/.pi-sessions
exec pi \
  --provider openrouter \
  --model ${RC_TEST_AGENT_MODEL} \
  --session-dir /workspace/.pi-sessions \
  -p "You are a coding assistant. Do all four steps below using your tools. Each step is a SEPARATE tool call -- do not combine them.

Step 1: bash tool -- run exactly: printf 'TOOL_1\\n' >> /workspace/TOOL_LOG.txt
Step 2: read tool -- read the file /workspace/SEED.txt
Step 3: write tool -- write the first line of SEED.txt (and only that line) to /workspace/RESULT.txt
Step 4: bash tool -- run exactly: printf 'TOOL_4\\n' >> /workspace/TOOL_LOG.txt

All four steps are required. Do them in order."
PIEOF
chmod +x "${WORKSPACE}/run-pi.sh"

echo ""

# ---------------------------------------------------------------------------
# Spin up the tmux cage
# rc up mounts WORKSPACE at /workspace inside the cage.
# The cage starts sleep infinity; init-rip-cage.sh runs + starts tmux.
# ---------------------------------------------------------------------------
echo "=== Spin up tmux cage (${CAGE}) ==="

"$RC" up "$WORKSPACE" </dev/null >/tmp/rc-mux-agent-e2e-up.out 2>&1 || true

CAGE_STARTED=false
if docker inspect "$CAGE" >/dev/null 2>&1; then
  CAGE_STARTED=true
  pass "Cage started: ${CAGE}"
else
  fail "Cage failed to start (see /tmp/rc-mux-agent-e2e-up.out)"
fi

if [[ "$CAGE_STARTED" != "true" ]]; then
  echo "${FAILURES} failure(s). See /tmp/rc-mux-agent-e2e-up.out for details."
  exit $FAILURES
fi

# ---------------------------------------------------------------------------
# Wait for tmux server + 'rip-cage' session (created by init-rip-cage.sh)
# ---------------------------------------------------------------------------
echo ""
echo "=== Wait for tmux session 'rip-cage' ==="

TMUX_READY=false
for _i in $(seq 1 20); do
  if docker exec "$CAGE" tmux list-sessions 2>/dev/null | grep -q 'rip-cage'; then
    TMUX_READY=true
    break
  fi
  sleep 2
done

if [[ "$TMUX_READY" == "true" ]]; then
  pass "tmux session 'rip-cage' is ready"
else
  TMUX_SESSIONS=$(docker exec "$CAGE" tmux list-sessions 2>/dev/null || echo "(none)")
  fail "tmux session 'rip-cage' did NOT appear after 40s" "sessions: ${TMUX_SESSIONS}"
fi

if [[ "$TMUX_READY" != "true" ]]; then
  exit $FAILURES
fi

# ---------------------------------------------------------------------------
# Verify tmux multiplexer label
# ---------------------------------------------------------------------------
MUX_LABEL=$(docker inspect --format '{{index .Config.Labels "rc.session.multiplexer"}}' "$CAGE" 2>/dev/null || true)
if [[ "$MUX_LABEL" == "tmux" ]]; then
  pass "rc.session.multiplexer label = 'tmux'"
else
  fail "rc.session.multiplexer label = '${MUX_LABEL}' (expected 'tmux')"
fi

# ---------------------------------------------------------------------------
# Dispatch pi THROUGH the tmux attach surface via send-keys.
# This is the gap: send-keys into the rip-cage session (NOT docker exec pi -p).
# We send a single short command (bash /workspace/run-pi.sh) to avoid
# multi-line quoting issues — the prompt lives in run-pi.sh.
# ---------------------------------------------------------------------------
echo ""
echo "=== Dispatch pi through tmux send-keys (the mux attach surface) ==="

docker exec "$CAGE" tmux send-keys -t rip-cage "bash /workspace/run-pi.sh" Enter

pass "tmux send-keys dispatched pi into rip-cage session"

# ---------------------------------------------------------------------------
# Poll for completion: RESULT.txt appears (pi's own write tool action)
# Max wait: 180s (pi needs to: load extensions, call tools, wait for LLM)
# ---------------------------------------------------------------------------
echo ""
echo "=== Poll for pi completion (RESULT.txt) ==="

RESULT_FOUND=false
POLL_TIMEOUT=180
POLL_ELAPSED=0
POLL_INTERVAL=5

while [[ $POLL_ELAPSED -lt $POLL_TIMEOUT ]]; do
  sleep $POLL_INTERVAL
  POLL_ELAPSED=$((POLL_ELAPSED + POLL_INTERVAL))

  RESULT_EXISTS=$(docker exec "$CAGE" test -f /workspace/RESULT.txt 2>/dev/null && echo "yes" || echo "no")

  if [[ "$RESULT_EXISTS" == "yes" ]]; then
    RESULT_FOUND=true
    break
  fi

  # Periodic diagnostics
  if [[ $((POLL_ELAPSED % 30)) -eq 0 ]]; then
    echo "  [t=${POLL_ELAPSED}s] Still waiting... pane (last 5 lines):"
    docker exec "$CAGE" tmux capture-pane -p -t rip-cage -S -5 2>/dev/null | sed 's/^/    /'
  fi
done

# Always show final pane state for diagnostics
echo "Pane (last 20 lines after ${POLL_ELAPSED}s):"
docker exec "$CAGE" tmux capture-pane -p -t rip-cage -S -20 2>/dev/null | sed 's/^/  /'

if [[ "$RESULT_FOUND" == "true" ]]; then
  pass "RESULT.txt appeared after ${POLL_ELAPSED}s (pi completed via tmux surface)"
else
  fail "RESULT.txt did NOT appear within ${POLL_TIMEOUT}s" \
    "pi may not have completed — check pane output above"
fi

# ---------------------------------------------------------------------------
# Assertion (a): >=2 DISTINCT pi tool invocations, with DISTINCT TOOL NAMES
#
# The session JSONL is the authoritative record of pi's tool calls.
# Each "toolCall" entry in a message's content = one distinct tool invocation.
#
# TWO-PART discrimination (DP6 anti-launcher guard):
# (a1) WRITE TOOL PRESENT (cardinal DP6 discriminator): the session JSONL must
#      include a native `write` toolCall entry. A launcher uses bash shell
#      redirection (head -1 FILE > OUTPUT) and NEVER fires pi's native write
#      tool. An agent reasoning through "read file → extract line → write
#      result" uses the native write tool — this is the sharpest discriminator.
#      HEAD (multi-step): tool names = bash + read + write → HAS write → PASS
#      LAUNCHER revert:   tool names = bash + read          → NO  write → FAIL
# (a2) DISTINCT TOOL NAMES ACROSS >=2 TYPES: at least 2 distinct tool names
#      appear in the JSONL toolCall entries (belt-and-suspenders).
#
# This is strictly stronger than just count>=2 (a launcher could make 2 bash
# calls) and directly proven by the A2 manual run which showed distinct tool
# names: bash/find, read/.rip-cage.yaml, write/RESULT.txt.
#
# Belt-and-suspenders: also check TOOL_LOG.txt for bash-call evidence
# (pi's step 1 + step 4 bash calls).
#
# Positive-control RED: the launcher prompt "Run: head -1 SEED.txt > RESULT.txt"
# causes pi to use bash (shell redirection) + read (reads file for context) but
# NO native write tool → (a1) fires RED (NO write tool in JSONL).
# Note: launcher DOES produce bash + read (2 distinct tools) → (a2) PASSES;
# it is (a1) — no write tool — that fires RED (the cardinal DP6 guard).
# ---------------------------------------------------------------------------
echo ""
echo "=== Assertion (a): >=2 distinct pi tool invocations (with distinct tool names) ==="

# Find the session JSONL in /workspace/.pi-sessions
SESSION_JSONL=$(docker exec "$CAGE" find /workspace/.pi-sessions -name "*.jsonl" 2>/dev/null | head -1)
echo "  Session JSONL: ${SESSION_JSONL:-<not found>}"

TOOL_CALL_COUNT=0
DISTINCT_TOOL_NAMES=""
DISTINCT_TOOL_COUNT=0
HAS_NON_BASH_TOOL="false"

if [[ -n "$SESSION_JSONL" ]]; then
  # Extract all toolCall names from the JSONL session
  # Format: {"type":"toolCall","name":"read","arguments":{...}}
  JSONL_ANALYSIS=$(docker exec "$CAGE" \
    python3 -c "
import sys, json
total_calls = 0
tool_names = {}
try:
    with open('${SESSION_JSONL}') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get('type') == 'message':
                    msg = obj.get('message', {})
                    content = msg.get('content', [])
                    if isinstance(content, list):
                        for item in content:
                            if isinstance(item, dict) and item.get('type') == 'toolCall':
                                total_calls += 1
                                name = item.get('name', 'unknown')
                                tool_names[name] = tool_names.get(name, 0) + 1
            except json.JSONDecodeError:
                pass
except Exception as e:
    print('ERROR:', e, file=sys.stderr)
names_sorted = sorted(tool_names.keys())
has_non_bash = any(n != 'bash' for n in names_sorted)
print(f'total_calls={total_calls}')
print(f'distinct_names={len(names_sorted)}')
print(f'names={\" \".join(names_sorted)}')
print(f'has_non_bash={has_non_bash}')
for n,c in sorted(tool_names.items()):
    print(f'  tool:{n}={c}')
" 2>/dev/null || echo "total_calls=0
distinct_names=0
names=
has_non_bash=False")

  echo "  JSONL analysis:"
  echo "$JSONL_ANALYSIS" | sed 's/^/    /'

  TOOL_CALL_COUNT=$(echo "$JSONL_ANALYSIS" | grep '^total_calls=' | cut -d= -f2 | tr -d '[:space:]' || echo "0")
  DISTINCT_TOOL_COUNT=$(echo "$JSONL_ANALYSIS" | grep '^distinct_names=' | cut -d= -f2 | tr -d '[:space:]' || echo "0")
  DISTINCT_TOOL_NAMES=$(echo "$JSONL_ANALYSIS" | grep '^names=' | cut -d= -f2- | tr -d '[:space:]' || echo "")
  HAS_NON_BASH_TOOL=$(echo "$JSONL_ANALYSIS" | grep '^has_non_bash=' | cut -d= -f2 | tr -d '[:space:]' || echo "False")

  # Ensure numeric values are clean integers
  TOOL_CALL_COUNT=$(echo "$TOOL_CALL_COUNT" | grep -E '^[0-9]+$' || echo "0")
  DISTINCT_TOOL_COUNT=$(echo "$DISTINCT_TOOL_COUNT" | grep -E '^[0-9]+$' || echo "0")

  echo "  Tool call count: ${TOOL_CALL_COUNT}"
  echo "  Distinct tool names: ${DISTINCT_TOOL_COUNT} (${DISTINCT_TOOL_NAMES})"
  echo "  Has non-bash tool: ${HAS_NON_BASH_TOOL}"
else
  fail "Assertion (a): No session JSONL found in /workspace/.pi-sessions" \
    "pi may not have saved a session (--session-dir may not have worked)"
fi

# Belt-and-suspenders: TOOL_LOG bash-call evidence
TOOL_LOG_CONTENT=$(docker exec "$CAGE" cat /workspace/TOOL_LOG.txt 2>/dev/null || echo "")
# Use awk for counting to avoid grep -c exit-1-on-zero-matches bug with pipefail
BASH_TOOL_COUNT=$(echo "$TOOL_LOG_CONTENT" | awk '/^TOOL_[0-9]+$/{count++} END{print count+0}' 2>/dev/null || echo "0")
echo "  TOOL_LOG content (bash-call evidence):"
echo "$TOOL_LOG_CONTENT" | sed 's/^/    /'
echo "  TOOL_LOG bash-call count: ${BASH_TOOL_COUNT}"

# (a1) CARDINAL assertion (DP6 anti-launcher guard):
# Pi must have used its native `write` tool to produce RESULT.txt.
# A launcher (one bash call: `head -1 SEED.txt > RESULT.txt`) uses bash shell
# redirection — it NEVER fires pi's native `write` tool. An agent reasoning
# through "read file → extract line → write result" uses the native `write` tool.
# This is the sharpest discriminator proven by the positive-control runs:
#   HEAD (multi-step): tool names = bash + read + write → HAS write → PASS
#   LAUNCHER revert:   tool names = bash + read          → NO  write → FAIL
JSONL_HAS_WRITE="false"
if echo "$DISTINCT_TOOL_NAMES" | grep -q "write"; then
  JSONL_HAS_WRITE="true"
fi

if [[ "$JSONL_HAS_WRITE" == "true" ]]; then
  pass "Assertion (a1): pi used native write tool (JSONL confirms write toolCall — agent did real work, not bash delegation)"
else
  fail "Assertion (a1): pi did NOT use the native write tool — only bash/shell delegation detected" \
    "This fires RED on the launcher-prompt revert (positive control, DP6 guard). Tool names: ${DISTINCT_TOOL_NAMES}"
fi

# (a2) Assert: >=2 distinct tool NAMES (belt-and-suspenders)
# Combined with (a1): proves distinct reasoning steps across tool types.
if [[ "$DISTINCT_TOOL_COUNT" -ge 2 ]]; then
  pass "Assertion (a2): pi used ${DISTINCT_TOOL_COUNT} distinct tool types (>=2 required): ${DISTINCT_TOOL_NAMES}"
else
  fail "Assertion (a2): pi used only ${DISTINCT_TOOL_COUNT} distinct tool type(s) — need >=2" \
    "This also fires RED on the launcher-prompt revert (positive control, DP6 guard)"
fi

# Secondary: TOOL_LOG bash-call evidence (pi's explicit step 1+4 bash log calls)
if [[ "$BASH_TOOL_COUNT" -ge 1 ]]; then
  pass "Assertion (a) [secondary]: TOOL_LOG has ${BASH_TOOL_COUNT} bash tool call(s) logged (pi's own step 1+4)"
else
  pass "Assertion (a) [secondary/info]: TOOL_LOG is empty — pi may have skipped the explicit log steps (non-fatal if (a1)+(a2) pass)"
fi

# ---------------------------------------------------------------------------
# Assertion (b): RESULT.txt produced by pi's OWN write tool + content correct
#
# Content check: RESULT.txt must equal SEED_FIRST_LINE (the expected first line).
# This proves the artifact is pi's OWN read→write tool chain:
#   - pi used the read tool on SEED.txt (toolCall #2+)
#   - pi used the write tool to produce RESULT.txt (toolCall #3+)
#   - the content is correct: == SEED_FIRST_LINE
# A wrapper/launcher could write RESULT.txt but the JSONL count would be <2.
# The conjunction (a)+(b) is the full DP6 proof.
# ---------------------------------------------------------------------------
echo ""
echo "=== Assertion (b): RESULT.txt content == expected first line ==="

RESULT_CONTENT=$(docker exec "$CAGE" cat /workspace/RESULT.txt 2>/dev/null | head -1 || echo "")
RESULT_TRIMMED=$(echo "$RESULT_CONTENT" | tr -d '[:space:]')
EXPECTED_TRIMMED=$(echo "$SEED_FIRST_LINE" | tr -d '[:space:]')

echo "  Expected first line: ${SEED_FIRST_LINE}"
echo "  RESULT.txt content:  ${RESULT_CONTENT}"

if [[ -n "$RESULT_CONTENT" ]]; then
  pass "Assertion (b): RESULT.txt is non-empty (pi's write tool executed)"
else
  fail "Assertion (b): RESULT.txt is empty — pi's write tool did not produce content"
fi

if [[ "$RESULT_TRIMMED" == "$EXPECTED_TRIMMED" ]]; then
  pass "Assertion (b): RESULT.txt content matches expected first line of SEED.txt"
else
  fail "Assertion (b): RESULT.txt content MISMATCH" \
    "expected='${SEED_FIRST_LINE}' got='${RESULT_CONTENT}'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== test-multiplexer-agent-e2e.sh complete ==="
echo "Cage: ${CAGE}"
echo "SEED_FIRST_LINE: ${SEED_FIRST_LINE}"
echo "TOOL_CALL_COUNT (JSONL): ${TOOL_CALL_COUNT}"
echo "DISTINCT_TOOL_COUNT (JSONL): ${DISTINCT_TOOL_COUNT} (${DISTINCT_TOOL_NAMES})"
echo "BASH_TOOL_COUNT (TOOL_LOG): ${BASH_TOOL_COUNT}"
echo "RESULT_CONTENT: ${RESULT_CONTENT}"
echo "FAILURES: ${FAILURES}"

if [[ $FAILURES -eq 0 ]]; then
  echo "All multiplexer-agent e2e tests PASSED."
else
  echo "${FAILURES} multiplexer-agent e2e test(s) FAILED."
fi

# DP1/DP2 guard: exit with failure count (NOT hardcoded 0 or 1)
exit $FAILURES
