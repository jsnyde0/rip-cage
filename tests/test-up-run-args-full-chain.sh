#!/usr/bin/env bash
# tests/test-up-run-args-full-chain.sh — rip-cage-9oyh §3(i) helper-level test
# (one of the TWO load-bearing tests for the CRITICAL _UP_RUN_ARGS gate).
#
# Extends the proven idiom from test-credential-mounts.sh:110-131 (source rc,
# reset _UP_RUN_ARGS=(), call the create-path helpers directly) into a
# FULL-CHAIN replica of cmd_up's real create-path helper call order
# (rc:5136 `_UP_RUN_ARGS=()` -> rc:5408 final image/cmd append ->
# `_up_start_container` rc:5410). All of these helpers are host-side/config-
# only — the harness spec's own review VERIFIED no docker call intervenes
# between 5136 and 5408 (§3(i)) — so the whole chain runs container-free.
#
# LIMITATION (accepted per harness spec §3(i)): this test hand-replicates
# cmd_up's helper call order rather than executing cmd_up itself, so it CAN
# drift from the real function if a future edit reorders/adds/removes a
# helper call in that block without a matching edit here. That is exactly
# why this is only ONE of the two load-bearing tests — the companion
# END-TO-END test (test-up-run-args-e2e.sh) drives the REAL `cmd_up` through
# a content-keyed docker shim and is the higher-fidelity gate.
#
# Wired into tests/run-host.sh (host-only tier).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
# shellcheck source=golden-master/lib/scrub.sh
source "${SCRIPT_DIR}/golden-master/lib/scrub.sh"
FAILURES=0
TEST_HOME=""
TEST_WS=""

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

unset RC_CONFIG_GLOBAL

cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  return 0
}
trap cleanup EXIT

setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-up-args-chain-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 1
mounts:
  denylist: []
  allow_risky: null
YAML
  touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
  TEST_WS="${TEST_HOME}/workspace"
  mkdir -p "$TEST_WS"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" TEST_WS=""
}

# run_full_chain — replicates cmd_up's create-path helper sequence
# (rc:5136-5408) verbatim in call order, using simple/deterministic flag
# values (egress=on, no mediator/dcg config) so no docker call and no
# host-git-identity leakage occurs. Prints the final _UP_RUN_ARGS array, one
# entry per line.
#
# ssh-cluster call sites (_resolve_github_identity, _resolve_github_identity_source,
# _up_resolve_ssh_allowlists, rc.ssh-config / rc.ssh-key-filter / rc.github-identity
# labels, rc_ssh_config / rc_forward_ssh flags) retired at the msb cutover
# (ADR-029 D3, rip-cage-f1qo S5) and removed from this replica to match.
run_full_chain() {
  RC_SKIP_KEYCHAIN_EXTRACTION=1 HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="$TEST_WS" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    bash -c "
    source '$RC' 2>/dev/null
    cd '$TEST_HOME'
    path='$TEST_WS'
    name='chain-test-cage'
    rc_egress='on'
    rc_allow_config_override=''
    rc_cpus='2'
    rc_memory='4g'
    rc_pids_limit='500'
    port=''
    env_file=''
    wt_detected=false wt_name= wt_main_git=

    _UP_RUN_ARGS=()
    _UP_RUN_ARGS+=(-d --name \"\$name\")
    _UP_RUN_ARGS+=(--label \"rc.source.path=\$path\")

    _rc_cache_dir=\"\${HOME}/.cache/rip-cage/\${name}\"
    mkdir -p \"\$_rc_cache_dir\"

    if [[ \"\$rc_egress\" != off ]]; then
      _up_resolve_egress_rules \"\$path\" \"\$_rc_cache_dir\"
    fi

    _UP_DCG_CONFIG_PATH=''
    _up_resolve_dcg_config \"\$path\" \"\$_rc_cache_dir\" || exit 1

    _UP_CREDENTIAL_MOUNTS='real'
    _UP_CRED_MOUNTS_CLAUDE='real'
    _UP_CRED_MOUNTS_PI='real'
    _UP_RUN_ARGS+=(--label \"rc.auth.credential-mounts=\${_UP_CREDENTIAL_MOUNTS}\")
    _UP_RUN_ARGS+=(--label \"rc.auth.credential-mounts.claude=\${_UP_CRED_MOUNTS_CLAUDE}\")
    _UP_RUN_ARGS+=(--label \"rc.auth.credential-mounts.pi=\${_UP_CRED_MOUNTS_PI}\")

    _UP_RUN_ARGS+=(--label 'rc.config-mode=ro')

    _sfl_fingerprint=\$(_symlink_follow_fingerprint \"\${HOME}/.pi/agent\" rw follow file \"\$path\" \"\$_UP_CRED_MOUNTS_PI\")
    _UP_RUN_ARGS+=(--label \"rc.symlink-follow-fingerprint=\${_sfl_fingerprint}\")

    _rc_multiplexer='none'
    _UP_RUN_ARGS+=(-e \"RC_MULTIPLEXER=\${_rc_multiplexer}\")
    _UP_RUN_ARGS+=(--label \"rc.session.multiplexer=\${_rc_multiplexer}\")

    _UP_MEDIATOR_CA_ENV=false
    _UP_RUN_ARGS+=(--label \"rc.mediator-ca-env=\${_UP_MEDIATOR_CA_ENV}\")

    _up_prepare_docker_mounts \"\$path\" \"\$name\"

    _up_resolve_placeholder_env_file \"\$path\" \"\$env_file\"
    if [[ -n \"\$_UP_PLACEHOLDER_ENV_FILE\" ]]; then
      env_file=\"\$_UP_PLACEHOLDER_ENV_FILE\"
    fi

    _up_prepare_environment \"\$path\" \"\$port\" \"\$env_file\" \"\$rc_cpus\" \"\$rc_memory\" \"\$rc_pids_limit\"

    if [[ \"\$rc_egress\" != off ]]; then
      _UP_RUN_ARGS+=(--label \"rc.egress.mode=\${_UP_EGRESS_MODE:-legacy}\")
    else
      _UP_RUN_ARGS+=(--label 'rc.egress.mode=legacy')
    fi
    _UP_RUN_ARGS+=(--label \"rc.egress.config-override=\${rc_allow_config_override:-false}\")

    if [[ \"\$rc_egress\" != off ]]; then
      _egress_rules_cache=\"\${_rc_cache_dir}/egress-rules.yaml\"
      _UP_RUN_ARGS+=(--mount \"type=bind,src=\${_egress_rules_cache},dst=/etc/rip-cage/egress-rules.yaml,ro\")
    fi

    if [[ -n \"\${_UP_DCG_CONFIG_PATH:-}\" ]]; then
      _UP_RUN_ARGS+=(--mount \"type=bind,src=\${_UP_DCG_CONFIG_PATH},dst=/usr/local/lib/rip-cage/dcg/config.toml,ro\")
    fi

    _UP_RUN_ARGS+=(\"\$IMAGE\" sleep infinity)

    printf '%s\n' \"\${_UP_RUN_ARGS[@]}\"
  " 2>/tmp/rc-up-args-chain-stderr.$$
}

# ---------------------------------------------------------------------------
# Test 1: the full-chain argv is byte-stable across repeated runs on an
# unmodified checkout (own-scrub self-check for the paths this test embeds).
#
# Scrub the per-invocation TEST_HOME path (mktemp-random) before comparing —
# both runs use a FRESH mktemp sandbox, so the raw argv differs only in that
# substring when the chain itself is deterministic. Reuses lib/scrub.sh's
# `gm_scrub_root_script` (realpath-before-nominal, raw AND
# `tr '/.' '-'`-slugified forms) rather than a bespoke regex — a private
# regex here previously only stripped the mktemp-random SUFFIX, leaving the
# ABSOLUTE TMPDIR PREFIX (machine/CI-specific) baked into the recorded
# snapshot -- false-RED on any host whose TMPDIR differs from the one that
# recorded it (2026-07-08 adversarial-review Finding 1). Must scrub EACH
# run's output while ITS OWN $TEST_HOME still exists (realpath resolution
# needs the dir), so scrubbing happens inline before that run's teardown —
# not after both runs, when only the second run's TEST_HOME would still be
# resolvable.
# ---------------------------------------------------------------------------
setup_sandbox
RUN1=$(run_full_chain)
RUN1_STDERR=$(cat "/tmp/rc-up-args-chain-stderr.$$" 2>/dev/null || true)
rm -f "/tmp/rc-up-args-chain-stderr.$$"
RUN1_SCRUBBED=$(printf '%s' "$RUN1" | sed -E -e "$(gm_scrub_root_script "$TEST_HOME" "TEST_HOME" true)")
teardown_sandbox

setup_sandbox
RUN2=$(run_full_chain)
rm -f "/tmp/rc-up-args-chain-stderr.$$"
RUN2_SCRUBBED=$(printf '%s' "$RUN2" | sed -E -e "$(gm_scrub_root_script "$TEST_HOME" "TEST_HOME" true)")
teardown_sandbox

if [[ "$RUN1_SCRUBBED" == "$RUN2_SCRUBBED" ]]; then
  pass "full-chain _UP_RUN_ARGS is deterministic across repeated runs"
else
  fail "full-chain determinism" "argv differs between two runs on an unmodified checkout:
$(diff <(printf '%s\n' "$RUN1_SCRUBBED") <(printf '%s\n' "$RUN2_SCRUBBED"))"
fi

# ---------------------------------------------------------------------------
# Test 2: the argv matches the recorded golden snapshot (byte-identity net
# for the refactor -- this is what the decomposition bead diffs against).
# ---------------------------------------------------------------------------
SNAPSHOT="${SCRIPT_DIR}/golden-master/snapshots/up-run-args-full-chain.argv"
if [[ "${1:-}" == "--record" ]]; then
  mkdir -p "$(dirname "$SNAPSHOT")"
  printf '%s' "$RUN1_SCRUBBED" > "$SNAPSHOT"
  echo "RECORDED: $SNAPSHOT"
else
  if [[ ! -f "$SNAPSHOT" ]]; then
    fail "golden snapshot" "no recorded snapshot at $SNAPSHOT -- run: bash $0 --record"
  else
    EXPECTED=$(cat "$SNAPSHOT")
    if [[ "$RUN1_SCRUBBED" == "$EXPECTED" ]]; then
      pass "full-chain _UP_RUN_ARGS matches the recorded golden snapshot"
    else
      fail "golden snapshot match" "argv differs from the recorded baseline:
$(diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$RUN1_SCRUBBED"))"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: sanity -- the argv reaches the final image+cmd append (proves the
# chain actually ran to completion, not an early `exit`/empty array).
# ---------------------------------------------------------------------------
if echo "$RUN1" | grep -qF "sleep" && echo "$RUN1" | grep -qF "infinity"; then
  pass "full-chain reaches the final '\$IMAGE sleep infinity' append"
else
  fail "full-chain completion" "argv does not end in the expected image+cmd append (chain aborted early?) -- stderr: $RUN1_STDERR
argv: $RUN1"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
