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

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
# shellcheck source=tests/_cage-conf-lib.sh
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

# rip-cage-jgz2: resolve the sandbox root the same way cage_conf_for does.
# msb does not follow a host-side symlink in a bind source, and on macOS
# $TMPDIR lives under /var, itself a symlink to /private/var.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-lifecycle-doctor-XXXXXX")
TEST_HOME=$(cd "$TEST_HOME" && pwd -P)
WS="${TEST_HOME}/workspace"
mkdir -p "${TEST_HOME}/.config/rip-cage" "$WS"
CAGE_NAME=""
cleanup() {
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

git -C "$WS" init -q
touch "${WS}/README.md"
git -C "$WS" add README.md
git -C "$WS" -c user.name="scratch" -c user.email="scratch@example.invalid" commit -q -m "initial"

# THE FIXTURE CONFIG, AND WHY ITS HOST COUNT IS PINNED TWICE (rip-cage-jgz2).
#
# This suite used to seed the legacy per-project YAML inside the workspace —
# a schema-versioned file with its own allowed-hosts list — and drive rc with
# the allowed-roots env override. ADR-031 D2/D3 retired all three: rc reads
# ONE native msb config per project, and the allowed-roots guard is deleted
# (the retired token names are in that ADR, not duplicated here, so a suite
# auditing for their absence does not trip over this comment). That fixture
# therefore configured nothing,
# and the POSTURE case below was asserting about whatever default the runtime
# happened to produce — a vacuous pass.
#
# The config is now seeded through the shared helper every current suite uses.
# CONF_HOSTS is what the fixture declares; EXPECTED_ALLOW_RULES is an
# INDEPENDENT literal, deliberately not computed from CONF_HOSTS. That
# duplication is the point: changing the fixture's host count by one without
# touching the literal is the mutation this suite has to go red on, and a
# derived expectation would move with the fixture and stay green. Three hosts,
# not one, so the observed count cannot coincide with a single-host default.
CONF_HOSTS=(api.anthropic.com example.com github.com)
EXPECTED_ALLOW_RULES=3
CAGE_CONF=$(cage_conf_install "$WS" "${TEST_HOME}/.config" "$IMAGE" "${CONF_HOSTS[@]}")

run_rc() {
  XDG_CONFIG_HOME="${TEST_HOME}/.config" "$RC" --output json "$@"
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
scratch_cage_register "$CAGE_NAME"
pass "setup: rc up created ${CAGE_NAME} from ${CAGE_CONF}"

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
if echo "$POSTURE_TEXT" | grep -q "net-default=deny"; then
  pass "POSTURE: posture probe reports net-default=deny"
else
  fail "POSTURE: expected net-default=deny in the posture summary" "$POSTURE_TEXT"
fi
# The count is asserted EXACTLY, against the independent literal above -- a
# `[0-9]+ allow-rule` regex passes on any number, including the number a cage
# booted from a config rc never read would report (rip-cage-jgz2).
OBSERVED_ALLOW_RULES=$(echo "$POSTURE_TEXT" | sed -n 's/.*net-default=[^,]*, \([0-9][0-9]*\) allow-rule.*/\1/p')
if [[ "$OBSERVED_ALLOW_RULES" == "$EXPECTED_ALLOW_RULES" ]]; then
  pass "POSTURE: allow-rule count is the ${EXPECTED_ALLOW_RULES} the fixture config declares"
else
  fail "POSTURE: expected exactly ${EXPECTED_ALLOW_RULES} allow-rule(s) (the fixture declares ${#CONF_HOSTS[@]} hosts), observed '${OBSERVED_ALLOW_RULES}'" "$POSTURE_TEXT"
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
