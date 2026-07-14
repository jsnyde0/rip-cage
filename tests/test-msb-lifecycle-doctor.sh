#!/usr/bin/env bash
# tests/test-msb-lifecycle-doctor.sh -- LIVE effect-based proof for bead
# rip-cage-rj68 (S6) criterion 4: "`doctor` reports cage posture WITHOUT
# referencing deleted engine processes (and without the retired ssh
# probe)." Drives the REAL `rc doctor` verb against a REAL `rc up`-created
# msb cage, not a hand-rolled msb inspection.
#
# Coverage:
#   NOENGINE  `rc doctor <name> --output json` output contains no
#             engine-process/ssh-cluster reference (rc.forward-ssh,
#             ssh_forwarding probe key, ssh-add, rip_cage_router, iptables)
#   POSTURE   the new posture probe is present and reports a real,
#             non-empty net-default + rule-count summary read from the
#             actual booted cage (not a placeholder string)
#   HOST      `rc doctor --host` reports BOTH docker and msb liveness
#
# NEEDS_CONTAINER (docker, rc up's image-provisioning preflight) + NEEDS_MSB
# + a pre-built rip-cage:latest image already `msb load`-ed. Self-skips
# otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker not available/responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-lifecycle-doctor-XXXXXX")
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_NAME=""
cleanup() {
  [[ -n "$CAGE_NAME" ]] && msb remove --force "$CAGE_NAME" >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

cat > "${WS}/.rip-cage.yaml" <<'EOF'
version: 2
network:
  allowed_hosts: [example.com, api.anthropic.com]
EOF

run_rc() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_ALLOWED_ROOTS="$WS" "$RC" --output json "$@"
}

CR_OUT=$(run_rc up "$WS" 2>&1)
CR_RC=$?
if [[ "$CR_RC" -ne 0 ]]; then
  fail "setup: rc up failed" "$CR_OUT"
  echo ""
  echo "=== test-msb-lifecycle-doctor.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi
CAGE_NAME=$(echo "$CR_OUT" | tail -1 | jq -r '.name' 2>/dev/null)
pass "setup: rc up created ${CAGE_NAME}"

# Trigger a real denial so the posture probe's fix-hint has real content.
msb exec "$CAGE_NAME" -- curl -sS --max-time 8 https://denied-doctor-probe.example.invalid >/dev/null 2>&1 || true

DOCTOR_OUT=$(run_rc doctor "$CAGE_NAME" 2>&1)
DOCTOR_RC=$?

echo ""
echo "=== NOENGINE: rc doctor output has no engine/ssh-cluster references ==="
if [[ "$DOCTOR_RC" -eq 0 ]]; then
  pass "rc doctor exits 0 against a real running cage"
else
  fail "rc doctor failed" "$DOCTOR_OUT"
fi
NOENGINE_PATTERNS=(
  "rc.forward-ssh" "ssh_forwarding" "ssh-add" "rip_cage_router"
  "rip_cage_egress" "rip_cage_dns" "iptables" "init-firewall" "init-mediator"
)
NOENGINE_CLEAN=1
for pat in "${NOENGINE_PATTERNS[@]}"; do
  if echo "$DOCTOR_OUT" | grep -qiF "$pat"; then
    NOENGINE_CLEAN=0
    fail "NOENGINE: doctor output references retired surface '${pat}'" "$DOCTOR_OUT"
  fi
done
if [[ "$NOENGINE_CLEAN" -eq 1 ]]; then
  pass "NOENGINE: doctor output contains none of ${#NOENGINE_PATTERNS[@]} retired engine/ssh-cluster references"
fi

echo ""
echo "=== POSTURE: the new posture probe reports real, non-placeholder content ==="
POSTURE_TEXT=$(echo "$DOCTOR_OUT" | jq -r '.probes.posture' 2>/dev/null)
if echo "$POSTURE_TEXT" | grep -q "net-default=deny" && echo "$POSTURE_TEXT" | grep -qE "[0-9]+ allow-rule"; then
  pass "POSTURE: posture probe reports real net-default + rule-count: '${POSTURE_TEXT}'"
else
  fail "POSTURE: expected a real net-default/rule-count summary" "$POSTURE_TEXT"
fi
if echo "$POSTURE_TEXT" | grep -q "denied-doctor-probe.example.invalid"; then
  pass "POSTURE: the real triggered denial's domain appears in the doctor posture probe"
else
  fail "POSTURE: expected the triggered denial's domain in the posture probe" "$POSTURE_TEXT"
fi

echo ""
echo "=== HOST: rc doctor --host reports both docker and msb liveness ==="
HOST_OUT=$(run_rc doctor --host 2>&1)
HOST_DAEMON=$(echo "$HOST_OUT" | jq -r '.daemon' 2>/dev/null)
HOST_MSB=$(echo "$HOST_OUT" | jq -r '.msb' 2>/dev/null)
if [[ "$HOST_DAEMON" == OK* && "$HOST_MSB" == OK* ]]; then
  pass "HOST: rc doctor --host reports docker OK and msb OK: daemon='${HOST_DAEMON}' msb='${HOST_MSB}'"
else
  fail "HOST: expected both docker and msb OK" "$HOST_OUT"
fi

echo ""
echo "=== test-msb-lifecycle-doctor.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
