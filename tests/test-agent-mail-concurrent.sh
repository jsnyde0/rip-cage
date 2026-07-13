#!/usr/bin/env bash
# test-agent-mail-concurrent.sh — NEEDS_CONTAINER + RC_E2E e2e
#
# Proves: two concurrently-live REAL pi agents coordinate through agent_mail's
# am CLI over pi's bash tool (ADR-019: pi has only bash tool / no MCP bridge).
# Agent A sends a unique per-run sentinel body to agent B while B's pi is live
# and ITERATIVELY POLLING (multiple am mail inbox bash tool calls, driven by
# pi's own reasoning between polls).  B reads and the test asserts B received
# A's EXACT body — written to a result file by pi's own bash tool call (inbox
# JSON redirect: `am mail inbox ... --json > /tmp/result`).
#
# This is the strictly-stronger CONCURRENT successor to rip-cage-ckv (closed
# sequential demo).  The discriminating property: send in A / read in B, both
# concurrently live pi processes, proven via body-EQUALITY.  Pi is the iterative
# executor — NOT a wrapper/launcher — the poll loop is pi's own bash tool loop.
#
# Pre-conditions (LOUD-FAIL, never silent-skip):
#   - host ~/.pi/agent/auth.json present + mountable
#   - agent_mail fixture image built (am binary present) + daemon healthy
#   - am flag surface confirmed against the built binary (rip-cage-swv discovery)
#
# False-green guards (ADR-swv design — second-review fixes applied):
#   - real pi processes in both sessions (not bare am invocations)
#   - pi is the ITERATIVE executor: ≥2 distinct am mail inbox calls in B's pane
#     (pi reasoned across the window, not one blocking script call)
#   - working-liveness gate (B has run am inbox ≥1 time) not just startup marker
#   - send-in-A / read-in-B (two distinct agents, not same-agent loopback)
#   - body-EQUALITY on unique sentinel (not inbox-non-empty)
#   - result file written by pi's own bash tool call (inbox JSON redirect)
#   - exit $FAILURES at end (not hardcoded exit 1)
#
# am flag surface (verified against built binary - rip-cage-swv):
#   am mail send --project <path> --from <agent-name> --to <agent-name> \
#     --subject <s> --body <body>
#   am mail inbox --project <path> --agent <agent-name> --include-bodies --json
#   am agents register --project <path> --program <prog> --model <model>
#     → auto-generates adjective+noun name (wordlist-validated; must not hardcode)
#   daemon: am serve-http --no-auth --no-tui (with STORAGE_ROOT env)
#     mcp-agent-mail serve returns Forbidden on CLI calls; am serve-http --no-auth
#     is the correct server for CLI-level am send/inbox (rip-cage-swv discovery)
#
# Fixture isolation: uses tests/fixtures/manifest-agent-mail-concurrent.yaml
# (am serve-http --no-auth) — NOT the shared manifest-agent-mail.yaml which uses
# mcp-agent-mail serve --no-tui for the T2d sequential MCP-client demo.  This
# removes all regression risk on closed T2d work.
#
# NEEDS_CONTAINER: requires a real running cage + RC_E2E=1.
# Registered in tests/run-host.sh NEEDS_CONTAINER denylist.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/_agent-model-lib.sh
source "${SCRIPT_DIR}/_agent-model-lib.sh"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
# swv uses its OWN concurrent-variant fixture (am serve-http --no-auth)
# to avoid any blast radius on the shared T2d manifest-agent-mail.yaml.
FIXTURE_FILE="${FIXTURES}/manifest-agent-mail-concurrent.yaml"

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Skip guard: RC_E2E must be 1 to run e2e tests
# ---------------------------------------------------------------------------
if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
  echo "SKIP (NEEDS_CONTAINER / e2e): test-agent-mail-concurrent.sh — set RC_E2E=1 to run"
  exit 0
fi

echo "=== test-agent-mail-concurrent.sh ==="

# ---------------------------------------------------------------------------
# PRECONDITION 1 (LOUD-FAIL): pi auth must be present and mountable
# A missing token yields an interactive login pane that can still emit pi's
# startup marker (false-green path, swv design Finding 2).
# ---------------------------------------------------------------------------
PI_AUTH_FILE="${HOME}/.pi/agent/auth.json"
if [[ ! -f "$PI_AUTH_FILE" ]]; then
  fail "PRECONDITION: pi auth absent" "${PI_AUTH_FILE} not found — run 'pi /login' first; LOUD-FAIL per swv design (not silent-skip)"
  exit $FAILURES
fi

# ---------------------------------------------------------------------------
# PRECONDITION 1b (LOUD-FAIL): openrouter auth must be present in auth.json
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

# ---------------------------------------------------------------------------
# PRECONDITION 2 (LOUD-FAIL): fixture file must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$FIXTURE_FILE" ]]; then
  fail "PRECONDITION: swv concurrent fixture not found" "${FIXTURE_FILE}"
  exit $FAILURES
fi

# ---------------------------------------------------------------------------
# Unique per-run sentinel body (false-green guard: stale mailbox cannot pass)
# Simple ASCII — no special chars so pi can work with it safely.
# ---------------------------------------------------------------------------
SENTINEL_BODY="swv-sentinel-$(date +%s)-$$"

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------
T2_BUILD_MANIFEST_HOME=""
CONTAINER_NAME=""
WORKSPACE=""
# rip-cage-7atw.9: IMAGE-CLOBBER GUARD state. The build below overwrites
# rip-cage:latest with this fixture's image (am + herdr baked in); these
# track the pre-build state so cleanup() can restore rip-cage:latest to be
# BYTE-IDENTICAL to what it was before this test ran. Mirrors
# test-multiplexer-lifecycle.sh's MUX_SAVED_LATEST/MUX_HAD_LATEST +
# _mux_restore_latest save/restore pattern (:112-169).
AM_SAVED_LATEST=""
AM_HAD_LATEST=0

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
  if [[ -n "${CONTAINER_NAME:-}" ]]; then
    # herdr agent panes are ephemeral (self-close when the spawned process
    # exits/is killed) — no explicit per-session kill needed before teardown,
    # unlike tmux's persistent sessions. docker stop below reaps everything.
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -n "${T2_BUILD_MANIFEST_HOME:-}" ]]; then
    rm -rf "$T2_BUILD_MANIFEST_HOME"
  fi
  if [[ -n "${WORKSPACE:-}" ]]; then
    rm -rf "$WORKSPACE"
  fi
  # rip-cage-7atw.9 IMAGE-CLOBBER GUARD: restore rip-cage:latest to its
  # pre-test state (byte-identical) — see _mux_restore_latest.
  if [[ -n "${AM_SAVED_LATEST:-}" ]]; then
    if [[ "${AM_HAD_LATEST:-0}" -eq 1 ]]; then
      docker tag "${AM_SAVED_LATEST}" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "${AM_SAVED_LATEST}" 2>/dev/null || true
    AM_SAVED_LATEST=""
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# rip-cage-7atw.9 IMAGE-CLOBBER GUARD: save rip-cage:latest BEFORE the build
# below overwrites it. Mirrors test-multiplexer-lifecycle.sh :123-127.
# ---------------------------------------------------------------------------
_am_tag_suffix="$(date +%s)-$$"
if docker image inspect rip-cage:latest >/dev/null 2>&1; then
  AM_SAVED_LATEST="rip-cage:am-concurrent-saved-${_am_tag_suffix}"
  docker tag rip-cage:latest "${AM_SAVED_LATEST}" 2>/dev/null && AM_HAD_LATEST=1
fi

# ---------------------------------------------------------------------------
# Build the agent_mail fixture image using swv's own concurrent fixture
# Mirrors the _t2_build_agent_mail_image pattern from test-manifest-agent-mail.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup: Build agent_mail fixture image (swv concurrent fixture) ==="

T2_BUILD_MANIFEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-am-concurrent-e2e-XXXXXX")
mkdir -p "${T2_BUILD_MANIFEST_HOME}/.config/rip-cage"
cp "${FIXTURE_FILE}" "${T2_BUILD_MANIFEST_HOME}/.config/rip-cage/tools.yaml"

build_rc=0
echo "[setup] Building cage image with swv concurrent manifest (may take a moment if not cached)..."
build_out=$(HOME="$T2_BUILD_MANIFEST_HOME" \
  XDG_CONFIG_HOME="${T2_BUILD_MANIFEST_HOME}/.config" \
  "${RC}" build 2>&1) || build_rc=$?

if [[ "$build_rc" -ne 0 ]]; then
  fail "SETUP: cage image build failed" "exit=${build_rc} last30: $(echo "$build_out" | tail -30)"
  exit $FAILURES
fi
echo "[setup] Image built: rip-cage:latest"

# ---------------------------------------------------------------------------
# Positive fixture-built sentinel: verify am binary is in the built image
# ---------------------------------------------------------------------------
am_check=""
am_check=$(docker run --rm rip-cage:latest which am 2>/dev/null)
if [[ -z "$am_check" ]]; then
  fail "SETUP: am binary not found in rip-cage:latest after build — fixture image missing am"
  exit $FAILURES
fi
pass "Setup: am binary present in fixture image ($am_check)"

# rip-cage-7atw.9: tmux was un-baked from the base image (commit af7a1ce);
# this fixture now bakes herdr (see manifest-agent-mail-concurrent.yaml) as
# the session-spawner INFRA for the two concurrent named pi agents below.
herdr_check=""
herdr_check=$(docker run --rm rip-cage:latest which herdr 2>/dev/null)
if [[ -z "$herdr_check" ]]; then
  fail "SETUP: herdr binary not found in rip-cage:latest after build — fixture image missing herdr"
  exit $FAILURES
fi
pass "Setup: herdr binary present in fixture image ($herdr_check)"

# ---------------------------------------------------------------------------
# Start the cage container with pi auth mounted
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup: Start cage container ==="

WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/rc-am-concurrent-ws-XXXXXX")
CONTAINER_NAME="rc-am-concurrent-$$"

docker run -d --name "$CONTAINER_NAME" \
  -v "${WORKSPACE}:/workspace" \
  -v "${PI_AUTH_FILE}:/home/agent/.pi/agent/auth.json:ro" \
  -e PI_CODING_AGENT_DIR=/home/agent/.pi/agent \
  -e RC_MULTIPLEXER=herdr \
  rip-cage:latest sleep infinity >/dev/null

# Run init to start the daemon and set up the cage. RC_MULTIPLEXER=herdr
# (above) makes init-rip-cage.sh dispatch the baked herdr MULTIPLEXER start
# hook, which starts 'herdr server' in the background (rip-cage-7atw.9).
docker exec "$CONTAINER_NAME" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1

# ---------------------------------------------------------------------------
# PRECONDITION 2b (LOUD-FAIL): herdr server must be up before any agent spawn
# tmux auto-starts its server on first use; herdr needs its server started
# explicitly (done by the init-rip-cage.sh herdr start hook above) — poll for
# it so a slow-starting server doesn't produce a confusing later failure.
# ---------------------------------------------------------------------------
echo ""
echo "=== Precondition: herdr server health ==="

herdr_server_up=false
for _i in $(seq 1 15); do
  if docker exec -u agent "$CONTAINER_NAME" herdr agent list >/dev/null 2>&1; then
    herdr_server_up=true
    break
  fi
  sleep 1
done

if [[ "$herdr_server_up" != "true" ]]; then
  herdr_log=$(docker exec "$CONTAINER_NAME" cat /tmp/rip-cage-mux-herdr.log 2>/dev/null | head -20)
  fail "PRECONDITION: herdr server NOT reachable after 15s" "log: ${herdr_log}"
  exit $FAILURES
fi
pass "Precondition: herdr server reachable (herdr agent list responded)"

# ---------------------------------------------------------------------------
# PRECONDITION 3 (LOUD-FAIL): daemon must be healthy before any send
# ---------------------------------------------------------------------------
echo ""
echo "=== Precondition: Daemon health ==="

daemon_healthy=false
for _i in $(seq 1 15); do
  if docker exec "$CONTAINER_NAME" timeout 5 curl -sf http://127.0.0.1:8765/healthz >/dev/null 2>&1; then
    daemon_healthy=true
    break
  fi
  sleep 2
done

if [[ "$daemon_healthy" != "true" ]]; then
  daemon_log=$(docker exec "$CONTAINER_NAME" cat /tmp/rip-cage-daemon-agent-mail.log 2>/dev/null | head -20)
  fail "PRECONDITION: agent_mail daemon NOT healthy after 30s" "log: ${daemon_log}"
  exit $FAILURES
fi

health_body=$(docker exec "$CONTAINER_NAME" timeout 5 curl -sf http://127.0.0.1:8765/healthz 2>/dev/null)
pass "Precondition: daemon healthy (body='${health_body:0:60}')"

# ---------------------------------------------------------------------------
# PRECONDITION 4: Verify am flag surface against built binary
# (rip-cage-swv discovery: verified real surface before writing test commands)
# ---------------------------------------------------------------------------
echo ""
echo "=== Precondition: Verify am mail flag surface ==="

send_help=$(docker exec "$CONTAINER_NAME" am mail send --help 2>&1)
inbox_help=$(docker exec "$CONTAINER_NAME" am mail inbox --help 2>&1)

if echo "$send_help" | grep -q -- "--from"; then
  pass "Precondition: am mail send --from flag present"
else
  fail "PRECONDITION: am mail send --from flag not found" "$send_help"
  exit $FAILURES
fi

if echo "$inbox_help" | grep -q -- "--agent"; then
  pass "Precondition: am mail inbox --agent flag present"
else
  fail "PRECONDITION: am mail inbox --agent flag not found" "$inbox_help"
  exit $FAILURES
fi

if echo "$inbox_help" | grep -q -- "--include-bodies"; then
  pass "Precondition: am mail inbox --include-bodies flag present"
else
  fail "PRECONDITION: am mail inbox --include-bodies flag not found" "$inbox_help"
  exit $FAILURES
fi

# Verify daemon accepts CLI calls (distinguishes am serve-http --no-auth from mcp-agent-mail serve)
cli_compat_check=$(docker exec "$CONTAINER_NAME" curl -sf -X POST "http://127.0.0.1:8765/mcp/session" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":"health_check","arguments":{}}}' 2>/dev/null)
if echo "$cli_compat_check" | grep -q '"result"'; then
  pass "Precondition: daemon accepts MCP tool calls (no-auth server confirmed)"
else
  fail "PRECONDITION: daemon MCP tool calls not working — is server am serve-http --no-auth?" "$cli_compat_check"
  exit $FAILURES
fi

# ---------------------------------------------------------------------------
# Setup: Register two agents in the workspace project
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup: Register agents ==="

AGENT_A_NAME=$(docker exec "$CONTAINER_NAME" am agents register \
  --project /workspace --program pi --model "${RC_TEST_AGENT_MODEL_NATIVE}" --json 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null)

if [[ -z "$AGENT_A_NAME" ]]; then
  fail "SETUP: Failed to register agent A (no name returned)"
  exit $FAILURES
fi
pass "Setup: agent A registered as '${AGENT_A_NAME}'"

AGENT_B_NAME=$(docker exec "$CONTAINER_NAME" am agents register \
  --project /workspace --program pi --model "${RC_TEST_AGENT_MODEL_NATIVE}" --json 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null)

if [[ -z "$AGENT_B_NAME" ]]; then
  fail "SETUP: Failed to register agent B (no name returned)"
  exit $FAILURES
fi
pass "Setup: agent B registered as '${AGENT_B_NAME}'"

if [[ "$AGENT_A_NAME" == "$AGENT_B_NAME" ]]; then
  fail "SETUP: agent A and B have the same name — not distinct agents" "name=${AGENT_A_NAME}"
  exit $FAILURES
fi
pass "Setup: agents A ('${AGENT_A_NAME}') and B ('${AGENT_B_NAME}') are distinct"

echo "Sentinel body: ${SENTINEL_BODY}"
echo "Agent A (sender): ${AGENT_A_NAME}"
echo "Agent B (receiver): ${AGENT_B_NAME}"

# ---------------------------------------------------------------------------
# Paths for result files (written INSIDE the container by pi's own bash calls)
# B_RESULT_FILE: pi writes inbox JSON here (am mail inbox ... --json > file)
# B_POLL_LOG: pi writes POLL_N lines here to prove iteration count
# ---------------------------------------------------------------------------
B_RESULT_FILE="/tmp/rc-am-swv-b-result.json"
B_POLL_LOG="/tmp/rc-am-swv-b-poll.log"
PROMPT_B_PATH="/tmp/rc-am-swv-prompt-b.txt"
PROMPT_A_PATH="/tmp/rc-am-swv-prompt-a.txt"

# ---------------------------------------------------------------------------
# Write agent B's pi prompt into the container.
#
# DESIGN REQUIREMENT (second-review cardinal finding):
# B's pi must ITSELF iterate: run am mail inbox multiple times via its OWN bash
# tool calls, with reasoning between each call. The loop is pi's loop, not a
# pre-baked shell script's loop.
#
# B's strategy:
# 1. Log each poll attempt to B_POLL_LOG (proves pi ran bash tool N times)
# 2. Check inbox with am mail inbox ... --json
# 3. If inbox non-empty (has messages beyond Contact Request), write raw JSON
#    to B_RESULT_FILE using `am mail inbox ... --json > B_RESULT_FILE` (pi's
#    own bash tool call — NOT pre-baked in a script)
# 4. Print INBOX:RECEIVED and stop
# 5. Otherwise sleep 5 and repeat (up to 20 times)
#
# pi's bash tool handles `>` redirection natively. The test extracts body_md
# from the JSON for equality assertion (cleaner than having pi do extraction).
#
# Prompt is written to container file to prevent host shell parsing of any
# special characters in the prompt text.
# ---------------------------------------------------------------------------

docker exec -i "$CONTAINER_NAME" tee "$PROMPT_B_PATH" > /dev/null <<PROMPT_B_EOF
You are agent ${AGENT_B_NAME}. Poll your inbox for a message, using your bash tool for each step.

Follow these steps, up to 20 times total:

Attempt 1:
1. Run bash: printf 'POLL_1\n' >> ${B_POLL_LOG}
2. Run bash: am mail inbox --project /workspace --agent ${AGENT_B_NAME} --include-bodies --json
3. Look at the output. If the JSON array has any message (ignore messages with subject containing "Contact request"), then:
   a. Run bash: am mail inbox --project /workspace --agent ${AGENT_B_NAME} --include-bodies --json > ${B_RESULT_FILE}
   b. Print exactly: INBOX:RECEIVED
   c. Stop here.
4. If no qualifying message, run bash: sleep 5

Attempt 2:
1. Run bash: printf 'POLL_2\n' >> ${B_POLL_LOG}
2. Run bash: am mail inbox --project /workspace --agent ${AGENT_B_NAME} --include-bodies --json
3. Same check. If message found: write JSON to ${B_RESULT_FILE}, print INBOX:RECEIVED, stop.
4. If not: run bash: sleep 5

Continue this pattern for attempts 3, 4, 5... up to 20.

After attempt 20 with no message found, run bash:
printf 'TIMEOUT\n' > ${B_RESULT_FILE}
Print: INBOX:TIMEOUT

Rules:
- Run EACH step as a SEPARATE bash tool call.
- Do NOT write a shell script. YOU make each bash call.
- Do NOT skip the printf poll logging step.
PROMPT_B_EOF

# ---------------------------------------------------------------------------
# Write agent A's pi prompt into the container.
# A's pi runs am mail send as its own bash tool call.
# ---------------------------------------------------------------------------

docker exec -i "$CONTAINER_NAME" tee "$PROMPT_A_PATH" > /dev/null <<PROMPT_A_EOF
You are agent ${AGENT_A_NAME}. Send one mail message using your bash tool.

Run this bash command:
am mail send --project /workspace --from ${AGENT_A_NAME} --to ${AGENT_B_NAME} --subject swv-test --body ${SENTINEL_BODY}

Show the command output. If the JSON output contains an "id" field, print exactly:
SENT:OK

That is all.
PROMPT_A_EOF

# ---------------------------------------------------------------------------
# herdr pane-read helper (rip-cage-7atw.9 — tmux capture-pane equivalent).
# 'herdr agent read <name> --source visible' returns the pane's CURRENT
# visible screen content as JSON ({"result":{"read":{"text":"..."}}});
# --source visible (not the default 'recent') mirrors tmux capture-pane -p's
# whole-visible-screen semantics. Extracts .result.read.text; empty string
# (not an error) if the agent isn't found (matches the old capture-pane's
# `2>/dev/null` swallow-and-return-empty behavior on a missing target).
#
# NOTE: unlike tmux (remain-on-exit + respawn-pane keeps a session's pane
# alive after its command exits), a herdr agent's pane closes as soon as its
# spawned process exits — so both mail-a/mail-b are spawned as
# 'bash -c "<pi invocation>; sleep <generous-tail>"' below, keeping the pane
# (and its scrollback) readable for the rest of this test's polling windows.
# ---------------------------------------------------------------------------
hread() {
  local target="$1" lines="${2:-300}"
  docker exec "$CONTAINER_NAME" herdr agent read "$target" --source visible --lines "$lines" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d.get('result', {}).get('read', {}).get('text', ''))
except Exception:
    pass
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 1: Spawn agent B FIRST (will iteratively poll inbox)
# B must be in mid-iteration (actively running am mail inbox polls) before A is
# spawned — proving both pi processes are live across the send→read window.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: Spawn agent B (${AGENT_B_NAME}) to iteratively poll inbox ==="

B_PROMPT_CONTENT=$(docker exec "$CONTAINER_NAME" cat "$PROMPT_B_PATH" 2>/dev/null)

# rc agent was retired in rip-cage-1f59 (ADR-006 D7). tmux was un-baked from
# the base image (commit af7a1ce); use herdr's 'agent start' (session-spawner
# INFRA, mirrors tmux new-session -d -s <name> -c <cwd> <argv...> — raw argv
# passthrough, no shell reinterpretation of the prompt text). The trailing
# 'sleep 600' keeps the pane alive well past B's own polling window (up to
# 20 * 5s + reasoning time) so later steps can still read its scrollback.
docker exec "$CONTAINER_NAME" herdr agent start mail-b --cwd /workspace \
  -- bash -c "pi --provider openrouter --model ${RC_TEST_AGENT_MODEL} -p \"\$1\"; sleep 600" _ "$B_PROMPT_CONTENT"
EXIT_B=$?

if [[ $EXIT_B -eq 0 ]]; then
  pass "Step 1: herdr agent start mail-b spawned (exit 0)"
else
  fail "Step 1: herdr agent start mail-b failed" "exit=${EXIT_B}"
fi

# ---------------------------------------------------------------------------
# Step 2: Wait for B to be WORKING — pi made ≥1 am mail inbox call
# Working-liveness gate: B's poll log has ≥1 POLL_ entry (pi actually ran the
# bash tool), AND B's pane shows am mail inbox output.
# The pi startup "escape interrupt" marker is NOT sufficient on its own (swv
# design Finding 4): it persists after pi crash + respawn-pane resurrects pane
# as a bare shell.
# Once B has made ≥1 poll, we proceed to spawn A — B still has more polls coming.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Wait for B to be WORKING (pi has run am mail inbox ≥1 time) ==="

B_WORKING=false
B_STARTUP_SEEN=false
_timeout=120
_waited=0

while [[ $_waited -lt $_timeout ]]; do
  sleep 5
  _waited=$((_waited + 5))

  # Primary liveness gate: pi wrote POLL_1 to the poll log via its bash tool
  POLL_LOG_CONTENT=$(docker exec "$CONTAINER_NAME" cat "$B_POLL_LOG" 2>/dev/null)
  if echo "$POLL_LOG_CONTENT" | grep -qE "^POLL_[0-9]+$"; then
    B_WORKING=true
    break
  fi

  # Secondary: pi startup marker visible (confirms pi process is live)
  PANE_B=$(hread mail-b 200)
  if echo "$PANE_B" | grep -qE "escape interrupt|pi v0\.|openrouter"; then
    B_STARTUP_SEEN=true
  fi
done

echo "B poll log after ${_waited}s:"
docker exec "$CONTAINER_NAME" cat "$B_POLL_LOG" 2>/dev/null | head -5 | sed 's/^/  /'
echo "B pane (last 15 lines after ${_waited}s wait):"
hread mail-b 15 | sed 's/^/  /'

if [[ "$B_WORKING" == "true" ]]; then
  pass "Step 2: agent B is WORKING — pi ran am mail inbox (poll log has POLL_1 entry)"
else
  if [[ "$B_STARTUP_SEEN" == "true" ]]; then
    fail "Step 2: pi started but poll log empty after ${_timeout}s — pi startup seen but bash tool not used for polling"
  else
    fail "Step 2: agent B NOT working — poll log empty and no pi startup marker after ${_timeout}s"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Spawn agent A (sender) — AFTER confirming B is working
# Proves both pi processes are alive across the send→read window.
# A's pi runs am mail send as its own bash tool call.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Spawn agent A (${AGENT_A_NAME}) to send sentinel ==="

A_PROMPT_CONTENT=$(docker exec "$CONTAINER_NAME" cat "$PROMPT_A_PATH" 2>/dev/null)

# rc agent was retired in rip-cage-1f59 (ADR-006 D7). tmux was un-baked from
# the base image (commit af7a1ce); use herdr's 'agent start' — see Step 1's
# comment for the argv/pane-persistence rationale (sleep tail keeps A's pane
# readable through Step 6, well after A's own one-shot task completes).
docker exec "$CONTAINER_NAME" herdr agent start mail-a --cwd /workspace \
  -- bash -c "pi --provider openrouter --model ${RC_TEST_AGENT_MODEL} -p \"\$1\"; sleep 600" _ "$A_PROMPT_CONTENT"
EXIT_A=$?

if [[ $EXIT_A -eq 0 ]]; then
  pass "Step 3: herdr agent start mail-a spawned (exit 0)"
else
  fail "Step 3: herdr agent start mail-a failed" "exit=${EXIT_A}"
fi

# ---------------------------------------------------------------------------
# Step 4: Wait for A to confirm the send (SENT:OK in A's pane)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: Wait for A to confirm send ==="

A_SENT=false
_timeout=120
_waited=0

while [[ $_waited -lt $_timeout ]]; do
  sleep 5
  _waited=$((_waited + 5))

  PANE_A=$(hread mail-a 300)

  if echo "$PANE_A" | grep -q "SENT:OK"; then
    A_SENT=true
    break
  fi
done

echo "A pane (last 15 lines after ${_waited}s wait):"
hread mail-a 15 | sed 's/^/  /'

if [[ "$A_SENT" == "true" ]]; then
  pass "Step 4: agent A confirmed send (SENT:OK seen in pane)"
else
  fail "Step 4: agent A did NOT confirm send within ${_timeout}s — SENT:OK not seen in pane"
fi

# ---------------------------------------------------------------------------
# Step 5: Wait for B to confirm receipt with BODY EQUALITY
# B's pi writes raw inbox JSON to B_RESULT_FILE via its own bash tool call:
#   am mail inbox ... --json > B_RESULT_FILE
# The test then extracts body_md from the JSON for equality assertion.
# This is pi's own tool action — not a wrapper script's output.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Wait for B to confirm receipt with body equality ==="

B_RECEIVED=false
B_BODY_MATCHES=false
RECEIVED_BODY=""
# B polls up to 20 * 5s = 100s. Add generous buffer for pi reasoning + network.
_timeout=300
_waited=0

while [[ $_waited -lt $_timeout ]]; do
  sleep 5
  _waited=$((_waited + 5))

  RESULT_CONTENT=$(docker exec "$CONTAINER_NAME" cat "$B_RESULT_FILE" 2>/dev/null)

  # Non-empty and not TIMEOUT means pi received and wrote inbox JSON
  if [[ -n "$RESULT_CONTENT" && "$RESULT_CONTENT" != "TIMEOUT" ]]; then
    # Extract body_md from JSON (first message that is not a Contact request)
    RECEIVED_BODY=$(echo "$RESULT_CONTENT" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
bodies = [m.get('body_md','') for m in msgs
          if 'Contact request' not in m.get('subject','') and m.get('body_md','')]
print(bodies[0] if bodies else '')
" 2>/dev/null)
    if [[ -n "$RECEIVED_BODY" ]]; then
      B_RECEIVED=true
      SENTINEL_TRIMMED=$(echo "$SENTINEL_BODY" | tr -d '[:space:]')
      RECEIVED_TRIMMED=$(echo "$RECEIVED_BODY" | tr -d '[:space:]')
      if [[ "$RECEIVED_TRIMMED" == "$SENTINEL_TRIMMED" ]]; then
        B_BODY_MATCHES=true
      fi
      break
    fi
  fi

  # Break if B timed out (exhausted all poll iterations)
  if [[ "$RESULT_CONTENT" == "TIMEOUT" ]]; then
    break
  fi
done

echo "B pane (last 20 lines after ${_waited}s wait):"
hread mail-b 20 | sed 's/^/  /'
echo "B result file content (first 10 lines):"
docker exec "$CONTAINER_NAME" cat "$B_RESULT_FILE" 2>/dev/null | head -10 | sed 's/^/  /'
echo "B poll log (all entries):"
docker exec "$CONTAINER_NAME" cat "$B_POLL_LOG" 2>/dev/null | sed 's/^/  /'

if [[ "$B_RECEIVED" == "true" ]]; then
  pass "Step 5: agent B received a message (inbox JSON written by pi's own bash tool call)"
else
  fail "Step 5: agent B did NOT receive a message within ${_timeout}s"
fi

# Body EQUALITY assertion — the load-bearing discriminating check
if [[ "$B_BODY_MATCHES" == "true" ]]; then
  pass "Step 5: BODY EQUALITY confirmed — received='${RECEIVED_BODY}' equals sentinel='${SENTINEL_BODY}'"
elif [[ "$B_RECEIVED" == "true" ]]; then
  fail "Step 5: BODY MISMATCH — received='${RECEIVED_BODY}' does NOT equal sentinel='${SENTINEL_BODY}'"
fi

# ---------------------------------------------------------------------------
# Step 6: Assert pi iterated — ≥2 distinct am mail inbox invocations in B
# This is the cardinal false-green guard (second-review Finding 1):
# proves pi reasoned between polls (not one blocking script call).
# B is spawned before A sends, so B must have polled at least once before A's
# message arrived, then polled again to find it — that is ≥2 invocations.
# Poll log count = number of pi bash tool calls for am mail inbox.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 6: Assert pi iterated (≥2 am mail inbox calls in B's poll log) ==="

POLL_LOG_FINAL=$(docker exec "$CONTAINER_NAME" cat "$B_POLL_LOG" 2>/dev/null)
POLL_COUNT=$(echo "$POLL_LOG_FINAL" | grep -cE "^POLL_[0-9]+$" 2>/dev/null || echo "0")

echo "  Poll log entries: ${POLL_COUNT}"
echo "  Poll log content:"
echo "$POLL_LOG_FINAL" | sed 's/^/    /'

if [[ "$POLL_COUNT" -ge 2 ]]; then
  pass "Step 6: pi iterated — ${POLL_COUNT} distinct am mail inbox invocations (≥2 required)"
else
  fail "Step 6: pi did NOT iterate — only ${POLL_COUNT} poll log entries (need ≥2)" \
    "This means pi acted as a launcher not an agent (second-review cardinal finding)"
fi

# Also check pane for pi process evidence (belt-and-suspenders)
PANE_B_FINAL=$(hread mail-b 2000)

# Verify real pi process in mail-b (not a bare shell invocation)
B_HAS_PI=false
if echo "$PANE_B_FINAL" | grep -qE "escape interrupt|pi v0\.|openrouter|INBOX:"; then
  B_HAS_PI=true
fi
# Poll log entries = pi's bash tool ran (proves pi was alive and using tools)
if echo "$POLL_LOG_FINAL" | grep -qE "^POLL_[0-9]+$"; then
  B_HAS_PI=true
fi

if [[ "$B_HAS_PI" == "true" ]]; then
  pass "Step 6: mail-b session ran a real pi process (pi tool evidence confirmed)"
else
  fail "Step 6: mail-b session did NOT show evidence of a real pi process"
fi

# Verify real pi process in mail-a
PANE_A_FINAL=$(hread mail-a 2000)
A_HAS_PI=false
if echo "$PANE_A_FINAL" | grep -qE "escape interrupt|pi v0\.|openrouter|SENT:OK"; then
  A_HAS_PI=true
fi

if [[ "$A_HAS_PI" == "true" ]]; then
  pass "Step 6: mail-a session ran a real pi process (pi tool evidence confirmed)"
else
  fail "Step 6: mail-a session did NOT show evidence of a real pi process"
fi

# Confirm two distinct named sessions (not same-agent loopback).
# 'rc sessions' was RETIRED (ADR-006 D7): spawn/list/kill moved to being the
# in-cage multiplexer's native surface — 'herdr agent list' for the herdr
# choice (ADR-006 D7/:101). Same grep-on-raw-JSON style as the old check.
AGENT_LIST_JSON=$(docker exec "$CONTAINER_NAME" herdr agent list 2>/dev/null)
A_SESSION_LISTED=false
B_SESSION_LISTED=false
if echo "$AGENT_LIST_JSON" | grep -q '"name":"mail-a"'; then
  A_SESSION_LISTED=true
fi
if echo "$AGENT_LIST_JSON" | grep -q '"name":"mail-b"'; then
  B_SESSION_LISTED=true
fi

if [[ "$A_SESSION_LISTED" == "true" && "$B_SESSION_LISTED" == "true" ]]; then
  pass "Step 6: TWO distinct herdr agent sessions (mail-a + mail-b) confirmed — not a same-agent loopback"
  pass "Step 6: Concurrent coordination proven: send-in-A='${AGENT_A_NAME}' / read-in-B='${AGENT_B_NAME}'"
else
  fail "Step 6: could not confirm two distinct sessions" \
    "mail-a=${A_SESSION_LISTED} mail-b=${B_SESSION_LISTED}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== test-agent-mail-concurrent.sh complete ==="
echo "Sentinel body: ${SENTINEL_BODY}"
echo "Agent A (sender): ${AGENT_A_NAME}"
echo "Agent B (receiver): ${AGENT_B_NAME}"
echo "Poll iterations (pi bash tool calls): ${POLL_COUNT}"
echo "Results: FAILURES=${FAILURES}"
if [[ $FAILURES -eq 0 ]]; then
  echo "All concurrent agent_mail tests PASSED."
else
  echo "${FAILURES} concurrent agent_mail test(s) FAILED."
fi

exit $FAILURES
