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
  "test-multiplexer-lifecycle.sh" # requires a live rip-cage container; exercises multiplexer lifecycle (none/tmux/herdr) + retirement + config-isolation (rip-cage-1f59.8)
  "test-agent-mail-concurrent.sh" # requires RC_E2E=1 + pi auth + agent_mail fixture image; proves two concurrent pi agents coordinate via am CLI
  "test-ssh-forwarding.sh"    # ADR-017/018 live-cage ssh-agent socket mount/label/sentinels; self-skips without docker (rip-cage-b6ia)
  "test-ssh-resolver.sh"      # Tests 6-10 spin up live cages; Tests 1-5 are host unit tests of _parse_identity_rules/_resolve_github_identity, already covered by test-ssh-config.sh checks 10-13 — whole file denylisted, no unique host coverage lost under --host-only (rip-cage-b6ia)
  "test-session-persistence.sh" # Phase 3 calls rc up + docker exec for dn2 projects/sessions persist-to-host (rip-cage-b6ia)
  "test-pi-dcg-gate.sh"       # asserts in-cage pi dcg-gate.ts + dcg-guard paths; \`command -v pi\` would vacuously skip on host (rip-cage-b6ia)
  "test-pi-no-extensions.sh"  # rip-cage-sn1h: pi wrapper --no-extensions regression probe; requires running cage
  "test-skills.sh"            # live meta-skill MCP handshake + cage-path/settings assertions inside a container (rip-cage-b6ia)
  "test-multiplexer-agent-e2e.sh" # requires RC_E2E=1 + pi auth; proves pi agent does real work THROUGH the tmux attach surface with >=2 distinct tool invocations (rip-cage-w621.7)
  "test-multiplexer-composable.sh" # E1 tier builds + runs a cage; G1 host-only grep-guards run always (rip-cage-61al.8)
  "test-symlink-follow.sh"    # needs a non-reserved writable scratch dir for symlink targets; on Linux every writable top-level (/home,/tmp,/var) is in rc's FHS-reserved set (rc:1511-1513), so it only runs on macOS (mktemp→/private/var dodges rc's deliberate non-canonicalization). Not "needs a cage" but host-only-Linux-incompatible (rip-cage-woow)
  "test-cc-managed-settings-probe.sh" # rip-cage-wlwc.1: D8 CC managed-settings anchor probe — requires live authed cage + API call; self-skips if no cage or unauthed (NEEDS_CONTAINER+AUTH)
  "test-cc-dcg-managed-settings.sh"  # rip-cage-r9n4: DCG managed-settings regression — proves managed deny survives stripping ALL agent-writable layers; requires live authed cage (NEEDS_CONTAINER+AUTH)
  "test-mount-mode-e2e.sh"           # rip-cage-wlwc.3: real-cage ro/rw behavioral probes (RE1-RE3); self-skips without RC_E2E=1
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
run_test "${SCRIPT_DIR}/test-rc-source-isolation.sh" # rip-cage-k2d5: rc source isolation — set -e must not leak when sourcing rc
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
run_test "${SCRIPT_DIR}/test-manifest-herdr.sh"        # rip-cage-1f59.5: herdr TOOL fixture (T1a-T1g always; T2a-T2d self-skip via RC_E2E gate; T2d = ADR-006 D8 auto-install regression guard)
run_test "${SCRIPT_DIR}/test-manifest-cm.sh"           # rip-cage-l0u2.4: cm binary + mount e2e proof (T1a always; T2a-T2d self-skip via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-manifest-mounts.sh"      # rip-cage-buuo.1: manifest mounts schema + consumer (host-only MV1/MH*/MD1/MC*; ME1 self-skips via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-manifest-source.sh"      # rip-cage-buuo.2: from-source builder stage schema + codegen (host-only S1-S10; SE1 self-skips via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-manifest-security.sh"   # rip-cage-buuo.3: binary-root-owned + build-isolation assertions (host-only B1a-d/BI1a-h; BE1-BE2 self-skip via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-manifest-mount-mode.sh"  # rip-cage-wlwc.3: per-asset ro/rw mount mode + root_owned_required validator (MS1-MS8/MA1-MA4/MR1-MR5/MD1-MD2 host-only; RE1-RE3 real-cage in test-mount-mode-e2e.sh)
run_test "${SCRIPT_DIR}/test-mount-mode-e2e.sh"       # rip-cage-wlwc.3: real-cage ro/rw behavioral probes (RE1-RE3; NEEDS_CONTAINER/RC_E2E, self-skips without RC_E2E=1)
run_test "${SCRIPT_DIR}/test-manifest-multiplexer-validate.sh" # rip-cage-61al.1: MULTIPLEXER archetype validation (T1a-T1m host-only)
run_test "${SCRIPT_DIR}/test-multiplexer-registry-bake.sh"     # rip-cage-61al.2: MULTIPLEXER registry bake + label + reference reader (T1a-T1g host-only; T2a-T2e self-skip via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-multiplexer-config-dynamic.sh"    # rip-cage-61al.4: dynamic session.multiplexer schema + config-validate (T1a-T1e host-only; T2a-T2c self-skip via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-multiplexer-composable.sh"        # rip-cage-61al.8: composability integration harness — live fakemux e2e + exhaustive grep-guard (G1 host-only; E1a-E1g self-skip via RC_E2E gate)
run_test "${SCRIPT_DIR}/test-mediator-manifest.sh"             # rip-cage-ta1o.5.1: MEDIATOR archetype manifest validation (T1a-T1l host-only)
run_test "${SCRIPT_DIR}/test-mediator-lifecycle.sh"            # rip-cage-ta1o.5.8: egress-mediator launch seam — host-driven init-mediator.sh launcher + fail-closed uid + ordering (G1/U1/U2/O1 host-only)
run_test "${SCRIPT_DIR}/test-mediator-validator.sh"           # rip-cage-ta1o.5.3: fail-closed validator bounds MEDIATOR hooks — RIP_CAGE_EGRESS=/iptables/floor-weakening + both build entrypoints (T1a-T1j host-only)
run_test "${SCRIPT_DIR}/test-skill-manifest-author.sh" # rip-cage-buuo.4: repo-shipped skill — skill well-formed + cm worked example passes _manifest_validate (SA1-SA7 host-only)
run_test "${SCRIPT_DIR}/test-claude-concurrency.sh"    # rip-cage-p1p: per-session Claude config isolation (NEEDS_CONTAINER; self-skips if no running cage)
run_test "${SCRIPT_DIR}/test-cc-managed-settings-probe.sh"  # rip-cage-wlwc.1: D8 CC managed-settings anchor probe — enforces un-suppressibly + deny-wins? (NEEDS_CONTAINER+AUTH; self-skips if no cage or unauthed)
run_test "${SCRIPT_DIR}/test-cc-dcg-managed-settings.sh"   # rip-cage-r9n4: DCG managed-settings regression — managed deny survives stripping ALL agent-writable layers (NEEDS_CONTAINER+AUTH; self-skips if no cage or unauthed)
run_test "${SCRIPT_DIR}/test-multiplexer-lifecycle.sh"  # rip-cage-1f59.8: multiplexer lifecycle (none/tmux/herdr) + retirement + config-isolation (NEEDS_CONTAINER; self-skips without RC_E2E=1)
run_test "${SCRIPT_DIR}/test-selftest-classifier.sh"   # rip-cage-fft: pure classifier unit tests (no live firewall needed)
run_test "${SCRIPT_DIR}/test-selftest-mode-gating.sh"  # rip-cage-fft: mode-gating tests via curl PATH-shim (no production hook)
run_pytest "${SCRIPT_DIR}/test_selftest_endpoint.py" --with pytest --with pyyaml python -m pytest "${SCRIPT_DIR}/test_selftest_endpoint.py" -v  # rip-cage-fft: proxy reserved endpoint unit tests
run_test "${SCRIPT_DIR}/test-selftest-integration.sh"  # rip-cage-fft: container integration tests (init-firewall.sh → curl → iptables → proxy end-to-end)
run_test "${SCRIPT_DIR}/test-agent-readability.sh"     # rip-cage-7wc: host-side fixture tests for agent *.md readability classification
run_test "${SCRIPT_DIR}/test-agent-mail-concurrent.sh" # rip-cage-swv: two concurrent pi agents coordinate via am CLI (NEEDS_CONTAINER + RC_E2E)
run_test "${SCRIPT_DIR}/test-multiplexer-agent-e2e.sh" # rip-cage-w621.7: pi agent through tmux mux surface with >=2 distinct tool invocations (NEEDS_CONTAINER + RC_E2E)
run_test "${SCRIPT_DIR}/test-ssh-config.sh"            # rip-cage-b0a: SSH config translation checks incl. ADR-022 D4 inverse assertion (host-side; no container needed)
run_test "${SCRIPT_DIR}/test-allowed-roots-bypass.sh"  # rip-cage-36j: RC_ALLOWED_ROOTS bypass regression net (symlink/redirect cases)

# rip-cage-b6ia: previously-dark test files, audited 2026-06-09 and wired.
# Host-tier (run on every invocation):
run_test "${SCRIPT_DIR}/test-ssh-preflight.sh"        # ADR-020 identity-preflight cache (cold/warm/mismatch/TTL/JSON shape)
run_test "${SCRIPT_DIR}/test-ssh-visibility.sh"       # ADR-020 D5 visibility surfaces (zshrc/init banner, rc ls GH-IDENTITY col) + 9eg regression
run_test "${SCRIPT_DIR}/test-bd-host-preflight.sh"    # _bd_host_preflight dolt-server preflight helper (host-only)
run_test "${SCRIPT_DIR}/test-lfs-warning.sh"          # rc --dry-run up LFS pointer-stub scan + silent-exit-1 regression
run_test "${SCRIPT_DIR}/test-ssh-allowlist.sh"        # ADR-022 known_hosts filter + hashed-host HMAC + resume mount-shape guard (EXIT-trap fixed)
run_test "${SCRIPT_DIR}/test-denylist-matching.sh"    # _check_secret_path_denylist component-match (unsets RC_CONFIG_GLOBAL per driver-fixture trap)
run_test "${SCRIPT_DIR}/test-pi-substrate-mounts.sh"  # rip-cage-kstk: pi substrate projection mount args + denylist + init symlinks + floor-protection
run_test "${SCRIPT_DIR}/test-symlink-follow.sh"       # symlink-follow scanner + fingerprint + denylist gating (unsets RC_CONFIG_GLOBAL)
run_test "${SCRIPT_DIR}/test-config-loader.sh"        # layered config additive/select merge + provenance matrix (unsets RC_CONFIG_GLOBAL)
# Container-tier (NEEDS_CONTAINER above; self-skip under --host-only, run on full invocation):
run_test "${SCRIPT_DIR}/test-ssh-forwarding.sh"       # ADR-017/018 live ssh-agent forwarding
run_test "${SCRIPT_DIR}/test-ssh-resolver.sh"         # github-identity resolver; Tests 6-10 spin up cages
run_test "${SCRIPT_DIR}/test-session-persistence.sh"  # dn2 projects/sessions persist-to-host (Phase 3 container)
run_test "${SCRIPT_DIR}/test-pi-dcg-gate.sh"          # in-cage pi dcg-gate.ts structural + exec-field parity
run_test "${SCRIPT_DIR}/test-pi-no-extensions.sh"     # rip-cage-sn1h: pi wrapper --no-extensions regression (evil.ts NOT loaded + DCG still denies)
run_test "${SCRIPT_DIR}/test-skills.sh"               # meta-skill MCP handshake + cage-path/settings inside cage

echo "=== run-host.sh complete ==="

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo ""
  echo "=== ${#FAILED_TESTS[@]} TEST FILE(S) FAILED ==="
  for _ft in "${FAILED_TESTS[@]}"; do
    echo "  FAILED: ${_ft}"
  done
  exit 1
fi
