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
#     --observed: RETIRED under msb (rip-cage-tsf2.2 loud-fail stub, ADR-029).
#       The in-cage egress log this read no longer exists; the flag now
#       exits non-zero instead of silently reporting "(none)". Fast-follow
#       (redesign/removal) tracked at rip-cage-tsf2.2.
#
#   promote --from-observed [--cage=<name>] [--config-file=<path>] [--log-file=<path>]
#     RETIRED under msb (rip-cage-tsf2.2 loud-fail stub, ADR-029). Used to
#     read the observed egress log and merge blocked hosts into
#     .rip-cage.yaml; the log producer no longer exists, so the flag now
#     exits non-zero instead of silently applying nothing. Fast-follow
#     (redesign/removal) tracked at rip-cage-tsf2.2.
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


# _allowlist_add_host_to_yaml: idempotently add <host> to network.allowed_hosts
# in the given YAML file. Creates the file with version: 2 if absent.
# Returns 0=added, 1=skipped (already present).
#
# ADR-021 D8 (rip-cage-tsf2.10.4): `rc allowlist add` is now SUGAR over the
# shared surgical write path — the bespoke `yq += [...]` re-emit (which dropped
# comments/blank lines) is replaced by delegation to _config_edit_apply, the
# same comment-preserving engine `rc config add network.allowed_hosts` uses.
# _config_edit_apply owns idempotency itself (return code 2 = already
# present) so this wrapper just translates that engine contract (0=added,
# 1=refused/error, 2=idempotent no-op) onto allowlist's own long-standing CLI
# contract (0=added, 1=skipped) — including every engine-level safety guard
# (newline-injection refusal, F-GATE verification, etc.) for free, on this
# path too.
_allowlist_add_host_to_yaml() {
  local host="$1" yaml_file="$2"

  # NOTE: the shim owns `set -e`; use `|| rc=$?` (not a bare call) so a
  # non-zero return (2 = idempotent no-op, 1 = refused) doesn't trip errexit
  # before this function gets to translate the engine's contract onto
  # allowlist's own (same defensive pattern as cli/config.sh's write verb —
  # this call site happens to already run inside a caller's `if !`, which
  # bash also exempts from -e, but that's an implicit property of the
  # CALLER, not this function; make it explicit here too).
  local rc=0
  _config_edit_apply add network.allowed_hosts "$host" "$yaml_file" || rc=$?
  case "$rc" in
    0) return 0 ;;  # added
    2) return 1 ;;  # already present -- skipped
    *)
      echo "Error: failed to add '${host}' to network.allowed_hosts in ${yaml_file}." >&2
      exit 1
      ;;
  esac
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
  # log_file is still parsed below (CLI-compat) but is unused now that the
  # rip-cage-tsf2.2 --observed retirement guard exits before ever reading a
  # log file; kept as flag-parsing scaffolding, not removed, per the
  # loud-fail-not-redesign ruling.
  # shellcheck disable=SC2034
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
    # rip-cage-tsf2.2 loud-fail stub: --observed is retired. Observed-host
    # capture read .rip-cage/egress.log + egress-dns.log, produced by the
    # in-cage egress engine that was deleted in the msb migration (ADR-029
    # D2) -- nothing writes those logs anymore under microsandbox, so this
    # guard MUST fire before any log read (below) or it silently reports
    # "(none)" instead of failing (a containment-posture surprise). Full
    # removal/redesign is the fast-follow: rip-cage-tsf2.2.
    echo "Error: 'rc allowlist show --observed' is retired." >&2
    echo "Observed-host capture relied on the in-cage egress log (.rip-cage/egress.log, .rip-cage/egress-dns.log), produced by the in-cage egress engine deleted in the msb migration (ADR-029). Nothing writes those logs under microsandbox, so this flag is not available and cannot report anything meaningful." >&2
    echo "Fast-follow (redesign or removal): rip-cage-tsf2.2." >&2
    exit 2
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
  # log_file is still parsed below (CLI-compat) but is unused now that the
  # rip-cage-tsf2.2 --from-observed retirement guard exits before ever
  # reading a log file or writing .rip-cage.yaml; kept as flag-parsing
  # scaffolding, not removed, per the loud-fail-not-redesign ruling.
  # shellcheck disable=SC2034
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

  # rip-cage-tsf2.2 loud-fail stub: --from-observed is retired. It read
  # .rip-cage/egress.log + egress-dns.log, produced by the in-cage egress
  # engine that was deleted in the msb migration (ADR-029 D2) -- nothing
  # writes those logs anymore under microsandbox, so this guard MUST fire
  # before any log read or .rip-cage.yaml write (below) or it silently
  # applies nothing (a containment-posture surprise). Full removal/redesign
  # is the fast-follow: rip-cage-tsf2.2.
  echo "Error: 'rc allowlist promote --from-observed' is retired." >&2
  echo "Observed-host capture relied on the in-cage egress log (.rip-cage/egress.log, .rip-cage/egress-dns.log), produced by the in-cage egress engine deleted in the msb migration (ADR-029). Nothing writes those logs under microsandbox, so this flag is not available and cannot promote anything meaningful." >&2
  echo "Fast-follow (redesign or removal): rip-cage-tsf2.2." >&2
  exit 2
}

