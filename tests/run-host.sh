#!/usr/bin/env bash
# Runs every host-side test. Exits non-zero on any failure.
# Called by `rc test --host` and CI.
#
# HOST-ONLY INVARIANT: rc exits immediately when /.dockerenv is present.
# This script will never succeed from inside a rip-cage container.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
bash "${SCRIPT_DIR}/test-rc-commands.sh"
bash "${SCRIPT_DIR}/test-worktree-support.sh"
bash "${SCRIPT_DIR}/test-security-hardening.sh"
bash "${SCRIPT_DIR}/test-json-output.sh"
bash "${SCRIPT_DIR}/test-prerequisites.sh"
bash "${SCRIPT_DIR}/test-docker-daemon-hang.sh"
bash "${SCRIPT_DIR}/test-pull-first.sh"
bash "${SCRIPT_DIR}/test-dockerfile-sudoers.sh"
bash "${SCRIPT_DIR}/test-bd-wrapper.sh"
bash "${SCRIPT_DIR}/test-agent-cli.sh"
bash "${SCRIPT_DIR}/test-code-review-fixes.sh"
bash "${SCRIPT_DIR}/test-dg6.2.sh"
bash "${SCRIPT_DIR}/test-auth-refresh.sh"
bash "${SCRIPT_DIR}/test-completions.sh"
bash "${SCRIPT_DIR}/test-pi-install.sh"
bash "${SCRIPT_DIR}/test-pi-auth-mount.sh"
bash "${SCRIPT_DIR}/test-pi-cage-context.sh"
bash "${SCRIPT_DIR}/test-pi-e2e.sh"
bash "${SCRIPT_DIR}/test-config-init.sh"
bash "${SCRIPT_DIR}/test-secret-path-denylist.sh"  # tests/test-secret-path-denylist.sh
bash "${SCRIPT_DIR}/test-egress-rules-gen.sh"      # rip-cage-hhh.2: per-cage egress-rules generation
uv run --with pytest --with pyyaml python -m pytest "${SCRIPT_DIR}/test_egress_proxy.py" -v  # rip-cage-hhh.3: egress proxy enforcement rewrite

echo "=== run-host.sh complete ==="
