#!/usr/bin/env bash
# Runs every host-side test. Exits non-zero on any failure.
# Called by `rc test --host` and CI.
#
# Usage:
#   bash tests/run-host.sh            # run all tests (default)
#   bash tests/run-host.sh --host-only # skip NEEDS_CONTAINER tests (CI mode)
#
# HOST-ONLY INVARIANT: rc exits immediately when /.dockerenv is present.
# This script will never succeed from inside a rip-cage container.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# --host-only flag: parse before the driver fixture so it's set early.
# Classification is a DENYLIST: NEEDS_CONTAINER lists tests that require a
# live cage or ANTHROPIC_API_KEY; everything else runs by default (HOST_ONLY).
# Safe-failure direction: a newly-added test runs in CI by default and fails
# loudly if it actually needs a container — rather than being silently dropped.
# ---------------------------------------------------------------------------
HOST_ONLY_MODE=false
if [[ "${1:-}" == "--host-only" ]]; then
  HOST_ONLY_MODE=true
  export RC_HOST_ONLY=1
fi

# Accumulate failures across ALL test files rather than aborting at the first
# one (set -e would otherwise stop the suite at the first failing test, hiding
# the rest — a thrashing trap for CI where each red cycle costs ~12min). The
# driver runs every test, collects the failures, and exits non-zero at the end.
FAILED_TESTS=()

# Tests that REQUIRE a running rip-cage container or live API key.
# Each entry carries a one-line comment explaining why.
NEEDS_CONTAINER=(
  "test-agent-cli.sh"        # calls rc up to create a live container; exercises full lifecycle
  "test-pi-e2e.sh"           # calls rc up AND requires ~/.pi/agent/auth.json with valid pi credentials
  "test-pi-install.sh"       # runs docker run --rm rip-cage:latest; requires a pre-built rip-cage image
  "test-pi-auth-mount.sh"    # calls rc up to create a live container; inspects container env + mounts
  "test-pi-cage-context.sh"  # calls rc up to create a live container; inspects CLAUDE.md inside cage
  "test-claude-concurrency.sh" # requires a live rip-cage container with Claude auth (ANTHROPIC_API_KEY or OAuth)
  "test-multi-agent-levers.sh" # requires a live rip-cage container; exercises rc agent lever + two-pi concurrency
  "test-agent-mail-concurrent.sh" # requires RC_E2E=1 + pi auth + agent_mail fixture image; proves two concurrent pi agents coordinate via am CLI
)

# Helper: check if a given test basename is in NEEDS_CONTAINER.
_is_needs_container() {
  local name
  name="$(basename "$1")"
  for entry in "${NEEDS_CONTAINER[@]}"; do
    local entry_name
    entry_name="$(echo "$entry" | awk '{print $1}')"
    if [[ "$name" == "$entry_name" ]]; then
      return 0
    fi
  done
  return 1
}

# Run a test file, respecting --host-only mode.
run_test() {
  local test_file="$1"
  if [[ "$HOST_ONLY_MODE" == "true" ]] && _is_needs_container "$test_file"; then
    echo "SKIP (needs container): $(basename "$test_file")"
    return 0
  fi
  # `if !` keeps set -e from aborting the suite; record the failure and continue.
  if ! bash "$test_file"; then
    FAILED_TESTS+=("$(basename "$test_file")")
  fi
}

run_pytest() {
  # Usage: run_pytest <test_file_for_skip_check> <uv run args...>
  # The test_file arg is used only for --host-only classification; the remaining
  # args are passed verbatim to uv run.
  local test_file="$1"
  shift
  if [[ "$HOST_ONLY_MODE" == "true" ]] && _is_needs_container "$test_file"; then
    echo "SKIP (needs container): $(basename "$test_file")"
    return 0
  fi
  if ! uv run "$@"; then
    FAILED_TESTS+=("$(basename "$test_file")")
  fi
}

# ADR-023 secret-path denylist (rip-cage-3gu.2): rc up requires a global
# config file at $RC_CONFIG_GLOBAL or ~/.config/rip-cage/config.yaml.
# Provide a default empty-denylist fixture for the suite so tests don't all
# need to set RC_CONFIG_GLOBAL individually. Tests that verify the
# missing-config preflight (e.g. test-secret-path-denylist.sh case j) override
# this with their own local export.
#
# rip-cage-4c5.8: driver-level manifest fixture (analogous to the config fixture
# above). Seeds a benign empty tools.yaml so any rc invocation that derives its
# manifest path from XDG_CONFIG_HOME (the default path) reads a known-safe default
# (empty file = bundled-only default stack, D8 contract) rather than the developer's
# real ~/.config/rip-cage/tools.yaml. Both fixtures share a single driver temp dir
# and a unified EXIT trap.
#
# ISOLATION: RC_MANIFEST_GLOBAL is NOT exported at the driver level because it has
# higher priority than XDG_CONFIG_HOME in _manifest_global_path(), and exporting
# it would override the per-test sandbox HOME/XDG_CONFIG_HOME used by test-manifest-
# schema.sh, test-manifest-tool.sh, etc. Those tests correctly isolate their
# fixture loading via explicit HOME+XDG_CONFIG_HOME in subprocess calls. The
# driver fixture works through XDG_CONFIG_HOME (exported below) which those tests
# then override per-call. New tests that invoke rc without a sandboxed HOME/XDG
# inherit the driver XDG_CONFIG_HOME and thus the empty tools.yaml.
_RUN_HOST_CFG_DIR=$(mktemp -d)
mkdir -p "${_RUN_HOST_CFG_DIR}/rip-cage"
cat > "${_RUN_HOST_CFG_DIR}/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
# Empty tools.yaml: seeded once at driver level; zero-byte = default bundled stack.
touch "${_RUN_HOST_CFG_DIR}/rip-cage/tools.yaml"
trap 'rm -rf "${_RUN_HOST_CFG_DIR}"' EXIT
export RC_CONFIG_GLOBAL="${RC_CONFIG_GLOBAL:-${_RUN_HOST_CFG_DIR}/rip-cage/config.yaml}"
# XDG_CONFIG_HOME: default to driver temp dir so rc invocations without an explicit
# HOME/XDG sandbox read from the driver fixture. Tests that set HOME+XDG_CONFIG_HOME
# explicitly in their subprocess calls (all test-manifest-*.sh) override this.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${_RUN_HOST_CFG_DIR}}"

# Uncomment each line below after the audit step confirms pass or skip-guard:
run_test "${SCRIPT_DIR}/test-rc-commands.sh"
run_test "${SCRIPT_DIR}/test-worktree-support.sh"
run_test "${SCRIPT_DIR}/test-security-hardening.sh"
run_test "${SCRIPT_DIR}/test-json-output.sh"
run_test "${SCRIPT_DIR}/test-prerequisites.sh"
run_test "${SCRIPT_DIR}/test-docker-daemon-hang.sh"
run_test "${SCRIPT_DIR}/test-pull-first.sh"
run_test "${SCRIPT_DIR}/test-dockerfile-sudoers.sh"
run_test "${SCRIPT_DIR}/test-bd-wrapper.sh"
run_test "${SCRIPT_DIR}/test-agent-cli.sh"
run_test "${SCRIPT_DIR}/test-code-review-fixes.sh"
run_test "${SCRIPT_DIR}/test-dg6.2.sh"
run_test "${SCRIPT_DIR}/test-auth-refresh.sh"
run_test "${SCRIPT_DIR}/test-completions.sh"
run_test "${SCRIPT_DIR}/test-pi-install.sh"
run_test "${SCRIPT_DIR}/test-pi-auth-mount.sh"
run_test "${SCRIPT_DIR}/test-pi-cage-context.sh"
run_test "${SCRIPT_DIR}/test-pi-e2e.sh"
run_test "${SCRIPT_DIR}/test-config-init.sh"
run_test "${SCRIPT_DIR}/test-secret-path-denylist.sh"  # tests/test-secret-path-denylist.sh
run_test "${SCRIPT_DIR}/test-workspace-trust.sh"       # rip-cage-hhh.5: workspace base-URL redirect validator
run_test "${SCRIPT_DIR}/test-egress-rules-gen.sh"      # rip-cage-hhh.2: per-cage egress-rules generation
run_pytest "${SCRIPT_DIR}/test_egress_proxy.py" --with pytest --with pyyaml python -m pytest "${SCRIPT_DIR}/test_egress_proxy.py" -v   # rip-cage-hhh.3: egress proxy enforcement rewrite
run_pytest "${SCRIPT_DIR}/test_dns_decide.py" --with pytest --with dnspython --with pyyaml python -m pytest "${SCRIPT_DIR}/test_dns_decide.py" -v  # rip-cage-hhh.8: DNS resolver sidecar decision logic
run_test "${SCRIPT_DIR}/test-firewall-tcp22.sh"        # rip-cage-hhh.4: TCP-22 IP allowlist + UDP/443 DROP + mode-aware banner
run_test "${SCRIPT_DIR}/test-rc-reload.sh"             # rip-cage-hhh.4: rc reload snapshot format + diff generalization
run_test "${SCRIPT_DIR}/test-rc-allowlist.sh"          # rip-cage-hhh.6: rc allowlist add/show/promote + D10 host-side guard
run_test "${SCRIPT_DIR}/test-ls-mode-source.sh"        # rip-cage-hhh.6: rc ls/doctor mode read from source .rip-cage.yaml not stale label
run_test "${SCRIPT_DIR}/test-dcg-policy.sh"            # rip-cage-hhh.11.2: DCG host-adoptable policy (ADR-025 D1/D5)
run_test "${SCRIPT_DIR}/test-auto-seed.sh"             # rip-cage-j86: rc up auto-seeds global config on first run
run_test "${SCRIPT_DIR}/test-pi-cold-start-seed.sh"   # rip-cage-wo9: rc up seeds ~/.pi/agent/auth.json on cold start
run_test "${SCRIPT_DIR}/test-manifest-schema.sh"       # rip-cage-4c5.1: tool manifest schema/loader (host-only)
# NOTE: T1 cases are host-only; T2 (NEEDS_CONTAINER) self-skips via RC_E2E gate.
# The e2e-tier wiring + driver-level fixture for T2 is rip-cage-4c5.8's job.
run_test "${SCRIPT_DIR}/test-manifest-tool.sh"         # rip-cage-4c5.2: TOOL install-step generation (host-only T1); e2e self-skips via RC_E2E gate
run_test "${SCRIPT_DIR}/test-manifest-egress.sh"       # rip-cage-4c5.3: egress+mounts floor (host-only E1/E1b/E2/E3); e2e self-skips via RC_E2E gate
run_test "${SCRIPT_DIR}/test-manifest-shell.sh"        # rip-cage-4c5.4: SHELL-INTEGRATION shell_init baking (host-only T1); e2e self-skips via RC_E2E gate
run_test "${SCRIPT_DIR}/test-manifest-daemon.sh"       # rip-cage-4c5.5: IN-CAGE-DAEMON lifecycle (host-only T1); e2e self-skips via RC_E2E gate
run_test "${SCRIPT_DIR}/test-manifest-agent-mail.sh"   # rip-cage-4c5.6: agent_mail daemon fixture (host-only T1); e2e self-skips via RC_E2E gate; T2d auth-gated
run_test "${SCRIPT_DIR}/test-manifest-cross.sh"        # rip-cage-4c5.8: cross-cutting integration regressions (H1/H2 always; C1/C2/C3 self-skip via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-claude-concurrency.sh"    # rip-cage-p1p: per-session Claude config isolation (NEEDS_CONTAINER; self-skips if no running cage)
run_test "${SCRIPT_DIR}/test-multi-agent-levers.sh"    # rip-cage-tlm: Tier 1a rc agent lever + two-pi concurrency (NEEDS_CONTAINER; self-skips if no running cage)
run_test "${SCRIPT_DIR}/test-selftest-classifier.sh"   # rip-cage-fft: pure classifier unit tests (no live firewall needed)
run_test "${SCRIPT_DIR}/test-selftest-mode-gating.sh"  # rip-cage-fft: mode-gating tests via curl PATH-shim (no production hook)
run_pytest "${SCRIPT_DIR}/test_selftest_endpoint.py" --with pytest --with pyyaml python -m pytest "${SCRIPT_DIR}/test_selftest_endpoint.py" -v  # rip-cage-fft: proxy reserved endpoint unit tests
run_test "${SCRIPT_DIR}/test-selftest-integration.sh"  # rip-cage-fft: container integration tests (init-firewall.sh → curl → iptables → proxy end-to-end)
run_test "${SCRIPT_DIR}/test-agent-readability.sh"     # rip-cage-7wc: host-side fixture tests for agent *.md readability classification
run_test "${SCRIPT_DIR}/test-agent-mail-concurrent.sh" # rip-cage-swv: two concurrent pi agents coordinate via am CLI (NEEDS_CONTAINER + RC_E2E)

echo "=== run-host.sh complete ==="

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo ""
  echo "=== ${#FAILED_TESTS[@]} TEST FILE(S) FAILED ==="
  for _ft in "${FAILED_TESTS[@]}"; do
    echo "  FAILED: ${_ft}"
  done
  exit 1
fi
