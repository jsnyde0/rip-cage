#!/usr/bin/env bash
# cli/lib/manifest_checks.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# =============================================================================
# Tool manifest schema + host-only loader (rip-cage-4c5.1)
#
# ADR-005 D7/D8 — schema format crystallized here; storage host-only (FIRM).
# ADR-021 D1   — manifest lives at ~/.config/rip-cage/tools.yaml (host config home).
# ADR-024 D1   — host-only = agent-inaccessible (prompt-injection threat model).
# ADR-001      — strict-parse, fail-closed; validator is independent of consumer.
#
# Three archetypes (ADR-005 D2):
#   TOOL             — binary on PATH; required fields: name, archetype, egress (list), mounts (list), version_pin
#   SHELL-INTEGRATION — shell rc eval line; required: name, archetype, shell_init, version_pin
#   IN-CAGE-DAEMON   — localhost service; required: name, archetype, start, health, state_dir, version_pin
#                       optional: mcp_fragment
#
# Default manifest = current bundled stack (D8: no-manifest cage is byte-for-byte today's image).
# =============================================================================

# Returns the path to the host-side tool manifest.
# Honors RC_MANIFEST_GLOBAL env override (for testing); falls back to
# XDG_CONFIG_HOME / ~/.config/rip-cage/tools.yaml (ADR-021 D1).
#
# RC_MANIFEST_GLOBAL and XDG_CONFIG_HOME are host-side test/operator overrides.
# The agent-inaccessible invariant (ADR-005 D7 FIRM, ADR-024 D1) does NOT rest
# on this path being unconditionally fixed — it rests on rc running host-side
# (rc is not copied into the container image; neither env var is forwarded into
# the cage).  Tests that redirect these vars to a temp dir exercise the
# path-derivation logic correctly without breaking the security property.
_manifest_global_path() {
  echo "${RC_MANIFEST_GLOBAL:-${XDG_CONFIG_HOME:-$HOME/.config}/rip-cage/tools.yaml}"
}


# The default (floor-only) tool manifest — the containment floor with no optional tools.
# Any cage built from this default gets beads, dolt, and gh only — no CC, pi, dcg,
# or ssh-bypass. The "blessed default" for the PUBLISHED image is manifest/default-tools.yaml
# (maintainer-authored, composing CC+pi+dcg+ssh-bypass). This in-repo default stays
# floor-only so rc never silently special-cases any optional tool (ADR-005 D12).
#
# Agents and operators compose the rest: copy recipe fragments from examples/ into
# ~/.config/rip-cage/tools.yaml (or manifest/default-tools.yaml) and run rc build.
_manifest_default_yaml() {
  cat <<'YAML'
version: 1
tools:
  - name: beads
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - api.github.com
    mounts: []

  - name: dolt
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - doltremoteapi.dolthub.com
    mounts: []

  - name: gh
    archetype: TOOL
    version_pin: "bundled"
    egress:
      - api.github.com
      - github.com
    mounts: []

  # claude, pi, dcg, ssh-bypass are NOT floor — they are composable recipes.
  # See examples/{claude,pi,dcg,ssh-bypass}/ for recipe fragments.
  # The published image composes them via manifest/default-tools.yaml (rip-cage-wlwc.12).
  # Add recipe entries to ~/.config/rip-cage/tools.yaml and run rc build to opt in.
YAML
}


# Auto-seed the manifest on first run. Mirrors _config_ensure_global_seeded.
# If the file already exists: silent no-op (idempotent — returns 0 immediately).
# If absent: mkdir -p its directory, write the default manifest YAML, emit a
# one-line stderr notice.
_manifest_ensure_seeded() {
  local _path
  _path=$(_manifest_global_path)
  if [[ -f "$_path" ]]; then
    return 0
  fi
  if ! mkdir -p "$(dirname "$_path")"; then
    echo "Error: failed to create manifest directory for ${_path}." >&2
    exit 1
  fi
  if ! _manifest_default_yaml > "$_path" || [[ ! -s "$_path" ]]; then
    echo "Error: failed to seed default tool manifest at ${_path}." >&2
    exit 1
  fi
  echo "rip-cage: seeded default tool manifest at ${_path} (first run; edit to add tools)." >&2
}


# =============================================================================
# Manifest seed-drift detection + reconcile (rip-cage-6vt9)
#
# ROOT CAUSE: the operator manifest ~/.config/rip-cage/tools.yaml is typically
# composed once — by copying manifest/default-tools.yaml (the maintainer-blessed
# composed default; see _manifest_default_yaml's header above for why the
# in-repo default stays floor-only) and adding custom entries — then never
# re-checked against the shipped defaults. When manifest/default-tools.yaml's
# recipes change (e.g. a guard relocation), a frozen local manifest keeps
# baking the superseded layout on every `rc build`, silently.
#
# Sibling of rip-cage-jnvb (stale IMAGE blind-resumed on `rc up`): same
# "stale artifact silently used, no drift-detection" family — jnvb compares
# a resumed container's pinned image against the current image; this
# compares a local manifest's seed provenance against the current
# manifest/default-tools.yaml.
#
# DETECTION SUBSTRATE: a seed-provenance STAMP (`# rc-seed-fingerprint:
# sha256:<hash>` comment line, written by `rc manifest reconcile`), not a
# raw content-diff of local-vs-dist — a content-diff would false-fire on
# legitimate user customization (any hand-edit looks like drift to a naive
# diff). The stamp records dist's hash AT RECONCILE TIME; `rc build`
# compares it to dist's CURRENT hash.
#
# UNSTAMPED manifests (every manifest in the wild before this bead, and any
# hand-authored one that never ran `rc manifest reconcile`) have no
# ground truth to compare against. Rather than risk a false-fire content
# heuristic, this is split by the one case we CAN judge safely:
#   - byte-identical to the floor-only in-repo default (_manifest_default_yaml)
#     -> nothing was ever composed from dist; there is nothing to reconcile;
#        stay completely silent (an unconfigured `rc build` must never warn).
#   - anything else (composed/hand-edited, no stamp) -> a soft, distinctly-
#     worded "provenance unknown" notice pointing at `rc manifest reconcile`
#     to adopt tracking. Never the hard "stale" wording — we don't actually
#     know it's stale, only that we can't tell.
# =============================================================================

# _manifest_dist_path — the shipped, maintainer-composed default manifest
# (manifest/default-tools.yaml), resolved relative to this checkout/install.
_manifest_dist_path() {
  echo "${SCRIPT_DIR}/manifest/default-tools.yaml"
}


# _manifest_seed_fingerprint_hash FILE — bare sha256 hex digest of FILE's
# current byte content (no "sha256:" prefix, no comment wrapper).
_manifest_seed_fingerprint_hash() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}


# _manifest_extract_seed_fingerprint FILE — the recorded fingerprint hash
# from FILE's `# rc-seed-fingerprint: sha256:<hex>` stamp line, if present.
# Empty stdout = unstamped (a NORMAL, expected outcome for most manifests —
# always returns 0, even on no-match; grep's no-match exit code must not
# propagate under `set -o pipefail`, which would otherwise abort the caller
# under `set -e` on the (common) unstamped path). Extracted via grep/sed on
# the raw file, NOT via a yq round-trip — yq's YAML re-serialization can
# drop comments, so the stamp must never pass through it (rc manifest
# reconcile writes the stamp line directly, after any yq-based rendering,
# for the same reason).
_manifest_extract_seed_fingerprint() {
  local _line
  _line=$(grep -m1 '^# rc-seed-fingerprint: sha256:' "$1" 2>/dev/null || true)
  sed -n 's/^# rc-seed-fingerprint: sha256:\([0-9a-f]*\).*/\1/p' <<<"$_line"
  return 0
}


# _manifest_check_seed_drift MANIFEST_PATH
# Informational only — emits at most one line to stderr, never fails the
# build. See the section header above for the full detection design.
_manifest_check_seed_drift() {
  local _manifest_path="$1"
  local _dist_path
  _dist_path=$(_manifest_dist_path)

  [[ -f "$_manifest_path" ]] || return 0
  [[ -f "$_dist_path" ]] || return 0

  # Bypass: MANIFEST_PATH resolves to rc's own shipped dist file (the
  # RC_MANIFEST_GLOBAL=manifest/default-tools.yaml CI/release compose path). It
  # IS dist — comparing it to itself is meaningless, and this path must
  # never surface a warning in CI.
  local _manifest_abs _dist_abs
  _manifest_abs="$(cd "$(dirname "$_manifest_path")" 2>/dev/null && pwd)/$(basename "$_manifest_path")"
  _dist_abs="$(cd "$(dirname "$_dist_path")" 2>/dev/null && pwd)/$(basename "$_dist_path")"
  if [[ -n "$_manifest_abs" && "$_manifest_abs" == "$_dist_abs" ]]; then
    return 0
  fi

  local _stamp
  _stamp=$(_manifest_extract_seed_fingerprint "$_manifest_path")

  if [[ -n "$_stamp" ]]; then
    local _current_hash
    _current_hash=$(_manifest_seed_fingerprint_hash "$_dist_path")
    if [[ "$_stamp" != "$_current_hash" ]]; then
      echo "Warning: ${_manifest_path} was seeded/reconciled from an older manifest/default-tools.yaml layout — the shipped defaults changed since (sibling drift-detection family: rip-cage-jnvb, stale image on resume). Run 'rc manifest reconcile' to pull the update (preserves your custom entries)." >&2
    fi
    return 0
  fi

  # Unstamped. A pristine, never-composed floor default is healthy by
  # construction — stay silent rather than cry-wolf on every default build.
  local _manifest_content _floor_default_content
  _manifest_content=$(cat "$_manifest_path" 2>/dev/null)
  _floor_default_content=$(_manifest_default_yaml)
  if [[ "$_manifest_content" == "$_floor_default_content" ]]; then
    return 0
  fi

  # rip-cage-6vt9 F1 (adversarial review fold): the bead's own documented
  # repro is an UNSTAMPED manifest frozen at an older dist layout — that
  # case must not be limited to a "provenance unknown" shrug. Compare each
  # LOCALLY-present entry whose name ALSO exists in the CURRENT dist by
  # name (entry-level, not a whole-file diff — a whole-file diff false-fires
  # on ANY customization, e.g. an added custom tool). A dist-default entry
  # simply absent locally is fine (operators compose subsets); only entries
  # present on BOTH sides are load-bearing here. Reuses the same yq/jq
  # node-extraction shape as _manifest_reconcile below (sibling: rip-cage-jnvb,
  # stale image on resume).
  command -v yq &>/dev/null || return 0
  command -v jq &>/dev/null || return 0
  local _local_tools_json _dist_tools_json
  _local_tools_json=$(yq -o=json '.tools // []' "$_manifest_path" 2>/dev/null) || return 0
  _dist_tools_json=$(yq -o=json '.tools // []' "$_dist_path" 2>/dev/null) || return 0

  local _intersecting_json
  _intersecting_json=$(jq -c -n --argjson dist "$_dist_tools_json" --argjson local "$_local_tools_json" '
    ($dist | map(.name)) as $dist_names
    | [ $local[] | select(.name as $n | $dist_names | index($n)) | .name ]
  ' 2>/dev/null) || return 0

  if [[ "$_intersecting_json" == "[]" || -z "$_intersecting_json" ]]; then
    # Zero overlap with dist by name — an all-custom manifest. Nothing to
    # compare; fall back to the same soft "provenance unknown" notice.
    echo "Notice: ${_manifest_path} has no seed-fingerprint stamp (composed before this rc version, or hand-authored) — its freshness vs the shipped manifest/default-tools.yaml defaults is unknown. Run 'rc manifest reconcile' to adopt tracking (preserves your custom entries)." >&2
    return 0
  fi

  local _differing_names
  _differing_names=$(jq -r -n --argjson dist "$_dist_tools_json" --argjson local "$_local_tools_json" '
    ($dist | map({key: .name, value: .}) | from_entries) as $dist_by_name
    | [ $local[] | select(.name as $n | $dist_by_name | has($n)) | select($dist_by_name[.name] != .) | .name ]
    | join(", ")
  ' 2>/dev/null)

  if [[ -n "$_differing_names" ]]; then
    echo "Warning: ${_manifest_path}: entries also present in the shipped manifest/default-tools.yaml no longer match it — [${_differing_names}] differ from the current dist defaults (customized, or seeded by an older rc — a stale seed silently bakes superseded recipe layouts). Run 'rc manifest reconcile' to refresh defaults (preserves custom entries, backs up the old file, stamps provenance)." >&2
  fi
  # All name-intersecting entries byte/structurally match current dist —
  # provably current. Stay completely silent (no notice at all): this is
  # the cry-wolf-prevention branch for a healthy composed-but-unstamped
  # manifest.
}


# _manifest_check_install_cmd_single_line FILE IDX NAME VALUE
# install_cmd is interpolated inline into a generated Dockerfile RUN line by
# _manifest_generate_extra_dockerfile_steps, which has no archetype filter —
# TOOL, SHELL-INTEGRATION and IN-CAGE-DAEMON entries may all carry it — so
# the newline-injection guard must hold in all three of those cases, not just
# TOOL (rip-cage-62a9; ADR-005 D11 mechanism 2). MULTIPLEXER/MEDIATOR
# strict-parse reject install_cmd outright. This helper covers install_cmd
# only; the sibling build_source sub-field validation now lives in
# _manifest_check_build_source_subfields below, applied across the same set
# of consumed archetypes (rip-cage-m0hh).
_manifest_check_install_cmd_single_line() {
  local file="$1" idx="$2" name="$3" value="$4"
  if [[ "$value" == *$'\n'* ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'install_cmd' must be a single line (newlines inject arbitrary Dockerfile directives; single-line-required)." >&2
    return 1
  fi
  return 0
}


# _manifest_check_build_source_subfields FILE IDX NAME ENTRY
# build_source is consumed archetype-agnostically by two generators with no
# archetype filter: _manifest_generate_extra_dockerfile_steps (emits
# COPY --from=<stage> ${bs_output_path} ...) and
# _manifest_generate_source_builder_stages (emits
# FROM ${bs_builder_image} AS <stage> and COPY ${bs_build_script}
# /rc-build/build.sh) — TOOL, SHELL-INTEGRATION and IN-CAGE-DAEMON entries
# may all carry build_source, so the sub-field validation (required fields,
# single-line, build-context escape) must hold for every archetype the
# generators actually consume, not just TOOL (rip-cage-m0hh; sibling of the
# install_cmd gap fixed in rip-cage-62a9; ADR-005 D11 mechanism 2 / ADR-024).
_manifest_check_build_source_subfields() {
  local file="$1" idx="$2" name="$3" entry="$4"
  local bs_builder_image bs_build_script bs_output_path
  bs_builder_image=$(jq -r '.build_source.builder_image // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
  bs_build_script=$(jq -r '.build_source.build_script // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
  bs_output_path=$(jq -r '.build_source.output_path // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
  if [[ "$bs_builder_image" == "___RC_ABSENT___" || -z "$bs_builder_image" ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'build_source.builder_image' is missing (from-source entries must declare the Docker builder image)." >&2
    return 1
  fi
  # builder_image must be a single line — newlines inject arbitrary Dockerfile directives (ADR-024).
  if [[ "$bs_builder_image" == *$'\n'* ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'build_source.builder_image' must be a single line (newlines inject arbitrary Dockerfile directives; single-line-required)." >&2
    return 1
  fi
  if [[ "$bs_build_script" == "___RC_ABSENT___" || -z "$bs_build_script" ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'build_source.build_script' is missing (from-source entries must declare the host-side build script path)." >&2
    return 1
  fi
  # build_script must be a single line — newlines inject arbitrary Dockerfile directives (ADR-024).
  if [[ "$bs_build_script" == *$'\n'* ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'build_source.build_script' must be a single line (newlines inject arbitrary Dockerfile directives; single-line-required)." >&2
    return 1
  fi
  # build_script must be a relative path that does NOT escape the build context (SCRIPT_DIR /
  # repo root). An absolute path or a ../-escape is rejected fail-loud (ADR-001):
  #   - Docker would fail with an opaque "forbidden path outside build context" error; the
  #     validator must catch it FIRST with a named error (rip-cage-buuo.6 F2).
  if [[ "${bs_build_script:0:1}" == "/" ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'build_source.build_script' must be a relative path within the build context (repo root) — absolute paths are outside the Docker build context and will be rejected by docker build (ADR-001 fail-loud; rip-cage-buuo.6 F2). Got: '${bs_build_script}'." >&2
    return 1
  fi
  # Reject ../ traversal: any path starting with "../" or containing "/../" or ending with "/..",
  # and also the bare ".." path (no slashes) — all escape the build context (repo root).
  # Check each variant explicitly.
  if [[ "$bs_build_script" == ".." ]] || [[ "$bs_build_script" == "../"* ]] || [[ "$bs_build_script" == *"/../"* ]] || [[ "$bs_build_script" == *"/.." ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'build_source.build_script' must not escape the build context — '../' traversal resolves outside the repo root and will be rejected by docker build (ADR-001 fail-loud; rip-cage-buuo.6 F2). Got: '${bs_build_script}'." >&2
    return 1
  fi
  if [[ "$bs_output_path" == "___RC_ABSENT___" || -z "$bs_output_path" ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'build_source.output_path' is missing (from-source entries must declare the output binary path inside the builder stage)." >&2
    return 1
  fi
  # output_path must be a single line — newlines inject arbitrary Dockerfile directives (ADR-024).
  if [[ "$bs_output_path" == *$'\n'* ]]; then
    echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'build_source.output_path' must be a single line (newlines inject arbitrary Dockerfile directives; single-line-required)." >&2
    return 1
  fi
  return 0
}


# _manifest_validate FILE
# Strict-parse, fail-closed validator for a manifest YAML file.
# Validates ALL tool entries. On the first violation, prints a field-naming
# error to stderr and returns non-zero. Does NOT use a fail-open consumer.
# (validate-config-by-parsing-not-by-running-fail-open-consumer — ADR-001)
_manifest_validate() {
  local file="$1"

  # yq required (same policy as config loader — no silent degradation ADR-001).
  if ! command -v yq &>/dev/null; then
    echo "Error: yq not found on PATH. yq is a rip-cage manifest dependency — install it: brew install yq (macOS) or the mikefarah/yq release binary (Linux: https://github.com/mikefarah/yq/releases) — NOT apt's yq, which is the incompatible python-yq." >&2
    return 1
  fi

  local json
  if ! json=$(yq -o=json '.' "$file" 2>/dev/null); then
    echo "Error: manifest '${file}' failed to parse as YAML." >&2
    return 1
  fi

  # Empty / null file → treat as "use defaults" (caller handles; validator passes empty)
  if [[ -z "$json" || "$json" == "null" ]]; then
    return 0
  fi

  # version field check (must be numeric scalar, if present)
  local version
  version=$(jq -r '.version // "MISSING"' <<<"$json" 2>/dev/null)
  if [[ "$version" != "MISSING" && ! "$version" =~ ^[0-9]+$ ]]; then
    echo "Error: manifest '${file}' has invalid 'version' field: '${version}' (must be a positive integer)." >&2
    return 1
  fi

  # tools must be a list (if present)
  local tools_type
  tools_type=$(jq -r 'if has("tools") then (.tools | type) else "absent" end' <<<"$json" 2>/dev/null)
  if [[ "$tools_type" != "absent" && "$tools_type" != "array" ]]; then
    echo "Error: manifest '${file}' field 'tools' must be a list, got: ${tools_type}." >&2
    return 1
  fi

  # Per-entry validation: walk each entry
  local count idx
  count=$(jq '.tools | length' <<<"$json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  for (( idx=0; idx<count; idx++ )); do
    local entry
    entry=$(jq -c ".tools[${idx}]" <<<"$json" 2>/dev/null)

    # 'name' is required on every entry
    local name
    name=$(jq -r '.name // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
    if [[ "$name" == "___RC_ABSENT___" || -z "$name" ]]; then
      echo "Error: manifest '${file}' tools[${idx}]: required field 'name' is missing." >&2
      return 1
    fi

    # 'archetype' is required and must be one of the three valid values
    local archetype
    archetype=$(jq -r '.archetype // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" == "___RC_ABSENT___" || -z "$archetype" ]]; then
      echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'archetype' is missing." >&2
      return 1
    fi
    case "$archetype" in
      TOOL|SHELL-INTEGRATION|IN-CAGE-DAEMON|MULTIPLEXER|MEDIATOR)
        ;;
      *)
        echo "Error: manifest '${file}' tools[${idx}] ('${name}'): unknown 'archetype' value '${archetype}'. Allowed: TOOL, SHELL-INTEGRATION, IN-CAGE-DAEMON, MULTIPLEXER, MEDIATOR." >&2
        return 1
        ;;
    esac

    # 'version_pin' is required on every entry (all three archetypes — ADR-005 D3)
    local version_pin
    version_pin=$(jq -r '.version_pin // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
    if [[ "$version_pin" == "___RC_ABSENT___" || -z "$version_pin" ]]; then
      echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'version_pin' is missing (all archetypes require a version_pin; use \"bundled\" for image-bundled tools)." >&2
      return 1
    fi

    # Archetype-specific required field checks
    case "$archetype" in
      TOOL)
        # 'egress' required and must be a list
        local egress_type
        egress_type=$(jq -r 'if has("egress") then (.egress | type) else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$egress_type" == "absent" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'egress' is missing (TOOL archetype requires egress declaration, even if empty: egress: [])." >&2
          return 1
        fi
        if [[ "$egress_type" != "array" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'egress' must be a list, got: ${egress_type}." >&2
          return 1
        fi
        # 'mounts' required and must be a list
        local mounts_type
        mounts_type=$(jq -r 'if has("mounts") then (.mounts | type) else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$mounts_type" == "absent" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'mounts' is missing (TOOL archetype requires mounts declaration, even if empty: mounts: [])." >&2
          return 1
        fi
        if [[ "$mounts_type" != "array" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'mounts' must be a list, got: ${mounts_type}." >&2
          return 1
        fi
        # Each mounts[] element must be an object {host, dest} (rip-cage-buuo.1).
        # Scalar strings (old shape) are rejected fail-loud.
        local mounts_count_for_val midx_val
        mounts_count_for_val=$(jq '.mounts | length' <<<"$entry" 2>/dev/null)
        for (( midx_val=0; midx_val<mounts_count_for_val; midx_val++ )); do
          local mount_element mount_elem_type
          mount_element=$(jq -c ".mounts[${midx_val}]" <<<"$entry" 2>/dev/null)
          mount_elem_type=$(jq -r 'type' <<<"$mount_element" 2>/dev/null)
          if [[ "$mount_elem_type" != "object" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): mounts[${midx_val}] must be an object with 'host' and 'dest' fields, got: ${mount_elem_type} (use {host: \"/path/on/host\", dest: \"/path/in/cage\"})." >&2
            return 1
          fi
          # 'host' is required and must be non-empty
          local mount_host
          mount_host=$(jq -r '.host // "___RC_ABSENT___"' <<<"$mount_element" 2>/dev/null)
          if [[ "$mount_host" == "___RC_ABSENT___" || -z "$mount_host" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): mounts[${midx_val}]: required field 'host' is missing or empty (must be the host-side directory path to mount)." >&2
            return 1
          fi
          # 'dest' is required and must be non-empty
          local mount_dest
          mount_dest=$(jq -r '.dest // "___RC_ABSENT___"' <<<"$mount_element" 2>/dev/null)
          if [[ "$mount_dest" == "___RC_ABSENT___" || -z "$mount_dest" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): mounts[${midx_val}]: required field 'dest' is missing or empty (must be the in-cage destination path)." >&2
            return 1
          fi
          # 'mode' is optional (default: ro); when present must be exactly "ro" or "rw".
          # rip-cage-wlwc.3: per-asset ro/rw mount seam (ADR-027 D1).
          local mount_mode_raw
          mount_mode_raw=$(jq -r '.mode // "___RC_ABSENT___"' <<<"$mount_element" 2>/dev/null)
          if [[ "$mount_mode_raw" != "___RC_ABSENT___" ]]; then
            if [[ "$mount_mode_raw" != "ro" && "$mount_mode_raw" != "rw" ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): mounts[${midx_val}]: field 'mode' must be 'ro' or 'rw' (got '${mount_mode_raw}'); default is 'ro' (ADR-027 D1 / rip-cage-wlwc.3)." >&2
              return 1
            fi
          fi
          # 'root_owned_required' is optional (default: false); when present must be a boolean.
          # rip-cage-wlwc.3: generic per-asset root-owned flag (NOT AGENT-keyed).
          local root_owned_raw root_owned_type
          root_owned_raw=$(jq -r 'if has("root_owned_required") then (.root_owned_required | tostring) else "___RC_ABSENT___" end' <<<"$mount_element" 2>/dev/null)
          if [[ "$root_owned_raw" != "___RC_ABSENT___" ]]; then
            root_owned_type=$(jq -r 'if has("root_owned_required") then (.root_owned_required | type) else "absent" end' <<<"$mount_element" 2>/dev/null)
            if [[ "$root_owned_type" != "boolean" ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): mounts[${midx_val}]: field 'root_owned_required' must be a boolean (true or false), got type '${root_owned_type}' (rip-cage-wlwc.3)." >&2
              return 1
            fi
          fi
        done
        # 'install_cmd' / 'build_source' coupling with version_pin:
        #   version_pin == "bundled"  → MUST NOT have install_cmd or build_source
        #   version_pin != "bundled"  → MUST have EITHER install_cmd (single-line) OR build_source
        #                               (builder_image + build_script + output_path); not both.
        # build_source is the from-source path (rip-cage-buuo.2 ADR-005 D6/D11).
        # Newlines in install_cmd are rejected regardless (newline-injection defense — fix 2).
        local install_cmd_raw build_source_raw
        install_cmd_raw=$(jq -r '.install_cmd // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        build_source_raw=$(jq -r 'if has("build_source") and (.build_source | type) == "object" then "present" else "___RC_ABSENT___" end' <<<"$entry" 2>/dev/null)
        if [[ "$version_pin" == "bundled" ]]; then
          if [[ "$install_cmd_raw" != "___RC_ABSENT___" && -n "$install_cmd_raw" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'install_cmd' must not be set when version_pin is \"bundled\" (bundled tools are baked by the Dockerfile; install_cmd is contradictory)." >&2
            return 1
          fi
          if [[ "$build_source_raw" == "present" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'build_source' must not be set when version_pin is \"bundled\" (bundled tools are baked by the Dockerfile; build_source is contradictory)." >&2
            return 1
          fi
        elif [[ "$build_source_raw" == "present" ]]; then
          # From-source path: build_source present — install_cmd must NOT also be set.
          if [[ "$install_cmd_raw" != "___RC_ABSENT___" && -n "$install_cmd_raw" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): fields 'install_cmd' and 'build_source' are mutually exclusive (use build_source for from-source builds; install_cmd for prebuilt package installs)." >&2
            return 1
          fi
          # Validate build_source sub-fields: builder_image, build_script, output_path
          # (all required, single-line, build-context-scoped). Shared helper — also
          # applied to SHELL-INTEGRATION and IN-CAGE-DAEMON below (rip-cage-m0hh).
          if ! _manifest_check_build_source_subfields "$file" "$idx" "$name" "$entry"; then
            return 1
          fi
        else
          # Non-bundled, no build_source: install_cmd required and must be non-empty
          if [[ "$install_cmd_raw" == "___RC_ABSENT___" || -z "$install_cmd_raw" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'install_cmd' is missing (non-bundled TOOL entries must have an install_cmd so the binary can be baked into the image at build time)." >&2
            return 1
          fi
          # install_cmd must be a single line — newlines inject arbitrary Dockerfile directives.
          if ! _manifest_check_install_cmd_single_line "$file" "$idx" "$name" "$install_cmd_raw"; then
            return 1
          fi
        fi
        # Validate optional 'binary_path' field (rip-cage-ryn6).
        # binary_path may be a string OR a list of strings. When present, each entry
        # must be a non-empty, single-line absolute path. When absent, valid (un-checked
        # by binary-root-owned assertion — deliberate 80/20 boundary per ADR-024 D11).
        # Format-validated for ANY TOOL entry that carries the field; only CONSUMED by the
        # binary-root-owned assertion for install_cmd (prebuilt) entries — from-source entries
        # are checked via build_source.output_path and ignore a stray binary_path at runtime.
        local binary_path_raw binary_path_type
        binary_path_raw=$(jq -r 'if has("binary_path") then "present" else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$binary_path_raw" == "present" ]]; then
          binary_path_type=$(jq -r '.binary_path | type' <<<"$entry" 2>/dev/null)
          if [[ "$binary_path_type" == "string" ]]; then
            # Single string — validate non-empty, single-line, absolute.
            local bp_val
            bp_val=$(jq -r '.binary_path' <<<"$entry" 2>/dev/null)
            if [[ -z "$bp_val" ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path' must be a non-empty absolute path (got empty string)." >&2
              return 1
            fi
            if [[ "$bp_val" == *$'\n'* ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path' must be a single-line absolute path (newlines are not allowed; single-line-required)." >&2
              return 1
            fi
            if [[ "${bp_val:0:1}" != "/" ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path' must be an absolute path starting with '/' (got: '${bp_val}')." >&2
              return 1
            fi
          elif [[ "$binary_path_type" == "array" ]]; then
            # List of strings — validate each entry.
            local bp_count bp_i
            bp_count=$(jq '.binary_path | length' <<<"$entry" 2>/dev/null)
            for (( bp_i=0; bp_i<bp_count; bp_i++ )); do
              local bp_elem_type bp_elem_val
              bp_elem_type=$(jq -r ".binary_path[${bp_i}] | type" <<<"$entry" 2>/dev/null)
              if [[ "$bp_elem_type" != "string" ]]; then
                echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path[${bp_i}]' must be a string (got: ${bp_elem_type})." >&2
                return 1
              fi
              bp_elem_val=$(jq -r ".binary_path[${bp_i}]" <<<"$entry" 2>/dev/null)
              if [[ -z "$bp_elem_val" ]]; then
                echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path[${bp_i}]' must be a non-empty absolute path (got empty string)." >&2
                return 1
              fi
              if [[ "$bp_elem_val" == *$'\n'* ]]; then
                echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path[${bp_i}]' must be a single-line absolute path (newlines are not allowed; single-line-required)." >&2
                return 1
              fi
              if [[ "${bp_elem_val:0:1}" != "/" ]]; then
                echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path[${bp_i}]' must be an absolute path starting with '/' (got: '${bp_elem_val}')." >&2
                return 1
              fi
            done
          else
            # Neither string nor array — reject.
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'binary_path' must be a string or a list of strings (got: ${binary_path_type})." >&2
            return 1
          fi
        fi
        # Validate optional 'launch_args' field (rip-cage-l72i.1 / ADR-027 D4).
        # launch_args is a list of strings — manifest-declared launch flags contributed
        # by this recipe fragment and concatenated by rc build across fragments in
        # fragment order (ADR-005 D12: owning the composition interface, not naming a tool).
        # When absent, valid (no launch-arg contribution from this fragment).
        # Each element must be a non-empty, single-line string (newline-injection defense).
        local launch_args_raw launch_args_type
        launch_args_raw=$(jq -r 'if has("launch_args") then "present" else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$launch_args_raw" == "present" ]]; then
          launch_args_type=$(jq -r '.launch_args | type' <<<"$entry" 2>/dev/null)
          if [[ "$launch_args_type" != "array" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'launch_args' must be a list of strings (got: ${launch_args_type}; use launch_args: [\"--flag\", \"value\"])." >&2
            return 1
          fi
          local la_count la_i
          la_count=$(jq '.launch_args | length' <<<"$entry" 2>/dev/null)
          for (( la_i=0; la_i<la_count; la_i++ )); do
            local la_elem_type la_elem_val
            la_elem_type=$(jq -r ".launch_args[${la_i}] | type" <<<"$entry" 2>/dev/null)
            if [[ "$la_elem_type" != "string" ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'launch_args[${la_i}]' must be a string (got: ${la_elem_type})." >&2
              return 1
            fi
            la_elem_val=$(jq -r ".launch_args[${la_i}]" <<<"$entry" 2>/dev/null)
            if [[ -z "$la_elem_val" ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'launch_args[${la_i}]' must be a non-empty string (got empty string)." >&2
              return 1
            fi
            if [[ "$la_elem_val" == *$'\n'* ]]; then
              echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'launch_args[${la_i}]' must be a single-line string (newlines are not allowed; single-line-required)." >&2
              return 1
            fi
          done
        fi
        # Validate optional 'init' field (rip-cage-p35a.2, ADR-005 D7).
        # A one-shot AGENT-CONTEXT boot command a TOOL recipe declares — runs once
        # at cage boot (distinct from IN-CAGE-DAEMON 'start', which launches a
        # long-lived background service). Uniform with how MULTIPLEXER/MEDIATOR
        # contribute boot logic (ADR-005 D9/D11) — completes the per-archetype
        # build/boot/launch lifecycle. When absent, valid (no init contribution).
        local tool_init_raw
        tool_init_raw=$(jq -r '.init // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        if [[ "$tool_init_raw" != "___RC_ABSENT___" ]]; then
          # Must be non-empty/non-whitespace (never eval "").
          local tool_init_trimmed
          tool_init_trimmed=$(printf '%s' "$tool_init_raw" | tr -d '[:space:]')
          if [[ -z "$tool_init_trimmed" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'init' is present but empty/whitespace — an empty hook is never run as eval \"\" (rip-cage-p35a.2)." >&2
            return 1
          fi
          # Must be a single line — newlines inject arbitrary Dockerfile directives
          # when baked (same injection-safety rule as install_cmd/shell_init/hooks.*).
          if [[ "$tool_init_raw" == *$'\n'* ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'init' must be a single-line shell command (newlines inject arbitrary Dockerfile directives; single-line-required; rip-cage-p35a.2)." >&2
            return 1
          fi
          # Hook-bounds check (ADR-005 D10/D11, ADR-001 fail-loud) — the exact
          # floor-weakening patterns enforced on MULTIPLEXER/MEDIATOR hooks
          # (rc:6995-7068), STATICALLY applied to the TOOL 'init' hook command.
          # Parse, never run (validate-config-by-parsing-not-by-running-fail-open-consumer).
          if echo "$tool_init_raw" | grep -qE '\.config/dcg/'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — 'init' references '.config/dcg/' path, which is the DCG safety floor config (floor-weakening write; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the init command." >&2
            return 1
          fi
          if echo "$tool_init_raw" | grep -qE '\.dcg\.toml'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — 'init' references '.dcg.toml', which is the workspace DCG config (floor-weakening write; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the init command." >&2
            return 1
          fi
          if echo "$tool_init_raw" | grep -qE 'PATH='; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — 'init' sets PATH=, which can PATH-shadow safety binaries (dcg, dcg-policy, block-ssh-bypass) and weakens the safety floor (floor-weakening; ADR-005 D10/D11, ADR-001 fail-loud). Remove PATH manipulation from the init command." >&2
            return 1
          fi
          if echo "$tool_init_raw" | grep -qE '/(usr/local/lib/rip-cage/(bin|hooks)|usr/local/bin|usr/bin)/(dcg-guard|dcg|dcg-policy|block-ssh-bypass(\.sh)?)'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — 'init' writes to a safety binary path (/usr/local/lib/rip-cage/bin/dcg-guard or similar), which would replace a safety floor binary (floor-weakening; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the init command." >&2
            return 1
          fi
          if echo "$tool_init_raw" | grep -qE '/etc/rip-cage/|settings\.json|PreToolUse|PostToolUse'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — 'init' references lifecycle-interceptor targets (/etc/rip-cage/, settings.json, PreToolUse, or PostToolUse), which can register hooks that weaken the safety floor (floor-weakening lifecycle-interceptor; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the init command." >&2
            return 1
          fi
        fi
        ;;
      SHELL-INTEGRATION)
        # 'shell_init' required and must be a single line.
        # Newlines in shell_init are rejected here (fail-closed at load) — mirrors the
        # install_cmd newline guard above.  A defense-in-depth check also lives at the
        # generation site (_manifest_generate_shell_init_zshrc_steps).
        local shell_init
        shell_init=$(jq -r '.shell_init // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        if [[ "$shell_init" == "___RC_ABSENT___" || -z "$shell_init" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'shell_init' is missing (SHELL-INTEGRATION archetype)." >&2
          return 1
        fi
        # shell_init must be a single line — newlines inject arbitrary Dockerfile directives.
        if [[ "$shell_init" == *$'\n'* ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'shell_init' must be a single line (newlines inject arbitrary Dockerfile directives; single-line-required)." >&2
          return 1
        fi
        # Optional 'install_cmd' (binary baking via _manifest_generate_extra_dockerfile_steps,
        # which has no archetype filter) — same newline guard as TOOL (rip-cage-62a9).
        local si_install_cmd
        si_install_cmd=$(jq -r '.install_cmd // ""' <<<"$entry" 2>/dev/null)
        if [[ -n "$si_install_cmd" ]]; then
          if ! _manifest_check_install_cmd_single_line "$file" "$idx" "$name" "$si_install_cmd"; then
            return 1
          fi
        fi
        # Optional 'build_source' (from-source builder stage via
        # _manifest_generate_source_builder_stages / _manifest_generate_extra_dockerfile_steps,
        # neither of which has an archetype filter) — same sub-field guard as TOOL (rip-cage-m0hh).
        local si_build_source_present
        si_build_source_present=$(jq -r 'if has("build_source") and (.build_source | type) == "object" then "present" else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$si_build_source_present" == "present" ]]; then
          if ! _manifest_check_build_source_subfields "$file" "$idx" "$name" "$entry"; then
            return 1
          fi
        fi
        ;;
      IN-CAGE-DAEMON)
        # 'start', 'health', 'state_dir' required
        local daemon_start daemon_health daemon_state_dir
        daemon_start=$(jq -r '.start // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        daemon_health=$(jq -r '.health // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        daemon_state_dir=$(jq -r '.state_dir // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        if [[ "$daemon_start" == "___RC_ABSENT___" || -z "$daemon_start" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'start' is missing (IN-CAGE-DAEMON archetype)." >&2
          return 1
        fi
        if [[ "$daemon_health" == "___RC_ABSENT___" || -z "$daemon_health" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'health' is missing (IN-CAGE-DAEMON archetype)." >&2
          return 1
        fi
        if [[ "$daemon_state_dir" == "___RC_ABSENT___" || -z "$daemon_state_dir" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'state_dir' is missing (IN-CAGE-DAEMON archetype)." >&2
          return 1
        fi
        # R3: fail-closed state_dir path safety guard (ADR-001).
        # state_dir is used in a Dockerfile RUN: mkdir -p <state_dir> && chown -R agent:agent <state_dir>
        # A typo like "/ var" word-splits into "chown -R agent:agent / var" — chowning root.
        # Reject at load if state_dir is not an absolute path token: must start with '/',
        # must contain no whitespace, and must contain no shell metacharacters.
        if [[ "$daemon_state_dir" != /* ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'state_dir' must be an absolute path (starting with '/'); got '${daemon_state_dir}'." >&2
          return 1
        fi
        if [[ "$daemon_state_dir" =~ [[:space:]] ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'state_dir' must not contain whitespace (word-split injection risk); got '${daemon_state_dir}'." >&2
          return 1
        fi
        if [[ "$daemon_state_dir" =~ [\$\`\;\|\&\>\<\(\)\\] ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'state_dir' must not contain shell metacharacters (\$\`;&|><()\\); got '${daemon_state_dir}'." >&2
          return 1
        fi
        # Optional 'install_cmd' (binary baking via _manifest_generate_extra_dockerfile_steps,
        # which has no archetype filter) — same newline guard as TOOL (rip-cage-62a9).
        local daemon_install_cmd
        daemon_install_cmd=$(jq -r '.install_cmd // ""' <<<"$entry" 2>/dev/null)
        if [[ -n "$daemon_install_cmd" ]]; then
          if ! _manifest_check_install_cmd_single_line "$file" "$idx" "$name" "$daemon_install_cmd"; then
            return 1
          fi
        fi
        # Optional 'build_source' (from-source builder stage via
        # _manifest_generate_source_builder_stages / _manifest_generate_extra_dockerfile_steps,
        # neither of which has an archetype filter) — same sub-field guard as TOOL (rip-cage-m0hh).
        local daemon_build_source_present
        daemon_build_source_present=$(jq -r 'if has("build_source") and (.build_source | type) == "object" then "present" else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$daemon_build_source_present" == "present" ]]; then
          if ! _manifest_check_build_source_subfields "$file" "$idx" "$name" "$entry"; then
            return 1
          fi
        fi
        ;;
      MULTIPLEXER)
        # MULTIPLEXER archetype: provider hook contract (ADR-005 D9/D11, rip-cage-61al.1).
        # Required: hooks.start, hooks.attach
        # Optional: hooks.exec, hooks.new_session, hooks.teardown
        # Strict-parse: unknown top-level fields rejected (ADR-025 D5).
        # Hook-bounds check: each hook command is statically asserted to not weaken the
        # safety floor (ADR-005 D10/D11, ADR-001 fail-loud). Parse, never run.

        # Name format check: MULTIPLEXER names are used as directory components under
        # /etc/rip-cage/multiplexers/<name>/ in the image. Only [a-z0-9_-] is safe —
        # quotes, backticks, spaces, slashes, or other metacharacters produce malformed
        # Dockerfile RUN/echo steps that fail docker build with an opaque syntax error.
        # Fail loud here with a clear message (ADR-001) rather than letting docker fail later.
        if [[ ! "$name" =~ ^[a-z0-9_-]+$ ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): MULTIPLEXER name '${name}' contains characters outside [a-z0-9_-] — names are used as directory components in the image registry (/etc/rip-cage/multiplexers/<name>) and must be lowercase alphanumeric, hyphens, or underscores only (ADR-001 fail-loud; name-format check)." >&2
          return 1
        fi

        # Strict-parse: reject unknown/extra top-level fields on MULTIPLEXER entries.
        # Known fields: name, archetype, version_pin, hooks
        local mux_known_fields mux_entry_keys mux_unknown_key
        mux_known_fields="name archetype version_pin hooks"
        mux_entry_keys=$(jq -r 'keys[]' <<<"$entry" 2>/dev/null)
        while IFS= read -r mux_unknown_key; do
          [[ -z "$mux_unknown_key" ]] && continue
          local mux_is_known=0
          local mux_known_chk
          for mux_known_chk in $mux_known_fields; do
            if [[ "$mux_unknown_key" == "$mux_known_chk" ]]; then
              mux_is_known=1
              break
            fi
          done
          if [[ "$mux_is_known" -eq 0 ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): MULTIPLEXER entry has unknown field '${mux_unknown_key}' (strict-parse — only name/archetype/version_pin/hooks are allowed; ADR-025 D5)." >&2
            return 1
          fi
        done <<<"$mux_entry_keys"

        # 'hooks' block is required
        local hooks_type
        hooks_type=$(jq -r 'if has("hooks") then (.hooks | type) else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$hooks_type" == "absent" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'hooks' is missing (MULTIPLEXER archetype)." >&2
          return 1
        fi
        if [[ "$hooks_type" != "object" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'hooks' must be an object, got: ${hooks_type} (MULTIPLEXER archetype)." >&2
          return 1
        fi

        # Required hooks: start and attach
        local mux_start mux_attach
        mux_start=$(jq -r '.hooks.start // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        mux_attach=$(jq -r '.hooks.attach // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        if [[ "$mux_start" == "___RC_ABSENT___" || -z "$mux_start" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'hooks.start' is missing (MULTIPLEXER archetype — start hook is required)." >&2
          return 1
        fi
        if [[ "$mux_attach" == "___RC_ABSENT___" || -z "$mux_attach" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'hooks.attach' is missing (MULTIPLEXER archetype — attach hook is required)." >&2
          return 1
        fi

        # Optional hooks: exec, new_session, teardown (absent = no-op / generic fallback)
        local mux_exec mux_new_session mux_teardown
        mux_exec=$(jq -r '.hooks.exec // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        mux_new_session=$(jq -r '.hooks.new_session // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        mux_teardown=$(jq -r '.hooks.teardown // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)

        # Strict-parse: reject unknown keys INSIDE the hooks object (Finding 3 / ADR-025 D5).
        # Known hook sub-keys: start, attach, exec, new_session, teardown.
        # An unrecognized hook key escapes both the required-hooks check and the bounds
        # iterator — a command hiding under an unknown key is never inspected. Fail-closed.
        local mux_known_hooks mux_hooks_keys mux_hook_key
        mux_known_hooks="start attach exec new_session teardown"
        mux_hooks_keys=$(jq -r '.hooks | keys[]' <<<"$entry" 2>/dev/null)
        while IFS= read -r mux_hook_key; do
          [[ -z "$mux_hook_key" ]] && continue
          local mux_hook_is_known=0
          local mux_known_hook_chk
          for mux_known_hook_chk in $mux_known_hooks; do
            if [[ "$mux_hook_key" == "$mux_known_hook_chk" ]]; then
              mux_hook_is_known=1
              break
            fi
          done
          if [[ "$mux_hook_is_known" -eq 0 ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): MULTIPLEXER entry has unknown hook key '${mux_hook_key}' inside 'hooks' (strict-parse — only start/attach/exec/new_session/teardown are allowed; ADR-025 D5, ADR-005 D10/D11)." >&2
            return 1
          fi
        done <<<"$mux_hooks_keys"

        # Hook-bounds check (M7, ADR-005 D10/D11, ADR-001 fail-loud).
        # Each hook command string is STATICALLY parsed (NEVER executed) to assert it
        # does NOT weaken the safety floor. This is the fail-closed check.
        # validate-config-by-parsing-not-by-running-fail-open-consumer.
        #
        # Forbidden patterns (floor-weakening):
        #   1. Writes to DCG global config: ~/.config/dcg/config.toml or
        #      any path matching */.config/dcg/config.toml or /root/.config/dcg*
        #   2. Writes to workspace DCG config: .dcg.toml (any path ending in .dcg.toml)
        #   3. PATH-shadows a safety binary: copies a file to /usr/local/bin/dcg,
        #      /usr/local/bin/dcg-policy, /usr/local/bin/block-ssh-bypass, or
        #      prepends a PATH entry that shadows one of these names (PATH=...:$PATH
        #      where the prepended dir contains dcg/dcg-policy/block-ssh-bypass).
        #      Static check: reject any hook that sets PATH= (PATH manipulation is
        #      the mechanism; legitimate muxers do not need PATH overrides in hooks).
        #   3b. Direct write to safety binary paths — includes the real in-image paths:
        #      /usr/local/lib/rip-cage/bin/dcg-guard (DCG guard wrapper, policy enforcer)
        #      /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh (ssh-bypass blocker)
        #      as well as /usr/local/bin/{dcg,dcg-policy,block-ssh-bypass} (Finding 1).
        #   4. Lifecycle-interceptor registration — hook modifies the Claude Code settings
        #      file (/etc/rip-cage/settings.json) or references the hook lifecycle keys
        #      PreToolUse / PostToolUse (Finding 2, M7 requirement).
        local mux_hook_name mux_hook_cmd
        for mux_hook_name in start attach exec new_session teardown; do
          case "$mux_hook_name" in
            start)  mux_hook_cmd="$mux_start" ;;
            attach) mux_hook_cmd="$mux_attach" ;;
            exec)   mux_hook_cmd="$mux_exec" ;;
            new_session) mux_hook_cmd="$mux_new_session" ;;
            teardown) mux_hook_cmd="$mux_teardown" ;;
          esac
          [[ "$mux_hook_cmd" == "___RC_ABSENT___" || -z "$mux_hook_cmd" ]] && continue

          # Pattern 1: DCG global config write — matches /.config/dcg/ path patterns
          # including ~, $HOME, /home/*, /root variants.
          if echo "$mux_hook_cmd" | grep -qE '\.config/dcg/'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${mux_hook_name}' references '.config/dcg/' path, which is the DCG safety floor config (floor-weakening write; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi

          # Pattern 2: Workspace DCG config write — any path ending in .dcg.toml
          if echo "$mux_hook_cmd" | grep -qE '\.dcg\.toml'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${mux_hook_name}' references '.dcg.toml', which is the workspace DCG config (floor-weakening write; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi

          # Pattern 3: PATH manipulation — hook sets PATH= which can shadow safety binaries.
          # Legitimate multiplexer hooks (start, attach, exec) do not need PATH overrides;
          # any PATH= in a hook command is a floor-weakening signal (static reject).
          if echo "$mux_hook_cmd" | grep -qE 'PATH='; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${mux_hook_name}' sets PATH=, which can PATH-shadow safety binaries (dcg, dcg-policy, block-ssh-bypass) and weakens the safety floor (floor-weakening; ADR-005 D10/D11, ADR-001 fail-loud). Remove PATH manipulation from hook commands." >&2
            return 1
          fi

          # Pattern 3b: Direct write to safety binary paths — all in-image locations.
          # Covers /usr/local/lib/rip-cage/bin/dcg-guard (the policy-enforcing wrapper),
          # /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh (ssh-bypass blocker),
          # and the /usr/local/bin / /usr/bin paths for dcg, dcg-policy, block-ssh-bypass.
          if echo "$mux_hook_cmd" | grep -qE '/(usr/local/lib/rip-cage/(bin|hooks)|usr/local/bin|usr/bin)/(dcg-guard|dcg|dcg-policy|block-ssh-bypass(\.sh)?)'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${mux_hook_name}' writes to a safety binary path (/usr/local/lib/rip-cage/bin/dcg-guard or similar), which would replace a safety floor binary (floor-weakening; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi

          # Pattern 4: Lifecycle-interceptor registration (M7, Finding 2).
          # A multiplexer hook must NOT modify the Claude Code settings file or reference
          # lifecycle hook registration keys. These strings have no legitimate place in a
          # multiplexer start/attach hook; any reference is a floor-weakening signal.
          # Matches: /etc/rip-cage/ (settings dir), settings.json (the lifecycle config),
          # PreToolUse, PostToolUse (the hook-registration keys in the settings schema).
          if echo "$mux_hook_cmd" | grep -qE '/etc/rip-cage/|settings\.json|PreToolUse|PostToolUse'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${mux_hook_name}' references lifecycle-interceptor targets (/etc/rip-cage/, settings.json, PreToolUse, or PostToolUse), which can register hooks that weaken the safety floor (floor-weakening lifecycle-interceptor; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi
        done
        ;;
      MEDIATOR)
        # MEDIATOR archetype: co-located proxy hook contract (ADR-026 D5, rip-cage-ta1o.5.1).
        # Isomorphic to MULTIPLEXER but for the egress-mediator seam.
        # Required: hooks.start (launch the proxy at cage init)
        # Optional: hooks.health_check, hooks.teardown
        # Required: run_as_uid (dedicated non-root uid for co-located-process topology)
        # Strict-parse: unknown top-level fields rejected (ADR-025 D5).
        # Hook-bounds check: reuses the same floor-weakening patterns as MULTIPLEXER.

        # Name format check: MEDIATOR names are used as directory components under
        # /etc/rip-cage/mediators/<name>/ in the image. Only [a-z0-9_-] is safe.
        if [[ ! "$name" =~ ^[a-z0-9_-]+$ ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): MEDIATOR name '${name}' contains characters outside [a-z0-9_-] — names are used as directory components in the image registry (/etc/rip-cage/mediators/<name>) and must be lowercase alphanumeric, hyphens, or underscores only (ADR-001 fail-loud; name-format check)." >&2
          return 1
        fi

        # Strict-parse: reject unknown/extra top-level fields on MEDIATOR entries.
        # Known fields: name, archetype, version_pin, run_as_uid, hooks, ca_cert_path
        # ca_cert_path (optional): path inside the container to the mediator's generated CA cert.
        # When present, init-mediator.sh installs it into the system trust store so the
        # in-cage agent curl can verify the MITM cert. (rip-cage-ta1o.5.8)
        local med_known_fields med_entry_keys med_unknown_key
        med_known_fields="name archetype version_pin run_as_uid hooks ca_cert_path"
        med_entry_keys=$(jq -r 'keys[]' <<<"$entry" 2>/dev/null)
        while IFS= read -r med_unknown_key; do
          [[ -z "$med_unknown_key" ]] && continue
          local med_is_known=0
          local med_known_chk
          for med_known_chk in $med_known_fields; do
            if [[ "$med_unknown_key" == "$med_known_chk" ]]; then
              med_is_known=1
              break
            fi
          done
          if [[ "$med_is_known" -eq 0 ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): MEDIATOR entry has unknown field '${med_unknown_key}' (strict-parse — only name/archetype/version_pin/run_as_uid/hooks/ca_cert_path are allowed; ADR-025 D5)." >&2
            return 1
          fi
        done <<<"$med_entry_keys"

        # 'run_as_uid' is required (co-located-process topology, ADR-026 D5).
        # The start hook must support launching the mediator under a dedicated non-root uid.
        local med_run_as_uid
        med_run_as_uid=$(jq -r '.run_as_uid // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        if [[ "$med_run_as_uid" == "___RC_ABSENT___" || -z "$med_run_as_uid" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'run_as_uid' is missing (MEDIATOR archetype — the mediator must run under a dedicated non-root uid for loop prevention; ADR-026 D5)." >&2
          return 1
        fi

        # 'hooks' block is required
        local med_hooks_type
        med_hooks_type=$(jq -r 'if has("hooks") then (.hooks | type) else "absent" end' <<<"$entry" 2>/dev/null)
        if [[ "$med_hooks_type" == "absent" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'hooks' is missing (MEDIATOR archetype)." >&2
          return 1
        fi
        if [[ "$med_hooks_type" != "object" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'hooks' must be an object, got: ${med_hooks_type} (MEDIATOR archetype)." >&2
          return 1
        fi

        # Required hook: start
        local med_start
        med_start=$(jq -r '.hooks.start // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        if [[ "$med_start" == "___RC_ABSENT___" || -z "$med_start" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): required field 'hooks.start' is missing (MEDIATOR archetype — start hook is required to launch the mediator at cage init)." >&2
          return 1
        fi

        # Optional hooks: health_check, teardown (absent = no-op / generic fallback)
        local med_health_check med_teardown
        med_health_check=$(jq -r '.hooks.health_check // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
        med_teardown=$(jq -r '.hooks.teardown // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)

        # Strict-parse: reject unknown keys INSIDE the hooks object (ADR-025 D5).
        # Known hook sub-keys: start, health_check, teardown.
        local med_known_hooks med_hooks_keys med_hook_key
        med_known_hooks="start health_check teardown"
        med_hooks_keys=$(jq -r '.hooks | keys[]' <<<"$entry" 2>/dev/null)
        while IFS= read -r med_hook_key; do
          [[ -z "$med_hook_key" ]] && continue
          local med_hook_is_known=0
          local med_known_hook_chk
          for med_known_hook_chk in $med_known_hooks; do
            if [[ "$med_hook_key" == "$med_known_hook_chk" ]]; then
              med_hook_is_known=1
              break
            fi
          done
          if [[ "$med_hook_is_known" -eq 0 ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): MEDIATOR entry has unknown hook key '${med_hook_key}' inside 'hooks' (strict-parse — only start/health_check/teardown are allowed; ADR-025 D5, ADR-026 D5)." >&2
            return 1
          fi
        done <<<"$med_hooks_keys"

        # Hook-bounds check (ADR-005 D10/D11, ADR-001 fail-loud).
        # Reuses the same floor-weakening patterns as MULTIPLEXER hooks.
        # Each hook command string is STATICALLY parsed (NEVER executed).
        local med_hook_name med_hook_cmd
        for med_hook_name in start health_check teardown; do
          case "$med_hook_name" in
            start)        med_hook_cmd="$med_start" ;;
            health_check) med_hook_cmd="$med_health_check" ;;
            teardown)     med_hook_cmd="$med_teardown" ;;
          esac
          [[ "$med_hook_cmd" == "___RC_ABSENT___" || -z "$med_hook_cmd" ]] && continue

          # Pattern 1: DCG global config write
          if echo "$med_hook_cmd" | grep -qE '\.config/dcg/'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${med_hook_name}' references '.config/dcg/' path, which is the DCG safety floor config (floor-weakening write; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi

          # Pattern 2: Workspace DCG config write
          if echo "$med_hook_cmd" | grep -qE '\.dcg\.toml'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${med_hook_name}' references '.dcg.toml', which is the workspace DCG config (floor-weakening write; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi

          # Pattern 3: PATH manipulation
          if echo "$med_hook_cmd" | grep -qE 'PATH='; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${med_hook_name}' sets PATH=, which can PATH-shadow safety binaries and weakens the safety floor (floor-weakening; ADR-005 D10/D11, ADR-001 fail-loud). Remove PATH manipulation from hook commands." >&2
            return 1
          fi

          # Pattern 3b: Direct write to safety binary paths
          if echo "$med_hook_cmd" | grep -qE '/(usr/local/lib/rip-cage/(bin|hooks)|usr/local/bin|usr/bin)/(dcg-guard|dcg|dcg-policy|block-ssh-bypass(\.sh)?)'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${med_hook_name}' writes to a safety binary path, which would replace a safety floor binary (floor-weakening; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi

          # Pattern 4: Lifecycle-interceptor registration
          if echo "$med_hook_cmd" | grep -qE '/etc/rip-cage/|settings\.json|PreToolUse|PostToolUse'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${med_hook_name}' references lifecycle-interceptor targets (/etc/rip-cage/, settings.json, PreToolUse, or PostToolUse), which can register hooks that weaken the safety floor (floor-weakening lifecycle-interceptor; ADR-005 D10/D11, ADR-001 fail-loud). Remove this from the hook command." >&2
            return 1
          fi

          # Pattern 5: Egress kill-switch disable (MEDIATOR-specific, ADR-026 D5).
          # RIP_CAGE_EGRESS=off (or any value) in a hook would disable the entire L7
          # egress enforcement stack — the floor the mediator sits behind. A push-side
          # mediator hook MUST NOT touch the kill-switch (floor-uncrossable, ADR-026 D5).
          # Static check: any RIP_CAGE_EGRESS= assignment in a hook command is rejected.
          if echo "$med_hook_cmd" | grep -qE 'RIP_CAGE_EGRESS='; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${med_hook_name}' sets RIP_CAGE_EGRESS=, which disables the egress enforcement stack and weakens the safety floor (floor-weakening egress kill-switch; ADR-026 D5, ADR-001 fail-loud). Remove RIP_CAGE_EGRESS manipulation from hook commands." >&2
            return 1
          fi

          # Pattern 6: iptables/ip6tables/nft manipulation (MEDIATOR-specific, ADR-026 D5).
          # iptables, ip6tables, and nft can disable the REDIRECT rule that force-routes
          # all traffic through the egress router — a hook using these tools can silently
          # strip the force-through floor. A push-side mediator hook MUST NOT manipulate
          # the firewall rules it depends on (floor-uncrossable, ADR-026 D5).
          # Static check: any reference to iptables/ip6tables/nft as a command is rejected.
          # Boundary class includes '/' so a full-path invocation (e.g. /sbin/iptables -F)
          # is also caught, not just the bare command word.
          if echo "$med_hook_cmd" | grep -qE '(^|[[:space:];|&/])(iptables|ip6tables|nft)([[:space:]]|$)'; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): hook-bounds violation — hook '${med_hook_name}' references iptables/ip6tables/nft, which can disable the force-through REDIRECT rule and weaken the safety floor (floor-weakening firewall manipulation; ADR-026 D5, ADR-001 fail-loud). Remove firewall manipulation from hook commands." >&2
            return 1
          fi
        done
        ;;
    esac

    # ---------------------------------------------------------------------------
    # Cross-cutting: validate 'required' + 'assert_loaded' fields (rip-cage-m8zc).
    # These fields may appear on ANY archetype; all REJECT rules live here.
    # Truth table (all cells fail-closed per locked-design v3):
    #   required:true + assert_loaded:"cmd"       → ACCEPT (bake <id> b64(cmd))
    #   required:true + no assert_loaded + path   → ACCEPT (codegen synthesizes test -x <path>)
    #   required:true + assert_loaded empty/ws    → REJECT (never bash -c ""; F5 fail-open closed)
    #   required:true + no assert_loaded + no path → REJECT (must be checkable)
    #   assert_loaded present + required absent   → REJECT (a check that would never fire is a footgun)
    #   required:false (with or without path)     → ACCEPT (INFO-skip; explicit false is a valid optional tool)
    #   neither field                             → ACCEPT (INFO-skip; normal optional tool)
    # ---------------------------------------------------------------------------
    local req_raw al_raw req_val
    req_raw=$(jq -r 'if has("required") then (.required | tostring) else "___RC_ABSENT___" end' <<<"$entry" 2>/dev/null)
    al_raw=$(jq -r '.assert_loaded // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)

    # Detect presence of assert_loaded without required (footgun → REJECT).
    if [[ "$al_raw" != "___RC_ABSENT___" ]]; then
      # assert_loaded is present — required must also be set and true.
      if [[ "$req_raw" == "___RC_ABSENT___" || "$req_raw" == "false" ]]; then
        echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'assert_loaded' requires 'required: true' — a check command that would never fire is a footgun (truth-table REJECT; rip-cage-m8zc)." >&2
        return 1
      fi
    fi

    # If required is present and truthy, validate the full truth table.
    if [[ "$req_raw" != "___RC_ABSENT___" && "$req_raw" != "false" ]]; then
      req_val=$(jq -r 'if has("required") then (.required | type) else "absent" end' <<<"$entry" 2>/dev/null)
      if [[ "$req_val" != "boolean" ]]; then
        echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'required' must be a boolean (got type '${req_val}'; rip-cage-m8zc)." >&2
        return 1
      fi
      # required:true is confirmed (req_raw == "true"). Check assert_loaded.
      if [[ "$al_raw" == "___RC_ABSENT___" || "$al_raw" == "null" ]]; then
        # No assert_loaded — fall through to codegen synthesize from path.
        # For TOOL archetype, binary_path or build_source.output_path must be present.
        # For other archetypes without a path-declaration, REJECT.
        if [[ "$archetype" == "TOOL" ]]; then
          # Check: does the entry have binary_path or build_source.output_path?
          local has_binary_path has_output_path
          has_binary_path=$(jq -r 'if has("binary_path") then "yes" else "no" end' <<<"$entry" 2>/dev/null)
          has_output_path=$(jq -r 'if (.build_source // {}) | has("output_path") then "yes" else "no" end' <<<"$entry" 2>/dev/null)
          if [[ "$has_binary_path" != "yes" && "$has_output_path" != "yes" ]]; then
            echo "Error: manifest '${file}' tools[${idx}] ('${name}'): 'required: true' but no 'assert_loaded' and no declarable path (binary_path or build_source.output_path) — a required tool must be presence-checkable or carry assert_loaded (truth-table REJECT; rip-cage-m8zc)." >&2
            return 1
          fi
        else
          # Non-TOOL archetype with required:true but no assert_loaded → REJECT.
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): 'required: true' on archetype '${archetype}' requires 'assert_loaded' (non-TOOL archetypes have no declarable binary path; truth-table REJECT; rip-cage-m8zc)." >&2
          return 1
        fi
      else
        # assert_loaded is present — reject empty/whitespace (never bash -c "").
        local al_trimmed
        al_trimmed=$(printf '%s' "$al_raw" | tr -d '[:space:]')
        if [[ -z "$al_trimmed" ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'assert_loaded' is present but empty/whitespace — an empty check is never run as bash -c \"\" (truth-table REJECT; rip-cage-m8zc)." >&2
          return 1
        fi
        # assert_loaded must be a single line (newlines inject arbitrary Dockerfile directives).
        if [[ "$al_raw" == *$'\n'* ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): field 'assert_loaded' must be a single-line shell command (newlines inject arbitrary Dockerfile directives; single-line-required; rip-cage-m8zc)." >&2
          return 1
        fi
        # Entry-id (name) must be space-free (the baked line format is space-delimited).
        if [[ "$name" == *' '* ]]; then
          echo "Error: manifest '${file}' tools[${idx}] ('${name}'): tool 'name' must be space-free when 'required: true' is set (the baked asserted-file is space-delimited; a space in name corrupts the line parser; rip-cage-m8zc)." >&2
          return 1
        fi
      fi
      # Space-free name check for synthesized path case too.
      if [[ "$name" == *' '* ]]; then
        echo "Error: manifest '${file}' tools[${idx}] ('${name}'): tool 'name' must be space-free when 'required: true' is set (the baked asserted-file is space-delimited; rip-cage-m8zc)." >&2
        return 1
      fi
    fi

  done

  return 0
}


# _manifest_load
# Load and validate the host-side tool manifest. Returns JSON on stdout.
# If the manifest is absent or empty, emits the default manifest as JSON.
# On validation failure, exits non-zero with a field-naming error on stderr.
# Does NOT fall back to "ignore bad entries" — fail-closed (ADR-001).
#
# Host-only: this function runs on the host process only.  The agent-inaccessible
# invariant (ADR-005 D7 FIRM, ADR-024 D1) is enforced by rc running host-side
# (not copied into the image; RC_MANIFEST_GLOBAL / XDG_CONFIG_HOME are not
# forwarded into the container), NOT by the path being unconditionally fixed.
_manifest_load() {
  local manifest_path
  manifest_path=$(_manifest_global_path)

  # Absent or empty manifest → return the default stack (D8 regression contract).
  if [[ ! -f "$manifest_path" || ! -s "$manifest_path" ]]; then
    local default_json
    if ! default_json=$(yq -o=json '.' <(  _manifest_default_yaml) 2>/dev/null); then
      echo "Error: failed to parse internal default manifest." >&2
      return 1
    fi
    echo "$default_json"
    return 0
  fi

  # Validate the manifest strictly before exposing any content.
  if ! _manifest_validate "$manifest_path"; then
    return 1
  fi

  # Parse + emit as JSON.
  local json
  if ! json=$(yq -o=json '.' "$manifest_path" 2>/dev/null); then
    echo "Error: manifest '${manifest_path}' failed to parse as YAML." >&2
    return 1
  fi

  # Empty/null manifest after YAML parse (e.g. file with only comments)
  # → return defaults (D8).
  if [[ -z "$json" || "$json" == "null" ]]; then
    local default_json
    if ! default_json=$(yq -o=json '.' <(_manifest_default_yaml) 2>/dev/null); then
      echo "Error: failed to parse internal default manifest." >&2
      return 1
    fi
    echo "$default_json"
    return 0
  fi

  echo "$json"
}


# _manifest_generate_extra_dockerfile_steps
# Read the host manifest and emit Dockerfile RUN instructions for every TOOL
# entry that carries an `install_cmd` field (non-bundled tools).  Entries with
# `version_pin: "bundled"` and no `install_cmd` are baked by the existing
# Dockerfile stages — no RUN step is generated for them.
#
# This is the mechanism that lets rc build add arbitrary tool binaries to the
# image from the manifest (ADR-005 D1 FIRM: install = build-time).
#
# D8 byte-for-byte contract: when the default manifest is in effect (all tools
# have version_pin "bundled" / no install_cmd), this function emits NOTHING.
# rc build then uses the original Dockerfile unchanged — the build is
# bit-for-bit identical to the pre-manifest image.
#
# D4 reconciliation (ADR-005 D4 FIRM --with flags): the manifest IS the
# build-time tool-selection surface.  Per-cage --with/--only/--skip selection
# is DEFERRED (Open-decision 8); it will layer on top of this mechanism later.
# This function does not implement selection.
#
# Mechanism choice (recorded for siblings):
#   rc build appends extra RUN steps to a temp copy of the Dockerfile when
#   non-bundled tools are present.  The original Dockerfile is NEVER modified.
#   For the default (bundled-only) manifest this function outputs nothing and
#   rc build uses the original Dockerfile directly — satisfying D8.
#
# Output: zero or more lines of the form:
#   RUN <install_cmd>
# one per non-bundled entry that has an install_cmd field. There is NO
# archetype filter: SHELL-INTEGRATION and IN-CAGE-DAEMON entries may carry
# install_cmd for their binary baking and are consumed identically to TOOL
# entries — which is why _manifest_validate enforces the install_cmd
# single-line rule in all three of those cases, not just TOOL
# (rip-cage-62a9). MULTIPLEXER/MEDIATOR strict-parse reject install_cmd.
# build_source (also consumed here, branch below) is validated across every
# consumed archetype (TOOL, SHELL-INTEGRATION, IN-CAGE-DAEMON) by the shared
# _manifest_check_build_source_subfields helper (rip-cage-m0hh).
_manifest_generate_extra_dockerfile_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  # Walk TOOL-archetype entries that have a non-empty install_cmd field OR a build_source.
  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local steps=""
  for (( idx=0; idx<count; idx++ )); do
    local entry archetype install_cmd build_source_present
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    install_cmd=$(jq -r '.install_cmd // ""' <<<"$entry" 2>/dev/null)
    build_source_present=$(jq -r 'if has("build_source") and (.build_source | type) == "object" then "yes" else "no" end' <<<"$entry" 2>/dev/null)

    local name
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    if [[ "$build_source_present" == "yes" ]]; then
      # From-source path (rip-cage-buuo.2): emit a COPY --from the isolated builder stage
      # into the runtime stage.  The builder stage itself is emitted by
      # _manifest_generate_source_builder_stages and injected before the runtime FROM.
      local bs_output_path bs_runtime_dest stage_name
      bs_output_path=$(jq -r '.build_source.output_path // ""' <<<"$entry" 2>/dev/null)
      # Derive runtime destination: same as output_path (basename in /usr/local/bin).
      bs_runtime_dest="/usr/local/bin/$(basename "${bs_output_path}")"
      # Stage name must be safe for Docker AS label: lowercase alphanumeric + hyphens.
      stage_name="rc-builder-$(echo "${name}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')"
      steps+="# manifest from-source TOOL: ${name} (copy artifact from isolated builder stage)"$'\n'
      steps+="COPY --from=${stage_name} ${bs_output_path} ${bs_runtime_dest}"$'\n'
    elif [[ -n "$install_cmd" ]]; then
      # Defense-in-depth: install_cmd is validated single-line at load time
      # (_manifest_validate, all consumed archetypes) — re-check here at the
      # generation site, mirroring the shell_init guard in
      # _manifest_generate_shell_init_zshrc_steps (rip-cage-62a9).
      if [[ "$install_cmd" == *$'\n'* ]]; then
        echo "Error: manifest entry '${name}' (${archetype}): field 'install_cmd' must be a single line (newlines inject arbitrary Dockerfile directives; single-line-required)." >&2
        return 1
      fi
      # Prebuilt install path: emit a RUN apt-get / install step in the runtime stage.
      steps+="RUN # manifest TOOL: ${name} (${archetype})"$'\n'
      steps+="RUN apt-get update && ${install_cmd} && rm -rf /var/lib/apt/lists/*"$'\n'
    fi
    # Entries with no install_cmd and no build_source are bundled; skip.
  done

  # Strip trailing newline for clean output; caller appends to Dockerfile.
  if [[ -n "$steps" ]]; then
    printf '%s' "${steps%$'\n'}"
  fi
}


# _manifest_generate_source_builder_stages
# Read the host manifest and emit Dockerfile FROM ... AS rc-builder-<name> stages
# for every TOOL entry that carries a build_source field (from-source build path).
# Each stage: FROM <builder_image> AS rc-builder-<name>
#             COPY <build_script> /rc-build/build.sh
#             RUN sh /rc-build/build.sh
#
# These stages are prepended before the runtime FROM (Stage 4) so the build
# toolchain stays in an isolated layer and is NOT copied into the runtime image.
#
# Arch-adaptive by construction: the stage targets the BUILD platform (no
# --platform or --target flags), so arm64 and amd64 each produce a native binary
# (ADR-005 D6/D11, rip-cage-buuo.2 acceptance criterion).
#
# D8 byte-for-byte contract: when the manifest has no from-source entries, this
# function emits NOTHING — rc build uses the original Dockerfile unchanged.
#
# Output: zero or more multi-line Dockerfile stage blocks, one per from-source entry.
_manifest_generate_source_builder_stages() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local stages=""
  for (( idx=0; idx<count; idx++ )); do
    local entry build_source_present
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    build_source_present=$(jq -r 'if has("build_source") and (.build_source | type) == "object" then "yes" else "no" end' <<<"$entry" 2>/dev/null)
    if [[ "$build_source_present" != "yes" ]]; then
      continue
    fi

    local name bs_builder_image bs_build_script stage_name
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)
    bs_builder_image=$(jq -r '.build_source.builder_image // ""' <<<"$entry" 2>/dev/null)
    bs_build_script=$(jq -r '.build_source.build_script // ""' <<<"$entry" 2>/dev/null)

    if [[ -z "$bs_builder_image" || -z "$bs_build_script" ]]; then
      echo "Error: manifest from-source TOOL '${name}': build_source.builder_image or build_source.build_script is empty." >&2
      return 1
    fi

    # Stage name: lowercase alphanumeric + hyphens, no trailing hyphen.
    stage_name="rc-builder-$(echo "${name}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-$//')"

    # Emit the isolated builder stage.
    # The build script is COPY'd in; rip-cage does not interpret its contents.
    # No host mount in this stage — pure Dockerfile isolation (ADR-002).
    stages+="# manifest from-source builder stage: ${name} (rip-cage-buuo.2)"$'\n'
    stages+="FROM ${bs_builder_image} AS ${stage_name}"$'\n'
    stages+="COPY ${bs_build_script} /rc-build/build.sh"$'\n'
    stages+="RUN sh /rc-build/build.sh"$'\n'
  done

  if [[ -n "$stages" ]]; then
    printf '%s' "${stages%$'\n'}"
  fi
}


# _manifest_generate_launch_args
# Read the host manifest and collect all launch_args across TOOL entries in
# fragment order (tools[] array order), outputting one arg per line.
#
# This is the assembly step for ADR-027 D4: recipes declare their launch-flag
# contributions in the manifest, and rc build concatenates them in fragment
# order so the guard fragment's args (loaded first) precede extension args.
#
# The caller (rc build) uses the assembled args to bake the generic pi launch
# shim: exec <real-binary> <assembled-args> "$@".
#
# Fragment order is the composition tool (ADR-005 D12 agentic-composition):
#   guard fragment composed first → guard args first → guard loads before
#   any other extension. Non-floor ordering among other fragments is the
#   configuring agent's responsibility.
#
# Output: zero or more lines, one arg per line, in fragment order.
# Entries with no launch_args field contribute zero lines (correct: omitting
# the field = no launch contribution from that fragment).
#
# rip-cage-l72i.1 — manifest-declared launch_args assembly (ADR-027 D4 FLEXIBLE).
_manifest_generate_launch_args() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  for (( idx=0; idx<count; idx++ )); do
    local entry launch_args_present la_count la_i la_val
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    launch_args_present=$(jq -r 'if has("launch_args") then "yes" else "no" end' <<<"$entry" 2>/dev/null)
    if [[ "$launch_args_present" != "yes" ]]; then
      continue
    fi
    la_count=$(jq '.launch_args | length' <<<"$entry" 2>/dev/null)
    for (( la_i=0; la_i<la_count; la_i++ )); do
      la_val=$(jq -r ".launch_args[${la_i}]" <<<"$entry" 2>/dev/null)
      printf '%s\n' "$la_val"
    done
  done
}


# _manifest_generate_pi_shim_steps <wrapper_template_path>
# Generates the Dockerfile RUN step that bakes the generic pi launch wrapper at
# /usr/local/bin/pi (root:root 0755) with ASSEMBLED_ARGS populated from all
# launch_args declared across composed fragments in fragment order.
#
# The wrapper template file is read (pi-wrapper.sh), the ASSEMBLED_ARGS=()
# placeholder is replaced with the assembled args, the result is base64-encoded,
# and a single RUN step is emitted.
#
# This function is generic: it names no recipe. It bakes whatever launch_args the
# composed fragments declared. Guard args appear first when the guard fragment is
# composed first (fragment order is the agent's composition tool, per ADR-005 D12).
#
# When no launch_args are declared across any fragment, ASSEMBLED_ARGS stays (),
# which means pi auto-discovers its extensions (correct for no-guard compositions).
#
# This generator ALWAYS emits a step when invoked (the direct-call test contract).
# The DECISION of whether to bake the shim at all lives in the caller
# (_manifest_build_dockerfile_path), which only invokes this generator when at least
# one composed fragment declares launch_args — so a no-launch_args manifest keeps the
# original Dockerfile unchanged (ADR-005 D8 invariant).
#
# rip-cage-l72i.1 — ADR-027 D4 FLEXIBLE + ADR-005 D12
_manifest_generate_pi_shim_steps() {
  local wrapper_template="${1:-}"
  if [[ -z "$wrapper_template" || ! -f "$wrapper_template" ]]; then
    echo "rip-cage: _manifest_generate_pi_shim_steps: wrapper template not found: ${wrapper_template}" >&2
    return 1
  fi

  # Collect assembled args (one per line from _manifest_generate_launch_args)
  local raw_args
  raw_args=$(_manifest_generate_launch_args 2>/dev/null) || true

  # Build the ASSEMBLED_ARGS=(...) literal from the args
  # Each arg is single-quoted with ' -> '\'' escaping for safety
  local assembled_literal="ASSEMBLED_ARGS=("
  if [[ -n "$raw_args" ]]; then
    local _arg_line
    while IFS= read -r _arg_line; do
      # Single-quote each arg: replace ' with '\''
      local _quoted
      _quoted="'${_arg_line//"'"/"'\\''"}'"
      assembled_literal+="${_quoted} "
    done <<<"$raw_args"
    # Trim trailing space
    assembled_literal="${assembled_literal% }"
  fi
  assembled_literal+=")"

  # Read the template and substitute the ASSEMBLED_ARGS=() placeholder
  local wrapper_content
  wrapper_content=$(< "$wrapper_template")
  # Replace the ASSEMBLED_ARGS=() line with the assembled literal
  local assembled_wrapper
  assembled_wrapper="${wrapper_content/ASSEMBLED_ARGS=()/$assembled_literal}"

  # Base64-encode (single line, no wraps)
  local b64_wrapper
  b64_wrapper=$(printf '%s' "$assembled_wrapper" | base64 | tr -d '\n')

  # Emit the Dockerfile RUN step
  printf 'RUN echo %s | base64 -d > /usr/local/bin/pi && chown root:root /usr/local/bin/pi && chmod 0755 /usr/local/bin/pi\n' \
    "'${b64_wrapper}'"
}


# _manifest_build_dockerfile_path
# Returns the path to the Dockerfile that rc build should use.
# If the manifest has non-bundled tools (extra steps to add), writes a temp
# Dockerfile that includes the original plus the extra RUN steps, and prints
# its path.  If all tools are bundled, prints the original Dockerfile path.
# The caller is responsible for cleaning up any temp file created.
#
# Injection points:
#   0. From-source builder stages (source_builder_stages)
#      → BEFORE the "# Stage 4: Runtime" sentinel (before FROM debian:trixie).
#      These are isolated builder stages that keep build toolchains OUT of the
#      runtime image (ADR-002 multi-stage; rip-cage-buuo.2 D6/D11).
#   1. TOOL install steps (extra_steps: apt-get / binary installs; also COPY --from
#      for from-source tools) → before "# Non-root user" (root context; no /etc/rip-cage
#      dependency).
#   2. IN-CAGE-DAEMON config bake + MCP fragment merge (daemon_config_steps + daemon_mcp_steps)
#      → after "COPY cage/agent/settings.json /etc/rip-cage/settings.json" (still root context,
#        but MUST be after /etc/rip-cage is created at Dockerfile:113 and settings.json
#        is COPY'd at Dockerfile:133; writing to /etc/rip-cage/ before mkdir-p fails with
#        "Directory nonexistent" — rip-cage-4c5.9 fix).
#   3. SHELL-INTEGRATION shell_init steps → after "COPY --chown=agent:agent cage/agent/zshrc /home/agent/.zshrc"
#      (USER agent context; appends to the agent-owned .zshrc)
_manifest_build_dockerfile_path() {
  local orig_dockerfile="${1:-${SCRIPT_DIR}/cage/Dockerfile}"

  local extra_steps
  if ! extra_steps=$(_manifest_generate_extra_dockerfile_steps); then
    return 1
  fi

  local source_builder_stages
  if ! source_builder_stages=$(_manifest_generate_source_builder_stages); then
    return 1
  fi

  local shell_init_steps
  if ! shell_init_steps=$(_manifest_generate_shell_init_zshrc_steps); then
    return 1
  fi

  local daemon_config_steps
  if ! daemon_config_steps=$(_manifest_generate_daemon_config_dockerfile_steps); then
    return 1
  fi

  local daemon_mcp_steps
  if ! daemon_mcp_steps=$(_manifest_generate_daemon_mcp_dockerfile_steps); then
    return 1
  fi

  local tool_init_config_steps
  if ! tool_init_config_steps=$(_manifest_generate_tool_init_config_dockerfile_steps); then
    return 1
  fi

  local mux_registry_steps
  if ! mux_registry_steps=$(_manifest_generate_multiplexer_registry_steps); then
    return 1
  fi

  local mux_label
  if ! mux_label=$(_manifest_generate_multiplexer_label); then
    return 1
  fi

  local mediator_registry_steps
  if ! mediator_registry_steps=$(_manifest_generate_mediator_registry_steps); then
    return 1
  fi

  local mediator_label
  if ! mediator_label=$(_manifest_generate_mediator_label); then
    return 1
  fi

  local safety_stack_asserted_steps
  if ! safety_stack_asserted_steps=$(_manifest_generate_safety_stack_asserted_steps); then
    return 1
  fi

  # Pi launch shim: bake /usr/local/bin/pi ONLY when at least one composed fragment
  # declares launch_args. launch_args is the generic, tool-agnostic signal that this
  # manifest composes a pi launch contribution (ADR-005 D12 — rc names no tool/recipe).
  # Consequences of the gate:
  #   - floor-only / non-pi (SHELL/DAEMON/cross) manifests declare no launch_args, so
  #     the original Dockerfile is returned unchanged (ADR-005 D8 byte-for-byte invariant).
  #   - a no-guard pi recipe declares no launch_args, so no shim is baked — pi runs from
  #     /usr/bin/pi with auto-discovery, which IS the no-guard semantics.
  #   - the default published manifest's dcg fragment declares the guard launch_args, so
  #     the shim bakes and the guard loads first.
  # (rip-cage-l72i.1 — ADR-027 D4 FLEXIBLE; D8-invariant fix v0.10.0)
  local pi_shim_steps=""
  local pi_launch_args
  pi_launch_args=$(_manifest_generate_launch_args 2>/dev/null) || true
  if [[ -n "$pi_launch_args" ]]; then
    local pi_wrapper_template="${SCRIPT_DIR}/examples/pi/pi-wrapper.sh"
    if [[ -f "$pi_wrapper_template" ]]; then
      if ! pi_shim_steps=$(_manifest_generate_pi_shim_steps "$pi_wrapper_template"); then
        return 1
      fi
    else
      # launch_args declared (a guard wants to load) but the wrapper template is
      # missing — we cannot bake the shim that carries the guard. Fail loud rather
      # than silently building an unguarded image (ADR-001 D1 fail-closed).
      echo "rip-cage: pi launch_args declared but wrapper template missing: ${pi_wrapper_template}" >&2
      return 1
    fi
  fi

  if [[ -z "$extra_steps" && -z "$source_builder_stages" && -z "$shell_init_steps" && -z "$daemon_config_steps" && -z "$daemon_mcp_steps" && -z "$tool_init_config_steps" && -z "$mux_registry_steps" && -z "$mux_label" && -z "$mediator_registry_steps" && -z "$mediator_label" && -z "$safety_stack_asserted_steps" && -z "$pi_shim_steps" ]]; then
    # Default/bundled-only manifest — use the original Dockerfile unchanged (D8).
    echo "$orig_dockerfile"
    return 0
  fi

  # Non-bundled tools and/or SHELL-INTEGRATION/IN-CAGE-DAEMON/MULTIPLEXER/MEDIATOR entries present — generate a temp Dockerfile.
  local tmp_dockerfile
  tmp_dockerfile=$(mktemp "${TMPDIR:-/tmp}/rip-cage-Dockerfile-XXXXXX")

  # Start with the original Dockerfile; we'll build it up in sections.
  cp "$orig_dockerfile" "$tmp_dockerfile"

  # --- From-source builder stages: inject BEFORE "# Stage 4: Runtime" sentinel ---
  # These are isolated FROM ... AS rc-builder-<name> stages. They must appear before
  # the runtime FROM so Docker multi-stage COPY --from can reference them.
  # The build toolchain stays in the builder layer and does NOT leak into runtime.
  if [[ -n "$source_builder_stages" ]]; then
    local sentinel_runtime="# Stage 4: Runtime"
    local tmp_inject_builders
    tmp_inject_builders=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated from-source builder stages (rip-cage-buuo.2) ---\n%s\n' "$source_builder_stages" > "$tmp_inject_builders"

    if grep -qF "$sentinel_runtime" "$tmp_dockerfile"; then
      local sentinel_line_runtime base_dockerfile_s
      sentinel_line_runtime=$(grep -nF "$sentinel_runtime" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_s=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "$((sentinel_line_runtime - 1))" "$tmp_dockerfile" > "$base_dockerfile_s"
      cat "$tmp_inject_builders" >> "$base_dockerfile_s"
      tail -n "+${sentinel_line_runtime}" "$tmp_dockerfile" >> "$base_dockerfile_s"
      mv "$base_dockerfile_s" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: '# Stage 4: Runtime' sentinel not found in Dockerfile — appending from-source builder stages before end of file. Dockerfile may need the sentinel restored." >&2
      cat "$tmp_inject_builders" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_builders"
  fi

  # --- TOOL install steps + pi shim: inject before "# Non-root user" sentinel ---
  # extra_steps includes: apt-get / binary installs (prebuilt path) and COPY --from
  # (from-source path). Both run as root in the runtime stage; no /etc/rip-cage dependency.
  # pi_shim_steps (rip-cage-l72i.1) also runs root — appended here so /usr/local/bin/pi
  # is always root-owned with the assembled ASSEMBLED_ARGS from composed launch_args.
  [[ -n "$pi_shim_steps" ]] && extra_steps+="${extra_steps:+$'\n'}${pi_shim_steps}"
  if [[ -n "$extra_steps" ]]; then
    local sentinel_tool="# Non-root user"
    local tmp_inject_root
    tmp_inject_root=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated tool install steps (rip-cage-4c5.2) ---\n%s\n' "$extra_steps" > "$tmp_inject_root"

    if grep -qF "$sentinel_tool" "$tmp_dockerfile"; then
      local sentinel_line_tool base_dockerfile
      sentinel_line_tool=$(grep -nF "$sentinel_tool" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "$((sentinel_line_tool - 1))" "$tmp_dockerfile" > "$base_dockerfile"
      cat "$tmp_inject_root" >> "$base_dockerfile"
      tail -n "+${sentinel_line_tool}" "$tmp_dockerfile" >> "$base_dockerfile"
      mv "$base_dockerfile" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: '# Non-root user' sentinel not found in Dockerfile — appending manifest tool install steps at end (they will run as USER agent and may fail). Dockerfile may need the sentinel restored." >&2
      cat "$tmp_inject_root" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_root"
  fi

  # --- IN-CAGE-DAEMON config bake + MCP merge: inject AFTER "COPY settings.json" sentinel ---
  # These steps write to /etc/rip-cage/daemon-config.json and patch /etc/rip-cage/settings.json.
  # /etc/rip-cage is created at Dockerfile:113 (mkdir -p) and settings.json is COPY'd at
  # Dockerfile:133 — both AFTER the "# Non-root user" sentinel at Dockerfile:101. Injecting
  # daemon steps before "# Non-root user" fails with "Directory nonexistent". Instead, inject
  # AFTER the settings.json COPY so both prereqs are satisfied, while still in root context
  # (USER agent only appears at Dockerfile:160 — rip-cage-4c5.9 fix).
  local daemon_root_steps=""
  [[ -n "$daemon_config_steps" ]] && daemon_root_steps+="${daemon_config_steps}"$'\n'
  [[ -n "$daemon_mcp_steps" ]] && daemon_root_steps+="${daemon_mcp_steps}"$'\n'
  daemon_root_steps="${daemon_root_steps%$'\n'}"

  if [[ -n "$daemon_root_steps" ]]; then
    local sentinel_settings="COPY cage/agent/settings.json /etc/rip-cage/settings.json"
    local tmp_inject_daemon
    tmp_inject_daemon=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated daemon config steps (rip-cage-4c5.5/.9) ---\n%s\n' "$daemon_root_steps" > "$tmp_inject_daemon"

    if grep -qF "$sentinel_settings" "$tmp_dockerfile"; then
      local sentinel_line_settings base_dockerfile_d
      sentinel_line_settings=$(grep -nF "$sentinel_settings" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_d=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_settings}" "$tmp_dockerfile" > "$base_dockerfile_d"
      cat "$tmp_inject_daemon" >> "$base_dockerfile_d"
      tail -n "+$((sentinel_line_settings + 1))" "$tmp_dockerfile" >> "$base_dockerfile_d"
      mv "$base_dockerfile_d" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: 'COPY settings.json' sentinel not found in Dockerfile — appending daemon config steps at end (may fail if /etc/rip-cage does not exist). Dockerfile may need the sentinel restored." >&2
      cat "$tmp_inject_daemon" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_daemon"
  fi

  # --- TOOL init-hook config bake: inject AFTER "COPY settings.json" sentinel ---
  # Same injection site as IN-CAGE-DAEMON config steps (root context; /etc/rip-cage
  # exists). Writes /etc/rip-cage/tool-init-config.json, read by init-rip-cage.sh
  # at boot to run each declared TOOL 'init' command in agent context
  # (rip-cage-p35a.2, ADR-005 D7).
  if [[ -n "$tool_init_config_steps" ]]; then
    local sentinel_settings_ti="COPY cage/agent/settings.json /etc/rip-cage/settings.json"
    local tmp_inject_ti
    tmp_inject_ti=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated TOOL init-hook config bake (rip-cage-p35a.2) ---\n%s\n' "$tool_init_config_steps" > "$tmp_inject_ti"

    if grep -qF "$sentinel_settings_ti" "$tmp_dockerfile"; then
      local sentinel_line_settings_ti base_dockerfile_ti
      sentinel_line_settings_ti=$(grep -nF "$sentinel_settings_ti" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_ti=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_settings_ti}" "$tmp_dockerfile" > "$base_dockerfile_ti"
      cat "$tmp_inject_ti" >> "$base_dockerfile_ti"
      tail -n "+$((sentinel_line_settings_ti + 1))" "$tmp_dockerfile" >> "$base_dockerfile_ti"
      mv "$base_dockerfile_ti" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: 'COPY settings.json' sentinel not found in Dockerfile — appending TOOL init-hook config bake steps at end (may fail if /etc/rip-cage does not exist). Dockerfile may need the sentinel restored." >&2
      cat "$tmp_inject_ti" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_ti"
  fi

  # --- SHELL-INTEGRATION shell_init steps: inject after "COPY zshrc" sentinel ---
  if [[ -n "$shell_init_steps" ]]; then
    local sentinel_zshrc="COPY --chown=agent:agent cage/agent/zshrc /home/agent/.zshrc"
    local tmp_inject_shell
    tmp_inject_shell=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated shell_init steps (rip-cage-4c5.4) ---\n%s\n' "$shell_init_steps" > "$tmp_inject_shell"

    if grep -qF "$sentinel_zshrc" "$tmp_dockerfile"; then
      local sentinel_line_zshrc base_dockerfile2
      sentinel_line_zshrc=$(grep -nF "$sentinel_zshrc" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile2=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_zshrc}" "$tmp_dockerfile" > "$base_dockerfile2"
      cat "$tmp_inject_shell" >> "$base_dockerfile2"
      tail -n "+$((sentinel_line_zshrc + 1))" "$tmp_dockerfile" >> "$base_dockerfile2"
      mv "$base_dockerfile2" "$tmp_dockerfile"
    else
      # Fallback: append at end (USER agent context should still be correct)
      echo "rip-cage: Warning: 'COPY zshrc' sentinel not found in Dockerfile — appending manifest shell_init steps at end." >&2
      cat "$tmp_inject_shell" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_shell"
  fi

  # --- MULTIPLEXER registry bake: inject AFTER "COPY settings.json" sentinel ---
  # Same injection site as IN-CAGE-DAEMON config steps (root context; /etc/rip-cage exists).
  # These steps create /etc/rip-cage/multiplexers/<name>/ and write one file per declared hook.
  if [[ -n "$mux_registry_steps" ]]; then
    local sentinel_settings_mux="COPY cage/agent/settings.json /etc/rip-cage/settings.json"
    local tmp_inject_mux
    tmp_inject_mux=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated MULTIPLEXER registry bake (rip-cage-61al.2) ---\n%s\n' "$mux_registry_steps" > "$tmp_inject_mux"

    if grep -qF "$sentinel_settings_mux" "$tmp_dockerfile"; then
      local sentinel_line_settings_mux base_dockerfile_mux
      sentinel_line_settings_mux=$(grep -nF "$sentinel_settings_mux" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_mux=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_settings_mux}" "$tmp_dockerfile" > "$base_dockerfile_mux"
      cat "$tmp_inject_mux" >> "$base_dockerfile_mux"
      tail -n "+$((sentinel_line_settings_mux + 1))" "$tmp_dockerfile" >> "$base_dockerfile_mux"
      mv "$base_dockerfile_mux" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: 'COPY settings.json' sentinel not found in Dockerfile — appending MULTIPLEXER registry bake steps at end (may fail if /etc/rip-cage does not exist). Dockerfile may need the sentinel restored." >&2
      cat "$tmp_inject_mux" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_mux"
  fi

  # --- MULTIPLEXER image label: inject AFTER existing LABEL line ---
  # The rc.multiplexers label is placed alongside the existing
  # org.opencontainers.image.version label so it is frozen in the image at build time.
  # B2 reads it host-side via `docker inspect` without re-reading the manifest.
  if [[ -n "$mux_label" ]]; then
    local sentinel_label="LABEL org.opencontainers.image.version"
    local tmp_inject_label
    tmp_inject_label=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# manifest-generated MULTIPLEXER registry label (rip-cage-61al.2)\n%s\n' "$mux_label" > "$tmp_inject_label"

    if grep -qF "$sentinel_label" "$tmp_dockerfile"; then
      local sentinel_line_label base_dockerfile_label
      sentinel_line_label=$(grep -nF "$sentinel_label" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_label=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_label}" "$tmp_dockerfile" > "$base_dockerfile_label"
      cat "$tmp_inject_label" >> "$base_dockerfile_label"
      tail -n "+$((sentinel_line_label + 1))" "$tmp_dockerfile" >> "$base_dockerfile_label"
      mv "$base_dockerfile_label" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: 'LABEL org.opencontainers.image.version' sentinel not found in Dockerfile — appending MULTIPLEXER label at end." >&2
      cat "$tmp_inject_label" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_label"
  fi

  # --- MEDIATOR registry bake: inject AFTER "COPY settings.json" sentinel ---
  # Same injection site as MULTIPLEXER registry steps (root context; /etc/rip-cage exists).
  # These steps create /etc/rip-cage/mediators/<name>/ and write one file per declared hook.
  if [[ -n "$mediator_registry_steps" ]]; then
    local sentinel_settings_med="COPY cage/agent/settings.json /etc/rip-cage/settings.json"
    local tmp_inject_med
    tmp_inject_med=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated MEDIATOR registry bake (rip-cage-ta1o.5.1) ---\n%s\n' "$mediator_registry_steps" > "$tmp_inject_med"

    if grep -qF "$sentinel_settings_med" "$tmp_dockerfile"; then
      local sentinel_line_settings_med base_dockerfile_med
      sentinel_line_settings_med=$(grep -nF "$sentinel_settings_med" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_med=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_settings_med}" "$tmp_dockerfile" > "$base_dockerfile_med"
      cat "$tmp_inject_med" >> "$base_dockerfile_med"
      tail -n "+$((sentinel_line_settings_med + 1))" "$tmp_dockerfile" >> "$base_dockerfile_med"
      mv "$base_dockerfile_med" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: 'COPY settings.json' sentinel not found in Dockerfile — appending MEDIATOR registry bake steps at end (may fail if /etc/rip-cage does not exist). Dockerfile may need the sentinel restored." >&2
      cat "$tmp_inject_med" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_med"
  fi

  # --- MEDIATOR image label: inject AFTER existing LABEL line ---
  # The rc.mediators label is placed alongside other image labels so it is
  # frozen in the image at build time (isomorphic to rc.multiplexers handling).
  if [[ -n "$mediator_label" ]]; then
    local sentinel_label_med="LABEL org.opencontainers.image.version"
    local tmp_inject_label_med
    tmp_inject_label_med=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# manifest-generated MEDIATOR registry label (rip-cage-ta1o.5.1)\n%s\n' "$mediator_label" > "$tmp_inject_label_med"

    if grep -qF "$sentinel_label_med" "$tmp_dockerfile"; then
      local sentinel_line_label_med base_dockerfile_label_med
      sentinel_line_label_med=$(grep -nF "$sentinel_label_med" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_label_med=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_label_med}" "$tmp_dockerfile" > "$base_dockerfile_label_med"
      cat "$tmp_inject_label_med" >> "$base_dockerfile_label_med"
      tail -n "+$((sentinel_line_label_med + 1))" "$tmp_dockerfile" >> "$base_dockerfile_label_med"
      mv "$base_dockerfile_label_med" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: 'LABEL org.opencontainers.image.version' sentinel not found in Dockerfile — appending MEDIATOR label at end." >&2
      cat "$tmp_inject_label_med" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_label_med"
  fi

  # --- required/assert_loaded safety-stack-asserted: inject AFTER "COPY settings.json" sentinel ---
  # Bakes /etc/rip-cage/safety-stack-asserted (one "<id> <b64check>" per line) root:root 0644
  # so in-cage rc test can run declared checks for required tools (rip-cage-m8zc).
  # Injection site: same as daemon/mux/mediator config steps (root context; /etc/rip-cage exists).
  # rc codegen copies check strings from manifest DATA — never interprets tool names (ADR-005 D12).
  if [[ -n "$safety_stack_asserted_steps" ]]; then
    local sentinel_settings_ssa="COPY cage/agent/settings.json /etc/rip-cage/settings.json"
    local tmp_inject_ssa
    tmp_inject_ssa=$(mktemp "${TMPDIR:-/tmp}/rip-cage-inject-XXXXXX")
    printf '\n# --- manifest-generated safety-stack-asserted bake (rip-cage-m8zc) ---\n%s\n' "$safety_stack_asserted_steps" > "$tmp_inject_ssa"

    if grep -qF "$sentinel_settings_ssa" "$tmp_dockerfile"; then
      local sentinel_line_ssa base_dockerfile_ssa
      sentinel_line_ssa=$(grep -nF "$sentinel_settings_ssa" "$tmp_dockerfile" | head -1 | cut -d: -f1)
      base_dockerfile_ssa=$(mktemp "${TMPDIR:-/tmp}/rip-cage-base-XXXXXX")
      head -n "${sentinel_line_ssa}" "$tmp_dockerfile" > "$base_dockerfile_ssa"
      cat "$tmp_inject_ssa" >> "$base_dockerfile_ssa"
      tail -n "+$((sentinel_line_ssa + 1))" "$tmp_dockerfile" >> "$base_dockerfile_ssa"
      mv "$base_dockerfile_ssa" "$tmp_dockerfile"
    else
      echo "rip-cage: Warning: 'COPY settings.json' sentinel not found in Dockerfile — appending safety-stack-asserted bake at end (may fail if /etc/rip-cage does not exist). Dockerfile may need the sentinel restored." >&2
      cat "$tmp_inject_ssa" >> "$tmp_dockerfile"
    fi
    rm -f "$tmp_inject_ssa"
  fi

  echo "$tmp_dockerfile"
}


# _manifest_generate_shell_init_zshrc_steps
# Read the host manifest and emit Dockerfile RUN instructions for every
# SHELL-INTEGRATION entry, appending its shell_init eval line to
# /home/agent/.zshrc at build time.
#
# Mechanism: bake at BUILD time via a Dockerfile RUN step that appends the
# eval line to .zshrc using printf.  This is consistent with ADR-005 D7
# (install = build-time) and keeps this function parallel-safe with cmd_up
# (C3 / rip-cage-4c5.3 owns the cmd_up site; this function does NOT touch it).
#
# Injection safety: shell_init is validated to be a single line (no embedded
# newlines) before it is baked into a RUN step and a .zshrc echo.  The manifest
# is host-only (lower risk) but we do not bake unvalidated input.
#
# D8 byte-for-byte contract: when the default manifest is in effect (no
# SHELL-INTEGRATION entries), this function emits NOTHING.
#
# Output: zero or more Dockerfile RUN steps of the form:
#   RUN printf '\n# manifest SHELL-INTEGRATION: <name>\neval "..."\n' >> /home/agent/.zshrc
# one per SHELL-INTEGRATION entry.
_manifest_generate_shell_init_zshrc_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local steps=""
  for (( idx=0; idx<count; idx++ )); do
    local entry archetype
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "SHELL-INTEGRATION" ]]; then
      continue
    fi

    local name shell_init
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)
    shell_init=$(jq -r '.shell_init // ""' <<<"$entry" 2>/dev/null)

    if [[ -z "$shell_init" ]]; then
      echo "Error: manifest SHELL-INTEGRATION entry '${name}' has empty shell_init — skipping." >&2
      return 1
    fi

    # Injection safety: shell_init must be a single line.
    # Multi-line shell_init could inject arbitrary Dockerfile directives when
    # baked into a RUN step.
    if [[ "$shell_init" == *$'\n'* ]]; then
      echo "Error: manifest SHELL-INTEGRATION entry '${name}': field 'shell_init' must be a single line (newlines inject arbitrary Dockerfile directives; single-line-required)." >&2
      return 1
    fi

    # Emit a Dockerfile RUN step that appends the eval line to .zshrc.
    # Quote-safe mechanism: base64-encode shell_init so the Dockerfile RUN step
    # is safe against ANY single-line content (single-quotes, double-quotes, $, parens, etc.).
    # base64 output is quote/newline-safe by construction.
    # The generated step decodes at build time and appends to .zshrc.
    local b64_shell_init
    b64_shell_init=$(printf '%s' "$shell_init" | base64 | tr -d '\n')
    steps+="RUN # manifest SHELL-INTEGRATION: ${name}"$'\n'
    steps+="RUN printf '\\\\n# rip-cage manifest SHELL-INTEGRATION: ${name}\\\\n' >> /home/agent/.zshrc && echo '${b64_shell_init}' | base64 -d >> /home/agent/.zshrc && echo >> /home/agent/.zshrc"$'\n'
  done

  # Strip trailing newline for clean output; caller appends to Dockerfile.
  if [[ -n "$steps" ]]; then
    printf '%s' "${steps%$'\n'}"
  fi
}


# _manifest_generate_daemon_config_dockerfile_steps
# Read the host manifest and emit a Dockerfile RUN step that bakes the
# runtime config (start/health/state_dir/mcp_fragment) for every IN-CAGE-DAEMON
# entry into /etc/rip-cage/daemon-config.json at BUILD time.
#
# Mechanism: the manifest is host-only (not mounted into the cage), so the
# daemon's runtime config must be known at build time (ADR-005 D7:
# install=build-time, start=init-time). This generator base64-encodes the JSON
# config and emits a Dockerfile RUN step that decodes + writes it.
# init-rip-cage.sh reads /etc/rip-cage/daemon-config.json at startup to start
# each daemon via the ssh-agent-filter-precedent (fork + PID-file + fail-warn).
#
# D8 byte-for-byte contract: when the default manifest is in effect (no
# IN-CAGE-DAEMON entries), this function emits NOTHING.
#
# State-dir persistence decision (ADR-019 D1):
#   Container-local, following the extensions/ precedent.  Daemon state is
#   cage-lifetime; auth.json is the only bind-mount-durable item.  If a user
#   needs durable daemon state they should set state_dir to a /workspace path.
#   The init block creates state_dir with `mkdir -p` using the value from the
#   baked config.
#
# Strict-parse discipline: config fields are extracted with jq strict mode;
# _manifest_validate already ensured required fields are present at load time.
_manifest_generate_daemon_config_dockerfile_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  # Build JSON array of daemon entries for baking.
  local daemon_entries="[]"
  local has_daemons=0
  local state_dirs=()
  for (( idx=0; idx<count; idx++ )); do
    local entry archetype
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "IN-CAGE-DAEMON" ]]; then
      continue
    fi
    has_daemons=1

    local name daemon_start daemon_health daemon_state_dir mcp_fragment
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)
    daemon_start=$(jq -r '.start // ""' <<<"$entry" 2>/dev/null)
    daemon_health=$(jq -r '.health // ""' <<<"$entry" 2>/dev/null)
    daemon_state_dir=$(jq -r '.state_dir // ""' <<<"$entry" 2>/dev/null)
    mcp_fragment=$(jq -c '.mcp_fragment // null' <<<"$entry" 2>/dev/null)

    # Validate mcp_fragment is valid JSON if present (fail-closed, ADR-025 D5).
    if [[ "$mcp_fragment" != "null" && -n "$mcp_fragment" ]]; then
      if ! echo "$mcp_fragment" | jq '.' >/dev/null 2>&1; then
        echo "Error: manifest IN-CAGE-DAEMON entry '${name}': 'mcp_fragment' is not valid JSON." >&2
        return 1
      fi
    fi

    # Collect state_dir for Dockerfile pre-creation (must be agent-writable at runtime;
    # root creates it at build time so agent doesn't need write access to the parent —
    # rip-cage-4c5.9 fix for /var/lib/rip-cage-daemon/ permission denied).
    if [[ -n "$daemon_state_dir" ]]; then
      state_dirs+=("$daemon_state_dir")
    fi

    # Append to daemon_entries JSON array.
    local daemon_obj
    daemon_obj=$(jq -cn \
      --arg n "$name" \
      --arg s "$daemon_start" \
      --arg h "$daemon_health" \
      --arg d "$daemon_state_dir" \
      --argjson m "${mcp_fragment:-null}" \
      '{name:$n, start:$s, health:$h, state_dir:$d, mcp_fragment:$m}')
    daemon_entries=$(jq -c ". + [$daemon_obj]" <<<"$daemon_entries" 2>/dev/null)
  done

  if [[ "$has_daemons" -eq 0 ]]; then
    # No IN-CAGE-DAEMON entries — emit nothing (D8 short-circuit).
    return 0
  fi

  # Build the full config JSON and base64-encode it for Dockerfile injection.
  local config_json b64_config
  config_json=$(jq -c '{daemons:'"$daemon_entries"'}' <<<"null" 2>/dev/null) || config_json="{\"daemons\":${daemon_entries}}"
  b64_config=$(printf '%s' "$config_json" | base64 | tr -d '\n')

  # Emit Dockerfile RUN steps (as root, AFTER settings.json COPY at Dockerfile:133).
  # Step 1: decode + write /etc/rip-cage/daemon-config.json.
  # Step 2: pre-create state_dir(s) with agent:agent ownership so init-rip-cage.sh
  #         (running as USER agent) can start the daemon without needing write access
  #         to the parent directory (rip-cage-4c5.9 fix).
  # init-rip-cage.sh reads daemon-config.json at startup to start each daemon.
  local step=""
  step+="RUN # manifest IN-CAGE-DAEMON config bake (rip-cage-4c5.5)"$'\n'
  step+="RUN echo '${b64_config}' | base64 -d > /etc/rip-cage/daemon-config.json && chmod 0644 /etc/rip-cage/daemon-config.json"

  # Pre-create each daemon's state_dir with agent ownership at image build time.
  # R3: state_dir values are quoted in the RUN line as defense-in-depth — the
  # validator already rejected non-absolute/whitespace/metachar values at load,
  # but quoting ensures no word-split even if a future code path bypasses validation.
  if [[ "${#state_dirs[@]}" -gt 0 ]]; then
    local mkdir_args=""
    for sd in "${state_dirs[@]}"; do
      mkdir_args+=" \"${sd}\""
    done
    step+=$'\n'"RUN mkdir -p${mkdir_args} && chown -R agent:agent${mkdir_args}"
  fi

  printf '%s' "$step"
}


# _manifest_generate_daemon_mcp_dockerfile_steps
# Read the host manifest and emit a Dockerfile RUN step that merges the
# mcp_fragment of every IN-CAGE-DAEMON entry into /etc/rip-cage/settings.json
# mcpServers at BUILD time, so an in-cage agent discovers the daemon's MCP server.
#
# D8 byte-for-byte contract: when no daemon has an mcp_fragment, emits NOTHING.
#
# Merge semantics: for each daemon with a non-null mcp_fragment, merge
# {name: mcp_fragment} into the existing mcpServers object in settings.json.
# Uses jq to patch settings.json in-place (atomic temp-file write).
_manifest_generate_daemon_mcp_dockerfile_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local steps=""
  local has_mcp=0
  for (( idx=0; idx<count; idx++ )); do
    local entry archetype
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "IN-CAGE-DAEMON" ]]; then
      continue
    fi

    local name mcp_fragment
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)
    mcp_fragment=$(jq -c '.mcp_fragment // null' <<<"$entry" 2>/dev/null)

    if [[ "$mcp_fragment" == "null" || -z "$mcp_fragment" ]]; then
      continue
    fi

    # Validate mcp_fragment is valid JSON (fail-closed, ADR-025 D5).
    if ! echo "$mcp_fragment" | jq '.' >/dev/null 2>&1; then
      echo "Error: manifest IN-CAGE-DAEMON entry '${name}': 'mcp_fragment' is not valid JSON." >&2
      return 1
    fi

    has_mcp=1

    # Base64-encode the fragment for safe Dockerfile injection.
    local b64_fragment
    b64_fragment=$(printf '%s' "$mcp_fragment" | base64 | tr -d '\n')

    # Emit a Dockerfile RUN step that merges the fragment into settings.json.
    # Uses jq to atomically patch mcpServers (temp-file swap).
    steps+="RUN # manifest IN-CAGE-DAEMON MCP fragment: ${name} (rip-cage-4c5.5)"$'\n'
    steps+="RUN _frag=\$(echo '${b64_fragment}' | base64 -d) && jq --argjson frag \"\$_frag\" --arg name '${name}' '.mcpServers[\$name] = \$frag' /etc/rip-cage/settings.json > /tmp/settings-tmp.json && mv /tmp/settings-tmp.json /etc/rip-cage/settings.json"$'\n'
  done

  if [[ "$has_mcp" -eq 0 ]]; then
    return 0
  fi

  # Strip trailing newline for clean output.
  if [[ -n "$steps" ]]; then
    printf '%s' "${steps%$'\n'}"
  fi
}


# _manifest_generate_tool_init_config_dockerfile_steps
# Read the host manifest and emit a Dockerfile RUN step that bakes the
# declared 'init' command for every TOOL entry that carries one into
# /etc/rip-cage/tool-init-config.json at BUILD time (rip-cage-p35a.2,
# implementing ADR-005 D7).
#
# Mechanism: the manifest is host-only (not mounted into the cage), so each
# TOOL's declared init command must be known at build time (ADR-005 D7:
# install=build-time). This generator base64-encodes a JSON config and emits
# a Dockerfile RUN step that decodes + writes it. init-rip-cage.sh reads
# /etc/rip-cage/tool-init-config.json at startup and runs each declared init
# command ONCE, in agent context (no sudo) — distinct from IN-CAGE-DAEMON
# 'start', which launches a long-lived background service.
#
# D8 byte-for-byte contract: when NO TOOL entry declares 'init', this function
# emits NOTHING — a TOOL manifest with no init hooks must produce byte-identical
# codegen output to a manifest with no init field at all (rip-cage-p35a.2;
# cf. memory dist-default-manifest-must-be-regenerated-when-example-recipes-change
# gap (2), where a shim was once baked unconditionally).
#
# Tool-agnostic seam (ADR-005 D12): this function reads manifest DATA only
# (entry.name, entry.init) — it names no tool. Any TOOL entry that declares
# 'init' is wired identically; there is no tool-specific branch.
#
# Strict-parse discipline: 'init' is single-line-validated and hook-bounds-
# checked by _manifest_validate before this function ever runs (rc:~6849-6866).
_manifest_generate_tool_init_config_dockerfile_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  # Build JSON array of tool-init entries for baking.
  local tool_init_entries="[]"
  local has_tool_inits=0
  for (( idx=0; idx<count; idx++ )); do
    local entry archetype
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "TOOL" ]]; then
      continue
    fi

    local name tool_init
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)
    tool_init=$(jq -r '.init // ""' <<<"$entry" 2>/dev/null)

    if [[ -z "$tool_init" ]]; then
      continue
    fi

    has_tool_inits=1

    local init_obj
    init_obj=$(jq -cn \
      --arg n "$name" \
      --arg i "$tool_init" \
      '{name:$n, init:$i}')
    tool_init_entries=$(jq -c ". + [$init_obj]" <<<"$tool_init_entries" 2>/dev/null)
  done

  if [[ "$has_tool_inits" -eq 0 ]]; then
    # No TOOL entry declares 'init' — emit nothing (D8 short-circuit).
    return 0
  fi

  # Build the full config JSON and base64-encode it for Dockerfile injection.
  local config_json b64_config
  config_json=$(jq -c '{tool_inits:'"$tool_init_entries"'}' <<<"null" 2>/dev/null) || config_json="{\"tool_inits\":${tool_init_entries}}"
  b64_config=$(printf '%s' "$config_json" | base64 | tr -d '\n')

  # Emit Dockerfile RUN steps (as root, AFTER settings.json COPY at Dockerfile:133 —
  # same injection site as the IN-CAGE-DAEMON config bake, root context, /etc/rip-cage exists).
  # init-rip-cage.sh reads tool-init-config.json at startup and runs each declared init.
  local step=""
  step+="RUN # manifest TOOL init-hook config bake (rip-cage-p35a.2)"$'\n'
  step+="RUN echo '${b64_config}' | base64 -d > /etc/rip-cage/tool-init-config.json && chmod 0644 /etc/rip-cage/tool-init-config.json"

  printf '%s' "$step"
}


# _manifest_generate_multiplexer_registry_steps
# Read the host manifest and emit Dockerfile RUN steps that bake each
# MULTIPLEXER-archetype tool's declared hook command strings into
# /etc/rip-cage/multiplexers/<name>/<hook> in the image at BUILD time.
#
# Mechanism: for each MULTIPLEXER entry, mkdir the registry dir and use
# base64-encoded hook commands (safe against any shell metachar) decoded at
# Dockerfile-RUN time into one file per declared hook.  Only DECLARED hooks
# are written; optional hooks absent from the manifest produce no file.
#
# Injection point: same as IN-CAGE-DAEMON config steps — after
# "COPY cage/agent/settings.json /etc/rip-cage/settings.json" (root context;
# /etc/rip-cage already exists at Dockerfile:127).
#
# D8 byte-for-byte contract: when the manifest has no MULTIPLEXER entries,
# this function emits NOTHING.
#
# ADR-005 D9 (hooks = availability-payload, FIRM)
# ADR-005 D12 (composable seam — registry IS the mechanism)
# rip-cage-61al.2
_manifest_generate_multiplexer_registry_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local steps=""
  local has_multiplexers=0

  for (( idx=0; idx<count; idx++ )); do
    local entry archetype
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "MULTIPLEXER" ]]; then
      continue
    fi
    has_multiplexers=1

    local name
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    # Sanitize name for use as a directory component (defense-in-depth guard).
    # _manifest_validate enforces the full [a-z0-9_-] format check before this
    # function is called, so any name reaching here should already be safe.
    # This guard catches internal callers that bypass the validator.
    if [[ "$name" == *"/"* || "$name" == *" "* ]]; then
      echo "Error: manifest MULTIPLEXER entry '${name}': name contains slash or space — cannot use as registry dir name." >&2
      return 1
    fi

    local registry_dir="/etc/rip-cage/multiplexers/${name}"

    # Start the step block for this mux entry.
    steps+="RUN # manifest MULTIPLEXER registry bake: ${name} (rip-cage-61al.2)"$'\n'
    steps+="RUN mkdir -p '${registry_dir}'"$'\n'

    # Write each declared hook as a file under the registry dir.
    # Use base64 encoding (same approach as daemon config bake) to handle any
    # shell metachar in the hook command string safely.
    # Only write files for hooks that are actually declared.
    local hook_name hook_cmd b64_cmd
    for hook_name in start attach exec new_session teardown; do
      hook_cmd=$(jq -r ".hooks.${hook_name} // \"___RC_ABSENT___\"" <<<"$entry" 2>/dev/null)
      [[ "$hook_cmd" == "___RC_ABSENT___" || -z "$hook_cmd" ]] && continue

      # Injection safety: hook_cmd must be a single line (already validated by
      # _manifest_validate, but guard here too — multi-line could inject Dockerfile directives).
      if [[ "$hook_cmd" == *$'\n'* ]]; then
        echo "Error: manifest MULTIPLEXER entry '${name}': hook '${hook_name}' contains newline — single-line required." >&2
        return 1
      fi

      b64_cmd=$(printf '%s' "$hook_cmd" | base64 | tr -d '\n')
      steps+="RUN echo '${b64_cmd}' | base64 -d > '${registry_dir}/${hook_name}' && chmod 0755 '${registry_dir}/${hook_name}'"$'\n'
    done
  done

  if [[ "$has_multiplexers" -eq 0 ]]; then
    # No MULTIPLEXER entries — emit nothing (D8 short-circuit).
    return 0
  fi

  # Strip trailing newline for clean output; caller appends to Dockerfile.
  if [[ -n "$steps" ]]; then
    printf '%s' "${steps%$'\n'}"
  fi
}


# _manifest_generate_multiplexer_label
# Read the host manifest and emit a Dockerfile LABEL line enumerating all
# MULTIPLEXER-archetype tool names declared in the manifest, e.g.:
#   LABEL rc.multiplexers="<name1>,<name2>"
#
# This label is frozen in the image at build time so B2 (host-side config
# validator) can read it via `docker inspect` WITHOUT re-reading the host
# manifest at runtime — preserving the no-image-vs-host-drift invariant.
#
# D8 byte-for-byte contract: when the manifest has no MULTIPLEXER entries,
# this function emits NOTHING.
#
# rip-cage-61al.2
_manifest_generate_multiplexer_label() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local mux_names=""
  for (( idx=0; idx<count; idx++ )); do
    local entry archetype name
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "MULTIPLEXER" ]]; then
      continue
    fi
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)
    if [[ -n "$mux_names" ]]; then
      mux_names+=",$name"
    else
      mux_names="$name"
    fi
  done

  if [[ -z "$mux_names" ]]; then
    # No MULTIPLEXER entries — emit nothing.
    return 0
  fi

  printf 'LABEL rc.multiplexers="%s"' "$mux_names"
}


# _manifest_generate_mediator_registry_steps
# Read the host manifest and emit Dockerfile RUN steps that bake each
# MEDIATOR-archetype tool's declared hook command strings into
# /etc/rip-cage/mediators/<name>/<hook> in the image at BUILD time.
#
# Isomorphic to _manifest_generate_multiplexer_registry_steps but for the
# egress-mediator seam (ADR-026 D5, rip-cage-ta1o.5.1).
#
# Mechanism: for each MEDIATOR entry, mkdir the registry dir and use
# base64-encoded hook commands decoded at Dockerfile-RUN time into one file
# per declared hook. Only DECLARED hooks are written.
#
# D8 byte-for-byte contract: when the manifest has no MEDIATOR entries,
# this function emits NOTHING.
#
# ADR-005 D12 (composable seam — registry IS the mechanism)
# rip-cage-ta1o.5.1
_manifest_generate_mediator_registry_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local steps=""
  local has_mediators=0

  for (( idx=0; idx<count; idx++ )); do
    local entry archetype
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "MEDIATOR" ]]; then
      continue
    fi
    has_mediators=1

    local name
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    # Sanitize name for use as a directory component (defense-in-depth guard).
    if [[ "$name" == *"/"* || "$name" == *" "* ]]; then
      echo "Error: manifest MEDIATOR entry '${name}': name contains slash or space — cannot use as registry dir name." >&2
      return 1
    fi

    local registry_dir="/etc/rip-cage/mediators/${name}"

    steps+="RUN # manifest MEDIATOR registry bake: ${name} (rip-cage-ta1o.5.1)"$'\n'
    steps+="RUN mkdir -p '${registry_dir}'"$'\n'

    # Bake run_as_uid into the registry so it's readable from the image without
    # re-reading the host manifest — preserves the no-image-vs-host-drift invariant
    # (ADR-026 D5). Child .2 (router forward) reads this to (a) install the
    # iptables egress uid-exemption and (b) drop privileges in the start hook.
    local med_run_as_uid
    med_run_as_uid=$(jq -r '.run_as_uid // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
    if [[ "$med_run_as_uid" != "___RC_ABSENT___" && -n "$med_run_as_uid" ]]; then
      steps+="RUN printf '%s' '${med_run_as_uid}' > '${registry_dir}/run_as_uid'"$'\n'
    fi

    # Optional: ca_cert_path — path inside the container to the mediator's generated CA cert.
    # init-mediator.sh reads this at cage init and installs the cert into the system trust
    # store so the in-cage agent curl can verify the MITM cert. (rip-cage-ta1o.5.8)
    local med_ca_cert_path
    med_ca_cert_path=$(jq -r '.ca_cert_path // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
    if [[ "$med_ca_cert_path" != "___RC_ABSENT___" && -n "$med_ca_cert_path" ]]; then
      steps+="RUN printf '%s' '${med_ca_cert_path}' > '${registry_dir}/ca_cert_path'"$'\n'
    fi

    # Write each declared hook as a file under the registry dir.
    local hook_name hook_cmd b64_cmd
    for hook_name in start health_check teardown; do
      hook_cmd=$(jq -r ".hooks.${hook_name} // \"___RC_ABSENT___\"" <<<"$entry" 2>/dev/null)
      [[ "$hook_cmd" == "___RC_ABSENT___" || -z "$hook_cmd" ]] && continue

      # Injection safety: hook_cmd must be a single line.
      if [[ "$hook_cmd" == *$'\n'* ]]; then
        echo "Error: manifest MEDIATOR entry '${name}': hook '${hook_name}' contains newline — single-line required." >&2
        return 1
      fi

      b64_cmd=$(printf '%s' "$hook_cmd" | base64 | tr -d '\n')
      steps+="RUN echo '${b64_cmd}' | base64 -d > '${registry_dir}/${hook_name}' && chmod 0755 '${registry_dir}/${hook_name}'"$'\n'
    done
  done

  if [[ "$has_mediators" -eq 0 ]]; then
    # No MEDIATOR entries — emit nothing (D8 short-circuit).
    return 0
  fi

  # Strip trailing newline for clean output; caller appends to Dockerfile.
  if [[ -n "$steps" ]]; then
    printf '%s' "${steps%$'\n'}"
  fi
}


# _manifest_generate_safety_stack_asserted_steps
# Read the host manifest and emit Dockerfile RUN steps to bake
# /etc/rip-cage/safety-stack-asserted, root:root 0644,
# parent dir root:root 0755 (already created by Dockerfile).
#
# ONLY tools that carry `required: true` contribute. rc never interprets tool
# names — it reads required + assert_loaded (or synthesizes test -x from the
# declared runtime binary_path) and bakes <entry-id> <base64(check)> pairs,
# one per line. This preserves ADR-005 D12 (rc stays tool-agnostic).
#
# Line format: "<entry-id> <base64(check-cmd)>"
#   - entry-id: the tool's manifest 'name' field (human-legible; space-free enforced by validator)
#   - base64(check-cmd): standard base64 of the shell check to run in-cage
#
# Codegen synthesizes the check:
#   required:true + assert_loaded:"cmd"           → bake <id> b64(cmd)
#   required:true + no assert_loaded + binary_path → bake <id> b64(test -x <binary_path>)
#   required:true + no assert_loaded + output_path → bake <id> b64(test -x <output_path>)
#   All other required:true combinations → rejected by _manifest_validate (never reach here)
#
# The file is ABSENT when no required:true entries are declared (default/bundled-only
# manifest), keeping the fail-closed semantics consistent: absent = minimal cage
# (no assertions); present = named tools must be active.
#
# D8 byte-for-byte contract: when the manifest has no required:true entries,
# this function emits NOTHING — rc build uses the original Dockerfile unchanged.
#
# rip-cage-m8zc
_manifest_generate_safety_stack_asserted_steps() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  # asserted_lines: each entry is "<id> <base64(check)>" for a required tool.
  local asserted_lines=""
  for (( idx=0; idx<count; idx++ )); do
    local entry req_raw entry_name
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    req_raw=$(jq -r 'if has("required") then (.required | tostring) else "false" end' <<<"$entry" 2>/dev/null)
    # Skip entries that are not required:true.
    [[ "$req_raw" != "true" ]] && continue

    entry_name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    # Determine the check command.
    # Priority: author-supplied assert_loaded → synthesized from binary_path → synthesized from output_path.
    local al_val check_cmd
    al_val=$(jq -r '.assert_loaded // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)

    if [[ "$al_val" != "___RC_ABSENT___" && "$al_val" != "null" && -n "$al_val" ]]; then
      # Author-supplied assert_loaded — validated single-line by _manifest_validate.
      check_cmd="$al_val"
    else
      # Synthesize from runtime binary_path (preferred) or build_source.output_path.
      # The validator ensures at least one is present when required:true and no assert_loaded.
      local binary_path_val output_path_val
      binary_path_val=$(jq -r '.binary_path // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)
      output_path_val=$(jq -r '.build_source.output_path // "___RC_ABSENT___"' <<<"$entry" 2>/dev/null)

      if [[ "$binary_path_val" != "___RC_ABSENT___" && "$binary_path_val" != "null" && -n "$binary_path_val" ]]; then
        # binary_path may be a string or a list; take the first element if list.
        local bp_type
        bp_type=$(jq -r '.binary_path | type' <<<"$entry" 2>/dev/null)
        if [[ "$bp_type" == "array" ]]; then
          binary_path_val=$(jq -r '.binary_path[0]' <<<"$entry" 2>/dev/null)
        fi
        check_cmd="test -x ${binary_path_val}"
      elif [[ "$output_path_val" != "___RC_ABSENT___" && "$output_path_val" != "null" && -n "$output_path_val" ]]; then
        check_cmd="test -x ${output_path_val}"
      else
        # Should never reach here — _manifest_validate rejects this case.
        echo "Error: manifest tools entry '${entry_name}': required:true but no assert_loaded and no binary path — codegen cannot synthesize check (rip-cage-m8zc)." >&2
        return 1
      fi
    fi

    # base64-encode the check command (newline-free for safe RUN embedding).
    local b64_check
    b64_check=$(printf '%s' "$check_cmd" | base64 | tr -d '\n')

    local line="${entry_name} ${b64_check}"
    if [[ -n "$asserted_lines" ]]; then
      asserted_lines+=$'\n'"$line"
    else
      asserted_lines="$line"
    fi
  done

  if [[ -z "$asserted_lines" ]]; then
    # No required:true entries — emit nothing (D8 contract).
    return 0
  fi

  # Emit a Dockerfile RUN step that writes the asserted file root:root 0644.
  # base64-encode the whole file content so the RUN step is safe against any
  # content (no shell injection risk).
  local b64_asserted
  b64_asserted=$(printf '%s\n' "$asserted_lines" | base64 | tr -d '\n')
  printf 'RUN # manifest required/assert_loaded: bake safety-stack-asserted (rip-cage-m8zc)\n'
  printf "RUN echo '%s' | base64 -d > /etc/rip-cage/safety-stack-asserted && chown root:root /etc/rip-cage/safety-stack-asserted && chmod 0644 /etc/rip-cage/safety-stack-asserted\n" "$b64_asserted"
}


# _manifest_generate_mediator_label
# Read the host manifest and emit a Dockerfile LABEL line enumerating all
# MEDIATOR-archetype tool names declared in the manifest, e.g.:
#   LABEL rc.mediators="<name1>,<name2>"
#
# This label is frozen in the image at build time so the host-side config
# validator can read it via `docker inspect` WITHOUT re-reading the host
# manifest at runtime — preserving the no-image-vs-host-drift invariant.
# Isomorphic to _manifest_generate_multiplexer_label (ADR-026 D5).
#
# D8 byte-for-byte contract: when the manifest has no MEDIATOR entries,
# this function emits NOTHING.
#
# rip-cage-ta1o.5.1
_manifest_generate_mediator_label() {
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count idx
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local mediator_names=""
  for (( idx=0; idx<count; idx++ )); do
    local entry archetype name
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)
    archetype=$(jq -r '.archetype // ""' <<<"$entry" 2>/dev/null)
    if [[ "$archetype" != "MEDIATOR" ]]; then
      continue
    fi
    name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)
    if [[ -n "$mediator_names" ]]; then
      mediator_names+=",$name"
    else
      mediator_names="$name"
    fi
  done

  if [[ -z "$mediator_names" ]]; then
    # No MEDIATOR entries — emit nothing.
    return 0
  fi

  printf 'LABEL rc.mediators="%s"' "$mediator_names"
}


# =============================================================================
# End tool manifest schema + host-only loader (rip-cage-4c5.1)
# + TOOL install-step generation (rip-cage-4c5.2)
# + SHELL-INTEGRATION shell_init baking (rip-cage-4c5.4)
# + IN-CAGE-DAEMON config bake + MCP fragment (rip-cage-4c5.5)
# + MULTIPLEXER registry bake + image label + reference reader (rip-cage-61al.2)
# =============================================================================

# =============================================================================
# Manifest egress+mounts floor (rip-cage-4c5.3)
#
# Wire declared egress: hosts into the allowlist union and check them against
# the IOC denylist (ADR-005 D3 / ADR-012 D1).  Check declared mounts: paths
# against the secret-path denylist (ADR-023 D1/D6).
# =============================================================================

# _manifest_check_ioc_egress — ADR-005 D3 / ADR-012 D1 / rip-cage-4c5.3
#
# Parse the manifest's egress: declarations for every TOOL and IN-CAGE-DAEMON
# entry and reject any host that matches a deny:true rule in egress-rules.yaml.
#
# Matching is performed with a real YAML parser (yq + jq), not fragile grep.
# Two matching modes per IOC rule:
#   match.host        — exact hostname match (e.g. "webhook.site")
#   match.host_suffix — suffix match (e.g. ".ngrok.io" matches "foo.ngrok.io")
#
# Fail-closed: on any match, print an error to stderr naming the offending host
# and return non-zero.  Absence of yq is an error (same policy as manifest
# loader and config validator).
#
# Parameters:
#   $1  ioc_rules_file  — path to egress-rules.yaml (default: SCRIPT_DIR)
#
# The check fires BEFORE any Docker call in both cmd_build and cmd_up so it is
# testable without a working Docker daemon.
_manifest_check_ioc_egress() {
  local _ioc_rules_file="${1:-${SCRIPT_DIR}/cage/egress/egress-rules.yaml}"

  if ! command -v yq &>/dev/null; then
    echo "Error: yq not found — required for manifest IOC egress check (install: brew install yq)." >&2
    return 1
  fi

  if [[ ! -f "$_ioc_rules_file" ]]; then
    echo "Error: IOC rules file not found at ${_ioc_rules_file}" >&2
    return 1
  fi

  # Load manifest (fail-closed if invalid).
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  # Extract IOC denylist: hosts (exact) and host_suffixes from deny:true rules.
  # Use yq to parse the YAML, jq to filter.
  local _ioc_json
  if ! _ioc_json=$(yq -o=json '.rules // []' "$_ioc_rules_file" 2>/dev/null); then
    echo "Error: failed to parse IOC rules file ${_ioc_rules_file}" >&2
    return 1
  fi

  # Build two arrays: exact deny hosts and deny host_suffixes.
  # Fail-CLOSED: if jq fails or returns empty when _ioc_json was non-empty, refuse
  # rather than defaulting to an empty denylist (fail-open is a security regression).
  local _deny_hosts_json _deny_suffixes_json
  if ! _deny_hosts_json=$(jq -c '[.[] | select(.deny == true) | .match.host // empty]' <<<"$_ioc_json" 2>/dev/null); then
    echo "Error: failed to parse IOC denylist from egress-rules.yaml — refusing to build/up" >&2
    return 1
  fi
  if [[ -z "$_deny_hosts_json" ]]; then
    echo "Error: failed to parse IOC denylist from egress-rules.yaml — refusing to build/up" >&2
    return 1
  fi
  if ! _deny_suffixes_json=$(jq -c '[.[] | select(.deny == true) | .match.host_suffix // empty]' <<<"$_ioc_json" 2>/dev/null); then
    echo "Error: failed to parse IOC denylist from egress-rules.yaml — refusing to build/up" >&2
    return 1
  fi
  if [[ -z "$_deny_suffixes_json" ]]; then
    echo "Error: failed to parse IOC denylist from egress-rules.yaml — refusing to build/up" >&2
    return 1
  fi

  # Walk every tool entry that has egress: declarations.
  # No archetype filter here — the IOC check covers ANY entry that declares egress:
  # (TOOL, IN-CAGE-DAEMON, SHELL-INTEGRATION, etc.). Entries without egress: simply
  # contribute nothing (egress_count == 0 → skip). This matches the union in
  # _manifest_egress_hosts_json which also iterates all entries regardless of archetype.
  local idx
  for (( idx=0; idx<count; idx++ )); do
    local entry egress_count eidx
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)

    egress_count=$(jq '.egress | length' <<<"$entry" 2>/dev/null)
    [[ -z "$egress_count" || "$egress_count" -eq 0 ]] && continue

    local tool_name
    tool_name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    for (( eidx=0; eidx<egress_count; eidx++ )); do
      local egress_host
      egress_host=$(jq -r ".egress[${eidx}]" <<<"$entry" 2>/dev/null)
      [[ -z "$egress_host" ]] && continue

      # Check exact host match.
      local exact_match
      exact_match=$(jq -r --arg h "$egress_host" '.[] | select(. == $h)' <<<"$_deny_hosts_json" 2>/dev/null)
      if [[ -n "$exact_match" ]]; then
        echo "Error: manifest tool '${tool_name}' declares egress host '${egress_host}' which is on the IOC denylist (egress-rules.yaml deny:true). Remove this host from the manifest egress: declaration. (ADR-005 D3 / ADR-012 D1)" >&2
        return 1
      fi

      # Check suffix match: egress_host ends with a deny host_suffix.
      # jq idiom: `. as $sfx | $h | endswith($sfx)` — binds current array element to
      # $sfx, then tests whether the egress host ends with that suffix.
      local suffix_match
      suffix_match=$(jq -r --arg h "$egress_host" '.[] | select(. as $sfx | $h | endswith($sfx))' <<<"$_deny_suffixes_json" 2>/dev/null)
      if [[ -n "$suffix_match" ]]; then
        echo "Error: manifest tool '${tool_name}' declares egress host '${egress_host}' which matches IOC denylist suffix '${suffix_match}' (egress-rules.yaml deny:true). Remove this host from the manifest egress: declaration. (ADR-005 D3 / ADR-012 D1)" >&2
        return 1
      fi
    done
  done

  return 0
}


# _manifest_expand_mount_host — expand leading ~/ and $HOME/${HOME} in a mount host path.
#
# SAFE expansion: only a LEADING ~/ prefix and the literal strings $HOME and ${HOME}
# are expanded to $HOME.  No arbitrary ${ANYVAR} interpolation is performed to avoid
# injection / info-leak surfaces.
#
# The expansion is applied BEFORE realpath + ADR-023 denylist so those mechanisms
# always operate on resolved paths (security fully preserved).
#
# Parameters:
#   $1  raw_path — the host path value as read from the manifest (may contain ~/ or $HOME)
#
# Returns: expanded path on stdout (unchanged if no known prefix is found)
_manifest_expand_mount_host() {
  local raw_path="${1:-}"
  local home_dir="${HOME:-}"

  # Expand leading ~/ to $HOME/
  # Use quoted '~/' pattern in both the test and the strip to avoid tilde
  # special-casing in bash parameter expansion (${var#~/} would expand ~
  # before stripping; '~/' is the literal two-char prefix we want).
  # shellcheck disable=SC2088  # intentional: comparing against literal ~/
  if [[ "$raw_path" == '~/'* ]]; then
    echo "${home_dir}/${raw_path#'~/'}"
    return 0
  fi

  # Expand leading $HOME/ or ${HOME}/ to the literal $HOME value.
  # Single-quoted patterns are intentional: we want to compare raw_path against
  # the *literal* strings "$HOME/" and "${HOME}/" as a user might write them in
  # a manifest, not against the shell-expanded value of $HOME.
  # shellcheck disable=SC2016  # intentional: literal $HOME/ pattern comparison
  if [[ "$raw_path" == '$HOME/'* ]]; then
    # shellcheck disable=SC2016  # intentional: strip literal $HOME/ prefix
    echo "${home_dir}/${raw_path#'$HOME/'}"
    return 0
  fi
  # shellcheck disable=SC2016  # intentional: literal ${HOME}/ pattern comparison
  if [[ "$raw_path" == '${HOME}/'* ]]; then
    # shellcheck disable=SC2016  # intentional: strip literal ${HOME}/ prefix
    echo "${home_dir}/${raw_path#'${HOME}/'}"
    return 0
  fi

  # Exact match: $HOME or ${HOME} alone (no trailing slash)
  # shellcheck disable=SC2016  # intentional: comparing against literal $HOME
  if [[ "$raw_path" == '$HOME' ]]; then
    echo "${home_dir}"
    return 0
  fi
  # shellcheck disable=SC2016  # intentional: comparing against literal ${HOME}
  if [[ "$raw_path" == '${HOME}' ]]; then
    echo "${home_dir}"
    return 0
  fi

  # No known prefix — return unchanged.
  echo "$raw_path"
}


# _manifest_check_mounts_denylist — ADR-023 D1/D6 / rip-cage-4c5.3
#
# Check every manifest mounts: path declaration against the secret-path
# denylist.  Resolves each path with realpath before matching (fail-loud on
# a denylisted target, ADR-023 D6 FIRM).
#
# Fires BEFORE any Docker call in cmd_up so it is testable without a running
# container.
#
# Parameters:
#   $1  workspace  — workspace path (for _load_effective_config / denylist)
_manifest_check_mounts_denylist() {
  local _workspace="${1:-.}"

  # Load manifest (fail-closed if invalid).
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local idx
  for (( idx=0; idx<count; idx++ )); do
    local entry mounts_count midx
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)

    mounts_count=$(jq '.mounts | length' <<<"$entry" 2>/dev/null)
    [[ -z "$mounts_count" || "$mounts_count" -eq 0 ]] && continue

    local tool_name
    tool_name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    for (( midx=0; midx<mounts_count; midx++ )); do
      local mount_path expanded_path resolved_path
      # Read .host field from the {host, dest} object (rip-cage-buuo.1).
      mount_path=$(jq -r ".mounts[${midx}].host" <<<"$entry" 2>/dev/null)
      [[ -z "$mount_path" || "$mount_path" == "null" ]] && continue

      # Expand ~/  and $HOME/${HOME} before realpath (rip-cage-buuo.5).
      expanded_path=$(_manifest_expand_mount_host "$mount_path")

      # Realpath-first: resolve before matching (ADR-023 D6).
      resolved_path=$(realpath "$expanded_path" 2>/dev/null) || resolved_path="$expanded_path"

      # Check against the denylist.
      if _check_secret_path_denylist "$resolved_path" "$_workspace"; then
        local _denied_pattern
        _denied_pattern=$(_secret_path_denylist_matched_pattern "$resolved_path" "$_workspace" 2>/dev/null || true)
        echo "Error: manifest-declared mount for tool '${tool_name}': '${resolved_path}' matched secret-path denylist pattern '${_denied_pattern:-<unknown>}'. Remove this path from the manifest mounts: declaration or add to mounts.allow_risky in .rip-cage.yaml. (ADR-023 D1/D6)" >&2
        return 1
      fi

      # rip-cage-rc09: dest-allowlist check.
      # CARVE-OUT (honest): root_owned_required: true mounts are exempt from
      # the dest-allowlist ONLY IF the resolved HOST SOURCE is genuinely
      # root-owned (uid 0, not group/other-writable).
      #
      # If root_owned_required: true but the source is NOT root-owned, the
      # exemption is NOT granted — fall through to the normal allowlist check.
      # This closes the bypass: a fragment with root_owned_required: true +
      # dest: /etc/rip-cage/pi + host: <agent-writable dir> is NOT exempt
      # (host uid != 0 → no exemption → allowlist rejects the system dest).
      #
      # A non-root source to an agent-space dest is still allowed (the allowlist
      # accepts it).  A non-root source to a system dest is rejected.
      # Cite: rip-cage-rc09 / ADR-027 D1.
      local _root_owned_req _allowlist_exempt=0
      _root_owned_req=$(jq -r ".mounts[${midx}].root_owned_required // false" <<<"$entry" 2>/dev/null)
      if [[ "$_root_owned_req" == "true" ]] && _host_source_is_root_owned "$resolved_path"; then
        _allowlist_exempt=1
      fi
      if [[ "$_allowlist_exempt" -ne 1 ]]; then
        # Lexically normalize the container dest path before allowlist check
        # to block '..' escape attacks (e.g. /home/agent/../etc/rip-cage/pi).
        local _mount_dest _norm_dest
        _mount_dest=$(jq -r ".mounts[${midx}].dest // \"\"" <<<"$entry" 2>/dev/null)
        if [[ -n "$_mount_dest" && "$_mount_dest" != "null" ]]; then
          _norm_dest=$(_lexical_normalize_path "$_mount_dest")
          if ! _manifest_dest_in_allowed_roots "$_norm_dest"; then
            echo "Error: manifest-declared mount for tool '${tool_name}': dest '${_mount_dest}' (normalized: '${_norm_dest}') is outside the agent-writable allowlist (/home/agent, /workspace). Mounts must land in agent-writable space, or declare root_owned_required: true with a root-owned host source (ADR-027 D1). (rip-cage-rc09)" >&2
            return 1
          fi
        fi
      fi
    done
  done

  return 0
}


# _manifest_check_binary_root_owned — ADR-005 D9 / ADR-024 / rip-cage-buuo.3 / rip-cage-ryn6
#
# EFFECT-based assertion: for every TOOL entry in the manifest that declares a
# checkable binary path, inspect the ACTUAL installed binary in the already-built
# image using `docker run --rm <image> stat -c '%U %a' <runtime-path>`. Rejects
# any binary that is NOT owned by root OR that is writable by the agent user
# (group-write or other-write bit set).
#
# An agent-writable binary is an ADR-005 D9 / ADR-024 violation: a prompt-injected
# agent could rewrite its own tool binary and escape the safety stack.
#
# This check fires AFTER docker build (it requires the image to exist).
# Two entry types are checked:
#
#   1. From-source (build_source) entries: runtime path is derived from
#      /usr/local/bin/<basename of build_source.output_path> (same derivation
#      as the Dockerfile codegen).
#
#   2. Prebuilt (install_cmd) entries that declare an optional 'binary_path'
#      field (rip-cage-ryn6): each declared path is checked directly as-is.
#      Prebuilt entries WITHOUT binary_path are skipped (the deliberate 80/20
#      boundary — package-manager installs have no author-chosen path).
#
# Parameters:
#   $1  image_tag  — Docker image tag to inspect (e.g. "rip-cage:latest")
#
# Stdout: (none)
# Stderr: error messages on violation
# Returns: 0 if all binaries are root-owned and not agent-writable, 1 on violation.
_manifest_check_binary_root_owned() {
  local _image_tag="${1:-rip-cage:latest}"

  # Load manifest (fail-closed if invalid).
  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  # Helper: check one binary path inside the image (owner + mode).
  # _check_one_path <tool_name> <runtime_path>
  # Uses _image_tag and _violation from outer scope.
  _check_one_binary_path() {
    local _tool_name="$1"
    local _runtime_path="$2"

    # Effect-based check: inspect the actual binary inside the built image.
    # stat -c '%U %a' prints: owner_name octal_mode (e.g. "root 755")
    local stat_out
    if ! stat_out=$(docker run --rm "$_image_tag" stat -c '%U %a' "$_runtime_path" 2>/dev/null); then
      echo "Error: manifest binary-root-owned check for tool '${_tool_name}': could not stat '${_runtime_path}' inside image '${_image_tag}' — binary may be absent or image not built. (ADR-005 D9 / ADR-024 binary-root-owned)" >&2
      _violation=1
      return
    fi

    local stat_owner stat_mode
    stat_owner=$(awk '{print $1}' <<<"$stat_out")
    stat_mode=$(awk '{print $2}' <<<"$stat_out")

    # Owner MUST be root.
    if [[ "$stat_owner" != "root" ]]; then
      echo "Error: manifest tool '${_tool_name}' binary at '${_runtime_path}' is owned by '${stat_owner}' (not root). An agent-writable binary violates the safety floor — an injected agent could rewrite its own tool. (ADR-005 D9 / ADR-024 binary-root-owned)" >&2
      _violation=1
    fi

    # Mode: group-write (bit 4 of 3-digit octal) or other-write (bit 1 of 3-digit octal)
    # must NOT be set. Extract the group and other permission digits.
    # For a 3-digit octal "XYZ": Y = group digit, Z = other digit.
    # Write bit in each digit: 2 = w, 3 = wx, 6 = rw, 7 = rwx.
    # Normalize to exactly 3 digits (drop leading digits like "0" prefix if stat gives 4).
    local mode_3
    mode_3="${stat_mode: -3}"  # last 3 chars
    local group_digit other_digit
    group_digit="${mode_3:1:1}"
    other_digit="${mode_3:2:1}"

    local writable=0
    case "$group_digit" in 2|3|6|7) writable=1 ;; esac
    case "$other_digit" in 2|3|6|7) writable=1 ;; esac

    if [[ "$writable" -eq 1 ]]; then
      echo "Error: manifest tool '${_tool_name}' binary at '${_runtime_path}' has mode '${stat_mode}' which is group/other-writable. The agent user could overwrite this binary, violating the safety floor. (ADR-005 D9 / ADR-024 binary-root-owned)" >&2
      _violation=1
    fi
  }

  local _violation=0
  local idx
  for (( idx=0; idx<count; idx++ )); do
    local entry
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)

    local tool_name
    tool_name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    # --- From-source (build_source) entries ---
    local build_source_present
    build_source_present=$(jq -r 'if has("build_source") and (.build_source | type) == "object" then "yes" else "no" end' <<<"$entry" 2>/dev/null)
    if [[ "$build_source_present" == "yes" ]]; then
      local bs_output_path runtime_path
      bs_output_path=$(jq -r '.build_source.output_path // ""' <<<"$entry" 2>/dev/null)
      if [[ -z "$bs_output_path" ]]; then
        echo "Error: manifest from-source tool '${tool_name}': build_source.output_path is empty — cannot verify binary ownership." >&2
        _violation=1
        continue
      fi
      # Runtime path: /usr/local/bin/<basename of output_path> (same derivation as codegen).
      runtime_path="/usr/local/bin/$(basename "${bs_output_path}")"
      _check_one_binary_path "$tool_name" "$runtime_path"
      continue
    fi

    # --- Prebuilt (install_cmd) entries with declared binary_path (rip-cage-ryn6) ---
    local binary_path_present binary_path_type
    binary_path_present=$(jq -r 'if has("binary_path") then "yes" else "no" end' <<<"$entry" 2>/dev/null)
    [[ "$binary_path_present" != "yes" ]] && continue

    binary_path_type=$(jq -r '.binary_path | type' <<<"$entry" 2>/dev/null)
    if [[ "$binary_path_type" == "string" ]]; then
      local bp_path
      bp_path=$(jq -r '.binary_path' <<<"$entry" 2>/dev/null)
      _check_one_binary_path "$tool_name" "$bp_path"
    elif [[ "$binary_path_type" == "array" ]]; then
      local bp_count bp_i
      bp_count=$(jq '.binary_path | length' <<<"$entry" 2>/dev/null)
      for (( bp_i=0; bp_i<bp_count; bp_i++ )); do
        local bp_path_item
        bp_path_item=$(jq -r ".binary_path[${bp_i}]" <<<"$entry" 2>/dev/null)
        _check_one_binary_path "$tool_name" "$bp_path_item"
      done
    fi
    # Non-string/non-array binary_path is caught by schema validator; skip here.
  done

  [[ "$_violation" -eq 0 ]]
}


# _manifest_check_mount_root_owned — rip-cage-wlwc.3 / ADR-027 D1
#
# OWNERSHIP-EFFECT assertion: for every mount entry in the manifest that declares
# root_owned_required: true, inspect the ACTUAL asset inside the already-built
# image using `docker run --rm <image> stat -c '%U %a' <dest>` and reject any
# mount asset that is NOT owned by root OR that is writable by the agent user
# (group-write or other-write bit set).
#
# This is the GENERIC per-asset root-owned validator — it keys off the mount
# declaration field `root_owned_required`, not any per-agent archetype field.
# This is a deliberate design choice (rip-cage-wlwc.3): the validator keys only
# off mount-level declarations, not archetype-level or agent-specific fields.
#
# Sibling to _manifest_check_binary_root_owned (which keys off TOOL binary paths).
#
# A mount entry that does NOT declare root_owned_required: true is SKIPPED.
# A mount entry that declares root_owned_required: false is also SKIPPED.
# Only root_owned_required: true triggers the ownership-effect check.
#
# Parameters:
#   $1  image_tag — Docker image tag to inspect (e.g. "rip-cage:latest")
#
# Stdout: (none)
# Stderr: error messages on violation
# Returns: 0 if all declared root_owned_required assets pass, 1 on violation.
_manifest_check_mount_root_owned() {
  local _image_tag="${1:-rip-cage:latest}"

  local manifest_json
  if ! manifest_json=$(_manifest_load); then
    return 1
  fi

  local count
  count=$(jq '.tools | length' <<<"$manifest_json" 2>/dev/null)
  if [[ -z "$count" || "$count" -eq 0 ]]; then
    return 0
  fi

  local _violation=0
  local idx
  for (( idx=0; idx<count; idx++ )); do
    local entry mounts_count midx
    entry=$(jq -c ".tools[${idx}]" <<<"$manifest_json" 2>/dev/null)

    mounts_count=$(jq '.mounts | length' <<<"$entry" 2>/dev/null)
    [[ -z "$mounts_count" || "$mounts_count" -eq 0 ]] && continue

    local tool_name
    tool_name=$(jq -r '.name // "unknown"' <<<"$entry" 2>/dev/null)

    for (( midx=0; midx<mounts_count; midx++ )); do
      local root_owned_required_val root_owned_required_type
      root_owned_required_type=$(jq -r ".mounts[${midx}] | if has(\"root_owned_required\") then (.root_owned_required | type) else \"absent\" end" <<<"$entry" 2>/dev/null)
      # Skip: root_owned_required absent or not a boolean true
      [[ "$root_owned_required_type" != "boolean" ]] && continue
      root_owned_required_val=$(jq -r ".mounts[${midx}].root_owned_required" <<<"$entry" 2>/dev/null)
      [[ "$root_owned_required_val" != "true" ]] && continue

      # This mount declared root_owned_required: true — check ownership inside the image.
      local mount_dest
      mount_dest=$(jq -r ".mounts[${midx}].dest // \"\"" <<<"$entry" 2>/dev/null)
      if [[ -z "$mount_dest" || "$mount_dest" == "null" ]]; then
        echo "Error: manifest tool '${tool_name}' mounts[${midx}]: root_owned_required: true but 'dest' is empty — cannot check ownership." >&2
        _violation=1
        continue
      fi

      # Effect-based check: inspect the actual asset inside the built image.
      # stat -c '%U %a' prints: owner_name octal_mode (e.g. "root 755")
      local stat_out
      if ! stat_out=$(docker run --rm "$_image_tag" stat -c '%U %a' "$mount_dest" 2>/dev/null); then
        echo "Error: manifest tool '${tool_name}' mounts[${midx}] dest '${mount_dest}': root_owned_required: true but could not stat path inside image '${_image_tag}' — asset may be absent or image not built. (rip-cage-wlwc.3 / ADR-027 D1)" >&2
        _violation=1
        continue
      fi

      local stat_owner stat_mode
      stat_owner=$(awk '{print $1}' <<<"$stat_out")
      stat_mode=$(awk '{print $2}' <<<"$stat_out")

      # Owner MUST be root.
      if [[ "$stat_owner" != "root" ]]; then
        echo "Error: manifest tool '${tool_name}' mounts[${midx}] dest '${mount_dest}' is owned by '${stat_owner}' (not root). A root_owned_required asset must be root-owned — an agent-writable asset is fail-open against the ro-mount guarantee. (rip-cage-wlwc.3 / ADR-027 D1)" >&2
        _violation=1
      fi

      # Mode: group-write or other-write bit must NOT be set.
      # Normalize to exactly 3 digits (drop leading "0" prefix if stat gives 4).
      local mode_3
      mode_3="${stat_mode: -3}"
      local group_digit other_digit writable
      group_digit="${mode_3:1:1}"
      other_digit="${mode_3:2:1}"
      writable=0
      case "$group_digit" in 2|3|6|7) writable=1 ;; esac
      case "$other_digit" in 2|3|6|7) writable=1 ;; esac
      if [[ "$writable" -eq 1 ]]; then
        echo "Error: manifest tool '${tool_name}' mounts[${midx}] dest '${mount_dest}' has mode '${stat_mode}' which is group/other-writable. A root_owned_required asset must not be agent-writable (fail-open against ro-mount guarantee). (rip-cage-wlwc.3 / ADR-027 D1)" >&2
        _violation=1
      fi
    done
  done

  [[ "$_violation" -eq 0 ]]
}

