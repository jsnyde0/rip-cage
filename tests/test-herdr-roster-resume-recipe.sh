#!/usr/bin/env bash
# tests/test-herdr-roster-resume-recipe.sh -- host-only unit/composition tests
# for the herdr roster-resume recipe (rip-cage-46s5, ADR-029 D8).
#
# Scope: recipe/composition-level pieces only -- durable state mount, socket
# relocation, scripted-attach helper, pin bump, CLAUDE_CODE_CHILD_SESSION env
# hygiene. All host-only (no docker/msb required) so this runs fast in every
# session. The live in-cage e2e (reload -> roster restored, N sessions,
# codewords recovered) is the bead's DEFERRED harness target -- it needs a
# booted msb cage and is NOT this file's job (see bead rip-cage-46s5 Harness
# target / docs/2026-07-27-roster-resume-design.md).
#
# Positive-sentinel discipline: every failure increments FAILURES; script
# exits non-zero if FAILURES > 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
WRAPPER_EXAMPLES="${REPO_ROOT}/examples/claude/claude-session-wrapper.sh"
WRAPPER_SUBSTRATE="${REPO_ROOT}/cage/substrate/claude-session-wrapper.sh"
HERDR_FRAGMENT="${REPO_ROOT}/examples/herdr/manifest-fragment.yaml"

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
# Method: copy the UNMODIFIED canonical wrapper to a tmp file, patch ONLY
# REAL_CLAUDE to point at a stub that dumps its env to a file (same technique
# as tests/test-claude-json-seed-synthesis.sh V4/V5), run it with
# CLAUDE_CODE_CHILD_SESSION pre-set in the invoking env, and assert the stub
# never saw it.
# =============================================================================
echo "--- T1: CLAUDE_CODE_CHILD_SESSION scrub ---"

test_t1_scrub() {
  local work stub_out
  work="${TMPROOT}/t1"
  mkdir -p "$work"
  stub_out="${work}/env-seen.txt"

  # Stub REAL_CLAUDE: dumps its environment, never calls the network.
  cat > "${work}/stub-claude" <<STUB
#!/usr/bin/env bash
env > "${stub_out}"
STUB
  chmod +x "${work}/stub-claude"

  # Copy the canonical wrapper, patch only REAL_CLAUDE (source untouched).
  cp "$WRAPPER_EXAMPLES" "${work}/wrapper-under-test.sh"
  sed -i.bak "s#^REAL_CLAUDE=/usr/bin/claude#REAL_CLAUDE=${work}/stub-claude#" "${work}/wrapper-under-test.sh"
  chmod +x "${work}/wrapper-under-test.sh"

  local fake_home
  fake_home="${work}/home"
  mkdir -p "$fake_home"

  CLAUDE_CODE_CHILD_SESSION=1 HOME="$fake_home" CLAUDE_CONFIG_DIR="${fake_home}/.claude-sessions/t1" \
    "${work}/wrapper-under-test.sh" --version >"${work}/run.out" 2>&1
  local rc=$?

  if [[ "$rc" -ne 0 ]]; then
    fail "T1: patched wrapper invocation failed (exit $rc)" "$(cat "${work}/run.out")"
    return
  fi
  if [[ ! -f "$stub_out" ]]; then
    fail "T1: stub-claude never ran (no env dump produced)" "$(cat "${work}/run.out")"
    return
  fi
  if grep -q '^CLAUDE_CODE_CHILD_SESSION=' "$stub_out"; then
    fail "T1: CLAUDE_CODE_CHILD_SESSION reached the exec'd claude binary -- wrapper must scrub it" "$(cat "$stub_out")"
  else
    pass "T1: CLAUDE_CODE_CHILD_SESSION is scrubbed before exec (absent from the exec'd env)"
  fi
}
test_t1_scrub

# =============================================================================
# T2 -- the two wrapper copies stay byte-identical (structural regression
# guard: examples/claude/claude-session-wrapper.sh is the recipe copy,
# cage/substrate/claude-session-wrapper.sh is its sibling; the bead requires
# both edited in lockstep).
# =============================================================================
echo ""
echo "--- T2: wrapper copies stay byte-identical ---"

test_t2_wrappers_identical() {
  if [[ ! -f "$WRAPPER_EXAMPLES" ]]; then
    fail "T2: examples/claude/claude-session-wrapper.sh missing"
    return
  fi
  if [[ ! -f "$WRAPPER_SUBSTRATE" ]]; then
    fail "T2: cage/substrate/claude-session-wrapper.sh missing"
    return
  fi
  if diff -q "$WRAPPER_EXAMPLES" "$WRAPPER_SUBSTRATE" >/dev/null 2>&1; then
    pass "T2: examples/claude and cage/substrate wrapper copies are byte-identical"
  else
    fail "T2: wrapper copies have diverged" "$(diff "$WRAPPER_EXAMPLES" "$WRAPPER_SUBSTRATE" | head -20)"
  fi
}
test_t2_wrappers_identical

# =============================================================================
# T3 -- durable state mount: examples/herdr/manifest-fragment.yaml declares a
# mounts: entry projecting a per-cage HOST DIRECTORY at guest path
# /home/agent/.config/herdr, mode rw (herdr writes session.json continuously).
#
# NOTE: mounts: is only valid on TOOL-archetype entries (MULTIPLEXER strict-
# parse rejects unknown top-level fields) -- must land on the herdr-bin TOOL
# entry, not the herdr MULTIPLEXER entry.
# =============================================================================
echo ""
echo "--- T3: durable state mount (herdr-bin TOOL entry) ---"

test_t3_durable_mount() {
  if [[ ! -f "$HERDR_FRAGMENT" ]]; then
    fail "T3: ${HERDR_FRAGMENT} missing"
    return
  fi
  local dest_count dest_val mode_val
  dest_count=$(yq -o=json '.tools[] | select(.name == "herdr-bin") | .mounts | length' "$HERDR_FRAGMENT" 2>/dev/null)
  if [[ -z "$dest_count" || "$dest_count" -eq 0 ]]; then
    fail "T3: herdr-bin TOOL entry has no mounts: declared"
    return
  fi
  dest_val=$(yq -o=json '.tools[] | select(.name == "herdr-bin") | .mounts[] | select(.dest == "/home/agent/.config/herdr") | .dest' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')
  if [[ "$dest_val" == "/home/agent/.config/herdr" ]]; then
    pass "T3a: herdr-bin mounts a durable host dir at guest dest /home/agent/.config/herdr"
  else
    fail "T3a: no mounts[] entry with dest /home/agent/.config/herdr found"
    return
  fi
  mode_val=$(yq -o=json '.tools[] | select(.name == "herdr-bin") | .mounts[] | select(.dest == "/home/agent/.config/herdr") | .mode' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')
  if [[ "$mode_val" == "rw" ]]; then
    pass "T3b: durable state mount is mode rw (herdr writes session.json continuously)"
  else
    fail "T3b: durable state mount mode is '${mode_val}', expected 'rw'"
  fi
}
test_t3_durable_mount

# =============================================================================
# T4 -- the fragment still strict-parse validates end to end (_manifest_validate).
# =============================================================================
echo ""
echo "--- T4: fragment strict-parse validates ---"

test_t4_fragment_validates() {
  local test_home stderr_file exit_code out
  test_home=$(mktemp -d "${TMPROOT}/rc-herdr-fragment-XXXXXX")
  mkdir -p "${test_home}/.config/rip-cage"
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$test_home" XDG_CONFIG_HOME="${test_home}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${HERDR_FRAGMENT}'" \
    2>"$stderr_file") || exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    pass "T4: examples/herdr/manifest-fragment.yaml strict-parse validates"
  else
    fail "T4: strict-parse FAILED: exit=${exit_code} stderr='$(cat "$stderr_file")' stdout='${out}'"
  fi
  rm -f "$stderr_file"
}
test_t4_fragment_validates

# =============================================================================
# T5 -- pin bump v0.7.0 -> v0.7.5 (latest stable at design time, verified
# present on github.com/ogulcancelik/herdr/releases). Both arch binaries'
# sha256 checksums independently verified (downloaded + `sha256sum`, matches
# the GitHub release API's asset digest field). No "validated" label carried
# forward — restore behavior was S4-validated on 0.7.4/0.7.3-era binaries;
# this bead's own in-cage e2e (deferred) re-validates the bumped pin.
# =============================================================================
echo ""
echo "--- T5: pin bump v0.7.0 -> v0.7.5 ---"

test_t5_pin_bump() {
  if [[ ! -f "$HERDR_FRAGMENT" ]]; then
    fail "T5: ${HERDR_FRAGMENT} missing"
    return
  fi
  local version_pin install_cmd
  version_pin=$(yq -o=json '.tools[] | select(.name == "herdr-bin") | .version_pin' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')
  if [[ "$version_pin" == "v0.7.5" ]]; then
    pass "T5a: herdr-bin version_pin is v0.7.5"
  else
    fail "T5a: herdr-bin version_pin is '${version_pin}', expected v0.7.5"
  fi

  install_cmd=$(yq -o=json '.tools[] | select(.name == "herdr-bin") | .install_cmd' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')
  if echo "$install_cmd" | grep -q "releases/download/v0.7.5/"; then
    pass "T5b: install_cmd downloads from the v0.7.5 release"
  else
    fail "T5b: install_cmd does not reference releases/download/v0.7.5/. Got: '${install_cmd:0:150}'"
  fi

  # Independently-verified sha256 (downloaded both assets, ran sha256sum locally,
  # cross-checked against the GitHub release API's asset digest field).
  local expected_aarch64="32e763a1499a6b694b1d708e4f062b743be1da9f34fcfa4d212d6db6fe09a8b9"
  local expected_x86_64="3dc83288073e4c2d3c679a30e7be97bcca9141c6fd17dbbb9219142e95c59253"
  if echo "$install_cmd" | grep -qF "$expected_aarch64"; then
    pass "T5c: install_cmd carries the independently-verified aarch64 sha256"
  else
    fail "T5c: install_cmd missing expected aarch64 sha256 ${expected_aarch64}"
  fi
  if echo "$install_cmd" | grep -qF "$expected_x86_64"; then
    pass "T5d: install_cmd carries the independently-verified x86_64 sha256"
  else
    fail "T5d: install_cmd missing expected x86_64 sha256 ${expected_x86_64}"
  fi

  # No stale v0.7.0 references left behind (regression guard).
  if echo "$install_cmd" | grep -q "v0.7.0"; then
    fail "T5e: install_cmd still references the old v0.7.0 pin"
  else
    pass "T5e: install_cmd carries no stale v0.7.0 reference"
  fi
}
test_t5_pin_bump

# =============================================================================
# T6 -- HERDR_SOCKET_PATH relocation (rip-cage-46s5 decision 2 / S4 spike).
# The live server+client unix sockets must NOT land on the durable host mount
# (/home/agent/.config/herdr) -- only the hardcoded, host-mount-safe files
# (session.json, session-history.json, logs) belong there (S4: HERDR_SOCKET_PATH
# relocates both server and client sockets; session.json et al are NOT
# relocatable by any env var, S4 finding). The start hook must export
# HERDR_SOCKET_PATH to a guest-local path (e.g. under /tmp) BEFORE starting the
# herdr server.
# =============================================================================
echo ""
echo "--- T6: HERDR_SOCKET_PATH relocation in the start hook ---"

test_t6_socket_relocation() {
  if [[ ! -f "$HERDR_FRAGMENT" ]]; then
    fail "T6: ${HERDR_FRAGMENT} missing"
    return
  fi
  local start_hook
  start_hook=$(yq -o=json '.tools[] | select(.name == "herdr") | .hooks.start' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')

  if echo "$start_hook" | grep -q "HERDR_SOCKET_PATH"; then
    pass "T6a: start hook exports HERDR_SOCKET_PATH"
  else
    fail "T6a: start hook does not reference HERDR_SOCKET_PATH"
    return
  fi

  # The relocated socket must NOT sit under the durable mount dir -- that
  # would defeat the whole point (sockets are a live-process concept, not
  # continuously-durable state; putting them on the mount is at best inert
  # and at worst risks a stale-socket collision across a cold-recreate).
  if echo "$start_hook" | grep -qE '\.config/herdr[^"'"'"']*herdr\.sock'; then
    fail "T6b: relocated socket path still lands under ~/.config/herdr (the durable mount) -- must be guest-local (e.g. /tmp)"
  else
    pass "T6b: relocated socket path is NOT under ~/.config/herdr"
  fi

  # Ordering: HERDR_SOCKET_PATH must be set BEFORE 'herdr server' starts, else
  # the server binds its default (mounted) socket path before the override lands.
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
# T7 -- scripted-attach.py is baked into the image (herdr-bin TOOL entry) and
# invoked from the start hook AFTER the server + integration-install loop
# (rip-cage-46s5 decision 2). The baked blob must match the CURRENT source
# file byte-for-byte (regression guard against "edited the script, forgot to
# regenerate the fragment").
# =============================================================================
echo ""
echo "--- T7: scripted-attach.py baked + invoked from the start hook ---"

HERDR_ATTACH_SCRIPT="${REPO_ROOT}/examples/herdr/scripted-attach.py"
BAKED_ATTACH_PATH="/usr/local/bin/herdr-scripted-attach.py"

test_t7_scripted_attach_wired() {
  if [[ ! -f "$HERDR_FRAGMENT" ]]; then
    fail "T7: ${HERDR_FRAGMENT} missing"
    return
  fi
  if [[ ! -f "$HERDR_ATTACH_SCRIPT" ]]; then
    fail "T7: ${HERDR_ATTACH_SCRIPT} missing"
    return
  fi

  local install_cmd
  install_cmd=$(yq -o=json '.tools[] | select(.name == "herdr-bin") | .install_cmd' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')

  if echo "$install_cmd" | grep -qF "$BAKED_ATTACH_PATH"; then
    pass "T7a: herdr-bin install_cmd bakes scripted-attach.py at ${BAKED_ATTACH_PATH}"
  else
    fail "T7a: herdr-bin install_cmd does not reference ${BAKED_ATTACH_PATH}"
    return
  fi

  # Extract the base64 blob piped into `base64 -d > BAKED_ATTACH_PATH` and
  # confirm it decodes to the CURRENT source file, byte-for-byte. Path is
  # unquoted in install_cmd (matches the existing convention just above it:
  # `install -m 755 /tmp/herdr /usr/local/bin/herdr` is unquoted too).
  local extracted_b64 decoded expected
  extracted_b64=$(echo "$install_cmd" | grep -oE "echo '[A-Za-z0-9+/=]+' \\| base64 -d > ${BAKED_ATTACH_PATH//\//\\/}" | grep -oE "'[A-Za-z0-9+/=]+'" | head -1 | tr -d "'")
  if [[ -z "$extracted_b64" ]]; then
    fail "T7b: could not extract the baked base64 blob for ${BAKED_ATTACH_PATH} from install_cmd"
  else
    decoded=$(printf '%s' "$extracted_b64" | base64 -d 2>/dev/null)
    expected=$(cat "$HERDR_ATTACH_SCRIPT")
    if [[ "$decoded" == "$expected" ]]; then
      pass "T7b: baked scripted-attach.py blob matches the current source file byte-for-byte"
    else
      fail "T7b: baked blob does NOT match examples/herdr/scripted-attach.py -- fragment is stale, regenerate it"
    fi
  fi

  if echo "$install_cmd" | grep -qE "chmod (0)?755 ${BAKED_ATTACH_PATH//\//\\/}"; then
    pass "T7c: baked scripted-attach.py is chmod 0755 (agent-executable)"
  else
    fail "T7c: install_cmd does not chmod 0755 ${BAKED_ATTACH_PATH}"
  fi

  # Invocation: the start hook must invoke the baked script AFTER the
  # integration-install loop ('done' closes that for loop).
  local start_hook loop_pos invoke_pos
  start_hook=$(yq -o=json '.tools[] | select(.name == "herdr") | .hooks.start' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')
  if echo "$start_hook" | grep -qF "$BAKED_ATTACH_PATH"; then
    pass "T7d: start hook invokes the baked scripted-attach.py"
  else
    fail "T7d: start hook does not invoke ${BAKED_ATTACH_PATH}"
    return
  fi
  loop_pos=$(echo "$start_hook" | grep -bo "; done" | head -1 | cut -d: -f1)
  invoke_pos=$(echo "$start_hook" | grep -bo "$BAKED_ATTACH_PATH" | head -1 | cut -d: -f1)
  if [[ -n "$loop_pos" && -n "$invoke_pos" && "$invoke_pos" -gt "$loop_pos" ]]; then
    pass "T7e: scripted-attach invocation is ordered AFTER the integration-install loop"
  else
    fail "T7e: scripted-attach invocation is not ordered after the integration-install loop"
  fi
}
test_t7_scripted_attach_wired

# =============================================================================
# T8 -- attach hook must export the SAME relocated HERDR_SOCKET_PATH as the
# start hook (rip-cage-vjuv). The start hook (T6) relocates the herdr control
# socket to a guest-local path under /tmp so it survives off the durable host
# mount. 'rc attach' dispatches the attach hook in a FRESH 'msb exec' process
# that does NOT inherit the start hook's exported environment -- a bare
# 'herdr' attach hook falls back to herdr's default (mounted, now-empty)
# socket path and fails with 'Error: Os NotFound'. Confirmed live: `msb exec
# code-personal -- herdr agent list` -> NotFound; with
# HERDR_SOCKET_PATH=/tmp/rip-cage-herdr.sock exported first -> works.
# =============================================================================
echo ""
echo "--- T8: attach hook exports the same relocated HERDR_SOCKET_PATH ---"

test_t8_attach_hook_socket_relocation() {
  if [[ ! -f "$HERDR_FRAGMENT" ]]; then
    fail "T8: ${HERDR_FRAGMENT} missing"
    return
  fi
  local start_hook attach_hook start_sock attach_sock
  start_hook=$(yq -o=json '.tools[] | select(.name == "herdr") | .hooks.start' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')
  attach_hook=$(yq -o=json '.tools[] | select(.name == "herdr") | .hooks.attach' "$HERDR_FRAGMENT" 2>/dev/null | tr -d '"')

  if echo "$attach_hook" | grep -q "HERDR_SOCKET_PATH"; then
    pass "T8a: attach hook exports HERDR_SOCKET_PATH"
  else
    fail "T8a: attach hook does not reference HERDR_SOCKET_PATH -- 'rc attach' runs in a fresh msb exec that does not inherit the start hook's env, so a bare 'herdr' attach falls back to the default (mounted, empty) socket path and fails with 'Error: Os NotFound'"
    return
  fi

  # The attach hook's relocated socket path must match the start hook's
  # relocated socket path EXACTLY -- otherwise the client dials a different
  # socket than the server bound.
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

  # attach still ultimately execs herdr (does not accidentally drop the CLI call).
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
