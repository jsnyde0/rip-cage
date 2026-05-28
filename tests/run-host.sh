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
fi

# Tests that REQUIRE a running rip-cage container or live API key.
# Each entry carries a one-line comment explaining why.
NEEDS_CONTAINER=(
  "test-agent-cli.sh"        # calls rc up to create a live container; exercises full lifecycle
  "test-pi-e2e.sh"           # calls rc up AND requires ~/.pi/agent/auth.json with valid pi credentials
  "test-pi-install.sh"       # runs docker run --rm rip-cage:latest; requires a pre-built rip-cage image
  "test-pi-auth-mount.sh"    # calls rc up to create a live container; inspects container env + mounts
  "test-pi-cage-context.sh"  # calls rc up to create a live container; inspects CLAUDE.md inside cage
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
  bash "$test_file"
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
  uv run "$@"
}

# ADR-023 secret-path denylist (rip-cage-3gu.2): rc up requires a global
# config file at $RC_CONFIG_GLOBAL or ~/.config/rip-cage/config.yaml.
# Provide a default empty-denylist fixture for the suite so tests don't all
# need to set RC_CONFIG_GLOBAL individually. Tests that verify the
# missing-config preflight (e.g. test-secret-path-denylist.sh case j) override
# this with their own local export.
_RUN_HOST_CFG_DIR=$(mktemp -d)
cat > "${_RUN_HOST_CFG_DIR}/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
trap 'rm -rf "${_RUN_HOST_CFG_DIR}"' EXIT
export RC_CONFIG_GLOBAL="${RC_CONFIG_GLOBAL:-${_RUN_HOST_CFG_DIR}/config.yaml}"

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

echo "=== run-host.sh complete ==="
