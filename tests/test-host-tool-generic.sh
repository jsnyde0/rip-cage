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

# --- G6: the skill's own example loads through the real loader ---------------
# The acceptance clause "an agent holding only the cage-config skill can write a
# valid declaration without reading rc source" needs traversing evidence, not a
# vocabulary match: take the yaml block the section shows, fill its placeholders
# the way a reader would (a tool name, a verb name, an absolute command), and
# load it through _host_tools_load against a plain mount list. G5 stays as the
# vocabulary floor (adjudication 2026-11-09, rip-cage-jdl2.5).
if command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  G6_YAML="$(printf '%s\n' "$CFG_SEC" | awk '/^```yaml/{p=1;next} p&&/^```/{exit} p')"
  if [[ -n "$G6_YAML" ]]; then
    pass "G6 the cage-config section carries a yaml example"
  else
    fail "G6 the cage-config section has no yaml example block"
  fi
  mkdir -p "$T/g6/bin" "$T/g6/ws"
  printf '#!/bin/sh\nexit 0\n' > "$T/g6/bin/cmd"; chmod 0755 "$T/g6/bin/cmd"
  printf '%s\n' "$T/g6/ws" > "$T/g6/mounts"
  printf '%s\n' "$G6_YAML" | sed -e "s|<tool>|demo|" -e "s|<verb>|send|" -e "s|/abs/path/to/command|$T/g6/bin/cmd|" > "$T/g6/demo.tools.yaml"
  G6_OUT="$(bash -c 'source cli/lib/protected_paths.sh; source cli/lib/msb_runtime.sh; source cli/lib/host_tools.sh; _host_tools_load "$1" "$2"' _ "$T/g6/demo.tools.yaml" "$T/g6/mounts" 2>"$T/g6/err")"; G6_RC=$?
  if [[ "$G6_RC" -eq 0 && -n "$G6_OUT" ]]; then
    pass "G6 the filled-in skill example loads clean through _host_tools_load (exit 0)"
  else
    fail "G6 the filled-in skill example did not load (exit $G6_RC): $(cat "$T/g6/err")"
  fi
  g6() { # DESC JQ-BOOL
    if [[ -n "$G6_OUT" ]] && printf '%s' "$G6_OUT" | jq -e "$2" >/dev/null 2>&1; then pass "G6 $1"; else fail "G6 $1"; fi
  }
  g6 "tool and verb are as declared" '.tools.demo.verbs.send | type == "object"'
  g6 "argv[0] is the filled-in absolute command" ".tools.demo.verbs.send.argv[0] == \"$T/g6/bin/cmd\""
  g6 "argv carries the two placeholders as whole elements" '.tools.demo.verbs.send.argv | index("{chat}") != null and index("{limit}") != null'
  g6 "slot chat: string, regex kept, allow_dash true, max defaulted to 4096" '.tools.demo.verbs.send.slots.chat | .type == "string" and .regex == "^-?[1-9][0-9]*$" and .allow_dash == true and .max == 4096'
  g6 "slot limit: int 1..100 default 20 (integer)" '.tools.demo.verbs.send.slots.limit | .type == "int" and .min == 1 and .max == 100 and .default == 20'
  g6 "timeout 30s normalised to 30, returns_secret false" '.tools.demo.verbs.send | .timeout == 30 and .returns_secret == false'
else
  echo "SKIP: G6 needs yq and jq on PATH"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: ${FAILURES}"
exit 1
