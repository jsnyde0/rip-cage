#!/usr/bin/env bash
# tests/test-adr-evolution-notes.sh -- proves the in-place ADR evolution the
# distribution repositioning (rip-cage-ely4.7 / rip-cage-ely4.8) requires
# actually landed on EVERY named decision, not once per file.
#
# The repositioning ratified by the human over rip-cage-ely4's two sittings
# (2026-09-14/15) is recorded in a new ADR; twelve sibling rip-cage ADRs carry
# decisions that the new ADR evolves, honors or retires. Per the global
# in-place-evolution rule (dotclaude ADR-011 D1) those siblings are edited in
# place rather than superseded, so the only durable signal that the bookkeeping
# is complete is a per-target assertion: each named target must cite the new
# ADR by number.
#
# The pair table below IS rip-cage-ely4.8's acceptance contract, executable.
# Three target shapes, matching the bead's verification target:
#   STATUS  -- whole-file retirement (ADR-021, rip-cage ADR-011): the file's
#              Status: line is what a reader hits first, so that is the target.
#   D<k>    -- a single decision section (### D<k> ... up to the next ### ).
#   INDEX   -- docs/decisions/INDEX.md lists the new ADR file.
#
# Host-only, no cage/docker/network required -- a pure text check over
# docs/decisions/. Runs in well under a second.
#
# Bash 3.2 compatible (rip-cage ADR-008 D5): no associative arrays, no mapfile.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
ADR_DIR="${REPO_ROOT}/docs/decisions"
INDEX_FILE="${ADR_DIR}/INDEX.md"

# The new ADR authored by rip-cage-ely4.8. Every target below must cite it.
NEW_ADR_NUM="ADR-031"
NEW_ADR_FILE="ADR-031-opinionated-distribution-of-microsandbox.md"

FAILURES=0
PASSES=0

pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Pair table: <adr-file>|<target>|<what the new ADR does to it>
# Sourced verbatim from rip-cage-ely4.8's "## Decisions" list.
PAIRS="
ADR-021-layered-rip-cage-config.md|STATUS|retires whole (layered config substrate)
ADR-011-shell-completions.md|STATUS|retires whole (rip-cage corpus ADR-011, not dotclaude ADR-011)
ADR-005-ecosystem-tools.md|D1|build-time tool integration evolves to FROM-extension
ADR-005-ecosystem-tools.md|D3|version pinning re-homes to the user Dockerfile
ADR-005-ecosystem-tools.md|D4|rc is no longer the tool-selection interface
ADR-005-ecosystem-tools.md|D7|manifest archetypes retire; boot descriptor survives
ADR-005-ecosystem-tools.md|D8|one-cage scope re-homes to the Dockerfile + descriptor
ADR-005-ecosystem-tools.md|D9|forbidden-touch floor re-homes to the built-image floor probe
ADR-005-ecosystem-tools.md|D11|validator retires for the fail-closed floor probe
ADR-005-ecosystem-tools.md|D12|HONORED -- FROM-extension IS composition by agents
ADR-005-ecosystem-tools.md|D13|HONORED -- the floor probe is D13's presence assertion
ADR-005-ecosystem-tools.md|D14|admission test revised: the Dockerfile path is the one input
ADR-002-rip-cage-containers.md|D3|lifecycle verbs: down deleted, destroy kept
ADR-003-agent-friendly-cli.md|D3|allowed-roots guard deleted (mounts are explicit lines)
ADR-003-agent-friendly-cli.md|D5|rc schema retires with the rip-cage config schema
ADR-009-ux-overhaul.md|D7|first-run interactive prompt deleted (agent-first)
ADR-010-auth-refresh.md|D1|HONORED -- rc auth survives on live secret refresh
ADR-023-secret-path-mount-denylist.md|D2|patterns move to the shipped protected-paths list
ADR-025-host-adoptable-dcg-policy.md|D1|transport note only: DCG policy rides the recipe's own mount
ADR-027-agent-substrate-projection.md|D4|launch-wrapper mechanism moves to base image + descriptor
ADR-029-msb-migration.md|D4|rc reload folds into rc up --replace
ADR-030-classify-by-use-secret-posture.md|D8|masking becomes template mount lines + auto-cover
"

# Print the Status: block of an ADR (the line and any continuation up to the
# first blank line). Both '**Status:**' and bare 'Status:' forms occur.
extract_status() {
  awk '
    /^\*\*Status:\*\*|^Status:/ { inblock = 1 }
    inblock && /^[[:space:]]*$/ { exit }
    inblock { print }
  ' "$1"
}

# Print one decision section: the '### D<k>' heading through the line before
# the next '### ' heading (or EOF). The boundary char class keeps D1 from
# matching D11/D12/D14 and keeps D4 from matching ADR-021's D4a.
extract_decision() {
  awk -v want="$2" '
    $0 ~ ("^### " want "([:.,)( ]|$)") { inblock = 1; print; next }
    inblock && /^### / { exit }
    inblock { print }
  ' "$1"
}

echo "=== ADR in-place evolution notes (rip-cage-ely4.8) ==="
echo "new ADR: ${NEW_ADR_NUM} (${NEW_ADR_FILE})"
echo

# --- The new ADR itself exists -------------------------------------------
if [ -f "${ADR_DIR}/${NEW_ADR_FILE}" ]; then
  pass "new ADR file exists: docs/decisions/${NEW_ADR_FILE}"
else
  fail "new ADR file missing: docs/decisions/${NEW_ADR_FILE}"
fi

# --- INDEX.md lists it ----------------------------------------------------
if grep -q "${NEW_ADR_FILE}" "${INDEX_FILE}" 2>/dev/null; then
  pass "INDEX.md lists ${NEW_ADR_FILE}"
else
  fail "INDEX.md does not list ${NEW_ADR_FILE}"
fi

# --- Every pair cites the new ADR ----------------------------------------
while IFS='|' read -r adr target why; do
  [ -z "${adr}" ] && continue
  label="${adr} ${target} -- ${why}"
  file="${ADR_DIR}/${adr}"

  if [ ! -f "${file}" ]; then
    fail "${label} [ADR file not found]"
    continue
  fi

  case "${target}" in
    STATUS) region="$(extract_status "${file}")" ;;
    D*)     region="$(extract_decision "${file}" "${target}")" ;;
    *)      fail "${label} [unknown target kind]"; continue ;;
  esac

  if [ -z "${region}" ]; then
    fail "${label} [target section not found in file]"
    continue
  fi

  if printf '%s\n' "${region}" | grep -q "${NEW_ADR_NUM}"; then
    pass "${label}"
  else
    fail "${label} [no ${NEW_ADR_NUM} citation in the target]"
  fi
done <<EOF
${PAIRS}
EOF

echo
echo "=== ${PASSES} passed, ${FAILURES} failed ==="
[ "${FAILURES}" -eq 0 ] || exit 1
exit 0
