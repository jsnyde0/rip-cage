#!/usr/bin/env bash
# cli/build.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# _build_reject_arg <message> <json_code> -- shared fail-loud emitter for
# cmd_build's argument checks (rip-cage-zqjz.2). Prints via json_error (JSON
# mode -- which itself calls `exit 1`, terminating the process immediately,
# matching every pre-existing reject site's behavior) or a plain `Error: ...`
# line on stderr (human mode). A bash function's own `return` cannot force its
# CALLER to return, so every call site must follow this with an explicit
# `return 1` of its own (a no-op in JSON mode, since json_error already exited).
_build_reject_arg() {
  local _msg="$1" _code="$2"
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    json_error "$_msg" "$_code"
  fi
  echo "Error: $_msg" >&2
}


# _build_cage_config_paths -- echo every cage config rc can see on this host,
# one per line. $RC_CAGE_CONF when set, otherwise every *.yaml / *.yml under the
# operator's host config dir. Silent when there are none.
_build_cage_config_paths() {
  if [[ -n "${RC_CAGE_CONF:-}" ]]; then
    [[ -f "${RC_CAGE_CONF}" ]] && printf '%s\n' "${RC_CAGE_CONF}"
    return 0
  fi
  local _dir="${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/projects"
  [[ -d "$_dir" ]] || return 0
  local _f
  for _f in "$_dir"/*.yaml "$_dir"/*.yml; do
    [[ -f "$_f" ]] && printf '%s\n' "$_f"
  done
  return 0
}


# _build_dockerfile_outside_cage_mounts <resolved_dockerfile_path>
#
# ADR-031 D5(a)/D5(c), FIRM: the Dockerfile is a composition input, so it is
# authored where the caged agent cannot reach it. Refuse -- non-zero, before any
# docker call, with NO opt-out flag -- when the path resolves inside a tree some
# cage config mounts into a cage. The opt-out IS the vector: an agent that can
# point `rc build` at a path it controls has written its own image.
#
# Sibling of _protected_paths_conf_outside_mounts, which enforces the same rule
# on the cage config itself; it supplies the mount reader, so the two agree on
# what "a cage mount" means by construction rather than by two parsers staying
# in step.
#
# FAIL-CLOSED on unreadable data too: a cage config whose mounts cannot be
# parsed leaves the question unanswered, and an unanswered containment question
# is a refusal, not a pass.
_build_dockerfile_outside_cage_mounts() {
  local _df_real="$1"
  local _conf _mounts _host _guest _host_real

  while IFS= read -r _conf; do
    [[ -z "$_conf" ]] && continue
    if ! _mounts="$(_protected_paths_conf_bind_mounts "$_conf" 2>/dev/null)"; then
      _build_reject_arg "rc build: could not read the mounts declared in the cage config ${_conf}, so it cannot be shown that '${_df_real}' sits outside every cage mount. Refusing before any docker call (ADR-031 D5(a), fail-closed, no opt-out). Fix the config's mounts: block, or move the Dockerfile somewhere no cage config can reach." "BUILD_FILE_MOUNT_CHECK_UNREADABLE"
      return 1
    fi
    [[ -z "$_mounts" ]] && continue
    while IFS=$'\t' read -r _host _guest; do
      [[ -z "$_host" ]] && continue
      _host_real="$(cd "$_host" 2>/dev/null && pwd -P)" || continue
      if [[ "$_df_real" == "$_host_real" || "$_df_real" == "$_host_real"/* ]]; then
        _build_reject_arg "rc build: the Dockerfile '${_df_real}' sits inside ${_host}, which the cage config ${_conf} mounts into a cage. Refusing before any docker call: an agent inside that cage could write the Dockerfile its own next image is built from (ADR-031 D5(a)). There is no opt-out flag -- move the Dockerfile outside every cage mount, for example to ${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/images/." "BUILD_FILE_INSIDE_CAGE_MOUNT"
        return 1
      fi
    done <<< "$_mounts"
  done < <(_build_cage_config_paths)
  return 0
}


# cmd_build -- build the cage image from ONE host-side Dockerfile.
#
# ADR-031 D5(c), FIRM: rc build accepts EXACTLY ONE user input, the Dockerfile
# path (`--file`, default: rc's own base Dockerfile), and hands docker a FIXED
# argv. Everything else in "$@" is rejected, fail-closed, before any docker call.
#
# WHY A FIXED ARGV RATHER THAN AN ALLOWLIST. The allowlist this replaces was
# defeated three times in three passes by three different mechanisms (-t is
# additive, so a caller tag co-tagged the default image; -f is last-wins, so a
# caller file swapped the recipe out from under the validator; -o redirects the
# build result away from the image store, so the post-build checks passed
# against a stale image while rc reported success). A fourth was found at the
# VALUE level, which no name-level allowlist can see: --build-arg
# BUILDKIT_SYNTAX=<image> replaces the Dockerfile frontend, i.e. the thing that
# interprets the Dockerfile. docker's flag surface evolves outside rc's control,
# so "unrecognized" has to mean "rejected".
#
# THE EXACT ARGV DOCKER RECEIVES:
#     docker build -f <path> --build-arg RC_VERSION=<version> -t <tag> <context>
# RC_VERSION is rc's own, read from the VERSION file beside rc, and is not
# reachable from any caller -- it is part of the fixed argv, not an exception to
# it (ADR-031 D5(c), clarified in place 2026-09-16; the label it bakes is what
# ADR-008 D6's staleness check reads). The tag is rc's $IMAGE. `rc build -t` is
# gone with the rest of the allowlist; RC_IMAGE is the documented test-only
# override that points the verb at a scratch tag.
#
# THE BUILD CONTEXT, in one sentence: the directory holding the resolved
# Dockerfile -- except when that resolved path IS rc's own base Dockerfile, whose
# context is the rc checkout root, because its COPY lines read cage/ and tests/.
# Keyed on the RESOLVED path, so `rc build --file <that same file>` behaves
# identically to plain `rc build`.
cmd_build() {
  local _bf_file="" _bf_file_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        if [[ $# -lt 2 ]]; then
          _build_reject_arg "rc build: ${1} requires a value" "BUILD_FILE_MISSING_VALUE"
          return 1
        fi
        _bf_file="$2"
        _bf_file_set=1
        shift 2
        ;;
      --file=*)
        _bf_file="${1#--file=}"
        _bf_file_set=1
        shift
        ;;
      -f=*)
        _bf_file="${1#-f=}"
        _bf_file_set=1
        shift
        ;;
      -f*)
        # Attached short-flag value (`-fVALUE`), docker/pflag's own spelling.
        _bf_file="${1#-f}"
        _bf_file_set=1
        shift
        ;;
      *)
        _build_reject_arg "rc build: '$1' is not accepted -- rc build takes exactly one input, --file <path to a host-side Dockerfile>, and passes docker a fixed argv (ADR-031 D5(c)). There is no escape hatch and no flag passthrough: put whatever you were trying to express INTO the Dockerfile, which is yours to write. To build under a different tag, set RC_IMAGE." "BUILD_ARG_NOT_ALLOWED"
        return 1
        ;;
    esac
  done

  if [[ "$_bf_file_set" -eq 1 && -z "$_bf_file" ]]; then
    _build_reject_arg "rc build: --file value must not be empty" "BUILD_FILE_EMPTY_VALUE"
    return 1
  fi

  local _bf_default="${SCRIPT_DIR}/cage/Dockerfile"
  [[ "$_bf_file_set" -eq 0 ]] && _bf_file="$_bf_default"

  if [[ ! -f "$_bf_file" ]]; then
    _build_reject_arg "rc build: no Dockerfile at '${_bf_file}'." "BUILD_FILE_NOT_FOUND"
    return 1
  fi

  # Resolve to a real path BEFORE the containment check -- a relative path or a
  # symlink that lands inside a cage mount must be caught by where it resolves,
  # not by how it was spelled (the realpath-first rule ADR-023 D6 already
  # applies to mount sources).
  local _bf_dir _bf_real
  if ! _bf_dir="$(cd "$(dirname "$_bf_file")" 2>/dev/null && pwd -P)"; then
    _build_reject_arg "rc build: could not resolve the directory of '${_bf_file}'." "BUILD_FILE_UNRESOLVABLE"
    return 1
  fi
  _bf_real="${_bf_dir}/$(basename "$_bf_file")"

  local _bf_default_real="$_bf_default"
  local _bf_default_dir
  if _bf_default_dir="$(cd "$(dirname "$_bf_default")" 2>/dev/null && pwd -P)"; then
    _bf_default_real="${_bf_default_dir}/$(basename "$_bf_default")"
  fi

  local _bf_context
  if [[ "$_bf_real" == "$_bf_default_real" ]]; then
    _bf_context="$SCRIPT_DIR"
  else
    _bf_context="$_bf_dir"
  fi

  # FAIL-CLOSED, before any docker call, no opt-out (ADR-031 D5(a)).
  _build_dockerfile_outside_cage_mounts "$_bf_real" || return 1

  log "Building $IMAGE from ${_bf_real}..."
  local _build_ok=0
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    if docker build -f "$_bf_real" --build-arg "RC_VERSION=${RC_VERSION}" -t "$IMAGE" "$_bf_context" >/dev/null 2>&1; then
      # rip-cage-jnvb / D-d: informational, non-blocking warning (stderr, so
      # stdout JSON stays parseable) when existing rc cages are pinned to a
      # different image than the one just built -- rc up will refuse to resume
      # them (see _up_resolve_resume_image_drift_stopped).
      #
      # Skipped under RC_IMAGE: the warning's premise is "cages running the
      # image you just rebuilt", which does not hold for a scratch or fixture
      # tag. Every real cage is still pinned to whatever it actually runs,
      # untouched by this build. (Was keyed on a caller -t/--tag, rip-cage-fo4z
      # F7; that flag retired with the allowlist, RC_IMAGE is the same signal.)
      [[ -z "${RC_IMAGE:-}" ]] && _build_warn_stale_containers
      # rip-cage-7dkq (S1): one-time docker save -> msb load conversion.
      # Best-effort (see _build_msb_load); its exit code is deliberately not
      # propagated into rc build's own.
      _build_msb_load || true
      # rip-cage-7bs3: AFTER _build_msb_load, not before -- pre-load, msb's
      # cache still holds the PREVIOUS build, so a pre-load compare is
      # divergent by construction on every successful build. Advisory only.
      _msb_warn_image_layer_drift
      jq -nc --arg img "$IMAGE" '{image: $img, action: "built", status: "success"}'
    else
      json_error "Build failed" "BUILD_FAILED"
    fi
  else
    docker build -f "$_bf_real" --build-arg "RC_VERSION=${RC_VERSION}" -t "$IMAGE" "$_bf_context" || _build_ok=$?
    if [[ "$_build_ok" -eq 0 ]]; then
      # Same informational warning and same RC_IMAGE skip as the JSON path.
      [[ -z "${RC_IMAGE:-}" ]] && _build_warn_stale_containers
      _build_msb_load || true
      _msb_warn_image_layer_drift
    fi
  fi
  return "$_build_ok"
}


# _build_warn_stale_containers (rip-cage-jnvb / D-d) — after a successful
# `rc build`, warn (informational, non-blocking) about existing rc-managed
# cages still pinned to an older image than the one just built. `rc up`
# will refuse to resume them (_up_resolve_resume_image_drift_stopped) until
# `rc up --replace` (rip-cage-syzk: volume-preserving repair, repointed off
# `rc destroy`, and off the retired `rc reload` by rip-cage-ely4.10 — this is
# the FIRST of the three sites an operator sees this message at, right after
# the `rc build` that caused the drift) or the correct RC_IMAGE.
#
# rip-cage-tsf2.1: REWRITTEN onto msb — was `docker ps -a --filter
# label=rc.source.path` + `docker inspect --format '{{.Image}}'`. Enumerates
# via the same msb primitives the retired `rc ls` used (msb list +
# _msb_inspect_json), and compares each real cage's STORED image digest
# (_msb_sandbox_image_digest) against the just-built image's REAL current
# digest in msb's local cache (_msb_current_image_digest) — the same digest
# comparator cli/lib/msb_runtime.sh's _msb_image_drift_status already trusts
# for the single-cage resume-time check.
#
# rip-cage-5jrt: FAIL-LOUD rewrite. Before this bead, every early return
# below had the same shape — "missing reference data == nothing to warn
# about" — so a host where `msb image list` came back empty while live
# rc-managed cages existed produced total silence: image provenance was
# unverifiable and the operator was never told. Advisory posture is
# unchanged (brain:rip-cage ruling, 2026-09-03): this function must still
# NEVER change `rc build`'s exit code, gate the build, or abort — only its
# SILENCE on a data-unavailable path is the bug, not its non-blocking
# nature. Every early exit below is now classified inline as either
# "nothing to check" (legitimately silent — there is genuinely nothing to
# warn about) or "cannot check" (the data needed to answer the question is
# missing/unreadable — must emit, naming the affected cage(s) and why).
#
# The caller-side `[[ "$_bt_tag_set" -eq 0 ]] &&` guard at cli/build.sh:556
# and :582 (skip this whole function on a custom-tag build) was also
# classified during this bead's sweep and deliberately LEFT ALONE — it is
# rip-cage-fo4z F7's scope guard, not an early return inside this function,
# and out of this bead's scope.
_build_warn_stale_containers() {
  # NOTHING TO CHECK: msb isn't installed at all, so no msb-backed rc cage
  # could exist to warn about (matches _build_msb_load's own precedent,
  # cli/build.sh:673 `command -v msb >/dev/null 2>&1 || return 0` — without
  # this carve-out, every build on a Docker-only host would emit a spurious
  # "cannot determine" warning below).
  command -v msb >/dev/null 2>&1 || return 0

  # CANNOT CHECK: the just-built image's digest could not be read from
  # msb's local image cache — either `msb image list` itself failed/came
  # back empty (empty msb image index) or the digest lookup for $IMAGE
  # specifically came back empty. Do NOT return here: the whole point of
  # this bead is that a missing digest must still be reported, and doing so
  # requires naming the live cage(s) it affects — so fall through into the
  # same single-sourced enumeration used for the normal digest-compare path
  # below, and let the per-cage loop emit instead of bailing out blind.
  local _just_built_digest _bwsc_digest_unknown=0
  if ! _just_built_digest=$(_msb_current_image_digest "$IMAGE" 2>/dev/null); then
    _bwsc_digest_unknown=1
  elif [[ -z "$_just_built_digest" ]]; then
    _bwsc_digest_unknown=1
  fi

  local _names_json
  if ! _names_json=$(msb list --format json 2>/dev/null); then
    # CANNOT CHECK: `msb list` itself failed (msb is present per the carve-out
    # above, so this means something else — daemon down, transient error).
    # Unlike the digest-unknown case, there is no cage list to fall through
    # with here: enumeration is impossible, so no per-cage naming is
    # possible either. Emit one generic loud line rather than going silent.
    echo "Warning: could not determine image provenance for any rc-managed sandboxes — 'msb list' failed, so existing cages could not be enumerated to check whether they are pinned to a stale image." >&2
    return 0
  fi
  # NOTHING TO CHECK: msb reports zero sandboxes of any kind — there is
  # nothing (rc-managed or not) to warn about.
  [[ -z "$_names_json" || "$_names_json" == "[]" ]] && return 0

  local _bwsc_name _bwsc_src _bwsc_digest
  while IFS= read -r _bwsc_name; do
    [[ -z "$_bwsc_name" ]] && continue
    _bwsc_src=$(_msb_label "$_bwsc_name" "rc.source.path" 2>/dev/null || true)
    # NOTHING TO CHECK: no rc.source.path label means this sandbox isn't
    # rc-managed at all — it's not this function's concern either way.
    [[ -z "$_bwsc_src" ]] && continue

    if [[ "$_bwsc_digest_unknown" -eq 1 ]]; then
      echo "Warning: image provenance for container '${_bwsc_name}' could not be determined — the just-built image's digest could not be read from msb's local image cache (empty msb image index, or the digest lookup failed); run 'msb image list' to check, then re-run 'rc build' to refresh this warning." >&2
      continue
    fi

    # Deliberately NOT _msb_image_drift_status here: that comparator is shaped
    # for a single named container with an abort/warn decision (per D-b/D-c),
    # not a fan-out enumeration over every rc container — a per-container
    # fallback that still EMITS (rip-cage-5jrt; was a silent `continue`) on
    # inspect failure is the right shape for a warning sweep, which doesn't
    # fit the resolver's status-code contract. Do not "fix" this into a
    # third derivation of the compare — see the M1 note on rip-cage-jnvb
    # (bd memory rip-cage-mount-shape-label-lock-pattern family).
    if ! _bwsc_digest=$(_msb_sandbox_image_digest "$_bwsc_name" 2>/dev/null); then
      # CANNOT CHECK (per-cage): msb inspect failed for this one sandbox
      # (e.g. removed between `msb list` and this inspect — a TOCTOU race).
      echo "Warning: image provenance for container '${_bwsc_name}' could not be determined — 'msb inspect' failed for this sandbox." >&2
      continue
    fi
    if [[ -z "$_bwsc_digest" ]]; then
      # CANNOT CHECK (per-cage): inspect succeeded but returned no digest.
      echo "Warning: image provenance for container '${_bwsc_name}' could not be determined — 'msb inspect' returned an empty image digest for this sandbox." >&2
      continue
    fi
    if [[ "$_bwsc_digest" != "$_just_built_digest" ]]; then
      echo "Warning: container '${_bwsc_name}' was created from a different image than the one just built — rc up will refuse to resume it (rc up --replace <its workspace> moves it onto the current image; named volumes and host mounts survive, the guest's ephemeral overlay does not); if a cage was intentionally pinned via RC_IMAGE, ignore this for it." >&2
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
# rip-cage-528o: publishes _RC_MSB_LOAD_SUCCEEDED (0/1) as the
# "was this a REAL build whose load actually ran and reported success?"
# signal consumed by _msb_warn_image_layer_drift (cli/lib/msb_runtime.sh).
# It is set to 0 at entry and to 1 on exactly ONE path -- the one below
# where `msb load` returned success. That is what lets the post-load
# emitter distinguish "the load silently failed to land" (loud) from "this
# was a fixture/Docker-only host that never produced a real archive"
# (silent), which is the tension this bead's DESIGN names. Every early
# return below therefore leaves it 0 on purpose.
#
# Parameters: none (uses global $IMAGE).
# Returns: 0 on ALL FIVE non-failure paths, enumerated here one-for-one with
# the classified early exits in the body below (rip-cage-528o fix round,
# adversarial finding F2 -- this line previously named only three of them,
# silently omitting the two the classification block counts as paths 2 and
# 3): (1) msb is absent, (2) mktemp could not create the scratch archive,
# (3) `docker save` failed, (4) the saved archive is implausibly small (not
# a real build), or (5) the load succeeded. 1 -- the ONLY non-zero return,
# and the only one that emits from this function -- with a loud stderr
# warning naming the image, if msb is present and the archive looks real but
# `msb load` itself failed.
#
# Every early exit below is classified inline as either "nothing to check"
# or "cannot check", the same way rip-cage-5jrt classified every early exit
# in _build_warn_stale_containers. rip-cage-528o's cut widened this sweep
# from the two paths its DESIGN named to all FOUR that exist here -- leaving
# mktemp/docker-save unclassified would repeat the exact gap 5jrt closed.
#
# WHAT SEPARATES THE TWO LABELS HERE (rip-cage-528o fix round, adversarial
# finding F4 -- previously carried by framing alone, now stated outright):
# all four early exits share the same OUTCOME -- no archive was handed to
# msb, so no load was attempted -- so the outcome cannot be the
# discriminator. The discriminator is whether the step that produced that
# outcome was SUPPOSED to succeed:
#
#   NOTHING TO CHECK -- the EXPECTED shape of a legitimate situation, in
#     which the question "did the load land?" never arises at all. `msb`
#     absent is a Docker-only host (there is no msb cache to load into); a
#     sub-_MSB_LOAD_MIN_BYTES archive is a fixture whose fake `docker save`
#     never implemented `save` for real (there is no image to load). Nothing
#     went wrong; there is genuinely nothing to load.
#
#   CANNOT CHECK -- an UNEXPECTED failure of a step that should have worked.
#     `mktemp` and `docker save` both succeed on any real build host, so a
#     failure there means the question DOES arise but its answer is
#     unavailable: we cannot know whether msb's cache is current, because
#     the conversion never got far enough to find out.
#
# Both classes stay SILENT and return 0. That is where this sweep
# deliberately departs from rip-cage-5jrt's own "cannot check => must emit"
# rider in _build_warn_stale_containers -- and the departure needs stating
# accurately, because 5jrt's rider does NOT depend on having something to
# name: its `msb list` failure branch (cli/build.sh, the "could not
# determine image provenance for any rc-managed sandboxes" line) emits
# precisely when no cage can be enumerated at all. So the reason this
# function stays quiet is not "nothing to name" but WHAT WAS AT RISK: over
# there, live cages already exist and may be silently pinned to a stale
# image, so an unanswerable question is itself the warning. Here the
# conversion simply never ran, the Docker image (the primary build
# artifact) is built and intact, nothing has yet booted from msb's cache,
# and _RC_MSB_LOAD_SUCCEEDED stays 0 -- so the downstream emitter stays
# quiet too. A never-attempted load must not be reported to the operator as
# a load that failed to land.
_build_msb_load() {
  _RC_MSB_LOAD_SUCCEEDED=0

  # NOTHING TO CHECK (path 1): msb isn't installed at all, so there is no
  # msb image cache to load into and nothing downstream could consume the
  # result -- the EXPECTED shape of a Docker-only host, not a build failure
  # (see the best-effort note above).
  command -v msb >/dev/null 2>&1 || return 0

  local _tar
  # CANNOT CHECK (path 2): no writable temp file, so the save->load
  # conversion cannot even be attempted -- an UNEXPECTED failure of a step
  # that should have worked. Deliberately silent and non-fatal: the Docker
  # image (the primary build artifact) is already built and intact, and the
  # post-load emitter stays quiet because the flag is still 0 -- a
  # never-attempted load must not be reported as a load that failed to land.
  _tar=$(mktemp -t "rc-msb-load.XXXXXX") || return 0

  # CANNOT CHECK (path 3): `docker save` itself failed, so there is no
  # archive to hand to msb. Same reasoning as the mktemp path -- an
  # UNEXPECTED failure of a step that succeeds on any real build host, so
  # the question "is msb's cache current?" is live but unanswerable. Silent
  # and non-fatal for the same reason: the conversion never ran, so there is
  # nothing to verify and nothing actionable to say.
  if ! docker save "$IMAGE" -o "$_tar" >/dev/null 2>&1; then
    rm -f "$_tar"
    return 0
  fi

  local _tar_bytes
  _tar_bytes=$(wc -c < "$_tar" 2>/dev/null | tr -d ' ')
  local _min_bytes="${_MSB_LOAD_MIN_BYTES:-1048576}"
  # NOTHING TO CHECK (path 4): the archive is implausibly small, i.e. "not
  # a real build" -- the fake-docker PATH-shim shape described in the
  # header. A real build's `docker save` is many MB.
  #
  # HONEST CAVEAT on the expected/unexpected axis: paths 1-3 read their
  # class off an observable (msb missing; mktemp failed; docker save
  # returned non-zero). This one does not. All the code sees is a byte
  # count, and a real host CAN reach the same byte count via a `docker save`
  # that exits 0 after a short or truncated write -- which by the axis above
  # would be CANNOT CHECK. NOTHING TO CHECK is therefore a PRESUMPTION here
  # (the fixture cause is overwhelmingly the common one), not a derivation.
  # It costs nothing today because both classes are silent and both leave
  # the flag 0; if this path ever gains behaviour that differs by class, the
  # presumption is the thing to revisit first -- distinguishing the two
  # would need a signal `wc -c` cannot give.
  #
  # Silent by design (there is nothing actionable to tell the operator), and
  # the flag stays 0 so the post-load emitter is silent too.
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
  # The ONLY path that sets the flag: a real-sized archive was handed to a
  # real `msb load` and it reported success. From here on, msb NOT holding
  # $IMAGE is a genuine "the load did not land" -- see rip-cage-528o's
  # status-3 branch in _msb_warn_image_layer_drift.
  _RC_MSB_LOAD_SUCCEEDED=1
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
# back to a local build on pull failure. Used by cmd_up's auto-build branch.
# Explicit `rc build` (cmd_build) is unchanged and always builds. ADR-008 D6.
#
# _pull_or_build_local — the from-source fallback. Builds rc's OWN base
# Dockerfile only: this path exists so `rc up` on a fresh host gets a working
# base image, and an operator's extension image is never something rc decides to
# build behind their back. Same fixed argv as cmd_build (ADR-031 D5(c)); the
# containment check cmd_build runs is not repeated here because the path is rc's
# own, not a caller's.
_pull_or_build_local() {
  local _pob_exit=0
  docker build -f "${SCRIPT_DIR}/cage/Dockerfile" --build-arg "RC_VERSION=${RC_VERSION}" -t "$IMAGE" "$SCRIPT_DIR" || _pob_exit=$?
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
