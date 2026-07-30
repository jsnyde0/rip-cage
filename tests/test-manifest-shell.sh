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
  # Positive sentinel: the generated step must encode the WHOLE .zshrc block
  # (comment header + shell_init, joined by REAL newlines -- rip-cage-l906
  # fix) via base64. The expected value here is an INDEPENDENT literal built
  # with $'\n' concatenation, not recomputed the way the generator computes
  # it -- so this test can actually disagree with a regression (e.g. the old
  # printf-escaping bug, which would decode to a single mashed line here).
  # SC2016 intentional: literal '$(...)' wanted, not command substitution.
  # shellcheck disable=SC2016
  local expected_block=$'\n''# rip-cage manifest SHELL-INTEGRATION: fake-tool'$'\n''eval "$(fake-tool init zsh)"'$'\n'
  # Extract the base64 payload from the step (single-quoted echo arg before '| base64 -d')
  local b64_payload decoded
  b64_payload=$(echo "$out" | grep -o "'[A-Za-z0-9+/=]*'" | tr -d "'" | head -1)
  decoded=$(printf '%s' "$b64_payload" | base64 -d 2>/dev/null; echo x)
  decoded="${decoded%x}"
  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "base64" && [[ "$decoded" == "$expected_block" ]]; then
    pass "T1a WITH SHELL-INTEGRATION: generated step base64-encodes the comment header + eval line as separate real-newline-terminated lines"
  else
    fail "T1a WITH SHELL-INTEGRATION: expected base64-encoded block with real newlines separating comment header and eval line (literal-backslash-n regression check). exit=${exit_code} decoded=$(printf '%q' "$decoded") expected=$(printf '%q' "$expected_block") stdout='${out}' stderr=$(cat "$stderr_file")"
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
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/cage/Dockerfile'" 2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "T1f _manifest_build_dockerfile_path failed. exit=${exit_code} stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # With base64-safe baking (Fix 1), the eval line is embedded as a base64 payload.
  # Check the temp Dockerfile contains: a base64 -d step AND references /home/agent/.zshrc.
  # Also verify the base64 payload decodes to include the expected tool name.
  if [[ "$dockerfile_path" == "${REPO_ROOT}/cage/Dockerfile" ]]; then
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
    [[ "$dockerfile_path" != "${REPO_ROOT}/cage/Dockerfile" ]] && rm -f "$dockerfile_path"
  else
    fail "T1f _manifest_build_dockerfile_path: temp Dockerfile missing base64 step or .zshrc reference. path='${dockerfile_path}' content=$(grep -A2 -B2 zshrc "$dockerfile_path" || echo '(no zshrc line)')"
    [[ "$dockerfile_path" != "${REPO_ROOT}/cage/Dockerfile" ]] && rm -f "$dockerfile_path"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# _t1g_comment_precedes_eval_line FILE EXPECTED_COMMENT EXPECTED_EVAL
# Order-and-adjacency check (rip-cage-l906.4 review F5): reads FILE line-by-
# line with a bash-3.2-compatible `while IFS= read -r` loop (NOT `mapfile`,
# which does not exist on the macOS system bash — rip-cage-l906.4 review F3 —
# and NOT a `$(...)` command-substitution + IFS split, which would silently
# strip the file's real trailing newline before the split ever sees it,
# masking exactly the kind of newline-handling regression this check exists
# to catch). Returns 0 (echoes nothing) only if EXPECTED_EVAL's line is the
# line IMMEDIATELY AFTER EXPECTED_COMMENT's line — membership of both lines
# ANYWHERE in the file is NOT sufficient (a reversed-order or junk-interleaved
# block would satisfy mere membership but must FAIL this check).
_t1g_comment_precedes_eval_line() {
  local file="$1" expected_comment="$2" expected_eval="$3"
  local idx=0 comment_idx=-1 eval_idx=-1 l
  while IFS= read -r l; do
    [[ "$l" == "$expected_comment" ]] && comment_idx=$idx
    [[ "$l" == "$expected_eval" ]] && eval_idx=$idx
    idx=$((idx + 1))
  done < "$file"
  [[ "$comment_idx" -ge 0 && "$eval_idx" -eq $((comment_idx + 1)) ]]
}

# ---------------------------------------------------------------------------
# T1g — GENERATOR-LEVEL regression guard (host-only, NO image build): the
# emitted Dockerfile RUN step, when actually EXECUTED (not grepped), must
# produce REAL newlines separating the comment header from the shell_init
# eval line in /home/agent/.zshrc — not a literal backslash-n — AND the eval
# line must be PRECEDED BY its comment header ON ITS OWN LINE, immediately
# adjacent (order matters, not mere membership — rip-cage-l906.4 review F5;
# see the parent bead's acceptance bullet 1).
#
# Root cause this guards against (rip-cage-l906): the old generator built the
# comment header via `printf '\\n# ...\\n'` inside a Dockerfile RUN string.
# Bash double-quote collapsing meant the Dockerfile line carried a literal
# two-character `\n` (backslash + n), which `printf` then rendered as literal
# text, NOT a newline — the comment header and the eval line were mashed onto
# one unparseable .zshrc line and the eval line never executed. grep-based
# assertions (T1a/T1b/T1d/T1f) could not catch this because the shell_init
# TEXT was present in the output either way — only executing the emitted
# shell fragment and inspecting real byte structure reveals the defect.
#
# Mechanism: extract the RUN step that appends to .zshrc, strip the leading
# 'RUN ' Dockerfile directive, rewrite the hardcoded /home/agent/.zshrc path
# to a scratch temp file, execute the resulting shell body with `sh -c`
# (materializing exactly what Docker's RUN would write, without a docker
# build), then assert BYTE-LEVEL (real-newline split + exact line equality +
# ADJACENT ORDER, od -c included as diagnostic evidence) via
# _t1g_comment_precedes_eval_line. Must FAIL against the old buggy generator,
# PASS against the fixed one.
# ---------------------------------------------------------------------------
test_t1g_generator_emits_real_newlines_not_literal_backslash_n() {
  setup_manifest_sandbox "manifest-with-shell-integration.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_shell_init_steps "$stderr_file") || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    fail "T1g Generator-level regression guard: generator failed. exit=${exit_code} stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # Isolate the RUN step(s) that actually append to .zshrc (not the separate
  # comment-only 'RUN # manifest SHELL-INTEGRATION: <name>' marker line(s)).
  # The fixture carries exactly ONE SHELL-INTEGRATION entry, so exactly ONE
  # such RUN step is expected. Fail loud (not `head -1`) if that count is
  # ever anything other than 1 — silently truncating to the first match would
  # leave a future multi-entry (or multi-step-per-entry) emission only
  # PARTIALLY checked (rip-cage-l906.4 review F5).
  local zshrc_run_lines zshrc_run_line_count
  zshrc_run_lines=$(echo "$out" | grep '^RUN ' | grep -F '/home/agent/.zshrc')
  zshrc_run_line_count=0
  if [[ -n "$zshrc_run_lines" ]]; then
    zshrc_run_line_count=$(echo "$zshrc_run_lines" | grep -c '.')
  fi
  if [[ "$zshrc_run_line_count" -ne 1 ]]; then
    fail "T1g Generator-level regression guard: expected exactly 1 RUN step appending to /home/agent/.zshrc (fixture has exactly 1 SHELL-INTEGRATION entry), found ${zshrc_run_line_count}. out='${out}'"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi
  local zshrc_run_step="$zshrc_run_lines"

  # Strip 'RUN ' and rewrite the hardcoded .zshrc path to a scratch temp file,
  # then EXECUTE the body — materializes what the Dockerfile RUN step writes.
  local body tmp_zshrc
  body="${zshrc_run_step#RUN }"
  tmp_zshrc=$(mktemp "${TMPDIR:-/tmp}/rc-t1g-zshrc-XXXXXX")
  : > "$tmp_zshrc"
  body="${body//\/home\/agent\/.zshrc/$tmp_zshrc}"
  if ! sh -c "$body"; then
    fail "T1g Generator-level regression guard: executing the rewritten RUN step body failed (body='${body}')"
    rm -f "$tmp_zshrc" "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # Byte-level, ORDER-SENSITIVE assertion (real-newline split + exact line
  # equality + adjacency — NOT grep/substring matching, and NOT independent
  # membership flags, either of which let a reversed-order or junk-
  # interleaved block silently pass; rip-cage-l906.4 review F5).
  local expected_comment='# rip-cage manifest SHELL-INTEGRATION: fake-tool'
  # shellcheck disable=SC2016
  local expected_eval='eval "$(fake-tool init zsh)"'

  if _t1g_comment_precedes_eval_line "$tmp_zshrc" "$expected_comment" "$expected_eval"; then
    pass "T1g Generator-level regression guard: shell_init eval line is on its own real-newline-terminated line, immediately preceded by its comment header on its own line, in materialized .zshrc"
  else
    fail "T1g Generator-level regression guard FAILED (literal-backslash-n and/or order regression): eval line is not immediately preceded by its comment header as two standalone real-newline-terminated lines. od -c: $(od -c "$tmp_zshrc" | head -10)"
  fi

  rm -f "$tmp_zshrc" "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1h — Order-check REGRESSION GUARD for _t1g_comment_precedes_eval_line
# itself (rip-cage-l906.4 review F5): a prior version of T1g set two
# INDEPENDENT membership flags (comment-found, eval-found) rather than
# checking order/adjacency — a materialized .zshrc with the comment and eval
# lines REVERSED, or with junk interleaved between them, would still satisfy
# that membership-only check. This test feeds
# _t1g_comment_precedes_eval_line synthetic (non-generator) inputs to prove
# it actually enforces order, not just membership: PASS on well-ordered
# input, FAIL on reversed-order input, FAIL on junk-interleaved input.
# ---------------------------------------------------------------------------
test_t1h_order_check_rejects_reversed_and_interleaved_lines() {
  local comment='# rip-cage manifest SHELL-INTEGRATION: fake-tool'
  # shellcheck disable=SC2016
  local eval_line='eval "$(fake-tool init zsh)"'
  local tmp

  # Case 1 (positive control): correct order → PASS.
  tmp=$(mktemp "${TMPDIR:-/tmp}/rc-t1h-ok-XXXXXX")
  printf '%s\n%s\n' "$comment" "$eval_line" > "$tmp"
  if _t1g_comment_precedes_eval_line "$tmp" "$comment" "$eval_line"; then
    pass "T1h Order-check helper: correctly-ordered comment-then-eval PASSES (positive control)"
  else
    fail "T1h SENTINEL FAILED: order-check helper rejected correctly-ordered input — cannot trust the negative cases below"
  fi
  rm -f "$tmp"

  # Case 2: REVERSED order (eval line before comment) → must FAIL.
  tmp=$(mktemp "${TMPDIR:-/tmp}/rc-t1h-reversed-XXXXXX")
  printf '%s\n%s\n' "$eval_line" "$comment" > "$tmp"
  if _t1g_comment_precedes_eval_line "$tmp" "$comment" "$eval_line"; then
    fail "T1h Order-check helper ACCEPTED reversed-order input (eval line before its comment header) — membership-only check regression (rip-cage-l906.4 F5)"
  else
    pass "T1h Order-check helper correctly REJECTS reversed-order input (eval line before its comment header)"
  fi
  rm -f "$tmp"

  # Case 3: junk line INTERLEAVED between comment and eval → must FAIL
  # (adjacency, not just "eval appears somewhere after comment").
  tmp=$(mktemp "${TMPDIR:-/tmp}/rc-t1h-interleaved-XXXXXX")
  printf '%s\n%s\n%s\n' "$comment" "RUN rm -rf /" "$eval_line" > "$tmp"
  if _t1g_comment_precedes_eval_line "$tmp" "$comment" "$eval_line"; then
    fail "T1h Order-check helper ACCEPTED junk interleaved between comment header and eval line — adjacency regression (rip-cage-l906.4 F5)"
  else
    pass "T1h Order-check helper correctly REJECTS junk interleaved between comment header and eval line"
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# T1i — Injection safety: a SHELL-INTEGRATION 'name' containing an embedded
# newline cannot inject an arbitrary Dockerfile directive via the
# 'RUN # manifest SHELL-INTEGRATION: <name>' marker line
# (rip-cage-l906.4 F2). Reviewer's live repro:
#   name: "good\nRUN touch /pwned"
# emits `RUN touch /pwned` as its own real Dockerfile RUN directive — the
# a4d0e37 fix base64-encoded the .zshrc PAYLOAD line but left this marker
# line's ${name} interpolation raw.
#
# Fix shape: reject the hostile name at VALIDATION time (a shared
# [a-z0-9_-] allowlist applied to 'name' for every archetype, rip-cage-l906.4)
# so the generator — which only ever runs via _manifest_load, which validates
# first — never sees it, rather than base64-encoding yet another call site
# (escaping-level-counting, the defect class rip-cage-l906 itself was).
# ---------------------------------------------------------------------------
test_t1i_injection_hostile_newline_name_rejected_before_marker_bake() {
  setup_manifest_sandbox "manifest-hostile-name-newline-shell-integration.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_shell_init_steps "$stderr_file") || exit_code=$?
  local err_output
  err_output=$(cat "$stderr_file")

  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "name"; then
    pass "T1i SHELL-INTEGRATION name with embedded newline is rejected before the marker-line bake (names 'name' in the error)"
  else
    fail "T1i expected non-zero exit + 'name' named in error (hostile newline-name must be rejected, not baked). exit=${exit_code} stdout='${out}' stderr='${err_output}'"
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
  #
  # stderr is captured (NOT discarded) on every docker-run probe below
  # (rip-cage-l906 F3): a prior version of this test used `2>/dev/null` on
  # the outer `docker run`, so a T2a failure reported an empty probe string
  # with no diagnosis -- that cost two triage rounds tracking down the
  # printf-escaping bug. The INNER `alias ... 2>/dev/null` (part of the
  # probed shell command itself) is deliberately kept: it silences the
  # expected "no such alias" message from zsh's `alias` builtin when the
  # hook has NOT fired, which is normal control flow for this probe, not a
  # diagnostic signal.
  local probe_with_interactive probe_with_interactive_stderr_file
  probe_with_interactive_stderr_file=$(mktemp)
  probe_with_interactive=$(docker run --rm "$image_with" zsh -lic "alias __rc_shell_hook_fired 2>/dev/null && echo HOOK_FIRED" 2>"$probe_with_interactive_stderr_file") || true
  if echo "$probe_with_interactive" | grep -q "HOOK_FIRED"; then
    pass "T2a SHELL-INTEGRATION hook fires in interactive shell (zsh -lic): eval line loaded from .zshrc"
  else
    fail "T2a SHELL-INTEGRATION hook NOT firing interactively. probe='${probe_with_interactive}' docker_stderr='$(cat "$probe_with_interactive_stderr_file")'"
  fi
  rm -f "$probe_with_interactive_stderr_file"

  # Verify non-interactive zsh DOES NOT fire the hook (proving it's rc-dependent)
  local probe_with_noninteractive probe_with_noninteractive_stderr_file
  probe_with_noninteractive_stderr_file=$(mktemp)
  probe_with_noninteractive=$(docker run --rm "$image_with" zsh -c "alias __rc_shell_hook_fired 2>/dev/null && echo HOOK_FIRED" 2>"$probe_with_noninteractive_stderr_file") || true
  if ! echo "$probe_with_noninteractive" | grep -q "HOOK_FIRED"; then
    pass "T2b Hook does NOT fire in non-interactive shell (zsh -c): proves hook is .zshrc-dependent (not a plain binary)"
  else
    fail "T2b Hook fires even in non-interactive shell — this means it's not rc-dependent. probe='${probe_with_noninteractive}' docker_stderr='$(cat "$probe_with_noninteractive_stderr_file")'"
  fi
  rm -f "$probe_with_noninteractive_stderr_file"

  # Counterfactual: WITHOUT entry, .zshrc has no eval line for hook
  local probe_without_interactive probe_without_interactive_stderr_file
  probe_without_interactive_stderr_file=$(mktemp)
  probe_without_interactive=$(docker run --rm "$image_without" zsh -lic "alias __rc_shell_hook_fired 2>/dev/null && echo HOOK_FIRED" 2>"$probe_without_interactive_stderr_file") || true
  if ! echo "$probe_without_interactive" | grep -q "HOOK_FIRED"; then
    pass "T2c SHELL-INTEGRATION absent in WITHOUT-entry image: hook NOT fired in interactive shell (counterfactual holds)"
  else
    fail "T2c Hook fired even WITHOUT SHELL-INTEGRATION entry — counterfactual FAILED. probe='${probe_without_interactive}' docker_stderr='$(cat "$probe_without_interactive_stderr_file")'"
  fi
  rm -f "$probe_without_interactive_stderr_file"

  # Verify .zshrc contains eval line WITH entry but not WITHOUT
  local zshrc_with zshrc_without zshrc_with_stderr_file zshrc_without_stderr_file
  zshrc_with_stderr_file=$(mktemp)
  zshrc_without_stderr_file=$(mktemp)
  zshrc_with=$(docker run --rm "$image_with" cat /home/agent/.zshrc 2>"$zshrc_with_stderr_file") || true
  zshrc_without=$(docker run --rm "$image_without" cat /home/agent/.zshrc 2>"$zshrc_without_stderr_file") || true
  if echo "$zshrc_with" | grep -q "__rc_shell_hook_fired"; then
    pass "T2d .zshrc in WITH-entry image contains the eval line"
  else
    fail "T2d .zshrc in WITH-entry image does NOT contain the eval line. zshrc='${zshrc_with}' docker_stderr='$(cat "$zshrc_with_stderr_file")'"
  fi
  if ! echo "$zshrc_without" | grep -q "__rc_shell_hook_fired"; then
    pass "T2e .zshrc in WITHOUT-entry image does NOT contain the eval line (eval line absent without entry)"
  else
    fail "T2e .zshrc in WITHOUT-entry image CONTAINS the eval line — contaminated build. zshrc='${zshrc_without}' docker_stderr='$(cat "$zshrc_without_stderr_file")'"
  fi
  rm -f "$zshrc_with_stderr_file" "$zshrc_without_stderr_file"
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
test_t1g_generator_emits_real_newlines_not_literal_backslash_n
test_t1h_order_check_rejects_reversed_and_interleaved_lines
test_t1i_injection_hostile_newline_name_rejected_before_marker_bake

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
