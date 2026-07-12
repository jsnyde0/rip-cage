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
#
# rip-cage-7atw.13: --batch/--only/--ledger/--ledger-summary let a full-suite
# run be split into resumable, unioned slices (mac-mini background-task
# lifetime kills runs at ~1hr) while --ledger-summary's zero-row detection
# proves the union is complete. Default invocation (no flags) is unchanged.
#
# HOST-ONLY INVARIANT: rc exits immediately when /.dockerenv is present.
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
RH_DRY_RUN=false
RH_LIST_MODE=false
RH_LEDGER_SUMMARY_MODE=false
RH_LEDGER_SUMMARY_FILES=()

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

# Tests that REQUIRE a running rip-cage container or live API key.
# Each entry carries a one-line comment explaining why.
NEEDS_CONTAINER=(
  "test-agent-cli.sh"        # calls rc up to create a live container; exercises full lifecycle
  "test-pi-e2e.sh"           # calls rc up AND requires ~/.pi/agent/auth.json with valid pi credentials
  "test-pi-install.sh"       # runs docker run --rm rip-cage:latest; requires a pre-built rip-cage image
  "test-pi-auth-mount.sh"    # calls rc up to create a live container; inspects container env + mounts
  "test-pi-cage-context.sh"  # calls rc up to create a live container; inspects CLAUDE.md inside cage
  "test-claude-concurrency.sh" # requires a live rip-cage container with Claude auth (ANTHROPIC_API_KEY or OAuth)
  "test-claude-json-seed-synthesis.sh" # rip-cage-vwka: spins its own real cages via rc up (non-possession + possession) to verify R4 seed synthesis; requires docker + a pre-built rip-cage image
  "test-multiplexer-lifecycle.sh" # requires a live rip-cage container; exercises multiplexer lifecycle (none/tmux/herdr) + retirement + config-isolation (rip-cage-1f59.8)
  "test-agent-mail-concurrent.sh" # requires RC_E2E=1 + pi auth + agent_mail fixture image; proves two concurrent pi agents coordinate via am CLI
  "test-session-persistence.sh" # Phase 3 calls rc up + docker exec for dn2 projects/sessions persist-to-host (rip-cage-b6ia)
  "test-pi-no-extensions.sh"  # rip-cage-sn1h: LOCKED-VARIANT-ONLY probe; requires running cage; self-skips under shipped OPEN default (rip-cage-p35a.1 / ADR-027 D1)
  "test-skills.sh"            # live meta-skill MCP handshake + cage-path/settings assertions inside a container (rip-cage-b6ia)
  "test-multiplexer-agent-e2e.sh" # requires RC_E2E=1 + pi auth; proves pi agent does real work THROUGH the tmux attach surface with >=2 distinct tool invocations (rip-cage-w621.7)
  "test-multiplexer-composable.sh" # E1 tier builds + runs a cage; G1 host-only grep-guards run always (rip-cage-61al.8)
  "test-symlink-follow.sh"    # needs a non-reserved writable scratch dir for symlink targets; on Linux every writable top-level (/home,/tmp,/var) is in rc's FHS-reserved set (rc:1511-1513), so it only runs on macOS (mktemp→/private/var dodges rc's deliberate non-canonicalization). Not "needs a cage" but host-only-Linux-incompatible (rip-cage-woow)
  "test-cc-managed-settings-probe.sh" # rip-cage-wlwc.1: D8 CC managed-settings anchor probe — requires live authed cage + API call; self-skips if no cage or unauthed (NEEDS_CONTAINER+AUTH)
  "test-cc-dcg-managed-settings.sh"  # rip-cage-r9n4: DCG managed-settings regression — proves managed deny survives stripping ALL agent-writable layers; requires live authed cage (NEEDS_CONTAINER+AUTH)
  "test-mount-mode-e2e.sh"           # rip-cage-wlwc.3: real-cage ro/rw behavioral probes (RE1-RE3); self-skips without RC_E2E=1
  "test-doctor-runnability.sh"       # rip-cage-2cks: spins live cages (rc up + docker run) to exercise rc doctor's cwd/workspace-resolution probes; self-skips without docker or host bd
  "test-msb-boot-smoke.sh"           # rip-cage-7dkq (S1, msb migration): needs live docker + live msb + a pre-built rip-cage:latest image to actually boot a cage; self-skips (SKIP:, exit 0) without any of the three
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
_rh_ledger_write_header() {
  [[ -z "$RH_LEDGER_PATH" ]] && return 0
  local commit img_digest e2e_flag ts
  if [[ -n "${RC_TEST_STAMP_COMMIT:-}" ]]; then
    commit="$RC_TEST_STAMP_COMMIT"
  else
    commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  fi
  if [[ -n "${RC_TEST_STAMP_IMAGE_DIGEST:-}" ]]; then
    img_digest="$RC_TEST_STAMP_IMAGE_DIGEST"
  else
    img_digest="unavailable"
    if command -v docker >/dev/null 2>&1; then
      img_digest="$(docker image inspect --format '{{.Id}}' rip-cage:latest 2>/dev/null || true)"
      [[ -z "$img_digest" ]] && img_digest="unavailable"
    fi
  fi
  e2e_flag="${RC_E2E:-0}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '#RUN commit=%s image_digest=%s rc_e2e=%s timestamp=%s\n' "$commit" "$img_digest" "$e2e_flag" "$ts" >> "$RH_LEDGER_PATH"
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
    _rh_ledger_row "$base" "SKIP" "dry-run" 0
    return 0
  fi

  if [[ "$HOST_ONLY_MODE" == "true" ]] && _is_needs_container "$test_file"; then
    echo "SKIP (needs container): $base"
    _rh_ledger_row "$base" "SKIP" "needs-container" 0
    return 0
  fi

  local t0 t1
  t0=$(date +%s)
  # `if !` keeps set -e from aborting the suite; record the failure and continue.
  if ! bash "$test_file"; then
    FAILED_TESTS+=("$base")
    t1=$(date +%s)
    _rh_ledger_row "$base" "FAIL" "" "$((t1 - t0))"
  else
    t1=$(date +%s)
    _rh_ledger_row "$base" "PASS" "" "$((t1 - t0))"
  fi
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
    _rh_ledger_row "$base" "SKIP" "dry-run" 0
    return 0
  fi

  if [[ "$HOST_ONLY_MODE" == "true" ]] && _is_needs_container "$test_file"; then
    echo "SKIP (needs container): $base"
    _rh_ledger_row "$base" "SKIP" "needs-container" 0
    return 0
  fi

  local t0 t1
  t0=$(date +%s)
  if ! uv run "$@"; then
    FAILED_TESTS+=("$base")
    t1=$(date +%s)
    _rh_ledger_row "$base" "FAIL" "" "$((t1 - t0))"
  else
    t1=$(date +%s)
    _rh_ledger_row "$base" "PASS" "" "$((t1 - t0))"
  fi
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
  run_test "${SCRIPT_DIR}/test-agent-cli.sh"
  run_test "${SCRIPT_DIR}/test-code-review-fixes.sh"
  run_test "${SCRIPT_DIR}/test-dg6.2.sh"
  run_test "${SCRIPT_DIR}/test-auth-refresh.sh"
  run_test "${SCRIPT_DIR}/test-completions.sh"
  run_test "${SCRIPT_DIR}/test-pi-install.sh"
  run_test "${SCRIPT_DIR}/test-pi-auth-mount.sh"
  run_test "${SCRIPT_DIR}/test-pi-cage-context.sh"
  run_test "${SCRIPT_DIR}/test-pi-e2e.sh"
  run_test "${SCRIPT_DIR}/test-secret-path-denylist.sh"  # tests/test-secret-path-denylist.sh
  run_test "${SCRIPT_DIR}/test-workspace-trust.sh"       # rip-cage-hhh.5: workspace base-URL redirect validator
  # test-egress-rules-gen.sh / test_egress_proxy.py / test_dns_decide.py /
  # test-firewall-tcp22.sh retired: they tested the in-cage egress
  # router/DNS-resolver/firewall engine, deleted per ADR-029 D2
  # (engine-deletion sweep, rip-cage-3vj2 / S4).
  run_pytest "${SCRIPT_DIR}/test_skill_server.py" --with pytest python -m pytest "${SCRIPT_DIR}/test_skill_server.py" -v   # rip-cage-nu91: skill-server MCP shim unit tests
  run_test "${SCRIPT_DIR}/test-rc-reload.sh"             # rip-cage-hhh.4: rc reload snapshot format + diff generalization
  run_test "${SCRIPT_DIR}/test-rc-allowlist.sh"          # rip-cage-hhh.6: rc allowlist add/show/promote + D10 host-side guard
  run_test "${SCRIPT_DIR}/test-ls-mode-source.sh"        # rip-cage-hhh.6: rc ls/doctor mode read from source .rip-cage.yaml not stale label
  run_test "${SCRIPT_DIR}/test-doctor-version-skew.sh"   # rip-cage-2cks: _doctor_bd_version_compare unit tests (host-only, no docker)
  run_test "${SCRIPT_DIR}/test-doctor-dead-mount.sh"     # rip-cage-uben: generic dead-handle detection over single-file bind mounts — stubbed docker, host-only, no live cage needed
  run_test "${SCRIPT_DIR}/test-extract-credentials.sh"   # rip-cage-towm: keychain-extraction warning gated on no-usable-existing-creds — security shim + sandboxed HOME, host-only
  run_test "${SCRIPT_DIR}/test-doctor-runnability.sh"    # rip-cage-2cks: rc doctor cwd-floor + workspace-resolution live-cage checks (NEEDS_CONTAINER; guards rip-cage-0rng + rip-cage-aq70; schema-error sub-case additionally gated behind RC_DOCTOR_STALE_BD_IMAGE, self-skips visibly otherwise)
  run_test "${SCRIPT_DIR}/test-dcg-policy.sh"            # rip-cage-hhh.11.2: DCG host-adoptable policy (ADR-025 D1/D5)
  run_test "${SCRIPT_DIR}/test-auto-seed.sh"             # rip-cage-j86: rc up auto-seeds global config on first run
  run_test "${SCRIPT_DIR}/test-manifest-seed-drift.sh"   # rip-cage-6vt9: manifest seed-drift detection (rc build) + rc manifest reconcile — sibling of rip-cage-jnvb (stale image on resume)
  run_test "${SCRIPT_DIR}/test-pi-cold-start-seed.sh"   # rip-cage-wo9: rc up seeds ~/.pi/agent/auth.json on cold start
  run_test "${SCRIPT_DIR}/test-manifest-schema.sh"       # rip-cage-4c5.1: tool manifest schema/loader (host-only)
  # NOTE: T1 cases are host-only; T2 (NEEDS_CONTAINER) self-skips via RC_E2E gate.
  # The e2e-tier wiring + driver-level fixture for T2 is rip-cage-4c5.8's job.
  run_test "${SCRIPT_DIR}/test-manifest-tool.sh"         # rip-cage-4c5.2: TOOL install-step generation (host-only T1); e2e self-skips via RC_E2E gate
  run_test "${SCRIPT_DIR}/test-manifest-tool-init-hook.sh" # rip-cage-p35a.2: TOOL archetype 'init' agent-context boot-hook seam (host-only T1a-T1k); e2e T2a/T2b self-skip via RC_E2E gate
  run_test "${SCRIPT_DIR}/test-pi-recipe-lifecycle.sh"   # rip-cage-p35a.3: pi-recipe owns full lifecycle — fwp3 mkdir relocated to init hook, base-init de-pi audit, dist/e2e-fixture sync, --model pin mechanism-not-default (host-only T1a-T1i)
  run_test "${SCRIPT_DIR}/test-manifest-egress.sh"       # rip-cage-4c5.3: egress+mounts floor (host-only E1/E1b/E2/E3); e2e self-skips via RC_E2E gate
  run_test "${SCRIPT_DIR}/test-manifest-shell.sh"        # rip-cage-4c5.4: SHELL-INTEGRATION shell_init baking (host-only T1); e2e self-skips via RC_E2E gate
  run_test "${SCRIPT_DIR}/test-manifest-daemon.sh"       # rip-cage-4c5.5: IN-CAGE-DAEMON lifecycle (host-only T1); e2e self-skips via RC_E2E gate
  run_test "${SCRIPT_DIR}/test-manifest-agent-mail.sh"   # rip-cage-4c5.6: agent_mail daemon fixture (host-only T1); e2e self-skips via RC_E2E gate; T2d auth-gated
  run_test "${SCRIPT_DIR}/test-manifest-cross.sh"        # rip-cage-4c5.8: cross-cutting integration regressions (H1/H2 always; C1/C2/C3 self-skip via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-manifest-herdr.sh"        # rip-cage-1f59.5: herdr TOOL fixture (T1a-T1g always; T2a-T2d self-skip via RC_E2E gate; T2d = ADR-006 D8 auto-install regression guard)
  run_test "${SCRIPT_DIR}/test-manifest-cm.sh"           # rip-cage-l0u2.4: cm binary + mount e2e proof (T1a always; T2a-T2d self-skip via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-manifest-mounts.sh"      # rip-cage-buuo.1: manifest mounts schema + consumer (host-only MV1/MH*/MD1/MC*; ME1 self-skips via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-manifest-source.sh"      # rip-cage-buuo.2: from-source builder stage schema + codegen (host-only S1-S10; SE1 self-skips via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-manifest-security.sh"   # rip-cage-buuo.3: binary-root-owned + build-isolation assertions (host-only B1a-d/BI1a-h; BE1-BE2 self-skip via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-manifest-mount-mode.sh"  # rip-cage-wlwc.3: per-asset ro/rw mount mode + root_owned_required validator (MS1-MS8/MA1-MA4/MR1-MR5/MD1-MD2 host-only; RE1-RE3 real-cage in test-mount-mode-e2e.sh)
  run_test "${SCRIPT_DIR}/test-mount-mode-e2e.sh"       # rip-cage-wlwc.3: real-cage ro/rw behavioral probes (RE1-RE3; NEEDS_CONTAINER/RC_E2E, self-skips without RC_E2E=1)
  run_test "${SCRIPT_DIR}/test-manifest-multiplexer-validate.sh" # rip-cage-61al.1: MULTIPLEXER archetype validation (T1a-T1m host-only)
  run_test "${SCRIPT_DIR}/test-multiplexer-registry-bake.sh"     # rip-cage-61al.2: MULTIPLEXER registry bake + label + reference reader (T1a-T1g host-only; T2a-T2e self-skip via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-multiplexer-config-dynamic.sh"    # rip-cage-61al.4: dynamic session.multiplexer schema + config-validate (T1a-T1e host-only; T2a-T2c self-skip via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-multiplexer-composable.sh"        # rip-cage-61al.8: composability integration harness — live fakemux e2e + exhaustive grep-guard (G1 host-only; E1a-E1g self-skip via RC_E2E gate)
  # test-mediator-manifest.sh / test-mediator-lifecycle.sh /
  # test-mediator-validator.sh retired: the MEDIATOR archetype + its launch
  # machinery were deleted per ADR-029 D2 (engine-deletion sweep,
  # rip-cage-3vj2 / S4).
  run_test "${SCRIPT_DIR}/test-credential-mounts.sh"             # rip-cage-seqc.4: config-gated credential mounts — schema / mount-absence / symlink-follow-leaf / fingerprint / extraction-skip / resume-guard (CM1-CM11 host-only)
  run_test "${SCRIPT_DIR}/test-skill-manifest-author.sh" # rip-cage-buuo.4: repo-shipped skill — skill well-formed + cm worked example passes _manifest_validate (SA1-SA7 host-only)
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
  run_test "${SCRIPT_DIR}/test-scratch-cage-cleanup.sh"  # rip-cage-aqww: scratch-cage cleanup helper (D1 lib + D2 sweep) — needs docker daemon; self-skips without docker
  run_test "${SCRIPT_DIR}/test-agent-readability.sh"     # rip-cage-7wc: host-side fixture tests for agent *.md readability classification
  run_test "${SCRIPT_DIR}/test-agent-mail-concurrent.sh" # rip-cage-swv: two concurrent pi agents coordinate via am CLI (NEEDS_CONTAINER + RC_E2E)
  run_test "${SCRIPT_DIR}/test-multiplexer-agent-e2e.sh" # rip-cage-w621.7: pi agent through tmux mux surface with >=2 distinct tool invocations (NEEDS_CONTAINER + RC_E2E)
  run_test "${SCRIPT_DIR}/test-allowed-roots-bypass.sh"  # rip-cage-36j: RC_ALLOWED_ROOTS bypass regression net (symlink/redirect cases)

  # rip-cage-9oyh: rc behavior-preservation golden-master harness (baseline
  # captured at HEAD) + §3/§4 seam and gap-fill tests. All container-free
  # (content-keyed fake-docker PATH shim under tests/golden-master/lib/fake-bin;
  # see docs/2026-07-08-rc-decomposition-harness.md rev.2). The two-directional
  # scrub self-check (tests/golden-master/self-check.sh) is intentionally NOT
  # wired here — it's a meta-check of the harness's own scrub soundness, run
  # on-demand when cases.sh/scrub.sh change, not a per-commit regression gate.
  run_test "${SCRIPT_DIR}/golden-master/capture.sh"       # §1/§2: byte-identity check of the recorded baseline (--check, the default)
  run_test "${SCRIPT_DIR}/test-golden-master-sandbox-isolation.sh" # rip-cage-6qxs: GM_ROOT per-process-uniqueness (structural) + concurrent sandbox-sourcing processes don't cross-contaminate (stress)
  run_test "${SCRIPT_DIR}/test-up-run-args-full-chain.sh" # §3(i) CRITICAL gate, helper-level: full create-path _UP_RUN_ARGS replica
  run_test "${SCRIPT_DIR}/test-up-run-args-e2e.sh"        # §3(i) CRITICAL gate, e2e: real cmd_up through the content-keyed docker shim
  run_test "${SCRIPT_DIR}/test-up-validate-warning-seam.sh" # §3(iii): RC_VALIDATE_WARNING write (validate_path) -> read (_up_json_output) seam
  run_test "${SCRIPT_DIR}/test-reload-exit-trap-seam.sh"  # §3(vi): cmd_reload's EXIT-trap lock_dir cleanup (golden-master-invisible filesystem effect)
  run_test "${SCRIPT_DIR}/test-generate-dockerfile.sh"    # §4 gap-fill: rc generate-dockerfile (bundled + from-source structural assertions)
  run_test "${SCRIPT_DIR}/test-build-msb-load.sh"         # rip-cage-7dkq (S1, msb migration): _build_msb_load unit tests (fake docker+msb PATH shims, host-only, no live daemon)
  run_test "${SCRIPT_DIR}/test-msb-boot-smoke.sh"         # rip-cage-7dkq (S1, msb migration): effect-based docker-save->msb-load->boot->in-guest-exec smoke root + negative control (NEEDS_CONTAINER+NEEDS_MSB; self-skips without docker/msb/pre-built image)
  run_test "${SCRIPT_DIR}/test-rc-setup.sh"               # §4 gap-fill: rc setup idempotency (zsh/bash, relaxed eval-line match)
  run_test "${SCRIPT_DIR}/test-manifest-reconcile-verb.sh" # §4 gap-fill: rc manifest reconcile backup-before-overwrite + validation-abort
  run_test "${SCRIPT_DIR}/test-rc-install.sh"             # §4 gap-fill: rc install idempotency + --yes/--force/no-TTY matrix
  run_test "${SCRIPT_DIR}/test-attach-exec-errors.sh"     # §4 gap-fill: attach/exec error-path matrix

  # rip-cage-b6ia: previously-dark test files, audited 2026-06-09 and wired.
  # Host-tier (run on every invocation):
  run_test "${SCRIPT_DIR}/test-bd-host-preflight.sh"    # _bd_host_preflight dolt-server preflight helper (host-only)
  run_test "${SCRIPT_DIR}/test-container-name.sh"       # rip-cage-a0h item (c): container_name() collision-hash disambiguation regression — docker PATH-shim + real cmd_up --dry-run, host-only
  run_test "${SCRIPT_DIR}/test-lfs-warning.sh"          # rc --dry-run up LFS pointer-stub scan + silent-exit-1 regression
  run_test "${SCRIPT_DIR}/test-denylist-matching.sh"    # _check_secret_path_denylist component-match (unsets RC_CONFIG_GLOBAL per driver-fixture trap)
  run_test "${SCRIPT_DIR}/test-pi-substrate-mounts.sh"  # rip-cage-kstk: pi substrate projection mount args + denylist + init symlinks + floor-protection
  run_test "${SCRIPT_DIR}/test-symlink-follow.sh"       # symlink-follow scanner + fingerprint + denylist gating (unsets RC_CONFIG_GLOBAL)
  run_test "${SCRIPT_DIR}/test-config-loader.sh"        # layered config additive/select merge + provenance matrix (unsets RC_CONFIG_GLOBAL)
  run_test "${SCRIPT_DIR}/test-config-ro-mount.sh"      # rip-cage-cw51: .rip-cage.yaml ro shadow-mount (ADR-021 D7) — schema + mount-arg + label-lock (unsets RC_CONFIG_GLOBAL)
  run_test "${SCRIPT_DIR}/test-dcg-demotion.sh"          # rip-cage-wlwc.10: dcg demoted from base image to composable recipe (DS1-DS4 host-only structural; DB1-DB2 RC_E2E-gated)
  run_test "${SCRIPT_DIR}/test-mount-seam-integration.sh" # rip-cage-wlwc.6: integration harness capstone (SI1-SI6 host-only Tier-1; SE1-SE5 self-skip via RC_E2E gate)
  run_test "${SCRIPT_DIR}/test-image-drift-resume.sh"    # rip-cage-jnvb: rc up image-ID drift guard on resume — full-rc-through-fake-docker-shim T1-T6, host-only, no live container needed
  run_test "${SCRIPT_DIR}/test-dry-run-resume-guards.sh" # rip-cage-3y9g: rc up --dry-run runs the same _up_resolve_resume_* guard set/order as a real resume (P1a/P1b parity + B1 behavioral), host-only
  # Container-tier (NEEDS_CONTAINER above; self-skip under --host-only, run on full invocation):
  run_test "${SCRIPT_DIR}/test-session-persistence.sh"  # dn2 projects/sessions persist-to-host (Phase 3 container)
  run_test "${SCRIPT_DIR}/test-pi-no-extensions.sh"     # rip-cage-sn1h: LOCKED-VARIANT-ONLY probe (evil.ts NOT loaded + DCG still denies); self-skips under the shipped OPEN default (rip-cage-p35a.1 / ADR-027 D1)
  run_test "${SCRIPT_DIR}/test-skills.sh"               # meta-skill MCP handshake + cage-path/settings inside cage
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

# ADR-023 secret-path denylist (rip-cage-3gu.2): rc up requires a global
# config file at $RC_CONFIG_GLOBAL or ~/.config/rip-cage/config.yaml.
# Provide a default empty-denylist fixture for the suite so tests don't all
# need to set RC_CONFIG_GLOBAL individually. Tests that verify the
# missing-config preflight (e.g. test-secret-path-denylist.sh case j) override
# this with their own local export.
#
# rip-cage-4c5.8: driver-level manifest fixture (analogous to the config fixture
# above). Seeds a benign empty tools.yaml so any rc invocation that derives its
# manifest path from XDG_CONFIG_HOME (the default path) reads a known-safe default
# (empty file = bundled-only default stack, D8 contract) rather than the developer's
# real ~/.config/rip-cage/tools.yaml. Both fixtures share a single driver temp dir
# and a unified EXIT trap.
#
# ISOLATION: RC_MANIFEST_GLOBAL is NOT exported at the driver level because it has
# higher priority than XDG_CONFIG_HOME in _manifest_global_path(), and exporting
# it would override the per-test sandbox HOME/XDG_CONFIG_HOME used by test-manifest-
# schema.sh, test-manifest-tool.sh, etc. Those tests correctly isolate their
# fixture loading via explicit HOME+XDG_CONFIG_HOME in subprocess calls. The
# driver fixture works through XDG_CONFIG_HOME (exported below) which those tests
# then override per-call. New tests that invoke rc without a sandboxed HOME/XDG
# inherit the driver XDG_CONFIG_HOME and thus the empty tools.yaml.
_RUN_HOST_CFG_DIR=$(mktemp -d)
mkdir -p "${_RUN_HOST_CFG_DIR}/rip-cage"
cat > "${_RUN_HOST_CFG_DIR}/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
# Empty tools.yaml: seeded once at driver level; zero-byte = default bundled stack.
touch "${_RUN_HOST_CFG_DIR}/rip-cage/tools.yaml"

# ---------------------------------------------------------------------------
# Self-healing sweep (rip-cage-aqww D2): reap leaked scratch-cage containers
# whose rc.source.path label is under the OS temp root.
#
# DISCRIMINATOR: every cage carries an rc.source.path label (rc:4196); the value
# is already realpath-resolved at creation (rc:504/3685).  On macOS $TMPDIR is
# /var/folders/... but the label is /private/var/folders/... — resolve the temp
# root before comparing, NOT the label (the cage workspace dir may already be
# deleted, and BSD realpath returns empty on missing paths, which would miss it).
#
# This mirrors the existing idiom in test-multiplexer-agent-e2e.sh:163-179.
# Uses `rc destroy --force` (rc:4882) to remove BOTH rc-state-<name> and
# rc-history-<name> volumes — no hand-rolled volume removal.
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

_sweep_scratch_cages() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  local _cname _raw_sp _root
  for _cname in $(docker ps -a --filter "label=rc.source.path" --format '{{.Names}}' 2>/dev/null || true); do
    _raw_sp=$(docker inspect --format '{{ index .Config.Labels "rc.source.path" }}' "$_cname" 2>/dev/null || true)
    [[ -z "$_raw_sp" ]] && continue
    for _root in "${_SWEEP_TEMP_ROOTS[@]+"${_SWEEP_TEMP_ROOTS[@]}"}"; do
      if [[ "$_raw_sp" == "${_root}"/* || "$_raw_sp" == "${_root}" ]]; then
        "${SCRIPT_DIR}/../rc" destroy --force "$_cname" >/dev/null 2>&1 || true
        break
      fi
    done
  done
}

# Run the sweep at START of run to reap any residue from a previous aborted run.
_sweep_scratch_cages

# Combined EXIT/INT/TERM handler: config-fixture cleanup + scratch-cage sweep.
_run_host_cleanup() {
  rm -rf "${_RUN_HOST_CFG_DIR}"
  _sweep_scratch_cages
}
trap '_run_host_cleanup' EXIT INT TERM

export RC_CONFIG_GLOBAL="${RC_CONFIG_GLOBAL:-${_RUN_HOST_CFG_DIR}/rip-cage/config.yaml}"
# XDG_CONFIG_HOME: default to driver temp dir so rc invocations without an explicit
# HOME/XDG sandbox read from the driver fixture. Tests that set HOME+XDG_CONFIG_HOME
# explicitly in their subprocess calls (all test-manifest-*.sh) override this.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${_RUN_HOST_CFG_DIR}}"

# Real pass: write the run header (if a ledger is configured), reset the
# call-ordinal counter so it starts fresh at 1 (matches --list/--ledger-
# summary's enumerate pass, which uses the identical call sequence), and
# actually execute the selected tests.
_rh_ledger_write_header
_RH_MODE="run"
_RH_CALL_INDEX=0
_run_all_tests

echo "=== run-host.sh complete ==="

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo ""
  echo "=== ${#FAILED_TESTS[@]} TEST FILE(S) FAILED ==="
  for _ft in "${FAILED_TESTS[@]}"; do
    echo "  FAILED: ${_ft}"
  done
  exit 1
fi
