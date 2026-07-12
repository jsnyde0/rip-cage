#!/usr/bin/env bash
# cli/lib/config.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# ============================================================================
# Layered .rip-cage.yaml config loader (ADR-021)
# ----------------------------------------------------------------------------
# Reads two layers (global ~/.config/rip-cage/config.yaml + project
# <workspace>/.rip-cage.yaml), merges per per-field-type rules (D2), handles
# schema versioning (D3 Option B — field-type-conditional unknown-version
# behavior), and exposes the effective config + provenance to consumers.
#
# Substrate-only: no behavior change in cage posture when both files absent
# (D5). Downstream consumers (the egress allowlist, mount policy, etc.)
# interpret the effective config; this module only loads, merges, validates,
# and reports. (The ssh.allowed_hosts/allowed_keys consumer, ADR-022,
# retired at the msb cutover — ADR-029 D3 / rip-cage-f1qo S5.)
# ============================================================================

# Schema — single source of truth for field types and defaults.
# Format: <dotted_key>|<type>|<default_json>[|allowed_values_csv]
# Types: scalar | additive_list | selection_list
#
# selection_list fields with a 4th column of allowed_values are enum-scalars:
# the field stores a single string value constrained to the allowed set.
# Unknown enum values abort loud per ADR-021 D3 (same abort path as
# selection-list + future-version conflict).
#
# Schema additions are versioned changes — bump RC_CONFIG_SUPPORTED_VERSION_MAX
# below when adding fields that v1 files cannot represent.
_config_schema_lines() {
  cat <<'EOF'
version|scalar|1
mounts.denylist|additive_list|[]
mounts.allow_risky|selection_list|null
mounts.config_mode|selection_list|"ro"|ro,rw
mounts.symlinks.on_dangling|selection_list|"follow"|follow,warn,skip,error
mounts.symlinks.scope|selection_list|"file"|file,parent
mounts.symlinks.mode|selection_list|"rw"|ro,rw
network.allowed_hosts|additive_list|[]
network.mode|selection_list|null|observe,block
network.dns.forward_to|scalar|null
network.http.forward_to|scalar|null
dcg.packs|additive_list|[]
dcg.custom_rule_paths|additive_list|[]
session.multiplexer|selection_list|"none"
auth.credential_mounts|selection_list|"real"|real,none
auth.placeholder_env_file|scalar|null
auth.per_tool.claude|selection_list|null|real,none
auth.per_tool.pi|selection_list|null|real,none
auth.credentials|additive_list|[]
EOF
}

# Highest schema version this rc supports. Files declaring a higher version
# trigger D3 field-type-conditional behavior.
RC_CONFIG_SUPPORTED_VERSION_MAX=1


_config_schema_selection_list_keys() {
  _config_schema_lines | awk -F'|' '$2 == "selection_list" { print $1 }'
}


_config_schema_field_type() {
  local key="$1"
  _config_schema_lines | awk -F'|' -v k="$key" '$1 == k { print $2; exit }'
}


# _config_mux_derive_allowed_set
#
# Derives the allowed value set for session.multiplexer dynamically from the
# baked registry — NOT a static enum (ADR-005 D12).
#
# Resolution order:
#   1. Check whether the image EXISTS (docker image inspect). If it exists, the
#      rc.multiplexers label is the SOLE authoritative source — even an empty
#      label means "no muxes baked", so the allowed set is "none" only.
#      The label is build-frozen: it does NOT re-read the host manifest at
#      runtime, preserving the no-image-vs-host-drift invariant (rip-cage-61al.2).
#      This prevents the validate-passes/runtime-fails hole: a user who adds a
#      MULTIPLEXER to the manifest without running 'rc build' gets a loud error
#      naming 'rc build' rather than a silent acceptance that fails at dispatch.
#   2. Only when the image is GENUINELY ABSENT (docker not available or image
#      not found) fall back to enumerating MULTIPLEXER entries in the resolved
#      manifest. Same source of truth as the build, evaluated pre-bake.
#      NOT a fail-open: only names present in the manifest are accepted.
#   3. 'none' is always included regardless of the registry contents.
#
# Outputs a comma-separated allowed-set string (CSV), e.g. "none,test-mux".
# Always exits 0 (returns empty string on derivation failure, which the caller
# will treat as allowed-set = "none" only — still validated, still loud).
#
# ADR-001: selected-but-not-baked names fail loud at config-validate (caller
# responsibility — this function only derives the set).
# ADR-005 D12: the function MUST NOT name specific optional multiplexers;
# it enumerates whatever the baked registry or manifest declares.
#
# rip-cage-61al.4
_config_mux_derive_allowed_set() {
  # Default to $IMAGE (rc:45) so an RC_IMAGE override (custom-tag/scratch cage)
  # validates against ITS OWN baked registry, not rip-cage:latest's. The
  # explicit RC_MUX_INSPECT_IMAGE env override still wins (rip-cage-gkc7).
  local image="${RC_MUX_INSPECT_IMAGE:-$IMAGE}"

  # Step 1: If image EXISTS, the label is authoritative (even when empty).
  # Empty label = no muxes baked = allowed set is "none" only.
  # This path must NOT call _manifest_load (no runtime manifest read).
  if command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1; then
    local label_val
    label_val=$(docker inspect --format '{{ index .Config.Labels "rc.multiplexers" }}' "$image" 2>/dev/null || true)
    if [[ -n "$label_val" ]]; then
      echo "none,${label_val}"
    else
      echo "none"
    fi
    return 0
  fi

  # Step 2: Image is genuinely ABSENT (pre-build path) — manifest-enumeration fallback.
  # Only reached when docker is unavailable or the image has not been built yet.
  local baked_set=""
  local manifest_json
  if manifest_json=$(_manifest_load 2>/dev/null); then
    local count idx mux_names=""
    count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null || echo "0")
    for (( idx=0; idx<count; idx++ )); do
      local entry archetype name
      entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
      archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
      if [[ "$archetype" != "MULTIPLEXER" ]]; then
        continue
      fi
      name=$(jq -r '.name // ""' <<<"$entry" 2>/dev/null)
      if [[ -n "$name" ]]; then
        if [[ -n "$mux_names" ]]; then
          mux_names+=",${name}"
        else
          mux_names="$name"
        fi
      fi
    done
    baked_set="$mux_names"
  fi

  # Step 3: Always include 'none'; prepend to the derived set.
  if [[ -n "$baked_set" ]]; then
    echo "none,${baked_set}"
  else
    echo "none"
  fi
}


# yq dependency check (ADR-001 fail-loud — no silent degradation).
# Loader does NOT fall back to "skip config" on missing parser; that would
# silently nullify a user-authored capability scoping.
_config_check_yq() {
  if ! command -v yq &>/dev/null; then
    echo "Error: yq not found on PATH. yq is a rip-cage config dependency — install it: brew install yq (macOS) or the mikefarah/yq release binary (Linux: https://github.com/mikefarah/yq/releases) — NOT apt's yq, which is the incompatible python-yq." >&2
    exit 1
  fi
}


_config_global_path() {
  echo "${RC_CONFIG_GLOBAL:-${XDG_CONFIG_HOME:-$HOME/.config}/rip-cage/config.yaml}"
}


# Returns the canonical default secret-path denylist YAML (single source of
# truth). Used by both cmd_install (interactive seed) and
# _config_ensure_global_seeded (auto-seed on first rc up — rip-cage-j86).
_config_default_global_yaml() {
  cat <<'YAML'
version: 1
mounts:
  denylist:
    - .ssh
    - .gnupg
    - .gpg
    - .aws
    - .azure
    - .gcloud
    - .kube
    - .docker
    - credentials
    - .netrc
    - .npmrc
    - .pypirc
    - id_rsa
    - id_ed25519
    - private_key
    - .secret
  allow_risky: null
YAML
}


_config_project_path() {
  local workspace="$1"
  echo "${workspace}/.rip-cage.yaml"
}


# Returns: "<version_int>|<status>" where status ∈ {ok, missing, unsupported}
_config_check_version() {
  local file="$1"
  local v
  v=$(yq '.version // "MISSING"' "$file" 2>/dev/null)
  if [[ "$v" == "MISSING" || -z "$v" || "$v" == "null" ]]; then
    echo "1|missing"; return
  fi
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    # Non-integer version — treat as unsupported so D3 partial parse fires.
    echo "${v}|unsupported"; return
  fi
  if (( v > RC_CONFIG_SUPPORTED_VERSION_MAX )); then
    echo "${v}|unsupported"; return
  fi
  echo "${v}|ok"
}


# D3 Option B partial parse: enumerate selection-list fields PRESENT in an
# unknown-version file. Returns "abort|<comma-separated-fields>" if any
# selection-list field is present (silent skip would silently EXPAND
# capability beyond user intent — ADR-001:13 failure mode), else "skip".
_config_unknown_version_classify() {
  local file="$1"
  local hits=()
  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # mikefarah yq uses dot-notation. `.foo // "X"` returns X if foo is
    # absent. Use a sentinel so we distinguish absent from explicit-null;
    # explicit-null still counts as "field present" for D3 purposes (the user
    # typed the key).
    local present
    present=$(yq ".${key} // \"___RC_ABSENT___\"" "$file" 2>/dev/null || echo "___RC_ABSENT___")
    if [[ "$present" != "___RC_ABSENT___" ]]; then
      hits+=("$key")
    fi
  done < <(_config_schema_selection_list_keys)
  if [[ ${#hits[@]} -gt 0 ]]; then
    local joined=""
    local h
    for h in "${hits[@]}"; do
      joined+="${h},"
    done
    echo "abort|${joined%,}"
  else
    echo "skip"
  fi
}


# Load one layer. Emits warnings to stderr per D3.
# stdout: JSON object (empty {} if file absent or skipped)
# exit:   0 = OK or skipped; 1 = fatal abort (selection-list version-drift)
_config_load_layer() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "{}"
    return 0
  fi

  local vinfo version vstatus
  vinfo=$(_config_check_version "$file")
  version="${vinfo%|*}"
  vstatus="${vinfo#*|}"

  case "$vstatus" in
    missing)
      echo "Warning: '$file' has no 'version:' field; assuming version 1. Add 'version: 1' to silence." >&2
      ;;
    unsupported)
      local cls fields
      cls=$(_config_unknown_version_classify "$file")
      if [[ "$cls" == abort\|* ]]; then
        fields="${cls#abort|}"
        echo "Error: '$file' declares version: $version (rc supports up to ${RC_CONFIG_SUPPORTED_VERSION_MAX}) AND uses selection-list field(s) [$fields]." >&2
        echo "  Skipping the file would silently expand capability beyond your declared intent." >&2
        echo "  Upgrade rc, or remove the selection-list field(s) and pin to a supported version." >&2
        return 1
      fi
      echo "Warning: '$file' declares version: $version but rc supports up to ${RC_CONFIG_SUPPORTED_VERSION_MAX}. Skipping this file (no selection-list fields detected — capability degradation is in the safer direction). Run 'rc --version' and consider upgrading." >&2
      echo "{}"
      return 0
      ;;
    ok)
      ;;
  esac

  local json
  if ! json=$(yq -o=json '.' "$file" 2>/dev/null); then
    echo "Warning: '$file' failed to parse as YAML; treating as empty." >&2
    echo "{}"
    return 0
  fi
  # yq emits "null" for empty files
  if [[ -z "$json" || "$json" == "null" ]]; then
    echo "{}"; return 0
  fi

  # Enum-scalar validation: for selection_list fields with allowed_values (4th
  # schema column), check that the field's value in this layer is in the set.
  # Unknown enum values abort loud per ADR-021 D3.
  #
  # session.multiplexer is a special case: its allowed set derives dynamically
  # from the baked registry (rc.multiplexers image label) via
  # _config_mux_derive_allowed_set — not a static 4th column (rip-cage-61al.4,
  # ADR-005 D12). The 4th column for this field is intentionally absent from
  # _config_schema_lines(); the dynamic derivation runs instead.
  # (network.egress.mediator's isomorphic dynamic-derivation case retired with
  # the MEDIATOR archetype per ADR-029 D2 — the schema field itself is gone.)
  local _ev_key _ev_type _ev_default _ev_allowed
  while IFS='|' read -r _ev_key _ev_type _ev_default _ev_allowed; do
    [[ -z "$_ev_key" ]] && continue
    [[ "$_ev_type" != "selection_list" ]] && continue
    # Dynamic derivation for session.multiplexer (4th column intentionally absent).
    if [[ "$_ev_key" == "session.multiplexer" && -z "$_ev_allowed" ]]; then
      _ev_allowed=$(_config_mux_derive_allowed_set)
    fi
    [[ -z "$_ev_allowed" ]] && continue
    local _ev_path_arr _ev_val
    _ev_path_arr=$(jq -nc --arg k "$_ev_key" '$k | split(".")')
    _ev_val=$(jq -r --argjson p "$_ev_path_arr" 'getpath($p) // "___RC_ABSENT___"' <<<"$json" 2>/dev/null || echo "___RC_ABSENT___")
    [[ "$_ev_val" == "___RC_ABSENT___" || "$_ev_val" == "null" ]] && continue
    # Check against allowed values
    local _ev_ok=0
    local _ev_a
    IFS=',' read -ra _ev_parts <<< "$_ev_allowed"
    for _ev_a in "${_ev_parts[@]}"; do
      [[ "$_ev_val" == "$_ev_a" ]] && _ev_ok=1 && break
    done
    if [[ "$_ev_ok" -eq 0 ]]; then
      if [[ "$_ev_key" == "session.multiplexer" ]]; then
        echo "Error: '$file' has invalid value '${_ev_val}' for field '${_ev_key}'. '${_ev_val}' is not in the baked multiplexer registry (allowed: ${_ev_allowed}). Add the provider to your manifest and run \`rc build\` to bake it (see examples/ for provider definitions)." >&2
      else
        echo "Error: '$file' has invalid value '${_ev_val}' for field '${_ev_key}'. Allowed values: ${_ev_allowed}." >&2
      fi
      return 1
    fi
  done < <(_config_schema_lines)

  # D7 (rip-cage-xhgr, fail-closed): unknown keys under auth.per_tool. abort
  # loud rather than silently vanishing. _config_merge only reads the two
  # schema-declared per-tool keys (claude, pi) by walking _config_schema_lines
  # — any other key under auth.per_tool (a typo like 'claud', or an
  # unsupported tool name) would otherwise be silently dropped by the merge
  # and the tool would silently inherit the global default ("real") against
  # operator intent. A credential-suppression knob must fail closed, not
  # open (ADR-001). Scoped to auth.per_tool. only — general unknown-key
  # rejection is a separate ADR-021 D3 conformance question, out of scope here.
  local _pt_key
  while IFS= read -r _pt_key; do
    [[ -z "$_pt_key" ]] && continue
    if [[ "$_pt_key" != "claude" && "$_pt_key" != "pi" ]]; then
      echo "Error: '$file' has unknown key 'auth.per_tool.${_pt_key}'. Allowed per-tool keys: claude, pi." >&2
      return 1
    fi
  done < <(jq -r '.auth.per_tool // {} | keys[]?' <<<"$json" 2>/dev/null || true)

  # auth.credentials (rip-cage-rj68, S6 Fold a — the credential->host binding
  # surface the deleted MEDIATOR archetype used to carry, ADR-029 D2). Each
  # entry MUST declare a non-empty 'source_env' and a non-empty 'hosts'
  # array — fail-closed (ADR-001), same discipline as the auth.per_tool
  # check above: a malformed binding must never be silently dropped (an
  # operator who thinks a credential is scoped to a host, when the entry
  # was actually discarded, is a worse outcome than refusing to boot).
  # This is a generation-time check ON THE CONFIG SURFACE, distinct from
  # (and upstream of) cli/lib/msb_flags.sh's OWN source_env validation on
  # its JSON contract — msb_flags.sh's contract stays untouched; this is
  # the layer that produces well-formed input for it.
  local _cred_count _cred_idx
  _cred_count=$(jq '.auth.credentials // [] | length' <<<"$json" 2>/dev/null || echo 0)
  for (( _cred_idx=0; _cred_idx<_cred_count; _cred_idx++ )); do
    local _cred_source_env _cred_hosts_count
    _cred_source_env=$(jq -r ".auth.credentials[${_cred_idx}].source_env // \"\"" <<<"$json" 2>/dev/null)
    if [[ -z "$_cred_source_env" ]]; then
      echo "Error: '$file' has auth.credentials[${_cred_idx}] missing required field 'source_env'." >&2
      return 1
    fi
    _cred_hosts_count=$(jq ".auth.credentials[${_cred_idx}].hosts // [] | length" <<<"$json" 2>/dev/null || echo 0)
    if [[ "$_cred_hosts_count" -eq 0 ]]; then
      echo "Error: '$file' has auth.credentials[${_cred_idx}] (source_env=${_cred_source_env}) with missing or empty 'hosts' — a credential bound to zero hosts is not a valid binding." >&2
      return 1
    fi
  done

  echo "$json"
}


# Merge two layer JSONs per D2 per-field-type rules. Walks the schema
# explicitly — only declared fields appear in the effective config.
_config_merge() {
  local global="$1" project="$2"
  local effective='{}'
  local key type default _allowed
  while IFS='|' read -r key type default _allowed; do
    [[ -z "$key" ]] && continue
    local g_val p_val merged path_arr
    path_arr=$(jq -nc --arg k "$key" '$k | split(".")')
    g_val=$(jq -c --argjson p "$path_arr" 'getpath($p)' <<<"$global")
    p_val=$(jq -c --argjson p "$path_arr" 'getpath($p)' <<<"$project")
    case "$type" in
      additive_list)
        # Union: global ∪ project, order-preserving dedup. Default applied
        # only if both layers absent (so [] in either layer is honored, not
        # replaced with defaults).
        if [[ "$g_val" == "null" && "$p_val" == "null" ]]; then
          merged="$default"
        else
          merged=$(jq -nc --argjson g "$g_val" --argjson p "$p_val" '
            (($g // []) + ($p // []))
            | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
          ')
        fi
        ;;
      selection_list)
        # Three-state per D2: project absent ⇒ inherit global (or default);
        # project present (any value, including []) ⇒ project replaces.
        merged=$(jq -nc --argjson g "$g_val" --argjson p "$p_val" --argjson d "$default" '
          if $p != null then $p
          elif $g != null then $g
          else $d end')
        ;;
      scalar)
        merged=$(jq -nc --argjson g "$g_val" --argjson p "$p_val" --argjson d "$default" '
          if $p != null then $p
          elif $g != null then $g
          else $d end')
        ;;
      *)
        echo "Internal error: unknown schema type '$type' for key '$key'" >&2
        return 1
        ;;
    esac
    effective=$(jq -c --argjson v "$merged" --argjson p "$path_arr" 'setpath($p; $v)' <<<"$effective")
  done < <(_config_schema_lines)
  echo "$effective"
}


# Per-field provenance: where each effective value came from.
# Output: { "<dotted_key>": "global"|"project"|"default"|["global","project"] }
_config_provenance() {
  local global="$1" project="$2"
  local prov='{}'
  local key type default _allowed
  while IFS='|' read -r key type default _allowed; do
    [[ -z "$key" ]] && continue
    local g_val p_val src path_arr
    path_arr=$(jq -nc --arg k "$key" '$k | split(".")')
    g_val=$(jq -c --argjson p "$path_arr" 'getpath($p)' <<<"$global")
    p_val=$(jq -c --argjson p "$path_arr" 'getpath($p)' <<<"$project")
    local g_present="false" p_present="false"
    [[ "$g_val" != "null" ]] && g_present="true"
    [[ "$p_val" != "null" ]] && p_present="true"
    case "$type" in
      additive_list)
        if [[ "$g_present" == "true" && "$p_present" == "true" ]]; then
          src='["global","project"]'
        elif [[ "$g_present" == "true" ]]; then
          src='"global"'
        elif [[ "$p_present" == "true" ]]; then
          src='"project"'
        else
          src='"default"'
        fi
        ;;
      selection_list|scalar)
        if [[ "$p_present" == "true" ]]; then
          src='"project"'
        elif [[ "$g_present" == "true" ]]; then
          src='"global"'
        else
          src='"default"'
        fi
        ;;
    esac
    prov=$(jq -c --argjson v "$src" --arg k "$key" '.[$k] = $v' <<<"$prov")
  done < <(_config_schema_lines)
  echo "$prov"
}


# Top-level loader entry. Returns JSON:
# {
#   config:     <effective merged config>,
#   provenance: { "<dotted_key>": "global"|"project"|"default"|["global","project"] },
#   layers:     { global: <path|null>, project: <path|null> },
#   sha256:     "<hex>"   # of canonical effective config — for rc.config-loaded label
# }
# Emits warnings/errors to stderr; exits non-zero on D3 abort case.
_load_effective_config() {
  local workspace="$1"
  local global_path project_path
  global_path=$(_config_global_path)
  project_path=$(_config_project_path "$workspace")

  local global_json project_json
  if ! global_json=$(_config_load_layer "$global_path"); then
    return 1
  fi
  if ! project_json=$(_config_load_layer "$project_path"); then
    return 1
  fi

  local effective provenance sha
  effective=$(_config_merge "$global_json" "$project_json")
  provenance=$(_config_provenance "$global_json" "$project_json")

  # Note: network.writable_hosts cross-field constraint removed in rip-cage-ta1o.1
  # (method-asymmetry / write-gate fully deleted; writable_hosts is no longer a live config field).

  # Canonical-form hash so equivalent reordering doesn't churn the label.
  sha=$(jq -cS '.' <<<"$effective" | shasum -a 256 | awk '{print $1}')

  local global_layer project_layer
  if [[ -f "$global_path" ]]; then global_layer="\"$global_path\""; else global_layer="null"; fi
  if [[ -f "$project_path" ]]; then project_layer="\"$project_path\""; else project_layer="null"; fi

  jq -nc \
    --argjson c "$effective" \
    --argjson p "$provenance" \
    --argjson gl "$global_layer" \
    --argjson pr "$project_layer" \
    --arg sha "$sha" \
    '{config: $c, provenance: $p, layers: {global: $gl, project: $pr}, sha256: $sha}'
}


# Format effective config as YAML-with-provenance comments for human reading.
# Per D4: per-element provenance for top-level scalar additive lists; field-
# level provenance for everything else.
_config_format_yaml() {
  local result="$1"
  local global_path project_path
  global_path=$(jq -r '.layers.global // "(absent)"' <<<"$result")
  project_path=$(jq -r '.layers.project // "(absent)"' <<<"$result")

  echo "# Effective rip-cage config (rc config show)"
  echo "# Layers loaded:"
  echo "#   global  = ${global_path}"
  echo "#   project = ${project_path}"
  echo "#"

  # Group keys by top-level prefix so output looks like nested YAML.
  # Supports up to 3-level nesting (e.g. mounts.symlinks.on_dangling).
  local prev_top="" prev_mid=""
  local key type default _allowed
  while IFS='|' read -r key type default _allowed; do
    [[ -z "$key" ]] && continue
    # Split key into parts: top, mid (optional), leaf
    local top="" mid="" leaf=""
    local _parts _nparts
    IFS='.' read -ra _parts <<< "$key"
    _nparts=${#_parts[@]}
    if [[ $_nparts -eq 1 ]]; then
      leaf="${_parts[0]}"
    elif [[ $_nparts -eq 2 ]]; then
      top="${_parts[0]}"
      leaf="${_parts[1]}"
    else
      top="${_parts[0]}"
      mid="${_parts[1]}"
      leaf="${_parts[2]}"
    fi

    local src
    src=$(jq -c --arg k "$key" '.provenance[$k]' <<<"$result")
    local val
    val=$(jq -c --arg k "$key" '.config | getpath($k | split("."))' <<<"$result")

    # Provenance comment text
    local src_text
    if [[ "$src" == '["global","project"]' ]]; then
      src_text="union(global, project)"
    else
      # strip quotes from JSON string
      src_text="from $(jq -r . <<<"$src")"
    fi

    # Emit group headers when top-level or mid-level changes.
    if [[ -n "$top" && "$top" != "$prev_top" ]]; then
      echo "${top}:"
      prev_top="$top"
      prev_mid=""  # reset mid tracking when top changes
    fi
    if [[ -n "$mid" && ( "$mid" != "$prev_mid" || "$top" != "$prev_top" ) ]]; then
      echo "  ${mid}:"
      prev_mid="$mid"
    fi

    local indent=""
    if [[ -n "$mid" ]]; then
      indent="    "
    elif [[ -n "$top" ]]; then
      indent="  "
    fi

    case "$type" in
      additive_list)
        # Empty list: render inline.
        if [[ "$val" == "[]" ]]; then
          echo "${indent}${leaf}: []                 # ${src_text}"
        else
          echo "${indent}${leaf}:                   # ${src_text}"
          # Per-element provenance: re-read each layer to tag each element.
          local g_layer p_layer g_list p_list
          g_layer=$(jq -r '.layers.global' <<<"$result")
          p_layer=$(jq -r '.layers.project' <<<"$result")
          if [[ "$g_layer" != "null" && -f "$g_layer" ]]; then
            g_list=$(yq -o=json -I=0 ".${key} // []" "$g_layer" 2>/dev/null || echo "[]")
          else
            g_list="[]"
          fi
          if [[ "$p_layer" != "null" && -f "$p_layer" ]]; then
            p_list=$(yq -o=json -I=0 ".${key} // []" "$p_layer" 2>/dev/null || echo "[]")
          else
            p_list="[]"
          fi
          local elt
          while IFS= read -r elt; do
            [[ -z "$elt" ]] && continue
            local in_g in_p label
            in_g=$(jq -r --arg e "$elt" 'any(.[]; . == $e)' <<<"$g_list")
            in_p=$(jq -r --arg e "$elt" 'any(.[]; . == $e)' <<<"$p_list")
            if [[ "$in_g" == "true" && "$in_p" == "true" ]]; then label="global+project"
            elif [[ "$in_g" == "true" ]]; then label="global"
            elif [[ "$in_p" == "true" ]]; then label="project"
            else label="default"
            fi
            echo "${indent}  - ${elt}                 # ${label}"
          done < <(jq -r '.[]' <<<"$val")
        fi
        ;;
      selection_list)
        # Enum-scalar variant: value is a JSON string (not array).
        # Render as scalar. Array variant (e.g. allowed_keys) renders as list.
        # Note: _allowed is the 4th schema column; some scalar selection_list fields
        # (e.g. session.multiplexer) have no static 4th column yet are still string
        # scalars — detect via JSON type, not _allowed presence.
        if [[ "$val" == "null" ]]; then
          echo "${indent}${leaf}: null               # ${src_text}"
        elif [[ -n "$_allowed" ]] || jq -e 'type == "string"' <<<"$val" >/dev/null 2>&1; then
          # Enum scalar — render as plain scalar value
          local v_text
          v_text=$(jq -r '.' <<<"$val")
          echo "${indent}${leaf}: ${v_text}               # ${src_text}"
        elif [[ "$val" == "[]" ]]; then
          echo "${indent}${leaf}: []                 # ${src_text} (explicit zero-out)"
        else
          echo "${indent}${leaf}:                   # ${src_text}"
          local elt
          while IFS= read -r elt; do
            [[ -z "$elt" ]] && continue
            echo "${indent}  - ${elt}"
          done < <(jq -r '.[]' <<<"$val")
        fi
        ;;
      scalar)
        local v_text
        v_text=$(jq -r '.' <<<"$val")
        echo "${indent}${leaf}: ${v_text}               # ${src_text}"
        ;;
    esac
  done < <(_config_schema_lines)
}


# Substrate validation step (ADR-021 D3 + ADR-001 fail-loud contract).
# Called from cmd_up / cmd_init BEFORE any container-state side-effects so a
# malformed or selection-list-future-version config aborts the whole command.
#
# Behavior:
#   - No config file present (neither layer)        → return 0 (D5: no posture
#                                                     change beyond informational)
#   - Any config file present + yq missing on PATH  → exit 1 with ADR-001
#                                                     actionable error
#   - Any config file present + _load_effective_config returns non-zero
#     (D3 selection-list + future-version)          → exit 1 (loader already
#                                                     emitted the error to stderr)
#
# Idempotent: safe to call multiple times per invocation. Cheap (single yq +
# single jq pipeline; comparable to `rc config show` cost ~50ms).
_config_validate_or_abort() {
  local workspace="$1"
  local global_path project_path
  global_path=$(_config_global_path)
  project_path=$(_config_project_path "$workspace")
  if [[ ! -f "$global_path" && ! -f "$project_path" ]]; then
    return 0
  fi
  _config_check_yq
  if ! _load_effective_config "$workspace" >/dev/null; then
    exit 1
  fi
  return 0
}


# Path to the per-container "applied config" snapshot. Written at cmd_up
# create-time and after cmd_reload. Compared against live effective config by
# both cmd_reload
# (to decide what changed) and _config_emit_hint (to suppress false-positive
# drift hints once a reload has been applied — labels are immutable post-create
# so a sha-only check would warn forever).
_config_applied_path() {
  local cname="$1"
  echo "${HOME}/.cache/rip-cage/${cname}/config-applied.json"
}


# Write the snapshot. Caller passes the effective-config JSON object as $2
# (the {network:{...}, egress:..., etc.} subtree — same shape as `.config` from
# _load_effective_config). Truncate-then-write to preserve inode (rip-cage-rx8
# recipe: never mv-into-place, the parent dir is not bind-mounted).
_config_write_applied() {
  local cname="$1" cfg_json="$2"
  local path
  path=$(_config_applied_path "$cname")
  mkdir -p "$(dirname "$path")"
  : > "$path"
  printf '%s\n' "$cfg_json" > "$path"
}


# Read snapshot. Echoes JSON to stdout if file exists, empty otherwise.
_config_read_applied() {
  local cname="$1" path
  path=$(_config_applied_path "$cname")
  [[ -f "$path" ]] || return 1
  cat "$path"
}

