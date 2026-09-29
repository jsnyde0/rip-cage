#!/usr/bin/env bash
# tests/test-herdr-roster-resume-recipe.sh -- host-only composition tests for
# the herdr recipe's roster-resume pieces (rip-cage-46s5, ADR-029 D8).
#
# Reads the recipe as it ships today: examples/herdr/Dockerfile.snippet,
# boot-fragment.json, scripted-attach.py and README.md. Covers the herdr pin,
# the durable state mount, socket relocation, the scripted-attach helper, and
# the CLAUDE_CODE_CHILD_SESSION scrub in the claude session wrapper. No
# docker/msb needed. The live leg (a herdr boot on the pinned release) is
# tests/test-msb-lifecycle-cockpit-reregistration.sh.
#
# History (rip-cage-8jg5.1, 2026-09-29): T3-T8 used to read
# examples/herdr/manifest-fragment.yaml, deleted with the manifest (ADR-031
# D4); they now read the snippet and boot fragment. T2 (the two claude
# wrapper copies stay byte-identical) is retired: the copies now differ on
# purpose -- the base-image copy execs /usr/local/lib/rip-cage/bin/claude-real
# behind the boot descriptor's tool-launch wrapper, the recipe copy sits at
# /usr/local/bin/claude (rip-cage-jimf.9). tests/test-claude-recipe-bypass-
# preaccept.sh covers both copies' behaviour.
#
# Positive-sentinel discipline: every failure increments FAILURES; script
# exits non-zero if FAILURES > 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
WRAPPER_EXAMPLES="${REPO_ROOT}/examples/claude/claude-session-wrapper.sh"
WRAPPER_SUBSTRATE="${REPO_ROOT}/cage/substrate/claude-session-wrapper.sh"
HERDR_SNIPPET="${REPO_ROOT}/examples/herdr/Dockerfile.snippet"
HERDR_BOOT="${REPO_ROOT}/examples/herdr/boot-fragment.json"
HERDR_README="${REPO_ROOT}/examples/herdr/README.md"
HERDR_ATTACH_SCRIPT="${REPO_ROOT}/examples/herdr/scripted-attach.py"
BAKED_ATTACH_PATH="/usr/local/bin/herdr-scripted-attach.py"

FAILURES=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

echo "=== test-herdr-roster-resume-recipe.sh (rip-cage-46s5) ==="
echo ""

# =============================================================================
# T1 -- CLAUDE_CODE_CHILD_SESSION scrub in claude-session-wrapper.sh
#
# S4 trap (docs/2026-07-27-msb-spike-roster-resume.md): an inherited
# CLAUDE_CODE_CHILD_SESSION marker silently disables transcript saving in
# interactive panes. The wrapper is the single PATH-shadowing chokepoint for
# every claude invocation (herdr resume, -p one-shots, direct calls) -- scrub
# it there so no spawn path needs its own special case.
#
# Both copies (examples/claude and cage/substrate) are checked.
# Method: copy the UNMODIFIED wrapper to a tmp file, patch ONLY
# REAL_CLAUDE to point at a stub that dumps its env to a file (same technique
# as tests/test-claude-json-seed-synthesis.sh V4/V5), run it with
# CLAUDE_CODE_CHILD_SESSION pre-set in the invoking env, and assert the stub
# never saw it.
# =============================================================================
echo "--- T1: CLAUDE_CODE_CHILD_SESSION scrub ---"

test_t1_scrub() {
  local label="$1" wrapper="$2"
  local work stub_out
  work="${TMPROOT}/t1-${label}"
  mkdir -p "$work"
  stub_out="${work}/env-seen.txt"

  # Stub REAL_CLAUDE: dumps its environment, never calls the network.
  cat > "${work}/stub-claude" <<STUB
#!/usr/bin/env bash
env > "${stub_out}"
STUB
  chmod +x "${work}/stub-claude"

  # Copy the canonical wrapper, patch only REAL_CLAUDE (source untouched).
  cp "$wrapper" "${work}/wrapper-under-test.sh"
  sed -i.bak "s#^REAL_CLAUDE=.*#REAL_CLAUDE=${work}/stub-claude#" "${work}/wrapper-under-test.sh"
  chmod +x "${work}/wrapper-under-test.sh"

  local fake_home
  fake_home="${work}/home"
  mkdir -p "$fake_home"

  CLAUDE_CODE_CHILD_SESSION=1 HOME="$fake_home" CLAUDE_CONFIG_DIR="${fake_home}/.claude-sessions/t1" \
    "${work}/wrapper-under-test.sh" --version >"${work}/run.out" 2>&1
  local rc=$?

  if [[ "$rc" -ne 0 ]]; then
    fail "T1 (${label}): patched wrapper invocation failed (exit $rc)" "$(cat "${work}/run.out")"
    return
  fi
  if [[ ! -f "$stub_out" ]]; then
    fail "T1 (${label}): stub-claude never ran (no env dump produced)" "$(cat "${work}/run.out")"
    return
  fi
  if grep -q '^CLAUDE_CODE_CHILD_SESSION=' "$stub_out"; then
    fail "T1 (${label}): CLAUDE_CODE_CHILD_SESSION reached the exec'd claude binary -- wrapper must scrub it" "$(cat "$stub_out")"
  else
    pass "T1 (${label}): CLAUDE_CODE_CHILD_SESSION is scrubbed before exec (absent from the exec'd env)"
  fi
}
test_t1_scrub examples "$WRAPPER_EXAMPLES"
test_t1_scrub substrate "$WRAPPER_SUBSTRATE"

# The herdr multiplexer's hooks, read from the boot fragment.
hook() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["multiplexers"][0][sys.argv[2]])' "$HERDR_BOOT" "$1" 2>/dev/null; }

# =============================================================================
# T3 -- durable state mount: the README tells the operator to mount a per-cage
# host directory at /home/agent/.config/herdr, read-write (herdr writes
# session.json continuously). The mount lives in the cage config, not the
# image, so the README line is the recipe's whole contract for it.
# =============================================================================
echo ""
echo "--- T3: durable state mount documented ---"

test_t3_durable_mount() {
  local line
  line=$(grep -E '^[[:space:]]*- "[^"]*:/home/agent/\.config/herdr"' "$HERDR_README" | head -1)
  if [[ -n "$line" ]]; then
    pass "T3a: README's mounts: line puts a host dir at /home/agent/.config/herdr"
  else
    fail "T3a: README has no mounts: line ending in :/home/agent/.config/herdr"
    return
  fi
  if echo "$line" | grep -q ':ro"'; then
    fail "T3b: the durable state mount is :ro -- herdr writes session.json continuously"
  else
    pass "T3b: the durable state mount is read-write (no :ro suffix)"
  fi
}
test_t3_durable_mount

# =============================================================================
# T4 -- the boot fragment parses and declares the herdr multiplexer with the
# two required hooks.
# =============================================================================
echo ""
echo "--- T4: boot fragment declares the herdr multiplexer ---"

test_t4_boot_fragment() {
  local name
  name=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["multiplexers"][0]; assert m["start"] and m["attach"]; print(m["name"])' "$HERDR_BOOT" 2>&1)
  if [[ "$name" == "herdr" ]]; then
    pass "T4: boot-fragment.json parses; multiplexers[0] is herdr with start + attach"
  else
    fail "T4: boot-fragment.json does not declare herdr with start + attach" "$name"
  fi
}
test_t4_boot_fragment

# =============================================================================
# T5 -- the pin: v0.9.0, both linux sha256 digests (release API digest,
# cross-checked by downloading both assets, rip-cage-8jg5.1). dotpi's seat
# needs herdr >= 0.8.2. No stale 0.7.x reference left in the snippet.
# =============================================================================
echo ""
echo "--- T5: herdr pin is v0.9.0 with both sha256 digests ---"

test_t5_pin() {
  if grep -q "releases/download/v0.9.0/herdr-linux-" "$HERDR_SNIPPET"; then
    pass "T5a: snippet downloads from the v0.9.0 release"
  else
    fail "T5a: snippet does not download releases/download/v0.9.0/"
  fi
  local expected_aarch64="9c8db20fb7e7427b138d5367113f1621ffd319f2f65d6f009e2594029115f0d2"
  local expected_x86_64="4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f"
  if grep -qF "$expected_aarch64" "$HERDR_SNIPPET" && grep -qF "$expected_x86_64" "$HERDR_SNIPPET"; then
    pass "T5b: snippet carries both verified sha256 digests"
  else
    fail "T5b: snippet is missing an expected sha256 (aarch64 ${expected_aarch64:0:12}..., x86_64 ${expected_x86_64:0:12}...)"
  fi
  if grep -q "sha256sum -c" "$HERDR_SNIPPET"; then
    pass "T5c: snippet checks the digest before installing"
  else
    fail "T5c: snippet never runs sha256sum -c"
  fi
  if grep -qE 'v0\.7\.[0-9]' "$HERDR_SNIPPET"; then
    fail "T5d: snippet still references a v0.7.x release"
  else
    pass "T5d: snippet carries no stale v0.7.x reference"
  fi
}
test_t5_pin

# =============================================================================
# T6 -- HERDR_SOCKET_PATH relocation (rip-cage-46s5 decision 2 / S4 spike).
# The live sockets must NOT land on the durable host mount
# (/home/agent/.config/herdr). The start hook exports HERDR_SOCKET_PATH to a
# guest-local path BEFORE starting the herdr server.
# =============================================================================
echo ""
echo "--- T6: HERDR_SOCKET_PATH relocation in the start hook ---"

test_t6_socket_relocation() {
  local start_hook
  start_hook=$(hook start)
  if echo "$start_hook" | grep -q "HERDR_SOCKET_PATH"; then
    pass "T6a: start hook exports HERDR_SOCKET_PATH"
  else
    fail "T6a: start hook does not reference HERDR_SOCKET_PATH"
    return
  fi
  if echo "$start_hook" | grep -qE '\.config/herdr[^"'"'"']*herdr\.sock'; then
    fail "T6b: relocated socket path still lands under ~/.config/herdr (the durable mount) -- must be guest-local (e.g. /tmp)"
  else
    pass "T6b: relocated socket path is NOT under ~/.config/herdr"
  fi
  local sock_pos server_pos
  sock_pos=$(echo "$start_hook" | grep -bo "HERDR_SOCKET_PATH" | head -1 | cut -d: -f1)
  server_pos=$(echo "$start_hook" | grep -bo "herdr server" | head -1 | cut -d: -f1)
  if [[ -n "$sock_pos" && -n "$server_pos" && "$sock_pos" -lt "$server_pos" ]]; then
    pass "T6c: HERDR_SOCKET_PATH is set before 'herdr server' starts"
  else
    fail "T6c: HERDR_SOCKET_PATH is not ordered before 'herdr server' in the hook string"
  fi
}
test_t6_socket_relocation

# =============================================================================
# T7 -- scripted-attach.py is baked root-owned 0755 by the snippet and invoked
# from the start hook AFTER the integration-install loop (rip-cage-46s5
# decision 2).
# =============================================================================
echo ""
echo "--- T7: scripted-attach.py baked + invoked from the start hook ---"

test_t7_scripted_attach_wired() {
  if [[ ! -f "$HERDR_ATTACH_SCRIPT" ]]; then
    fail "T7: ${HERDR_ATTACH_SCRIPT} missing"
    return
  fi
  if grep -qE "^COPY scripted-attach\.py ${BAKED_ATTACH_PATH}\$" "$HERDR_SNIPPET"; then
    pass "T7a: snippet COPYs scripted-attach.py to ${BAKED_ATTACH_PATH}"
  else
    fail "T7a: snippet does not COPY scripted-attach.py to ${BAKED_ATTACH_PATH}"
  fi
  if grep -qF "chown root:root ${BAKED_ATTACH_PATH}" "$HERDR_SNIPPET" && grep -qF "chmod 0755 ${BAKED_ATTACH_PATH}" "$HERDR_SNIPPET"; then
    pass "T7b: baked scripted-attach.py is root-owned and 0755 (agent can run, not replace)"
  else
    fail "T7b: snippet does not chown root:root + chmod 0755 ${BAKED_ATTACH_PATH}"
  fi
  local start_hook loop_pos invoke_pos
  start_hook=$(hook start)
  if echo "$start_hook" | grep -qF "$BAKED_ATTACH_PATH"; then
    pass "T7c: start hook invokes the baked scripted-attach.py"
  else
    fail "T7c: start hook does not invoke ${BAKED_ATTACH_PATH}"
    return
  fi
  loop_pos=$(echo "$start_hook" | grep -bo "; done" | head -1 | cut -d: -f1)
  invoke_pos=$(echo "$start_hook" | grep -bo "$BAKED_ATTACH_PATH" | head -1 | cut -d: -f1)
  if [[ -n "$loop_pos" && -n "$invoke_pos" && "$invoke_pos" -gt "$loop_pos" ]]; then
    pass "T7d: scripted-attach invocation is ordered AFTER the integration-install loop"
  else
    fail "T7d: scripted-attach invocation is not ordered after the integration-install loop"
  fi
}
test_t7_scripted_attach_wired

# =============================================================================
# T8 -- the attach hook exports the SAME relocated HERDR_SOCKET_PATH as the
# start hook (rip-cage-vjuv): attach runs in a fresh `msb exec` that does not
# inherit start's env, and a bare `herdr` falls back to the default socket
# path and fails with 'Error: Os NotFound'.
# =============================================================================
echo ""
echo "--- T8: attach hook exports the same relocated HERDR_SOCKET_PATH ---"

test_t8_attach_hook_socket_relocation() {
  local start_hook attach_hook start_sock attach_sock
  start_hook=$(hook start)
  attach_hook=$(hook attach)
  if echo "$attach_hook" | grep -q "HERDR_SOCKET_PATH"; then
    pass "T8a: attach hook exports HERDR_SOCKET_PATH"
  else
    fail "T8a: attach hook does not reference HERDR_SOCKET_PATH"
    return
  fi
  start_sock=$(echo "$start_hook" | grep -oE '/tmp/[A-Za-z0-9._-]*herdr[A-Za-z0-9._-]*\.sock' | head -1)
  attach_sock=$(echo "$attach_hook" | grep -oE '/tmp/[A-Za-z0-9._-]*herdr[A-Za-z0-9._-]*\.sock' | head -1)
  if [[ -z "$start_sock" ]]; then
    fail "T8b: could not extract a relocated socket path from the start hook"
    return
  fi
  if [[ "$attach_sock" == "$start_sock" ]]; then
    pass "T8b: attach hook relocates to the SAME socket path as start (${start_sock})"
  else
    fail "T8b: attach hook socket path ('${attach_sock}') does not match start hook socket path ('${start_sock}')"
  fi
  if echo "$attach_hook" | grep -qE '(^|[^A-Za-z0-9_-])herdr([^A-Za-z0-9_-]|$)'; then
    pass "T8c: attach hook still invokes herdr"
  else
    fail "T8c: attach hook no longer invokes herdr"
  fi
}
test_t8_attach_hook_socket_relocation

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-herdr-roster-resume-recipe.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-herdr-roster-resume-recipe.sh: all ${TOTAL} tests passed ==="
