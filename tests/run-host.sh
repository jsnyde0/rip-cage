#!/usr/bin/env bash
# Runs every host-side test. Exits non-zero on any failure.
# Called by `rc test --host` and CI.
#
# Usage:
#   bash tests/run-host.sh                     # run all tests (default)
#   bash tests/run-host.sh --host-only          # skip NEEDS_CONTAINER tests (CI mode)
#   bash tests/run-host.sh --list               # print the selected ordered basenames (respects --batch/--only), exit
#   bash tests/run-host.sh --batch K/N          # run only slice K of N (1-based, deterministic)
#   bash tests/run-host.sh --only 'glob,glob'   # run only basenames matching a comma-separated glob list
#   bash tests/run-host.sh --ledger PATH        # append PASS/FAIL/SKIP+duration rows to PATH (or set RC_TEST_LEDGER)
#   bash tests/run-host.sh --dry-run            # with --batch/--only/--ledger: record selection without executing tests
#   bash tests/run-host.sh --ledger-summary PATH...  # union ledger files against the full enumeration; report never-run files + totals
#   bash tests/run-host.sh --expect-no-skip 'glob,glob'  # or RC_TEST_EXPECT_NO_SKIP: a body-decided SKIP on a
#                                                # matching basename ledgers FAIL instead -- declares "this probe
#                                                # MUST run (not self-skip) under today's configuration"
#
# rip-cage-7atw.13: --batch/--only/--ledger/--ledger-summary let a full-suite
# run be split into resumable, unioned slices (mac-mini background-task
# lifetime kills runs at ~1hr) while --ledger-summary's zero-row detection
# proves the union is complete. Default invocation (no flags) is unchanged.
#
# rip-cage-pow0: a test file can exit 0 for two different reasons -- "I ran
# and proved my guarantee" (PASS) or "my precondition is absent, I checked
# nothing" (SKIP). The suite ledger used to fold both into PASS. A test whose
# stdout has a line starting "SKIP" followed by a space, colon, or open paren
# (matches "SKIP:", "SKIP (NEEDS_CONTAINER / RC_E2E):", "SKIP C6:", etc --
# every self-skip spelling actually in use in tests/ as of rip-cage-pow0
# round 2; deliberately does NOT match "SKIPPED"/"SKIPS"/"SKIP_"-prefixed
# identifiers) AND never prints a single "PASS"-prefixed line is treated as a
# body-decided SKIP, not a PASS -- see run_test's classification block.
# --expect-no-skip closes the "a SKIP column alone is cosmetic" gap: without
# it, a probe silently switching from PASS to SKIP (e.g. an asset relocation)
# is still a green suite. Name it there and the same event becomes a FAIL.
#
# HOST-ONLY INVARIANT: rc exits immediately when /etc/rip-cage/release is present.
# This script will never succeed from inside a rip-cage container.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Flag parsing. --host-only is the original flag (kept positionally
# compatible: `bash tests/run-host.sh --host-only` behaves exactly as
# before). The rip-cage-7atw.13 flags below it are additive; a bare
# invocation with no arguments takes the same path it always has.
# Classification is a DENYLIST: NEEDS_CONTAINER lists tests that require a
# live cage or ANTHROPIC_API_KEY; everything else runs by default (HOST_ONLY).
# Safe-failure direction: a newly-added test runs in CI by default and fails
# loudly if it actually needs a container — rather than being silently dropped.
# ---------------------------------------------------------------------------
HOST_ONLY_MODE=false
RH_BATCH_K=""
RH_BATCH_N=""
RH_ONLY_FILTER=""
RH_LEDGER_PATH="${RC_TEST_LEDGER:-}"
RH_EXPECT_NO_SKIP_FILTER="${RC_TEST_EXPECT_NO_SKIP:-}"
RH_DRY_RUN=false
RH_LIST_MODE=false
RH_LEDGER_SUMMARY_MODE=false
RH_LEDGER_SUMMARY_FILES=()
# rip-cage-or84: image_digest captured at run START (by _rh_ledger_write_
# header, regardless of whether a ledger is configured) so the run-end
# CAVEAT check below has something to compare against.
RH_START_IMAGE_DIGEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-only)
      HOST_ONLY_MODE=true
      export RC_HOST_ONLY=1
      shift
      ;;
    --batch)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --batch requires K/N (e.g. --batch 1/4)" >&2
        exit 2
      fi
      RH_BATCH_K="${2%%/*}"
      RH_BATCH_N="${2##*/}"
      if ! [[ "$RH_BATCH_K" =~ ^[0-9]+$ && "$RH_BATCH_N" =~ ^[0-9]+$ \
            && "$RH_BATCH_N" -ge 1 && "$RH_BATCH_K" -ge 1 && "$RH_BATCH_K" -le "$RH_BATCH_N" ]]; then
        echo "ERROR: --batch expects K/N with 1<=K<=N (got: $2)" >&2
        exit 2
      fi
      shift 2
      ;;
    --only)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --only requires a comma-separated basename/glob list" >&2
        exit 2
      fi
      RH_ONLY_FILTER="$2"
      shift 2
      ;;
    --ledger)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --ledger requires a PATH" >&2
        exit 2
      fi
      RH_LEDGER_PATH="$2"
      shift 2
      ;;
    --expect-no-skip)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --expect-no-skip requires a comma-separated basename/glob list" >&2
        exit 2
      fi
      RH_EXPECT_NO_SKIP_FILTER="$2"
      shift 2
      ;;
    --dry-run)
      RH_DRY_RUN=true
      shift
      ;;
    --list)
      RH_LIST_MODE=true
      shift
      ;;
    --ledger-summary)
      RH_LEDGER_SUMMARY_MODE=true
      shift
      # Remaining args are ledger file paths (variadic, terminal).
      while [[ $# -gt 0 ]]; do
        RH_LEDGER_SUMMARY_FILES+=("$1")
        shift
      done
      ;;
    *)
      echo "ERROR: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

# Accumulate failures across ALL test files rather than aborting at the first
# one (set -e would otherwise stop the suite at the first failing test, hiding
# the rest — a thrashing trap for CI where each red cycle costs ~12min). The
# driver runs every test, collects the failures, and exits non-zero at the end.
FAILED_TESTS=()

# rip-cage-pow0: PASS_COUNT/SKIP_COUNT/SKIPPED_TESTS give a normal (non
# --ledger-summary) run its own TOTALS line -- FAIL's count is
# ${#FAILED_TESTS[@]}, already tracked above. SKIPPED_TESTS names every
# skipped basename (dry-run, needs-container, AND body-decided self-skip) so
# a permanently-skipping probe is visible at a glance, not just counted.
PASS_COUNT=0
SKIP_COUNT=0
SKIPPED_TESTS=()

# Tests that REQUIRE a running rip-cage container or live API key.
# Each entry carries a one-line comment explaining why.
NEEDS_CONTAINER=(
  # test-agent-cli.sh: RETIRED with the verbs it tested (rip-cage-ely4.7.3 /
  # ADR-031 D3). Its subject was the agent-facing CLI contract, and six of its
  # fifteen cases drove `rc ls` or `rc down`, plus one asserting an
  # allowed-roots warning whose guard ADR-031 D2 deleted. Every SURVIVING
  # subject is already covered in the HOST tier, which is strictly better --
  # this file was container-gated and therefore invisible to --host-only:
  # path hardening, the destroy dry-run and the AGENTS.md rules section in
  # test-dg6.2.sh; `rc build --output json` in test-build-flag-override.sh and
  # test-build-msb-load.sh; `rc test --output json` in test-rc-commands.sh
  # (Test 15); `rc up --dry-run` JSON in test-json-output.sh. Nothing was
  # dropped without a home.
  "test-pi-e2e.sh"           # calls rc up AND requires ~/.pi/agent/auth.json with valid pi credentials
  "test-pi-install.sh"       # runs docker run --rm rip-cage:latest; requires a pre-built rip-cage image
  "test-pi-auth-mount.sh"    # calls rc up to create a live container; inspects container env + mounts
  "test-pi-cage-context.sh"  # calls rc up to create a live container; inspects CLAUDE.md inside cage
  "test-claude-concurrency.sh" # requires a live rip-cage container with Claude auth (ANTHROPIC_API_KEY or OAuth)
  "test-claude-json-seed-synthesis.sh" # rip-cage-vwka: spins its own real cages via rc up (non-possession + possession) to verify R4 seed synthesis; requires docker + msb + a pre-built rip-cage image
  "test-multiplexer-lifecycle.sh" # requires a live rip-cage container; exercises multiplexer lifecycle (none/tmux/herdr) + retirement + config-isolation (rip-cage-1f59.8)
  "test-agent-mail-concurrent.sh" # requires RC_E2E=1 + pi auth + agent_mail fixture image; proves two concurrent pi agents coordinate via am CLI
  "test-session-persistence.sh" # Phase 3 calls rc up + docker exec for dn2 projects/sessions persist-to-host (rip-cage-b6ia)
  "test-pi-no-extensions.sh"  # rip-cage-sn1h: LOCKED-VARIANT-ONLY probe; requires running cage; self-skips under shipped OPEN default (rip-cage-p35a.1 / ADR-027 D1)
  "test-skills.sh"            # live meta-skill MCP handshake + cage-path/settings assertions inside a container (rip-cage-b6ia)
  "test-multiplexer-agent-e2e.sh" # requires RC_E2E=1 + pi auth; proves pi agent does real work THROUGH the tmux attach surface with >=2 distinct tool invocations (rip-cage-w621.7)
  "test-multiplexer-composable.sh" # E1 tier builds + runs a cage; G1 host-only grep-guards run always (rip-cage-61al.8)
  "test-symlink-follow.sh"    # needs a non-reserved writable scratch dir for symlink targets; on Linux every writable top-level (/home,/tmp,/var) is in rc's FHS-reserved set (cli/up.sh:'_SFL_RESERVED_CAGE_PATHS'), so it only runs on macOS (mktemp→/private/var dodges rc's deliberate non-canonicalization). Not "needs a cage" but host-only-Linux-incompatible (rip-cage-woow)
  "test-cc-managed-settings-probe.sh" # rip-cage-wlwc.1: D8 CC managed-settings anchor probe — requires live authed cage + API call; self-skips if no cage or unauthed (NEEDS_CONTAINER+AUTH)
  "test-cc-dcg-managed-settings.sh"  # rip-cage-r9n4: DCG managed-settings regression — proves managed deny survives stripping ALL agent-writable layers; requires live authed cage (NEEDS_CONTAINER+AUTH)
  "test-mount-mode-e2e.sh"           # rip-cage-wlwc.3: real-cage ro/rw behavioral probes (RE1-RE3); self-skips without RC_E2E=1
  "test-doctor-runnability.sh"       # rip-cage-2cks: spins live cages (rc up + msb create) to exercise rc doctor's cwd/workspace-resolution probes; self-skips without docker, msb, or host bd
  "test-msb-boot-smoke.sh"           # rip-cage-7dkq (S1, msb migration): needs live docker + live msb + a pre-built rip-cage:latest image to actually boot a cage; self-skips (SKIP:, exit 0) without any of the three
  "test-floor-probe.sh"              # rip-cage-ely4.12: builds two DELIBERATELY BROKEN extension images and boots a cage on each to prove the floor probe refuses them; needs live docker + msb + a base image carrying the probe; self-skips without any of the three
)

# Helper: check if a given test basename is in NEEDS_CONTAINER.
_is_needs_container() {
  local name
  name="$(basename "$1")"
  for entry in "${NEEDS_CONTAINER[@]}"; do
    local entry_name
    entry_name="$(echo "$entry" | awk '{print $1}')"
    if [[ "$name" == "$entry_name" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# rip-cage-7atw.13 selection/ledger plumbing.
#
# _RH_MODE drives what run_test/run_pytest actually do:
#   "enumerate" — used only by --ledger-summary, to learn the driver's own
#                 TRUE full enumeration (ignores --batch/--only on purpose —
#                 the aggregator's zero-row detector needs the universal set,
#                 not whatever selection happened to be passed alongside it).
#                 Records the basename and returns immediately; never
#                 executes a test body.
#   "list"      — used by --list. Applies the normal --batch/--only
#                 selection, then echoes the basename instead of executing —
#                 i.e. "what would this invocation run". Near-instant.
#   "run"       — the normal path (default invocation, --host-only,
#                 --batch, --only, --dry-run all flow through here).
#
# Selection is by call-ordinal position (1-based, the same order the calls
# appear below), NOT by re-deriving the full list first — --batch K/N only
# needs the caller-supplied N, so no enumeration pass is required on the hot
# path. This keeps the default (no-flags) invocation's cost identical to
# before: one counter increment per call.
# ---------------------------------------------------------------------------
_RH_MODE="run"
_RH_CALL_INDEX=0
_RH_FULL_ENUM=()

# Deterministic selection for call ordinal `idx` (1-based) with basename
# `base`. No --batch/--only given => everything is selected (parity with the
# pre-7atw.13 default). Round-robin batch assignment (idx % N) means the
# same K/N over the same ordered call sequence always yields the same slice,
# so a union over K=1..N is provably the full set regardless of whether N
# evenly divides the total.
_rh_is_selected() {
  local base="$1" idx="$2"
  if [[ -n "$RH_BATCH_N" ]]; then
    local slot=$(( (idx - 1) % RH_BATCH_N + 1 ))
    [[ "$slot" -eq "$RH_BATCH_K" ]] || return 1
  fi
  if [[ -n "$RH_ONLY_FILTER" ]]; then
    _rh_matches_only "$base" || return 1
  fi
  return 0
}

# --only accepts a comma-separated list of basenames or globs.
_rh_matches_only() {
  local base="$1"
  local -a patterns
  IFS=',' read -ra patterns <<< "$RH_ONLY_FILTER"
  local p
  for p in "${patterns[@]}"; do
    # shellcheck disable=SC2254 # intentional glob match: $p is a user-supplied pattern, not a literal
    case "$base" in
      $p) return 0 ;;
    esac
  done
  return 1
}

# Appends one ledger row for a file this invocation actually attempted.
# Files outside this invocation's selection get zero rows here — that's what
# makes the aggregator's "union of batch ledgers" story work.
_rh_ledger_row() {
  local base="$1" status="$2" reason="$3" dur="$4"
  [[ -z "$RH_LEDGER_PATH" ]] && return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s|%s|%s|%s|%s\n' "$base" "$status" "$dur" "$reason" "$ts" >> "$RH_LEDGER_PATH"
}

# rip-cage-or84: shared rip-cage:latest image-digest resolver, used for both
# the ledger header's START value (_rh_ledger_write_header below) and the
# run-end CAVEAT comparison (_rh_check_image_tag_moved). Docker-unreachable
# falls back to "unavailable" rather than aborting (set -e safe: the
# fallback assignment always leaves the function's own exit status 0).
# Honors RC_TEST_STAMP_IMAGE_DIGEST (rip-cage-7atw.15) so a pinned
# batch-capture run compares its fixed pin against itself (never a spurious
# CAVEAT) instead of against live docker state the pin exists to decouple
# from.
_rh_resolve_image_digest() {
  if [[ -n "${RC_TEST_STAMP_IMAGE_DIGEST:-}" ]]; then
    echo "$RC_TEST_STAMP_IMAGE_DIGEST"
    return 0
  fi
  local digest="unavailable"
  if command -v docker >/dev/null 2>&1; then
    digest="$(docker image inspect --format '{{.Id}}' rip-cage:latest 2>/dev/null || true)"
    [[ -z "$digest" ]] && digest="unavailable"
  fi
  echo "$digest"
}

# One header line per invocation, stamping commit + rip-cage:latest image
# digest + RC_E2E on/off + timestamp. Docker-unreachable must not crash the
# driver — falls back to "unavailable".
#
# rip-cage-7atw.15: RC_TEST_STAMP_COMMIT / RC_TEST_STAMP_IMAGE_DIGEST, when
# set, are used VERBATIM instead of re-deriving per invocation. A multi-hour
# batched capture (rip-cage-7atw.14) re-derives commit/image_digest fresh on
# every batch by default -- but a concurrent session can commit to main (or
# rip-cage:latest can get rebuilt) mid-capture, which legitimately moves
# those derived values batch-to-batch and would fail 7atw.13's header-
# coherence check even though every file ran against the SAME intended
# baseline. Pinning lets the capturer fix one identity for the whole run.
# Unset (the default) = today's per-invocation auto-derivation, unchanged.
#
# rip-cage-or84: RH_START_IMAGE_DIGEST is captured HERE unconditionally
# (even with no --ledger configured) so _rh_check_image_tag_moved at run end
# always has a START value to compare against — the ledger-file write itself
# still only happens when RH_LEDGER_PATH is set.
_rh_ledger_write_header() {
  local commit img_digest e2e_flag ts
  if [[ -n "${RC_TEST_STAMP_COMMIT:-}" ]]; then
    commit="$RC_TEST_STAMP_COMMIT"
  else
    commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  fi
  img_digest="$(_rh_resolve_image_digest)"
  RH_START_IMAGE_DIGEST="$img_digest"
  [[ -z "$RH_LEDGER_PATH" ]] && return 0
  e2e_flag="${RC_E2E:-0}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '#RUN commit=%s image_digest=%s rc_e2e=%s timestamp=%s\n' "$commit" "$img_digest" "$e2e_flag" "$ts" >> "$RH_LEDGER_PATH"
}

# rip-cage-or84: run-end counterpart to the ledger header's START
# image_digest. Re-resolves the digest AFTER _run_all_tests has finished and,
# if it differs from the START value captured in _rh_ledger_write_header,
# prints an advisory CAVEAT naming the mid-run tag move as a named condition
# -- so any image-dependent probe failure in this run is not read as a bare,
# uninformative red (rip-cage-or84 / rip-cage-sw6s).
#
# Advisory only: this function only ever echoes; it never sets FAILURES,
# never touches PASS_COUNT/FAILED_TESTS, and never exits. A tag move must
# not turn a PASS into a FAIL or otherwise change run-host.sh's exit status.
_rh_check_image_tag_moved() {
  local end_digest
  end_digest="$(_rh_resolve_image_digest)"
  if [[ -n "$RH_START_IMAGE_DIGEST" && "$RH_START_IMAGE_DIGEST" != "unavailable" \
        && -n "$end_digest" && "$end_digest" != "unavailable" \
        && "$RH_START_IMAGE_DIGEST" != "$end_digest" ]]; then
    echo ""
    echo "CAVEAT: rip-cage:latest MOVED during this run (image_digest ${RH_START_IMAGE_DIGEST} at start -> ${end_digest} at end)."
    echo "        Any image-dependent probe failure above may be attributable to that mid-run tag move, not to the code under test."
    echo "        See rip-cage-or84 (this guard) and rip-cage-sw6s (the incident it closes)."
  fi
}

# A batched real-world run (e.g. a multi-hour, kill-resumable baseline
# capture) can land its slices at DIFFERENT commits/images/RC_E2E postures.
# A union that is file-complete (every basename has a row) but stamped from
# incoherent #RUN headers is NOT a valid single-revision baseline -- it
# would certify a state that existed at no single point in time. Collects
# the distinct value-set seen for each of commit/image_digest/rc_e2e across
# ALL #RUN header lines in ALL given files; prints which field(s) diverge and
# their values. Prints nothing and returns 0 when every header agrees.
_rh_ledger_check_headers() {
  local -a files=("$@")
  local commits image_digests e2e_flags
  commits="$(grep -h '^#RUN' "${files[@]}" 2>/dev/null | grep -oE 'commit=[^ ]*' | sort -u)"
  image_digests="$(grep -h '^#RUN' "${files[@]}" 2>/dev/null | grep -oE 'image_digest=[^ ]*' | sort -u)"
  e2e_flags="$(grep -h '^#RUN' "${files[@]}" 2>/dev/null | grep -oE 'rc_e2e=[^ ]*' | sort -u)"

  local incoherent=false
  local -a msgs=()
  if [[ "$(printf '%s\n' "$commits" | grep -c .)" -gt 1 ]]; then
    incoherent=true
    msgs+=("  commit diverges: $(printf '%s' "$commits" | tr '\n' ' ')")
  fi
  if [[ "$(printf '%s\n' "$image_digests" | grep -c .)" -gt 1 ]]; then
    incoherent=true
    msgs+=("  image_digest diverges: $(printf '%s' "$image_digests" | tr '\n' ' ')")
  fi
  if [[ "$(printf '%s\n' "$e2e_flags" | grep -c .)" -gt 1 ]]; then
    incoherent=true
    msgs+=("  rc_e2e diverges: $(printf '%s' "$e2e_flags" | tr '\n' ' ')")
  fi

  if $incoherent; then
    echo "=== INCOHERENT RUN HEADERS across unioned ledgers ==="
    local m
    for m in "${msgs[@]}"; do
      echo "$m"
    done
    echo "A complete-but-incoherent union is not a valid single-revision baseline."
    echo ""
    return 1
  fi
  return 0
}

# Unions the given ledger files against the driver's own full enumeration
# (_RH_FULL_ENUM, populated by an "enumerate" pass before this is called).
# Last row seen per basename wins ("latest status"). Reports per-file status,
# the files with zero rows across ALL given ledgers (never ran — the
# silent-gap detector), and PASS/FAIL/SKIP totals. Exits non-zero when there
# is any never-run file, any FAIL, or the run headers are incoherent (see
# _rh_ledger_check_headers) -- so it doubles as a CI completeness+coherence gate.
_rh_ledger_summary() {
  local -a files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "ERROR: --ledger-summary requires at least one ledger file" >&2
    return 2
  fi
  local f
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: ledger file not found: $f" >&2
      return 2
    fi
  done

  # `if !` guards this the same way run_test/run_pytest guard `bash
  # "$test_file"` -- _rh_ledger_check_headers legitimately returns 1 on
  # divergence, and under set -e an unguarded failing statement would abort
  # the whole function here, silently skipping the completeness table below.
  local header_rc=0
  if ! _rh_ledger_check_headers "${files[@]}"; then
    header_rc=1
  fi

  local order_file
  order_file="$(mktemp)"
  printf '%s\n' "${_RH_FULL_ENUM[@]}" > "$order_file"

  local summary_rc
  awk -F'|' -v order_file="$order_file" '
    BEGIN {
      while ((getline b < order_file) > 0) {
        order[++n] = b
      }
      close(order_file)
    }
    /^#/ { next }
    {
      # A torn write (mid-write SIGTERM during --ledger append) can glue the
      # next "#RUN ..." header directly onto this line with no separating
      # newline (the row content lands, its trailing newline does not).
      # That garbage can land in ANY field depending on exactly
      # where the tear fell -- most dangerously the timestamp field, which
      # a merely NF>=4 check never inspects, so the row would otherwise
      # look completely legitimate. Validate the full row shape: exactly 5
      # fields, status/duration/reason/timestamp each well-formed. Anything
      # else is malformed -- surfaced explicitly, never silently accepted
      # as a status and never silently vanished either.
      ok = (NF == 5) \
        && ($2 == "PASS" || $2 == "FAIL" || $2 == "SKIP") \
        && ($3 ~ /^[0-9]+$/) \
        && ($4 ~ /^[A-Za-z0-9_-]*$/) \
        && ($5 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/)
      if (!ok) {
        malformed++
        malformed_list[malformed] = $0
        next
      }
      status[$1] = $2; dur[$1] = $3; reason[$1] = $4; seen[$1] = 1
    }
    END {
      pass = 0; fail = 0; skip = 0; zero = 0; malformed += 0
      print "=== ledger summary (enumerated: " n ") ==="
      for (i = 1; i <= n; i++) {
        b = order[i]
        if (seen[b]) {
          reason_suffix = (reason[b] != "" ? " [" reason[b] "]" : "")
          printf "%s: %s (%ss)%s\n", b, status[b], dur[b], reason_suffix
          if (status[b] == "PASS") pass++
          else if (status[b] == "FAIL") fail++
          else if (status[b] == "SKIP") skip++
        } else {
          print b ": NEVER-RUN"
          zero++
          zero_list[++zn] = b
        }
      }
      print ""
      if (zero > 0) {
        print "=== " zero " FILE(S) NEVER RAN (zero ledger rows) ==="
        for (i = 1; i <= zn; i++) print "  ZERO-ROW: " zero_list[i]
        print ""
      }
      if (malformed > 0) {
        print "=== " malformed " MALFORMED LEDGER ROW(S) (torn/short write -- not counted as PASS/FAIL/SKIP) ==="
        for (i = 1; i <= malformed; i++) print "  MALFORMED: " malformed_list[i]
        print ""
      }
      print "TOTALS: PASS=" pass " FAIL=" fail " SKIP=" skip " ZERO=" zero " MALFORMED=" malformed " ENUMERATED=" n
      if (zero > 0 || fail > 0 || malformed > 0) exit 1
      exit 0
    }
  ' "${files[@]}"
  summary_rc=$?
  rm -f "$order_file"
  if [[ "$header_rc" -ne 0 ]]; then
    return "$header_rc"
  fi
  return "$summary_rc"
}

# Run a test file, respecting --host-only mode, --batch/--only selection,
# --dry-run, and --ledger recording.
run_test() {
  local test_file="$1"
  local base
  base="$(basename "$test_file")"
  _RH_CALL_INDEX=$((_RH_CALL_INDEX + 1))

  if [[ "$_RH_MODE" == "enumerate" ]]; then
    _RH_FULL_ENUM+=("$base")
    return 0
  fi

  _rh_is_selected "$base" "$_RH_CALL_INDEX" || return 0

  if [[ "$_RH_MODE" == "list" ]]; then
    echo "$base"
    return 0
  fi

  if [[ "$RH_DRY_RUN" == "true" ]]; then
    echo "SKIP (dry-run): $base"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_TESTS+=("$base")
    _rh_ledger_row "$base" "SKIP" "dry-run" 0
    return 0
  fi

  if [[ "$HOST_ONLY_MODE" == "true" ]] && _is_needs_container "$test_file"; then
    echo "SKIP (needs container): $base"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_TESTS+=("$base")
    _rh_ledger_row "$base" "SKIP" "needs-container" 0
    return 0
  fi

  local t0 t1 rc out_file
  t0=$(date +%s)
  out_file="$(mktemp "${TMPDIR:-/tmp}/rh-test-out.XXXXXX")"
  rc=0
  # `|| rc=$?` (not `if !`) keeps set -e from aborting the suite while still
  # capturing the pipefail-adjusted exit status of the test body itself --
  # tee always succeeds, so pipefail (from `set -euo pipefail` at file top)
  # surfaces bash's exit code here, not tee's.
  bash "$test_file" | tee "$out_file" || rc=$?
  t1=$(date +%s)

  if [[ "$rc" -ne 0 ]]; then
    FAILED_TESTS+=("$base")
    _rh_ledger_row "$base" "FAIL" "" "$((t1 - t0))"
  elif grep -q '^SKIP[[:space:]:(]' "$out_file" 2>/dev/null && ! grep -q '^PASS' "$out_file" 2>/dev/null; then
    # rip-cage-pow0: exit 0 + a "SKIP" stdout sentinel at column 0 -- either
    # the repo's original "SKIP:" convention (test-msb-boot-smoke.sh comment
    # above) or one of the other in-repo spellings ("SKIP (NEEDS_CONTAINER /
    # RC_E2E): ...", "SKIP (reserved-scratch): ...", "SKIP C6: ...", etc --
    # rip-cage-pow0 round 2's blast-radius measurement found 21 files using a
    # non-colon spelling that the original '^SKIP:' match missed) -- plus
    # zero "PASS"-prefixed lines means the test body declared "precondition
    # absent, nothing checked" -- not "I ran and proved my guarantee". Ledger
    # SKIP, never PASS. The character class after SKIP (space, colon, open
    # paren) is deliberately narrow: it must NOT match "SKIPPED", "SKIPS", or
    # "SKIP_"-prefixed identifiers, which are prose/var-name usages, not a
    # skip sentinel.
    local _expect_no_skip=false
    if [[ -n "${RH_EXPECT_NO_SKIP_FILTER:-}" ]]; then
      local -a _epat
      IFS=',' read -ra _epat <<< "${RH_EXPECT_NO_SKIP_FILTER:-}"
      local _ep
      for _ep in "${_epat[@]}"; do
        # shellcheck disable=SC2254 # intentional glob match, mirrors _rh_matches_only
        case "$base" in
          $_ep) _expect_no_skip=true; break ;;
        esac
      done
    fi
    if $_expect_no_skip; then
      # A probe declared EXPECTED-TO-RUN in this configuration self-skipped
      # instead -- that is itself a regression (rip-cage-pow0's "the part
      # that actually protects coverage"), not a legitimate SKIP.
      echo "FAIL (expected to run, but self-skipped): $base"
      FAILED_TESTS+=("$base")
      _rh_ledger_row "$base" "FAIL" "expected-no-skip" "$((t1 - t0))"
    else
      SKIP_COUNT=$((SKIP_COUNT + 1))
      SKIPPED_TESTS+=("$base")
      _rh_ledger_row "$base" "SKIP" "self-skip" "$((t1 - t0))"
    fi
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    _rh_ledger_row "$base" "PASS" "" "$((t1 - t0))"
  fi
  rm -f "$out_file"
}

run_pytest() {
  # Usage: run_pytest <test_file_for_skip_check> <uv run args...>
  # The test_file arg is used only for --host-only classification; the remaining
  # args are passed verbatim to uv run.
  local test_file="$1"
  shift
  local base
  base="$(basename "$test_file")"
  _RH_CALL_INDEX=$((_RH_CALL_INDEX + 1))

  if [[ "$_RH_MODE" == "enumerate" ]]; then
    _RH_FULL_ENUM+=("$base")
    return 0
  fi

  _rh_is_selected "$base" "$_RH_CALL_INDEX" || return 0

  if [[ "$_RH_MODE" == "list" ]]; then
    echo "$base"
    return 0
  fi

  if [[ "$RH_DRY_RUN" == "true" ]]; then
    echo "SKIP (dry-run): $base"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_TESTS+=("$base")
    _rh_ledger_row "$base" "SKIP" "dry-run" 0
    return 0
  fi

  if [[ "$HOST_ONLY_MODE" == "true" ]] && _is_needs_container "$test_file"; then
    echo "SKIP (needs container): $base"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_TESTS+=("$base")
    _rh_ledger_row "$base" "SKIP" "needs-container" 0
    return 0
  fi

  local t0 t1 rc out_file
  t0=$(date +%s)
  out_file="$(mktemp "${TMPDIR:-/tmp}/rh-test-out.XXXXXX")"
  rc=0
  uv run "$@" | tee "$out_file" || rc=$?
  t1=$(date +%s)

  if [[ "$rc" -ne 0 ]]; then
    FAILED_TESTS+=("$base")
    _rh_ledger_row "$base" "FAIL" "" "$((t1 - t0))"
  elif grep -q '^SKIP[[:space:]:(]' "$out_file" 2>/dev/null && ! grep -q '^PASS' "$out_file" 2>/dev/null; then
    # rip-cage-pow0: same body-decided-SKIP classification as run_test above
    # (see that block's comment for the widened-spelling rationale).
    local _expect_no_skip=false
    if [[ -n "${RH_EXPECT_NO_SKIP_FILTER:-}" ]]; then
      local -a _epat
      IFS=',' read -ra _epat <<< "${RH_EXPECT_NO_SKIP_FILTER:-}"
      local _ep
      for _ep in "${_epat[@]}"; do
        # shellcheck disable=SC2254 # intentional glob match, mirrors _rh_matches_only
        case "$base" in
          $_ep) _expect_no_skip=true; break ;;
        esac
      done
    fi
    if $_expect_no_skip; then
      echo "FAIL (expected to run, but self-skipped): $base"
      FAILED_TESTS+=("$base")
      _rh_ledger_row "$base" "FAIL" "expected-no-skip" "$((t1 - t0))"
    else
      SKIP_COUNT=$((SKIP_COUNT + 1))
      SKIPPED_TESTS+=("$base")
      _rh_ledger_row "$base" "SKIP" "self-skip" "$((t1 - t0))"
    fi
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    _rh_ledger_row "$base" "PASS" "" "$((t1 - t0))"
  fi
  rm -f "$out_file"
}

# rip-cage-7atw.13: --list / --ledger-summary are enumerate-only modes --
# they never execute a test body, so they run before (and independent of)
# the config-sandbox/scratch-cage setup below. Both need the driver's own
# full ordered enumeration, which only exists once _run_all_tests has been
# defined -- hence _run_all_tests lives here, ahead of the sandbox setup.
_run_all_tests() {
  # Uncomment each line below after the audit step confirms pass or skip-guard:
  run_test "${SCRIPT_DIR}/test-rc-source-isolation.sh" # rip-cage-k2d5: rc source isolation — set -e must not leak when sourcing rc
  run_test "${SCRIPT_DIR}/test-rc-decomposition-structure.sh" # rip-cage-gto1: post-split structural invariants (strict-mode-per-module, fn-count, reachability, up<->reload coupling, top-level globals, lib/-boundary, cwd/libexec sourcing)
  run_test "${SCRIPT_DIR}/test-rc-commands.sh"
  run_test "${SCRIPT_DIR}/test-worktree-support.sh"
  run_test "${SCRIPT_DIR}/test-security-hardening.sh"
  run_test "${SCRIPT_DIR}/test-json-output.sh"
  run_test "${SCRIPT_DIR}/test-prerequisites.sh"
  run_test "${SCRIPT_DIR}/test-docker-daemon-hang.sh"
  run_test "${SCRIPT_DIR}/test-pull-first.sh"
  run_test "${SCRIPT_DIR}/test-dockerfile-sudoers.sh"
  run_test "${SCRIPT_DIR}/test-bd-wrapper.sh"
  run_test "${SCRIPT_DIR}/test-code-review-fixes.sh"
  run_test "${SCRIPT_DIR}/test-dg6.2.sh"
  run_test "${SCRIPT_DIR}/test-auth-refresh.sh"
  run_test "${SCRIPT_DIR}/test-pi-install.sh"
  run_test "${SCRIPT_DIR}/test-pi-auth-mount.sh"
  run_test "${SCRIPT_DIR}/test-pi-cage-context.sh"
  run_test "${SCRIPT_DIR}/test-pi-e2e.sh"
  run_test "${SCRIPT_DIR}/test-workspace-trust.sh"       # rip-cage-hhh.5: workspace base-URL redirect validator
  # test-egress-rules-gen.sh / test_egress_proxy.py / test_dns_decide.py /
  # test-firewall-tcp22.sh retired: they tested the in-cage egress
  # router/DNS-resolver/firewall engine, deleted per ADR-029 D2
  # (engine-deletion sweep, rip-cage-3vj2 / S4).
  run_pytest "${SCRIPT_DIR}/test_skill_server.py" --with pytest python -m pytest "${SCRIPT_DIR}/test_skill_server.py" -v   # rip-cage-nu91: skill-server MCP shim unit tests
  run_test "${SCRIPT_DIR}/test-up-msb-egress-config.sh"  # rip-cage-tsf2.8/tsf2.10.5: _up_build_egress_config_json config∪manifest egress union + post-split runtime-invariant regression (r1-F1: was missing from run-host.sh)
  run_test "${SCRIPT_DIR}/test-doctor-version-skew.sh"   # rip-cage-2cks: _doctor_bd_version_compare unit tests (host-only, no docker)
  run_test "${SCRIPT_DIR}/test-doctor-dead-mount.sh"     # rip-cage-uben: generic dead-handle detection over single-file bind mounts — stubbed docker, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-doctor-exec-source-deleted.sh"   # rip-cage-uod6 (charted from rip-cage-54q3; the rc exec half retired with the verb in rip-cage-ely4.10, so rc doctor carries the hint alone now): rc doctor names a deleted host workspace source with a Fix-hint instead of msb's misleading ENOENT-against-the-program-name text — fake msb PATH shim, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-cage-host-bridge-probe.sh"       # rip-cage-woox: _rc_probe_host_bridge preset-honoring + msb-first probe order, stubbed getent via RC_INIT_LIB_ONLY-guarded sourcing, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-host-scratch-root.sh"            # rip-cage-6v34.6: the suite's own scratch root stays short enough for msb's 104-byte socket budget and symlink-free; host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-rc-test-suite-continuation.sh" # rip-cage-83y6: rc test's non-json path runs all four in-cage suites even when an earlier one fails — stubbed msb, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-cage-claude-projects-host-bound.sh" # rip-cage-aa4t: _cage_claude_projects_host_bound predicate — stubbed msb, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-doctor-transcript-persistence.sh"   # rip-cage-aa4t: rc doctor transcript-persistence probe — stubbed msb, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-claude-bypass-preaccept.sh"         # rip-cage-k8vi: claude-session-wrapper pre-accepts bypassPermissionsModeAccepted in the writable per-session .claude.json — real wrapper on host via RC_REAL_CLAUDE_BIN stub, host-only, no live cage
  run_test "${SCRIPT_DIR}/test-denial-visibility.sh"     # rip-cage-jlu4: denial-visibility disambiguation (DNS-denial vs secret-violation) — stubbed msb, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-extract-credentials.sh"   # rip-cage-towm: keychain-extraction warning gated on no-usable-existing-creds — security shim + sandboxed HOME, host-only
  run_test "${SCRIPT_DIR}/test-doctor-runnability.sh"    # rip-cage-2cks: rc doctor cwd-floor + workspace-resolution live-cage checks (NEEDS_CONTAINER; guards rip-cage-0rng + rip-cage-aq70; schema-error sub-case additionally gated behind RC_DOCTOR_STALE_BD_IMAGE, self-skips visibly otherwise)
  run_test "${SCRIPT_DIR}/test-floor-probe.sh"          # rip-cage-ely4.12 / rip-cage-ely4.15: the fail-closed floor probe's contract against real images — the stock base boots and rc test reports every floor line; a USER-root extension and a chmod-o+w-guard extension each refuse the boot naming the property (NEEDS_CONTAINER, self-skips without docker+msb or on a base image predating the probe)
  run_test "${SCRIPT_DIR}/test-boot-descriptor.sh"      # rip-cage-ely4.11: the boot descriptor's contract in a LIVE cage — a declared daemon starts + health-checks + is a true no-op on re-init; a missing required field fails the boot naming it (NEEDS_CONTAINER, self-skips without docker+msb)
  run_test "${SCRIPT_DIR}/test-pi-cold-start-seed.sh"   # rip-cage-wo9: rc up seeds ~/.pi/agent/auth.json on cold start
  # Also retired with the manifest, for the same reason -- every case called a
  # deleted _manifest_* function: test-mount-seam-integration.sh,
  # test-pi-recipe-lifecycle.sh, test-pi-substrate-mounts.sh,
  # test-dcg-demotion.sh, test-pi-wrapper-glob.sh, test-skill-manifest-author.sh,
  # test-herdr-roster-resume-recipe.sh, test-multiplexer-registry-bake.sh,
  # test-build-flag-override.sh (the flag allowlist it tested is gone) and
  # test-seed-drift-stderr-scoping.sh.
  # The whole manifest test corpus (19 files), the manifest-authoring skill
  # test, the multiplexer registry-bake test, the build-flag-override test and
  # the seed-drift stderr-scoping test all retired with the manifest itself
  # (ADR-031 D4, rip-cage-ely4.11): they tested a schema, a validator, a flag
  # allowlist, a seed-drift stamp and a baked registry that no longer exist.
  # What replaces their coverage: test-boot-descriptor.sh (the descriptor
  # contract, in a live cage) and ADR-031 D5(b)'s floor probe on the built
  # image (rip-cage-ely4.12).
  run_test "${SCRIPT_DIR}/test-mount-mode-e2e.sh"       # rip-cage-wlwc.3: real-cage ro/rw behavioral probes (RE1-RE3; NEEDS_CONTAINER/RC_E2E, self-skips without RC_E2E=1)
  run_test "${SCRIPT_DIR}/test-multiplexer-composable.sh"        # rip-cage-61al.8: composability integration harness — live fakemux e2e + exhaustive grep-guard (G1 host-only; E1a-E1g self-skip via RC_E2E gate)
  # test-mediator-manifest.sh / test-mediator-lifecycle.sh /
  # test-mediator-validator.sh retired: the MEDIATOR archetype + its launch
  # machinery were deleted per ADR-029 D2 (engine-deletion sweep,
  # rip-cage-3vj2 / S4).
  run_test "${SCRIPT_DIR}/test-claude-concurrency.sh"    # rip-cage-p1p: per-session Claude config isolation (NEEDS_CONTAINER; self-skips if no running cage)
  run_test "${SCRIPT_DIR}/test-claude-json-seed-synthesis.sh" # rip-cage-vwka: R4 seed-synthesis for non-possession postures — synthesized-when-absent, not-clobbered, possession positive control, wrapper WARNING no-longer-fires/genuinely-broken-still-fires (NEEDS_CONTAINER; spins own cages, self-skips without docker/image)
  run_test "${SCRIPT_DIR}/test-cc-managed-settings-probe.sh"  # rip-cage-wlwc.1: D8 CC managed-settings anchor probe — enforces un-suppressibly + deny-wins? (NEEDS_CONTAINER+AUTH; self-skips if no cage or unauthed)
  run_test "${SCRIPT_DIR}/test-cc-dcg-managed-settings.sh"   # rip-cage-r9n4: DCG managed-settings regression — managed deny survives stripping ALL agent-writable layers (NEEDS_CONTAINER+AUTH; self-skips if no cage or unauthed)
  run_test "${SCRIPT_DIR}/test-multiplexer-lifecycle.sh"  # rip-cage-1f59.8: multiplexer lifecycle (none/tmux/herdr) + retirement + config-isolation (NEEDS_CONTAINER; self-skips without RC_E2E=1)
  # test-selftest-classifier.sh / test-selftest-mode-gating.sh /
  # test_selftest_endpoint.py / test-selftest-integration.sh retired: they
  # tested the in-cage firewall startup self-test guard (init-firewall.sh /
  # rip_cage_egress.py's reserved endpoint), deleted per ADR-029 D2
  # (engine-deletion sweep, rip-cage-3vj2 / S4).
  run_test "${SCRIPT_DIR}/test-scratch-cage-cleanup.sh"  # rip-cage-aqww/neu7.9: scratch-cage cleanup — D1 register-array helper + D2 detect-and-warn (never destroys); needs msb daemon + cached alpine image, self-skips without either
  run_test "${SCRIPT_DIR}/test-cleanup-failsafe.sh"      # rip-cage-neu7.9: committed repro — register-array CLEANUP fired on an EMPTY registry invokes the destroy command ZERO times (stubbed destroy, pure bash, no docker/msb dependency)
  run_test "${SCRIPT_DIR}/test-scratch-cage-registry.sh"        # rip-cage-sygz.2: the created-cage registry survives a SIGKILL that runs no trap, and test-pi-install.sh refuses a cage the suite did not create (stub rc + fake docker, host-only, no live cage)
  run_test "${SCRIPT_DIR}/test-production-image-tag-write-guard.sh"  # rip-cage-lh62: static recurrence guard — no un-allowlisted test may `docker tag`/`docker build -t` onto the operator's rip-cage:latest; carries its own negative controls, host-only, no docker call at all
  run_test "${SCRIPT_DIR}/test-scratch-cage-teardown-guard.sh"  # rip-cage-4cuh/22hn/qg25: static recurrence guard — an unpaired msb-remove teardown on an rc-up cage leaks rc-state-*/rc-history-* forever; volume-attachment gated (a direct msb-create cage has no volumes to orphan), host-only
  run_test "${SCRIPT_DIR}/test-real-home-pi-write-guard.sh"     # rip-cage-bh0r: static recurrence guard — a write reaching a real, unsandboxed ${HOME}/.pi path clobbers a live symlink target (dotpi's tracked AGENTS.md, 2026-09-03); host-only
  run_test "${SCRIPT_DIR}/test-shared-scratch-path-guard.sh"    # rip-cage-k13u: static recurrence guard — a FIXED shared scratch path (the golden-master under-scrub diff, the repo-root VERSION backup) makes concurrent invocations delete each other's files, so S5 flakes on timing instead of on truth; carries its own negative controls, host-only
  run_test "${SCRIPT_DIR}/test-destroy-orphaned-volumes.sh" # rip-cage-o5ie: rc destroy reaps rc-state-/rc-history- volumes by exact derived name even when the sandbox is already absent; exact-name-only cleanup + negative-control decoy volume, no sandbox boot needed, self-skips without msb
  run_test "${SCRIPT_DIR}/test-agent-readability.sh"     # rip-cage-7wc: host-side fixture tests for agent *.md readability classification
  run_test "${SCRIPT_DIR}/test-agent-mail-concurrent.sh" # rip-cage-swv: two concurrent pi agents coordinate via am CLI (NEEDS_CONTAINER + RC_E2E)
  run_test "${SCRIPT_DIR}/test-multiplexer-agent-e2e.sh" # rip-cage-w621.7: pi agent through tmux mux surface with >=2 distinct tool invocations (NEEDS_CONTAINER + RC_E2E)

  # rip-cage-9oyh: rc behavior-preservation golden-master harness (baseline
  # captured at HEAD) + §3/§4 seam and gap-fill tests. All container-free
  # (content-keyed fake-docker PATH shim under tests/golden-master/lib/fake-bin;
  # see docs/2026-07-08-rc-decomposition-harness.md rev.2). The two-directional
  # scrub self-check (tests/golden-master/self-check.sh) is intentionally NOT
  # wired here — it's a meta-check of the harness's own scrub soundness, run
  # on-demand when cases.sh/scrub.sh change, not a per-commit regression gate.
  run_test "${SCRIPT_DIR}/golden-master/capture.sh"       # §1/§2: byte-identity check of the recorded baseline (--check, the default)
  run_test "${SCRIPT_DIR}/test-golden-master-sandbox-isolation.sh" # rip-cage-6qxs: GM_ROOT per-process-uniqueness (structural) + concurrent sandbox-sourcing processes don't cross-contaminate (stress)
  # rip-cage-5iti (S10, msb migration test-suite port): test-up-run-args-
  # full-chain.sh RETIRED. Its hand-replica of cmd_up's create-path (never
  # updated past the ssh-cluster retirement) had drifted onto asserting
  # RETIRED machinery (rc.mediator-ca-env / rc.egress.mode / an
  # egress-rules.yaml bind mount into the deleted in-cage engine) as its
  # own "chain completion" proof -- a rule-presence assertion on dead code
  # that could never catch a real regression (adversarial review finding,
  # 2026-07-13). test-up-run-args-e2e.sh below drives the REAL `cmd_up`
  # (not a hand-copy) and captures the REAL `msb create` argv, so it
  # already covers the full post-translation msb-flag surface with
  # strictly higher fidelity (e.g. it captures `rc.config-loaded` and the
  # real `--net-default deny` egress flag, neither of which the retired
  # replica ever modeled) -- no separate helper-level companion needed.
  run_test "${SCRIPT_DIR}/test-up-run-args-e2e.sh"        # §3(i) CRITICAL gate, e2e: real cmd_up through the content-keyed docker+msb shims
  run_test "${SCRIPT_DIR}/test-build-msb-load.sh"         # rip-cage-7dkq (S1, msb migration): _build_msb_load unit tests (fake docker+msb PATH shims, host-only, no live daemon)
  run_test "${SCRIPT_DIR}/test-up-msb-load-wiring.sh"     # rip-cage-0v47: rc up's new-container/image-absent provisioning block calls _build_msb_load then _msb_warn_image_layer_drift IN THE SAME SHELL right after a successful _pull_or_build (fake docker+msb PATH shims + extract-and-eval against scratch-mutated copies, host-only, no live daemon, never a real cage)
  run_test "${SCRIPT_DIR}/test-msb-boot-smoke.sh"         # rip-cage-7dkq (S1, msb migration): effect-based docker-save->msb-load->boot->in-guest-exec smoke root + negative control (NEEDS_CONTAINER+NEEDS_MSB; self-skips without docker/msb/pre-built image)

  # rip-cage-b6ia: previously-dark test files, audited 2026-06-09 and wired.
  # Host-tier (run on every invocation):
  run_test "${SCRIPT_DIR}/test-bd-host-preflight.sh"    # _bd_host_preflight dolt-server preflight helper (host-only)
  run_test "${SCRIPT_DIR}/test-container-name.sh"       # rip-cage-a0h item (c): container_name() collision-hash disambiguation regression — docker PATH-shim + real cmd_up --dry-run, host-only
  run_test "${SCRIPT_DIR}/test-lfs-warning.sh"          # rc --dry-run up LFS pointer-stub scan + silent-exit-1 regression
  run_test "${SCRIPT_DIR}/test-symlink-follow.sh"       # symlink-follow scanner + fingerprint + denylist gating (unsets RC_CONFIG_GLOBAL)
  run_test "${SCRIPT_DIR}/test-image-drift-resume.sh"    # rip-cage-jnvb: rc up image-ID drift guard on resume — full-rc-through-fake-docker-shim T1-T6, host-only, no live container needed
  run_test "${SCRIPT_DIR}/test-doctor-json-doc.sh"       # rip-cage-bbjn: rc doctor --output json top-level field set derived from cli/doctor.sh vs documented in docs/reference/cli-reference.md, both directions, host-only static check
  run_test "${SCRIPT_DIR}/test-adr-evolution-notes.sh"  # rip-cage-ely4.8: every decision ADR-031 evolves/honors/retires cites ADR-031 in place, and INDEX.md lists it; host-only static check over docs/decisions/
  # Container-tier (NEEDS_CONTAINER above; self-skip under --host-only, run on full invocation):
  run_test "${SCRIPT_DIR}/test-session-persistence.sh"  # dn2 projects/sessions persist-to-host (Phase 3 container)
  run_test "${SCRIPT_DIR}/test-pi-no-extensions.sh"     # rip-cage-sn1h: LOCKED-VARIANT-ONLY probe (evil.ts NOT loaded + DCG still denies); self-skips under the shipped OPEN default (rip-cage-p35a.1 / ADR-027 D1)
  run_test "${SCRIPT_DIR}/test-skills.sh"               # meta-skill MCP handshake + cage-path/settings inside cage
  run_test "${SCRIPT_DIR}/test-rh-expected-skip-fixture.sh" # rip-cage-pow0: deterministic always-self-skip fixture proving the SKIP-vs-PASS ledger classification + --expect-no-skip's SKIP-becomes-FAIL assertion; host-only, no container
  run_test "${SCRIPT_DIR}/test-rh-non-colon-skip-fixture.sh" # rip-cage-pow0 round 2: deterministic always-self-skip fixture using a non-colon "SKIP (...)" sentinel spelling, regression-protecting the widened '^SKIP[[:space:]:(]' match; host-only, no container
}

if [[ "$RH_LIST_MODE" == "true" ]]; then
  # "list" mode: apply --batch/--only selection like a real run would, but
  # just echo the basename instead of executing (a selection preview).
  _RH_MODE="list"
  _run_all_tests
  exit 0
fi

if [[ "$RH_LEDGER_SUMMARY_MODE" == "true" ]]; then
  _RH_MODE="enumerate"
  _run_all_tests
  _rh_ledger_summary "${RH_LEDGER_SUMMARY_FILES[@]}"
  exit $?
fi

# rip-cage-w3lq: the config-sandbox setup (RC_CONFIG_GLOBAL + XDG_CONFIG_HOME
# pointed at a mktemp dir with an empty-denylist config.yaml + zero-byte
# tools.yaml; deliberately NOT exporting RC_MANIFEST_GLOBAL) is extracted into
# a shared lib so tests/run-one.sh (single-file wrapper) can build the
# identical sandbox. See tests/_host-sandbox-lib.sh for the full rationale
# (ADR-023 secret-path denylist / rip-cage-4c5.8 manifest fixture / the
# RC_MANIFEST_GLOBAL isolation contract) — preserved there verbatim.
# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"

# ---------------------------------------------------------------------------
# Self-healing DETECT-AND-WARN (rip-cage-neu7.9, post code-personal destroy
# incident; formerly rip-cage-aqww D2's enumerate-and-destroy sweep): flag
# leaked scratch-cage containers whose rc.source.path label is under the OS
# temp root — READ-ONLY, never destroys.
#
# INCIDENT CONTEXT: the prior D2 sweep enumerated every msb sandbox (`msb
# list`) and destroyed any whose rc.source.path label PREFIX-matched a temp
# root — a computed/glob match against every cage, not an explicit
# this-run-created-name allowlist. Adversarial review (rip-cage-neu7.9)
# judged that fragile SHAPE (not just the earlier /*-glob degeneration
# already patched in rip-cage-neu7.8) unsafe in principle: a cage the runner
# did not create must be structurally unreachable by any destroy call. The
# brain's ruling: rely on per-run self-reap (individual tests already destroy
# their own cages by explicit name / register-array — see
# tests/_scratch-cage-lib.sh, the exemplar this converts toward) and replace
# this cross-run reconciler with a read-only detect-and-warn: name the
# leftover cage + its source path + a suggested `rc destroy <name>`
# command a human can run, and stop there.
#
# DISCRIMINATOR (unchanged from the former sweep): every cage carries an
# rc.source.path label (cli/up.sh:'rc.source.path='); the value is already realpath-resolved at
# creation (cli/lib/path.sh:validate_path).  On macOS $TMPDIR is /var/folders/... but the label
# is /private/var/folders/... — resolve the temp root before comparing, NOT
# the label (the cage workspace dir may already be deleted, and BSD realpath
# returns empty on missing paths, which would miss it).
# ---------------------------------------------------------------------------
_SWEEP_TEMP_ROOTS=()
_sweep_init_temp_roots() {
  local _rt
  _rt=$(realpath "${TMPDIR:-/tmp}" 2>/dev/null || true)
  [[ -n "$_rt" ]] && _SWEEP_TEMP_ROOTS+=("$_rt")
  # macOS /private/var/folders, /tmp, /private/tmp — add as literals so the
  # sweep still works even if realpath above gives only one form.
  for _lit in "/private/var/folders" "/tmp" "/private/tmp"; do
    local _already=0
    local _existing
    for _existing in "${_SWEEP_TEMP_ROOTS[@]+"${_SWEEP_TEMP_ROOTS[@]}"}"; do
      [[ "$_existing" == "$_lit" ]] && _already=1
    done
    [[ "$_already" -eq 0 ]] && _SWEEP_TEMP_ROOTS+=("$_lit")
  done
}
_sweep_init_temp_roots

# rip-cage-5iti (S10, msb migration test-suite port): retargeted onto msb --
# was `docker ps --filter label=... | docker inspect`. `msb list --label
# KEY=VALUE` only exact-matches (no docker-style presence-only `label=KEY`
# filter), so this enumerates every sandbox name via `msb list --format
# json` and reads each one's `rc.source.path` label via `msb inspect`
# (mirrors _msb_label's `.config.labels[$k]` shape) -- same discriminator
# (label value must be under one of the swept temp roots) as before.
#
# rip-cage-neu7.9: this function used to run `rc destroy "$_cname"`
# here. It no longer does — READ-ONLY, prints a loud warning (name + source
# path + suggested destroy command) to stderr and moves on. No enumeration
# result is ever fed to a destroy call in this function's body.
_warn_leftover_scratch_cages() {
  if ! command -v msb >/dev/null 2>&1; then
    return 0
  fi
  local _cname _raw_sp _root
  for _cname in $(msb list --format json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true); do
    _raw_sp=$(msb inspect "$_cname" --format json 2>/dev/null | jq -r '.config.labels["rc.source.path"] // empty' 2>/dev/null || true)
    [[ -z "$_raw_sp" ]] && continue
    for _root in "${_SWEEP_TEMP_ROOTS[@]+"${_SWEEP_TEMP_ROOTS[@]}"}"; do
      if [[ "$_raw_sp" == "${_root}"/* || "$_raw_sp" == "${_root}" ]]; then
        echo "WARNING: leftover scratch cage detected: ${_cname} (source path: ${_raw_sp})" >&2
        echo "  This test runner did not create it this run and will NOT destroy it." >&2
        echo "  If it is stale debris, clean it up yourself: rc destroy ${_cname}" >&2
        break
      fi
    done
  done
}

# Build the shared config sandbox (see tests/_host-sandbox-lib.sh) — sets
# _HOST_SANDBOX_CFG_DIR and exports RC_CONFIG_GLOBAL/XDG_CONFIG_HOME to point
# at it (same ${VAR:-default} precedence as before this extraction).
_host_sandbox_setup

# Both residue passes run at START of run, sweep before warn so the warning
# names only what is actually left (rip-cage-sygz.2):
#
#   1. scratch_cage_sweep_registry — DESTROYS the cages a killed run stranded
#      (a SIGKILL runs no EXIT trap, so they outlive the run that made them).
#      Names come only from the registry file this harness itself wrote, and
#      each one must still carry a harness scratch prefix to be touched at
#      all. Both guards, and why rip-cage-neu7.9 permits this at all, are in
#      tests/_scratch-cage-lib.sh's own header.
#   2. _warn_leftover_scratch_cages — READ-ONLY. It ENUMERATES, so it may
#      never destroy (neu7.9). It is the backstop for what the sweep refuses
#      or never knew about: a cage from before the registry existed, or one
#      whose registry file was wiped.
# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
scratch_cage_sweep_registry
_warn_leftover_scratch_cages

# EXIT/INT/TERM handler: config-fixture cleanup ONLY. rip-cage-neu7.9: the
# former scratch-cage sweep is NOT run here — it ran an enumerate-and-destroy
# pass on every EXIT/INT/TERM (the highest run-frequency call site of the
# dangerous shape). Individual tests self-reap their own cages by explicit
# name (tests/_scratch-cage-lib.sh's register-array trap); this cleanup path
# must never enumerate-and-destroy a cage the runner did not create.
_run_host_cleanup() {
  _host_sandbox_cleanup
}
trap '_run_host_cleanup' EXIT INT TERM

# Real pass: write the run header (if a ledger is configured), reset the
# call-ordinal counter so it starts fresh at 1 (matches --list/--ledger-
# summary's enumerate pass, which uses the identical call sequence), and
# actually execute the selected tests.
_rh_ledger_write_header
_RH_MODE="run"
_RH_CALL_INDEX=0
_run_all_tests

echo ""
echo "TOTALS: PASS=${PASS_COUNT} FAIL=${#FAILED_TESTS[@]} SKIP=${SKIP_COUNT}"
if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
  echo "  SKIPPED:"
  for _st in "${SKIPPED_TESTS[@]}"; do
    echo "    - ${_st}"
  done
fi
# rip-cage-or84: advisory-only, never touches exit status (see the
# function's own header comment).
_rh_check_image_tag_moved
echo "=== run-host.sh complete ==="

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo ""
  echo "=== ${#FAILED_TESTS[@]} TEST FILE(S) FAILED ==="
  for _ft in "${FAILED_TESTS[@]}"; do
    echo "  FAILED: ${_ft}"
  done
  exit 1
fi
