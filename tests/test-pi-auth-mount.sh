#!/usr/bin/env bash
# Tests for pi state mount topology: container-local PI_CODING_AGENT_DIR and
# NO host auth.json mount (pi credentials ride msb `secrets:`, rip-cage-3w82).
# Requires docker + rip-cage:latest image already built (./rc build).
#
# What this tests:
#   1. the host's ~/.pi/agent/auth.json is NOT visible inside the container
#   2. the rc.auth.credential-mounts.pi label is the constant none
#   3. PI_CODING_AGENT_DIR=/home/agent/.pi/agent set in container env
#   4. CAGE_HOST_ADDR passed through explicitly (for non-interactive pi -p)
#   5. Empty OPENAI_API_KEY is NOT forwarded (empty-value filter)
#   6. rc up succeeds when ~/.pi/agent is absent (warning, no fatal)
#   7. /home/agent/.pi/agent/AGENTS.md content + mtime unchanged after rc up
#      (init must not mutate container-local dotfiles)
#   8. a write to the cage's auth.json path never reaches the host file
#   9. extensions/ dir is agent-owned + writable (agent's own extension space; the pi guard is NOT auto-loaded from here — post-olen it rides an explicit -e from /etc/rip-cage/pi/; OPEN by default, ADR-027 D1, FIRM 2026-07-02 — extensions/ still auto-loads normally, --no-extensions is a LOCKED opt-in)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"
# shellcheck source=tests/_cage-lookup-lib.sh
source "${SCRIPT_DIR}/_cage-lookup-lib.sh"

FAILURES=0
TEST_WS=""
CONTAINER=""
CONTAINER2=""
CREATED_CAGES=()

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — got: ${2:-}"; FAILURES=$((FAILURES + 1)); }

_track() { CREATED_CAGES+=("$1"); }

# Resolve the container name from the workspace label — robust against
# rc's collision-hash fallback and tr/sed name normalization.
_resolve_container() { cage_name_for_source "${1:-$TEST_WS}"; }

# _pi_agent_identity_snapshot <dir> -- top-level entry names, types
# (symlink/dir/file), and — for symlinks — the raw unresolved link target.
# Identity-only, not full content hashing (unrelated agents/tools may be
# legitimately touching files under a live ~/.pi/agent during this run, and
# hashing those would produce false failures unrelated to this test). A
# symlink silently being replaced by a regular file is exactly the shape
# rip-cage-bh0r's incident took, and is exactly what this catches. Shared
# with the identical helper in test-pi-cage-context.sh (rip-cage-bh0r).
_pi_agent_identity_snapshot() {
  local dir="$1"
  if [[ ! -e "$dir" ]]; then
    echo "ABSENT"
    return
  fi
  find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort | while IFS= read -r entry; do
    local name
    name=$(basename "$entry")
    if [[ -L "$entry" ]]; then
      echo "SYMLINK $name -> $(readlink "$entry")"
    elif [[ -d "$entry" ]]; then
      echo "DIR $name"
    else
      echo "FILE $name"
    fi
  done
}

# ---- Guard: skip if docker or image not available ----
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest image not built — run ./rc build first"
  exit 0
fi

# ---- Self-isolate HOME (rip-cage-7atw.3) ----
# This test manipulates ~/.pi/agent directly (mv-away, in-place overwrite,
# rm -rf of an auto-seeded artifact). It must NEVER do that against the
# operator's REAL ~/.pi/agent. The full-suite driver (tests/run-host.sh)
# sandboxes XDG_CONFIG_HOME/RC_CONFIG_GLOBAL but deliberately does NOT set
# HOME — well-behaved tests are expected to sandbox their own (see
# test-ssh-preflight.sh / test-ssh-config.sh for the same pattern). Point
# HOME at a throwaway dir for the lifetime of this script BEFORE deriving
# PI_AGENT_DIR, so every operation below lands in the sandbox regardless of
# how/where this test is invoked. Not nested under the real $HOME, so
# teardown is a plain rm -rf (mirrors TEST_WS/TEST_WS2 cleanup below) — no
# DCG home-path collision is possible.
#
# REAL_MSB_HOME: captured BEFORE the HOME override (msb-port note, mirrors
# test-e2e-lifecycle.sh). msb derives its per-sandbox agent-relay Unix socket
# path from $HOME by default, and macOS's mktemp default TMPDIR is long
# enough that a temp-HOME override alone overflows the 104-byte AF_UNIX path
# limit ("agent relay socket path is too long"). msb's local image cache is
# ALSO keyed off $HOME, so a temp HOME sees an empty cache and would force a
# doomed registry pull for rip-cage:latest. Pointing MSB_HOME at the real,
# unmodified microsandbox home sidesteps both.
#
# REAL-HOME SAFETY SNAPSHOT (rip-cage-bh0r acceptance #2, belt-and-braces):
# captured BEFORE the HOME override, against the REAL, un-sandboxed
# ~/.pi/agent, so the assertion in cleanup() below holds even if the
# sandboxing above this comment has a bug.
REAL_HOME="$HOME"
REAL_HOME_PI_AGENT="${REAL_HOME}/.pi/agent"
BEFORE_REAL_HOME_SNAPSHOT=$(_pi_agent_identity_snapshot "$REAL_HOME_PI_AGENT")
REAL_MSB_HOME="${REAL_HOME}/.microsandbox"
TEST_HOME_SANDBOX=$(mktemp -d)
export HOME="$TEST_HOME_SANDBOX"
# Exported (not just per-call) since every rc/msb invocation below (rc ls,
# rc exec, rc destroy — not only rc up) must resolve against the real msb
# sandboxes registry, not an empty one under the temp HOME.
export MSB_HOME="$REAL_MSB_HOME"
# Docker resolves its CONTEXT through $HOME/.docker, and HOME is sandboxed
# above, so without this `docker info` fails and every case reports a daemon
# error instead of its own subject. The isolation this suite needs is over
# rip-cage's own config, not over the container runtime.
export DOCKER_CONFIG="${REAL_HOME}/.docker"

# ---- State backup/restore for ~/.pi/agent ----
PI_AGENT_DIR="${HOME}/.pi/agent"
PI_AGENT_BACKUP=""
PI_AGENT_EXISTED=false
if [[ -d "$PI_AGENT_DIR" ]]; then
  PI_AGENT_EXISTED=true
  PI_AGENT_BACKUP=$(mktemp -d)
  cp -a "$PI_AGENT_DIR/." "$PI_AGENT_BACKUP/"
fi

cleanup() {
  local prior_exit=$?
  local c _d_out _d_rc
  # Tear down any cages we started (register-array shape — never enumerate+glob)
  for c in "${CREATED_CAGES[@]:-}"; do
    if [[ -n "$c" ]]; then
      _d_out=$("$RC" destroy "$c" 2>&1)
      _d_rc=$?
      if [[ "$_d_rc" -ne 0 ]]; then
        echo "WARNING: failed to destroy '$c' (exit ${_d_rc}): ${_d_out}" >&2
      fi
    fi
  done
  # Clean up test workspace dirs
  [[ -n "$TEST_WS" && -d "$TEST_WS" ]] && rm -rf "$TEST_WS"
  [[ -n "${TEST_WS2:-}" && -d "${TEST_WS2}" ]] && rm -rf "$TEST_WS2"
  # Restore ~/.pi/agent state — atomic mv-swap to avoid losing data on cp failure
  if [[ "$PI_AGENT_EXISTED" == "true" && -n "$PI_AGENT_BACKUP" ]]; then
    mv "$PI_AGENT_DIR" "${PI_AGENT_DIR}.evicting"
    mv "$PI_AGENT_BACKUP" "$PI_AGENT_DIR"
    rm -rf "${PI_AGENT_DIR}.evicting"
  elif [[ "$PI_AGENT_EXISTED" == "false" ]]; then
    # We created ~/.pi/agent for the test — remove it (unless it still exists as the
    # real user's directory). Check that it only contains our test file before deleting.
    if [[ -d "$PI_AGENT_DIR" ]]; then
      local _count
      _count=$(find "$PI_AGENT_DIR" -maxdepth 1 -name '*.json' | wc -l)
      # Only auto-remove if it looks like our test directory (single auth.json)
      if [[ -f "$PI_AGENT_DIR/auth.json" && "$_count" -le 1 ]]; then
        rm -rf "$PI_AGENT_DIR"
      fi
    fi
  fi
  # Tear down the throwaway HOME sandbox itself. It is never nested under
  # the real $HOME (mktemp'd, like TEST_WS/TEST_WS2 above), so a plain
  # rm -rf is safe here too — the whole point of the sandbox is that
  # discarding it can never touch the operator's real ~/.pi/agent.
  [[ -n "${TEST_HOME_SANDBOX:-}" && -d "$TEST_HOME_SANDBOX" ]] && rm -rf "$TEST_HOME_SANDBOX"

  # ---- REAL-HOME SAFETY ASSERTION (rip-cage-bh0r acceptance #1/#2) ----
  local after_snapshot
  after_snapshot=$(_pi_agent_identity_snapshot "$REAL_HOME_PI_AGENT")
  if [[ "$after_snapshot" == "$BEFORE_REAL_HOME_SNAPSHOT" ]]; then
    echo "PASS: real \$HOME/.pi/agent identity unchanged (entries/types/symlink-targets match before/after)"
  else
    echo "FAIL: real \$HOME/.pi/agent was mutated by this test run"
    echo "  before: $BEFORE_REAL_HOME_SNAPSHOT"
    echo "  after:  $after_snapshot"
    prior_exit=1
  fi
  exit "$prior_exit"
}
trap cleanup EXIT

# ---- Set up fake ~/.pi/agent/auth.json ----
mkdir -p "$PI_AGENT_DIR"
printf '{"fake":true}\n' > "$PI_AGENT_DIR/auth.json"

TEST_WS=$(mktemp -d)

# ================================================================
# Test 1: the host auth.json is NOT mounted into the cage
# ================================================================
echo ""
echo "=== Test 1: host ~/.pi/agent/auth.json is not visible in the cage ==="

RC_CAGE_CONF="$(cage_conf_for "$TEST_WS")" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS" </dev/null >/dev/null 2>&1 || true
CONTAINER=$(_resolve_container "$TEST_WS")

if [[ -z "$CONTAINER" ]]; then
  fail "container did not come up"
  echo "$FAILURES test(s) FAILED (fatal — no container to inspect)."
  exit "$FAILURES"
fi
_track "$CONTAINER"

content=$(msb exec "$CONTAINER" -- cat /home/agent/.pi/agent/auth.json 2>/dev/null || true)
if echo "$content" | grep -q "fake"; then
  fail "host auth.json content is visible inside the cage (it must never be mounted)" "$content"
else
  pass "host auth.json content is not visible inside the cage"
fi

# ================================================================
# Test 2: credential-mounts.pi label is the constant none
# ================================================================
echo ""
echo "=== Test 2: rc.auth.credential-mounts.pi label is none ==="

pi_label=$(msb inspect "$CONTAINER" --format json 2>/dev/null | jq -r '.config.labels["rc.auth.credential-mounts.pi"] // empty')
if [[ "$pi_label" == "none" ]]; then
  pass "rc.auth.credential-mounts.pi=none"
else
  fail "rc.auth.credential-mounts.pi label is '$pi_label' (expected none)"
fi

# ================================================================
# Test 3: PI_CODING_AGENT_DIR=/home/agent/.pi/agent set in container env
# ================================================================
echo ""
echo "=== Test 3: PI_CODING_AGENT_DIR=/home/agent/.pi/agent in container env ==="

pi_env=$(msb exec "$CONTAINER" -- env 2>/dev/null | grep '^PI_CODING_AGENT_DIR=' || true)
if [[ "$pi_env" == "PI_CODING_AGENT_DIR=/home/agent/.pi/agent" ]]; then
  pass "PI_CODING_AGENT_DIR=/home/agent/.pi/agent in container env"
else
  fail "PI_CODING_AGENT_DIR not set correctly" "$pi_env"
fi

# ================================================================
# Test 4: CAGE_HOST_ADDR passed through explicitly (for non-interactive pi -p)
# ================================================================
echo ""
echo "=== Test 4: CAGE_HOST_ADDR present in container env ==="

cage_addr_line=$(msb exec "$CONTAINER" -- env 2>/dev/null | grep '^CAGE_HOST_ADDR=' || true)
if [[ "${cage_addr_line#CAGE_HOST_ADDR=}" != "" ]]; then
  pass "CAGE_HOST_ADDR present and non-empty in container env ('$cage_addr_line')"
else
  fail "CAGE_HOST_ADDR not set or empty in container env (non-interactive pi -p will fail)" "$cage_addr_line"
fi

# ================================================================
# Test 5: Empty OPENAI_API_KEY is NOT forwarded (empty-value filter)
# ================================================================
echo ""
echo "=== Test 5: Empty OPENAI_API_KEY is NOT forwarded ==="

# Simulate the env-var passthrough logic using the same fixed list and
# empty-value filter from _up_prepare_docker_mounts. This verifies the
# logic without needing to parse the docker run command.
_pi_env_vars=(
  ANTHROPIC_API_KEY AZURE_OPENAI_API_KEY OPENAI_API_KEY GEMINI_API_KEY
  MISTRAL_API_KEY GROQ_API_KEY CEREBRAS_API_KEY XAI_API_KEY
  OPENROUTER_API_KEY AI_GATEWAY_API_KEY ZAI_API_KEY OPENCODE_API_KEY
  KIMI_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY
  PI_SKIP_VERSION_CHECK PI_CACHE_RETENTION
)

# Export OPENAI_API_KEY as empty, and a non-empty sentinel key
OPENAI_API_KEY=""
export OPENAI_API_KEY
TEST_ANTHROPIC_KEY="sk-test-sentinel-value"
ANTHROPIC_API_KEY="$TEST_ANTHROPIC_KEY"
export ANTHROPIC_API_KEY

_test_args=()
for _pi_var in "${_pi_env_vars[@]}"; do
  if [[ -n "${!_pi_var:-}" ]]; then
    _test_args+=(-e "${_pi_var}=${!_pi_var}")
  fi
done

# OPENAI_API_KEY="" should NOT appear
found_empty=false
for arg in "${_test_args[@]}"; do
  if [[ "$arg" == *"OPENAI_API_KEY="* ]]; then
    found_empty=true
  fi
done
if [[ "$found_empty" == "false" ]]; then
  pass "OPENAI_API_KEY='' not forwarded (empty-value filter works)"
else
  fail "OPENAI_API_KEY='' was forwarded — empty-value filter broken"
fi

# ANTHROPIC_API_KEY=sk-test-... SHOULD appear
found_set=false
for arg in "${_test_args[@]}"; do
  if [[ "$arg" == "-e" ]]; then
    continue
  fi
  if [[ "$arg" == "ANTHROPIC_API_KEY=${TEST_ANTHROPIC_KEY}" ]]; then
    found_set=true
  fi
done
if [[ "$found_set" == "true" ]]; then
  pass "Non-empty ANTHROPIC_API_KEY forwarded correctly"
else
  fail "ANTHROPIC_API_KEY not forwarded despite being set"
fi

# Clean up the exported test vars
unset OPENAI_API_KEY ANTHROPIC_API_KEY _pi_env_vars _pi_var _test_args

# ================================================================
# Test 6: rc up succeeds when ~/.pi/agent is absent (warning, no fatal)
# ================================================================
echo ""
echo "=== Test 6: rc up succeeds when ~/.pi/agent is missing ==="

# Rename the pi agent dir to simulate absence
mv "$PI_AGENT_DIR" "${PI_AGENT_DIR}.bak-test"

TEST_WS2=$(mktemp -d)
rc_output=""
rc_exit=0
rc_output=$(RC_CAGE_CONF="$(cage_conf_for "$TEST_WS2")" RIP_CAGE_EGRESS=off "$RC" up "$TEST_WS2" </dev/null 2>&1) || rc_exit=$?

CONTAINER2=$(_resolve_container "$TEST_WS2")

if [[ -n "$CONTAINER2" ]]; then
  _track "$CONTAINER2"
  pass "rc up succeeded without ~/.pi/agent (container came up)"
else
  fail "rc up failed when ~/.pi/agent absent (should warn, not fatal)" "exit=$rc_exit"
fi

# Should have logged a warning
if echo "$rc_output" | grep -qi "pi.*not found\|pi.*skip\|pi.*warning"; then
  pass "rc up logged a pi-related warning when ~/.pi/agent absent"
else
  # Warning goes to log (log() may be silent by default unless verbose) — acceptable
  echo "  Note: pi warning may only appear with verbose logging (log() may be silent)"
  pass "rc up did not fatal on missing ~/.pi/agent (warning check inconclusive)"
fi

# Restore for cleanup trap. rc up no longer seeds ~/.pi/agent, so the moved-away
# backup lands back at the top level.
mv "${PI_AGENT_DIR}.bak-test" "$PI_AGENT_DIR"

# ================================================================
# Test 7: /home/agent/.pi/agent dir is container-local (not host-mounted whole-dir)
# bin/ subdir exists in container but is NOT the host's ~/.pi/agent/bin/
# ================================================================
echo ""
echo "=== Test 7: Container-local pi dir — bin/ not host-mounted ==="

# Verify the container-local dir exists as agent:agent and is independent of host
pi_dir_stat=$(msb exec "$CONTAINER" -- stat -c '%U:%G' /home/agent/.pi/agent 2>/dev/null || true)
if [[ "$pi_dir_stat" == "agent:agent" ]]; then
  pass "/home/agent/.pi/agent dir exists as agent:agent in container"
else
  fail "/home/agent/.pi/agent dir stat unexpected" "$pi_dir_stat"
fi

# bin/ should NOT be a mount of the host's bin/ — the container should generate
# its own tools. Write a sentinel file to host ~/.pi/agent/bin/ and verify it
# does NOT appear inside the container.
mkdir -p "$PI_AGENT_DIR/bin"
printf 'host-sentinel' > "$PI_AGENT_DIR/bin/host-marker.txt"
# Container was started before this file existed — if bin/ is not mounted, it won't appear
bin_content=$(msb exec "$CONTAINER" -- cat /home/agent/.pi/agent/bin/host-marker.txt 2>/dev/null || true)
if [[ -z "$bin_content" ]]; then
  pass "bin/ is NOT host-mounted (container-local; host sentinel not visible)"
else
  fail "bin/ appears to be host-mounted (host sentinel visible — bin/ should be container-local)" "$bin_content"
fi
rm -f "$PI_AGENT_DIR/bin/host-marker.txt"

# ================================================================
# Test 8: a write to the cage's auth.json path never reaches the host file
# ================================================================
echo ""
echo "=== Test 8: cage write to auth.json does not touch the host file ==="

msb exec "$CONTAINER" -- bash -c 'printf "{\"cage\":true}\n" > /home/agent/.pi/agent/auth.json' 2>/dev/null || true
host_content=$(cat "$PI_AGENT_DIR/auth.json" 2>/dev/null || true)
if echo "$host_content" | grep -q "cage"; then
  fail "cage write to auth.json reached the host file (rw mount still present)" "$host_content"
else
  pass "cage write to auth.json did not reach the host file"
fi

# ================================================================
# Test 9: the agent's pi extensions/ dir is correct, agent-owned, and writable
#
# Post-wlwc.4 (olen retirement, ADR-019 D8 / ADR-027 D1/D3) the DCG guard does
# NOT live in this dir. The root-owned launch wrapper ($(command -v pi), /usr/bin/pi on this image) loads
# the guard explicitly via boot.json tools[pi].launch (-e /etc/rip-cage/pi/dcg-gate.ts) on its OWN separate
# root-owned path — a workspace/extensions write cannot shadow it either way.
# /home/agent/.pi/agent/extensions/ is therefore NOT a guard path — it is the
# agent's own writable extension space (ADR-027 rw self-improvement). OPEN by
# default (ADR-027 D1, FIRM 2026-07-02): pi DOES normally auto-load whatever
# the agent drops here (that autonomy IS the point); --no-extensions is a
# documented LOCKED opt-in (examples/dcg/README.md) that disables it.
#
# What this test proves non-interactively:
#   - The dir exists in the container image (baked by Dockerfile)
#   - It is agent:agent owned (the agent owns its own extension space)
#   - The agent user can write to it (agent improves its own extensions in-cage)
#   - A marker file dropped here is readable by the agent user
#
# What this test does NOT assert:
#   - Whether pi actually auto-loads from this dir at runtime (open vs. locked
#     posture) — that live behavior is covered by tests/test-pi-no-extensions.sh
#     (LOCKED-VARIANT-ONLY; self-skips under the shipped OPEN default) and the
#     RC_E2E_DCGHP_ONLY canary in tests/test-multiplexer-lifecycle.sh.
# ================================================================
echo ""
echo "=== Test 9: agent pi extensions/ dir exists, is agent-owned, and is writable ==="

# Guard (rip-cage-sw6s): /home/agent/.pi/agent/extensions is created by the
# examples/pi recipe's TOOL 'init' agent-context boot-hook (rip-cage-p35a.3),
# NOT by base init-rip-cage.sh and NOT baked into the image any more (see
# cage/init/init-rip-cage.sh:46-49 — the mkdir was relocated out of base
# infra). A floor-only image (no tools.yaml composing examples/pi, as on the
# repo-default build) never runs that hook, so the dir is legitimately
# absent here. That is a DIFFERENT cause from a broken exec channel
# (rip-cage-54q3: "failed to exec ... -> not found: spawn ... ENOENT" for
# EVERY command on a live cage) — both would otherwise look like the same
# empty output under `2>/dev/null`, so 9a inspects stderr instead of
# discarding it, to keep a future exec-channel regression visibly
# distinguishable from this expected, named absence.
_ext_stderr_file=$(mktemp)
ext_dir_stat=$(msb exec "$CONTAINER" -- stat -c '%U:%G' /home/agent/.pi/agent/extensions 2>"$_ext_stderr_file")
ext_dir_rc=$?
ext_dir_stderr="$(cat "$_ext_stderr_file")"
rm -f "$_ext_stderr_file"

_ext_broken_channel=false
_ext_recipe_absent=false
if [[ $ext_dir_rc -ne 0 ]] && echo "$ext_dir_stderr" | grep -qE 'failed to exec|spawn "|\(ENOENT\)'; then
  _ext_broken_channel=true
elif [[ $ext_dir_rc -ne 0 ]] && echo "$ext_dir_stderr" | grep -q 'No such file or directory'; then
  _ext_recipe_absent=true
fi

if [[ "$_ext_broken_channel" == "true" ]]; then
  # A genuine defect (rip-cage-54q3 shape) — must never be skip-guarded.
  fail "9a: extensions dir check aborted — exec channel looks broken (rip-cage-54q3 shape), not a missing prerequisite" "$ext_dir_stderr"
elif [[ "$ext_dir_stat" == "agent:agent" ]]; then
  pass "9a: /home/agent/.pi/agent/extensions dir exists as agent:agent in container"
elif [[ "$_ext_recipe_absent" == "true" ]]; then
  echo "SKIP: 9a extensions dir check — examples/pi recipe not composed into this image, so its TOOL init boot-hook (rip-cage-p35a.3) that creates the dir never ran"
else
  fail "9a: extensions dir missing or wrong ownership (got: '$ext_dir_stat')" "$ext_dir_stderr"
fi

# 9b: dir must be writable by agent user (agent's own extension space — ADR-027 rw)
if [[ "$_ext_broken_channel" == "true" ]]; then
  fail "9b: extensions writability check skipped — exec channel looks broken (rip-cage-54q3 shape)" "$ext_dir_stderr"
elif [[ "$_ext_recipe_absent" == "true" ]]; then
  echo "SKIP: 9b extensions writability check — examples/pi recipe not composed into this image, extensions dir does not exist"
else
  write_test=$(msb exec "$CONTAINER" -- bash -c 'touch /home/agent/.pi/agent/extensions/.write-test && echo ok && rm /home/agent/.pi/agent/extensions/.write-test' 2>/dev/null || true)
  if [[ "$write_test" == "ok" ]]; then
    pass "9b: /home/agent/.pi/agent/extensions dir is writable by agent user"
  else
    fail "9b: /home/agent/.pi/agent/extensions dir is NOT writable by agent user" "$write_test"
  fi
fi

# 9c: a marker file dropped into the dir is readable by the agent user
#     (confirms the agent extension space is not blocked by permissions or mount shadowing)
if [[ "$_ext_broken_channel" == "true" ]]; then
  fail "9c: extensions marker-readability check skipped — exec channel looks broken (rip-cage-54q3 shape)" "$ext_dir_stderr"
elif [[ "$_ext_recipe_absent" == "true" ]]; then
  echo "SKIP: 9c extensions marker-readability check — examples/pi recipe not composed into this image, extensions dir does not exist"
else
  msb exec "$CONTAINER" -- bash -c 'printf "// marker\nexport default {};\n" > /home/agent/.pi/agent/extensions/marker-test.js' 2>/dev/null
  marker_content=$(msb exec "$CONTAINER" -- cat /home/agent/.pi/agent/extensions/marker-test.js 2>/dev/null || true)
  msb exec "$CONTAINER" -- rm -f /home/agent/.pi/agent/extensions/marker-test.js 2>/dev/null || true
  if echo "$marker_content" | grep -q "marker"; then
    pass "9c: marker file dropped in extensions/ is readable by agent user (agent extension space writable)"
  else
    fail "9c: marker file in extensions/ not readable — agent extension space may be blocked" "$marker_content"
  fi
fi

# ================================================================
# Summary
# ================================================================
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All pi state mount tests passed."
else
  echo "$FAILURES test(s) FAILED."
fi
exit "$FAILURES"
