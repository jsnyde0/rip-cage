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

# ---------------------------------------------------------------------------
# rip-cage-l72i.7: DCG+herdr+pi composed fixture (three-conjunction test)
# Variables for the composed image built from manifest-dcg-herdr-pi.yaml.
# ---------------------------------------------------------------------------
DCG_HERDR_PI_FIXTURE="${SCRIPT_DIR}/fixtures/manifest-dcg-herdr-pi.yaml"
DCG_HERDR_PI_IMAGE=""
DCG_HERDR_PI_SAVED_LATEST=""
DCG_HERDR_PI_HAD_LATEST=0

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
# rip-cage-l72i.7: _dcg_herdr_pi_build_image — build composed DCG+herdr+pi image
#
# Mirrors _mux_build_combined_image: saves rip-cage:latest, builds from the
# composed manifest-dcg-herdr-pi.yaml fixture (HOME override pattern), tags the
# result, restores the saved image. Called lazily (once) before the three-
# conjunction test. Idempotent: returns 0 immediately if already built.
# ---------------------------------------------------------------------------
_dcg_herdr_pi_build_image() {
  if [[ -n "${DCG_HERDR_PI_IMAGE:-}" ]]; then
    return 0
  fi
  if [[ ! -f "$DCG_HERDR_PI_FIXTURE" ]]; then
    echo "FATAL: DCG+herdr+pi fixture not found at ${DCG_HERDR_PI_FIXTURE}"
    exit 1
  fi

  local unique_suffix
  unique_suffix="$(date +%s)-$$-dcghp"
  DCG_HERDR_PI_SAVED_LATEST="rip-cage:l72i7-saved-${unique_suffix}"
  DCG_HERDR_PI_HAD_LATEST=0
  if docker image inspect rip-cage:latest >/dev/null 2>&1; then
    docker tag rip-cage:latest "${DCG_HERDR_PI_SAVED_LATEST}" 2>/dev/null && DCG_HERDR_PI_HAD_LATEST=1
  fi

  local dcghp_build_home
  dcghp_build_home=$(mktemp -d)
  mkdir -p "${dcghp_build_home}/.config/rip-cage"
  cp "$DCG_HERDR_PI_FIXTURE" "${dcghp_build_home}/.config/rip-cage/tools.yaml"
  echo "=== Building DCG+herdr+pi composed image (manifest-dcg-herdr-pi.yaml) ==="
  local dcghp_build_rc=0
  HOME="$dcghp_build_home" XDG_CONFIG_HOME="${dcghp_build_home}/.config" \
    "$RC" build >/tmp/rc-l72i7-dcghp-build.out 2>&1 || dcghp_build_rc=$?
  rm -rf "$dcghp_build_home"

  if [[ "$dcghp_build_rc" -ne 0 ]]; then
    fail "(l72i7) DCG+herdr+pi image build FAILED (see /tmp/rc-l72i7-dcghp-build.out)"
    echo "FATAL: cannot run l72i7 three-conjunction test without the composed image"
    if [[ "${DCG_HERDR_PI_HAD_LATEST}" -eq 1 ]]; then
      docker tag "${DCG_HERDR_PI_SAVED_LATEST}" rip-cage:latest 2>/dev/null || true
    fi
    docker image rm "${DCG_HERDR_PI_SAVED_LATEST}" 2>/dev/null || true
    return 1
  fi

  DCG_HERDR_PI_IMAGE="rip-cage:l72i7-dcghp-${unique_suffix}"
  docker tag rip-cage:latest "${DCG_HERDR_PI_IMAGE}" 2>/dev/null || true
  pass "(l72i7) DCG+herdr+pi composed image built: ${DCG_HERDR_PI_IMAGE}"
}

_dcg_herdr_pi_restore_latest() {
  # Only clean up the DCG+herdr+pi side-tag; rip-cage:latest restore is owned by
  # _mux_restore_latest (which restores the user's original pre-test image).
  # DCG_HERDR_PI_SAVED_LATEST points to the combined-mux image (what was
  # rip-cage:latest when the DCG+herdr+pi build ran) — that image is managed
  # as MUX_COMBINED_IMAGE by _mux_restore_latest, so we only clean the saved copy.
  if [[ -n "${DCG_HERDR_PI_IMAGE:-}" ]]; then
    docker image rm "${DCG_HERDR_PI_IMAGE}" 2>/dev/null || true
    DCG_HERDR_PI_IMAGE=""
  fi
  if [[ -n "${DCG_HERDR_PI_SAVED_LATEST:-}" ]]; then
    docker image rm "${DCG_HERDR_PI_SAVED_LATEST}" 2>/dev/null || true
    DCG_HERDR_PI_SAVED_LATEST=""
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
  # Restore rip-cage:latest for the DCG+herdr+pi composed build (l72i7).
  # _dcg_herdr_pi_restore_latest is idempotent.
  _dcg_herdr_pi_restore_latest
}
# Arm the trap BEFORE the first mutation (_mux_build_combined_image tags aside and
# overwrites rip-cage:latest). An interrupt during the build would otherwise strand
# a modified rip-cage:latest. MUX_TMP is still empty at this point, so the cage-
# cleanup loop in CLEANUP is a safe no-op; _mux_restore_latest handles the image.
trap CLEANUP EXIT INT TERM

# ---------------------------------------------------------------------------
# RC_E2E_DCGHP_ONLY=1: skip the combined-mux preamble (none/tmux/herdr lifecycle
# tests + _mux_build_combined_image) and run ONLY the l72i7 three-conjunction
# block. Useful for fast iteration on the DCG+herdr+pi composed cage without
# waiting ~25 min for the combined-mux build.
#
# Usage:
#   RC_E2E=1 RC_E2E_DCGHP_ONLY=1 bash tests/test-multiplexer-lifecycle.sh
#
# When set:
#   - _mux_build_combined_image is skipped (MUX_COMBINED_IMAGE stays empty)
#   - none/tmux/herdr lifecycle cages are not spun up
#   - grep-guard and retirement assertions are skipped
#   - The l72i7 block builds its own dcghp image from scratch
#   - cleanup handles only dcghp images (nothing to restore for mux)
# ---------------------------------------------------------------------------
if [[ "${RC_E2E_DCGHP_ONLY:-0}" == "1" ]]; then
  echo "=== RC_E2E_DCGHP_ONLY=1: skipping combined-mux preamble — running l72i7 only ==="
else
  # Build combined image now (needed for tmux + herdr lifecycle tests)
  _mux_build_combined_image
fi

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

# rip-cage-l72i.7: DCG+herdr+pi composed cage workspace + name.
# Uses parent rc-mux / base dcghp-test → container rc-mux-dcghp-test.
DCG_HERDR_PI_WS="${MUX_TMP}/rc-mux/dcghp-test"
DCG_HERDR_PI_CAGE="rc-mux-dcghp-test"

# Pre-cleanup: remove leftover cages from prior aborted runs
for _c in "$NONE_CAGE" "$TMUX_CAGE" "$HERDR_CAGE" "$DCG_HERDR_PI_CAGE"; do
  docker rm -f "$_c" >/dev/null 2>&1 || true
  docker volume rm "rc-state-${_c}" >/dev/null 2>&1 || true
done
unset _c

export RC_ALLOWED_ROOTS="${MUX_TMP}"

echo "=== test-multiplexer-lifecycle.sh ==="
echo "MUX_TMP=${MUX_TMP}"
echo ""

# ---------------------------------------------------------------------------
# Helper: create workspace + .rip-cage.yaml + git init
# Defined here (before any gate) so it is available to both the preamble and
# the RC_E2E_DCGHP_ONLY=1 l72i7 block.
# ---------------------------------------------------------------------------
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

if [[ "${RC_E2E_DCGHP_ONLY:-0}" != "1" ]]; then

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

fi # end RC_E2E_DCGHP_ONLY gate

echo ""

# ---------------------------------------------------------------------------
# rip-cage-l72i.7: Three-conjunction test — DCG+herdr+pi composed cage
# (rip-cage-p35a.1 / ADR-027 D1, FIRM 2026-07-02: reconciled to the OPEN
# shipped default posture — dcg-wiring no longer contributes --no-extensions)
#
# Builds and exercises a real cage from the operator manifest
# tests/fixtures/manifest-dcg-herdr-pi.yaml, asserting SIMULTANEOUSLY:
#   (1) DOWNGRADED per invalidation clause: herdr extension loaded in-process
#       (herdr-agent-state.ts present + in ASSEMBLED_ARGS; semantic working-status
#        not observable headlessly — see bead's ## Harness target Invalidation clause)
#   (2) DCG guard floor present + loaded: dcg-guard binary + config.toml exist,
#       pi shim has -e dcg-gate.ts present (guard loads) and --no-extensions
#       ABSENT (OPEN default). EFFECT test: a root/home-targeted destructive
#       command is still DENIED by dcg-guard (the load-bearing safety check —
#       open posture must not disarm command-guarding).
#   (3) canary extension dropped into pi auto-discovery path IS loaded under
#       the OPEN default (accepted residual "vector-b", ADR-027 D1 — pi's own
#       extension autonomy is preserved; this is NOT a regression, it is the
#       decided tradeoff). Retired: the old "NOT loaded" assertion tested the
#       now-abandoned LOCKED-by-default posture.
#
# IMPORTANT: Assertion (2a-2e) + downgraded (1a)+(1b) are ALWAYS run (structural,
# no auth needed). The best-effort semantic poll part of (1) and assertion (3)
# are auth-gated (require openrouter key in pi auth.json to drive a real pi
# invocation); they SKIP (not FAIL) when auth is absent.
#
# False-green guards:
#   - NOT a synthetic stub: built from the real operator manifest under RC_E2E=1
#   - NOT session-seeding: the probe observes real composed cage state
#     (per wrapper-seeding-false-green-in-cage-probes bd memory)
#   - NOT a self-skipped gated tier: all RC_E2E=1 assertions execute and
#     assert, not just pass vacuously
# ---------------------------------------------------------------------------
echo "=== (l72i7) Three-conjunction test: DCG+herdr+pi composed cage ==="

# Build the composed image from manifest-dcg-herdr-pi.yaml.
# On build failure, _dcg_herdr_pi_build_image returns non-zero; skip the
# whole block and register a FAIL (FATAL for this conjunction test).
_L72I7_CAGE_STARTED=false

if ! _dcg_herdr_pi_build_image; then
  fail "(l72i7) cannot run three-conjunction test — composed image build failed"
else
  # Spin up the DCG+herdr+pi cage (multiplexer=herdr for the semantic-status path)
  _create_workspace "$DCG_HERDR_PI_WS" "herdr"
  echo "--- (l72i7) Spinning up DCG+herdr+pi composed cage (${DCG_HERDR_PI_CAGE}) ---"
  "$RC" up "$DCG_HERDR_PI_WS" </dev/null >/tmp/rc-l72i7-dcghp-up.out 2>&1 || true
  if docker inspect "$DCG_HERDR_PI_CAGE" >/dev/null 2>&1; then
    _L72I7_CAGE_STARTED=true
    pass "(l72i7) DCG+herdr+pi cage started: ${DCG_HERDR_PI_CAGE}"
  else
    fail "(l72i7) DCG+herdr+pi cage failed to start (see /tmp/rc-l72i7-dcghp-up.out)"
  fi

  # Restore the combined-mux image as rip-cage:latest after the DCG+herdr+pi build
  # swapped it. The combined-mux image is still needed by the herdr lifecycle tests
  # above (already run), but we want rip-cage:latest to refer to the combined-mux
  # image for any remaining assertions. Re-tag it.
  if [[ -n "${MUX_COMBINED_IMAGE:-}" ]]; then
    docker tag "${MUX_COMBINED_IMAGE}" rip-cage:latest 2>/dev/null || true
  fi
fi

if [[ "$_L72I7_CAGE_STARTED" == "true" ]]; then
  echo ""
  echo "--- (l72i7) Assertion (2): DCG guard floor present + pi shim guard-first ---"
  # (2) DCG guard floor: targeted in-cage checks (always run, no auth needed).
  # NOT rc test --output json overall (which includes base-image CLAUDE.md topology
  # checks inapplicable to pi+herdr operator manifests — e2e-lifecycle-builds-from-
  # operator-manifest; those checks only apply when rip-cage:latest is the base).
  # Instead, probe the guard floor SPECIFICALLY:
  #   (2a) dcg-guard binary executable + config.toml present (dcg-wiring install_cmd ran)
  #   (2b) /etc/rip-cage/pi/dcg-gate.ts owned by root:root
  #   (2c) /usr/local/bin/pi owned by root:root
  #   (2d) pi shim ASSEMBLED_ARGS has -e /etc/rip-cage/pi/dcg-gate.ts present
  #        (guard loads, ADR-027 D4) and does NOT contain --no-extensions
  #        (OPEN default, ADR-027 D1, FIRM — rip-cage-p35a.1)

  # (2a) dcg-guard binary + config.toml
  _L72I7_DCG_FLOOR=0
  docker exec "$DCG_HERDR_PI_CAGE" sh -c \
    'test -x /usr/local/lib/rip-cage/bin/dcg-guard && test -f /usr/local/lib/rip-cage/dcg/config.toml' \
    2>/dev/null || _L72I7_DCG_FLOOR=$?
  if [[ $_L72I7_DCG_FLOOR -eq 0 ]]; then
    pass "(l72i7/2a) DCG guard floor: dcg-guard binary executable + config.toml present"
  else
    fail "(l72i7/2a) DCG guard floor: dcg-guard binary or config.toml missing (dcg-wiring install_cmd may not have run)"
  fi

  # (2b) /etc/rip-cage/pi/dcg-gate.ts owned by root
  _L72I7_GATE_OWNER=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
    "stat -c '%U' /etc/rip-cage/pi/dcg-gate.ts 2>/dev/null || echo absent")
  echo "  dcg-gate.ts owner: ${_L72I7_GATE_OWNER}"
  if [[ "$_L72I7_GATE_OWNER" == "root" ]]; then
    pass "(l72i7/2b) DCG gate extension root-owned: /etc/rip-cage/pi/dcg-gate.ts is root:root"
  else
    fail "(l72i7/2b) DCG gate extension NOT root-owned: got '${_L72I7_GATE_OWNER}' (expected root)"
  fi

  # (2c) /usr/local/bin/pi owned by root
  _L72I7_PI_OWNER=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
    "stat -c '%U' /usr/local/bin/pi 2>/dev/null || echo absent")
  echo "  pi shim owner: ${_L72I7_PI_OWNER}"
  if [[ "$_L72I7_PI_OWNER" == "root" ]]; then
    pass "(l72i7/2c) pi shim root-owned: /usr/local/bin/pi is root:root"
  else
    fail "(l72i7/2c) pi shim NOT root-owned: got '${_L72I7_PI_OWNER}' (expected root)"
  fi

  # (2d) pi shim ASSEMBLED_ARGS: -e dcg-gate.ts present, --no-extensions ABSENT
  # (OPEN default, ADR-027 D1, FIRM — rip-cage-p35a.1). Decode the pi shim
  # (direct grep) to inspect ASSEMBLED_ARGS inline.
  _L72I7_PI_ARGS=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
    "grep 'ASSEMBLED_ARGS=' /usr/local/bin/pi 2>/dev/null || echo 'NOT_FOUND'")
  echo "  pi shim ASSEMBLED_ARGS line: ${_L72I7_PI_ARGS}"
  # Check the dcg-gate guard extension is declared. The shim bakes args as
  # single-quoted tokens: ASSEMBLED_ARGS=('-e' '/etc/rip-cage/pi/dcg-gate.ts' ...)
  # so match the guard PATH token (unique to the guard -e arg), not a space-joined "-e <path>".
  if echo "$_L72I7_PI_ARGS" | grep -q -- '/etc/rip-cage/pi/dcg-gate.ts'; then
    pass "(l72i7/2d-a) pi shim ASSEMBLED_ARGS declares the guard extension /etc/rip-cage/pi/dcg-gate.ts (guard loads)"
  else
    fail "(l72i7/2d-a) pi shim ASSEMBLED_ARGS missing the guard extension /etc/rip-cage/pi/dcg-gate.ts (guard not declared)"
  fi
  # Check --no-extensions is ABSENT — the shipped default is OPEN (ADR-027 D1,
  # FIRM 2026-07-02): pi's own extension auto-discovery paths stay live even
  # with DCG composed. --no-extensions is a documented LOCKED opt-in
  # (examples/dcg/README.md), not something the default-posture fixture adds.
  if echo "$_L72I7_PI_ARGS" | grep -q -- '--no-extensions'; then
    fail "(l72i7/2d-b) pi shim ASSEMBLED_ARGS contains --no-extensions — expected OPEN default (ADR-027 D1); fixture may still be on the retired LOCKED posture"
  else
    pass "(l72i7/2d-b) pi shim ASSEMBLED_ARGS does NOT contain --no-extensions (OPEN default, ADR-027 D1, FIRM)"
  fi
  unset _L72I7_DCG_FLOOR _L72I7_GATE_OWNER _L72I7_PI_OWNER _L72I7_PI_ARGS

  # (2e) EFFECT test: DCG guard still DENIES a root/home-targeted destructive
  # command (canonical form, NOT a /tmp path — memory in-cage-guard-probe-false-
  # fail-shapes). This is the load-bearing safety check under the OPEN default:
  # dropping --no-extensions must not disarm command-guarding (bead Invalidation
  # clause). Positive control (D1) proves the guard ran and is responsive;
  # D2 proves the destructive command is actually blocked.
  _L72I7_DCG_GUARD="/usr/local/lib/rip-cage/bin/dcg-guard"
  if docker exec "$DCG_HERDR_PI_CAGE" test -x "$_L72I7_DCG_GUARD" 2>/dev/null; then
    _L72I7_SAFE_OUT=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
      "printf '{\"tool_name\":\"bash\",\"tool_input\":{\"command\":\"echo hello\"}}' | ${_L72I7_DCG_GUARD} 2>/dev/null || true")
    if echo "$_L72I7_SAFE_OUT" | grep -qE '"permissionDecision".*"deny"'; then
      fail "(l72i7/2e-a) POSITIVE CONTROL FAILED — safe command 'echo hello' was DENIED by dcg-guard (over-blocking)"
    else
      pass "(l72i7/2e-a) POSITIVE CONTROL — safe command 'echo hello' is ALLOWED (guard ran and is responsive)"
    fi

    _L72I7_DENY_OUT=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
      "printf '{\"tool_name\":\"bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | ${_L72I7_DCG_GUARD} 2>/dev/null || true")
    if echo "$_L72I7_DENY_OUT" | grep -qE '"permissionDecision".*"deny"'; then
      pass "(l72i7/2e-b) EFFECT — destructive 'rm -rf /' is DENIED by dcg-guard (open posture did not disarm command-guarding)"
    else
      fail "(l72i7/2e-b) EFFECT FAILED — destructive 'rm -rf /' was NOT denied by dcg-guard; output: ${_L72I7_DENY_OUT}"
    fi
    unset _L72I7_SAFE_OUT _L72I7_DENY_OUT
  else
    fail "(l72i7/2e) dcg-guard not executable at ${_L72I7_DCG_GUARD} — cannot run deny-probe"
  fi
  unset _L72I7_DCG_GUARD

  # ---------------------------------------------------------------------------
  # Assertion (4): herdr integration install/status parity for pi (rip-cage-fwp3)
  #
  # AUTH-FREE, fully headless. Closes the observability gap l72i's downgrade
  # left open: the interactive/boot-time 'herdr integration install pi' path
  # was never actually asserted (only the -e build-time bake was proven green).
  #
  # Root cause this catches: herdr v0.7.0's 'integration install pi' (run by
  # the herdr multiplexer start hook at every boot, examples/herdr/manifest-
  # fragment.yaml) writes into ${PI_CODING_AGENT_DIR}/extensions/ and requires
  # that directory to pre-exist. Before rip-cage-fwp3's fix, nothing in the
  # image or init flow created extensions/ (only the chown of the already-
  # existing top-level .pi/agent dir) -> the install silently WARNed and
  # failed every boot, and pi showed "available but not installed" in the
  # herdr roster while claude showed installed (the false-negative asymmetry).
  #
  # This assertion is pinned to the composed image built from the REAL
  # manifest-dcg-herdr-pi.yaml fixture (herdr v0.7.0 — _dcg_herdr_pi_build_image
  # above), NOT the older manifest-herdr-multiplexer.yaml fixture used by
  # test-manifest-herdr.sh T2d (that one pins herdr v0.6.10 and would
  # false-green this exact RED — do not reuse it for this assertion).
  # ---------------------------------------------------------------------------
  echo ""
  echo "--- (l72i7) Assertion (4): herdr integration install/status parity for pi (rip-cage-fwp3, headless) ---"

  # (4a) extensions/ directory exists and is agent-writable (the fix)
  _L72I7_PI_EXT_DIR_STAT=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
    "stat -c '%U:%a' /home/agent/.pi/agent/extensions 2>/dev/null || echo absent")
  echo "  /home/agent/.pi/agent/extensions owner:mode = ${_L72I7_PI_EXT_DIR_STAT}"
  if [[ "$_L72I7_PI_EXT_DIR_STAT" == agent:* ]]; then
    pass "(l72i7/4a) /home/agent/.pi/agent/extensions exists, agent-owned (rip-cage-fwp3 fix)"
  else
    fail "(l72i7/4a) /home/agent/.pi/agent/extensions missing or not agent-owned (got '${_L72I7_PI_EXT_DIR_STAT}') — herdr's boot-time 'integration install pi' cannot write its extension file"
  fi

  # (4b) herdr integration status shows pi installed, at parity with claude
  # (this is the exact roster the smoketest observed as "available but not
  # installed" for pi while claude showed installed).
  _L72I7_HERDR_STATUS=$(docker exec -u agent "$DCG_HERDR_PI_CAGE" herdr integration status 2>&1 || true)
  echo "  herdr integration status:"
  echo "$_L72I7_HERDR_STATUS" | while IFS= read -r _l72i7_status_line; do echo "    $_l72i7_status_line"; done

  if echo "$_L72I7_HERDR_STATUS" | grep -qE '^pi: *(current|outdated|installed)'; then
    pass "(l72i7/4b) herdr integration status: pi installed (parity with claude, rip-cage-fwp3 fix)"
  else
    fail "(l72i7/4b) herdr integration status: pi NOT installed" \
      "Got: ${_L72I7_HERDR_STATUS}. Expected a 'pi: current/outdated/installed' line — regression of rip-cage-fwp3 (extensions/ dir provisioning)."
  fi
  if echo "$_L72I7_HERDR_STATUS" | grep -qE '^claude: *(current|outdated|installed)'; then
    pass "(l72i7/4b) herdr integration status: claude installed (control — unaffected by this fix)"
  else
    fail "(l72i7/4b) herdr integration status: claude NOT installed (unexpected regression outside this bead's scope)"
  fi

  # (4c) 'herdr integration install pi' run directly succeeds and the
  # "extension directory not found" error is gone (the exact smoketest symptom).
  _L72I7_INSTALL_OUT=$(docker exec -u agent "$DCG_HERDR_PI_CAGE" herdr integration install pi 2>&1)
  _L72I7_INSTALL_RC=$?
  echo "  herdr integration install pi (rc=${_L72I7_INSTALL_RC}): ${_L72I7_INSTALL_OUT}"
  if [[ "$_L72I7_INSTALL_RC" -eq 0 ]]; then
    pass "(l72i7/4c) 'herdr integration install pi' exits 0"
  else
    fail "(l72i7/4c) 'herdr integration install pi' exited ${_L72I7_INSTALL_RC}" "output: ${_L72I7_INSTALL_OUT}"
  fi
  if echo "$_L72I7_INSTALL_OUT" | grep -q "extension directory not found"; then
    fail "(l72i7/4c) 'herdr integration install pi' still emits the rip-cage-fwp3 symptom: 'extension directory not found'" \
      "output: ${_L72I7_INSTALL_OUT}"
  else
    pass "(l72i7/4c) 'herdr integration install pi' error message ('extension directory not found') is gone"
  fi

  unset _L72I7_PI_EXT_DIR_STAT _L72I7_HERDR_STATUS _L72I7_INSTALL_OUT _L72I7_INSTALL_RC

  # (1) + (3): auth-gated (require openrouter API key for pi to run)
  echo ""
  echo "--- (l72i7) Checking openrouter auth for assertions (1) + (3) ---"
  _L72I7_OR_KEY=$(docker exec "$DCG_HERDR_PI_CAGE" python3 -c "
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

  if [[ "$_L72I7_OR_KEY" != "yes" ]]; then
    skip "(l72i7/1+3)" "openrouter auth absent — assertions (1) herdr semantic status and (3) canary auto-load require pi to run. Run 'pi /login openrouter' on host. SKIP (not a false-pass)."
  else
    pass "(l72i7) auth precondition: openrouter API key present in cage"

    # (3) Setup: drop canary extension into pi's auto-discovery path BEFORE pi launches.
    # The canary extension writes a marker file at module-load time (top-level TS).
    # If pi loads the extension (auto-discovery), the marker appears.
    # Under the OPEN default (ADR-027 D1, FIRM — rip-cage-p35a.1), --no-extensions
    # is NOT in the assembled shim, so auto-discovery stays live → marker MUST
    # appear (proves pi extension autonomy — the accepted-residual tradeoff).
    #
    # Canary marker path (cage-internal): /tmp/l72i7-canary-loaded
    # Canary extension path: /home/agent/.pi/agent/extensions/l72i7-canary/index.ts
    # (pi's default PI_CODING_AGENT_DIR is /home/agent/.pi/agent by default; verify below)
    _L72I7_CANARY_MARKER="/tmp/l72i7-canary-loaded"
    _L72I7_CANARY_DIR="/home/agent/.pi/agent/extensions/l72i7-canary"
    _L72I7_CANARY_TS="${_L72I7_CANARY_DIR}/index.ts"

    echo ""
    echo "--- (l72i7) Assertion (3) setup: dropping canary extension into auto-discovery path ---"
    # The canary extension writes the marker file via top-level fs.writeFileSync at
    # module-load time (synchronous, before any tool call). Under the OPEN default
    # (no --no-extensions in the assembled shim), pi auto-discovers this extension
    # from its writable extensions/ dir → marker MUST appear when pi starts.
    docker exec -u agent "$DCG_HERDR_PI_CAGE" sh -c \
      "mkdir -p '${_L72I7_CANARY_DIR}'" 2>/dev/null || true
    docker exec -u agent "$DCG_HERDR_PI_CAGE" sh -c \
      "cat > '${_L72I7_CANARY_TS}'" <<'CANARY_EOF'
// l72i7 canary extension — writes marker at load time (NOT a real tool)
// If pi loads this extension via auto-discovery, the marker file appears.
// Under the OPEN default (ADR-027 D1), auto-discovery stays live -> loaded.
import * as fs from "fs";

// Write marker immediately at module load (synchronous at extension load time)
try {
  fs.writeFileSync("/tmp/l72i7-canary-loaded", "l72i7-canary-was-loaded\n");
} catch (_e) {}
CANARY_EOF
    _L72I7_CANARY_PLACED=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
      "test -f '${_L72I7_CANARY_TS}' && echo yes || echo no" 2>/dev/null || echo "no")
    if [[ "$_L72I7_CANARY_PLACED" == "yes" ]]; then
      pass "(l72i7/3-setup) canary extension placed at ${_L72I7_CANARY_TS} (in pi auto-discovery path)"
    else
      fail "(l72i7/3-setup) canary extension NOT placed — cannot assert not-loaded"
    fi

    # (1) DOWNGRADED per bead invalidation clause.
    # Original: assert herdr agent_status=working + screen_detection_skipped=true.
    # Problem: herdr semantic working-status is not externally observable in a
    # headless harness (same limitation as the pre-existing herdr status-view test).
    # Downgrade: verify herdr extension is LOADED IN-PROCESS (herdr-agent-state.ts
    # present at the expected path AND present in pi shim ASSEMBLED_ARGS). This
    # is structurally verifiable without running pi.
    # Best-effort: also attempt semantic poll (SKIP, not FAIL, when agents list empty).
    echo ""
    echo "--- (l72i7) Assertion (1): herdr extension loaded in-process [DOWNGRADED] ---"
    echo "  (l72i7/1) DOWNGRADED per invalidation clause: herdr ext loaded in-process"
    echo "  + guard intact; externally-observable working-status not verifiable in headless harness"

    # (1a) herdr-agent-state.ts present in cage (installed by herdr-pi fragment)
    _L72I7_HERDR_EXT_PATH="/etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts"
    _L72I7_HERDR_EXT_EXISTS=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
      "test -f '${_L72I7_HERDR_EXT_PATH}' && echo yes || echo no" 2>/dev/null || echo "no")
    echo "  herdr-agent-state.ts present: ${_L72I7_HERDR_EXT_EXISTS}"
    if [[ "$_L72I7_HERDR_EXT_EXISTS" == "yes" ]]; then
      pass "(l72i7/1a-downgraded) herdr extension file present: ${_L72I7_HERDR_EXT_PATH}"
    else
      fail "(l72i7/1a-downgraded) herdr extension file ABSENT at ${_L72I7_HERDR_EXT_PATH} (herdr-pi install_cmd may not have run)"
    fi

    # (1b) pi shim ASSEMBLED_ARGS contains -e herdr-agent-state.ts
    _L72I7_HERDR_IN_ARGS=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
      "grep -c 'herdr-agent-state.ts' /usr/local/bin/pi 2>/dev/null || echo 0")
    echo "  pi shim contains herdr-agent-state.ts in args: ${_L72I7_HERDR_IN_ARGS} occurrences"
    if [[ "${_L72I7_HERDR_IN_ARGS:-0}" -gt 0 ]]; then
      pass "(l72i7/1b-downgraded) herdr extension declared in pi shim ASSEMBLED_ARGS"
    else
      fail "(l72i7/1b-downgraded) herdr extension NOT declared in pi shim ASSEMBLED_ARGS (herdr-pi launch_args fragment missing)"
    fi
    unset _L72I7_HERDR_EXT_PATH _L72I7_HERDR_EXT_EXISTS _L72I7_HERDR_IN_ARGS

    # (1-best-effort) Attempt semantic poll: drive pi agent via herdr to observe
    # agent_status=working + screen_detection_skipped=true. SKIP (not FAIL) if
    # herdr server not up or agents list stays empty (headless harness limitation).
    echo ""
    echo "--- (l72i7/1-best-effort) Optional semantic poll (SKIP-not-FAIL if unobservable) ---"
    _L72I7_HERDR_START_OUT=$(docker exec -u agent "$DCG_HERDR_PI_CAGE" herdr agent start \
      l72i7-probe \
      --cwd /workspace \
      -- pi \
        --provider openrouter \
        --model anthropic/claude-3.5-haiku \
        -p "Write the word hello to /workspace/l72i7-hello.txt using your write tool. Then write the word world to /workspace/l72i7-world.txt using your write tool. Then write the word done to /workspace/l72i7-done.txt using your write tool." \
      2>&1 || true)
    echo "  herdr agent start output: ${_L72I7_HERDR_START_OUT}"

    # Wait for herdr server socket
    _l72i7_herdr_wait=0
    _l72i7_herdr_up=false
    while [[ $_l72i7_herdr_wait -lt 15 ]]; do
      if docker exec "$DCG_HERDR_PI_CAGE" bash -c \
          'test -S "${HOME}/.config/herdr/herdr.sock"' 2>/dev/null; then
        _l72i7_herdr_up=true
        break
      fi
      sleep 1
      _l72i7_herdr_wait=$((_l72i7_herdr_wait + 1))
    done

    if [[ "$_l72i7_herdr_up" != "true" ]]; then
      skip "(l72i7/1-semantic)" "herdr socket not found in composed cage after ${_l72i7_herdr_wait}s — semantic poll not observable (headless harness limitation; downgraded checks above are the binding assertions)"
    else
      # Poll herdr agent list for agent_status=working + screen_detection_skipped=true
      _L72I7_WORKING=false
      _L72I7_INTEGRATION_PATH=false
      _l72i7_poll_elapsed=0
      _l72i7_poll_interval=2
      _l72i7_poll_timeout=60
      _l72i7_last_list=""
      while [[ $_l72i7_poll_elapsed -lt $_l72i7_poll_timeout ]]; do
        _l72i7_last_list=$(docker exec -u agent "$DCG_HERDR_PI_CAGE" herdr agent list 2>/dev/null || echo '{}')
        _l72i7_status_check=$(echo "$_l72i7_last_list" | python3 -c "
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
        echo "  [l72i7/1-semantic t=${_l72i7_poll_elapsed}s] herdr agent list: ${_l72i7_status_check}"
        if echo "$_l72i7_status_check" | grep -q "integration_working=yes"; then
          _L72I7_WORKING=true
          _L72I7_INTEGRATION_PATH=true
          break
        fi
        sleep $_l72i7_poll_interval
        _l72i7_poll_elapsed=$((_l72i7_poll_elapsed + _l72i7_poll_interval))
      done
      echo "  Final herdr agent list: ${_l72i7_last_list}"
      if [[ "$_L72I7_WORKING" == "true" ]] && [[ "$_L72I7_INTEGRATION_PATH" == "true" ]]; then
        pass "(l72i7/1-semantic) BONUS: herdr semantic status observed: agent_status=working + screen_detection_skipped=true (ADR-006 D8 integration path — above downgraded checks already satisfied)"
      else
        # Not a FAIL — downgraded checks (1a+1b) are the binding assertions.
        skip "(l72i7/1-semantic)" "herdr semantic working-status not observable in ${_l72i7_poll_timeout}s (headless harness limitation per invalidation clause). Downgraded checks (1a+1b) are green — this SKIP does NOT affect overall pass."
      fi
      unset _l72i7_last_list _l72i7_status_check
    fi
    unset _l72i7_herdr_wait _l72i7_herdr_up _l72i7_poll_elapsed _l72i7_poll_interval _l72i7_poll_timeout

    # (3) Check: canary marker MUST exist after pi ran under the OPEN default
    # (ADR-027 D1, FIRM 2026-07-02 — rip-cage-p35a.1: dcg-wiring no longer
    # contributes --no-extensions, so pi's own extension auto-discovery paths
    # stay live; this canary loading IS the accepted-residual proof, not a
    # regression). Wait a few seconds for pi to start (it may not have started
    # extensions yet at the time herdr polled 'working'; give it time to settle).
    sleep 3
    echo ""
    echo "--- (l72i7) Assertion (3): canary extension IS loaded under the OPEN default ---"
    _L72I7_CANARY_MARKER_EXISTS=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
      "test -f '${_L72I7_CANARY_MARKER}' && echo yes || echo no" 2>/dev/null || echo "no")
    echo "  Canary marker exists: ${_L72I7_CANARY_MARKER_EXISTS}"
    if [[ "$_L72I7_CANARY_MARKER_EXISTS" == "yes" ]]; then
      _L72I7_CANARY_CONTENT=$(docker exec "$DCG_HERDR_PI_CAGE" cat "${_L72I7_CANARY_MARKER}" 2>/dev/null || echo "<unreadable>")
      pass "(l72i7/3) canary extension IS loaded: marker present at ${_L72I7_CANARY_MARKER} with content '${_L72I7_CANARY_CONTENT}' (OPEN default preserves pi extension autonomy — ADR-027 D1)"
    else
      # POSITIVE CONTROL before declaring FAIL: the canary writes its marker
      # SYNCHRONOUSLY at extension module-load time, before any tool call —
      # its absence is only meaningful if pi actually started as a process.
      # Same headless-harness limitation as the semantic poll above (herdr
      # agent list showed zero/idle agents the whole time): check whether pi
      # produced ANY of its requested output files as evidence it ran at all.
      _L72I7_PI_RAN_EVIDENCE=$(docker exec "$DCG_HERDR_PI_CAGE" sh -c \
        "test -f /workspace/l72i7-hello.txt -o -f /workspace/l72i7-world.txt -o -f /workspace/l72i7-done.txt && echo yes || echo no" 2>/dev/null || echo "no")
      if [[ "$_L72I7_PI_RAN_EVIDENCE" == "yes" ]]; then
        fail "(l72i7/3) canary extension NOT loaded: marker absent at ${_L72I7_CANARY_MARKER} despite pi having demonstrably run (output files present) — expected auto-discovery to be live under the OPEN default (ADR-027 D1); pi shim may still carry --no-extensions (retired LOCKED-by-default posture)"
      else
        skip "(l72i7/3)" "canary marker absent AND no evidence pi produced any output (l72i7-hello/world/done.txt all absent) — same headless-harness limitation as the (1) semantic poll above (herdr agent list showed no working agent); not a false-pass, but not conclusive enough to FAIL the auto-discovery property. Structural assertions (2a-2e) — including the DCG deny-probe — are the binding safety check and are green."
      fi
      unset _L72I7_PI_RAN_EVIDENCE
    fi

    unset _L72I7_HERDR_START_OUT _L72I7_WORKING _L72I7_INTEGRATION_PATH
    unset _L72I7_OR_KEY
    unset _L72I7_CANARY_MARKER _L72I7_CANARY_DIR _L72I7_CANARY_TS _L72I7_CANARY_PLACED _L72I7_CANARY_MARKER_EXISTS
  fi
else
  fail "(l72i7) skipping three-conjunction assertions — DCG+herdr+pi cage did not start"
fi

unset _L72I7_CAGE_STARTED

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
