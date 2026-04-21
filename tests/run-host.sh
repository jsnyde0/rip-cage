#!/usr/bin/env bash
# Runs every host-side test. Exits non-zero on any failure.
# Called by `rc test --host` and CI.
#
# HOST-ONLY INVARIANT: rc exits immediately when /.dockerenv is present.
# This script will never succeed from inside a rip-cage container.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Uncomment each line below after the audit step confirms pass or skip-guard:
bash "${SCRIPT_DIR}/test-rc-commands.sh"
bash "${SCRIPT_DIR}/test-worktree-support.sh"
bash "${SCRIPT_DIR}/test-security-hardening.sh"
bash "${SCRIPT_DIR}/test-json-output.sh"
bash "${SCRIPT_DIR}/test-prerequisites.sh"
bash "${SCRIPT_DIR}/test-dockerfile-sudoers.sh"
bash "${SCRIPT_DIR}/test-bd-wrapper.sh"
bash "${SCRIPT_DIR}/test-agent-cli.sh"
bash "${SCRIPT_DIR}/test-code-review-fixes.sh"
bash "${SCRIPT_DIR}/test-dg6.2.sh"
bash "${SCRIPT_DIR}/test-auth-refresh.sh"
bash "${SCRIPT_DIR}/test-completions.sh"

echo "=== run-host.sh complete ==="
