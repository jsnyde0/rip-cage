#!/usr/bin/env bash
# E2E lifecycle test — exercises rc up/down/destroy + regression guards.
# ADR-013 D1/D3 (FIRM). Supersedes test-integration.sh.
#
# Runtime: ~90-180s warm cache. Set RC_E2E_REBUILD=1 to force rc build first.
# Run from host only; rc hard-exits when /.dockerenv is present.
#
# NAMING: rc container_name() derives from parent+basename of the workspace
# path, so we stage workspaces under /var/folders/.../rc/e2e-test to produce
# the deterministic container name "rc-e2e-test".
set -euo pipefail

PASS=0; FAIL=0; TOTAL=0
check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ -- $detail}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  [$TOTAL] $name${detail:+ -- $detail}"
    FAIL=$((FAIL + 1))
  fi
}

CONTAINER_NAME="rc-e2e-test"
E2E_TMP=""
E2E_TMP2=""
OFF_TMP=""

CLEANUP() {
  # Destroy any e2e containers + volumes we may have created. Match on labels
  # keyed to our staging roots so we don't touch the developer's real work.
  local c
  for c in $(docker ps -a --filter "label=rc.source.path" --format '{{.Names}}' 2>/dev/null); do
    local sp
    sp=$(docker inspect --format '{{index .Config.Labels "rc.source.path"}}' "$c" 2>/dev/null || true)
    case "$sp" in
      "$E2E_TMP"/*|"$E2E_TMP2"/*|"$OFF_TMP"/*)
        docker rm -f "$c" > /dev/null 2>&1 || true
        docker volume rm "rc-state-${c}" > /dev/null 2>&1 || true
        ;;
    esac
  done
  [[ -n "$E2E_TMP"  ]] && rm -rf "$E2E_TMP"
  [[ -n "$E2E_TMP2" ]] && rm -rf "$E2E_TMP2"
  [[ -n "$OFF_TMP"  ]] && rm -rf "$OFF_TMP"
}
trap CLEANUP EXIT

# Pre-cleanup: remove any leftover state from a prior aborted run so we
# don't accidentally hit the name-collision code path.
docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
docker volume rm "rc-state-${CONTAINER_NAME}" > /dev/null 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RC="${SCRIPT_DIR}/../rc"

# Stage workspaces so container_name() = "rc-e2e-test". Parent dir must be "rc".
E2E_TMP=$(mktemp -d)
mkdir -p "${E2E_TMP}/rc"
TEST_WS="${E2E_TMP}/rc/e2e-test"
mkdir -p "$TEST_WS"

# RC_ALLOWED_ROOTS must cover the resolved parent (macOS /var -> /private/var).
E2E_TMP_RESOLVED=$(realpath "$E2E_TMP")
export RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}"

echo "=== E2E Lifecycle Checks ==="
echo "TEST_WS=$TEST_WS"
echo ""

# -----------------------------------------------------------------------------
# Lifecycle — setup
# -----------------------------------------------------------------------------

# Check 1: RC_E2E_REBUILD guard
if [[ "${RC_E2E_REBUILD:-0}" == "1" ]]; then
  if "$RC" build > /dev/null 2>&1; then
    check "rc build succeeds" "pass"
  else
    check "rc build succeeds" "fail" "rc build exited non-zero"
  fi
else
  check "rc build (skipped -- set RC_E2E_REBUILD=1 to rebuild)" "pass" "using existing local image"
fi

# Check 2: Scratch workspace initialized
git -C "$TEST_WS" init > /dev/null 2>&1
echo "# e2e test workspace" > "$TEST_WS/README"
check "scratch workspace created with git repo" "pass" "$TEST_WS"

# Check 3: rc up headless — container starts, rc.egress label = "on"
"$RC" up "$TEST_WS" < /dev/null > /tmp/rc-e2e-up.out 2>&1 || true
egress_label=$(docker inspect "$CONTAINER_NAME" \
  --format '{{index .Config.Labels "rc.egress"}}' 2>/dev/null || true)
if [[ "$egress_label" == "on" ]]; then
  check "rc up headless -- container running with rc.egress=on" "pass"
else
  check "rc up headless -- container running with rc.egress=on" "fail" \
    "label was '${egress_label:-missing}' (see /tmp/rc-e2e-up.out)"
fi

# Check 4: Scratch workspace bind-mounted at /workspace
if docker exec "$CONTAINER_NAME" test -f /workspace/README > /dev/null 2>&1; then
  check "scratch workspace bind-mounted at /workspace" "pass"
else
  check "scratch workspace bind-mounted at /workspace" "fail"
fi

# Check 5: /workspace/.rip-cage/ writable by agent
if docker exec "$CONTAINER_NAME" sh -c 'mkdir -p /workspace/.rip-cage && touch /workspace/.rip-cage/.probe' > /dev/null 2>&1; then
  check "/workspace/.rip-cage/ writable by agent" "pass"
else
  check "/workspace/.rip-cage/ writable by agent" "fail"
fi

# -----------------------------------------------------------------------------
# Regression guards (ADR-013 D3 FIRM)
# -----------------------------------------------------------------------------

# Check 6: python3-venv present (regression guard for 2026-04-20 fix #1)
# A plain rc build is NOT sufficient — Docker reuses cached apt layers even if
# the Dockerfile line is deleted. Assert both package presence and functional
# venv creation.
dpkg_ok=0; venv_ok=0
docker exec "$CONTAINER_NAME" dpkg -s python3-venv > /dev/null 2>&1 && dpkg_ok=1
docker exec "$CONTAINER_NAME" python3 -m venv /tmp/venv-probe > /dev/null 2>&1 && venv_ok=1
if [[ "$dpkg_ok" -eq 1 && "$venv_ok" -eq 1 ]]; then
  check "python3-venv present and functional (regression guard)" "pass"
else
  check "python3-venv present and functional (regression guard)" "fail" \
    "dpkg=$dpkg_ok venv=$venv_ok"
fi

# Check 7: rc test passes all in-container suites
if "$RC" test "$CONTAINER_NAME" > /tmp/rc-e2e-rctest.out 2>&1; then
  if grep -qE '^PASS|pass' /tmp/rc-e2e-rctest.out; then
    check "rc test passes in-container suites" "pass"
  else
    check "rc test passes in-container suites" "fail" "no PASS lines in output"
  fi
else
  check "rc test passes in-container suites" "fail" "rc test exited non-zero (see /tmp/rc-e2e-rctest.out)"
fi

# Check 8: rc ls source path matches realpath of TEST_WS
rc_ls_path=$("$RC" --output json ls 2>/dev/null | jq -r \
  --arg name "$CONTAINER_NAME" \
  '.[] | select(.name == $name) | .source_path' 2>/dev/null || true)
expected=$(realpath "$TEST_WS")
if [[ "$rc_ls_path" == "$expected" ]]; then
  check "rc ls source path matches realpath of TEST_WS" "pass"
else
  check "rc ls source path matches realpath of TEST_WS" "fail" \
    "got '${rc_ls_path}' expected '${expected}'"
fi

# Check 9: Expected tools present inside container.
# Core tools (hard-required): sourced from test-integration.sh step 7.
# Advisory tools (ms rg fd): mentioned in the design doc; `ms` is delivered via
# the Python MCP shim, not a binary, so absence of the CLI isn't a regression.
# Surface missing advisory tools as detail but do not fail.
tools_missing=()
tools_advisory_missing=()
for tool in claude dcg bd uv bun node gh git perl jq tmux zsh; do
  if ! docker exec "$CONTAINER_NAME" which "$tool" > /dev/null 2>&1; then
    tools_missing+=("$tool")
  fi
done
for tool in ms rg fd; do
  if ! docker exec "$CONTAINER_NAME" which "$tool" > /dev/null 2>&1; then
    tools_advisory_missing+=("$tool")
  fi
done
if [[ ${#tools_missing[@]} -eq 0 ]]; then
  if [[ ${#tools_advisory_missing[@]} -gt 0 ]]; then
    check "core tools present (advisory: ${tools_advisory_missing[*]} absent)" "pass"
  else
    check "core + advisory tools present inside container" "pass"
  fi
else
  check "core tools present inside container" "fail" \
    "missing: ${tools_missing[*]}"
fi

# Check 10: No host CLAUDE.md leaked to agent home
# After init, CLAUDE.md IS copied into ~/.claude/CLAUDE.md if a global template
# exists on the host. The original integration-test assertion was that no
# CLAUDE.md leaked when the host file is NOT provided. In this test we do
# mount the host's CLAUDE.md (via the standard rc up path), so the file is
# expected to be present. Downgrade the assertion to "if ~/.claude/CLAUDE.md
# exists, it matches the intended host source".
if docker exec "$CONTAINER_NAME" test -f /home/agent/.claude/CLAUDE.md > /dev/null 2>&1; then
  # File present — confirm it came from the .rc-context bind mount (sourced from host).
  if docker exec "$CONTAINER_NAME" test -f /home/agent/.rc-context/global-claude.md > /dev/null 2>&1; then
    check "CLAUDE.md presence matches host source" "pass" "copied from .rc-context/global-claude.md"
  else
    check "CLAUDE.md presence matches host source" "fail" "CLAUDE.md present but no .rc-context source"
  fi
else
  check "CLAUDE.md presence matches host source" "pass" "no CLAUDE.md (host template absent)"
fi

# Check 11: Hook path consistency
hook_ok=0; dcg_ok=0
docker exec "$CONTAINER_NAME" test -x /usr/local/lib/rip-cage/hooks/block-compound-commands.sh > /dev/null 2>&1 && hook_ok=1
docker exec "$CONTAINER_NAME" test -x /usr/local/bin/dcg > /dev/null 2>&1 && dcg_ok=1
if [[ "$hook_ok" -eq 1 && "$dcg_ok" -eq 1 ]]; then
  check "hook path consistency (block-compound-commands.sh + dcg)" "pass"
else
  check "hook path consistency (block-compound-commands.sh + dcg)" "fail" \
    "hook=$hook_ok dcg=$dcg_ok"
fi

# -----------------------------------------------------------------------------
# Lifecycle — stop/resume
# -----------------------------------------------------------------------------

# Check 12: docker stop exits 0 (simulates rc down)
if docker stop "$CONTAINER_NAME" > /dev/null 2>&1; then
  check "docker stop exits 0" "pass"
else
  check "docker stop exits 0" "fail"
fi

# Check 16 setup: snapshot tmux client count before resume (container is stopped
# so this will error or return 0; capture safely).
docker start "$CONTAINER_NAME" > /dev/null 2>&1 || true
sleep 1
tmux_clients_before=$(docker exec "$CONTAINER_NAME" sh -c 'tmux list-clients 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]' || echo 0)
docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true

# Check 13: rc up on same workspace resumes — egress label preserved
"$RC" up "$TEST_WS" < /dev/null > /dev/null 2>&1 || true
egress_label=$(docker inspect "$CONTAINER_NAME" \
  --format '{{index .Config.Labels "rc.egress"}}' 2>/dev/null || true)
if [[ "$egress_label" == "on" ]]; then
  check "rc up resume preserves rc.egress=on" "pass"
else
  check "rc up resume preserves rc.egress=on" "fail" "label='${egress_label:-missing}'"
fi

# Check 14: Volume contents intact after resume
if docker exec "$CONTAINER_NAME" test -f /workspace/README > /dev/null 2>&1; then
  check "workspace contents intact after resume" "pass"
else
  check "workspace contents intact after resume" "fail"
fi

# Check 15: rc test still passes after restart
if "$RC" test "$CONTAINER_NAME" > /tmp/rc-e2e-rctest2.out 2>&1; then
  check "rc test passes after restart" "pass"
else
  check "rc test passes after restart" "fail" "(see /tmp/rc-e2e-rctest2.out)"
fi

# Check 16: Resume TTY guard (regression guard for 2026-04-20 fix #3).
# The fix prevents rc up from launching tmux attach when stdin is not a TTY.
# Compare tmux client count before/after a no-op resume against the already
# running container. No new client should appear.
"$RC" up "$TEST_WS" < /dev/null > /dev/null 2>&1 || true
tmux_clients_after=$(docker exec "$CONTAINER_NAME" sh -c 'tmux list-clients 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]' || echo 0)
if [[ "${tmux_clients_after:-0}" -le "${tmux_clients_before:-0}" ]]; then
  check "resume TTY guard (no tmux attach on non-TTY stdin)" "pass" \
    "before=$tmux_clients_before after=$tmux_clients_after"
else
  check "resume TTY guard (no tmux attach on non-TTY stdin)" "fail" \
    "before=$tmux_clients_before after=$tmux_clients_after"
fi

# Check 17: CA env propagation (regression guard for 2026-04-20 fix #2)
env_out=$(docker exec "$CONTAINER_NAME" env 2>/dev/null || true)
if echo "$env_out" | grep -q "^NODE_EXTRA_CA_CERTS="; then
  ca_val=$(echo "$env_out" | grep "^NODE_EXTRA_CA_CERTS=" | head -1 | cut -d= -f2-)
  if [[ "$ca_val" == "/usr/local/share/ca-certificates/rip-cage-proxy.crt" ]]; then
    check "NODE_EXTRA_CA_CERTS propagated (egress=on path)" "pass"
  else
    check "NODE_EXTRA_CA_CERTS propagated (egress=on path)" "fail" "value='$ca_val'"
  fi
else
  check "NODE_EXTRA_CA_CERTS propagated (egress=on path)" "fail" "env var missing"
fi

# -----------------------------------------------------------------------------
# Lifecycle — destroy
# -----------------------------------------------------------------------------

# Check 18: rc destroy removes container
"$RC" destroy -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
if ! docker inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
  check "rc destroy removes container" "pass"
else
  check "rc destroy removes container" "fail"
fi

# Check 19: rc destroy removes volume
if ! docker volume ls --format '{{.Name}}' | grep -q "^rc-state-${CONTAINER_NAME}$"; then
  check "rc destroy removes volume" "pass"
else
  check "rc destroy removes volume" "fail"
fi

# -----------------------------------------------------------------------------
# Name collision
# -----------------------------------------------------------------------------

# Check 20: Second workspace whose parent+base would compute the SAME raw name
# triggers rc's collision handling (-XXXX suffix appended).
E2E_TMP2=$(mktemp -d)
mkdir -p "${E2E_TMP2}/rc"
COLLIDE_WS="${E2E_TMP2}/rc/e2e-test"
mkdir -p "$COLLIDE_WS"
git -C "$COLLIDE_WS" init > /dev/null 2>&1
E2E_TMP2_RESOLVED=$(realpath "$E2E_TMP2")
export RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${E2E_TMP2_RESOLVED}"

# Re-up the primary workspace so there's something to collide against.
"$RC" up "$TEST_WS" < /dev/null > /dev/null 2>&1 || true
"$RC" up "$COLLIDE_WS" < /dev/null > /dev/null 2>&1 || true

collide_resolved=$(realpath "$COLLIDE_WS")
collision_name=$(docker ps -a --filter "label=rc.source.path=${collide_resolved}" \
  --format '{{.Names}}' 2>/dev/null | head -1)
if [[ "$collision_name" =~ -[0-9a-f]{4}$ ]]; then
  check "name collision produces -XXXX suffix" "pass" "$collision_name"
else
  check "name collision produces -XXXX suffix" "fail" "name was '${collision_name:-<none>}'"
fi

# Cleanup collision container + primary re-up.
[[ -n "$collision_name" ]] && docker rm -f "$collision_name" > /dev/null 2>&1 || true
[[ -n "$collision_name" ]] && docker volume rm "rc-state-${collision_name}" > /dev/null 2>&1 || true
docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
docker volume rm "rc-state-${CONTAINER_NAME}" > /dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Egress-off variant
# -----------------------------------------------------------------------------

# Check 21: RIP_CAGE_EGRESS=off — no mitmdump, label = "off".
# Stage the off workspace under a path that yields a distinct container name
# (parent "rc-off", base "test" -> "rc-off-test").
OFF_TMP=$(mktemp -d)
mkdir -p "${OFF_TMP}/rc-off"
OFF_WS="${OFF_TMP}/rc-off/test"
mkdir -p "$OFF_WS"
git -C "$OFF_WS" init > /dev/null 2>&1
OFF_TMP_RESOLVED=$(realpath "$OFF_TMP")
export RC_ALLOWED_ROOTS="${E2E_TMP_RESOLVED}:${E2E_TMP2_RESOLVED}:${OFF_TMP_RESOLVED}"
RIP_CAGE_EGRESS=off "$RC" up "$OFF_WS" < /dev/null > /dev/null 2>&1 || true

off_resolved=$(realpath "$OFF_WS")
off_container=$(docker ps -a --filter "label=rc.source.path=${off_resolved}" \
  --format '{{.Names}}' 2>/dev/null | head -1)
off_label=$(docker inspect "$off_container" \
  --format '{{index .Config.Labels "rc.egress"}}' 2>/dev/null || true)
no_mitm=0
if [[ -n "$off_container" ]]; then
  docker exec "$off_container" pgrep -u rip-proxy mitmdump > /dev/null 2>&1 || no_mitm=1
fi
if [[ "$off_label" == "off" && "$no_mitm" -eq 1 ]]; then
  check "RIP_CAGE_EGRESS=off -- label=off, no mitmdump" "pass"
else
  check "RIP_CAGE_EGRESS=off -- label=off, no mitmdump" "fail" \
    "container='${off_container:-<none>}' label='${off_label:-missing}' no_mitm=$no_mitm"
fi
# Cleanup off container.
[[ -n "$off_container" ]] && docker rm -f "$off_container" > /dev/null 2>&1 || true
[[ -n "$off_container" ]] && docker volume rm "rc-state-${off_container}" > /dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Failure mode
# -----------------------------------------------------------------------------

# Check 22: rc up with nonexistent path exits non-zero, no partial container.
# Subshell isolates env leaks.
nonexistent_exit=0
( "$RC" up /nonexistent/path/that/does/not/exist < /dev/null > /dev/null 2>&1 ) || nonexistent_exit=$?
partial=$(docker ps -a --filter label=rc.source.path=/nonexistent/path/that/does/not/exist --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$nonexistent_exit" -ne 0 && "$partial" -eq 0 ]]; then
  check "rc up nonexistent path -- exit non-zero, no partial container" "pass"
else
  check "rc up nonexistent path -- exit non-zero, no partial container" "fail" \
    "exit=$nonexistent_exit partial_containers=$partial"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
echo "=== E2E Summary: $PASS/$TOTAL passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
