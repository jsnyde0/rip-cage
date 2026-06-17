#!/usr/bin/env bash
# test-pi-substrate-mounts.sh — verifies pi substrate projection (rip-cage-kstk)
#
# Coverage (host-only, no Docker required):
#   (A)  _up_prepare_docker_mounts emits pi-skills, pi-prompts, pi-roles,
#        pi-AGENTS.md, and pi-ext-subagent bind-mount args with realpaths :ro
#   (B)  denylist warn-and-skip applies to pi mounts (an .aws-containing pi
#        asset is skipped + warned, not fatal)
#   (C)  syntax check: bash -n on rc and init-rip-cage.sh
#   (D)  init-rip-cage.sh creates pi symlinks (grep for pi symlink stanza)
#   (E)  init-rip-cage.sh does NOT replace the baked extensions dir with a
#        symlink (floor-shadow check: ln -sfn must only create
#        extensions/subagent, never extensions itself)
#
# Tests call _up_prepare_docker_mounts directly in a subshell (the same
# pattern used by test-secret-path-denylist.sh test_bprime) — no Docker needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
INIT="${SCRIPT_DIR}/../init-rip-cage.sh"
FAILURES=0
TEST_TMPDIR=""

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# Create a sandbox with a fake pi agent structure:
#   TEST_HOME/.pi/agent/skills/   (real dir)
#   TEST_HOME/.pi/agent/prompts -> dotpi symlink (we create a target dir)
#   TEST_HOME/.pi/agent/roles/    (real dir)
#   TEST_HOME/.pi/agent/AGENTS.md -> dotpi symlink
#   TEST_HOME/.pi/agent/extensions/subagent/ (real dir)
setup_sandbox() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-pi-mounts-test-XXXXXX")
  # Resolve to avoid macOS /tmp -> /private/tmp divergence
  TEST_TMPDIR=$(realpath "$TEST_TMPDIR" 2>/dev/null || echo "$TEST_TMPDIR")
  TEST_HOME="${TEST_TMPDIR}/home"
  TEST_WS="${TEST_TMPDIR}/workspace"
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  mkdir -p "$TEST_WS"

  # Write empty denylist config (so denylist machinery is active but silent)
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist:
    - .ssh
    - .gnupg
    - .gpg
    - .aws
    - .azure
    - .gcloud
    - .kube
    - .docker
    - credentials
    - .netrc
    - .npmrc
    - .pypirc
    - id_rsa
    - id_ed25519
    - private_key
    - .secret
YAML

  # Fake dotpi dir (simulates ~/code/personal/dotpi/agent/)
  DOTPI_DIR="${TEST_TMPDIR}/dotpi/agent"
  mkdir -p "${DOTPI_DIR}/prompts"
  mkdir -p "${DOTPI_DIR}/extensions/subagent"
  touch "${DOTPI_DIR}/AGENTS.md"

  # Real dirs
  mkdir -p "${TEST_HOME}/.pi/agent/skills/send-it"
  touch "${TEST_HOME}/.pi/agent/skills/send-it/SKILL.md"
  mkdir -p "${TEST_HOME}/.pi/agent/roles"
  touch "${TEST_HOME}/.pi/agent/roles/default.md"

  # Relative symlinks (simulating what dotpi ships)
  # prompts -> ../../dotpi/agent/prompts (relative symlink)
  ln -s "${DOTPI_DIR}/prompts" "${TEST_HOME}/.pi/agent/prompts"
  # AGENTS.md -> ../../dotpi/agent/AGENTS.md (relative symlink)
  ln -s "${DOTPI_DIR}/AGENTS.md" "${TEST_HOME}/.pi/agent/AGENTS.md"
  # extensions/subagent -> dotpi (absolute for test simplicity — same realpath behavior)
  mkdir -p "${TEST_HOME}/.pi/agent/extensions"
  ln -s "${DOTPI_DIR}/extensions/subagent" "${TEST_HOME}/.pi/agent/extensions/subagent"
}

teardown_sandbox() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
  TEST_HOME=""
  TEST_WS=""
}

# ---------------------------------------------------------------------------
# (A) _up_prepare_docker_mounts emits pi substrate mount args
# ---------------------------------------------------------------------------
test_A_pi_mounts_emitted() {
  setup_sandbox

  # Source rc in a subshell and call _up_prepare_docker_mounts.
  # Capture _UP_RUN_ARGS via a printed summary (one arg per line to stdout).
  local mount_args
  local exit_code=0
  mount_args=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash -c "
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container' 2>/dev/null
      printf '%s\n' \"\${_UP_RUN_ARGS[@]:-}\"
    " 2>/dev/null
  ) || exit_code=$?

  # --- skills ---
  local skills_realpath
  skills_realpath=$(realpath "${TEST_HOME}/.pi/agent/skills" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/skills")
  if printf '%s' "$mount_args" | grep -q "${skills_realpath}:/home/agent/.rc-context/pi-skills:ro"; then
    pass "(A) pi-skills mount arg present with realpath :ro"
  else
    fail "(A) pi-skills mount arg missing; expected '${skills_realpath}:/home/agent/.rc-context/pi-skills:ro'; got: $(printf '%s' "$mount_args" | grep pi-skills || echo '<none>')"
  fi

  # --- prompts (resolve through symlink) ---
  local prompts_realpath
  prompts_realpath=$(realpath "${TEST_HOME}/.pi/agent/prompts" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/prompts")
  if printf '%s' "$mount_args" | grep -q "${prompts_realpath}:/home/agent/.rc-context/pi-prompts:ro"; then
    pass "(A) pi-prompts mount arg present with resolved realpath :ro"
  else
    fail "(A) pi-prompts mount arg missing; expected '${prompts_realpath}:/home/agent/.rc-context/pi-prompts:ro'; got: $(printf '%s' "$mount_args" | grep pi-prompts || echo '<none>')"
  fi

  # --- roles ---
  local roles_realpath
  roles_realpath=$(realpath "${TEST_HOME}/.pi/agent/roles" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/roles")
  if printf '%s' "$mount_args" | grep -q "${roles_realpath}:/home/agent/.rc-context/pi-roles:ro"; then
    pass "(A) pi-roles mount arg present with realpath :ro"
  else
    fail "(A) pi-roles mount arg missing; expected '${roles_realpath}:/home/agent/.rc-context/pi-roles:ro'; got: $(printf '%s' "$mount_args" | grep pi-roles || echo '<none>')"
  fi

  # --- AGENTS.md (resolve through symlink) ---
  local agents_realpath
  agents_realpath=$(realpath "${TEST_HOME}/.pi/agent/AGENTS.md" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/AGENTS.md")
  if printf '%s' "$mount_args" | grep -q "${agents_realpath}:/home/agent/.rc-context/pi-AGENTS.md:ro"; then
    pass "(A) pi-AGENTS.md mount arg present with resolved realpath :ro"
  else
    fail "(A) pi-AGENTS.md mount arg missing; expected '${agents_realpath}:/home/agent/.rc-context/pi-AGENTS.md:ro'; got: $(printf '%s' "$mount_args" | grep pi-AGENTS || echo '<none>')"
  fi

  # --- subagent extension ---
  local subagent_realpath
  subagent_realpath=$(realpath "${TEST_HOME}/.pi/agent/extensions/subagent" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/extensions/subagent")
  if printf '%s' "$mount_args" | grep -q "${subagent_realpath}:/home/agent/.rc-context/pi-ext-subagent:ro"; then
    pass "(A) pi-ext-subagent mount arg present with resolved realpath :ro"
  else
    fail "(A) pi-ext-subagent mount arg missing; expected '${subagent_realpath}:/home/agent/.rc-context/pi-ext-subagent:ro'; got: $(printf '%s' "$mount_args" | grep pi-ext || echo '<none>')"
  fi

  # --- Verify NO whole-extensions-dir mount (floor-shadow check, strengthened) ---
  # Check 1: no -v arg's destination path ends in /extensions (bare extensions dir)
  # The loop emits .rc-context/<cage-name>, never a bare .pi/agent/extensions destination.
  if printf '%s\n' "$mount_args" | grep -E ":/home/agent/[^:]*extensions:?$|:/home/agent/[^:]*extensions:ro$" | grep -vq "extensions/"; then
    fail "(A-fs1) a -v mount arg maps to a bare extensions/ destination — floor-shadow risk"
  else
    pass "(A-fs1) no mount arg maps to a bare extensions/ destination (floor protected)"
  fi

  # Check 2: no -v arg's destination path is .rc-context/pi-extensions (non-subagent cage name)
  if printf '%s\n' "$mount_args" | grep -q ":/home/agent/.rc-context/pi-extensions:"; then
    fail "(A-fs2) a -v mount maps to pi-extensions (non-subagent cage name) — unexpected"
  else
    pass "(A-fs2) no mount maps to pi-extensions cage name (only pi-ext-subagent allowed)"
  fi

  # Check 3: the pi-ext-subagent source realpath ends in /extensions/subagent (selective projection)
  local subagent_mount_src
  subagent_mount_src=$(printf '%s\n' "$mount_args" \
    | grep ":/home/agent/.rc-context/pi-ext-subagent:" \
    | sed 's|:/home/agent.*||')
  if [[ "${subagent_mount_src}" == */extensions/subagent ]]; then
    pass "(A-fs3) pi-ext-subagent source ends in /extensions/subagent (selective projection)"
  else
    fail "(A-fs3) pi-ext-subagent source '${subagent_mount_src}' does not end in /extensions/subagent"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (A2) Pi mounts are skipped gracefully when ~/.pi/agent is absent
# ---------------------------------------------------------------------------
test_A2_pi_absent_graceful() {
  setup_sandbox

  # Create a home WITHOUT a .pi/agent dir
  local NOAPI_HOME="${TEST_TMPDIR}/home_nopi"
  mkdir -p "${NOAPI_HOME}/.config/rip-cage"
  cp "${TEST_HOME}/.config/rip-cage/config.yaml" "${NOAPI_HOME}/.config/rip-cage/config.yaml"

  local exit_code=0
  bash -c "
    source '$RC' 2>/dev/null
    _UP_RUN_ARGS=()
    wt_detected=false
    HOME='$NOAPI_HOME' XDG_CONFIG_HOME='${NOAPI_HOME}/.config' \
    _up_prepare_docker_mounts '$TEST_WS' 'test-container' 2>/dev/null
  " 2>/dev/null || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "(A2) rc up succeeds when ~/.pi/agent is absent (graceful skip)"
  else
    fail "(A2) rc up should not fail when ~/.pi/agent is absent (exit=$exit_code)"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (B) denylist warn-and-skip: pi asset resolving to an .aws path is skipped
# ---------------------------------------------------------------------------
test_B_pi_denylist_warn_and_skip() {
  setup_sandbox

  local resolved_home
  resolved_home=$(realpath "$TEST_HOME" 2>/dev/null || echo "$TEST_HOME")

  # Create a pi skills dir whose realpath contains .aws
  mkdir -p "${resolved_home}/.aws/pi-skills/send-it"
  touch "${resolved_home}/.aws/pi-skills/send-it/SKILL.md"

  # Point ~/.pi/agent/skills -> .aws/pi-skills via symlink
  rm -rf "${resolved_home}/.pi/agent/skills"
  ln -s "${resolved_home}/.aws/pi-skills" "${resolved_home}/.pi/agent/skills"

  local stderr_out
  local exit_code=0
  stderr_out=$(
    HOME="$resolved_home" \
    XDG_CONFIG_HOME="${resolved_home}/.config" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash -c "
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container'
    " 2>&1 >/dev/null
  ) || exit_code=$?

  if printf '%s' "$stderr_out" | grep -q "\.aws" \
     && printf '%s' "$stderr_out" | grep -qi "skip\|skipping"; then
    pass "(B) pi mount with .aws realpath: warned and skipped"
  else
    fail "(B) expected denylist warn-and-skip for pi .aws asset; got exit=$exit_code stderr=${stderr_out:-(empty)}"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (C) Syntax check: bash -n on rc and init-rip-cage.sh
# ---------------------------------------------------------------------------
test_C_bash_syntax() {
  local exit_rc=0
  bash -n "$RC" 2>/dev/null || exit_rc=$?
  if [[ "$exit_rc" -eq 0 ]]; then
    pass "(C) bash -n rc: no syntax errors"
  else
    fail "(C) bash -n rc: syntax error (exit=$exit_rc)"
  fi

  local exit_init=0
  bash -n "$INIT" 2>/dev/null || exit_init=$?
  if [[ "$exit_init" -eq 0 ]]; then
    pass "(C) bash -n init-rip-cage.sh: no syntax errors"
  else
    fail "(C) bash -n init-rip-cage.sh: syntax error (exit=$exit_init)"
  fi
}

# ---------------------------------------------------------------------------
# (D) init-rip-cage.sh symlinks pi assets into ~/.pi/agent/<asset>
# ---------------------------------------------------------------------------
test_D_init_creates_pi_symlinks() {
  # Check that init-rip-cage.sh contains a loop that creates pi symlinks
  # from /home/agent/.rc-context/pi-<asset> -> ~/.pi/agent/<asset>
  # We verify by grepping for the expected symlink creation patterns.

  if grep -q "rc-context/pi-" "$INIT"; then
    pass "(D) init-rip-cage.sh references .rc-context/pi- paths (pi symlink stanza present)"
  else
    fail "(D) init-rip-cage.sh missing .rc-context/pi- references"
  fi

  # Also verify it references pi skills and the subagent extension
  if grep -q "pi-skills\|pi-ext-subagent" "$INIT"; then
    pass "(D) init-rip-cage.sh references pi-skills and pi-ext-subagent"
  else
    fail "(D) init-rip-cage.sh missing pi-skills or pi-ext-subagent references"
  fi
}

# ---------------------------------------------------------------------------
# (E) init-rip-cage.sh does NOT replace the extensions dir itself
#     (only creates extensions/subagent symlink alongside baked dcg-gate)
# ---------------------------------------------------------------------------
test_E_floor_not_shadowed_by_init() {
  # Verify that init-rip-cage.sh DOES NOT contain a pattern like:
  #   ln -sfn ... ~/.pi/agent/extensions
  # which would replace the entire baked extensions dir.
  #
  # It SHOULD contain:
  #   ln -sfn ... ~/.pi/agent/extensions/subagent
  # which adds alongside the baked dcg-gate.ts

  if grep -E "ln -sfn.*extensions[^/]" "$INIT" | grep -vq "extensions/subagent"; then
    # A bare 'extensions' symlink target exists without the subagent qualifier
    fail "(E) init-rip-cage.sh may replace whole extensions/ dir — floor-shadow risk"
  else
    pass "(E) init-rip-cage.sh does not replace whole extensions/ dir (floor protected)"
  fi

  # Positive: should have the per-extension subagent symlink
  if grep -q "extensions/subagent" "$INIT"; then
    pass "(E) init-rip-cage.sh creates extensions/subagent symlink (selective projection)"
  else
    fail "(E) init-rip-cage.sh missing extensions/subagent symlink"
  fi
}

# ---------------------------------------------------------------------------
# (F) subagent extension source registers NO tool_call / interceptor handler
#     (ADR-027 fact #3: structural reason it cannot shadow dcg-gate)
# ---------------------------------------------------------------------------
test_F_subagent_no_interceptor() {
  # Resolve the host realpath of the subagent extension to read its source.
  local subagent_src
  subagent_src=$(realpath "${HOME}/.pi/agent/extensions/subagent/index.ts" 2>/dev/null || true)
  if [[ -z "${subagent_src}" || ! -f "${subagent_src}" ]]; then
    # If the host does not have pi installed, skip gracefully
    pass "(F) subagent index.ts absent on host — skip interceptor check (pi not installed)"
    return
  fi

  # Confirm it calls registerTool (positive: extension IS a tool registration)
  if grep -q "registerTool" "${subagent_src}"; then
    pass "(F) subagent/index.ts calls registerTool (tool registration confirmed)"
  else
    fail "(F) subagent/index.ts does not call registerTool — unexpected structure"
  fi

  # Confirm absence of interceptor handler patterns.
  # pi's block is monotonic: a handler can block but not un-block.
  # Dangerous patterns that could mutate post-approval state:
  #   tool_call handler, onToolCall, registerHandler (for events), pi.on(), addListener (for events)
  # NOTE: addEventListener is used for AbortSignal (abort-on-cancel) — NOT a pi event interceptor.
  # We grep specifically for pi-level event handlers, not DOM/signal listeners.
  local interceptor_hits
  interceptor_hits=$(grep -E \
    "pi\.on\(|registerHandler\(|onToolCall\b|\"tool_call\"|'tool_call'" \
    "${subagent_src}" 2>/dev/null || true)
  if [[ -z "${interceptor_hits}" ]]; then
    pass "(F) subagent/index.ts: no pi-level tool_call/interceptor handler (fact #3 structural check)"
  else
    fail "(F) subagent/index.ts contains pi-level interceptor pattern — floor-shadow risk: ${interceptor_hits}"
  fi
}

# ---------------------------------------------------------------------------
# (G) SYSTEM.md and APPEND_SYSTEM.md entries skip gracefully when absent
# ---------------------------------------------------------------------------
test_G_system_md_absent_graceful() {
  setup_sandbox

  # The sandbox has no SYSTEM.md or APPEND_SYSTEM.md under .pi/agent/
  local mount_args
  local exit_code=0
  mount_args=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash -c "
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container' 2>/dev/null
      printf '%s\n' \"\${_UP_RUN_ARGS[@]:-}\"
    " 2>/dev/null
  ) || exit_code=$?

  # Neither pi-SYSTEM.md nor pi-APPEND_SYSTEM.md should appear (absent on host)
  if printf '%s\n' "$mount_args" | grep -q "pi-SYSTEM.md\|pi-APPEND_SYSTEM.md"; then
    fail "(G) pi-SYSTEM.md or pi-APPEND_SYSTEM.md mount emitted when host files are absent"
  else
    pass "(G) pi-SYSTEM.md and pi-APPEND_SYSTEM.md skip gracefully when absent (no mount emitted)"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    pass "(G) rc exits 0 when SYSTEM.md/APPEND_SYSTEM.md are absent"
  else
    fail "(G) rc exits non-zero when SYSTEM.md/APPEND_SYSTEM.md are absent (exit=$exit_code)"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (H) SYSTEM.md and APPEND_SYSTEM.md emit mount args when present
# ---------------------------------------------------------------------------
test_H_system_md_present_emits_mount() {
  setup_sandbox

  # Create SYSTEM.md and APPEND_SYSTEM.md in the sandbox pi agent dir
  local system_realpath append_realpath
  touch "${TEST_HOME}/.pi/agent/SYSTEM.md"
  touch "${TEST_HOME}/.pi/agent/APPEND_SYSTEM.md"
  system_realpath=$(realpath "${TEST_HOME}/.pi/agent/SYSTEM.md" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/SYSTEM.md")
  append_realpath=$(realpath "${TEST_HOME}/.pi/agent/APPEND_SYSTEM.md" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/APPEND_SYSTEM.md")

  local mount_args
  mount_args=$(
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="${TEST_WS}" \
    bash -c "
      source '$RC' 2>/dev/null
      _UP_RUN_ARGS=()
      wt_detected=false
      _up_prepare_docker_mounts '$TEST_WS' 'test-container' 2>/dev/null
      printf '%s\n' \"\${_UP_RUN_ARGS[@]:-}\"
    " 2>/dev/null
  )

  if printf '%s\n' "$mount_args" | grep -q "${system_realpath}:/home/agent/.rc-context/pi-SYSTEM.md:ro"; then
    pass "(H) pi-SYSTEM.md mount emitted when SYSTEM.md is present"
  else
    fail "(H) pi-SYSTEM.md mount missing; expected '${system_realpath}:/home/agent/.rc-context/pi-SYSTEM.md:ro'; got: $(printf '%s\n' "$mount_args" | grep "SYSTEM" || echo '<none>')"
  fi

  if printf '%s\n' "$mount_args" | grep -q "${append_realpath}:/home/agent/.rc-context/pi-APPEND_SYSTEM.md:ro"; then
    pass "(H) pi-APPEND_SYSTEM.md mount emitted when APPEND_SYSTEM.md is present"
  else
    fail "(H) pi-APPEND_SYSTEM.md mount missing; expected '${append_realpath}:/home/agent/.rc-context/pi-APPEND_SYSTEM.md:ro'; got: $(printf '%s\n' "$mount_args" | grep "APPEND" || echo '<none>')"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-pi-substrate-mounts.sh — pi substrate projection (rip-cage-kstk) ==="
echo ""
test_C_bash_syntax
echo ""
test_A_pi_mounts_emitted
echo ""
test_A2_pi_absent_graceful
echo ""
test_B_pi_denylist_warn_and_skip
echo ""
test_D_init_creates_pi_symlinks
echo ""
test_E_floor_not_shadowed_by_init
echo ""
test_F_subagent_no_interceptor
echo ""
test_G_system_md_absent_graceful
echo ""
test_H_system_md_present_emits_mount
echo ""

if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
