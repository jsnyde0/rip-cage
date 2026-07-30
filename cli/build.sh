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


# _build_reject_arg <message> <json_code> -- shared fail-loud emitter for
# cmd_build's fail-closed argument allowlist (rip-cage-zqjz.2). Prints via
# json_error (JSON mode -- which itself calls `exit 1`, terminating the
# process immediately, matching every pre-existing reject site's behavior)
# or a plain `Error: ...` line on stderr (human mode). A bash function's own
# `return` cannot force its CALLER to return, so every call site must follow
# this with an explicit `return 1` of its own (a no-op in JSON mode, since
# json_error already exited).
_build_reject_arg() {
  local _msg="$1" _code="$2"
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    json_error "$_msg" "$_code"
  fi
  echo "Error: $_msg" >&2
}


cmd_build() {
  # rip-cage-fo4z: parse a caller-supplied -t/--tag OUT of "$@" and let it
  # OVERRIDE the effective image name for the REST of this function, rather
  # than being passed through to `docker build` as a second tag.
  #
  # Why: the docker build invocations below hardcode `-t "$IMAGE"` (default
  # rip-cage:latest) FIRST. If a caller's own -t/--tag were left in "$@" and
  # appended after it, docker would apply BOTH tags to the SAME image --
  # `-t` reads as "build as this tag instead" but docker's actual semantics
  # are "also tag this". `rc build -t custom:tag` would then silently
  # re-tag (clobber) rip-cage:latest with whatever manifest/HOME the custom
  # build happened to use -- observed live 2026-07-29, stripping an
  # operator's composed `rc.multiplexers` bake off the default tag.
  #
  # $IMAGE is not only the docker tag -- it's the handle the post-build
  # root-owned validators inspect (_manifest_check_binary_root_owned /
  # _manifest_check_mount_root_owned below) and the handle the fail-closed
  # `docker image rm` cleanup untags on a violation (ADR-001), plus the
  # handle _build_warn_stale_containers / _build_msb_load read afterwards.
  # So the fix is NOT "strip -t from $@" alone -- it's "let a caller -t
  # override $IMAGE for this whole call". `local IMAGE=` below shadows the
  # global for the rest of this function's dynamic scope (bash resolves
  # unqualified $IMAGE reads in every function called from here -- the
  # validators, _build_warn_stale_containers, _build_msb_load -- against
  # this local, since none of them re-declare their own local IMAGE), so
  # every one of those call sites sees the EFFECTIVE image automatically,
  # without threading a new parameter through each of them.
  #
  # Degenerate cases:
  #   - -t / --tag with no following value: fail loud, before any docker
  #     call (mirrors docker's own "flag needs an argument" behavior).
  #   - -t / --tag with an EXPLICITLY EMPTY value (`-t ""`, `--tag=`, `-t=`,
  #     ...): ALSO fail loud, before any docker call (rip-cage-fo4z F2,
  #     round 2). Pre-round-2 this was already a hard docker error
  #     ("invalid tag \"\": repository name must have at least one
  #     component"); round-1's `${_bt_tag:-$IMAGE}` treated "supplied
  #     empty" the same as "not supplied" and silently fell back to
  #     building/tagging/validating/msb-loading the DEFAULT rip-cage:latest
  #     instead -- i.e. it converted a hard failure into a silent clobber of
  #     exactly the tag this bead exists to protect. `_bt_tag_set` (set the
  #     instant ANY -t/--tag spelling is recognized, regardless of the
  #     value) is what lets the empty-value check below distinguish "not
  #     supplied" from "supplied empty" -- `${_bt_tag:-...}` cannot.
  #   - -t given more than once: last occurrence wins (standard "last flag
  #     wins" convention; also what `getopts`/most CLIs do for repeated
  #     flags).
  #   - `--`: rc stops scanning for -t/--tag at this point, but this is NOT
  #     a general "pass everything after verbatim" escape hatch (round-1's
  #     comment overclaimed this). cmd_build always appends $SCRIPT_DIR as
  #     its OWN final positional after "$@" (see the two `docker build`
  #     calls below) -- so any non-empty content placed after `--` yields
  #     2+ positionals and `docker build` hard-errors ("requires 1
  #     argument") rather than silently doing something unexpected. Fails
  #     loud, doesn't clobber -- but it does not achieve verbatim pass-
  #     through; correcting the claim here rather than trying to make `--`
  #     actually work (out of this bead's scope, rip-cage-fo4z F4/round 2).
  #   - Docker (pflag) accepts several OTHER spellings of -t/--tag beyond
  #     the two above: an attached short-flag value (`-tVALUE`), an
  #     attached-with-equals short-flag value (`-t=VALUE`), and -t clustered
  #     behind docker build's OTHER boolean short flags (`-qt VALUE`,
  #     `-Dqt=VALUE`, ...). Any of these reaching docker unmodified
  #     alongside rc's own leading `-t "$IMAGE"` reproduces the exact co-tag
  #     clobber this bead exists to fix, so they are parsed out too -- see
  #     the dedicated comment on the regex branch below (rip-cage-fo4z F1,
  #     round 2).
  #
  # rip-cage-zqjz.2 -- POLICY INVERSION: fail-closed ALLOWLIST, not a
  # per-flag reject list.
  #
  # A THIRD distinct validator-defeat was found in this exact seam, with a
  # THIRD distinct mechanism (-t: additive; -f: last-wins; -o: BuildKit
  # output-redirection -- `docker build -t X -o type=local,dest=DIR .` exits
  # 0 and exports the build result to the filesystem WITHOUT loading it into
  # the docker image store; if a prior $IMAGE already existed, the
  # post-build root-owned validators below silently pass against the STALE
  # image while `rc build` reports status "built" -- a false green on the
  # safety floor, not a UX surprise). Three distinct mechanisms in three
  # passes means an open pass-through with a growing per-flag reject list is
  # unwinnable by construction: docker's flag surface evolves outside rc's
  # control, and each new flag is a fresh chance at a fresh mechanism.
  #
  # So the seam inverts: every token in "$@" is now classified into exactly
  # one of four buckets, decided BEFORE any docker call:
  #   1. Intercepted -t/--tag (every spelling above) -- overrides $IMAGE.
  #   2. Rejected -f/--file (every spelling) -- rip-cage-zqjz, unchanged.
  #   3. Rejected -o/--output (every spelling) -- THIS bead, closes the
  #      false-green above.
  #   4. An explicit ADMIT list: flags verified against docker 29.4.0's
  #      REAL `docker build --help` surface to (a) be unable to touch image
  #      identity, the Dockerfile source, the build context, the output
  #      destination/image-store load, or any image metadata the floor
  #      later reads, and (b) have stable, known semantics. Passed through
  #      unmodified. See the ADMIT case arms below for the one-line
  #      rationale on each.
  #   5. EVERYTHING ELSE -- every other named docker flag (--target,
  #      --label, --secret, --push, --platform, ...; see the catch-all
  #      branch's comment for the full reject table), any genuinely
  #      unrecognized/future docker flag, a stray build-context positional
  #      (rc supplies its own -- see the two `docker build ... "$@"
  #      "$SCRIPT_DIR"` call sites below), and a bare `--` (previously a
  #      literal unfiltered-passthrough hole: a51b5da/fb79d10 dumped
  #      everything after `--` into the constructed argv VERBATIM,
  #      bypassing every one of the checks above, including this bead's own
  #      -o rejection -- closed by removing that special case entirely, so
  #      `--` itself now falls into this same fail-closed bucket) -- ALL
  #      fail loud here, before any docker call, naming the allowlist and
  #      the `rc generate-dockerfile` escape hatch (compose the Dockerfile
  #      yourself, invoke `docker build` yourself, explicitly outside rc's
  #      safety floor).
  # This also closes rip-cage-fo4z's own forward-compat caveat ("if docker
  # build ever gains a new boolean short flag, a cluster using it could
  # again slip past the pattern") -- an unrecognized flag now fails closed
  # by construction, rather than silently reaching docker.
  local _bt_remaining=() _bt_tag="" _bt_tag_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--tag)
        if [[ $# -lt 2 ]]; then
          if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            json_error "rc build: ${1} requires a value" "BUILD_TAG_MISSING_VALUE"
          fi
          echo "Error: ${1} requires a value" >&2
          return 1
        fi
        _bt_tag="$2"
        _bt_tag_set=1
        shift 2
        ;;
      --tag=*)
        _bt_tag="${1#--tag=}"
        _bt_tag_set=1
        shift
        ;;
      -f|--file|--file=*)
        # rip-cage-zqjz: REJECT outright, fail loud, BEFORE any docker call
        # (and before any temp-Dockerfile work below -- this scan runs first
        # in cmd_build, so no $_tmp_dockerfile exists yet to leak). Unlike
        # -t/--tag (fo4z), there is no legitimate rc build -f/--file use and
        # no "override-then-audit" fix shape: rc's own -f "$_dockerfile"
        # comes before "$@" in both docker-build call sites below, and a
        # duplicate -f is LAST-WINS in docker (unlike -t, which is
        # additive) -- so a caller -f would silently swap the caller's file
        # in for the ACTUAL build while _manifest_check_build_isolation
        # (ADR-005 D9 / ADR-024) still only ever audits rc's own
        # manifest-resolved $_dockerfile. Accepting an override just
        # reopens the same bypass in the other direction, since there is no
        # "effective Dockerfile" concept to swap to (brain-ruled on the
        # bead: resolving the Dockerfile from the manifest IS rc's job).
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
          json_error "rc build: -f/--file is not accepted — rc resolves the Dockerfile from the manifest; a caller-supplied Dockerfile would bypass the build-isolation validator (ADR-005 D9 / ADR-024), which only ever audits rc's own resolved Dockerfile" "BUILD_FILE_REJECTED"
        fi
        echo "Error: -f/--file is not accepted — rc resolves the Dockerfile from the manifest; a caller-supplied Dockerfile would bypass the build-isolation validator (ADR-005 D9 / ADR-024), which only ever audits rc's own resolved Dockerfile" >&2
        return 1
        ;;
      -o|--output|--output=*)
        # rip-cage-zqjz.2: REJECT outright, fail loud, BEFORE any docker
        # call -- same shape as -f/--file just above (there is no
        # legitimate rc build -o/--output use and no override-then-audit
        # fix: rc's docker-build call sites below have no "-o" of their own
        # to override, and BuildKit's -o/--output governs where the build
        # RESULT lands -- filesystem, registry, or the local image store --
        # independently of -t/--tag. `docker build -t X -o
        # type=local,dest=DIR .` exits 0 and exports to DIR WITHOUT loading
        # X into the docker image store; if a prior X already existed, the
        # post-build root-owned validators below (_manifest_check_
        # binary_root_owned / _manifest_check_mount_root_owned) silently
        # pass against the STALE X while `rc build` reports status "built"
        # -- a false green on the safety floor (ADR-005 D9/D11, ADR-024,
        # ADR-027 D1), not a UX surprise. This is THE bead this reject
        # exists for.
        _build_reject_arg "rc build: -o/--output is not accepted — it can redirect the build result away from the local docker image store (filesystem, registry, ...), which would let the post-build safety-floor validators silently pass against a STALE previously-built image while rc reports the build as successful. There is no legitimate rc build -o/--output use. See 'rc build flag allowlist' in docs/reference/cli-reference.md. Escape hatch: run 'rc generate-dockerfile > Dockerfile.composed' and invoke docker build yourself, explicitly outside rc's safety floor." "BUILD_OUTPUT_REJECTED"
        return 1
        ;;
      --build-arg)
        # ADMIT (rip-cage-fo4z, re-judged rip-cage-zqjz.2): --build-arg only
        # ever feeds _image_is_current's staleness heuristic (an
        # org.opencontainers.image.version label comparison) -- it never
        # reaches _manifest_check_build_isolation or either root-owned
        # validator, and repeated distinct-key --build-arg flags must stay
        # repeatable for a manifest fragment's own build args. EXCEPTION:
        # the RC_VERSION key specifically is carved out and rejected -- rc's
        # own docker-build calls below already set
        # `--build-arg "RC_VERSION=${RC_VERSION}"` unconditionally, and a
        # caller override would win (BuildKit's build-arg map is
        # last-value-wins per key), spoofing the version label
        # _image_is_current compares against. Not a root-owned-validator
        # bypass, but a real integrity gap on the versioning surface this
        # bead is the fresh-eyes moment for (per fo4z's own deferred note).
        # Matched case-sensitively against rc's own literal ARG key name.
        if [[ $# -lt 2 ]]; then
          _build_reject_arg "rc build: ${1} requires a value" "BUILD_ARG_MISSING_VALUE"
          return 1
        fi
        if [[ "$2" == RC_VERSION=* ]]; then
          _build_reject_arg "rc build: --build-arg RC_VERSION=... is not accepted — rc sets RC_VERSION itself on every build; a caller override could spoof the org.opencontainers.image.version label _image_is_current compares against. Other --build-arg keys are admitted." "BUILD_ARG_RC_VERSION_REJECTED"
          return 1
        fi
        _bt_remaining+=("$1" "$2")
        shift 2
        ;;
      --build-arg=*)
        local _bt_ba_val="${1#--build-arg=}"
        if [[ "$_bt_ba_val" == RC_VERSION=* ]]; then
          _build_reject_arg "rc build: --build-arg=RC_VERSION=... is not accepted — rc sets RC_VERSION itself on every build; a caller override could spoof the org.opencontainers.image.version label _image_is_current compares against. Other --build-arg keys are admitted." "BUILD_ARG_RC_VERSION_REJECTED"
          return 1
        fi
        _bt_remaining+=("$1")
        shift
        ;;
      --no-cache|--pull|--debug|--quiet)
        # ADMIT: --no-cache/--pull only affect cache/base-image freshness;
        # --debug/--quiet (long forms of -D/-q, handled for short/clustered
        # forms by the pure-boolean regex in the catch-all below) only
        # affect docker's OWN log verbosity. None of the four can touch
        # image identity, the Dockerfile source, the build context, the
        # output destination, or any image metadata the floor reads. -q's
        # stdout-suppression is safe here specifically because neither
        # docker-build call site below parses docker's own stdout (the JSON
        # branch redirects it to /dev/null; the plain branch lets it go
        # straight to the terminal).
        _bt_remaining+=("$1")
        shift
        ;;
      --progress)
        # ADMIT: output-formatting only.
        if [[ $# -lt 2 ]]; then
          _build_reject_arg "rc build: ${1} requires a value" "BUILD_PROGRESS_MISSING_VALUE"
          return 1
        fi
        _bt_remaining+=("$1" "$2")
        shift 2
        ;;
      --progress=*)
        _bt_remaining+=("$1")
        shift
        ;;
      *)
        # rip-cage-fo4z F1 (round 2): docker build's short-flag surface,
        # confirmed live against `docker build --help` on docker 29.4.0, is
        # exactly 5 flags: -D/--debug and -q/--quiet (boolean), -f/--file,
        # -o/--output, and -t/--tag (each value-taking). pflag's shorthand
        # clustering algorithm (also verified live against real `docker
        # build` invocations for every shape below) walks a single-dash
        # token left to right: a boolean flag consumes one character and
        # continues; the FIRST value-taking flag it hits consumes the REST
        # of the token as its value (stripping one leading "=" if present),
        # or -- if nothing is left in the token -- the NEXT argv word.
        #
        # The regex below is a deterministic, verified replica of that
        # algorithm restricted to "does this token set -t": zero or more
        # boolean D/q characters, then the literal `t`, then whatever
        # follows. It is exhaustive over docker build's CURRENT short-flag
        # surface. A future docker release adding another boolean short
        # flag would need this pattern revisited -- flagged here rather
        # than silently assumed complete forever.
        #
        # Deliberately NOT matched by the -t branch below (left to the -f/-o
        # branches, or to the pure-boolean/fail-closed branches further
        # down): any cluster where -f or -o precedes the `t` character. In
        # real docker parsing, -f/-o (also value-taking) consumes the REST
        # of the token first, so `t` is never actually treated as the tag
        # flag there (e.g. `-ft` sets -f's value to "t"; it does not set a
        # tag at all) -- that shape is rip-cage-zqjz's -f/--file clobber
        # bug, handled by the -f branch immediately below (it matches `-ft`
        # first, since `f` -- not `t` -- is the leftmost value-taking
        # character).
        #
        # rip-cage-zqjz: -f/--file is checked FIRST (before -t) so that a
        # cluster where `f` is the leftmost value-taking character (e.g.
        # -ft, -fVALUE, -Dqf) is rejected as -f, not misread as -t. This
        # mirrors real docker/pflag left-to-right cluster parsing: whichever
        # value-taking character (f/o/t) appears first in the token wins,
        # and everything after it is that flag's value, not another flag.
        # Same regex shape as -t's, restricted to `f`; unlike -t there is no
        # legitimate override to perform, so ANY match (value attached or
        # not) is rejected outright, before any docker call and before any
        # temp-Dockerfile work (this scan runs first in cmd_build).
        #
        # rip-cage-zqjz.2: under the fail-closed allowlist, three more
        # branches were added below the original two:
        #   - a stray non-flag positional (rc supplies the build-context
        #     positional itself -- see the two `docker build ... "$@"
        #     "$SCRIPT_DIR"` call sites -- a caller-supplied one would
        #     otherwise become a second positional docker itself would
        #     hard-error on; rc now fails loud on it directly instead),
        #     checked FIRST since it's not a `-`-prefixed token at all;
        #   - a -o/--output cluster (same regex shape as -f's, restricted
        #     to `o`), rejected for the same "first value-taking char in
        #     the token wins" reason -- this bead's own false-green fix;
        #   - a pure boolean short cluster (`^-[Dq]+$`, i.e. every char is
        #     D or q and there's at least one) -- the ADMIT case for -D/-q
        #     appearing standalone or clustered together with no value
        #     character at all (e.g. `-q`, `-D`, `-Dq`, `-qD`).
        # ANYTHING ELSE reaching the final `else` -- any other named docker
        # flag (--target/--label/--secret/--ssh/--push/--load/--platform/
        # --add-host/--allow/--annotation/--attest/--build-context/
        # --builder/--cache-from/--cache-to/--call/--check/--cgroup-parent/
        # --iidfile/--metadata-file/--network/--no-cache-filter/--policy/
        # --provenance/--sbom/--shm-size/--ulimit/...), any genuinely
        # unrecognized/future docker flag, or a bare `--` (no longer
        # special-cased into verbatim passthrough -- see the comment above
        # `local _bt_remaining=` for why) -- now fails loud here too,
        # instead of being silently passed through to docker. This is the
        # fail-closed default the allowlist inversion exists for: docker's
        # flag surface evolves outside rc's control, so "unrecognized"
        # means "rejected", not "assumed safe". Per-flag rationale for the
        # explicitly-named rejects above lives in this bead's commit
        # message and docs/reference/cli-reference.md's allowlist table,
        # not repeated per-flag here (one shared message covers all of
        # them, naming the actual token via `$1`).
        if [[ "$1" != -* ]]; then
          _build_reject_arg "rc build: unexpected argument '$1' — rc build does not accept a build-context positional; rc supplies it itself. See 'rc build flag allowlist' in docs/reference/cli-reference.md. Escape hatch: run 'rc generate-dockerfile > Dockerfile.composed' and invoke docker build yourself, explicitly outside rc's safety floor." "BUILD_EXTRA_POSITIONAL"
          return 1
        elif [[ "$1" =~ ^-[Dq]*f(.*)$ ]]; then
          if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            json_error "rc build: -f/--file is not accepted — rc resolves the Dockerfile from the manifest; a caller-supplied Dockerfile would bypass the build-isolation validator (ADR-005 D9 / ADR-024), which only ever audits rc's own resolved Dockerfile" "BUILD_FILE_REJECTED"
          fi
          echo "Error: -f/--file is not accepted — rc resolves the Dockerfile from the manifest; a caller-supplied Dockerfile would bypass the build-isolation validator (ADR-005 D9 / ADR-024), which only ever audits rc's own resolved Dockerfile" >&2
          return 1
        elif [[ "$1" =~ ^-[Dq]*o(.*)$ ]]; then
          _build_reject_arg "rc build: -o/--output is not accepted — it can redirect the build result away from the local docker image store, which would let the post-build safety-floor validators silently pass against a STALE previously-built image while rc reports the build as successful. See 'rc build flag allowlist' in docs/reference/cli-reference.md. Escape hatch: run 'rc generate-dockerfile > Dockerfile.composed' and invoke docker build yourself, explicitly outside rc's safety floor." "BUILD_OUTPUT_REJECTED"
          return 1
        elif [[ "$1" =~ ^-[Dq]*t(.*)$ ]]; then
          local _bt_prefix="${1%%t*}"
          local _bt_rest="${BASH_REMATCH[1]}"
          # Re-emit any leading boolean flags (-D/-q) as their own token so
          # docker still sees them -- only the tag portion is intercepted.
          if [[ "$_bt_prefix" != "-" ]]; then
            _bt_remaining+=("$_bt_prefix")
          fi
          if [[ -z "$_bt_rest" ]]; then
            # -t / -qt / -Dqt / ... with nothing attached: value is the
            # NEXT argv word (mirrors the -t|--tag case arm above).
            if [[ $# -lt 2 ]]; then
              if [[ "$OUTPUT_FORMAT" == "json" ]]; then
                json_error "rc build: ${1} requires a value" "BUILD_TAG_MISSING_VALUE"
              fi
              echo "Error: ${1} requires a value" >&2
              return 1
            fi
            _bt_tag="$2"
            _bt_tag_set=1
            shift 2
          else
            _bt_tag="${_bt_rest#=}"
            _bt_tag_set=1
            shift
          fi
        elif [[ "$1" =~ ^-[Dq]+$ ]]; then
          # ADMIT: a pure boolean short cluster (-D/-q only, no value
          # character at all) -- see the --debug/--quiet case arm above for
          # the rationale, which applies identically to the short spellings.
          _bt_remaining+=("$1")
          shift
        else
          _build_reject_arg "rc build: '$1' is not on rc's build-flag allowlist and cannot be passed to docker build — see 'rc build flag allowlist' in docs/reference/cli-reference.md for what is (and isn't) accepted and why. Escape hatch: run 'rc generate-dockerfile > Dockerfile.composed' and invoke docker build yourself, explicitly outside rc's safety floor." "BUILD_ARG_NOT_ALLOWED"
          return 1
        fi
        ;;
    esac
  done
  set -- "${_bt_remaining[@]+"${_bt_remaining[@]}"}"

  if [[ "$_bt_tag_set" -eq 1 && -z "$_bt_tag" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_error "rc build: -t/--tag value must not be empty" "BUILD_TAG_EMPTY_VALUE"
    fi
    echo "Error: -t/--tag value must not be empty" >&2
    return 1
  fi

  # shellcheck disable=SC2034  # read via dynamic scope by every helper cmd_build calls below
  # NOTE: the RHS `$IMAGE` here is evaluated against the OUTER (not-yet-
  # shadowed) variable at `local` declaration time -- standard bash
  # behavior for `local X="$X"`. Splitting the declaration and the
  # conditional assignment into two separate statements would instead read
  # back the (already-shadowed, empty) local on the second statement --
  # verified live while writing this fix (T3/T16 regressed to an empty tag
  # until this was combined into one statement).
  local IMAGE="$IMAGE"
  if [[ "$_bt_tag_set" -eq 1 ]]; then
    IMAGE="$_bt_tag"
  fi

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
      #
      # rip-cage-fo4z F7 (round 2): skip this when the caller supplied a
      # custom -t/--tag. The warning's premise is "cages running the image
      # you just rebuilt" -- that reasoning does not hold for a scratch/
      # fixture/test build under a throwaway tag, and every real cage is
      # still pinned to whatever image it actually was (rip-cage:latest or
      # an explicit RC_IMAGE), untouched by this build. Without this guard,
      # a second build of the SAME custom tag (already loaded into msb's
      # cache from the prior run) makes every real cage's digest mismatch
      # the fixture image, and the warning would wrongly advise `rc reload`
      # (a COLD RECREATE) on cages that are perfectly current.
      [[ "$_bt_tag_set" -eq 0 ]] && _build_warn_stale_containers
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
      # rip-cage-jnvb / D-d: same informational warning on the human-mode
      # build path. rip-cage-fo4z F7 (round 2): same custom-tag skip as the
      # JSON path above -- see that comment for the full rationale.
      [[ "$_bt_tag_set" -eq 0 ]] && _build_warn_stale_containers
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
# `rc reload` (rip-cage-syzk: volume-preserving repair, repointed off `rc
# destroy` — this is the FIRST of the three sites an operator sees this
# message at, right after the `rc build` that caused the drift) or the
# correct RC_IMAGE.
#
# rip-cage-tsf2.1: REWRITTEN onto msb — was `docker ps -a --filter
# label=rc.source.path` + `docker inspect --format '{{.Image}}'`. Enumerates
# via the same msb primitives cli/ls.sh's _rc_ls_enumerate uses (msb list +
# _msb_inspect_json), and compares each real cage's STORED image digest
# (_msb_sandbox_image_digest) against the just-built image's REAL current
# digest in msb's local cache (_msb_current_image_digest) — the same digest
# comparator cli/lib/msb_runtime.sh's _msb_image_drift_status already trusts
# for the single-cage resume-time check.
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
    # Deliberately NOT _msb_image_drift_status here: that comparator is shaped
    # for a single named container with an abort/warn decision (per D-b/D-c),
    # not a fan-out enumeration over every rc container — a silent `continue`
    # on inspect failure is the right per-container fallback for a warning
    # sweep, which doesn't fit the resolver's status-code contract. Do not
    # "fix" this into a third derivation of the compare — see the M1 note on
    # rip-cage-jnvb (bd memory rip-cage-mount-shape-label-lock-pattern family).
    _bwsc_digest=$(_msb_sandbox_image_digest "$_bwsc_name" 2>/dev/null) || continue
    if [[ -n "$_bwsc_digest" && "$_bwsc_digest" != "$_just_built_digest" ]]; then
      echo "Warning: container '${_bwsc_name}' was created from a different image than the one just built — rc up will refuse to resume it (rc reload ${_bwsc_name} moves it onto the current image; named volumes and host mounts survive, the guest's ephemeral overlay does not); if a cage was intentionally pinned via RC_IMAGE, ignore this for it." >&2
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

