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


# usage — the six-verb surface contract (ADR-031 D3).
#
# A verb exists here only where plain shell plus a skill cannot do the job
# identically every run. Adding a seventh line is an ADR-031 D3 decision, not
# an editing convenience; a pass-through wrapper is a second way to do the
# thing, which drifts from the first (ADR-005 D12).
#
# Everything this list used to carry — ls, attach, exec, down, reload,
# allowlist, config, schema, completions, setup, manifest, install,
# generate-dockerfile — reaches usage through the dispatch table's `*)` arm
# and exits 1. The cage-ops skill is the sole home of each one's successor.
usage() {
  cat <<'EOF'
Usage: rc [--output json] [--dry-run] <command> [args]

Commands:
  build [--file PATH]                           Build the cage image from ONE host-side Dockerfile
    --file PATH         The Dockerfile to build. Default: rc's own base image.
                        Must resolve outside every cage mount -- fail-closed,
                        no opt-out. Context: that file's directory (the rc
                        checkout root for rc's own base Dockerfile).
    (anything else)     REJECTED before any docker call. rc build takes exactly
                        one input and hands docker a fixed argv; express the
                        rest in the Dockerfile, which is yours to write. Set
                        RC_IMAGE to build under a different tag.
  up [path] [options]                           Start or resume a cage (default: .)
    --conf FILE         Native msb cage config to launch with. Default:
                        ~/.config/rip-cage/projects/<cage-name>.yaml. Must
                        resolve outside every mount the config declares.
    --replace           Graceful-stop and recreate a RUNNING cage against the
                        current config. A running cage is never recreated
                        implicitly; a STOPPED cage converges on a plain 'rc up'.
    --no-reload         Resume a stopped cage as-is instead of converging it
    --port PORT         Expose a port
    --env-file FILE     Load env vars from file
    --cpus N            CPU limit (default: 2)
    --memory SIZE       Memory limit (default: 4g)
    --pids-limit N      PID limit (default: 500)
    --new               Always start a new multiplexer session (auto-named; invokes new_session hook)
    --session NAME      Forward NAME to the multiplexer attach hook as $1
  destroy [name]                                Remove container and volumes (no prompt, no flags)
  test [name]                                  Run in-container safety stack tests
  test --host                                  Run all host-side tests (host-only; not usable inside container)
  test --e2e                                   Full lifecycle e2e test (slow; RC_E2E_REBUILD=1 to rebuild image)
  test --e2e-security                          Injection-exfil integration probes (slow; real cages; RC_E2E_REBUILD=1 to rebuild)
  doctor [name]                                Per-container diagnostic — labels + live probes
  doctor --host                                Daemon-liveness probe (no container required)
  auth refresh                                 Refresh credentials from host keychain

Cage config: one native microsandbox config file per project. Copy the shipped
template (share/rip-cage/cage.yaml.template) to
~/.config/rip-cage/projects/<cage-name>.yaml and edit it -- rc reads it and
never writes it. Adding an egress host is a line in that file's network.allow,
then 'rc up --replace'.

Everything else is a plain msb command or a file edit -- see the cage-ops
skill. List cages: msb list. Shell into one: msb exec <cage> -- zsh. Stop one:
msb stop <cage>.

Global flags:
  --output json    Emit machine-readable JSON
  --dry-run        Preview what would happen without executing
  --version, -V    Print version and exit
EOF
  exit 1
}

