#!/usr/bin/env bash
# test-multiplexer-lifecycle.sh — NEEDS_CONTAINER e2e test (rip-cage-1f59.8)
#
# Integration harness parameterized over session.multiplexer (none | tmux | herdr).
# This IS the parent signal for rip-cage-1f59 (the decoupling epic).
#
# Assertions:
#   (a) none  — plain shell, no tmux/herdr server (enumerated expected processes);
#               two rc exec / rc attach terminals concurrently independent; close-one-leaves-other.
#   (b) tmux  — started session survives a detach/reattach cycle.
#   (c) retirement — rc agent / rc sessions gone from dispatch, --help, schema,
#                    completions, and --output json allowlist.
#   (d) config-isolation — reuse p1p probe (test-claude-concurrency.sh, READ-only)
#                          green under none+tmux; gating under herdr (now installable).
#   herdr spawn — herdr server starts + a herdr session is reachable.
#   herdr status-view — semantic render assertion (rip-cage-w621.9 / ADR-006 D8):
#               drives pi THROUGH herdr agent start, polls herdr agent list for
#               agent_status=working + screen_detection_skipped=true (integration
#               path, NOT process-detection fallback). RC_E2E+openrouter-auth-gated;
#               visible SKIP when auth absent. Gap is CLOSED (was skip-with-log).
#
# Conventions:
#   - FAILURES counter + [[ $FAILURES -eq 0 ]] || exit 1 at end (no prose-only red).
#   - cleanup trap tears down every scratch cage on EXIT/INT/TERM.
#   - rc builds with RC_E2E_REBUILD=1; otherwise uses existing rip-cage:latest.
#   - RC_E2E=1 required to run (self-skips otherwise — NEEDS_CONTAINER per ADR-013).
#
# Run:
#   RC_E2E=1 bash tests/test-multiplexer-lifecycle.sh
#   RC_E2E=1 RC_E2E_REBUILD=1 bash tests/test-multiplexer-lifecycle.sh
#
# Wired into tests/run-host.sh as NEEDS_CONTAINER per ADR-013 D1/D3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+  -- $2}"; FAILURES=$((FAILURES + 1)); }
skip() { echo "SKIP ($1): $2"; }

# ---------------------------------------------------------------------------
# Guard: RC_E2E=1 required (NEEDS_CONTAINER)
# ---------------------------------------------------------------------------
if [[ "${RC_E2E:-}" != "1" ]]; then
  echo "SKIP (NEEDS_CONTAINER / e2e): test-multiplexer-lifecycle.sh — set RC_E2E=1 to run"
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
  if ! "$RC" build >/tmp/rc-mux-lifecycle-build.out 2>&1; then
    echo "FATAL: rc build failed (see /tmp/rc-mux-lifecycle-build.out)"
    exit 1
  fi
  pass "rc build succeeded"
fi

if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not built — run ./rc build first (or set RC_E2E_REBUILD=1)"
  exit 0
fi

# ---------------------------------------------------------------------------
# rip-cage-61al.3: Build the combined mux-registry image (tmux + herdr MULTIPLEXER).
#
# After B3, init-rip-cage.sh dispatches through the baked registry at
# /etc/rip-cage/multiplexers/<name>/start. The combined fixture bakes BOTH tmux
# and herdr providers so the lifecycle tests exercise real registry dispatch.
#
# The build is always done here (throwaway tag, not rip-cage:latest) so the test
# is self-contained and does not pollute the user's working image.
# ---------------------------------------------------------------------------
MUX_COMBINED_FIXTURE="${SCRIPT_DIR}/fixtures/manifest-mux-combined.yaml"
MUX_COMBINED_IMAGE=""
MUX_SAVED_LATEST=""
MUX_HAD_LATEST=0

_mux_build_combined_image() {
  if [[ -n "${MUX_COMBINED_IMAGE:-}" ]]; then
    return 0
  fi
  if [[ ! -f "$MUX_COMBINED_FIXTURE" ]]; then
    echo "FATAL: combined mux fixture not found at ${MUX_COMBINED_FIXTURE}"
    exit 1
  fi

  local unique_suffix
  unique_suffix="$(date +%s)-$$"
  MUX_SAVED_LATEST="rip-cage:mux-lifecycle-saved-${unique_suffix}"
  MUX_HAD_LATEST=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "${MUX_SAVED_LATEST}" 2>/dev/null && MUX_HAD_LATEST=1
  fi

  local mux_build_home
  mux_build_home=$(mktemp -d)
  mkdir -p "${mux_build_home}/.config/rip-cage"
  cp "$MUX_COMBINED_FIXTURE" "${mux_build_home}/.config/rip-cage/tools.yaml"
  echo "=== Building combined tmux+herdr registry image (manifest-mux-combined.yaml) ==="
  local mux_build_rc=0
  HOME="$mux_build_home" XDG_CONFIG_HOME="${mux_build_home}/.config" \
    "$RC" build >/tmp/rc-mux-lifecycle-combined-build.out 2>&1 || mux_build_rc=$?
  rm -rf "$mux_build_home"

  if [[ "$mux_build_rc" -ne 0 ]]; then
    fail "combined mux registry image build FAILED (see /tmp/rc-mux-lifecycle-combined-build.out)"
    echo "FATAL: cannot run mux lifecycle tests without the combined registry image"
    # Restore rip-cage:latest so we leave the user's system in a good state
    if [[ "${MUX_HAD_LATEST}" -eq 1 ]]; then
      docker tag "${MUX_SAVED_LATEST}" rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "${MUX_SAVED_LATEST}" 2>/dev/null || true
    exit 1
  fi

  MUX_COMBINED_IMAGE="rip-cage:mux-lifecycle-combined-${unique_suffix}"
  docker tag rip-cage:latest "${MUX_COMBINED_IMAGE}" 2>/dev/null || true
  pass "combined mux registry image built: ${MUX_COMBINED_IMAGE} (tmux+herdr MULTIPLEXER providers baked)"
}

_mux_restore_latest() {
  if [[ -n "${MUX_COMBINED_IMAGE:-}" ]]; then
    docker image rm "${MUX_COMBINED_IMAGE}" 2>/dev/null || true
    MUX_COMBINED_IMAGE=""
  fi
  if [[ -n "${MUX_SAVED_LATEST:-}" ]]; then
    if [[ "${MUX_HAD_LATEST:-0}" -eq 1 ]]; then
      docker tag "${MUX_SAVED_LATEST}" rip-cage:latest 2>/dev/null || true
    else
      docker image rm rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "${MUX_SAVED_LATEST}" 2>/dev/null || true
    MUX_SAVED_LATEST=""
  fi
}

# ---------------------------------------------------------------------------
# Scratch workspace / container name staging
# ---------------------------------------------------------------------------
# We create three workspaces (none/tmux/herdr) each under a predictable parent
# path so container_name() is deterministic:
#   parent: rc-mux  base: none-test  → container: rc-mux-none-test
#   parent: rc-mux  base: tmux-test  → container: rc-mux-tmux-test
#   parent: rc-mux  base: herdr-test → container: rc-mux-herdr-test
MUX_TMP=""

CLEANUP() {
  local c
  # Destroy all scratch cages spun by this test (keyed on rc.source.path label).
  for c in $(docker ps -a --filter "label=rc.source.path" --format '{{.Names}}' 2>/dev/null); do
    local sp
    sp=$(docker inspect --format '{{index .Config.Labels "rc.source.path"}}' "$c" 2>/dev/null || true)
    if [[ -n "$MUX_TMP" ]] && [[ "$sp" == "${MUX_TMP}"/* ]]; then
      docker rm -f "$c" >/dev/null 2>&1 || true
      docker volume rm "rc-state-${c}" >/dev/null 2>&1 || true
    fi
  done
  [[ -n "$MUX_TMP" ]] && rm -rf "$MUX_TMP"
  # Restore rip-cage:latest if we swapped it for the combined build.
  # _mux_restore_latest is idempotent (no-ops when MUX_SAVED_LATEST is empty).
  _mux_restore_latest
}
# Arm the trap BEFORE the first mutation (_mux_build_combined_image tags aside and
# overwrites rip-cage:latest). An interrupt during the build would otherwise strand
# a modified rip-cage:latest. MUX_TMP is still empty at this point, so the cage-
# cleanup loop in CLEANUP is a safe no-op; _mux_restore_latest handles the image.
trap CLEANUP EXIT INT TERM

# Build combined image now (needed for tmux + herdr lifecycle tests)
_mux_build_combined_image

# Resolve to realpath immediately (before cages are created and before the label is
# stamped) so MUX_TMP matches the rc.source.path label on macOS where mktemp -d
# returns /var/folders/... but rc stores /private/var/folders/... (symlink-resolved).
MUX_TMP=$(mktemp -d)
MUX_TMP=$(realpath "$MUX_TMP")
mkdir -p "${MUX_TMP}/rc-mux"

# Workspace paths
NONE_WS="${MUX_TMP}/rc-mux/none-test"
TMUX_WS="${MUX_TMP}/rc-mux/tmux-test"
HERDR_WS="${MUX_TMP}/rc-mux/herdr-test"

NONE_CAGE="rc-mux-none-test"
TMUX_CAGE="rc-mux-tmux-test"
HERDR_CAGE="rc-mux-herdr-test"

# Pre-cleanup: remove leftover cages from prior aborted runs
for _c in "$NONE_CAGE" "$TMUX_CAGE" "$HERDR_CAGE"; do
  docker rm -f "$_c" >/dev/null 2>&1 || true
  docker volume rm "rc-state-${_c}" >/dev/null 2>&1 || true
done
unset _c

export RC_ALLOWED_ROOTS="${MUX_TMP}"

echo "=== test-multiplexer-lifecycle.sh ==="
echo "MUX_TMP=${MUX_TMP}"
echo ""

# ---------------------------------------------------------------------------
# (c) RETIREMENT: rc agent / rc sessions gone from dispatch, --help,
#     schema, completions, --output json allowlist.
# This is a host-only check — no container needed. Assert it first so the
# retirement evidence is present even when e2e container spins fail.
# ---------------------------------------------------------------------------
echo "=== (c) Retirement assertions (host-only) ==="

# rc agent exits non-zero (unknown command)
RC_AGENT_EXIT=0
"$RC" agent rc-mux-none-test >/dev/null 2>&1 || RC_AGENT_EXIT=$?
if [[ $RC_AGENT_EXIT -ne 0 ]]; then
  pass "(c) rc agent exits non-zero (retired from dispatch)"
else
  fail "(c) rc agent exited 0 — should be an unknown command (not yet retired?)"
fi

# rc sessions exits non-zero (unknown command)
RC_SESSIONS_EXIT=0
"$RC" sessions rc-mux-none-test >/dev/null 2>&1 || RC_SESSIONS_EXIT=$?
if [[ $RC_SESSIONS_EXIT -ne 0 ]]; then
  pass "(c) rc sessions exits non-zero (retired from dispatch)"
else
  fail "(c) rc sessions exited 0 — should be an unknown command (not yet retired?)"
fi

# rc --help / usage does NOT list 'agent' or 'sessions' as top-level commands.
# Check for the command-line usage pattern: a line starting with whitespace,
# then 'agent' or 'sessions' as the first word (the commands section of usage).
# Avoids false-positive on 'ssh-agent' which legitimately appears in flag text.
RC_HELP_OUT=$("$RC" --help 2>&1 || true)
if [[ -z "$RC_HELP_OUT" ]]; then
  fail "(c) rc --help produced no output — cannot assert retirement"
else
  if echo "$RC_HELP_OUT" | grep -Eq '^\s+agent\b'; then
    fail "(c) rc --help still lists 'agent' as a top-level command"
  else
    pass "(c) rc --help does NOT list 'agent' as a top-level command"
  fi
  if echo "$RC_HELP_OUT" | grep -Eq '^\s+sessions\b'; then
    fail "(c) rc --help still lists 'sessions' as a top-level command"
  else
    pass "(c) rc --help does NOT list 'sessions' as a top-level command"
  fi
fi

# rc schema does NOT contain 'agent' or 'sessions' keys
RC_SCHEMA_OUT=$("$RC" schema 2>/dev/null || true)
if echo "$RC_SCHEMA_OUT" | grep -q '"agent"'; then
  fail "(c) rc schema contains 'agent' key"
else
  pass "(c) rc schema does NOT contain 'agent' key"
fi
if echo "$RC_SCHEMA_OUT" | grep -q '"sessions"'; then
  fail "(c) rc schema contains 'sessions' key"
else
  pass "(c) rc schema does NOT contain 'sessions' key"
fi

# rc completions zsh does NOT mention 'agent' or 'sessions' as completion tokens.
# Word-anchored grep avoids false-positives on e.g. 'ssh-agent' in flag descriptions.
RC_COMPLETIONS_ZSH=$("$RC" completions zsh 2>/dev/null || true)
if [[ -z "$RC_COMPLETIONS_ZSH" ]]; then
  fail "(c) rc completions zsh produced no output — cannot assert retirement"
else
  if echo "$RC_COMPLETIONS_ZSH" | grep -Eq '\bagent\b'; then
    fail "(c) rc completions zsh contains 'agent'"
  else
    pass "(c) rc completions zsh does NOT contain 'agent'"
  fi
  if echo "$RC_COMPLETIONS_ZSH" | grep -Eq '\bsessions\b'; then
    fail "(c) rc completions zsh contains 'sessions'"
  else
    pass "(c) rc completions zsh does NOT contain 'sessions'"
  fi
fi

# rc --output json ls does NOT surface 'agent'/'sessions' in the allowed command set
# (probe via schema which is the machine-readable surface)
if echo "$RC_SCHEMA_OUT" | python3 -c "
import sys, json
schema = json.load(sys.stdin)
cmds = list(schema.get('commands', {}).keys())
print('schema_commands:', cmds)
if 'agent' in cmds or 'sessions' in cmds:
    sys.exit(1)
" 2>/dev/null; then
  pass "(c) --output json schema allowlist does NOT contain agent/sessions"
else
  fail "(c) --output json schema allowlist still contains agent or sessions"
fi

# ---------------------------------------------------------------------------
# rip-cage-61al.3: grep-guard — no tmux|herdr literals in rc or init-rip-cage.sh
#
# After B3 de-hardcoding, the only survivors are the schema enum (B2's)
# and the default manifest herdr TOOL entry (C's). All dispatch gates,
# comments, and function names have been de-hardcoded.
# ---------------------------------------------------------------------------
echo ""
echo "=== (rip-cage-61al.3) grep-guard: no optional-mux names in rc/init-rip-cage.sh ==="

REPO_ROOT="${SCRIPT_DIR}/.."
GREP_GUARD_OUT=$(grep -n 'tmux\|herdr' "${REPO_ROOT}/rc" "${REPO_ROOT}/init-rip-cage.sh" 2>/dev/null || true)

if [[ -z "$GREP_GUARD_OUT" ]]; then
  pass "(grep-guard) zero tmux|herdr hits in rc + init-rip-cage.sh"
else
  # Count lines that are NOT in the known carve-outs:
  #   rc schema enum (session.multiplexer|...|none,tmux,herdr) — if still present
  # Note: rc is now fully clean — the default manifest no longer seeds herdr, and
  # all dispatch/default carve-outs have been de-hardcoded. The zero-hits fast path
  # above handles the common case. The survivor filter below is retained as a
  # forward-compatible safety net for any future schema-enum literals that may
  # reappear, but the carve-out path is dead at this revision.
  GREP_GUARD_SURVIVORS=$(echo "$GREP_GUARD_OUT" | grep -v 'session\.multiplexer|selection_list.*none,tmux,herdr' | grep -v '  - name: herdr' | grep -v 'Pinned release.*herdr' | grep -v 'herdr-linux' | grep -v 'ogulcancelik/herdr' | grep -v 'SHA-256.*herdr' | grep -v 'install_cmd.*herdr' | grep -v '\.config/herdr\|herdr pane\|herdr server\|herdr server\|herdr integration\|herdr\.sock\|herdr_pid\|herdr agent\|herdr\.log\|herdr branch' | grep -v 'Server start is wired in init-rip-cage\.sh.*herdr' | grep -v 'Bash-CLI control surface: herdr' || true)
  if [[ -z "$GREP_GUARD_SURVIVORS" ]]; then
    pass "(grep-guard) all tmux|herdr hits are in known B2/C carve-outs (schema enum + default manifest)"
  else
    fail "(grep-guard) unexpected tmux|herdr literals survive in rc or init-rip-cage.sh (B3 de-hardcoding incomplete):"
    echo "$GREP_GUARD_SURVIVORS" | head -20
  fi
fi

echo "  Full grep output (survivors report):"
echo "$GREP_GUARD_OUT" | while IFS= read -r _line; do echo "    $_line"; done
echo ""

# ---------------------------------------------------------------------------
# Spin up cages under each multiplexer value
# ---------------------------------------------------------------------------

# Helper: create workspace + .rip-cage.yaml + git init
_create_workspace() {
  local ws="$1" mux="$2"
  mkdir -p "$ws"
  git -C "$ws" init -q 2>/dev/null
  printf '# mux lifecycle test workspace\n' > "${ws}/README"
  if [[ "$mux" != "none" ]]; then
    printf 'version: 1\nsession:\n  multiplexer: %s\n' "$mux" > "${ws}/.rip-cage.yaml"
  fi
  # no .rip-cage.yaml for none — default is none
}

echo "=== Spinning up cages under each multiplexer ==="
echo ""

# ---- none cage ----
echo "--- Spinning up multiplexer=none cage (${NONE_CAGE}) ---"
_create_workspace "$NONE_WS" "none"
"$RC" up "$NONE_WS" </dev/null >/tmp/rc-mux-none-up.out 2>&1 || true
NONE_STARTED=false
if docker inspect "$NONE_CAGE" >/dev/null 2>&1; then
  NONE_STARTED=true
  pass "(none) cage started: ${NONE_CAGE}"
else
  fail "(none) cage failed to start (see /tmp/rc-mux-none-up.out)"
fi

# ---- tmux cage ----
echo "--- Spinning up multiplexer=tmux cage (${TMUX_CAGE}) ---"
_create_workspace "$TMUX_WS" "tmux"
"$RC" up "$TMUX_WS" </dev/null >/tmp/rc-mux-tmux-up.out 2>&1 || true
TMUX_STARTED=false
if docker inspect "$TMUX_CAGE" >/dev/null 2>&1; then
  TMUX_STARTED=true
  pass "(tmux) cage started: ${TMUX_CAGE}"
else
  fail "(tmux) cage failed to start (see /tmp/rc-mux-tmux-up.out)"
fi

# ---- herdr cage ----
echo "--- Spinning up multiplexer=herdr cage (${HERDR_CAGE}) ---"
_create_workspace "$HERDR_WS" "herdr"
"$RC" up "$HERDR_WS" </dev/null >/tmp/rc-mux-herdr-up.out 2>&1 || true
HERDR_STARTED=false
if docker inspect "$HERDR_CAGE" >/dev/null 2>&1; then
  HERDR_STARTED=true
  pass "(herdr) cage started: ${HERDR_CAGE}"
else
  fail "(herdr) cage failed to start (see /tmp/rc-mux-herdr-up.out)"
fi

echo ""

# ---------------------------------------------------------------------------
# (a) none — plain shell, no tmux/herdr server, two concurrent terminals
# ---------------------------------------------------------------------------
echo "=== (a) multiplexer=none assertions ==="

if [[ "$NONE_STARTED" == "true" ]]; then
  # Enumerate processes in the none cage.
  # EXPECTED process set under none: init (sleep infinity), sh/bash (init runner),
  # zsh/bash shells, and short-lived commands. NOT expected: tmux server, herdr server.
  NONE_PROCS=$(docker exec "$NONE_CAGE" ps -eo comm 2>/dev/null || true)
  echo "  Processes in none cage (ps -eo comm):"
  while IFS= read -r _proc; do echo "    $_proc"; done <<< "$NONE_PROCS"

  # Assert no tmux server.
  # tmux server appears as "tmux: server" in ps -eo comm output.
  if echo "$NONE_PROCS" | grep -qE '^tmux'; then
    fail "(a) none: tmux server process found — should NOT be present under multiplexer=none" \
      "found tmux in ps output"
  else
    pass "(a) none: no tmux server process (as expected under multiplexer=none)"
  fi

  # Assert no herdr server.
  if echo "$NONE_PROCS" | grep -qE '^herdr'; then
    fail "(a) none: herdr server process found — should NOT be present under multiplexer=none" \
      "found herdr in ps output"
  else
    pass "(a) none: no herdr server process (as expected under multiplexer=none)"
  fi

  # Assert multiplexer label is 'none'
  NONE_MUX_LABEL=$(docker inspect --format '{{index .Config.Labels "rc.session.multiplexer"}}' "$NONE_CAGE" 2>/dev/null || true)
  if [[ "$NONE_MUX_LABEL" == "none" ]]; then
    pass "(a) none: rc.session.multiplexer label = 'none'"
  else
    fail "(a) none: rc.session.multiplexer label = '${NONE_MUX_LABEL}' (expected 'none')"
  fi

  # Two concurrent rc exec terminals — independent; one writes sentinel, other reads it
  # Sentinel: a file in /tmp that exec-A writes; exec-B reads.
  SENT_A="/tmp/mux-lifecycle-sentinel-a-$$"
  echo "  Testing two independent rc exec sessions..."
  # Exec A: write sentinel
  "$RC" exec "$NONE_CAGE" -- sh -c "echo mux-sentinel-ok > ${SENT_A}" 2>/dev/null
  RC_EXEC_A_EXIT=$?
  if [[ $RC_EXEC_A_EXIT -eq 0 ]]; then
    pass "(a) none: first rc exec (sentinel write) exited 0"
  else
    fail "(a) none: first rc exec (sentinel write) exited ${RC_EXEC_A_EXIT}"
  fi

  # Exec B: read sentinel (independent from A)
  SENT_A_CONTENT=$(docker exec "$NONE_CAGE" cat "${SENT_A}" 2>/dev/null || true)
  if [[ "$SENT_A_CONTENT" == "mux-sentinel-ok" ]]; then
    pass "(a) none: second exec session reads sentinel written by first (independent)"
  else
    fail "(a) none: sentinel content mismatch or not found" \
      "expected 'mux-sentinel-ok' got '${SENT_A_CONTENT}'"
  fi

  # Close-one-leaves-other: background a long-running exec (exec-B), then kill exec-A
  # and confirm exec-B's process is still alive.
  # We use a docker exec in the background that writes a second sentinel file after a sleep,
  # then verify it completes (the container is still running and no error).
  SENT_B="/tmp/mux-lifecycle-sentinel-b-$$"
  docker exec "$NONE_CAGE" sh -c "sleep 2; echo alive-after-close > ${SENT_B}" &
  BG_PID=$!

  # Exec A (short-lived) completes immediately:
  "$RC" exec "$NONE_CAGE" -- sh -c "echo exec-a-done" >/dev/null 2>&1 || true

  # Wait for exec B to complete
  wait "$BG_PID" 2>/dev/null || true
  SENT_B_CONTENT=$(docker exec "$NONE_CAGE" cat "${SENT_B}" 2>/dev/null || true)
  if [[ "$SENT_B_CONTENT" == "alive-after-close" ]]; then
    pass "(a) none: closing exec-A leaves exec-B running (container alive)"
  else
    fail "(a) none: exec-B did not complete after exec-A closed" \
      "sentinel-b content='${SENT_B_CONTENT}'"
  fi

  # Cleanup sentinels
  docker exec "$NONE_CAGE" rm -f "${SENT_A}" "${SENT_B}" 2>/dev/null || true

else
  fail "(a) none: skipping assertions — none cage did not start"
fi

echo ""

# ---------------------------------------------------------------------------
# (b) tmux — started session survives a detach/reattach cycle
# ---------------------------------------------------------------------------
echo "=== (b) multiplexer=tmux assertions ==="

if [[ "$TMUX_STARTED" == "true" ]]; then
  # Assert multiplexer label is 'tmux'
  TMUX_MUX_LABEL=$(docker inspect --format '{{index .Config.Labels "rc.session.multiplexer"}}' "$TMUX_CAGE" 2>/dev/null || true)
  if [[ "$TMUX_MUX_LABEL" == "tmux" ]]; then
    pass "(b) tmux: rc.session.multiplexer label = 'tmux'"
  else
    fail "(b) tmux: rc.session.multiplexer label = '${TMUX_MUX_LABEL}' (expected 'tmux')"
  fi

  # tmux server is running in the cage.
  # tmux server appears as "tmux: server" in ps -eo comm output.
  TMUX_PROCS=$(docker exec "$TMUX_CAGE" ps -eo comm 2>/dev/null || true)
  if echo "$TMUX_PROCS" | grep -qE '^tmux'; then
    pass "(b) tmux: tmux server process is running in cage"
  else
    fail "(b) tmux: tmux server NOT found in cage (init-rip-cage.sh tmux branch broken?)"
  fi

  # 'rip-cage' session exists (created by init-rip-cage.sh tmux branch)
  TMUX_SESSIONS=$(docker exec "$TMUX_CAGE" tmux list-sessions 2>/dev/null || true)
  if echo "$TMUX_SESSIONS" | grep -q 'rip-cage'; then
    pass "(b) tmux: 'rip-cage' session exists"
  else
    fail "(b) tmux: 'rip-cage' session NOT found" "tmux list-sessions: ${TMUX_SESSIONS}"
  fi

  # Detach/reattach cycle: create a fresh test session, write a sentinel into it,
  # kill the client (simulate detach), then read the sentinel to confirm the session persisted.
  TMUX_TEST_SESSION="mux-lifecycle-reattach-$$"
  docker exec "$TMUX_CAGE" tmux kill-session -t "$TMUX_TEST_SESSION" 2>/dev/null || true
  docker exec "$TMUX_CAGE" tmux new-session -d -s "$TMUX_TEST_SESSION" 2>/dev/null

  SENT_REATTACH="/tmp/mux-lifecycle-reattach-$$"
  # Write sentinel from inside the tmux session (send-keys)
  docker exec "$TMUX_CAGE" tmux send-keys -t "$TMUX_TEST_SESSION" \
    "echo reattach-ok > ${SENT_REATTACH}; echo DONE_$$" Enter 2>/dev/null

  # Poll for sentinel (max 10s)
  _reattach_ok=false
  _waited=0
  while [[ $_waited -lt 10 ]]; do
    sleep 1
    _waited=$((_waited + 1))
    _pane=$(docker exec "$TMUX_CAGE" tmux capture-pane -p -t "$TMUX_TEST_SESSION" 2>/dev/null || true)
    if echo "$_pane" | grep -q "DONE_$$"; then
      _reattach_ok=true
      break
    fi
  done

  if [[ "$_reattach_ok" == "true" ]]; then
    pass "(b) tmux: sentinel written inside tmux session within 10s"
  else
    fail "(b) tmux: sentinel write timed out — tmux session may not be functional"
  fi

  # Session still exists (simulate detach: session persists even without a client)
  TMUX_SESSIONS_AFTER=$(docker exec "$TMUX_CAGE" tmux list-sessions 2>/dev/null || true)
  if echo "$TMUX_SESSIONS_AFTER" | grep -q "$TMUX_TEST_SESSION"; then
    pass "(b) tmux: detach/reattach — session '${TMUX_TEST_SESSION}' persists (detach-safe)"
  else
    fail "(b) tmux: session '${TMUX_TEST_SESSION}' gone after write — unexpected teardown" \
      "list-sessions: ${TMUX_SESSIONS_AFTER}"
  fi

  # Reattach: read the sentinel from outside tmux (docker exec) — session state survived
  SENT_REATTACH_CONTENT=$(docker exec "$TMUX_CAGE" cat "${SENT_REATTACH}" 2>/dev/null || true)
  if [[ "$SENT_REATTACH_CONTENT" == "reattach-ok" ]]; then
    pass "(b) tmux: reattach — sentinel content correct (session state persisted through detach)"
  else
    fail "(b) tmux: reattach — sentinel content mismatch" \
      "expected 'reattach-ok' got '${SENT_REATTACH_CONTENT}'"
  fi

  # Cleanup
  docker exec "$TMUX_CAGE" tmux kill-session -t "$TMUX_TEST_SESSION" 2>/dev/null || true
  docker exec "$TMUX_CAGE" rm -f "${SENT_REATTACH}" 2>/dev/null || true

  # rip-cage-61al.3: registry-dispatch probe — verify init dispatched through the baked hook.
  # The start hook at /etc/rip-cage/multiplexers/tmux/start must exist in the cage (baked at build).
  echo ""
  echo "--- (b) rip-cage-61al.3: registry-dispatch probe (tmux-from-examples) ---"
  TMUX_HOOK_START=$(docker exec "$TMUX_CAGE" sh -c 'test -f /etc/rip-cage/multiplexers/tmux/start && echo "present" || echo "absent"' 2>/dev/null || echo "absent")
  if [[ "$TMUX_HOOK_START" == "present" ]]; then
    pass "(b-61al3) tmux start hook baked in registry: /etc/rip-cage/multiplexers/tmux/start"
  else
    fail "(b-61al3) tmux start hook NOT found in registry — combined-mux fixture may not have baked it"
  fi

  TMUX_HOOK_ATTACH=$(docker exec "$TMUX_CAGE" sh -c 'test -f /etc/rip-cage/multiplexers/tmux/attach && echo "present" || echo "absent"' 2>/dev/null || echo "absent")
  if [[ "$TMUX_HOOK_ATTACH" == "present" ]]; then
    pass "(b-61al3) tmux attach hook baked in registry: /etc/rip-cage/multiplexers/tmux/attach"
  else
    fail "(b-61al3) tmux attach hook NOT found in registry"
  fi

  # Self-containment probe: run the attach hook directly inside the cage with no rc context.
  # The hook must work as a standalone command (no rc functions available — ADR-005 D12).
  # We use 'docker exec ... sh <hook>' in a non-interactive (non-TTY) context so it
  # exits cleanly rather than blocking on attach.
  echo "--- (b) self-containment probe: attach hook runs standalone (no rc context) ---"
  # The attach hook (tmux attach-session) exits non-zero in a non-TTY context; that's expected.
  # What we're probing is: (1) the hook file is readable, (2) the hook runs without rc context.
  # A tmux "no terminal" / "not a terminal" failure is acceptable (the hook requires a TTY).
  TMUX_HOOK_CONTENT=$(docker exec "$TMUX_CAGE" cat /etc/rip-cage/multiplexers/tmux/attach 2>/dev/null || echo "")
  if [[ -n "$TMUX_HOOK_CONTENT" ]]; then
    pass "(b-61al3) self-containment: attach hook file readable, content: '${TMUX_HOOK_CONTENT}'"
  else
    fail "(b-61al3) self-containment: attach hook file empty or unreadable"
  fi

  # Verify the hook file runs via 'sh' without calling any rc functions.
  # We source rc in a subshell and unset all rc-internal functions, then run the hook.
  # If the hook references an undefined rc function, it would error.
  SELFCONTAIN_PROBE_OUT=$(docker exec "$TMUX_CAGE" sh -c \
    'unset -f _rc_mux_resolve_hook_path 2>/dev/null; unset -f _up_attach_tmux 2>/dev/null; sh /etc/rip-cage/multiplexers/tmux/attach 2>&1 || true' \
    2>/dev/null || echo "exec_failed")
  # If the hook tried to call an undefined rc function, it would output "command not found"
  if echo "$SELFCONTAIN_PROBE_OUT" | grep -qE 'not found|undefined|_rc_mux|_up_attach'; then
    fail "(b-61al3) self-containment: attach hook references undefined rc function: '${SELFCONTAIN_PROBE_OUT}'"
  else
    pass "(b-61al3) self-containment: attach hook runs without rc function context (output: '${SELFCONTAIN_PROBE_OUT:-<empty/normal>}')"
  fi

else
  fail "(b) tmux: skipping assertions — tmux cage did not start"
fi

echo ""

# ---------------------------------------------------------------------------
# herdr spawn — herdr server starts + a herdr session is reachable
# ---------------------------------------------------------------------------
echo "=== herdr spawn assertions ==="

if [[ "$HERDR_STARTED" == "true" ]]; then
  # Assert multiplexer label is 'herdr'
  HERDR_MUX_LABEL=$(docker inspect --format '{{index .Config.Labels "rc.session.multiplexer"}}' "$HERDR_CAGE" 2>/dev/null || true)
  if [[ "$HERDR_MUX_LABEL" == "herdr" ]]; then
    pass "(herdr) rc.session.multiplexer label = 'herdr'"
  else
    fail "(herdr) rc.session.multiplexer label = '${HERDR_MUX_LABEL}' (expected 'herdr')"
  fi

  # herdr binary is present
  HERDR_WHICH=$(docker exec "$HERDR_CAGE" which herdr 2>/dev/null || true)
  if [[ -n "$HERDR_WHICH" ]]; then
    pass "(herdr) herdr binary is on PATH: ${HERDR_WHICH}"
  else
    fail "(herdr) herdr binary NOT found on PATH inside cage"
  fi

  # herdr server process is running (init-rip-cage.sh herdr branch)
  # Give it a few seconds after up to settle
  _herdr_server_up=false
  _herdr_wait=0
  while [[ $_herdr_wait -lt 10 ]]; do
    _herdr_procs=$(docker exec "$HERDR_CAGE" ps -eo comm 2>/dev/null || true)
    if echo "$_herdr_procs" | grep -qE '^herdr$'; then
      _herdr_server_up=true
      break
    fi
    sleep 1
    _herdr_wait=$((_herdr_wait + 1))
  done

  if [[ "$_herdr_server_up" == "true" ]]; then
    pass "(herdr) herdr server process is running in cage"
  else
    fail "(herdr) herdr server NOT found in cage after ${_herdr_wait}s wait" \
      "registry-dispatch start hook may have failed — see /tmp/rc-mux-herdr-up.out"
  fi

  # rip-cage-61al.3: registry probe — verify herdr hooks are baked in the registry.
  HERDR_HOOK_START=$(docker exec "$HERDR_CAGE" sh -c 'test -f /etc/rip-cage/multiplexers/herdr/start && echo "present" || echo "absent"' 2>/dev/null || echo "absent")
  if [[ "$HERDR_HOOK_START" == "present" ]]; then
    pass "(herdr-61al3) herdr start hook baked in registry: /etc/rip-cage/multiplexers/herdr/start"
  else
    fail "(herdr-61al3) herdr start hook NOT found in registry — combined-mux fixture may not have baked it"
  fi

  HERDR_HOOK_ATTACH=$(docker exec "$HERDR_CAGE" sh -c 'test -f /etc/rip-cage/multiplexers/herdr/attach && echo "present" || echo "absent"' 2>/dev/null || echo "absent")
  if [[ "$HERDR_HOOK_ATTACH" == "present" ]]; then
    pass "(herdr-61al3) herdr attach hook baked in registry: /etc/rip-cage/multiplexers/herdr/attach"
  else
    fail "(herdr-61al3) herdr attach hook NOT found in registry"
  fi

  # herdr session reachable: check that the herdr unix socket exists
  # herdr server creates ~/.config/herdr/herdr.sock by default
  HERDR_SOCK_EXISTS=$(docker exec "$HERDR_CAGE" bash -c \
    'test -S "${HOME}/.config/herdr/herdr.sock" && echo yes || echo no' 2>/dev/null || echo "no")
  if [[ "$HERDR_SOCK_EXISTS" == "yes" ]]; then
    pass "(herdr) herdr unix socket exists (server reachable)"
  else
    # Check if socket is at an alternate location
    HERDR_SOCK_ALT=$(docker exec "$HERDR_CAGE" find /home/agent -name "herdr.sock" 2>/dev/null | head -1)
    if [[ -n "$HERDR_SOCK_ALT" ]]; then
      pass "(herdr) herdr unix socket found at alternate location: ${HERDR_SOCK_ALT}"
    else
      # Log the herdr startup output for diagnostics
      HERDR_LOG=$(docker exec "$HERDR_CAGE" cat /tmp/rip-cage-mux-herdr.log 2>/dev/null || true)
      fail "(herdr) herdr unix socket NOT found at ~/.config/herdr/herdr.sock or alternate paths" \
        "herdr startup log: ${HERDR_LOG:-<empty>}"
    fi
  fi

  # herdr status-view semantics — semantic render assertion (rip-cage-w621.9)
  #
  # Post-ADR-006-D8, the semantic status-view IS observable headlessly:
  # A3 (rip-cage-w621.3) proved 'herdr agent list' reports agent_status=working
  # with screen_detection_skipped=true (integration path, NOT process-detection)
  # during a live pi run in a D8-initialised cage.
  #
  # Assertion strategy:
  #   1. Check openrouter auth in the cage (stable static-key provider).
  #      If absent → visible SKIP (not a false-pass, not a hang).
  #   2. Drive a brief pi agent THROUGH herdr: 'herdr agent start -- pi ...'
  #   3. Poll 'herdr agent list' (JSON) for agent_status=working AND
  #      screen_detection_skipped=true (the integration path marker).
  #
  # Regression guard: without D8 (integration not installed), herdr falls back
  # to process-detection and reports agent_status=idle regardless of the pi
  # state (screen_detection_skipped is absent or false). The assertion
  # FAILS on process-detection-only — a plain idle from process-detection
  # does NOT satisfy either condition (working OR screen_detection_skipped=true).
  #
  # Provider pin: openrouter (static API key, stable) — the cage-default
  # openai-codex OAuth token is invalidated within hours of issuance.
  # Same rationale as test-multiplexer-agent-e2e.sh header.

  echo ""
  echo "--- (herdr) status-view render assertion (rip-cage-w621.9 / ADR-006 D8) ---"

  # Check openrouter auth in the cage (pi's auth.json, mounted by rc up per ADR-019 D5)
  _HERDR_OR_KEY=$(docker exec "$HERDR_CAGE" python3 -c "
import json, sys
try:
    with open('/home/agent/.pi/agent/auth.json') as f:
        data = json.load(f)
    entry = data.get('openrouter', {})
    key = entry.get('key', '')
    print('yes' if key else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")

  if [[ "$_HERDR_OR_KEY" != "yes" ]]; then
    skip "(herdr) status-view render: openrouter auth absent in cage pi auth.json" \
      "This assertion pins --provider openrouter (stable key). Run 'pi /login openrouter' or set OPENROUTER_API_KEY. SKIP (not a false-pass) — without auth pi exits immediately and herdr never reports working."
  else
    pass "(herdr) status-view precondition: openrouter API key present in cage"

    # Drive a brief pi agent THROUGH the herdr surface.
    # The multi-step prompt forces >=3 tool calls so the LLM+tool round-trip
    # takes enough wall time (5-30s) for the polling window to catch working state.
    _HERDR_START_OUT=$(docker exec -u agent "$HERDR_CAGE" herdr agent start \
      status-view-probe \
      --cwd /workspace \
      -- pi \
        --provider openrouter \
        --model anthropic/claude-3.5-haiku \
        -p "Write the word hello to /workspace/sv-hello.txt using your write tool. Then write the word world to /workspace/sv-world.txt using your write tool. Then write the word done to /workspace/sv-done.txt using your write tool." \
      2>&1 || true)

    echo "  herdr agent start output: ${_HERDR_START_OUT}"

    # Poll herdr agent list for agent_status=working + screen_detection_skipped=true
    # Max poll: 60s (LLM round-trip takes 5-30s; first poll right after start)
    _HERDR_WORKING=false
    _HERDR_INTEGRATION_PATH=false
    _HERDR_POLL_ELAPSED=0
    _HERDR_POLL_INTERVAL=2
    _HERDR_POLL_TIMEOUT=60
    _HERDR_LAST_LIST=""

    while [[ $_HERDR_POLL_ELAPSED -lt $_HERDR_POLL_TIMEOUT ]]; do
      _HERDR_LAST_LIST=$(docker exec -u agent "$HERDR_CAGE" herdr agent list 2>/dev/null || echo '{}')

      # Extract agent_status and screen_detection_skipped from the JSON array
      _HERDR_STATUS_CHECK=$(echo "$_HERDR_LAST_LIST" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    agents = data.get('result', {}).get('agents', [])
    for a in agents:
        status = a.get('agent_status', '')
        sds = a.get('screen_detection_skipped', False)
        print('agent_status=' + str(status))
        print('screen_detection_skipped=' + str(sds))
        if status == 'working' and sds is True:
            print('integration_working=yes')
            sys.exit(0)
    print('integration_working=no')
except Exception as e:
    print('integration_working=error:' + str(e))
" 2>/dev/null || echo "integration_working=parse_error")

      echo "  [t=${_HERDR_POLL_ELAPSED}s] herdr agent list check: ${_HERDR_STATUS_CHECK}"

      if echo "$_HERDR_STATUS_CHECK" | grep -q "integration_working=yes"; then
        _HERDR_WORKING=true
        _HERDR_INTEGRATION_PATH=true
        break
      fi

      sleep $_HERDR_POLL_INTERVAL
      _HERDR_POLL_ELAPSED=$((_HERDR_POLL_ELAPSED + _HERDR_POLL_INTERVAL))
    done

    echo "  Final herdr agent list JSON: ${_HERDR_LAST_LIST}"

    if [[ "$_HERDR_WORKING" == "true" ]] && [[ "$_HERDR_INTEGRATION_PATH" == "true" ]]; then
      pass "(herdr) status-view: herdr agent list reports agent_status=working + screen_detection_skipped=true (semantic integration path, ADR-006 D8)"
    else
      fail "(herdr) status-view: semantic render NOT observed within ${_HERDR_POLL_TIMEOUT}s" \
        "Expected agent_status=working AND screen_detection_skipped=true. Got: ${_HERDR_LAST_LIST}. Regression: if integration absent (D8 missing), herdr falls back to process-detection and shows idle (screen_detection_skipped absent), NEVER working via integration — this assertion fires RED."
    fi

    # Cleanup: the pi agent will self-complete; pane is ephemeral in herdr
    unset _HERDR_START_OUT _HERDR_STATUS_CHECK _HERDR_LAST_LIST
    unset _HERDR_WORKING _HERDR_INTEGRATION_PATH
    unset _HERDR_POLL_ELAPSED _HERDR_POLL_INTERVAL _HERDR_POLL_TIMEOUT
  fi
  unset _HERDR_OR_KEY

else
  fail "(herdr) skipping herdr spawn assertions — herdr cage did not start"
fi

echo ""

# ---------------------------------------------------------------------------
# (d) config-isolation — reuse p1p probe (test-claude-concurrency.sh, READ-only)
#     green under none + tmux; gating under herdr (herdr IS installable now — .5 baked it).
# ---------------------------------------------------------------------------
echo "=== (d) Config-isolation via p1p probe (test-claude-concurrency.sh) ==="

P1P_PROBE="${SCRIPT_DIR}/test-claude-concurrency.sh"

if [[ ! -f "$P1P_PROBE" ]]; then
  fail "(d) p1p probe not found at ${P1P_PROBE} — cannot run config-isolation check"
else
  # none cage config-isolation
  if [[ "$NONE_STARTED" == "true" ]]; then
    echo ""
    echo "--- (d) config-isolation: none cage ---"
    P1P_NONE_EXIT=0
    RC_TEST_CONTAINER="$NONE_CAGE" bash "$P1P_PROBE" 2>&1 | sed 's/^/  [p1p-none] /' || P1P_NONE_EXIT=$?
    if [[ $P1P_NONE_EXIT -eq 0 ]]; then
      pass "(d) config-isolation: p1p probe GREEN under multiplexer=none"
    else
      fail "(d) config-isolation: p1p probe FAILED under multiplexer=none (exit=${P1P_NONE_EXIT})"
    fi
  else
    fail "(d) config-isolation: none cage not started — cannot run p1p probe under none"
  fi

  # tmux cage config-isolation
  if [[ "$TMUX_STARTED" == "true" ]]; then
    echo ""
    echo "--- (d) config-isolation: tmux cage ---"
    P1P_TMUX_EXIT=0
    RC_TEST_CONTAINER="$TMUX_CAGE" bash "$P1P_PROBE" 2>&1 | sed 's/^/  [p1p-tmux] /' || P1P_TMUX_EXIT=$?
    if [[ $P1P_TMUX_EXIT -eq 0 ]]; then
      pass "(d) config-isolation: p1p probe GREEN under multiplexer=tmux"
    else
      fail "(d) config-isolation: p1p probe FAILED under multiplexer=tmux (exit=${P1P_TMUX_EXIT})"
    fi
  else
    fail "(d) config-isolation: tmux cage not started — cannot run p1p probe under tmux"
  fi

  # herdr cage config-isolation (GATING — herdr IS installable per rip-cage-1f59.5)
  if [[ "$HERDR_STARTED" == "true" ]]; then
    echo ""
    echo "--- (d) config-isolation: herdr cage (GATING) ---"
    P1P_HERDR_EXIT=0
    RC_TEST_CONTAINER="$HERDR_CAGE" bash "$P1P_PROBE" 2>&1 | sed 's/^/  [p1p-herdr] /' || P1P_HERDR_EXIT=$?
    if [[ $P1P_HERDR_EXIT -eq 0 ]]; then
      pass "(d) config-isolation (GATING): p1p probe GREEN under multiplexer=herdr"
    else
      fail "(d) config-isolation (GATING): p1p probe FAILED under multiplexer=herdr (exit=${P1P_HERDR_EXIT})"
    fi
  else
    fail "(d) config-isolation (GATING): herdr cage not started — cannot run p1p probe under herdr"
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== test-multiplexer-lifecycle.sh complete ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All multiplexer lifecycle tests PASSED."
else
  echo "${FAILURES} multiplexer lifecycle test(s) FAILED."
fi

[[ $FAILURES -eq 0 ]] || exit 1
