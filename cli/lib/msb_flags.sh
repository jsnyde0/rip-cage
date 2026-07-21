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
#     {"source_env": "GH_TOKEN", "hosts": ["github.com", "api.github.com"]},
#     {"source_env": "CCTOK", "source_file": "/abs/host/token-file",
#      "hosts": ["api.anthropic.com"],
#      "target_env": ["CLAUDE_CODE_OAUTH_TOKEN"]}
#   ],
#   # source_file (optional, rip-cage-9dlw): read the real value from a host
#   #   FILE instead of a pre-exported host env var named source_env -- source
#   #   value moves only into the --secret machinery, never the guest.
#   # target_env (optional list, rip-cage-9dlw): guest env-var names to bridge
#   #   to this credential's placeholder via `-e <TARGET>=$MSB_<synth>`, so a
#   #   tool reading a FIXED var name gets the swappable placeholder. REQUIRES
#   #   the credential be bound to exactly one host (single placeholder).
#   "possession_mounts": [
#     {"host_path": "/abs/host/path", "guest_path": "/abs/guest/path",
#      "kind": "file"|"dir", "mode": "ro"|"rw"}
#   ],
#   "mounts": [
#     {"host_path": "/abs/host/path", "guest_path": "/abs/guest/path",
#      "kind": "file"|"dir", "mode": "ro"|"rw"}
#   ],
#   "tls_body_rewrite": true|false,
#   "dind_volumes": [
#     {"name": "docker-data", "guest_path": "/var/lib/docker", "size": "20G"}
#   ]
# }
#
# All keys optional; absent/null treated as empty/false. "kind" defaults to
# "dir" when omitted; "mode" defaults to "rw" when omitted.
#
# "dind_volumes" (rip-cage-75rq, S11) is a DISTINCT manifest surface from
# "mounts"/"possession_mounts" above: those two emit virtiofs --mount-dir/
# --mount-file (msb's `kind=dir`, the default). "dind_volumes" emits a
# **disk-kind** (virtio-blk) --mount-named volume instead -- required
# because docker's overlay2 storage driver cannot write whiteout files onto
# virtiofs/overlayfs (findings §10b), so a cage running nested Docker/compose
# needs its /var/lib/docker backed by a real block device, not a virtiofs
# mount. Each entry requires "name" (the msb named-volume identifier --
# reattaches to the same volume across cage recreates, findings §6), the
# in-guest "guest_path", and "size" (disk capacity, e.g. "20G") -- all three
# are REQUIRED, no defaults; a missing field is a generation-time validation
# failure (fail whole, matching this module's existing credential-validation
# discipline), never a silently-omitted mount.
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
    # target_env guest-env bridge (rip-cage-9dlw): a fixed guest env var can
    # hold exactly ONE placeholder string, but a credential bound to N hosts
    # has N DISTINCT synthesized placeholders. Populating one target var from a
    # multi-host credential is ambiguous and would silently swap correctly for
    # only one host -- so REJECT it here (fail whole, before any flag), never
    # emit a silently-wrong-host bridge. A credential that needs the same
    # secret bridged toward multiple hosts must be split into one single-host
    # credential per host.
    local tgt_count hosts_count_v
    tgt_count=$(jq ".credentials[${idx}].target_env // [] | length" <<<"$cfg")
    if [[ "$tgt_count" -gt 0 ]]; then
      hosts_count_v=$(jq ".credentials[${idx}].hosts // [] | length" <<<"$cfg")
      if [[ "$hosts_count_v" -ne 1 ]]; then
        echo "Error: msb_flags generator: credentials[${idx}] (source_env=${source_env}) declares target_env but is bound to ${hosts_count_v} hosts -- a target_env bridge requires exactly ONE host (a fixed guest var carries a single placeholder). Split into one single-host credential per host, or drop target_env." >&2
        return 1
      fi
    fi
  done

  # --- dind_volumes validation (S11, rip-cage-75rq): "name", "guest_path",
  # and "size" are all required -- no defaults. A missing field must fail
  # generation entirely (fail whole), never silently drop the disk-kind
  # mount (the overlay2-on-virtiofs failure this surface exists to prevent
  # would otherwise reappear invisibly).
  local dind_count di
  dind_count=$(jq '.dind_volumes // [] | length' <<<"$cfg")
  for (( di=0; di<dind_count; di++ )); do
    local dv_name dv_guest_path dv_size
    dv_name=$(jq -r ".dind_volumes[${di}].name // \"\"" <<<"$cfg")
    dv_guest_path=$(jq -r ".dind_volumes[${di}].guest_path // \"\"" <<<"$cfg")
    dv_size=$(jq -r ".dind_volumes[${di}].size // \"\"" <<<"$cfg")
    if [[ -z "$dv_name" ]]; then
      echo "Error: msb_flags generator: dind_volumes[${di}] is missing required field 'name'." >&2
      return 1
    fi
    if [[ -z "$dv_guest_path" ]]; then
      echo "Error: msb_flags generator: dind_volumes[${di}] is missing required field 'guest_path'." >&2
      return 1
    fi
    if [[ -z "$dv_size" ]]; then
      echo "Error: msb_flags generator: dind_volumes[${di}] is missing required field 'size'." >&2
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
    # Port-tight default (ADR-029 D4; empirically proven by spike
    # rip-cage-uuh9, tests/spike-uuh9-port443.sh, 17/17 probes): a
    # colon-free host is a default floor host lacking an explicit port,
    # so scope it to tcp:443 instead of all-ports. A host that already
    # carries an explicit port/proto spec (contains a colon) is a
    # user-added host (self-hosted svc, registry mirror on a nonstandard
    # port) -- emit it UNCHANGED so the port stays overridable (C2 --
    # ADR-005 D12 "block the accident, don't gate legitimate work").
    if [[ "$host" != *:* ]]; then
      echo "allow@${host}:tcp:443"
    else
      echo "allow@${host}"
    fi
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

  # 2b. Guest-env bridge (rip-cage-9dlw): for each credential that declares a
  # target_env, emit one `-e <TARGET>=$MSB_<synth>` per target name. This
  # populates the FIXED guest env var a tool reads (e.g. claude's
  # CLAUDE_CODE_OAUTH_TOKEN) with the SAME placeholder string msb watches for
  # on the wire toward the bound host (msb's placeholder for a --secret NAME is
  # the literal string `$MSB_<NAME>` -- proven end-to-end in rip-cage-cmqb,
  # docs/2026-07-09-msb-spike-claude-nonpossession.md, where the guest var held
  # exactly `$MSB_CCTOK`). Single-host is guaranteed by the validation pass
  # above, so hosts[0]'s synth is the one unambiguous placeholder. NO tool name
  # is hardcoded here -- the operator's config names the target var (ADR-005
  # D12). The `$MSB_` value is emitted literally (never shell-expanded here):
  # it reaches `msb run` as a verbatim argv token via the caller's
  # `mapfile`/`"${FLAGS[@]}"`, and msb sets the guest var to that literal.
  local bcred_count bidx
  bcred_count=$(jq '.credentials // [] | length' <<<"$cfg")
  for (( bidx=0; bidx<bcred_count; bidx++ )); do
    local b_tgt_count
    b_tgt_count=$(jq ".credentials[${bidx}].target_env // [] | length" <<<"$cfg")
    [[ "$b_tgt_count" -eq 0 ]] && continue
    local b_source_env b_host b_synth bti
    b_source_env=$(jq -r ".credentials[${bidx}].source_env" <<<"$cfg")
    b_host=$(jq -r ".credentials[${bidx}].hosts[0]" <<<"$cfg")
    # Index is hardcoded 1 (and host is hosts[0]) ONLY because the validation
    # pass above guarantees a target_env credential is single-host, so its sole
    # synth uses index 1 (matching the secret loop's $((hi+1)) at hi=0). If that
    # single-host constraint is ever relaxed to multi-host bridging, this site
    # must derive the index per target->host mapping, not assume 1 — otherwise
    # the bridge would silently point every target at the first host's synth.
    b_synth=$(_msb_flags_synth_secret_env_name "$b_source_env" 1 "$b_host")
    for (( bti=0; bti<b_tgt_count; bti++ )); do
      local b_target
      b_target=$(jq -r ".credentials[${bidx}].target_env[${bti}]" <<<"$cfg")
      # printf, NOT echo: a bare `echo "-e"` is swallowed by bash's echo
      # builtin as the -e escape flag (same footgun noted at cli/up.sh:1845),
      # emitting an empty line instead of the literal token `-e`.
      printf '%s\n' "-e" "${b_target}=\$MSB_${b_synth}"
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

  # 6. DinD/compose disk-kind docker-data volumes (S11, rip-cage-75rq,
  # findings §10b). Appended LAST and via its own emitter
  # (_msb_flags_emit_dind_volume) -- a distinct manifest surface from
  # section 4's virtiofs mounts, kept structurally separate so this
  # disk-kind concern never tangles _msb_flags_emit_mount's dir/file logic.
  local dind_count di
  dind_count=$(jq '.dind_volumes // [] | length' <<<"$cfg")
  for (( di=0; di<dind_count; di++ )); do
    _msb_flags_emit_dind_volume "$cfg" "$di"
  done

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
    local source_env source_file hosts_count hi cred_value
    source_env=$(jq -r ".credentials[${idx}].source_env" <<<"$cfg")
    source_file=$(jq -r ".credentials[${idx}].source_file // \"\"" <<<"$cfg")
    # Source the real value from a host FILE when source_file is declared
    # (rip-cage-9dlw, autonomy: a plain `rc up` needs no pre-exported host env
    # var), else from the same-named host env var. The value moves only through
    # this process's environment into the synthesized --secret name; it is
    # never printed and never written to the guest. `$(cat ...)` strips a
    # trailing newline, matching the rip-cage-cmqb spike's host-side read.
    if [[ -n "$source_file" ]]; then
      cred_value=$(cat "$source_file" 2>/dev/null || true)
    else
      cred_value="${!source_env:-}"
    fi
    hosts_count=$(jq ".credentials[${idx}].hosts // [] | length" <<<"$cfg")
    for (( hi=0; hi<hosts_count; hi++ )); do
      local cred_host synth
      cred_host=$(jq -r ".credentials[${idx}].hosts[${hi}]" <<<"$cfg")
      synth=$(_msb_flags_synth_secret_env_name "$source_env" "$((hi + 1))" "$cred_host")
      export "${synth}=${cred_value}"
    done
  done
}


# _msb_flags_preflight_secret_env CONFIG_JSON
#
# rip-cage-rj68 (S6, Fold b of the 2026-07-12 Fable rulings): NEW guard, ADDED
# alongside the existing _msb_flags_generate/_msb_flags_prepare_secret_env
# functions above -- the S6 input contract (this module's JSON shape) is
# APPROVED AS-IS and stays untouched; this function does not change it.
#
# _msb_flags_prepare_secret_env exports each credential's CURRENT host value
# under its synthesized name -- including an EMPTY STRING when the host
# source_env is unset (`${!source_env:-}`), with no error anywhere. That
# silently boots a cage carrying a placeholder-substituted EMPTY secret: the
# guest holds a `$MSB_<SYNTH>` placeholder that resolves to nothing, msb's
# violation guard never fires (there's no real value to compare against),
# and the operator gets no signal until whatever used the credential fails
# for an unrelated-looking reason deep inside the guest.
#
# This function is the fail-loud gate a caller runs BEFORE `msb run`/
# `msb create` (and before calling _msb_flags_prepare_secret_env, though the
# two are independent — order between them does not matter for correctness,
# only that THIS one gates the invocation): for every credential's
# source_env, checks the host environment variable is BOTH set AND
# non-empty. On the first violation, prints a loud, actionable error to
# stderr NAMING the offending source_env (never any value — see below) and
# returns non-zero; the caller must not proceed to `msb run`/`msb create`.
# Silent (no output, exit 0) when every credential's source_env passes, or
# when no credentials are declared at all.
#
# Never echoes any credential VALUE, only variable NAMES — mirrors
# _msb_flags_generate's malformed-source_env error discipline above (never
# echo the value-looking portion of anything).
_msb_flags_preflight_secret_env() {
  local cfg="$1"
  local cred_count idx
  cred_count=$(jq '.credentials // [] | length' <<<"$cfg")
  for (( idx=0; idx<cred_count; idx++ )); do
    local source_env source_file
    source_env=$(jq -r ".credentials[${idx}].source_env" <<<"$cfg")
    source_file=$(jq -r ".credentials[${idx}].source_file // \"\"" <<<"$cfg")
    if [[ -n "$source_file" ]]; then
      # source_file path (rip-cage-9dlw): must exist, be readable, and be
      # non-empty. The PATH is named in the error (a path is not secret); the
      # file CONTENTS are never read into the message.
      if [[ ! -r "$source_file" || ! -s "$source_file" ]]; then
        echo "Error: msb_flags preflight: credentials[${idx}].source_file '${source_file}' is missing, unreadable, or empty. Provide a readable, non-empty file holding the real secret value, or remove this credential binding from .rip-cage.yaml. Refusing to boot a cage that would carry a placeholder-substituted empty secret." >&2
        return 1
      fi
    elif [[ -z "${!source_env:-}" ]]; then
      echo "Error: msb_flags preflight: credentials[${idx}].source_env '${source_env}' is unset or empty in the host environment. Export a real value for ${source_env} before running this command (e.g. 'export ${source_env}=...'), declare a source_file, or remove this credential binding from .rip-cage.yaml. Refusing to boot a cage that would carry a placeholder-substituted empty secret." >&2
      return 1
    fi
  done
  return 0
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


# _msb_flags_emit_dind_volume CONFIG_JSON INDEX
#
# Emits one --mount-named NAME:GUEST_PATH:kind=disk,size=SIZE line pair for
# CONFIG_JSON.dind_volumes[INDEX] (S11, rip-cage-75rq, findings §10b).
#
# DISTINCT from _msb_flags_emit_mount above: msb's `--mount-named` volumes
# default to `kind=dir` (virtiofs-backed) when no OPTIONS are given, which
# is exactly what a plain `mounts`/`possession_mounts` entry wants -- but
# docker's overlay2 storage driver cannot write whiteout files onto
# virtiofs/overlayfs (fails with "failed to convert whiteout file ...
# operation not permitted"). A cage running nested Docker/compose needs
# `/var/lib/docker` (or wherever guest_path points) on a real virtio-blk
# block device instead, which requires the explicit `kind=disk,size=SIZE`
# OPTIONS suffix on the mount spec -- omitting it silently falls back to the
# broken virtiofs default, so this function ALWAYS emits the suffix (never
# conditionally), and the caller (_msb_flags_generate) validates all three
# fields are present before this function is ever called.
_msb_flags_emit_dind_volume() {
  local cfg="$1" index="$2"
  local name guest_path size
  name=$(jq -r ".dind_volumes[${index}].name" <<<"$cfg")
  guest_path=$(jq -r ".dind_volumes[${index}].guest_path" <<<"$cfg")
  size=$(jq -r ".dind_volumes[${index}].size" <<<"$cfg")

  echo "--mount-named"
  echo "${name}:${guest_path}:kind=disk,size=${size}"
}
