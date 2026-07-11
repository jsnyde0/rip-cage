#!/usr/bin/env bash
# cli/lib/msb_flags.sh -- config -> msb-flags generator (rip-cage-kl4r, S2 of
# the msb migration epic rip-cage-tsf2).
# NOTE: standalone translator, NOT wired into the rc shim's cli/lib sourcing
# loop or cli/up.sh's create path -- that wiring is S6's job (rc lifecycle
# verbs on msb). Sourced directly by this module's own tests. Must NOT set
# -euo pipefail itself (matches the other cli/lib/*.sh convention -- a future
# caller that sources this alongside the shim owns strict mode once).
#
# Implements ADR-029 D2 ("declare, don't run the engine" -- containment is
# the runtime's job) and D5 (--secret non-possession is the default, but a
# mixed posture survives: pi keeps a real mounted auth.json). Binding
# generator constraints from D3 (acceptance-shaping):
#   1. --secret accepts ONLY the bare ENV@HOST form -- an inline
#      ENV=VALUE@HOST input is REJECTED at generation, before any flag is
#      emitted, so the value never travels in argv.
#   2. Binding one credential to N hosts requires N DISTINCT synthesized
#      env-var names -- a same-name repeat or comma-list SILENTLY BLOCKS
#      BOTH hosts with zero boot error (msb footgun, proven live in the
#      rip-cage-7fqe spike). This generator always synthesizes a distinct
#      name per (credential, host) pair -- uniformly, even for a single-host
#      credential -- so there is no special-case path that could regress.
#
# ---------------------------------------------------------------------------
# Input contract: a single JSON object (positional arg $1), shape:
#
# {
#   "allowed_hosts": ["github.com", "api.anthropic.com"],
#   "credentials": [
#     {"source_env": "GH_TOKEN", "hosts": ["github.com", "api.github.com"]}
#   ],
#   "possession_mounts": [
#     {"host_path": "/abs/host/path", "guest_path": "/abs/guest/path",
#      "kind": "file"|"dir", "mode": "ro"|"rw"}
#   ],
#   "mounts": [
#     {"host_path": "/abs/host/path", "guest_path": "/abs/guest/path",
#      "kind": "file"|"dir", "mode": "ro"|"rw"}
#   ],
#   "tls_body_rewrite": true|false
# }
#
# All keys optional; absent/null treated as empty/false. "kind" defaults to
# "dir" when omitted; "mode" defaults to "rw" when omitted.
#
# ---------------------------------------------------------------------------
# Output contract: msb argv TOKENS, one per line, on stdout (mirrors
# tests/golden-master's up-run-args-*.argv convention -- flag and its value
# are separate lines -- so callers do
# `mapfile -t FLAGS < <(_msb_flags_generate "$json")` then
# `msb run "${FLAGS[@]}" ...`). Deterministic: identical input -> byte-
# identical output (declared-order preserved throughout; no unordered
# iteration over the input).
#
# Exit status: 0 on success (flags written to stdout). Non-zero on a
# generation-time validation failure -- an actionable error is written to
# stderr and NO flags are emitted at all (fail loud, fail whole -- never a
# partial flag set that silently drops the rejected part of the config).


# _msb_flags_synth_secret_env_name SOURCE_ENV INDEX HOST
#
# Deterministically synthesizes a distinct guest-placeholder / host-source
# env-var name for one (credential, host) binding. Always applied -- even
# for a credential bound to exactly one host -- so there is no special-cased
# "reuse the bare source_env name for the first host" path that could
# silently regress into the same-name-repeat footgun (D3 constraint 2) if a
# second host were later added to that credential.
#
# HOST is sanitized to [A-Z0-9_] (uppercased, non-alnum -> '_') for
# readability in `msb inspect`/logs, but INDEX is the actual distinctness
# guarantee -- two different hosts that happen to sanitize to the same
# string still produce two different names.
_msb_flags_synth_secret_env_name() {
  local source_env="$1" index="$2" host="$3"
  local sanitized_host
  sanitized_host=$(printf '%s' "$host" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')
  printf '%s__%s_%s' "$source_env" "$index" "$sanitized_host"
}


# _msb_flags_generate CONFIG_JSON
#
# See module header for the input/output contract.
_msb_flags_generate() {
  local cfg="$1"

  # --- Validation pass FIRST (fail whole, not partial): reject any
  # credential source_env containing '=' (the inline ENV=VALUE@HOST form) or
  # that is not a bare env-var-name token, BEFORE emitting any flags. This
  # is a generator-layer defense in depth on top of msb's own --secret
  # parser rejection -- the malformed form must never even appear in the
  # argv this generator hands back to a caller (D3 constraint 1 / bead
  # criterion 6). Never echo the value-looking portion of a malformed
  # source_env into the error -- only the portion up to (and not including)
  # the first '=', so a caller who accidentally passed a real secret value
  # inline does not get it echoed back in an error message.
  local cred_count idx
  cred_count=$(jq '.credentials // [] | length' <<<"$cfg")
  for (( idx=0; idx<cred_count; idx++ )); do
    local source_env
    source_env=$(jq -r ".credentials[${idx}].source_env // \"\"" <<<"$cfg")
    if [[ "$source_env" == *=* ]]; then
      local name_part="${source_env%%=*}"
      echo "Error: msb_flags generator: credentials[${idx}].source_env ('${name_part}=...') contains '=' -- inline ENV=VALUE@HOST is rejected. Pass the bare env-var NAME only (export the real value under that name in the host environment); the generator emits ENV@HOST, never ENV=VALUE@HOST." >&2
      return 1
    fi
    if [[ -z "$source_env" ]]; then
      echo "Error: msb_flags generator: credentials[${idx}] is missing required field 'source_env'." >&2
      return 1
    fi
    if ! [[ "$source_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "Error: msb_flags generator: credentials[${idx}].source_env ('${source_env}') is not a valid bare env-var name ([A-Za-z_][A-Za-z0-9_]*)." >&2
      return 1
    fi
  done

  # --- Emission pass. Fixed section order for determinism (bead criterion
  # 7): net rules, then secrets. Later sections (mounts, tls) are added as
  # their own behaviors land. Within each section, input order is preserved
  # verbatim (no sorting) -- jq array iteration and bash for-loops over an
  # index range are both deterministic for identical input.

  # 1. Network: default-deny + one allow rule per allowed host.
  echo "--net-default"
  echo "deny"
  local host_count h
  host_count=$(jq '.allowed_hosts // [] | length' <<<"$cfg")
  for (( h=0; h<host_count; h++ )); do
    local host
    host=$(jq -r ".allowed_hosts[${h}]" <<<"$cfg")
    echo "--net-rule"
    echo "allow@${host}"
  done

  # 2. Secrets: one --secret <SYNTH>@<host> per (credential, host) pair.
  local cred_count idx
  cred_count=$(jq '.credentials // [] | length' <<<"$cfg")
  for (( idx=0; idx<cred_count; idx++ )); do
    local source_env hosts_count hi
    source_env=$(jq -r ".credentials[${idx}].source_env" <<<"$cfg")
    hosts_count=$(jq ".credentials[${idx}].hosts // [] | length" <<<"$cfg")
    for (( hi=0; hi<hosts_count; hi++ )); do
      local cred_host synth
      cred_host=$(jq -r ".credentials[${idx}].hosts[${hi}]" <<<"$cfg")
      synth=$(_msb_flags_synth_secret_env_name "$source_env" "$((hi + 1))" "$cred_host")
      echo "--secret"
      echo "${synth}@${cred_host}"
    done
  done

  # 3. Possession mounts (D5 mixed posture -- pi keeps a real mounted
  # auth.json even under a non-possession default elsewhere).
  local pmount_count pi
  pmount_count=$(jq '.possession_mounts // [] | length' <<<"$cfg")
  for (( pi=0; pi<pmount_count; pi++ )); do
    _msb_flags_emit_mount "$cfg" "possession_mounts" "$pi"
  done

  # 4. General mount declarations.
  local mount_count mi
  mount_count=$(jq '.mounts // [] | length' <<<"$cfg")
  for (( mi=0; mi<mount_count; mi++ )); do
    _msb_flags_emit_mount "$cfg" "mounts" "$mi"
  done

  # 5. TLS body-rewrite: --tls-intercept ONLY when declared (bead criterion 5).
  local tls_rewrite
  tls_rewrite=$(jq -r '.tls_body_rewrite // false' <<<"$cfg")
  if [[ "$tls_rewrite" == "true" ]]; then
    echo "--tls-intercept"
  fi

  return 0
}


# _msb_flags_prepare_secret_env CONFIG_JSON
#
# Companion to _msb_flags_generate's --secret emission: msb reads a secret's
# real value from a host env var whose NAME is the ENV half of the ENV@HOST
# token, at `msb run` start time. Because this generator always synthesizes
# a distinct name per (credential, host) pair (see
# _msb_flags_synth_secret_env_name -- never the bare source_env, even for a
# single-host credential), the host environment needs the real value
# available under EVERY synthesized name, not just the original source_env
# name.
#
# This function copies the CURRENT value of each credential's source_env
# into every synthesized name for that credential's hosts, via `export`.
#
# MUST be called directly in the same shell that will invoke `msb run`
# (`source cli/lib/msb_flags.sh; _msb_flags_prepare_secret_env "$cfg"`) --
# NEVER through command substitution `$(...)`, which runs in a subshell and
# would discard the exports before `msb run` ever sees them.
#
# Never prints the source value anywhere (no echo of the value, only of
# variable names) -- the value only ever moves through the process
# environment.
_msb_flags_prepare_secret_env() {
  local cfg="$1"
  local cred_count idx
  cred_count=$(jq '.credentials // [] | length' <<<"$cfg")
  for (( idx=0; idx<cred_count; idx++ )); do
    local source_env hosts_count hi
    source_env=$(jq -r ".credentials[${idx}].source_env" <<<"$cfg")
    hosts_count=$(jq ".credentials[${idx}].hosts // [] | length" <<<"$cfg")
    for (( hi=0; hi<hosts_count; hi++ )); do
      local cred_host synth
      cred_host=$(jq -r ".credentials[${idx}].hosts[${hi}]" <<<"$cfg")
      synth=$(_msb_flags_synth_secret_env_name "$source_env" "$((hi + 1))" "$cred_host")
      export "${synth}=${!source_env:-}"
    done
  done
}


# _msb_flags_emit_mount CONFIG_JSON ARRAY_NAME INDEX
#
# Emits one --mount-file or --mount-dir SRC:DST[:ro] line pair for
# CONFIG_JSON.<ARRAY_NAME>[INDEX]. "kind" defaults to "dir"; "mode" defaults
# to "rw" (omitted from the OPTIONS suffix -- only ":ro" is ever appended,
# matching msb's own SOURCE:DEST[:OPTIONS] grammar where rw is the
# unmarked/default case).
_msb_flags_emit_mount() {
  local cfg="$1" array_name="$2" index="$3"
  local host_path guest_path kind mode
  host_path=$(jq -r ".${array_name}[${index}].host_path" <<<"$cfg")
  guest_path=$(jq -r ".${array_name}[${index}].guest_path" <<<"$cfg")
  kind=$(jq -r ".${array_name}[${index}].kind // \"dir\"" <<<"$cfg")
  mode=$(jq -r ".${array_name}[${index}].mode // \"rw\"" <<<"$cfg")

  local flag="--mount-dir"
  [[ "$kind" == "file" ]] && flag="--mount-file"

  local spec="${host_path}:${guest_path}"
  [[ "$mode" == "ro" ]] && spec="${spec}:ro"

  echo "$flag"
  echo "$spec"
}
