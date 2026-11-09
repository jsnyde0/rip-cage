#!/usr/bin/env bash
set -uo pipefail

# tests/test-host-tool-generic.sh -- the D1/D4 guards for the host-tool line
# (rip-cage-jdl2.5; ADR-032 D1, D4). rc is a generic seam: it names no tool,
# and nothing in the line knows the words approval, hook, card or policy.
#
#   G1  rc, cli/, cage/ and share/ (whole trees) name none of the recipe's tools (or
#       telegram): the recipe lives under examples/, never in the seam.
#   G2  the three files the epic added contain none of the four words,
#       whole-word, any case.
#   G3  the matching-line count of those four words over rc and cli/ equals
#       the pre-epic baseline, so the epic added none. The words already live
#       in rc (network.policy and the like); only "nothing new" is checkable.
#       Raising the constant needs a commit message that says why: a count
#       that climbs is the seam drifting toward a bundler (ADR-032 D4).
#   G4  positive controls: each pattern fires on a planted file, so an empty
#       grep cannot mean a grep that broke.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# Measured on the tree at charting (rip-cage-jdl2.5): 55 matching lines.
BASELINE=55

NAMES_RE='host-tool-examples|echo-tool|env-tool|ask-then-run|telegram'
WORDS_RE='approval|hook|card|policy'
NEW_FILES=(cli/lib/host_tools.sh cli/lib/host-tool-gatekeeper.py cage/substrate/host-tool)

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- G4: positive controls ---------------------------------------------------
T=$(mktemp -d /tmp/rc-ht-generic-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
printf 'an Approval here\nthe hook\ncard\npolicy: none\n' > "$T/words"
printf 'hooks cards policies approvals\n' > "$T/nonwords"
for n in host-tool-examples echo-tool env-tool ask-then-run Telegram; do
  printf 'x %s y\n' "$n" > "$T/probe"
  if [[ "$(grep -ciE "${NAMES_RE}" "$T/probe")" -eq 1 ]]; then
    pass "G4 names pattern fires on $n alone"
  else
    fail "G4 names pattern misses $n"
  fi
done
if [[ "$(grep -ciwE "${WORDS_RE}" "$T/words")" -eq 4 ]]; then
  pass "G4 words pattern fires on every planted word, any case"
else
  fail "G4 words pattern misses a planted word"
fi
if [[ "$(grep -ciwE "${WORDS_RE}" "$T/nonwords")" -eq 0 ]]; then
  pass "G4 words pattern is whole-word (plurals do not match)"
else
  fail "G4 words pattern matched a plural"
fi

# --- G1 ---------------------------------------------------------------------
for f in "${NEW_FILES[@]}"; do
  [[ -f "$f" ]] || fail "G1 target present: $f"
done
hits="$(grep -rniE "${NAMES_RE}" rc cli/ cage/ share/ 2>&1)"
if [[ -z "$hits" ]]; then
  pass "G1 rc, cli/, cage/ and share/ (whole trees) name no recipe tool and no telegram"
else
  fail "G1 a seam file names a recipe tool: $(printf '%s' "$hits" | head -3)"
fi

# --- G2 ---------------------------------------------------------------------
hits="$(grep -niwE "${WORDS_RE}" "${NEW_FILES[@]}" 2>&1)"
if [[ -z "$hits" ]]; then
  pass "G2 the three new seam files contain none of approval, hook, card, policy"
else
  fail "G2 a new seam file carries a forbidden word: $(printf '%s' "$hits" | head -3)"
fi

# --- G3 ---------------------------------------------------------------------
count="$(grep -rniwE "${WORDS_RE}" rc cli/ | wc -l | tr -d ' ')"
if [[ "$count" -eq "$BASELINE" ]]; then
  pass "G3 matching lines over rc and cli/ equal the baseline (${BASELINE})"
else
  fail "G3 matching lines over rc and cli/ are ${count}, baseline ${BASELINE}"
fi

# --- G5: the skill sections --------------------------------------------------
# The bead's Signal cited tests/test-agent-readability.sh for these sections,
# but that test only classifies agent .md symlinks and never reads a skill; G5
# is the leg that replaces it.
CFG=.claude/skills/cage-config/SKILL.md
OPS=.claude/skills/cage-ops/SKILL.md
section() { # FILE HEADING -> the body up to the next "## " heading
  awk -v h="## $2" '$0 == h {on=1; next} /^## / {on=0} on' "$1"
}
CFG_SEC="$(section "$CFG" "Declaring host tools")"
if [[ -n "$CFG_SEC" ]]; then
  pass "G5 cage-config has a non-empty 'Declaring host tools' section"
else
  fail "G5 cage-config has no 'Declaring host tools' section"
fi
for term in 'tools:' 'argv' 'slots' 'string' 'int' 'enum' 'allow_dash' 'allow_slash' 'timeout' 'returns_secret' 'HOME' '--replace' '.tools.yaml' '--conf' 'outside every mount' '32 KiB' 'allowlist'; do
  if printf '%s\n' "$CFG_SEC" | grep -qF -- "$term"; then
    pass "G5 cage-config section mentions: $term"
  else
    fail "G5 cage-config section lacks: $term"
  fi
done
OPS_SEC="$(section "$OPS" "The host-tool line: repairs")"
for code in 2 3 4 5; do
  if printf '%s\n' "$OPS_SEC" | grep -qE "^\|[^|]*exit ${code}[^0-9]"; then
    pass "G5 cage-ops repair table has a row for exit ${code}"
  else
    fail "G5 cage-ops repair table has no row for exit ${code}"
  fi
done

echo
if [[ "$FAILURES" -eq 0 ]]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: ${FAILURES}"
exit 1
