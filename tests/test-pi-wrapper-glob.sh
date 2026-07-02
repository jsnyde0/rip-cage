#!/usr/bin/env bash
# test-pi-wrapper-glob.sh — verifies manifest launch_args assembly (rip-cage-l72i.1)
#
# Coverage (host-only, no Docker required):
#   (1) grep of pi-wrapper.sh source shows NO recipe-specific/path literals
#       (SUBAGENT_EXT, dcg-gate, /dcg/, herdr — generic shim invariant)
#   (2) _manifest_generate_launch_args assembles args from two fixture fragments
#       in fragment order (guard fragment first -> guard args first)
#   (3) --no-extensions appears in examples/dcg/manifest-fragment.yaml launch_args
#       field, NOT in the pi-wrapper.sh source
#   (4) composing WITHOUT the dcg fragment yields no --no-extensions in assembled args
#   (5) bash -n syntax check on pi-wrapper.sh, rc, and this test file itself

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
WRAPPER="${SCRIPT_DIR}/../examples/pi/pi-wrapper.sh"
PI_FRAGMENT="${SCRIPT_DIR}/../examples/pi/manifest-fragment.yaml"
DCG_FRAGMENT="${SCRIPT_DIR}/../examples/dcg/manifest-fragment.yaml"
FAILURES=0
TEST_TMPDIR=""

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # cleanup IS invoked via trap EXIT
cleanup() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# (1) pi-wrapper.sh source contains NO recipe-specific literals
# ---------------------------------------------------------------------------
test_1_wrapper_generic() {
  # The generic shim MUST NOT contain these literals (ADR-027 D4 FIRM principle)
  local found_literals
  found_literals=$(grep -E 'SUBAGENT_EXT|/etc/rip-cage/pi/dcg-gate|dcg-gate|herdr' "$WRAPPER" 2>/dev/null || true)

  if [[ -z "$found_literals" ]]; then
    pass "(1) pi-wrapper.sh source has NO recipe-specific literals (SUBAGENT_EXT/dcg-gate/herdr absent)"
  else
    fail "(1) pi-wrapper.sh source STILL contains recipe-specific literals — not a generic shim:"
    printf '  %s\n' "$found_literals"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# (2) _manifest_generate_launch_args assembles args in fragment order
# ---------------------------------------------------------------------------
test_2_assembly_ordering() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-launch-args-test-XXXXXX")

  # Write a tools.yaml that declares two fragments: guard first, ext second.
  # This tests that launch_args are concatenated IN FRAGMENT ORDER.
  mkdir -p "${TEST_TMPDIR}/home/.config/rip-cage"

  # Write the combined tools.yaml directly (avoid heredoc-inside-bash-c quoting issues)
  printf '%s\n' \
    'version: 1' \
    'tools:' \
    '  - name: guard-tool' \
    '    archetype: TOOL' \
    '    version_pin: "bundled-recipe"' \
    '    install_cmd: ": && echo guard"' \
    '    launch_args: ["--no-extensions", "-e", "/etc/rip-cage/pi/guard.ts"]' \
    '    egress: []' \
    '    mounts: []' \
    '  - name: ext-tool' \
    '    archetype: TOOL' \
    '    version_pin: "bundled-recipe"' \
    '    install_cmd: ": && echo ext"' \
    '    launch_args: ["-e", "/home/agent/.rc-context/ext/index.ts"]' \
    '    egress: []' \
    '    mounts: []' \
    > "${TEST_TMPDIR}/home/.config/rip-cage/tools.yaml"

  # Call the assembly function via rc (source it in a subshell)
  local assembled_args
  local exit_code=0
  assembled_args=$(
    XDG_CONFIG_HOME="${TEST_TMPDIR}/home/.config" \
    HOME="${TEST_TMPDIR}/home" \
    bash -c "source '$RC' 2>/dev/null || true; _manifest_generate_launch_args 2>/dev/null"
  ) || exit_code=$?

  # The assembled args should contain guard args BEFORE ext args (fragment order)
  if [[ -z "$assembled_args" ]]; then
    fail "(2) _manifest_generate_launch_args returned empty output (function absent or errored; exit=$exit_code)"
    return
  fi

  # Check guard args appear before ext args
  local guard_pos ext_pos
  guard_pos=$(printf '%s' "$assembled_args" | grep -n -- '--no-extensions' | head -1 | cut -d: -f1)
  ext_pos=$(printf '%s' "$assembled_args" | grep -n -- '/home/agent/.rc-context/ext/index.ts' | head -1 | cut -d: -f1)

  if [[ -n "$guard_pos" && -n "$ext_pos" && "$guard_pos" -lt "$ext_pos" ]]; then
    pass "(2) launch_args assembled in fragment order: guard args (line ${guard_pos}) before ext args (line ${ext_pos})"
  elif [[ -z "$guard_pos" ]]; then
    fail "(2) guard launch_args (--no-extensions) not found in assembled output"
  elif [[ -z "$ext_pos" ]]; then
    fail "(2) ext launch_args (-e /home/agent/.rc-context/ext) not found in assembled output"
  else
    fail "(2) guard args (line ${guard_pos}) appear AFTER ext args (line ${ext_pos}) — wrong fragment order"
  fi

  # Check all expected args are present
  if printf '%s' "$assembled_args" | grep -q -- '--no-extensions'; then
    pass "(2a) --no-extensions present in assembled output"
  else
    fail "(2a) --no-extensions missing from assembled output"
  fi

  if printf '%s' "$assembled_args" | grep -q -- '/etc/rip-cage/pi/guard.ts'; then
    pass "(2b) -e /etc/rip-cage/pi/guard.ts present in assembled output"
  else
    fail "(2b) -e /etc/rip-cage/pi/guard.ts missing from assembled output"
  fi

  if printf '%s' "$assembled_args" | grep -q -- '/home/agent/.rc-context/ext/index.ts'; then
    pass "(2c) -e /home/agent/.rc-context/ext/index.ts present in assembled output"
  else
    fail "(2c) -e /home/agent/.rc-context/ext/index.ts missing from assembled output"
  fi

  rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
}

# ---------------------------------------------------------------------------
# (3) DCG fragment's launch_args field ships OPEN by default (rip-cage-p35a.1 /
# ADR-027 D1, FIRM 2026-07-02): no --no-extensions in the actual launch_args
# value. Prose elsewhere in the fragment MAY still mention "--no-extensions"
# to document the LOCKED opt-in variant — this check targets the launch_args
# FIELD specifically (not a blanket file grep) so it isn't vacuously satisfied
# by that documentation text. Never in wrapper source either way.
# ---------------------------------------------------------------------------
test_3_no_extensions_in_dcg_fragment() {
  # The launch_args field itself must NOT declare --no-extensions (open default).
  local launch_args_line
  launch_args_line=$(grep -E '^\s*launch_args:' "$DCG_FRAGMENT" 2>/dev/null || true)

  if [[ -z "$launch_args_line" ]]; then
    fail "(3a) DCG fragment has no launch_args: field at all — expected -e dcg-gate.ts"
  elif printf '%s' "$launch_args_line" | grep -q -- '--no-extensions'; then
    fail "(3a) DCG fragment's launch_args FIELD contains --no-extensions — expected OPEN default (ADR-027 D1); got: ${launch_args_line}"
  else
    pass "(3a) DCG fragment's launch_args field does NOT contain --no-extensions (OPEN default, ADR-027 D1, FIRM)"
  fi

  # And confirm wrapper source does NOT contain --no-extensions (never baked there,
  # regardless of open/locked — it's a recipe-contributed launch_arg, not a wrapper literal).
  local wrapper_has_no_ext
  wrapper_has_no_ext=$(grep -E 'no-extensions' "$WRAPPER" 2>/dev/null || true)

  if [[ -z "$wrapper_has_no_ext" ]]; then
    pass "(3b) pi-wrapper.sh source does NOT contain --no-extensions (it's recipe-contributed via launch_args, not a wrapper literal)"
  else
    fail "(3b) pi-wrapper.sh STILL contains --no-extensions — should never be hardcoded in the generic wrapper"
  fi
}

# ---------------------------------------------------------------------------
# (4) Composing WITHOUT DCG fragment yields no --no-extensions
# ---------------------------------------------------------------------------
test_4_no_dcg_no_no_extensions() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-launch-args-nodcg-XXXXXX")

  # Fragment with only a non-DCG extension (no --no-extensions)
  mkdir -p "${TEST_TMPDIR}/home/.config/rip-cage"
  printf '%s\n' \
    'version: 1' \
    'tools:' \
    '  - name: ext-only-tool' \
    '    archetype: TOOL' \
    '    version_pin: "bundled-recipe"' \
    '    install_cmd: ": && echo ext"' \
    '    launch_args: ["-e", "/home/agent/.rc-context/ext/index.ts"]' \
    '    egress: []' \
    '    mounts: []' \
    > "${TEST_TMPDIR}/home/.config/rip-cage/tools.yaml"

  local assembled_args
  local exit_code=0
  assembled_args=$(
    XDG_CONFIG_HOME="${TEST_TMPDIR}/home/.config" \
    HOME="${TEST_TMPDIR}/home" \
    bash -c "source '$RC' 2>/dev/null || true; _manifest_generate_launch_args 2>/dev/null"
  ) || exit_code=$?

  if printf '%s' "$assembled_args" | grep -q -- '--no-extensions'; then
    fail "(4) --no-extensions present when composing WITHOUT DCG fragment — should be absent"
  else
    pass "(4) no --no-extensions when composing without DCG fragment (pi auto-discovers normally)"
  fi

  rm -rf "$TEST_TMPDIR"
  TEST_TMPDIR=""
}

# ---------------------------------------------------------------------------
# (5) bash -n syntax checks
# ---------------------------------------------------------------------------
test_5_syntax_checks() {
  local exit_rc=0
  bash -n "$RC" 2>/dev/null || exit_rc=$?
  if [[ "$exit_rc" -eq 0 ]]; then
    pass "(5a) bash -n rc: no syntax errors"
  else
    fail "(5a) bash -n rc: syntax error (exit=$exit_rc)"
  fi

  local exit_wrapper=0
  bash -n "$WRAPPER" 2>/dev/null || exit_wrapper=$?
  if [[ "$exit_wrapper" -eq 0 ]]; then
    pass "(5b) bash -n pi-wrapper.sh: no syntax errors"
  else
    fail "(5b) bash -n pi-wrapper.sh: syntax error (exit=$exit_wrapper)"
  fi

  local exit_self=0
  bash -n "${BASH_SOURCE[0]}" 2>/dev/null || exit_self=$?
  if [[ "$exit_self" -eq 0 ]]; then
    pass "(5c) bash -n test-pi-wrapper-glob.sh: no syntax errors"
  else
    fail "(5c) bash -n test-pi-wrapper-glob.sh: syntax error (exit=$exit_self)"
  fi
}

# ---------------------------------------------------------------------------
# (6) DCG fragment declares launch_args field (structural check)
# ---------------------------------------------------------------------------
test_6_dcg_declares_launch_args() {
  if grep -q 'launch_args' "$DCG_FRAGMENT" 2>/dev/null; then
    pass "(6) DCG fragment contains launch_args field"
  else
    fail "(6) DCG fragment does NOT contain launch_args field — relocation not done"
  fi

  # Also: DCG fragment must declare the dcg-gate.ts path in launch_args
  if grep -E 'launch_args.*dcg-gate|dcg-gate.*launch_args|-e.*dcg-gate' "$DCG_FRAGMENT" 2>/dev/null | grep -q '.'; then
    pass "(6b) DCG fragment launch_args references dcg-gate.ts path"
  else
    # Check if launch_args and dcg-gate appear near each other in the yaml
    if grep -q 'dcg-gate' "$DCG_FRAGMENT" 2>/dev/null && grep -q 'launch_args' "$DCG_FRAGMENT" 2>/dev/null; then
      pass "(6b) DCG fragment has both launch_args field and dcg-gate.ts reference"
    else
      fail "(6b) DCG fragment launch_args does not reference dcg-gate.ts path"
    fi
  fi
}

# ---------------------------------------------------------------------------
# (7) Pi recipe install_cmd no longer bakes dcg-gate.ts
# ---------------------------------------------------------------------------
test_7_pi_recipe_no_dcg_gate() {
  # The pi recipe's install_cmd should NOT bake dcg-gate.ts
  # (it has been relocated to the DCG fragment — rip-cage-l72i.1)
  # Check install_cmd field specifically (grep for base64 blob or dcg-gate in install_cmd line)
  local install_cmd_line
  install_cmd_line=$(grep 'install_cmd:' "$PI_FRAGMENT" 2>/dev/null || true)

  if printf '%s' "$install_cmd_line" | grep -q 'dcg-gate'; then
    fail "(7) pi manifest-fragment.yaml install_cmd STILL bakes dcg-gate.ts — should be relocated to DCG fragment"
  else
    pass "(7) pi manifest-fragment.yaml install_cmd does NOT bake dcg-gate.ts (correctly relocated to DCG fragment)"
  fi
}

# ---------------------------------------------------------------------------
# (8) _manifest_generate_pi_shim_steps with guard+ext fragments:
#     generated Dockerfile step bakes ASSEMBLED_ARGS in fragment order
# ---------------------------------------------------------------------------
test_8_shim_steps_with_guard() {
  local test_tmpdir
  test_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-pi-shim-steps-XXXXXX")

  mkdir -p "${test_tmpdir}/home/.config/rip-cage"
  # Two fragments: guard (declares --no-extensions + -e guard.ts) then ext (declares -e ext.ts)
  printf '%s\n' \
    'version: 1' \
    'tools:' \
    '  - name: guard-tool' \
    '    archetype: TOOL' \
    '    version_pin: "bundled-recipe"' \
    '    install_cmd: ": && echo guard"' \
    '    launch_args: ["--no-extensions", "-e", "/etc/rip-cage/pi/guard.ts"]' \
    '    egress: []' \
    '    mounts: []' \
    '  - name: ext-tool' \
    '    archetype: TOOL' \
    '    version_pin: "bundled-recipe"' \
    '    install_cmd: ": && echo ext"' \
    '    launch_args: ["-e", "/home/agent/.rc-context/ext/index.ts"]' \
    '    egress: []' \
    '    mounts: []' \
    > "${test_tmpdir}/home/.config/rip-cage/tools.yaml"

  local shim_steps
  local exit_code=0
  shim_steps=$(
    XDG_CONFIG_HOME="${test_tmpdir}/home/.config" \
    HOME="${test_tmpdir}/home" \
    bash -c "source '$RC' 2>/dev/null || true; _manifest_generate_pi_shim_steps '$WRAPPER' 2>/dev/null"
  ) || exit_code=$?

  if [[ -z "$shim_steps" ]]; then
    fail "(8) _manifest_generate_pi_shim_steps returned empty (function absent or errored; exit=$exit_code)"
    rm -rf "$test_tmpdir"
    return
  fi

  # Must contain a RUN step that writes /usr/local/bin/pi
  if printf '%s' "$shim_steps" | grep -q '/usr/local/bin/pi'; then
    pass "(8a) shim Dockerfile step writes /usr/local/bin/pi"
  else
    fail "(8a) shim Dockerfile step does NOT write /usr/local/bin/pi"
  fi

  # Must set root:root 0755
  if printf '%s' "$shim_steps" | grep -q 'chown root:root'; then
    pass "(8b) shim Dockerfile step sets root:root ownership"
  else
    fail "(8b) shim Dockerfile step does NOT set root:root"
  fi

  if printf '%s' "$shim_steps" | grep -q '0755'; then
    pass "(8c) shim Dockerfile step sets 0755 permissions"
  else
    fail "(8c) shim Dockerfile step does NOT set 0755"
  fi

  # The baked wrapper must contain ASSEMBLED_ARGS with guard args first, then ext args.
  # Decode the base64 payload in the step and inspect it.
  local b64_payload
  b64_payload=$(printf '%s' "$shim_steps" | grep -o '[A-Za-z0-9+/=]\{40,\}' | head -1)
  if [[ -z "$b64_payload" ]]; then
    fail "(8d) no base64 payload found in shim Dockerfile step"
    rm -rf "$test_tmpdir"
    return
  fi

  local decoded_wrapper
  decoded_wrapper=$(printf '%s' "$b64_payload" | base64 -d 2>/dev/null)
  if [[ -z "$decoded_wrapper" ]]; then
    fail "(8d) base64 decode of shim payload failed"
    rm -rf "$test_tmpdir"
    return
  fi
  pass "(8d) shim payload base64-decodes successfully"

  # bash -n the decoded wrapper: a mis-quoted arg that produces a syntax error must fail here
  local bash_n_exit=0
  bash -n <(printf '%s' "$decoded_wrapper") 2>/dev/null || bash_n_exit=$?
  if [[ "$bash_n_exit" -eq 0 ]]; then
    pass "(8d2) bash -n on decoded shim wrapper: no syntax errors"
  else
    fail "(8d2) bash -n on decoded shim wrapper: SYNTAX ERROR (exit=${bash_n_exit}) — arg quoting may be broken"
  fi

  # Check ASSEMBLED_ARGS contains guard args (--no-extensions, -e /etc/rip-cage/pi/guard.ts)
  if printf '%s' "$decoded_wrapper" | grep -q -- '--no-extensions'; then
    pass "(8e) decoded shim wrapper contains --no-extensions (guard arg)"
  else
    fail "(8e) decoded shim wrapper does NOT contain --no-extensions — guard args missing"
  fi

  if printf '%s' "$decoded_wrapper" | grep -q '/etc/rip-cage/pi/guard.ts'; then
    pass "(8f) decoded shim wrapper contains /etc/rip-cage/pi/guard.ts (guard extension)"
  else
    fail "(8f) decoded shim wrapper does NOT contain /etc/rip-cage/pi/guard.ts"
  fi

  # Check ASSEMBLED_ARGS contains ext args (-e /home/agent/.rc-context/ext/index.ts)
  if printf '%s' "$decoded_wrapper" | grep -q '/home/agent/.rc-context/ext/index.ts'; then
    pass "(8g) decoded shim wrapper contains /home/agent/.rc-context/ext/index.ts (ext arg)"
  else
    fail "(8g) decoded shim wrapper does NOT contain /home/agent/.rc-context/ext/index.ts"
  fi

  # Guard args must appear before ext args (fragment order preserved)
  # Args may be on the same ASSEMBLED_ARGS line, so check string position within that line
  local assembled_line
  assembled_line=$(printf '%s' "$decoded_wrapper" | grep 'ASSEMBLED_ARGS=' | head -1)
  local guard_str="--no-extensions"
  local ext_str="/home/agent/.rc-context/ext/index.ts"
  # Use parameter expansion to find position: strip from guard/ext onwards and measure length
  local prefix_to_guard="${assembled_line%%"$guard_str"*}"
  local prefix_to_ext="${assembled_line%%"$ext_str"*}"

  if [[ "$prefix_to_guard" == "$assembled_line" || "$prefix_to_ext" == "$assembled_line" ]]; then
    fail "(8h) could not verify fragment order (one or both args not found in ASSEMBLED_ARGS line)"
  elif [[ "${#prefix_to_guard}" -lt "${#prefix_to_ext}" ]]; then
    pass "(8h) fragment order preserved: guard args (col ${#prefix_to_guard}) before ext args (col ${#prefix_to_ext}) in ASSEMBLED_ARGS"
  else
    fail "(8h) guard args appear AFTER ext args in ASSEMBLED_ARGS — wrong fragment order"
  fi

  rm -rf "$test_tmpdir"
}

# ---------------------------------------------------------------------------
# (9) _manifest_generate_pi_shim_steps WITHOUT any launch_args:
#     generated wrapper has ASSEMBLED_ARGS=() (empty — pi auto-discovers)
# ---------------------------------------------------------------------------
test_9_shim_steps_no_launch_args() {
  local test_tmpdir
  test_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-pi-shim-empty-XXXXXX")

  mkdir -p "${test_tmpdir}/home/.config/rip-cage"
  # Fragment with NO launch_args field (pi auto-discovers)
  printf '%s\n' \
    'version: 1' \
    'tools:' \
    '  - name: plain-tool' \
    '    archetype: TOOL' \
    '    version_pin: "bundled-recipe"' \
    '    install_cmd: ": && echo plain"' \
    '    egress: []' \
    '    mounts: []' \
    > "${test_tmpdir}/home/.config/rip-cage/tools.yaml"

  local shim_steps
  local exit_code=0
  shim_steps=$(
    XDG_CONFIG_HOME="${test_tmpdir}/home/.config" \
    HOME="${test_tmpdir}/home" \
    bash -c "source '$RC' 2>/dev/null || true; _manifest_generate_pi_shim_steps '$WRAPPER' 2>/dev/null"
  ) || exit_code=$?

  if [[ -z "$shim_steps" ]]; then
    fail "(9) _manifest_generate_pi_shim_steps returned empty when no launch_args (function absent or errored; exit=$exit_code)"
    rm -rf "$test_tmpdir"
    return
  fi

  # Decode the payload and confirm ASSEMBLED_ARGS=() (empty)
  local b64_payload
  b64_payload=$(printf '%s' "$shim_steps" | grep -o '[A-Za-z0-9+/=]\{40,\}' | head -1)
  if [[ -z "$b64_payload" ]]; then
    fail "(9a) no base64 payload found in shim Dockerfile step (empty-args case)"
    rm -rf "$test_tmpdir"
    return
  fi

  local decoded_wrapper
  decoded_wrapper=$(printf '%s' "$b64_payload" | base64 -d 2>/dev/null)
  if printf '%s' "$decoded_wrapper" | grep -qE 'ASSEMBLED_ARGS=\(\)'; then
    pass "(9) no launch_args → decoded shim wrapper has ASSEMBLED_ARGS=() (pi auto-discovers)"
  else
    # Check if ASSEMBLED_ARGS is present but non-empty
    local assembled_line
    assembled_line=$(printf '%s' "$decoded_wrapper" | grep 'ASSEMBLED_ARGS' | head -1)
    fail "(9) no launch_args → expected ASSEMBLED_ARGS=() in decoded wrapper but got: ${assembled_line}"
  fi

  # bash -n the decoded wrapper (empty-args case must also be syntactically valid)
  local bash_n_exit=0
  bash -n <(printf '%s' "$decoded_wrapper") 2>/dev/null || bash_n_exit=$?
  if [[ "$bash_n_exit" -eq 0 ]]; then
    pass "(9b) bash -n on decoded shim wrapper (empty-args): no syntax errors"
  else
    fail "(9b) bash -n on decoded shim wrapper (empty-args): SYNTAX ERROR (exit=${bash_n_exit})"
  fi

  rm -rf "$test_tmpdir"
}

# ---------------------------------------------------------------------------
# (10) Quoting-contract fixture: args with spaces and $(...) round-trip literally;
#      command substitution does NOT execute.
# ---------------------------------------------------------------------------
test_10_quoting_contract() {
  local test_tmpdir
  test_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-pi-quote-XXXXXX")

  local pwned_sentinel="${test_tmpdir}/PWNED"

  mkdir -p "${test_tmpdir}/home/.config/rip-cage"
  # launch_args with:
  #   (a) an arg containing a space:        "/tmp/path with space/ext.ts"
  #   (b) an arg containing $(...):         "/tmp/o'brien-$(touch ${pwned_sentinel})-x.ts"
  # The $(...) MUST NOT execute when the wrapper is sourced.
  local space_arg="/tmp/path with space/ext.ts"
  local subst_arg="/tmp/o'brien-\$(touch ${pwned_sentinel})-x.ts"
  printf '%s\n' \
    'version: 1' \
    'tools:' \
    '  - name: tricky-tool' \
    '    archetype: TOOL' \
    '    version_pin: "bundled-recipe"' \
    '    install_cmd: ": && echo tricky"' \
    "    launch_args: [\"-e\", \"${space_arg}\", \"-e\", \"${subst_arg}\"]" \
    '    egress: []' \
    '    mounts: []' \
    > "${test_tmpdir}/home/.config/rip-cage/tools.yaml"

  local shim_steps
  local exit_code=0
  shim_steps=$(
    XDG_CONFIG_HOME="${test_tmpdir}/home/.config" \
    HOME="${test_tmpdir}/home" \
    bash -c "source '$RC' 2>/dev/null || true; _manifest_generate_pi_shim_steps '$WRAPPER' 2>/dev/null"
  ) || exit_code=$?

  if [[ -z "$shim_steps" ]]; then
    fail "(10) _manifest_generate_pi_shim_steps returned empty for quoting fixture (exit=$exit_code)"
    rm -rf "$test_tmpdir"
    return
  fi

  # Decode
  local b64_payload
  b64_payload=$(printf '%s' "$shim_steps" | grep -o '[A-Za-z0-9+/=]\{40,\}' | head -1)
  if [[ -z "$b64_payload" ]]; then
    fail "(10) no base64 payload in shim step (quoting fixture)"
    rm -rf "$test_tmpdir"
    return
  fi

  local decoded_wrapper
  decoded_wrapper=$(printf '%s' "$b64_payload" | base64 -d 2>/dev/null)

  # (10a) bash -n: decoded wrapper must be syntactically valid
  local bash_n_exit=0
  bash -n <(printf '%s' "$decoded_wrapper") 2>/dev/null || bash_n_exit=$?
  if [[ "$bash_n_exit" -eq 0 ]]; then
    pass "(10a) bash -n on quoting-fixture decoded wrapper: syntactically valid"
  else
    fail "(10a) bash -n on quoting-fixture decoded wrapper: SYNTAX ERROR (exit=${bash_n_exit}) — quoting broke the output"
  fi

  # (10b) Source ONLY the ASSEMBLED_ARGS=(...) line in a clean bash -c;
  #       assert element count and literal values round-trip correctly.
  #       The $(...) in the arg must NOT execute (PWNED file must not appear).
  local assembled_line
  assembled_line=$(printf '%s' "$decoded_wrapper" | grep 'ASSEMBLED_ARGS=')
  if [[ -z "$assembled_line" ]]; then
    fail "(10b) ASSEMBLED_ARGS line not found in quoting-fixture decoded wrapper"
    rm -rf "$test_tmpdir"
    return
  fi

  # Run ASSEMBLED_ARGS assignment + element-count check in a clean subshell (no exec)
  # shellcheck disable=SC2016  # we intentionally pass unexpanded $(...) text
  local sourced_count
  sourced_count=$(bash -c "${assembled_line}"$'\n''printf "%d\n" "${#ASSEMBLED_ARGS[@]}"' 2>/dev/null) || true

  # Expected: 4 elements (-e, space-arg, -e, subst-arg)
  if [[ "$sourced_count" -eq 4 ]]; then
    pass "(10b) ASSEMBLED_ARGS element count round-trips correctly (4 elements)"
  else
    fail "(10b) ASSEMBLED_ARGS element count wrong: expected 4, got '${sourced_count:-EMPTY/ERROR}'"
  fi

  # (10c) $(...) in the arg must NOT have executed (PWNED file absent)
  if [[ ! -f "$pwned_sentinel" ]]; then
    pass "(10c) command substitution in launch_arg did NOT execute during bake/decode/source (PWNED absent)"
  else
    fail "(10c) SECURITY: command substitution EXECUTED — PWNED file created at ${pwned_sentinel}"
    rm -f "$pwned_sentinel"
  fi

  # (10d) The space-containing arg must survive literally (element 2 == space-arg)
  local sourced_elem1
  sourced_elem1=$(bash -c "${assembled_line}"$'\n''printf "%s\n" "${ASSEMBLED_ARGS[1]}"' 2>/dev/null) || true
  if [[ "$sourced_elem1" == "$space_arg" ]]; then
    pass "(10d) space-containing arg survives literally as array element: '${sourced_elem1}'"
  else
    fail "(10d) space-containing arg mangled: expected '${space_arg}', got '${sourced_elem1:-EMPTY}'"
  fi

  rm -rf "$test_tmpdir"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-pi-wrapper-glob.sh — manifest launch_args assembly (rip-cage-l72i.1) ==="
echo ""
test_5_syntax_checks
echo ""
test_1_wrapper_generic
echo ""
test_3_no_extensions_in_dcg_fragment
echo ""
test_6_dcg_declares_launch_args
echo ""
test_7_pi_recipe_no_dcg_gate
echo ""
test_2_assembly_ordering
echo ""
test_4_no_dcg_no_no_extensions
echo ""
test_8_shim_steps_with_guard
echo ""
test_9_shim_steps_no_launch_args
echo ""
test_10_quoting_contract
echo ""

if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
