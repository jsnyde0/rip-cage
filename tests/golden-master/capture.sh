#!/usr/bin/env bash
# tests/golden-master/capture.sh — golden-master capture/check driver for
# `rc`'s container-free command surface (rip-cage-9oyh §1).
#
# Usage:
#   bash tests/golden-master/capture.sh --record   # write the baseline (at HEAD)
#   bash tests/golden-master/capture.sh [--check]  # default: byte-identity check
#
# Drives each verb in the §1(a) container-free net against the fixed sandbox
# (lib/sandbox.sh) + content-keyed fake docker/uname (lib/fake-bin), applies
# the §2 scrub (lib/scrub.sh), then either records the scrubbed
# {stdout,stderr,exit} triple under snapshots/ or diffs against it.
set -uo pipefail

GM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sandbox.sh
source "${GM_DIR}/lib/sandbox.sh"
# shellcheck source=lib/scrub.sh
source "${GM_DIR}/lib/scrub.sh"
# shellcheck source=cases.sh
source "${GM_DIR}/cases.sh"

MODE="check"
case "${1:-}" in
  --record) MODE="record" ;;
  --check|"") MODE="check" ;;
  *) echo "Usage: capture.sh [--record|--check]" >&2; exit 2 ;;
esac

SNAP_DIR="${GM_SNAPSHOT_DIR_OVERRIDE:-${GM_DIR}/snapshots}"
mkdir -p "$SNAP_DIR"

FAILURES=0
CHECKED=0

run_case() {
  local name="$1"
  gm_sandbox_reset
  "case_${name}"

  local scrubbed_out scrubbed_err
  scrubbed_out=$(printf '%s' "$GM_OUT" | gm_scrub)
  scrubbed_err=$(printf '%s' "$GM_ERR" | gm_scrub)

  local out_file="${SNAP_DIR}/${name}.stdout"
  local err_file="${SNAP_DIR}/${name}.stderr"
  local exit_file="${SNAP_DIR}/${name}.exit"

  if [[ "$MODE" == "record" ]]; then
    printf '%s' "$scrubbed_out" > "$out_file"
    printf '%s' "$scrubbed_err" > "$err_file"
    printf '%s\n' "$GM_EXIT" > "$exit_file"
    echo "RECORDED: $name"
    return
  fi

  CHECKED=$((CHECKED + 1))
  if [[ ! -f "$out_file" || ! -f "$err_file" || ! -f "$exit_file" ]]; then
    echo "FAIL $name: no recorded snapshot -- run --record first"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local exp_out exp_err exp_exit ok=1
  exp_out=$(cat "$out_file")
  exp_err=$(cat "$err_file")
  exp_exit=$(cat "$exit_file")

  if [[ "$scrubbed_out" != "$exp_out" ]]; then
    echo "FAIL $name: stdout mismatch"
    diff <(printf '%s\n' "$exp_out") <(printf '%s\n' "$scrubbed_out") || true
    ok=0
  fi
  if [[ "$scrubbed_err" != "$exp_err" ]]; then
    echo "FAIL $name: stderr mismatch"
    diff <(printf '%s\n' "$exp_err") <(printf '%s\n' "$scrubbed_err") || true
    ok=0
  fi
  if [[ "$GM_EXIT" != "$exp_exit" ]]; then
    echo "FAIL $name: exit mismatch (expected $exp_exit got $GM_EXIT)"
    ok=0
  fi

  if [[ "$ok" == "1" ]]; then
    echo "PASS $name"
  else
    FAILURES=$((FAILURES + 1))
  fi
}

for _gm_case in "${GM_CASES[@]}"; do
  run_case "$_gm_case"
done

echo ""
echo "=== capture.sh (${MODE}): ${CHECKED} checked, ${FAILURES} failure(s) ==="
exit "$FAILURES"
