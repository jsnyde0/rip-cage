#!/usr/bin/env bash
# cli/lib/output.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# Output helpers
json_error() {
  local msg="$1" code="$2"
  jq -nc --arg error "$msg" --arg code "$code" '{error: $error, code: $code}'
  exit 1
}

log() {
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "$@" >&2
  else
    echo "$@"
  fi
}


# prerequisite_error <tool> <brew-pkg> <apt-pkg>
# Prints a helpful "not found + how to install" message and exits.
_prereq_error() {
  local tool="$1" brew_pkg="$2" apt_pkg="$3"
  echo "Error: '$tool' is required but not installed." >&2
  echo "  macOS:  brew install ${brew_pkg}" >&2
  echo "  Linux:  sudo apt install ${apt_pkg}" >&2
  exit 1
}


# check_jq — verifies jq is installed (required for --output json).
check_jq() {
  if ! command -v jq &>/dev/null; then
    _prereq_error "jq" "jq" "jq"
  fi
}


usage() {
  cat <<'EOF'
Usage: rc [--output json] [--dry-run] <command> [args]

Commands:
  build [docker-args...]                       Build the rip-cage image
  up [path] [options]                           Start or resume a container (default: .)
    --port PORT         Expose a port
    --env-file FILE     Load env vars from file
    --cpus N            CPU limit (default: 2)
    --memory SIZE       Memory limit (default: 4g)
    --pids-limit N      PID limit (default: 500)
    --new               Always start a new multiplexer session (auto-named; invokes new_session hook)
    --session NAME      Forward NAME to the multiplexer attach hook as $1
  ls                                           List rip-cage containers
  attach [name]                                Attach to container (multiplexer-aware; plain shell under none)
  exec <cage> -- <cmd...>                      Run a one-off command in the container (non-interactive safe)
  down [name]                                  Stop a container
  destroy [-f|--force] [name]                   Remove container and volumes
  reload [name] [--dry-run]                     Hot-reload .rip-cage.yaml allowlist changes (network.allowed_hosts)
  allowlist add <host> [--cage=<name>]         Append host to network.allowed_hosts (idempotent; --output json)
  allowlist show [--effective] [--observed]    Show configured/effective/observed blocked hosts
  allowlist promote --from-observed [--cage]   Merge observed blocked hosts + flip mode=block + rc reload
  test [name]                                  Run in-container safety stack tests
  test --host                                  Run all host-side tests (host-only; not usable inside container)
  test --e2e                                   Full lifecycle e2e test (slow; RC_E2E_REBUILD=1 to rebuild image)
  test --e2e-security                          Injection-exfil integration probes (slow; real cages; RC_E2E_REBUILD=1 to rebuild)
  doctor [name]                                Per-container diagnostic — labels + live probes
  doctor --host                                Daemon-liveness probe (no container required)
  auth refresh                                 Refresh credentials from host keychain
  config show [path] [--json]                  Print effective .rip-cage.yaml config (ADR-021); path defaults to pwd
  config get <key> [path] [--json]             Print one effective config value (dotted.key; rip-cage-08q)
  config set <key> <value> --scope S           Set a scalar/enum (S=global|project; surgical, comment-preserving; ADR-021 D8)
  config add <key> <item> --scope S            Add a list item (S=global|project)
  config remove <key> <item> --scope S         Remove a list item (S=global|project)
  manifest reconcile                           Re-seed default-derived tools.yaml entries from current
                                                manifest/default-tools.yaml, preserving custom entries (rip-cage-6vt9)
  schema                                       Print machine-readable command schema
  completions <shell>                          Print shell completion script (zsh|bash)
  setup                                        Interactive shell integration setup

Global flags:
  --output json    Emit machine-readable JSON
  --dry-run        Preview what would happen without executing
  --version, -V    Print version and exit
EOF
  exit 1
}

