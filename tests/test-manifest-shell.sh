#!/usr/bin/env bash
# Host-side + e2e tests for SHELL-INTEGRATION archetype shell_init eval-line baking (rip-cage-4c5.4).
# ADR-005 D7 (SHELL-INTEGRATION archetype = one shell_init field; install=build-time).
#
# Test tiers:
#
#   T1  (fast, host-only) — The generated Dockerfile steps contain a
#       `echo ... >> /home/agent/.zshrc` RUN step for the eval line when a
#       SHELL-INTEGRATION entry is present; ABSENT when no such entry exists.
#       No docker build needed. Positive-sentinel discipline: first prove the
#       WITH-entry case produces output, THEN assert the WITHOUT case is absent.
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1) — Build a cage image WITH a
#       SHELL-INTEGRATION entry (using a fixture whose binary is already in
#       the base image), then docker exec zsh -lic to prove the hook fires.
#       Counterfactual: build WITHOUT the entry, confirm the eval line is absent
#       from .zshrc.
#
# Positive-sentinel discipline (rip-cage-test-fail-prose-without-exit-silent-red):
#   Every failure increments FAILURES.
#   Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   Absence assertions are GATED on a positive sentinel proving the WITH-entry
#   generator actually produced output (so an empty/erroring generator cannot
#   false-green the absence half).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures"
FAILURES=0
TEST_HOME=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Build a sandbox HOME for manifest tests.
setup_manifest_sandbox() {
  local fixture="${1:-}"
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-shell-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_generate_shell_init_zshrc_steps in the sandbox.
# Outputs the generated Dockerfile fragment (RUN echo ... >> .zshrc) to stdout.
run_manifest_generate_shell_init_steps() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_shell_init_zshrc_steps" 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# T1a — WITH scratch SHELL-INTEGRATION entry: generated steps contain eval line
# ---------------------------------------------------------------------------
test_t1a_with_shell_integration_steps_present() {
  setup_manifest_sandbox "manifest-with-shell-integration.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_shell_init_steps "$stderr_file") || exit_code=$?
  # Positive sentinel: the generated step must encode the eval line via base64.
  # With base64-safe baking (Fix 1), the raw eval string is not embedded verbatim;
  # instead we verify that the base64 payload in the step decodes to the expected line.
  # SC2016 intentional: we want the literal string 'eval "$(fake-tool init zsh)"' for grep.
  # shellcheck disable=SC2016
  local expected_eval='eval "$(fake-tool init zsh)"'
  # Extract the base64 payload from the step (single-quoted echo arg before '| base64 -d')
  local b64_payload decoded
  b64_payload=$(echo "$out" | grep -o "'[A-Za-z0-9+/=]*'" | tr -d "'" | head -1)
  decoded=$(echo "$b64_payload" | base64 -d 2>/dev/null) || true
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "base64" && [[ "$decoded" == "$expected_eval" ]]; then
    pass "T1a WITH SHELL-INTEGRATION: generated steps encode eval line via base64 (decodes to '${expected_eval}')"
  else
    fail "T1a WITH SHELL-INTEGRATION: expected base64-encoded eval line in output. exit=${exit_code} decoded='${decoded}' expected='${expected_eval}' stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — WITH SHELL-INTEGRATION entry: generated steps are a Dockerfile RUN that
# appends to /home/agent/.zshrc
# ---------------------------------------------------------------------------
test_t1b_with_shell_integration_zshrc_append_run_step() {
  setup_manifest_sandbox "manifest-with-shell-integration.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_shell_init_steps "$stderr_file") || exit_code=$?
  # Must be a RUN step that appends to .zshrc
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "RUN" && echo "$out" | grep -q "/home/agent/.zshrc"; then
    pass "T1b WITH SHELL-INTEGRATION: generated step is a Dockerfile RUN appending to /home/agent/.zshrc"
  else
    fail "T1b WITH SHELL-INTEGRATION: expected Dockerfile RUN step referencing /home/agent/.zshrc. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — WITHOUT SHELL-INTEGRATION entry: generated steps are empty
# Gated on an inline positive sentinel proving the WITH-entry generator
# actually produces output before asserting the WITHOUT case is empty.
# (Mirrors T1d discipline — per rip-cage-test-fail-prose-without-exit-silent-red)
# ---------------------------------------------------------------------------
test_t1c_without_shell_integration_no_steps() {
  # Positive sentinel first: WITH-entry must produce non-empty output.
  # This ensures a generator that always returns empty cannot false-green the absence half.
  local out_with
  setup_manifest_sandbox "manifest-with-shell-integration.yaml"
  out_with=$(run_manifest_generate_shell_init_steps 2>/dev/null)
  teardown_manifest_sandbox

  if [[ -z "$out_with" ]]; then
    fail "T1c SENTINEL FAILED: WITH-entry generator produced empty output — cannot assert absence on WITHOUT side"
    return
  fi

  # Now assert the WITHOUT-entry case is empty.
  setup_manifest_sandbox
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_shell_init_steps "$stderr_file") || exit_code=$?
  # Default manifest = all bundled TOOL entries; no SHELL-INTEGRATION; expect empty
  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out" || "$out" == $'\n' ]]; then
    pass "T1c WITHOUT SHELL-INTEGRATION (default manifest): no extra .zshrc RUN steps generated"
  else
    fail "T1c WITHOUT SHELL-INTEGRATION: expected empty output. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d — Counterfactual delta: WITH entry → non-empty; WITHOUT entry → empty
# The delta proves manifest-driven provenance of the eval line.
# ---------------------------------------------------------------------------
test_t1d_counterfactual_delta() {
  # Positive sentinel first: WITH entry produces non-empty output
  setup_manifest_sandbox "manifest-with-shell-integration.yaml"
  local out_with
  out_with=$(run_manifest_generate_shell_init_steps 2>/dev/null)
  teardown_manifest_sandbox

  # Absence half: WITHOUT entry produces empty output
  setup_manifest_sandbox
  local out_without
  out_without=$(run_manifest_generate_shell_init_steps 2>/dev/null)
  teardown_manifest_sandbox

  # Gate: positive sentinel must hold before asserting absence
  if [[ -z "$out_with" ]]; then
    fail "T1d SENTINEL FAILED: WITH-entry generator produced empty output — cannot assert absence on WITHOUT side"
    return
  fi

  if [[ "$out_with" != "$out_without" ]] && [[ -n "$out_with" ]] && [[ -z "$out_without" || "$out_without" == $'\n' ]]; then
    pass "T1d Counterfactual delta: WITH SHELL-INTEGRATION has .zshrc steps, WITHOUT is empty (delta proves manifest-driven provenance)"
  else
    fail "T1d Counterfactual delta mismatch. WITH='${out_with}' WITHOUT='${out_without}'"
  fi
}

# ---------------------------------------------------------------------------
# T1e — Injection safety: shell_init with embedded newline is rejected at
# the generation site (cannot break out of RUN step via newline injection)
# ---------------------------------------------------------------------------
test_t1e_newline_injection_rejected() {
  # Create a hostile manifest with a newline in shell_init
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: hostile-shell
    archetype: SHELL-INTEGRATION
    version_pin: "1.0.0"
    shell_init: "eval \"$(hostile-shell init zsh)\"\nRUN rm -rf /"
YAML
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_shell_init_steps "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    pass "T1e Newline injection in shell_init: generator refused (non-zero exit)"
  else
    # If the generator succeeded, check it did NOT bake the injected RUN rm -rf /
    if echo "$out" | grep -q "rm -rf /"; then
      fail "T1e Newline injection: injected payload present in output (injection NOT blocked)"
    else
      fail "T1e Newline injection: generator succeeded but should have rejected multi-line shell_init (exit=${exit_code} out='${out}')"
    fi
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e2 — Fix 1: Quote-safe bake: shell_init containing a single-quote must
# produce a well-formed RUN step (not break the printf quoting context).
# Uses base64 encoding — the generated step must decode back to the original
# shell_init line exactly.
# ---------------------------------------------------------------------------
test_t1e2_single_quote_in_shell_init_produces_valid_run_step() {
  setup_manifest_sandbox
  # shell_init contains a single-quote (the it's pattern common in atuin/zoxide comments)
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: quoted-tool
    archetype: SHELL-INTEGRATION
    version_pin: "1.0.0"
    shell_init: "eval \"$(quoted-tool init zsh)\" # it's here"
YAML
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_shell_init_steps "$stderr_file") || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "T1e2 Single-quote bake: generator failed (exit=${exit_code}). stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # The RUN step must NOT contain a bare single-quoted printf with the literal ' embedded
  # (which would break the Dockerfile RUN step). Check that the generated step is well-formed:
  # for base64 approach: must contain 'base64 -d' and the step must be syntactically parseable.
  if ! echo "$out" | grep -q "base64"; then
    fail "T1e2 Single-quote bake: generated step does not use base64 encoding (single-quote-unsafe). out='${out}'"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # Verify the base64 payload decodes back to the original shell_init line
  local b64_payload decoded
  # Extract the base64 payload from the RUN step (between 'echo ' and ' | base64')
  b64_payload=$(echo "$out" | grep -o "'[A-Za-z0-9+/=]*'" | tr -d "'" | head -1)
  decoded=$(echo "$b64_payload" | base64 -d 2>/dev/null) || true

  if [[ "$decoded" == *"quoted-tool init zsh"* ]] && [[ "$decoded" == *"it's here"* ]]; then
    pass "T1e2 Single-quote in shell_init: generates base64-encoded RUN step that decodes back to original line"
  else
    fail "T1e2 Single-quote bake: decoded payload does not match original. decoded='${decoded}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e3 — Fix 2: Validator rejects multi-line shell_init at LOAD time
# (fail-closed at validation, not deferred to the generation site).
# ---------------------------------------------------------------------------
test_t1e3_validator_rejects_multiline_shell_init() {
  setup_manifest_sandbox
  # A manifest with a literal newline embedded in shell_init (YAML block scalar)
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: multiline-shell
    archetype: SHELL-INTEGRATION
    version_pin: "1.0.0"
    shell_init: "line one\nline two"
YAML
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  # Invoke _manifest_validate via _manifest_load (which calls validate internally)
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_load" >/dev/null 2>"$stderr_file" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    pass "T1e3 Validator rejects multi-line shell_init at load time (fail-closed)"
  else
    fail "T1e3 Validator should reject multi-line shell_init at load time but returned 0. stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e4 — Validator rejects multi-line install_cmd on SHELL-INTEGRATION at LOAD
# time. _manifest_generate_extra_dockerfile_steps has NO archetype filter — a
# SHELL-INTEGRATION entry carrying install_cmd gets a Dockerfile RUN step, so
# the same newline-injection guard that protects TOOL install_cmd must hold
# here (fail-closed validator gap, rip-cage-62a9 / ADR-005 D11 mechanism 2).
# ---------------------------------------------------------------------------
test_t1e4_validator_rejects_multiline_install_cmd_shell_integration() {
  setup_manifest_sandbox
  # Valid shell_init, hostile multi-line install_cmd (YAML double-quoted \n
  # parses to a literal newline — same mechanism as T1e3).
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: shell-with-hostile-install
    archetype: SHELL-INTEGRATION
    version_pin: "1.0.0"
    shell_init: "eval \"$(some-tool init zsh)\""
    install_cmd: "apt-get install -y some-tool\nUSER root"
YAML
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_load" >/dev/null 2>"$stderr_file" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] && grep -qi "install_cmd" "$stderr_file"; then
    pass "T1e4 Validator rejects multi-line install_cmd on SHELL-INTEGRATION (fail-closed, names install_cmd)"
  else
    fail "T1e4 expected non-zero exit + 'install_cmd' in error. exit=${exit_code} stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e5 — Single-line install_cmd on SHELL-INTEGRATION still validates AND is
# consumed by the generator (positive sentinel guarding against the rejected
# fix direction: an archetype filter in the generator would silently drop
# install_cmd for non-TOOL entries — a behavior change for third-party
# manifests; rip-cage-62a9 scoping review).
# ---------------------------------------------------------------------------
test_t1e5_single_line_install_cmd_shell_integration_accepted_and_baked() {
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: shell-with-install
    archetype: SHELL-INTEGRATION
    version_pin: "1.0.0"
    shell_init: "eval \"$(some-tool init zsh)\""
    install_cmd: "apt-get install -y some-tool"
YAML
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_extra_dockerfile_steps" 2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "apt-get install -y some-tool"; then
    pass "T1e5 Single-line install_cmd on SHELL-INTEGRATION validates and generator emits its RUN step"
  else
    fail "T1e5 expected exit 0 + install_cmd in generated steps. exit=${exit_code} out='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e6 — Strict-parse rejects a hostile build_source on SHELL-INTEGRATION.
# _manifest_generate_extra_dockerfile_steps and
# _manifest_generate_source_builder_stages consume build_source with NO
# archetype filter — a SHELL-INTEGRATION entry carrying build_source gets a
# builder stage + COPY --from step, so the same build_source sub-field guard
# that protects TOOL must hold here (fail-closed validator gap, rip-cage-m0hh
# / sibling of rip-cage-62a9 / ADR-005 D11 mechanism 2).
# ---------------------------------------------------------------------------
test_t1e6_strict_parse_rejects_hostile_build_source_shell_integration() {
  setup_manifest_sandbox "manifest-hostile-shell-integration-build-source-newline-builder-image.yaml"
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]] && grep -qi "builder_image" "$stderr_file"; then
    pass "T1e6 Strict-parse rejects hostile build_source (newline in builder_image) on SHELL-INTEGRATION: exits non-zero and names builder_image"
  else
    fail "T1e6 expected non-zero exit + 'builder_image' in error. exit=${exit_code} stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1f — _manifest_build_dockerfile_path incorporates shell_init steps
# When both TOOL and SHELL-INTEGRATION entries exist, the generated temp
# Dockerfile contains both the install RUN step AND the .zshrc append step.
# ---------------------------------------------------------------------------
test_t1f_build_dockerfile_path_includes_shell_init() {
  setup_manifest_sandbox "manifest-with-shell-integration.yaml"
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/Dockerfile'" 2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "T1f _manifest_build_dockerfile_path failed. exit=${exit_code} stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # With base64-safe baking (Fix 1), the eval line is embedded as a base64 payload.
  # Check the temp Dockerfile contains: a base64 -d step AND references /home/agent/.zshrc.
  # Also verify the base64 payload decodes to include the expected tool name.
  if [[ "$dockerfile_path" == "${REPO_ROOT}/Dockerfile" ]]; then
    # If original returned, the step was not baked — this is a failure for SHELL-INTEGRATION
    fail "T1f _manifest_build_dockerfile_path returned original Dockerfile (expected temp with .zshrc step). path='${dockerfile_path}'"
  elif grep -q "base64" "$dockerfile_path" && grep -q "/home/agent/.zshrc" "$dockerfile_path"; then
    # Verify the base64 payload decodes to include the expected eval line
    local b64_payload decoded
    b64_payload=$(grep "base64 -d" "$dockerfile_path" | grep -o "'[A-Za-z0-9+/=]*'" | tr -d "'" | head -1)
    decoded=$(echo "$b64_payload" | base64 -d 2>/dev/null) || true
    if [[ "$decoded" == *"fake-tool"* ]]; then
      pass "T1f _manifest_build_dockerfile_path temp Dockerfile contains base64-encoded .zshrc eval-line step (decodes to fake-tool eval)"
    else
      fail "T1f _manifest_build_dockerfile_path: base64 payload does not decode to expected eval. decoded='${decoded}'"
    fi
    # Cleanup temp file
    [[ "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
  else
    fail "T1f _manifest_build_dockerfile_path: temp Dockerfile missing base64 step or .zshrc reference. path='${dockerfile_path}' content=$(grep -A2 -B2 zshrc "$dockerfile_path" || echo '(no zshrc line)')"
    [[ "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T2 — E2E (NEEDS_CONTAINER / RC_E2E=1)
#
# Build a cage image WITH a SHELL-INTEGRATION entry using a binary already
# in the base image (using 'cat' as the fake tool since it's always present,
# or pair with a TOOL entry that installs a trivial binary).
#
# The discriminating probe: `zsh -lic '<tool> ...'` — login + interactive.
# A non-interactive `zsh -c` would NOT load the rc hook, proving the hook
# fired via the baked .zshrc eval line specifically.
#
# Counterfactual: build WITHOUT the entry, probe that the eval line is absent
# from .zshrc and `zsh -lic` fails or shows no hook output.
# ---------------------------------------------------------------------------
test_t2_e2e_shell_integration_fires_interactively() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): T2 SHELL-INTEGRATION interactive probe — set RC_E2E=1 to run"
    return 0
  fi

  # For e2e, use a manifest that pairs a TOOL entry (installs 'jq' which is fast)
  # with a SHELL-INTEGRATION entry whose shell_init is: eval "$(jq --version)"
  # Actually, we need a tool whose 'init zsh' produces something testable.
  # Better: use a manifest where shell_init is a simple echo/alias, and the
  # test checks that it appears in an interactive shell.
  #
  # Since 'zoxide' and 'atuin' aren't in the base image, we use a TOOL+SHELL-INT
  # fixture that installs a trivial binary AND wires a shell_init eval.
  # For simplicity: shell_init is 'alias __test_hook_fired=true' and we verify
  # that alias exists in the interactive shell.
  #
  # This test uses a special e2e fixture (manifest-e2e-shell-integration.yaml)
  # that pairs a TOOL entry installing a script + a SHELL-INTEGRATION entry.

  local image_with="rip-cage-test-shell-with:counterfactual"
  local image_without="rip-cage-test-shell-without:counterfactual"
  local _t2_home_with _t2_home_without

  # shellcheck disable=SC2329  # invoked indirectly via trap
  _t2_cleanup_t2() {
    docker rmi "$image_with" "$image_without" >/dev/null 2>&1 || true
    [[ -n "${_t2_home_with:-}" ]] && rm -rf "$_t2_home_with"
    [[ -n "${_t2_home_without:-}" ]] && rm -rf "$_t2_home_without"
  }
  trap _t2_cleanup_t2 RETURN

  # Build WITH SHELL-INTEGRATION
  _t2_home_with=$(mktemp -d "${TMPDIR:-/tmp}/rc-t2-shell-with-XXXXXX")
  mkdir -p "${_t2_home_with}/.config/rip-cage"
  cp "${FIXTURES}/manifest-e2e-shell-integration.yaml" "${_t2_home_with}/.config/rip-cage/tools.yaml"

  echo "T2: Building image WITH SHELL-INTEGRATION entry..."
  if ! HOME="$_t2_home_with" XDG_CONFIG_HOME="${_t2_home_with}/.config" \
       RC_MANIFEST_GLOBAL="${_t2_home_with}/.config/rip-cage/tools.yaml" \
       "${RC}" build -t "$image_with"; then
    fail "T2 Build WITH SHELL-INTEGRATION failed"
    return
  fi

  # Build WITHOUT SHELL-INTEGRATION (default manifest)
  _t2_home_without=$(mktemp -d "${TMPDIR:-/tmp}/rc-t2-shell-without-XXXXXX")
  mkdir -p "${_t2_home_without}/.config/rip-cage"

  echo "T2: Building image WITHOUT SHELL-INTEGRATION entry..."
  if ! HOME="$_t2_home_without" XDG_CONFIG_HOME="${_t2_home_without}/.config" \
       "${RC}" build -t "$image_without"; then
    fail "T2 Build WITHOUT SHELL-INTEGRATION failed"
    return
  fi

  # Discriminating probe: zsh -lic (login + interactive) loads .zshrc
  # The eval line in .zshrc sets alias __rc_shell_hook_fired=true
  # A non-interactive zsh -c would NOT load the hook.
  local probe_with_interactive
  probe_with_interactive=$(docker run --rm "$image_with" zsh -lic "alias __rc_shell_hook_fired 2>/dev/null && echo HOOK_FIRED" 2>/dev/null) || true
  if echo "$probe_with_interactive" | grep -q "HOOK_FIRED"; then
    pass "T2a SHELL-INTEGRATION hook fires in interactive shell (zsh -lic): eval line loaded from .zshrc"
  else
    fail "T2a SHELL-INTEGRATION hook NOT firing interactively. probe='${probe_with_interactive}'"
  fi

  # Verify non-interactive zsh DOES NOT fire the hook (proving it's rc-dependent)
  local probe_with_noninteractive
  probe_with_noninteractive=$(docker run --rm "$image_with" zsh -c "alias __rc_shell_hook_fired 2>/dev/null && echo HOOK_FIRED" 2>/dev/null) || true
  if ! echo "$probe_with_noninteractive" | grep -q "HOOK_FIRED"; then
    pass "T2b Hook does NOT fire in non-interactive shell (zsh -c): proves hook is .zshrc-dependent (not a plain binary)"
  else
    fail "T2b Hook fires even in non-interactive shell — this means it's not rc-dependent. probe='${probe_with_noninteractive}'"
  fi

  # Counterfactual: WITHOUT entry, .zshrc has no eval line for hook
  local probe_without_interactive
  probe_without_interactive=$(docker run --rm "$image_without" zsh -lic "alias __rc_shell_hook_fired 2>/dev/null && echo HOOK_FIRED" 2>/dev/null) || true
  if ! echo "$probe_without_interactive" | grep -q "HOOK_FIRED"; then
    pass "T2c SHELL-INTEGRATION absent in WITHOUT-entry image: hook NOT fired in interactive shell (counterfactual holds)"
  else
    fail "T2c Hook fired even WITHOUT SHELL-INTEGRATION entry — counterfactual FAILED. probe='${probe_without_interactive}'"
  fi

  # Verify .zshrc contains eval line WITH entry but not WITHOUT
  local zshrc_with zshrc_without
  zshrc_with=$(docker run --rm "$image_with" cat /home/agent/.zshrc 2>/dev/null) || true
  zshrc_without=$(docker run --rm "$image_without" cat /home/agent/.zshrc 2>/dev/null) || true
  if echo "$zshrc_with" | grep -q "__rc_shell_hook_fired"; then
    pass "T2d .zshrc in WITH-entry image contains the eval line"
  else
    fail "T2d .zshrc in WITH-entry image does NOT contain the eval line. zshrc='${zshrc_with}'"
  fi
  if ! echo "$zshrc_without" | grep -q "__rc_shell_hook_fired"; then
    pass "T2e .zshrc in WITHOUT-entry image does NOT contain the eval line (eval line absent without entry)"
  else
    fail "T2e .zshrc in WITHOUT-entry image CONTAINS the eval line — contaminated build. zshrc='${zshrc_without}'"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

# E2E flag from command line
if [[ "${1:-}" == "--e2e" ]]; then
  export RC_E2E=1
fi

echo "=== test-manifest-shell.sh — SHELL-INTEGRATION archetype shell_init baking (rip-cage-4c5.4) ==="
echo ""
echo "--- T1: Host-only unit tests (generate .zshrc eval-line Dockerfile steps) ---"
test_t1a_with_shell_integration_steps_present
test_t1b_with_shell_integration_zshrc_append_run_step
test_t1c_without_shell_integration_no_steps
test_t1d_counterfactual_delta
test_t1e_newline_injection_rejected
test_t1e2_single_quote_in_shell_init_produces_valid_run_step
test_t1e3_validator_rejects_multiline_shell_init
test_t1e4_validator_rejects_multiline_install_cmd_shell_integration
test_t1e5_single_line_install_cmd_shell_integration_accepted_and_baked
test_t1e6_strict_parse_rejects_hostile_build_source_shell_integration
test_t1f_build_dockerfile_path_includes_shell_init

echo ""
echo "--- T2: E2E counterfactual (NEEDS_CONTAINER) ---"
test_t2_e2e_shell_integration_fires_interactively

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "${FAILURES} test(s) failed."
  exit 1
fi
