#!/usr/bin/env bash
# tests/test-msb-flags-dind-volume.sh -- unit tests for the disk-kind
# docker-data volume manifest surface (rip-cage-75rq, S11 of the msb
# migration epic rip-cage-tsf2, cli/lib/msb_flags.sh).
#
# Pure-function tests: no live docker/msb daemon needed. Wires the
# proven-but-unwired capability from findings §10b: cages needing nested
# Docker/compose declare a `dind_volumes` array; the generator emits
# `--mount-named NAME:GUEST_PATH:kind=disk,size=SIZE` -- a virtio-blk
# disk-kind volume, NOT the virtiofs `--mount-dir`/`--mount-file` grammar
# S2's `_msb_flags_emit_mount` already covers. Kept as a DISTINCT function
# (`_msb_flags_emit_dind_volume`) and a DISTINCT top-level config key so
# S2's base mount logic (dir/file, virtiofs) stays untangled from this
# disk-kind concern.
#
# Live effect-based proof (real compose-service write+read round trip over
# TCP, the virtiofs-dir negative control, dockerd survives --init handoff)
# lives in tests/test-dind-compose-disk-kind-live.sh, which needs a live
# docker+msb daemon and self-skips otherwise.
#
# This file covers:
#   T1  a single dind_volumes entry -> one --mount-named NAME:GUEST_PATH:
#       kind=disk,size=SIZE flag pair
#   T2  absent dind_volumes -> no --mount-named kind=disk output at all
#       (backward-compat: existing S2 configs are unaffected)
#   T3  missing required field (name/guest_path/size) -> generation-time
#       validation failure, non-zero exit, no flags emitted (fail whole,
#       matches the module's existing credential-validation discipline)
#   T4  dind_volumes ordered AFTER the base `mounts` section (S11 stays a
#       distinct, later-appended surface -- doesn't reorder S2's output)
#   T5  determinism: same config run twice -> byte-identical output

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GEN="${REPO_ROOT}/cli/lib/msb_flags.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available -- skipping $(basename "$0")"
  exit 0
fi

# shellcheck disable=SC1090
source "$GEN"

# ---------------------------------------------------------------------------
# T1: a single dind_volumes entry -> --mount-named NAME:GUEST_PATH:kind=disk,size=SIZE
# ---------------------------------------------------------------------------
echo ""
echo "=== T1: dind_volumes entry -> --mount-named NAME:GUEST_PATH:kind=disk,size=SIZE ==="
T1_CFG='{"dind_volumes": [{"name": "docker-data", "guest_path": "/var/lib/docker", "size": "20G"}]}'
T1_OUT=$(_msb_flags_generate "$T1_CFG")
T1_RC=$?
T1_EXPECTED_TAIL=$'--mount-named\ndocker-data:/var/lib/docker:kind=disk,size=20G'
if [[ "$T1_RC" -eq 0 ]]; then
  pass "T1: exits 0"
else
  fail "T1: expected exit 0, got $T1_RC" "$T1_OUT"
fi
if [[ "$T1_OUT" == *"$T1_EXPECTED_TAIL"* ]]; then
  pass "T1b: emits --mount-named docker-data:/var/lib/docker:kind=disk,size=20G"
else
  fail "T1b: expected disk-kind mount-named line pair" "$T1_OUT"
fi

# ---------------------------------------------------------------------------
# T2: absent dind_volumes -> no --mount-named kind=disk output
# ---------------------------------------------------------------------------
echo ""
echo "=== T2: absent dind_volumes -> no disk-kind --mount-named output (backward-compat) ==="
T2_CFG='{"allowed_hosts": ["github.com"]}'
T2_OUT=$(_msb_flags_generate "$T2_CFG")
if [[ "$T2_OUT" != *"kind=disk"* ]]; then
  pass "T2: no disk-kind mount emitted when dind_volumes is absent"
else
  fail "T2: unexpected disk-kind mount in output" "$T2_OUT"
fi

# ---------------------------------------------------------------------------
# T3: missing required field -> validation failure, non-zero exit, no flags
# ---------------------------------------------------------------------------
echo ""
echo "=== T3: dind_volumes entry missing 'size' -> non-zero exit, no flags emitted ==="
T3_CFG='{"dind_volumes": [{"name": "docker-data", "guest_path": "/var/lib/docker"}]}'
T3_OUT=$(_msb_flags_generate "$T3_CFG" 2>/tmp/t3-dind-vol.err)
T3_RC=$?
if [[ "$T3_RC" -ne 0 ]]; then
  pass "T3: exits non-zero when a required dind_volumes field is missing"
else
  fail "T3: expected non-zero exit" "rc=$T3_RC"
fi
if [[ -z "$T3_OUT" ]]; then
  pass "T3b: NO flags emitted at all (fail whole, not a partial flag set)"
else
  fail "T3b: expected empty stdout" "$T3_OUT"
fi
T3_ERR=$(cat /tmp/t3-dind-vol.err)
if [[ "$T3_ERR" == *"size"* ]]; then
  pass "T3c: error names the actual missing field ('size')"
else
  fail "T3c: expected an actionable error mentioning the missing field" "$T3_ERR"
fi
rm -f /tmp/t3-dind-vol.err

# ---------------------------------------------------------------------------
# T4: dind_volumes ordered AFTER the base mounts section
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: dind_volumes emitted AFTER base 'mounts' -- distinct, later-appended surface ==="
T4_CFG='{"mounts": [{"host_path": "/h/workspace", "guest_path": "/workspace"}], "dind_volumes": [{"name": "docker-data", "guest_path": "/var/lib/docker", "size": "20G"}]}'
T4_OUT=$(_msb_flags_generate "$T4_CFG")
T4_MOUNT_DIR_LINE=$(grep -n -- '--mount-dir' <<<"$T4_OUT" | head -1 | cut -d: -f1)
T4_MOUNT_NAMED_LINE=$(grep -n -- '--mount-named' <<<"$T4_OUT" | head -1 | cut -d: -f1)
if [[ -n "$T4_MOUNT_DIR_LINE" && -n "$T4_MOUNT_NAMED_LINE" && "$T4_MOUNT_DIR_LINE" -lt "$T4_MOUNT_NAMED_LINE" ]]; then
  pass "T4: --mount-dir (base mounts) appears before --mount-named (dind_volumes) in emitted order"
else
  fail "T4: expected base mounts before dind_volumes in emission order" "$T4_OUT"
fi

# ---------------------------------------------------------------------------
# T5: determinism
# ---------------------------------------------------------------------------
echo ""
echo "=== T5: determinism -- identical dind_volumes config -> byte-identical output ==="
T5_CFG='{"dind_volumes": [{"name": "docker-data", "guest_path": "/var/lib/docker", "size": "20G"}, {"name": "second-vol", "guest_path": "/mnt/second", "size": "5G"}]}'
T5_RUN1=$(bash -c "source '${GEN}'; _msb_flags_generate '${T5_CFG}'")
T5_RUN2=$(bash -c "source '${GEN}'; _msb_flags_generate '${T5_CFG}'")
if [[ "$T5_RUN1" == "$T5_RUN2" ]]; then
  pass "T5: two independent process runs of the same dind_volumes config produce byte-identical argv"
else
  fail "T5: output differs across repeated runs" "run1:
$T5_RUN1
run2:
$T5_RUN2"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-flags-dind-volume.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-flags-dind-volume.sh: all ${TOTAL} tests passed ==="
