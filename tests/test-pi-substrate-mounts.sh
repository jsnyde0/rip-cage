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
#        symlink (floor-shadow check: no bare extensions/ ln -sfn); and
#        pi-wrapper.sh is the generic shim (no recipe-specific literals hardcoded)
#   (I)  examples/pi/subagent-fragment.yaml exists with correct manifest-declared
#        structure (launch_args -e, rc-context path, no baked source)
#   (J)  init-rip-cage.sh does NOT contain stale 'loaded by wrapper via -e' claim
#
# Tests call _up_prepare_docker_mounts directly in a subshell (the same
# pattern used by test-secret-path-denylist.sh test_bprime) — no Docker needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
INIT="${SCRIPT_DIR}/../init-rip-cage.sh"
WRAPPER="${SCRIPT_DIR}/../examples/pi/pi-wrapper.sh"
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

  # --- No subagent extension in rc's special-case table (rip-cage-l72i.3) ---
  # After the migration, rc no longer has a hardcoded 'extensions/subagent' entry.
  # The subagent mount is now fragment-declared (see test_A3). This rc path should
  # emit ONLY the instruction-content assets (skills/prompts/roles/AGENTS.md/etc).
  if printf '%s\n' "$mount_args" | grep -q "pi-ext-subagent"; then
    fail "(A) pi-ext-subagent mount unexpectedly emitted by rc special-case (should be fragment-declared only)"
  else
    pass "(A) pi-ext-subagent NOT emitted by rc's pi substrate table (removed per rip-cage-l72i.3)"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (A3) Fragment-declared subagent mount: when the subagent fragment is composed
#      AND the host has the extension dir, mount is emitted via manifest mechanism
# ---------------------------------------------------------------------------
test_A3_subagent_fragment_mount() {
  setup_sandbox

  # Create a tools.yaml in the sandbox that includes the subagent fragment.
  # This causes _manifest_build_mount_args to emit the subagent mount.
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: pi-subagent
    archetype: TOOL
    version_pin: "bundled-recipe"
    install_cmd: ":"
    egress: []
    mounts:
      - host: "~/.pi/agent/extensions/subagent"
        dest: "/home/agent/.rc-context/pi-ext-subagent"
        mode: ro
    launch_args: ["-e", "/home/agent/.rc-context/pi-ext-subagent/index.ts"]
YAML

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

  local subagent_realpath
  subagent_realpath=$(realpath "${TEST_HOME}/.pi/agent/extensions/subagent" 2>/dev/null || echo "${TEST_HOME}/.pi/agent/extensions/subagent")

  # The fragment mount (~/.pi/agent/extensions/subagent -> /home/agent/.rc-context/pi-ext-subagent)
  # should be emitted via the manifest mechanism.
  if printf '%s\n' "$mount_args" | grep -q "${subagent_realpath}:/home/agent/.rc-context/pi-ext-subagent:ro"; then
    pass "(A3) subagent mount emitted via fragment-declared mounts (manifest mechanism)"
  else
    fail "(A3) subagent mount missing; expected '${subagent_realpath}:/home/agent/.rc-context/pi-ext-subagent:ro' from fragment; got: $(printf '%s\n' "$mount_args" | grep -i "ext-sub\|subagent\|extensions" || echo '<none>')"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# (A4) Fragment-declared subagent mount skips gracefully when host ext is absent
# ---------------------------------------------------------------------------
test_A4_subagent_fragment_absent_graceful() {
  setup_sandbox

  # Same tools.yaml with subagent fragment, but NO extensions/subagent on host.
  local NOEXT_HOME="${TEST_TMPDIR}/home_noext"
  mkdir -p "${NOEXT_HOME}/.config/rip-cage"
  cp "${TEST_HOME}/.config/rip-cage/config.yaml" "${NOEXT_HOME}/.config/rip-cage/config.yaml"
  # Create .pi/agent WITHOUT extensions/subagent
  mkdir -p "${NOEXT_HOME}/.pi/agent/skills"
  touch "${NOEXT_HOME}/.pi/agent/skills/skill.md"
  # tools.yaml with subagent fragment
  cat > "${NOEXT_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: pi-subagent
    archetype: TOOL
    version_pin: "bundled-recipe"
    install_cmd: ":"
    egress: []
    mounts:
      - host: "~/.pi/agent/extensions/subagent"
        dest: "/home/agent/.rc-context/pi-ext-subagent"
        mode: ro
    launch_args: ["-e", "/home/agent/.rc-context/pi-ext-subagent/index.ts"]
YAML

  local exit_code=0
  bash -c "
    source '$RC' 2>/dev/null
    _UP_RUN_ARGS=()
    wt_detected=false
    HOME='$NOEXT_HOME' XDG_CONFIG_HOME='${NOEXT_HOME}/.config' \
    _up_prepare_docker_mounts '$TEST_WS' 'test-container' 2>/dev/null
  " 2>/dev/null || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "(A4) rc up succeeds when fragment composed but extensions/subagent absent (skip-if-host-missing)"
  else
    fail "(A4) rc up failed when extensions/subagent absent — should be graceful (exit=${exit_code})"
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
  # RC_CONFIG_GLOBAL is overridden here to the sandbox config (which has .aws in
  # the denylist). Without this, run-host.sh's driver-level empty-denylist fixture
  # (RC_CONFIG_GLOBAL → /tmp/.../rip-cage/config.yaml) would take precedence and
  # suppress the warn-and-skip we're testing. (See: test-secret-path-denylist.sh
  # top-level `unset RC_CONFIG_GLOBAL` for the same pattern.)
  stderr_out=$(
    HOME="$resolved_home" \
    XDG_CONFIG_HOME="${resolved_home}/.config" \
    RC_CONFIG_GLOBAL="${resolved_home}/.config/rip-cage/config.yaml" \
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

  # Verify pi-skills is still referenced (core substrate asset)
  if grep -q "pi-skills" "$INIT"; then
    pass "(D) init-rip-cage.sh references pi-skills (core substrate asset)"
  else
    fail "(D) init-rip-cage.sh missing pi-skills reference"
  fi
}

# ---------------------------------------------------------------------------
# (E) Floor invariant: guard on its own root-owned path, not in extensions/;
#     pi-wrapper.sh is the generic shim (no recipe-specific wiring hardcoded)
# ---------------------------------------------------------------------------
test_E_floor_not_shadowed_by_init() {
  # Negative control: init-rip-cage.sh DOES NOT contain a pattern like:
  #   ln -sfn ... ~/.pi/agent/extensions
  # which would replace the entire baked extensions dir.
  # (post-wlwc: no extensions/ symlink at all — wrapper owns the wiring)

  if grep -qE "ln -sfn.*extensions[^/]" "$INIT"; then
    fail "(E) init-rip-cage.sh may replace whole extensions/ dir — floor-shadow risk"
  else
    pass "(E) init-rip-cage.sh does not replace whole extensions/ dir (floor protected)"
  fi

  # Floor reasoning (ADR-027 D3/D4): the DCG guard lives at /etc/rip-cage/pi/dcg-gate.ts
  # (root-owned, separate from extensions/). Mounting anything into extensions/ or
  # rc-context/pi-ext-subagent CANNOT shadow the guard because:
  #   (a) the guard is not in extensions/ anymore (relocated to its own root-owned path)
  #   (b) --no-extensions (contributed by DCG fragment) disables pi auto-discovery of extensions/
  #   (c) guard is loaded via explicit -e /etc/rip-cage/pi/dcg-gate.ts (build-time artifact)
  # Verify the subagent fragment does NOT declare a mount dest over the guard's path.
  local guard_path_prefix="/etc/rip-cage/pi"
  if [[ -f "${SUBAGENT_FRAGMENT}" ]]; then
    if grep -q "${guard_path_prefix}" "${SUBAGENT_FRAGMENT}"; then
      fail "(E-fs) subagent fragment declares a mount dest overlapping the guard's root-owned path (${guard_path_prefix}) — floor-shadow risk"
    else
      pass "(E-fs) subagent fragment does NOT mount into guard's root-owned path (${guard_path_prefix}) — floor protected by separate-path model"
    fi
  else
    pass "(E-fs) subagent fragment absent — skip floor-shadow check"
  fi

  # Positive control (rip-cage-l72i.1): pi-wrapper.sh is the generic shim.
  # It MUST NOT contain recipe-specific literals (ADR-027 D4 FIRM principle).
  # Extension wiring (--no-extensions, -e dcg-gate.ts, subagent ext) is now
  # declared in manifest launch_args and assembled by rc build, NOT hardcoded.
  local wrapper_literals
  wrapper_literals=$(grep -E 'SUBAGENT_EXT|dcg-gate|/dcg/|herdr' "$WRAPPER" 2>/dev/null || true)
  if [[ -z "$wrapper_literals" ]]; then
    pass "(E) pi-wrapper.sh is the generic shim (no recipe-specific literals hardcoded)"
  else
    fail "(E) pi-wrapper.sh STILL contains recipe-specific literals — not a generic shim:
  ${wrapper_literals}"
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
# (I) subagent recipe fragment exists with correct manifest-declared structure
#     (rip-cage-l72i.3: subagent migrated onto manifest-declared mechanism)
# ---------------------------------------------------------------------------
SUBAGENT_FRAGMENT="${SCRIPT_DIR}/../examples/pi/subagent-fragment.yaml"
test_I_subagent_fragment_exists() {
  # (I-1) The fragment file exists
  if [[ -f "$SUBAGENT_FRAGMENT" ]]; then
    pass "(I-1) examples/pi/subagent-fragment.yaml exists"
  else
    fail "(I-1) examples/pi/subagent-fragment.yaml missing — subagent must be declared as a recipe fragment"
    return
  fi

  # (I-2) The fragment declares launch_args with -e pointing to the rc-context path
  if grep -q "\-e" "$SUBAGENT_FRAGMENT" && grep -q "pi-ext-subagent" "$SUBAGENT_FRAGMENT"; then
    pass "(I-2) subagent-fragment.yaml declares launch_args with -e and pi-ext-subagent path"
  else
    fail "(I-2) subagent-fragment.yaml missing launch_args -e declaration for pi-ext-subagent; got: $(grep -E 'launch_args|-e|pi-ext' "$SUBAGENT_FRAGMENT" || echo '<none>')"
  fi

  # (I-3) The fragment documents the runtime ro mount (host-projected via rc up).
  # NOTE: the manifest mounts[] is empty (Dockerfile-level mounts: none needed).
  # The ro mount at /home/agent/.rc-context/pi-ext-subagent is emitted at rc up
  # time by _up_prepare_docker_mounts. The fragment documents this in comments.
  if grep -q "pi-ext-subagent" "$SUBAGENT_FRAGMENT" && grep -q "rc-context" "$SUBAGENT_FRAGMENT"; then
    pass "(I-3) subagent-fragment.yaml documents the rc-context ro-mount path for pi-ext-subagent"
  else
    fail "(I-3) subagent-fragment.yaml missing rc-context/pi-ext-subagent path documentation; got: $(grep -E 'mount|rc-context|pi-ext' "$SUBAGENT_FRAGMENT" || echo '<none>')"
  fi

  # (I-4) The fragment does NOT bake the subagent source itself (it's host-projected, not baked)
  if ! grep -q "base64\|install_cmd.*subagent" "$SUBAGENT_FRAGMENT"; then
    pass "(I-4) subagent-fragment.yaml does not bake subagent source (host-projected ro mount)"
  else
    fail "(I-4) subagent-fragment.yaml should not bake the subagent source (it is host-projected)"
  fi

  # (I-5) YAML syntax: fragment must be parseable (use python3 yaml if available)
  local yaml_available=false
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import yaml" 2>/dev/null; then
      yaml_available=true
    fi
  fi
  if [[ "$yaml_available" == "true" ]]; then
    local yaml_err
    yaml_err=$(python3 -c "import yaml, sys; yaml.safe_load(open('$SUBAGENT_FRAGMENT'))" 2>&1)
    if [[ -z "$yaml_err" ]]; then
      pass "(I-5) subagent-fragment.yaml is valid YAML"
    else
      fail "(I-5) subagent-fragment.yaml YAML parse error: ${yaml_err}"
    fi
  else
    pass "(I-5) python3/yaml absent — skipping YAML syntax check"
  fi
}

# ---------------------------------------------------------------------------
# (J) init-rip-cage.sh does NOT contain the stale 'loaded by wrapper via -e'
#     claim (rip-cage-l72i.3: init comment must reflect manifest-declared reality)
# ---------------------------------------------------------------------------
test_J_init_comment_updated() {
  # The old comment asserted "loaded by wrapper via -e" — stale post-l72i.1.
  # After l72i.3, the subagent is declared in the pi/subagent recipe fragment's
  # launch_args and loaded by the manifest-assembled shim — not by a wrapper slot.
  if grep -q "loaded by wrapper via -e" "$INIT"; then
    fail "(J) init-rip-cage.sh still contains stale 'loaded by wrapper via -e' comment — update to reflect manifest-declared reality"
  else
    pass "(J) init-rip-cage.sh: stale 'loaded by wrapper via -e' claim absent (comment updated)"
  fi

  # The init region should still reference pi-ext-subagent (the mount path)
  # so the reader knows what path the runtime mount projects to.
  if grep -q "pi-ext-subagent" "$INIT"; then
    pass "(J) init-rip-cage.sh still references pi-ext-subagent (mount path documentation present)"
  else
    fail "(J) init-rip-cage.sh missing pi-ext-subagent reference — should document the fragment-declared mount path"
  fi
}

# ---------------------------------------------------------------------------
# (K) rc does NOT name 'subagent' anywhere (ADR-005 D12: no tool-specific
#     special-cases in rc source — rip-cage-l72i.3 removes the rc special-case)
# ---------------------------------------------------------------------------
test_K_rc_no_subagent_naming() {
  # grep -ni subagent rc should return empty.
  # This mirrors the accepted "grep -ri herdr rc → empty" invariant.
  local subagent_hits
  subagent_hits=$(grep -ni "subagent" "$RC" 2>/dev/null || true)
  if [[ -z "$subagent_hits" ]]; then
    pass "(K) grep -ni subagent rc: empty (rc no longer names subagent — ADR-005 D12)"
  else
    fail "(K) rc STILL contains 'subagent' references — must be removed per ADR-005 D12:
$(echo "$subagent_hits" | head -10)"
  fi
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
test_A3_subagent_fragment_mount
echo ""
test_A4_subagent_fragment_absent_graceful
echo ""
test_I_subagent_fragment_exists
echo ""
test_J_init_comment_updated
echo ""
test_K_rc_no_subagent_naming
echo ""

if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
