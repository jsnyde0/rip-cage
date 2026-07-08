#!/usr/bin/env bash
# cli/allowlist.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# cmd_allowlist — agent-first CLI for network.allowed_hosts management (rip-cage-hhh.6 / epic D11).
#
# Subcommands:
#   add <host> [--cage=<name>] [--config-file=<path>] [--output json]
#     Append host to network.allowed_hosts in .rip-cage.yaml (idempotent).
#     If --cage given, run rc reload <cage> after editing to apply live.
#
#   show [--effective] [--observed] [--cage=<name>] [--config-file=<path>] [--log-file=<path>]
#     Default (JSON): list configured network.allowed_hosts.
#     --effective: show merged allowlist with provenance (ADR-021 D4).
#     --observed: read egress JSONL log and list blocked/would-block hosts.
#
#   promote --from-observed [--cage=<name>] [--config-file=<path>] [--log-file=<path>]
#     Read observed egress log, merge unique blocked hosts into .rip-cage.yaml
#     network.allowed_hosts, flip network.mode to block, then invoke rc reload --cage if given.
#     Emits a diff of the .rip-cage.yaml mutation (hosts added + mode flip).
#
# D10 host-side-only: add and promote are refused when RC_TEST_FAKE_DOCKERENV=1
# (host-unit-test simulation of in-cage; real in-cage is blocked by the global
# /.dockerenv guard at rc startup).
# show is allowed in-cage (read-only).
#
# ADRs: ADR-003 D1/D4/D5, ADR-021 D4, ADR-022 D6, epic D10/D11.
cmd_allowlist() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    add)     _allowlist_add "$@" ;;
    show)    _allowlist_show "$@" ;;
    promote) _allowlist_promote "$@" ;;
    *)
      echo "Usage: rc allowlist <add|show|promote> [options]" >&2
      echo "  add <host> [--cage=<name>] [--config-file=<path>]" >&2
      echo "  show [--effective] [--observed] [--config-file=<path>] [--log-file=<path>]" >&2
      echo "  promote --from-observed [--cage=<name>] [--config-file=<path>] [--log-file=<path>]" >&2
      exit 1
      ;;
  esac
}


# _allowlist_is_in_cage: returns 0 if we should refuse (in-cage simulation for test OR real in-cage
# via the global /.dockerenv guard which fires before we get here in real usage).
# For unit-test purposes: simulated by RC_TEST_FAKE_DOCKERENV=1.
_allowlist_is_in_cage() {
  [[ "${RC_TEST_FAKE_DOCKERENV:-}" == "1" ]]
}


# _allowlist_refuse_in_cage: print error and exit when in-cage (D10 guard).
_allowlist_refuse_in_cage() {
  local subcmd="$1"
  echo "Error: 'rc allowlist ${subcmd}' is a host-only command — it mutates effective config via rc reload." >&2
  echo "You appear to be inside a rip-cage container. To add a host:" >&2
  echo "  - Surface the request in prose to the human (e.g. 'please add <host> to .rip-cage.yaml')" >&2
  echo "  - The human (or a host-side assistant) edits .rip-cage.yaml on the host" >&2
  echo "  - Then the human runs on the host: rc reload <cage-name>" >&2
  echo "  Note: .rip-cage.yaml is read-only inside the cage by default (ADR-021 D7 / mounts.config_mode); under mounts.config_mode=rw you may edit it in-cage, but rc reload is host-only regardless." >&2
  exit 1
}


# _allowlist_resolve_config_file: given an explicit override or empty, return the
# project .rip-cage.yaml path. Uses CWD as workspace root when no override is given.
_allowlist_resolve_config_file() {
  local override="$1"
  if [[ -n "$override" ]]; then
    echo "$override"
  else
    echo "${PWD}/.rip-cage.yaml"
  fi
}


# _allowlist_add_host_to_yaml: idempotently append <host> to network.allowed_hosts
# in the given YAML file. Creates the file with version: 1 if absent.
# Returns 0=added, 1=skipped (already present).
_allowlist_add_host_to_yaml() {
  local host="$1" yaml_file="$2"

  # Create minimal file if absent.
  if [[ ! -f "$yaml_file" ]]; then
    printf 'version: 1\nnetwork:\n  allowed_hosts: []\n' > "$yaml_file"
  fi

  # Check if host already present (line-level scan — avoids yq parse for simple idempotency).
  if grep -qxF "    - ${host}" "$yaml_file" 2>/dev/null || \
     grep -qxF "  - ${host}" "$yaml_file" 2>/dev/null; then
    return 1  # skipped
  fi

  # Ensure network.allowed_hosts exists with yq; append the host.
  if ! command -v yq &>/dev/null; then
    echo "Error: yq not found on PATH. Install yq (brew install yq, or the mikefarah/yq release binary on Linux: https://github.com/mikefarah/yq/releases — NOT apt's yq, which is the incompatible python-yq) to use rc allowlist." >&2
    exit 1
  fi

  # Use yq to append to the list. yq v4 (mikefarah) syntax.
  local tmp_file
  tmp_file=$(mktemp)
  yq '.network.allowed_hosts += ["'"$host"'"]' "$yaml_file" > "$tmp_file"
  cp "$tmp_file" "$yaml_file"
  rm -f "$tmp_file"
  return 0
}


_allowlist_add() {
  local host="" cage="" config_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cage=*)       cage="${1#--cage=}"; shift ;;
      --cage)         cage="$2"; shift 2 ;;
      --config-file=*) config_file="${1#--config-file=}"; shift ;;
      --config-file)  config_file="$2"; shift 2 ;;
      -*) echo "Error: unknown option for allowlist add: $1" >&2; exit 1 ;;
      *)  host="$1"; shift ;;
    esac
  done

  if [[ -z "$host" ]]; then
    echo "Error: rc allowlist add requires a host argument" >&2; exit 1
  fi

  # D10: refuse when in-cage.
  if _allowlist_is_in_cage; then
    _allowlist_refuse_in_cage "add"
  fi

  local yaml_file
  yaml_file=$(_allowlist_resolve_config_file "$config_file")

  local added_or_skipped="added"
  if ! _allowlist_add_host_to_yaml "$host" "$yaml_file"; then
    added_or_skipped="skipped"
  fi

  # If --cage given and we added (or even skipped), run rc reload to apply.
  if [[ -n "$cage" && "$added_or_skipped" == "added" ]]; then
    log "Running rc reload $cage to apply..."
    "$0" reload "$cage" || true
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc \
      --arg action "$added_or_skipped" \
      --arg host "$host" \
      --arg config_file "$yaml_file" \
      '{action: $action, host: $host, config_file: $config_file}'
  else
    if [[ "$added_or_skipped" == "added" ]]; then
      echo "Added '$host' to network.allowed_hosts in $yaml_file"
    else
      echo "Skipped '$host' — already in network.allowed_hosts in $yaml_file"
    fi
  fi
}


# _allowlist_read_observed_hosts: read egress JSONL log(s), extract unique hosts
# from deny/would-block events. Reads HTTP log + DNS log.
# Args: $1=http_log_path $2=dns_log_path (either may be empty/absent)
# Output: one host per line, deduped, sorted.
_allowlist_read_observed_hosts() {
  local http_log="${1:-}" dns_log="${2:-}"
  {
    if [[ -f "$http_log" ]]; then
      jq -r 'select(.event == "deny" or .event == "would-block") | .host' "$http_log" 2>/dev/null || true
    fi
    if [[ -f "$dns_log" ]]; then
      jq -r 'select(.event == "deny" or .event == "would-block") | .host' "$dns_log" 2>/dev/null || true
    fi
  } | grep -v '^$' | grep -v '^null$' | sort -u
}


_allowlist_show() {
  local show_effective=0 show_observed=0 cage="" config_file="" log_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --effective)      show_effective=1; shift ;;
      --observed)       show_observed=1; shift ;;
      --cage=*)         cage="${1#--cage=}"; shift ;;
      --cage)           cage="$2"; shift 2 ;;
      --config-file=*)  config_file="${1#--config-file=}"; shift ;;
      --config-file)    config_file="$2"; shift 2 ;;
      --log-file=*)     log_file="${1#--log-file=}"; shift ;;
      --log-file)       log_file="$2"; shift 2 ;;
      -*) echo "Error: unknown option for allowlist show: $1" >&2; exit 1 ;;
      *)  cage="$1"; shift ;;  # positional = cage name
    esac
  done

  local yaml_file
  yaml_file=$(_allowlist_resolve_config_file "$config_file")

  if [[ "$show_observed" -eq 1 ]]; then
    # Derive log file from cage workspace or explicit --log-file.
    local http_log dns_log
    if [[ -n "$log_file" ]]; then
      http_log="$log_file"
      dns_log="${log_file%egress.log}egress-dns.log"
    elif [[ -n "$cage" ]]; then
      local ws
      ws=$(docker inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$cage" 2>/dev/null || true)
      http_log="${ws}/.rip-cage/egress.log"
      dns_log="${ws}/.rip-cage/egress-dns.log"
    else
      # Try CWD workspace
      http_log="${PWD}/.rip-cage/egress.log"
      dns_log="${PWD}/.rip-cage/egress-dns.log"
    fi

    local observed_hosts
    observed_hosts=$(_allowlist_read_observed_hosts "$http_log" "$dns_log")

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      local hosts_json
      hosts_json=$(printf '%s\n' "$observed_hosts" | grep -v '^$' | jq -R . | jq -sc .)
      jq -nc --argjson h "$hosts_json" '{observed_hosts: $h}'
    else
      echo "Observed blocked/would-block hosts:"
      if [[ -z "$observed_hosts" ]]; then
        echo "  (none)"
      else
        while IFS= read -r h; do
          [[ -n "$h" ]] && echo "  $h"
        done <<<"$observed_hosts"
      fi
    fi
    return 0
  fi

  if [[ "$show_effective" -eq 1 ]]; then
    # Show merged allowlist with provenance via _load_effective_config.
    local workspace
    if [[ -n "$config_file" ]]; then
      workspace="$(dirname "$yaml_file")"
    else
      workspace="${PWD}"
    fi
    local eff_result
    eff_result=$(_load_effective_config "$workspace" 2>/dev/null) || {
      echo "Error: failed to load effective config" >&2; exit 1; }
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo "$eff_result"
    else
      _config_format_yaml "$eff_result"
    fi
    return 0
  fi

  # Default: list configured network.allowed_hosts from the project file.
  local allowed_hosts_json
  if [[ -f "$yaml_file" ]] && command -v yq &>/dev/null; then
    allowed_hosts_json=$(yq -o=json '.network.allowed_hosts // []' "$yaml_file" 2>/dev/null) || allowed_hosts_json="[]"
  else
    allowed_hosts_json="[]"
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc --argjson h "$allowed_hosts_json" \
      --arg config_file "$yaml_file" \
      '{allowed_hosts: $h, config_file: $config_file}'
  else
    echo "Configured network.allowed_hosts in $yaml_file:"
    if [[ "$allowed_hosts_json" == "[]" || -z "$allowed_hosts_json" ]]; then
      echo "  (none)"
    else
      jq -r '.[]' <<<"$allowed_hosts_json" | while IFS= read -r h; do echo "  $h"; done
    fi
  fi
}


_allowlist_promote() {
  local from_observed=0 cage="" config_file="" log_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-observed)  from_observed=1; shift ;;
      --cage=*)         cage="${1#--cage=}"; shift ;;
      --cage)           cage="$2"; shift 2 ;;
      --config-file=*)  config_file="${1#--config-file=}"; shift ;;
      --config-file)    config_file="$2"; shift 2 ;;
      --log-file=*)     log_file="${1#--log-file=}"; shift ;;
      --log-file)       log_file="$2"; shift 2 ;;
      -*) echo "Error: unknown option for allowlist promote: $1" >&2; exit 1 ;;
      *)  cage="$1"; shift ;;
    esac
  done

  if [[ "$from_observed" -eq 0 ]]; then
    echo "Error: rc allowlist promote requires --from-observed" >&2; exit 1
  fi

  # D10: refuse when in-cage.
  if _allowlist_is_in_cage; then
    _allowlist_refuse_in_cage "promote"
  fi

  local yaml_file
  yaml_file=$(_allowlist_resolve_config_file "$config_file")

  if ! command -v yq &>/dev/null; then
    echo "Error: yq not found on PATH. Install yq (brew install yq, or the mikefarah/yq release binary on Linux: https://github.com/mikefarah/yq/releases — NOT apt's yq, which is the incompatible python-yq) to use rc allowlist." >&2
    exit 1
  fi

  # Create minimal file if absent.
  if [[ ! -f "$yaml_file" ]]; then
    printf 'version: 1\nnetwork:\n  allowed_hosts: []\n  mode: observe\n' > "$yaml_file"
  fi

  # Resolve log files.
  local http_log dns_log
  if [[ -n "$log_file" ]]; then
    http_log="$log_file"
    dns_log="${log_file%egress.log}egress-dns.log"
  elif [[ -n "$cage" ]]; then
    local ws
    ws=$(docker inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$cage" 2>/dev/null || true)
    http_log="${ws}/.rip-cage/egress.log"
    dns_log="${ws}/.rip-cage/egress-dns.log"
  else
    http_log="${PWD}/.rip-cage/egress.log"
    dns_log="${PWD}/.rip-cage/egress-dns.log"
  fi

  # Read observed hosts.
  local observed_hosts
  observed_hosts=$(_allowlist_read_observed_hosts "$http_log" "$dns_log")

  # Read current allowed_hosts from yaml (for idempotency check + diff).
  local current_hosts_json
  current_hosts_json=$(yq -o=json '.network.allowed_hosts // []' "$yaml_file" 2>/dev/null) || current_hosts_json="[]"
  local current_mode
  current_mode=$(yq -r '.network.mode // "null"' "$yaml_file" 2>/dev/null) || current_mode="null"

  # Compute which hosts to add (observed minus already-present).
  local hosts_to_add=()
  local h
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    # Check if already in current list.
    if ! jq -e --arg h "$h" '. | index($h) != null' <<<"$current_hosts_json" >/dev/null 2>&1; then
      hosts_to_add+=("$h")
    fi
  done <<<"$observed_hosts"

  # Emit diff header.
  echo "=== rc allowlist promote: .rip-cage.yaml mutation diff ==="
  if [[ ${#hosts_to_add[@]} -eq 0 ]]; then
    echo "  network.allowed_hosts: no new hosts to add (all observed hosts already present)"
  else
    echo "  network.allowed_hosts: adding ${#hosts_to_add[@]} host(s):"
    for h in "${hosts_to_add[@]}"; do
      echo "    + $h"
    done
  fi

  if [[ "$current_mode" != "block" ]]; then
    echo "  network.mode: ${current_mode} -> block"
  else
    echo "  network.mode: already block (no change)"
  fi
  echo "=== end diff ==="

  # Apply mutations to the YAML file.
  local tmp_file
  tmp_file=$(mktemp)

  # Build updated allowed_hosts: current ∪ observed (order-preserving dedup).
  local new_hosts_json="$current_hosts_json"
  for h in "${hosts_to_add[@]}"; do
    new_hosts_json=$(jq -c --arg h "$h" '. + [$h]' <<<"$new_hosts_json")
  done

  # Write updated YAML using yq: set network.allowed_hosts and network.mode.
  yq -r ".network.allowed_hosts = ${new_hosts_json} | .network.mode = \"block\"" "$yaml_file" > "$tmp_file"
  cp "$tmp_file" "$yaml_file"
  rm -f "$tmp_file"

  # If --cage given, invoke rc reload to apply.
  if [[ -n "$cage" ]]; then
    log "Running rc reload $cage to apply..."
    "$0" reload "$cage" || true
  fi
}

