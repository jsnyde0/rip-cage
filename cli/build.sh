#!/usr/bin/env bash
# cli/build.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


cmd_generate_dockerfile() {
  # Expose the composed Dockerfile for CI/release use (rip-cage-wlwc.12).
  # Reads RC_MANIFEST_GLOBAL (default: ~/.config/rip-cage/tools.yaml) and emits
  # the composed Dockerfile to stdout. The caller redirects to a file and passes
  # it to docker build --file.
  #
  # This is NOT a compose mechanism — it simply exposes _manifest_build_dockerfile_path
  # (already used by cmd_build) so that CI can generate the composed Dockerfile without
  # also running docker build. No auto-wiring; no config-merge; the agent/CI provides
  # the manifest, this function outputs the Dockerfile.
  #
  # Usage: RC_MANIFEST_GLOBAL=manifest/default-tools.yaml ./rc generate-dockerfile > Dockerfile.composed
  local _df_path
  _df_path=$(_manifest_build_dockerfile_path "${SCRIPT_DIR}/cage/Dockerfile") || {
    echo "Error: failed to resolve composed Dockerfile from manifest." >&2
    return 1
  }
  cat "$_df_path"
  # Clean up temp file if one was created (path differs from original Dockerfile).
  if [[ "$_df_path" != "${SCRIPT_DIR}/cage/Dockerfile" ]]; then
    rm -f "$_df_path"
  fi
}


cmd_build() {
  # Ensure the manifest is seeded (first-run: writes defaults to ~/.config/rip-cage/tools.yaml).
  _manifest_ensure_seeded

  # rip-cage-6vt9: seed-drift detection — informational, never blocks the
  # build. Warns when the manifest's seed provenance stamp is stale relative
  # to the CURRENT shipped manifest/default-tools.yaml (or, unstamped, when its
  # freshness is simply unknown). See the section header above
  # _manifest_check_seed_drift for the full design.
  _manifest_check_seed_drift "$(_manifest_global_path)"

  # rip-cage-4c5.3: IOC pre-build check — reject any manifest egress: entry naming
  # a host on the IOC denylist BEFORE any Docker call (ADR-005 D3 / ADR-012 D1).
  # Fires fail-loud, naming the offending host, so the human knows what to fix.
  if ! _manifest_check_ioc_egress "${SCRIPT_DIR}/cage/egress/egress-rules.yaml"; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "Manifest declares an IOC-denylisted egress host — rc build refused (ADR-005 D3 / ADR-012 D1)" "MANIFEST_IOC_EGRESS_DENIED"
    fi
    return 1
  fi

  # Resolve the Dockerfile to use: original when all tools are bundled (D8),
  # or a temp Dockerfile with extra manifest-generated RUN steps for non-bundled tools.
  local _dockerfile _tmp_dockerfile
  _dockerfile=""
  _tmp_dockerfile=""
  _dockerfile=$(_manifest_build_dockerfile_path "${SCRIPT_DIR}/cage/Dockerfile") || {
    echo "Error: failed to resolve Dockerfile from manifest." >&2
    return 1
  }
  # Track a temp file for cleanup (empty means original was used).
  if [[ "$_dockerfile" != "${SCRIPT_DIR}/cage/Dockerfile" ]]; then
    _tmp_dockerfile="$_dockerfile"
  fi

  # rip-cage-buuo.3: build-isolation assertion — BEFORE docker build.
  # Assert that the generated builder stages do not bind-mount host paths.
  # Only applies when a manifest-generated Dockerfile was produced (non-bundled tools).
  # The original (unmodified) Dockerfile has no rc-builder-* stages, so this check
  # is a no-op when all tools are bundled (no temp Dockerfile → skipped).
  if [[ -n "$_tmp_dockerfile" ]]; then
    if ! _manifest_check_build_isolation "$_tmp_dockerfile"; then
      if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        json_error "Manifest builder stage violates build-isolation invariant — rc build refused (ADR-005 D9 / ADR-024 build-isolation)" "MANIFEST_BUILD_ISOLATION_VIOLATED"
      fi
      [[ -n "$_tmp_dockerfile" ]] && rm -f "$_tmp_dockerfile"
      return 1
    fi
  fi

  log "Building $IMAGE from ${_dockerfile}..."
  local _build_ok=0
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    if docker build -t "$IMAGE" --build-arg "RC_VERSION=${RC_VERSION}" -f "$_dockerfile" "$@" "$SCRIPT_DIR" >/dev/null 2>&1; then
      # rip-cage-buuo.3: binary-root-owned assertion — AFTER successful docker build.
      # Inspect the actual installed binary in the built image.
      # rip-cage-wlwc.3: ALSO assert per-asset root_owned_required mount ownership-effect
      # (ADR-027 D1) — sibling to _manifest_check_binary_root_owned, same gate, same
      # fail-closed semantics. Both validators run on every build entrypoint.
      if ! _manifest_check_binary_root_owned "$IMAGE" || ! _manifest_check_mount_root_owned "$IMAGE"; then
        [[ -n "$_tmp_dockerfile" ]] && rm -f "$_tmp_dockerfile"
        # Untag the violating image so a subsequent `rc up` / `docker run rip-cage:latest`
        # cannot use the tainted build. Fail-closed: remove before aborting (ADR-001).
        docker image rm "$IMAGE" 2>/dev/null || true
        json_error "Manifest tool binary is not root-owned/agent-writable, or a root_owned_required mount asset is not root-owned — safety floor violated (ADR-005 D9/D11, ADR-024, ADR-027 D1)" "MANIFEST_BINARY_NOT_ROOT_OWNED"
      fi
      # rip-cage-jnvb / D-d: informational, non-blocking warning (stderr, so
      # stdout JSON stays parseable) when existing rc containers are pinned
      # to a different image than the one just built — rc up will refuse to
      # resume them (see _up_resolve_resume_image_drift_stopped).
      _build_warn_stale_containers
      # rip-cage-7dkq (S1, msb migration testability root): one-time
      # docker save -> msb load conversion. Best-effort (see _build_msb_load);
      # its exit code is deliberately not propagated into rc build's own.
      _build_msb_load || true
      jq -nc --arg img "$IMAGE" '{image: $img, action: "built", status: "success"}'
    else
      [[ -n "$_tmp_dockerfile" ]] && rm -f "$_tmp_dockerfile"
      json_error "Build failed" "BUILD_FAILED"
    fi
  else
    docker build -t "$IMAGE" --build-arg "RC_VERSION=${RC_VERSION}" -f "$_dockerfile" "$@" "$SCRIPT_DIR" || _build_ok=$?
    # rip-cage-buuo.3: binary-root-owned assertion — AFTER successful docker build.
    # rip-cage-wlwc.3: ALSO assert per-asset root_owned_required mount ownership-effect
    # (ADR-027 D1) — entrypoint-completeness: same two validators on all build paths.
    if [[ "$_build_ok" -eq 0 ]]; then
      if ! _manifest_check_binary_root_owned "$IMAGE" || ! _manifest_check_mount_root_owned "$IMAGE"; then
        [[ -n "$_tmp_dockerfile" ]] && rm -f "$_tmp_dockerfile"
        # Untag the violating image so a subsequent `rc up` / `docker run rip-cage:latest`
        # cannot use the tainted build. Fail-closed: remove before aborting (ADR-001).
        docker image rm "$IMAGE" 2>/dev/null || true
        return 1
      fi
      # rip-cage-jnvb / D-d: same informational warning on the human-mode build path.
      _build_warn_stale_containers
      # rip-cage-7dkq (S1, msb migration testability root): one-time
      # docker save -> msb load conversion. Best-effort (see _build_msb_load);
      # its exit code is deliberately not propagated into rc build's own.
      _build_msb_load || true
    fi
  fi
  [[ -n "$_tmp_dockerfile" ]] && rm -f "$_tmp_dockerfile"
  return "$_build_ok"
}


# _build_warn_stale_containers (rip-cage-jnvb / D-d) — after a successful
# `rc build`, warn (informational, non-blocking) about existing rc-managed
# cages still pinned to an older image than the one just built. `rc up`
# will refuse to resume them (_up_resolve_resume_image_drift_stopped) until
# `rc destroy` + `rc up` (or the correct RC_IMAGE).
#
# rip-cage-tsf2.1: REWRITTEN onto msb — was `docker ps -a --filter
# label=rc.source.path` + `docker inspect --format '{{.Image}}'`. Enumerates
# via the same msb primitives cli/ls.sh's _rc_ls_enumerate uses (msb list +
# _msb_inspect_json), and compares each real cage's STORED image digest
# (_msb_sandbox_image_digest) against the just-built image's REAL current
# digest in msb's local cache (_msb_current_image_digest) — the same digest
# comparator cli/up.sh's _up_image_drift_status already trusts for the
# single-cage resume-time check.
_build_warn_stale_containers() {
  local _just_built_digest
  _just_built_digest=$(_msb_current_image_digest "$IMAGE" 2>/dev/null) || return 0
  [[ -z "$_just_built_digest" ]] && return 0
  local _names_json
  _names_json=$(msb list --format json 2>/dev/null) || return 0
  [[ -z "$_names_json" || "$_names_json" == "[]" ]] && return 0
  local _bwsc_name _bwsc_src _bwsc_digest
  while IFS= read -r _bwsc_name; do
    [[ -z "$_bwsc_name" ]] && continue
    _bwsc_src=$(_msb_label "$_bwsc_name" "rc.source.path" 2>/dev/null || true)
    [[ -z "$_bwsc_src" ]] && continue  # not rc-managed
    # Deliberately NOT _up_image_drift_status here: that resolver is shaped
    # for a single named container with an abort/warn decision (per D-b/D-c),
    # not a fan-out enumeration over every rc container — a silent `continue`
    # on inspect failure is the right per-container fallback for a warning
    # sweep, which doesn't fit the resolver's status-code contract. Do not
    # "fix" this into a third derivation of the compare — see the M1 note on
    # rip-cage-jnvb (bd memory rip-cage-mount-shape-label-lock-pattern family).
    _bwsc_digest=$(_msb_sandbox_image_digest "$_bwsc_name" 2>/dev/null) || continue
    if [[ -n "$_bwsc_digest" && "$_bwsc_digest" != "$_just_built_digest" ]]; then
      echo "Warning: container '${_bwsc_name}' was created from a different image than the one just built — rc up will refuse to resume it (rc destroy ${_bwsc_name} first); if a cage was intentionally pinned via RC_IMAGE, ignore this for it." >&2
    fi
  done < <(jq -r '.[].name' <<<"$_names_json" 2>/dev/null)
}


# _build_msb_load — one-time image-format conversion (docker save -> msb
# load) so a cage can boot from the just-built image via microsandbox (msb),
# the isolation-primitive migration's testability root (rip-cage-7dkq / S1,
# rip-cage-tsf2 §8b: "image is the artifact" + "one-time msb load adoption
# step"). Called at the end of a successful `rc build`.
#
# Best-effort by design: during the migration, most hosts do not have `msb`
# installed yet (rc up / rc create still run on Docker until S6 lands), so a
# missing `msb` binary is a silent no-op -- NOT a build failure. If `msb` IS
# present but the load step itself fails, that's a real problem and is
# surfaced loud on stderr; it still does not fail `rc build` overall, since
# the Docker image remains the primary build artifact.
#
# Saves to a temp file (msb load -i <path>) rather than piping, so the saved
# archive's size can be sanity-checked BEFORE ever touching msb --
# _MSB_LOAD_MIN_BYTES (default 1 MiB; overridable for testing) guards against
# every ad-hoc fake-docker PATH-shim fixture across this repo's test suite
# (most were written before msb existed and only fake `docker build`/`image
# inspect`/`run`, not `save`): on a host that has msb genuinely installed,
# such a fixture's `docker save` would otherwise produce a near-empty/garbage
# archive that gets handed to a REAL msb load, breaking fixtures that assert
# clean stderr with a spurious warning. Below the threshold, this is silently
# treated as "not a real build" and skipped -- no warning (there is nothing
# actionable to tell the operator; a real build's docker save is always many
# MB). rip-cage-7dkq: found live via the golden-master harness +
# test-manifest-seed-drift.sh both breaking during this bead's own
# verification (their fake-docker PATH shims never implement `save` for
# real, so `docker save` fails/returns near-nothing on those fixtures);
# regression-guarded by tests/test-build-msb-load.sh T5.
#
# Parameters: none (uses global $IMAGE).
# Returns: 0 if msb is absent, the saved archive is implausibly small (not a
# real build), or the load succeeded. 1 (with a loud stderr warning naming
# the image) if msb is present, the archive looks real, but the load failed.
_build_msb_load() {
  command -v msb >/dev/null 2>&1 || return 0

  local _tar
  _tar=$(mktemp -t "rc-msb-load.XXXXXX") || return 0
  if ! docker save "$IMAGE" -o "$_tar" >/dev/null 2>&1; then
    rm -f "$_tar"
    return 0
  fi

  local _tar_bytes
  _tar_bytes=$(wc -c < "$_tar" 2>/dev/null | tr -d ' ')
  local _min_bytes="${_MSB_LOAD_MIN_BYTES:-1048576}"
  if [[ -z "$_tar_bytes" || "$_tar_bytes" -lt "$_min_bytes" ]]; then
    rm -f "$_tar"
    return 0
  fi

  if ! msb load --tag "$IMAGE" -i "$_tar" >/dev/null 2>&1; then
    rm -f "$_tar"
    echo "Warning: 'msb load' failed for '${IMAGE}' after a successful docker build — msb-based tooling (msb run/exec) will not see this image until this is fixed. Run 'docker save ${IMAGE} | msb load --tag ${IMAGE}' manually for diagnostics." >&2
    return 1
  fi
  rm -f "$_tar"
  return 0
}


# _image_is_current — returns 0 if local rip-cage:latest carries an
# org.opencontainers.image.version label that matches RC_VERSION.
# Returns 1 (stale) if the label is missing, empty, or mismatched.
# When RC_VERSION is "unknown" (VERSION file absent / malformed checkout),
# returns 0 unconditionally — we can't meaningfully compare, so we skip
# the staleness check rather than silently re-provisioning every run.
# ADR-008 D6.
_image_is_current() {
  # Cannot compare without a known version — treat as current.
  if [[ "$RC_VERSION" == "unknown" ]]; then
    return 0
  fi
  local label
  label=$(docker image inspect "$IMAGE" \
    --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null) || return 1
  # docker returns "<no value>" when label key is absent
  if [[ "$label" == "<no value>" || -z "$label" ]]; then
    return 1
  fi
  [[ "$label" == "$RC_VERSION" ]]
}


# _pull_or_build — auto-provision the rip-cage image, pulling from GHCR when
# RIP_CAGE_IMAGE_REGISTRY is set (default ghcr.io/jsnyde0/rip-cage), falling
# back to local docker build on pull failure. Used by cmd_up's auto-build
# branch. Explicit `rc build` (cmd_build) is unchanged and always builds.
# ADR-008 D6.
#
# Manifest integration (rip-cage-4c5.2): the local-build fallback resolves the
# Dockerfile through _manifest_build_dockerfile_path so that any manifest-defined
# non-bundled TOOL entries are baked in.  The pull path is unaffected (the pulled
# image is a pre-built release image; manifest-driven tools require an explicit
# `rc build`).
# _pull_or_build_local — shared from-source local build helper for _pull_or_build.
# Resolves the Dockerfile, runs BOTH D11 validators (build-isolation pre-build and
# binary-root-owned post-build) with the same fail-closed semantics as cmd_build,
# then returns the build exit code.
# rip-cage-buuo.6 F1: wires the ADR-005 D11 FIRM validators into the auto-build path
# so that `rc up` without a prior `rc build` never bypasses D9/D11 enforcement.
_pull_or_build_local() {
  local _pob_dockerfile _pob_tmp
  _pob_dockerfile=""
  _pob_tmp=""
  _pob_dockerfile=$(_manifest_build_dockerfile_path "${SCRIPT_DIR}/cage/Dockerfile") || {
    echo "Error: failed to resolve Dockerfile from manifest." >&2
    return 1
  }
  if [[ "$_pob_dockerfile" != "${SCRIPT_DIR}/cage/Dockerfile" ]]; then
    _pob_tmp="$_pob_dockerfile"
  fi

  # rip-cage-buuo.6 F1: build-isolation assertion — BEFORE docker build.
  # Same semantics as cmd_build: only fires when a manifest-generated Dockerfile
  # was produced (non-bundled tools; _pob_tmp non-empty).
  if [[ -n "$_pob_tmp" ]]; then
    if ! _manifest_check_build_isolation "$_pob_tmp"; then
      echo "Error: Manifest builder stage violates build-isolation invariant — rc up auto-build refused (ADR-005 D9 / ADR-024 build-isolation)" >&2
      [[ -n "$_pob_tmp" ]] && rm -f "$_pob_tmp"
      return 1
    fi
  fi

  local _pob_exit=0
  docker build -t "$IMAGE" --build-arg "RC_VERSION=${RC_VERSION}" -f "$_pob_dockerfile" "$SCRIPT_DIR" || _pob_exit=$?

  # rip-cage-buuo.6 F1: binary-root-owned assertion — AFTER docker build.
  # rip-cage-wlwc.3: ALSO assert per-asset root_owned_required mount ownership-effect
  # (ADR-027 D1) — both validators on all build paths (entrypoint-completeness).
  # Same semantics as cmd_build: untag tainted image on failure (fail-closed, ADR-001).
  if [[ "$_pob_exit" -eq 0 ]]; then
    if ! _manifest_check_binary_root_owned "$IMAGE" || ! _manifest_check_mount_root_owned "$IMAGE"; then
      [[ -n "$_pob_tmp" ]] && rm -f "$_pob_tmp"
      docker image rm "$IMAGE" 2>/dev/null || true
      return 1
    fi
  fi

  [[ -n "$_pob_tmp" ]] && rm -f "$_pob_tmp"
  return "$_pob_exit"
}


_pull_or_build() {
  if [[ -z "${RIP_CAGE_IMAGE_REGISTRY}" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo '{"status":"building","reason":"registry_opt_out","message":"Building rip-cage image locally (RIP_CAGE_IMAGE_REGISTRY unset)"}' >&2
    else
      log "Building rip-cage image locally (RIP_CAGE_IMAGE_REGISTRY unset, takes a few minutes)..."
    fi
    _pull_or_build_local
    return $?
  fi
  local pull_ref="${RIP_CAGE_IMAGE_REGISTRY}:${RC_VERSION}"
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -nc --arg image "$pull_ref" '{status:"pulling", image:$image, message:"Pulling pre-built image from GHCR (first run only, ~30s)"}' >&2
  else
    log "Pulling ${pull_ref} (first run only, ~30s)..."
  fi
  if docker pull "${pull_ref}" >&2; then
    if docker tag "${pull_ref}" "$IMAGE" >&2; then
      return 0
    fi
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo '{"status":"building","reason":"retag_failed","message":"Pulled image but retag failed - falling back to local build"}' >&2
    else
      log "Pulled image but retag failed - falling back to local build..."
    fi
  else
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo '{"status":"building","reason":"pull_failed","message":"Pull failed (image unavailable, offline, or auth required) - building locally"}' >&2
    else
      log "Pull failed (image unavailable, offline, or auth required) - building locally (this takes a few minutes)..."
    fi
  fi
  _pull_or_build_local
  return $?
}


# _manifest_check_build_isolation — ADR-005 D9 / ADR-024 / rip-cage-buuo.3
#
# Assert that the generated Dockerfile's builder stages cannot reach the host.
# Specifically: within any rc-builder-* stage, there must be NO:
#   - RUN --mount=type=bind with an absolute src= path (host-path leak)
#   - VOLUME directive (host-path leak via Docker volume mount)
#
# The builder stage today uses only COPY <build_script> /rc-build/build.sh
# (copies from the build context, NOT a host bind mount) and RUN sh /rc-build/build.sh
# (runs inside the isolated layer). This assertion guards against a future
# manifest/codegen path that would BREAK that isolation (ADR-002 multi-stage).
#
# Fires BEFORE docker build — static analysis of the generated Dockerfile.
#
# Parameters:
#   $1  dockerfile_path — path to the generated Dockerfile to inspect
#
# Returns: 0 if isolated clean, 1 with fail-loud error if a host-access path found.
_manifest_check_build_isolation() {
  local _dockerfile="${1:-}"

  if [[ -z "$_dockerfile" || ! -f "$_dockerfile" ]]; then
    # No manifest-generated Dockerfile (all bundled, D8) — nothing to check.
    return 0
  fi

  # Track whether we are inside an rc-builder-* stage so we check only
  # the isolated builder stages, not the runtime stage.
  local _in_builder_stage=0
  local _stage_name=""
  local _line_no=0
  local _violation=0

  while IFS= read -r _line; do
    _line_no=$(( _line_no + 1 ))

    # Detect stage transitions: "FROM ... AS <name>"
    if [[ "$_line" =~ ^[[:space:]]*FROM[[:space:]] ]]; then
      local _as_label
      # Extract the AS label if present (case-insensitive AS).
      _as_label=$(printf '%s' "$_line" | grep -oiE 'AS [a-z0-9_-]+' | awk '{print $2}' | tr '[:upper:]' '[:lower:]' || true)
      if [[ "$_as_label" == rc-builder-* ]]; then
        _in_builder_stage=1
        _stage_name="$_as_label"
      else
        _in_builder_stage=0
        _stage_name=""
      fi
      continue
    fi

    [[ "$_in_builder_stage" -eq 0 ]] && continue

    # Check for RUN --mount=type=bind with an absolute src= path (host-path leak).
    # Pattern: RUN --mount=type=bind,src=/ or RUN --mount=type=bind,...,src=/...
    # An absolute src= means the build daemon is binding a HOST path into the build step.
    if [[ "$_line" =~ ^[[:space:]]*RUN[[:space:]].*--mount=type=bind ]]; then
      # Extract src= value.
      local _src_val
      _src_val=$(printf '%s' "$_line" | grep -oE 'src=[^, ]+' | head -1 | cut -d= -f2 || true)
      if [[ "$_src_val" == /* ]]; then
        echo "Error: manifest builder stage '${_stage_name}' (line ${_line_no}) contains RUN --mount=type=bind,src=${_src_val} — absolute host path in builder stage violates build-isolation invariant (ADR-005 D9 / ADR-024 build-isolation). Builder stages must not bind-mount host paths." >&2
        _violation=1
      fi
    fi

    # Check for RUN --mount=type=ssh (injects host SSH agent socket into build step).
    # This gives the builder stage direct access to the host SSH agent — a host-resource
    # access vector that violates build-isolation (ADR-005 D9 / ADR-024).
    if [[ "$_line" =~ ^[[:space:]]*RUN[[:space:]].*--mount=type=ssh ]]; then
      echo "Error: manifest builder stage '${_stage_name}' (line ${_line_no}) contains RUN --mount=type=ssh — SSH agent socket injection in a builder stage violates build-isolation invariant (ADR-005 D9 / ADR-024 build-isolation). Builder stages must not access host resources." >&2
      _violation=1
    fi

    # Check for RUN --mount=type=secret (exposes host build secrets into build step).
    # This gives the builder stage access to host secrets (API keys, credentials, etc.) —
    # a host-resource access vector that violates build-isolation (ADR-005 D9 / ADR-024).
    if [[ "$_line" =~ ^[[:space:]]*RUN[[:space:]].*--mount=type=secret ]]; then
      echo "Error: manifest builder stage '${_stage_name}' (line ${_line_no}) contains RUN --mount=type=secret — host secret injection in a builder stage violates build-isolation invariant (ADR-005 D9 / ADR-024 build-isolation). Builder stages must not access host resources." >&2
      _violation=1
    fi

    # Check for VOLUME directive inside a builder stage (host-volume access path).
    if [[ "$_line" =~ ^[[:space:]]*VOLUME[[:space:]] ]]; then
      echo "Error: manifest builder stage '${_stage_name}' (line ${_line_no}) contains a VOLUME directive — VOLUME in a builder stage introduces host-path access (ADR-005 D9 / ADR-024 build-isolation). Builder stages must be fully isolated." >&2
      _violation=1
    fi
  done < "$_dockerfile"

  [[ "$_violation" -eq 0 ]]
}

