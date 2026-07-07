#!/usr/bin/env bash
# Host-side + e2e tests for IN-CAGE DAEMON archetype lifecycle (rip-cage-4c5.5).
# ADR-005 D7 (IN-CAGE-DAEMON archetype: start+health+state_dir+mcp_fragment).
# ADR-005 D8 (default manifest → byte-for-byte original Dockerfile).
# ADR-005 D10 (user daemon fail-warn vs safety fail-closed).
# ADR-019 D1 (state-dir: container-local, not bind-mount-durable).
# ADR-025 D5 (validate by parsing, fail-closed).
#
# =============================================================================
# Test tiers
# =============================================================================
#
#   T1  (host-only, runs always):
#     T1a — WITH daemon entry: _manifest_generate_daemon_config_dockerfile_steps
#           emits a Dockerfile step that bakes daemon config to
#           /etc/rip-cage/daemon-config.json (positive sentinel).
#     T1b — DEFAULT manifest (no daemon entries): generator emits nothing.
#           Gated on T1a sentinel to avoid false-green from empty generator.
#     T1c — Counterfactual delta: WITH entry → non-empty; WITHOUT → empty.
#     T1d — Strict-parse validation: malformed daemon config (missing required
#           field) is rejected fail-closed by _manifest_validate, NOT by running
#           a fail-open consumer (ADR-025 D5 / bd memory
#           validate-config-by-parsing-not-by-running-fail-open-consumer).
#     T1e — MCP fragment: WITH mcp_fragment entry → _manifest_generate_daemon_mcp_dockerfile_steps
#           emits a Dockerfile step that merges mcpServers into settings.json.
#     T1f — _manifest_build_dockerfile_path includes daemon config step (temp
#           Dockerfile for daemon manifest; original Dockerfile for default).
#
#   T2  (e2e, NEEDS_CONTAINER / RC_E2E=1):
#     T2a — Health passes: daemon started by init, health check produces a
#           POSITIVE SENTINEL (daemon actually responded). A daemon that never
#           started must NOT green this check (absence-of-error is NOT sentinel).
#     T2b — Broken daemon → cage still starts (fail-warn): deliberately broken
#           start command → cage initializes but logs a WARNING, does NOT abort.
#     T2c — Init-idempotency (PID unchanged): re-running init-rip-cage.sh on a
#           running cage does NOT spawn a second daemon binder. The daemon PID is
#           UNCHANGED between first and second init run (true no-op, not
#           kill-and-restart which would produce a new PID on the same port).
#     T2d — State-dir placement: the daemon state-dir exists at the decided path
#           (/var/lib/rip-cage-daemon/<name>/ — container-local per ADR-019 D1
#           extensions pattern).
#     T2e — MCP fragment discoverable: the daemon's mcp_fragment is present in
#           settings.json mcpServers after cage init, visible to the in-cage agent.
#
# =============================================================================
# Positive-sentinel discipline (rip-cage-test-fail-prose-without-exit-silent-red):
#   * Every failure increments FAILURES.
#   * Script ends with [[ $FAILURES -eq 0 ]] || exit 1.
#   * Absence assertions MUST be gated on a positive sentinel proving the
#     WITH-entry path actually produces output.
#   * "Health passes" uses a POSITIVE SENTINEL (daemon responded), never
#     absence-of-error (a daemon that never started must NOT green it).
# =============================================================================
#
# State-dir persistence decision (ADR-019 D1):
#   Container-local (/var/lib/rip-cage-daemon/<name>/) following the
#   extensions/ precedent: extensions are container-local (cage-owned),
#   while only auth.json is bind-mount-durable. Daemon state (mailboxes,
#   caches, ephemeral coordination state) is cage-lifetime, not project-lifetime.
#   Wipe on rc destroy is correct semantics — a fresh cage starts fresh.
#   If a user needs durable daemon state, they should use a workspace-rooted
#   path (/workspace/.daemon-state/) via the state_dir field — the daemon
#   config bake places state_dir AS SPECIFIED in the manifest, so the user
#   controls this per-entry.
#
# Supervisor model decision:
#   init-script-start (NOT host-exec). The ssh-agent-filter fork+PID-parse+
#   fail-warn pattern (init-rip-cage.sh:60-103) is the exact precedent.
#   PID stored in /tmp/rip-cage-daemon-<name>.pid for idempotency detection.
#   Health check wrapped in a timeout (bd memory rip-cage-validate-hung-daemon)
#   to prevent a wedged daemon from hanging the init script.

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
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-manifest-daemon-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${TEST_HOME}/.config/rip-cage/tools.yaml"
  fi
}

teardown_manifest_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME=""
}

# Run _manifest_generate_daemon_config_dockerfile_steps in the sandbox.
run_manifest_generate_daemon_config_steps() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_daemon_config_dockerfile_steps" 2>"$stderr_file"
}

# Run _manifest_generate_daemon_mcp_dockerfile_steps in the sandbox.
run_manifest_generate_daemon_mcp_steps() {
  local stderr_file="${1:-/dev/null}"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_daemon_mcp_dockerfile_steps" 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# T1a — WITH daemon entry: generated steps bake daemon config to /etc/rip-cage/daemon-config.json
# ---------------------------------------------------------------------------
test_t1a_with_daemon_config_step_present() {
  setup_manifest_sandbox "manifest-with-trivial-daemon.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_daemon_config_steps "$stderr_file") || exit_code=$?

  # Positive sentinel: must produce a Dockerfile step referencing daemon-config.json
  if [[ "$exit_code" -eq 0 ]] \
     && echo "$out" | grep -q "daemon-config.json" \
     && echo "$out" | grep -q "RUN"; then
    pass "T1a WITH daemon entry: generated step bakes daemon-config.json into image"
  else
    fail "T1a WITH daemon entry: expected Dockerfile RUN step baking daemon-config.json. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1b — DEFAULT manifest: generator emits nothing (D8 short-circuit)
# Gated on T1a sentinel.
# ---------------------------------------------------------------------------
test_t1b_default_manifest_no_daemon_steps() {
  # Positive sentinel first: WITH-entry must produce non-empty output.
  local out_with
  setup_manifest_sandbox "manifest-with-trivial-daemon.yaml"
  out_with=$(run_manifest_generate_daemon_config_steps 2>/dev/null)
  teardown_manifest_sandbox

  if [[ -z "$out_with" ]]; then
    fail "T1b SENTINEL FAILED: WITH-daemon generator produced empty output — cannot assert absence on default side"
    return
  fi

  # Now assert the default (no daemon entries) case is empty.
  setup_manifest_sandbox
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_daemon_config_steps "$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out" || "$out" == $'\n' ]]; then
    pass "T1b DEFAULT manifest (no daemon entries): daemon-config generator emits nothing (D8 short-circuit)"
  else
    fail "T1b DEFAULT manifest: expected empty output. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1c — Counterfactual delta: WITH daemon entry → non-empty; WITHOUT → empty.
# ---------------------------------------------------------------------------
test_t1c_counterfactual_delta() {
  # WITH-entry produces non-empty output
  setup_manifest_sandbox "manifest-with-trivial-daemon.yaml"
  local out_with
  out_with=$(run_manifest_generate_daemon_config_steps 2>/dev/null)
  teardown_manifest_sandbox

  # WITHOUT-entry produces empty output
  setup_manifest_sandbox
  local out_without
  out_without=$(run_manifest_generate_daemon_config_steps 2>/dev/null)
  teardown_manifest_sandbox

  # Gate: positive sentinel must hold
  if [[ -z "$out_with" ]]; then
    fail "T1c SENTINEL FAILED: WITH-daemon generator produced empty output"
    return
  fi

  if [[ -n "$out_with" ]] && [[ -z "$out_without" || "$out_without" == $'\n' ]]; then
    pass "T1c Counterfactual delta: WITH daemon has config step, WITHOUT is empty (delta proves manifest-driven provenance)"
  else
    fail "T1c Counterfactual delta mismatch. WITH='${out_with}' WITHOUT='${out_without}'"
  fi
}

# ---------------------------------------------------------------------------
# T1d — Strict-parse validation: manifest with missing required daemon field
# must be rejected fail-closed by _manifest_validate (not silently ignored).
# Anti-pattern to avoid: validating by RUNNING the daemon and checking exit code
# (a daemon that silently ignores bad config would false-green such a check).
# ---------------------------------------------------------------------------
test_t1d_strict_parse_rejects_missing_start_field() {
  setup_manifest_sandbox
  # Missing 'start' field — must fail validation
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: bad-daemon
    archetype: IN-CAGE-DAEMON
    version_pin: "0.1.0"
    health: "curl -sf http://127.0.0.1:9999/health"
    state_dir: "/var/lib/rip-cage-daemon/bad-daemon"
YAML
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file") || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "start"; then
    pass "T1d Strict-parse rejects missing 'start' field: validator exits non-zero and names 'start' in error"
  else
    fail "T1d Strict-parse: expected non-zero exit + 'start' in error. exit=${exit_code} stderr='${err_output}' stdout='${out}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d2 — Strict-parse rejects missing 'health' field
# ---------------------------------------------------------------------------
test_t1d2_strict_parse_rejects_missing_health_field() {
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: bad-daemon-no-health
    archetype: IN-CAGE-DAEMON
    version_pin: "0.1.0"
    start: "/usr/bin/python3 -m http.server 9998"
    state_dir: "/var/lib/rip-cage-daemon/bad-daemon-no-health"
YAML
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "health"; then
    pass "T1d2 Strict-parse rejects missing 'health' field: names 'health' in error"
  else
    fail "T1d2 Strict-parse: expected non-zero exit + 'health' in error. exit=${exit_code} stderr='${err_output}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d3 — Strict-parse rejects missing 'state_dir' field
# ---------------------------------------------------------------------------
test_t1d3_strict_parse_rejects_missing_state_dir_field() {
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: bad-daemon-no-state-dir
    archetype: IN-CAGE-DAEMON
    version_pin: "0.1.0"
    start: "/usr/bin/python3 -m http.server 9997"
    health: "curl -sf http://127.0.0.1:9997/"
YAML
  local stderr_file exit_code
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  local err_output
  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "state_dir"; then
    pass "T1d3 Strict-parse rejects missing 'state_dir' field: names 'state_dir' in error"
  else
    fail "T1d3 Strict-parse: expected non-zero exit + 'state_dir' in error. exit=${exit_code} stderr='${err_output}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d4 — Strict-parse rejects invalid state_dir values (R3: fail-closed path
#         safety guard — a typo like "/ var" would word-split into
#         "chown -R agent:agent / var", chowning root; reject at load time).
#         Tests: non-absolute, whitespace, shell metacharacters.
# ---------------------------------------------------------------------------
test_t1d4_strict_parse_rejects_invalid_state_dir() {
  local _name _state_dir _label _stderr_file _exit_code _err_output

  # Sub-test helper
  check_invalid_state_dir() {
    _name="$1"
    _state_dir="$2"
    _label="$3"

    setup_manifest_sandbox
    cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<YAML
version: 1
tools:
  - name: ${_name}
    archetype: IN-CAGE-DAEMON
    version_pin: "0.1.0"
    start: "/usr/bin/python3 -m http.server 9996"
    health: "curl -sf http://127.0.0.1:9996/"
    state_dir: "${_state_dir}"
YAML
    _stderr_file=$(mktemp)
    _exit_code=0
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
      bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
      2>"$_stderr_file" || _exit_code=$?

    _err_output=$(cat "$_stderr_file")
    if [[ "$_exit_code" -ne 0 ]] && echo "$_err_output" | grep -qi "state_dir"; then
      pass "T1d4 Strict-parse rejects invalid state_dir (${_label}): exits non-zero and names state_dir"
    else
      fail "T1d4 Strict-parse should reject invalid state_dir (${_label}). exit=${_exit_code} stderr='${_err_output}'"
    fi
    rm -f "$_stderr_file"
    teardown_manifest_sandbox
  }

  # Non-absolute path (no leading /)
  check_invalid_state_dir "bad-rel" "var/lib/rip-cage-daemon/x" "relative path"
  # Whitespace (word-split risk: "/ var" → chown / var)
  check_invalid_state_dir "bad-ws" "/ var/lib/rip-cage-daemon/x" "whitespace in path"
  # Shell metacharacter ($) — use a variable to hold the literal string, avoiding SC2016
  local _meta_dollar="/var/lib/rip-cage-daemon/\$(id)"
  check_invalid_state_dir "bad-meta-dollar" "$_meta_dollar" "shell metachar dollar"
  # Shell metacharacter (;)
  check_invalid_state_dir "bad-meta-semi" '/var/lib/rip-cage-daemon/x;rm -rf /' "shell metachar semicolon"
}

# ---------------------------------------------------------------------------
# T1d5 — Strict-parse rejects multi-line install_cmd on IN-CAGE-DAEMON.
# _manifest_generate_extra_dockerfile_steps has NO archetype filter — a daemon
# entry carrying install_cmd gets a Dockerfile RUN step, so the same
# newline-injection guard that protects TOOL install_cmd must hold here
# (fail-closed validator gap, rip-cage-62a9 / ADR-005 D11 mechanism 2).
# ---------------------------------------------------------------------------
test_t1d5_strict_parse_rejects_multiline_install_cmd() {
  setup_manifest_sandbox
  # Valid required fields, hostile multi-line install_cmd (YAML double-quoted
  # \n parses to a literal newline).
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: daemon-with-hostile-install
    archetype: IN-CAGE-DAEMON
    version_pin: "0.1.0"
    start: "/usr/bin/python3 -m http.server 9995"
    health: "curl -sf http://127.0.0.1:9995/"
    state_dir: "/var/lib/rip-cage-daemon/daemon-with-hostile-install"
    install_cmd: "apt-get install -y some-daemon\nUSER root"
YAML
  local stderr_file exit_code err_output
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "install_cmd"; then
    pass "T1d5 Strict-parse rejects multi-line install_cmd on IN-CAGE-DAEMON: exits non-zero and names install_cmd"
  else
    fail "T1d5 Strict-parse should reject multi-line install_cmd on IN-CAGE-DAEMON. exit=${exit_code} stderr='${err_output}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d6 — Single-line install_cmd on IN-CAGE-DAEMON still validates AND is
# consumed by the generator (positive sentinel guarding against the rejected
# fix direction: an archetype filter in the generator would silently drop
# install_cmd for non-TOOL entries — a behavior change for third-party
# manifests; rip-cage-62a9 scoping review).
# ---------------------------------------------------------------------------
test_t1d6_single_line_install_cmd_daemon_accepted_and_baked() {
  setup_manifest_sandbox
  cat > "${TEST_HOME}/.config/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: daemon-with-install
    archetype: IN-CAGE-DAEMON
    version_pin: "0.1.0"
    start: "/usr/bin/python3 -m http.server 9994"
    health: "curl -sf http://127.0.0.1:9994/"
    state_dir: "/var/lib/rip-cage-daemon/daemon-with-install"
    install_cmd: "apt-get install -y some-daemon"
YAML
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_generate_extra_dockerfile_steps" 2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && echo "$out" | grep -q "apt-get install -y some-daemon"; then
    pass "T1d6 Single-line install_cmd on IN-CAGE-DAEMON validates and generator emits its RUN step"
  else
    fail "T1d6 expected exit 0 + install_cmd in generated steps. exit=${exit_code} out='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1d7 — Strict-parse rejects a hostile build_source on IN-CAGE-DAEMON.
# _manifest_generate_extra_dockerfile_steps and
# _manifest_generate_source_builder_stages consume build_source with NO
# archetype filter — a daemon entry carrying build_source gets a builder
# stage + COPY --from step, so the same build_source sub-field guard that
# protects TOOL must hold here (fail-closed validator gap, rip-cage-m0hh /
# sibling of rip-cage-62a9 / ADR-005 D11 mechanism 2, rip-cage-buuo.6 F2).
# ---------------------------------------------------------------------------
test_t1d7_strict_parse_rejects_hostile_build_source() {
  setup_manifest_sandbox "manifest-hostile-daemon-build-source-escape-build-script.yaml"
  local stderr_file exit_code err_output
  stderr_file=$(mktemp)
  exit_code=0
  HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_validate '${TEST_HOME}/.config/rip-cage/tools.yaml'" \
    2>"$stderr_file" || exit_code=$?

  err_output=$(cat "$stderr_file")
  if [[ "$exit_code" -ne 0 ]] && echo "$err_output" | grep -qi "build_script"; then
    pass "T1d7 Strict-parse rejects hostile build_source (../-escaping build_script) on IN-CAGE-DAEMON: exits non-zero and names build_script"
  else
    fail "T1d7 Strict-parse should reject hostile build_source on IN-CAGE-DAEMON. exit=${exit_code} stderr='${err_output}'"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e — MCP fragment: WITH mcp_fragment → step merges mcpServers into settings.json
# ---------------------------------------------------------------------------
test_t1e_with_mcp_fragment_step_present() {
  setup_manifest_sandbox "manifest-with-trivial-daemon-mcp.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_daemon_mcp_steps "$stderr_file") || exit_code=$?

  # Positive sentinel: must produce a Dockerfile step referencing mcpServers
  if [[ "$exit_code" -eq 0 ]] \
     && echo "$out" | grep -q "mcpServers\|settings.json" \
     && echo "$out" | grep -q "RUN"; then
    pass "T1e WITH mcp_fragment: generated step merges mcpServers into settings.json"
  else
    fail "T1e WITH mcp_fragment: expected Dockerfile RUN step merging mcpServers. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1e2 — WITHOUT mcp_fragment → MCP step generator emits nothing
# ---------------------------------------------------------------------------
test_t1e2_without_mcp_fragment_no_step() {
  # Positive sentinel first
  local out_with
  setup_manifest_sandbox "manifest-with-trivial-daemon-mcp.yaml"
  out_with=$(run_manifest_generate_daemon_mcp_steps 2>/dev/null)
  teardown_manifest_sandbox

  if [[ -z "$out_with" ]]; then
    fail "T1e2 SENTINEL FAILED: WITH-mcp generator produced empty output"
    return
  fi

  # Daemon WITHOUT mcp_fragment → empty
  setup_manifest_sandbox "manifest-with-trivial-daemon.yaml"
  local stderr_file out exit_code
  stderr_file=$(mktemp)
  exit_code=0
  out=$(run_manifest_generate_daemon_mcp_steps "$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && [[ -z "$out" || "$out" == $'\n' ]]; then
    pass "T1e2 WITHOUT mcp_fragment: MCP step generator emits nothing"
  else
    fail "T1e2 WITHOUT mcp_fragment: expected empty output. exit=${exit_code} stdout='${out}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1f — _manifest_build_dockerfile_path includes daemon config step (WITH daemon)
#         and returns ORIGINAL Dockerfile for default manifest (D8 invariant).
# ---------------------------------------------------------------------------
test_t1f_build_dockerfile_path_with_daemon() {
  setup_manifest_sandbox "manifest-with-trivial-daemon.yaml"
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/Dockerfile'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "T1f _manifest_build_dockerfile_path failed. exit=${exit_code} stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  if [[ "$dockerfile_path" == "${REPO_ROOT}/Dockerfile" ]]; then
    fail "T1f _manifest_build_dockerfile_path returned original Dockerfile (expected temp with daemon step). path='${dockerfile_path}'"
  elif grep -q "daemon-config.json" "$dockerfile_path" 2>/dev/null; then
    pass "T1f _manifest_build_dockerfile_path temp Dockerfile contains daemon-config.json bake step"
    [[ "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
  else
    fail "T1f _manifest_build_dockerfile_path: temp Dockerfile missing daemon-config.json bake step. path='${dockerfile_path}'"
    [[ "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1f2 — Daemon-config bake step POSITION regression (rip-cage-4c5.9 fix).
#         The daemon-config bake step must appear AFTER the
#         "COPY settings.json /etc/rip-cage/settings.json" line AND BEFORE
#         the "USER agent" line in the generated Dockerfile.
#         A regression that re-splices daemon steps before "# Non-root user"
#         (the exact bug fixed in 4c5.9) would still green T1f but fail here.
# ---------------------------------------------------------------------------
test_t1f2_daemon_config_step_position() {
  setup_manifest_sandbox "manifest-with-trivial-daemon.yaml"
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/Dockerfile'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    fail "T1f2 _manifest_build_dockerfile_path failed. exit=${exit_code} stderr=$(cat "$stderr_file")"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  if [[ "$dockerfile_path" == "${REPO_ROOT}/Dockerfile" ]]; then
    fail "T1f2 _manifest_build_dockerfile_path returned original Dockerfile (expected temp with daemon step)"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # Extract line numbers for the three sentinels
  local copy_settings_line daemon_config_line user_agent_line
  copy_settings_line=$(grep -n "COPY settings.json /etc/rip-cage/settings.json" "$dockerfile_path" | head -1 | cut -d: -f1)
  daemon_config_line=$(grep -n "daemon-config.json" "$dockerfile_path" | head -1 | cut -d: -f1)
  user_agent_line=$(grep -n "^USER agent" "$dockerfile_path" | head -1 | cut -d: -f1)

  # All three must be present
  if [[ -z "$copy_settings_line" ]] || [[ -z "$daemon_config_line" ]] || [[ -z "$user_agent_line" ]]; then
    fail "T1f2 Position check: could not find all sentinels in generated Dockerfile. copy_settings=${copy_settings_line} daemon_config=${daemon_config_line} user_agent=${user_agent_line}"
    [[ "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
    rm -f "$stderr_file"
    teardown_manifest_sandbox
    return
  fi

  # POSITION assertion: daemon-config step must be AFTER COPY settings.json AND BEFORE USER agent
  if [[ "$daemon_config_line" -gt "$copy_settings_line" ]] && [[ "$daemon_config_line" -lt "$user_agent_line" ]]; then
    pass "T1f2 Daemon-config bake step position correct: line ${daemon_config_line} is after COPY settings.json (line ${copy_settings_line}) and before USER agent (line ${user_agent_line})"
  else
    fail "T1f2 Daemon-config bake step WRONG POSITION: daemon_config_line=${daemon_config_line}, copy_settings_line=${copy_settings_line}, user_agent_line=${user_agent_line}. Expected: copy_settings < daemon_config < user_agent. A regression to pre-4c5.9 injection point would place daemon-config before COPY settings.json."
  fi

  [[ "$dockerfile_path" != "${REPO_ROOT}/Dockerfile" ]] && rm -f "$dockerfile_path"
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T1g — D8 invariant: DEFAULT manifest → _manifest_build_dockerfile_path returns
#        the ORIGINAL Dockerfile path unchanged.
# ---------------------------------------------------------------------------
test_t1g_d8_default_manifest_original_dockerfile() {
  setup_manifest_sandbox
  local stderr_file dockerfile_path exit_code
  stderr_file=$(mktemp)
  exit_code=0
  dockerfile_path=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    bash -c "source '${RC}'; _manifest_build_dockerfile_path '${REPO_ROOT}/Dockerfile'" \
    2>"$stderr_file") || exit_code=$?

  if [[ "$exit_code" -eq 0 ]] && [[ "$dockerfile_path" == "${REPO_ROOT}/Dockerfile" ]]; then
    pass "T1g D8 invariant: default manifest → _manifest_build_dockerfile_path returns original Dockerfile (byte-for-byte unchanged build)"
  else
    fail "T1g D8 invariant: expected original Dockerfile path. exit=${exit_code} got='${dockerfile_path}' stderr=$(cat "$stderr_file")"
  fi
  rm -f "$stderr_file"
  teardown_manifest_sandbox
}

# ---------------------------------------------------------------------------
# T2 — E2E (NEEDS_CONTAINER / RC_E2E=1)
#
# Uses a trivial fixture daemon: a python3 HTTP server on localhost:17843
# (high port to avoid collisions). The daemon has a health check endpoint.
# Cage built with manifest-with-trivial-daemon.yaml (includes mcp_fragment).
# ---------------------------------------------------------------------------

# Skip helper for all T2 tests
skip_if_not_e2e() {
  if [[ "${RC_E2E:-}" != "1" && "${RUN_E2E:-}" != "1" ]]; then
    echo "SKIP (NEEDS_CONTAINER / e2e): ${1} — set RC_E2E=1 to run"
    return 0
  fi
  return 1
}

test_t2a_health_passes_positive_sentinel() {
  if skip_if_not_e2e "T2a daemon health passes (positive sentinel)"; then return 0; fi

  # This test requires a cage image built with manifest-with-trivial-daemon-mcp.yaml.
  # rc build always tags its output as rip-cage:latest (IMAGE var in rc).
  # The fixture daemon is python3 -m http.server on port 17843.
  # Health check: curl -sf http://127.0.0.1:17843/
  # Positive sentinel: daemon must RESPOND (not merely absence-of-error).
  #
  # Pattern: start with sleep infinity (not --entrypoint init-rip-cage.sh) so the
  # container stays alive after init completes, then run init via docker exec.
  # This matches the T2c/T2d pattern — the container must be alive when we probe it.

  local container_name="rc-daemon-test-t2a-$$"
  local image_name="rip-cage:latest"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-XXXXXX")
  local manifest_home
  manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-home-XXXXXX")
  mkdir -p "${manifest_home}/.config/rip-cage"
  cp "${FIXTURES}/manifest-with-trivial-daemon-mcp.yaml" \
     "${manifest_home}/.config/rip-cage/tools.yaml"

  # Cleanup helper — called on every exit path (R4: container leak fix).
  t2a_cleanup() {
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    rm -rf "$workspace" "$manifest_home"
  }

  # Build image with daemon manifest
  local build_out
  if ! build_out=$(HOME="$manifest_home" XDG_CONFIG_HOME="${manifest_home}/.config" \
       "${REPO_ROOT}/rc" build 2>&1); then
    fail "T2a Could not build cage image with daemon manifest: ${build_out}"
    t2a_cleanup
    return
  fi

  # Start a persistent container (sleep infinity keeps it alive after init completes;
  # --entrypoint init-rip-cage.sh would exit the container, killing background daemons).
  if ! docker run -d --name "$container_name" \
       -v "${workspace}:/workspace" \
       "$image_name" sleep infinity >/dev/null 2>&1; then
    fail "T2a Could not start cage container with daemon image"
    t2a_cleanup
    return
  fi

  # Run init inside the running container.
  # R2: capture exit code + stderr; fail loud on non-zero (do not swallow init failures).
  local init_out init_rc
  init_rc=0
  init_out=$(docker exec "$container_name" /usr/local/bin/init-rip-cage.sh 2>&1) || init_rc=$?
  if [[ "$init_rc" -ne 0 ]]; then
    fail "T2a init-rip-cage.sh exited ${init_rc} — daemon cage init failed. output='${init_out}'"
    t2a_cleanup
    return
  fi

  # Wait briefly for daemon to bind its port after init
  sleep 2

  # POSITIVE SENTINEL: The daemon must RESPOND to a request.
  # curl without -f so we get the response body; non-zero exit means no connection.
  # curl -s (silent) but without -f so 4xx/5xx don't trigger exit code 22.
  # We check health_rc=0 AND non-empty response body as the positive sentinel.
  local health_out health_rc
  health_rc=0
  health_out=$(docker exec "$container_name" \
    timeout 5 curl -s http://127.0.0.1:17843/ 2>&1) || health_rc=$?

  if [[ "$health_rc" -eq 0 ]] && [[ -n "$health_out" ]]; then
    pass "T2a Daemon health positive sentinel: daemon responded (HTTP response received)"
  else
    fail "T2a Daemon health: daemon did NOT respond (health_rc=${health_rc}, out='${health_out}'). A daemon that never started must NOT green this test."
  fi

  t2a_cleanup
}

test_t2b_broken_daemon_cage_still_starts() {
  if skip_if_not_e2e "T2b broken daemon → cage still starts (fail-warn)"; then return 0; fi

  local container_name="rc-daemon-test-t2b-$$"
  local image_name="rip-cage:latest"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-XXXXXX")
  local manifest_home
  manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-home-XXXXXX")
  mkdir -p "${manifest_home}/.config/rip-cage"
  cp "${FIXTURES}/manifest-with-broken-daemon.yaml" \
     "${manifest_home}/.config/rip-cage/tools.yaml"

  local build_out
  if ! build_out=$(HOME="$manifest_home" XDG_CONFIG_HOME="${manifest_home}/.config" \
       "${REPO_ROOT}/rc" build 2>&1); then
    fail "T2b Could not build cage image with broken daemon manifest: ${build_out}"
    rm -rf "$workspace" "$manifest_home"
    return
  fi

  local init_out init_rc
  init_rc=0
  # Run init-rip-cage.sh directly; if fail-warn works, init exits 0 even with broken daemon.
  init_out=$(docker run --rm \
    -v "${workspace}:/workspace" \
    "$image_name" \
    /usr/local/bin/init-rip-cage.sh 2>&1) || init_rc=$?

  if [[ "$init_rc" -eq 0 ]] && echo "$init_out" | grep -qi "WARNING\|warn"; then
    pass "T2b Broken daemon → cage still starts (fail-warn): init exits 0 with WARNING in output"
  elif [[ "$init_rc" -ne 0 ]]; then
    fail "T2b Broken daemon: cage init ABORTED (exit=${init_rc}) — expected fail-WARN, not fail-closed. output='${init_out}'"
  else
    fail "T2b Broken daemon: cage started but no WARNING logged. output='${init_out}'"
  fi

  rm -rf "$workspace" "$manifest_home"
}

test_t2c_init_idempotency_pid_unchanged() {
  if skip_if_not_e2e "T2c init idempotency: PID unchanged on re-run"; then return 0; fi

  local container_name="rc-daemon-test-t2c-$$"
  local image_name="rip-cage:latest"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-XXXXXX")
  local manifest_home
  manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-home-XXXXXX")
  mkdir -p "${manifest_home}/.config/rip-cage"
  cp "${FIXTURES}/manifest-with-trivial-daemon-mcp.yaml" \
     "${manifest_home}/.config/rip-cage/tools.yaml"

  # Cleanup helper — called on every exit path (R4: container leak fix).
  t2c_cleanup() {
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    rm -rf "$workspace" "$manifest_home"
  }

  local build_out
  if ! build_out=$(HOME="$manifest_home" XDG_CONFIG_HOME="${manifest_home}/.config" \
       "${REPO_ROOT}/rc" build 2>&1); then
    fail "T2c Could not build cage image: ${build_out}"
    t2c_cleanup
    return
  fi

  # Start a persistent container
  if ! docker run -d --name "$container_name" \
       -v "${workspace}:/workspace" \
       "$image_name" sleep infinity >/dev/null 2>&1; then
    fail "T2c Could not start container"
    t2c_cleanup
    return
  fi

  # Run init-rip-cage.sh FIRST time
  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true
  sleep 2

  # Capture daemon PID after first init
  local pid1
  pid1=$(docker exec "$container_name" \
    cat /tmp/rip-cage-daemon-trivial-test-daemon.pid 2>/dev/null) || pid1=""

  if [[ -z "$pid1" ]]; then
    fail "T2c Could not capture daemon PID after first init (PID file absent or daemon not started)"
    t2c_cleanup
    return
  fi

  # Run init-rip-cage.sh SECOND time (idempotency re-run)
  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true
  sleep 1

  # Capture daemon PID after second init — must be UNCHANGED
  local pid2
  pid2=$(docker exec "$container_name" \
    cat /tmp/rip-cage-daemon-trivial-test-daemon.pid 2>/dev/null) || pid2=""

  # CRITICAL: kill-and-restart masquerade — a new PID on the same port would
  # false-green a "one binder" check but not this PID-unchanged check.
  if [[ "$pid1" == "$pid2" ]] && [[ -n "$pid1" ]]; then
    pass "T2c Init idempotency: daemon PID unchanged after second init (pid=${pid1} — true no-op, not kill-and-restart)"
  else
    fail "T2c Init idempotency: PID CHANGED between first (${pid1}) and second (${pid2}) init — this is kill-and-restart masquerading as idempotent, not a true no-op"
  fi

  t2c_cleanup
}

test_t2d_state_dir_placement() {
  if skip_if_not_e2e "T2d state-dir placement (container-local, ADR-019 D1)"; then return 0; fi

  local container_name="rc-daemon-test-t2d-$$"
  local image_name="rip-cage:latest"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-XXXXXX")
  local manifest_home
  manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-home-XXXXXX")
  mkdir -p "${manifest_home}/.config/rip-cage"
  cp "${FIXTURES}/manifest-with-trivial-daemon-mcp.yaml" \
     "${manifest_home}/.config/rip-cage/tools.yaml"

  # Cleanup helper — called on every exit path (R4: container leak fix).
  t2d_cleanup() {
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    rm -rf "$workspace" "$manifest_home"
  }

  local build_out
  if ! build_out=$(HOME="$manifest_home" XDG_CONFIG_HOME="${manifest_home}/.config" \
       "${REPO_ROOT}/rc" build 2>&1); then
    fail "T2d Could not build cage image: ${build_out}"
    t2d_cleanup
    return
  fi

  # Start a persistent container, run init, then check state-dir
  if ! docker run -d --name "$container_name" \
       -v "${workspace}:/workspace" \
       "$image_name" sleep infinity >/dev/null 2>&1; then
    fail "T2d Could not start container"
    t2d_cleanup
    return
  fi

  docker exec "$container_name" /usr/local/bin/init-rip-cage.sh >/dev/null 2>&1 || true
  sleep 2

  # State-dir for the trivial fixture daemon is /var/lib/rip-cage-daemon/trivial-test-daemon/
  local state_dir_check
  state_dir_check=$(docker exec "$container_name" \
    test -d /var/lib/rip-cage-daemon/trivial-test-daemon && echo "EXISTS" || echo "MISSING") 2>/dev/null

  if [[ "$state_dir_check" == "EXISTS" ]]; then
    pass "T2d State-dir at /var/lib/rip-cage-daemon/trivial-test-daemon (container-local, ADR-019 D1 extensions pattern)"
  else
    fail "T2d State-dir not found at /var/lib/rip-cage-daemon/trivial-test-daemon. Expected container-local path per ADR-019 D1."
  fi

  t2d_cleanup
}

test_t2e_mcp_fragment_discoverable() {
  if skip_if_not_e2e "T2e MCP fragment discoverable in settings.json"; then return 0; fi

  local container_name="rc-daemon-test-t2e-$$"
  local image_name="rip-cage:latest"
  local workspace
  workspace=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-XXXXXX")
  local manifest_home
  manifest_home=$(mktemp -d "${TMPDIR:-/tmp}/rc-daemon-e2e-home-XXXXXX")
  mkdir -p "${manifest_home}/.config/rip-cage"
  cp "${FIXTURES}/manifest-with-trivial-daemon-mcp.yaml" \
     "${manifest_home}/.config/rip-cage/tools.yaml"

  local build_out
  if ! build_out=$(HOME="$manifest_home" XDG_CONFIG_HOME="${manifest_home}/.config" \
       "${REPO_ROOT}/rc" build 2>&1); then
    fail "T2e Could not build cage image: ${build_out}"
    rm -rf "$workspace" "$manifest_home"
    return
  fi

  # Check the baked settings.json for the MCP fragment
  local mcp_check
  mcp_check=$(docker run --rm "$image_name" \
    jq -r '.mcpServers | keys[]' /etc/rip-cage/settings.json 2>&1)

  if echo "$mcp_check" | grep -q "trivial-test-daemon"; then
    pass "T2e MCP fragment discoverable: 'trivial-test-daemon' present in /etc/rip-cage/settings.json mcpServers"
  else
    fail "T2e MCP fragment: 'trivial-test-daemon' NOT in settings.json mcpServers. keys='${mcp_check}'"
  fi

  rm -rf "$workspace" "$manifest_home"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-manifest-daemon.sh ==="

# T1 host-tier tests (always run)
test_t1a_with_daemon_config_step_present
test_t1b_default_manifest_no_daemon_steps
test_t1c_counterfactual_delta
test_t1d_strict_parse_rejects_missing_start_field
test_t1d2_strict_parse_rejects_missing_health_field
test_t1d3_strict_parse_rejects_missing_state_dir_field
test_t1d4_strict_parse_rejects_invalid_state_dir
test_t1d5_strict_parse_rejects_multiline_install_cmd
test_t1d6_single_line_install_cmd_daemon_accepted_and_baked
test_t1d7_strict_parse_rejects_hostile_build_source
test_t1e_with_mcp_fragment_step_present
test_t1e2_without_mcp_fragment_no_step
test_t1f_build_dockerfile_path_with_daemon
test_t1f2_daemon_config_step_position
test_t1g_d8_default_manifest_original_dockerfile

# T2 e2e tests (NEEDS_CONTAINER / RC_E2E=1)
test_t2a_health_passes_positive_sentinel
test_t2b_broken_daemon_cage_still_starts
test_t2c_init_idempotency_pid_unchanged
test_t2d_state_dir_placement
test_t2e_mcp_fragment_discoverable

echo ""
echo "Results: FAILURES=${FAILURES}"
[[ $FAILURES -eq 0 ]] || exit 1
