#!/usr/bin/env bash
# tests/test-dotpi-factory-recipe.sh -- host-only structure tests for the
# examples/dotpi-factory recipe (rip-cage-8jg5.2).
#
# Reads the recipe as it ships: Dockerfile.snippet, boot-fragment.json and
# README.md. Covers the five CLI symlinks into the ro-mounted checkout (no
# dotpi code copied in), the snippet ending on USER agent, the boot fragment
# merging cleanly and declaring no clock loop, the README's config lines
# agreeing with the snippet's state dirs and DOTPI_DIR, the reach-in facts, and
# the absence of the literal secret placeholder (rip-cage-ureo). No docker/msb
# needed. The live leg (herdr version, CLIs from host msb exec, a grant row
# surviving rc up --replace) is recorded on the bead's ship-record.
#
# Positive-sentinel discipline: every failure increments FAILURES; script
# exits non-zero if FAILURES > 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RECIPE="${REPO_ROOT}/examples/dotpi-factory"
SNIPPET="${RECIPE}/Dockerfile.snippet"
BOOT="${RECIPE}/boot-fragment.json"
README="${RECIPE}/README.md"
HERDR_BOOT="${REPO_ROOT}/examples/herdr/boot-fragment.json"
BASE_BOOT="${REPO_ROOT}/cage/boot/boot.json"
BOOT_MERGE="${REPO_ROOT}/cage/boot/rc-boot-merge"

FAILURES=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

TMPROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

echo "=== test-dotpi-factory-recipe.sh (rip-cage-8jg5.2) ==="

for f in "$SNIPPET" "$BOOT" "$README"; do
  if [[ -f "$f" ]]; then pass "recipe file present: ${f#"${REPO_ROOT}"/}"; else fail "recipe file present" "$f missing"; fi
done

# --- T1: the CLIs are symlinks into ${DOTPI_DIR}/scripts, all five -----------
dotpi_dir=$(sed -n 's/^ARG DOTPI_DIR=//p' "$SNIPPET")
if [[ "$dotpi_dir" == /home/agent/* ]]; then
  pass "T1 DOTPI_DIR defaults under the cage home ($dotpi_dir)"
else
  fail "T1 DOTPI_DIR defaults under the cage home" "got '${dotpi_dir}'"
fi
ln_line=$(grep -E '^RUN for t in .*; do ln -sf "\$\{DOTPI_DIR\}/scripts/\$\{t\}" "/usr/local/bin/\$\{t\}"' "$SNIPPET")
clis=$(printf '%s\n' "$ln_line" | sed -n 's/^RUN for t in \([^;]*\); do.*/\1/p')
if [[ "$clis" == "grants seat mail dispatch pacemaker" ]]; then
  pass "T1 symlinks exactly grants seat mail dispatch pacemaker into \${DOTPI_DIR}/scripts"
else
  fail "T1 CLI symlink line" "got '${clis}'"
fi

# --- T2: no dotpi code enters the image -------------------------------------
copies=$(grep -E '^(COPY|ADD) ' "$SNIPPET" | grep -vc '^COPY boot-fragment.json ')
if [[ "$copies" -eq 0 ]]; then
  pass "T2 the snippet copies nothing but its boot fragment"
else
  fail "T2 the snippet copies nothing but its boot fragment" "$copies extra COPY/ADD line(s)"
fi
if grep -qiE 'git clone|curl |wget |pip install|uv (tool |pip )?install|dotpi\.git' "$SNIPPET"; then
  fail "T2 no pre-baked dotpi checkout" "clone/fetch found in snippet"
else
  pass "T2 no pre-baked dotpi checkout"
fi

# --- T3: the snippet ends on USER agent --------------------------------------
last_user=$(grep -E '^USER ' "$SNIPPET" | tail -1)
if [[ "$last_user" == "USER agent" ]]; then pass "T3 snippet ends on USER agent"; else fail "T3 snippet ends on USER agent" "last is '${last_user}'"; fi

# --- T4: the boot fragment merges, declares daemons[], and carries no clock loop
if jq -e '.daemons | type == "array"' "$BOOT" >/dev/null 2>&1; then
  pass "T4 boot fragment is JSON with a daemons[] seam"
else
  fail "T4 boot fragment is JSON with a daemons[] seam" "jq check failed"
fi
if jq -r '[.daemons[]?, .multiplexers[]?, .tools[]?] | map(tostring) | join("\n")' "$BOOT" | grep -qE 'pacemaker +tick|while +sleep'; then
  fail "T4 no clock loop in the boot fragment" "a tick loop is declared (root D4 / ADR-027 D4)"
else
  pass "T4 no clock loop in the boot fragment"
fi
if grep -qiE 'pacemaker +tick|while +sleep|until .*sleep|cron|profile\.d' "$SNIPPET"; then
  fail "T4 no clock loop baked by the snippet" "a tick loop, cron or profile.d hook is in the snippet"
else
  pass "T4 no clock loop baked by the snippet"
fi
cp "$BASE_BOOT" "${TMPROOT}/boot.json"
if RC_BOOT_DESCRIPTOR="${TMPROOT}/boot.json" sh "$BOOT_MERGE" "$BOOT" >/dev/null 2>&1 \
   && jq -e --slurpfile b "$BASE_BOOT" '.tools == $b[0].tools and .multiplexers == $b[0].multiplexers' "${TMPROOT}/boot.json" >/dev/null 2>&1; then
  pass "T4 rc-boot-merge takes the fragment and leaves tools/multiplexers unchanged"
else
  fail "T4 rc-boot-merge takes the fragment" "merge failed or changed tools/multiplexers"
fi

# --- T5: README config lines agree with the snippet --------------------------
state_dirs=$(sed -n 's/^RUN for d in \(.*\); do install -d -o agent -g agent.*/\1/p' "$SNIPPET")
if [[ -z "$state_dirs" ]]; then
  fail "T5 snippet creates agent-owned state dirs" "no install -d line"
else
  pass "T5 snippet creates agent-owned state dirs ($state_dirs)"
  for d in $state_dirs; do
    if grep -B1 -E "^ +target: /home/agent/${d//./\\.}\$" "$README" | grep -qE '^ +- named: "'; then
      pass "T5 README mounts a named volume at ~/${d}"
    else
      fail "T5 README mounts a named volume at ~/${d}" "no 'target: /home/agent/${d}' line"
    fi
  done
fi
for sub in scripts agent; do
  if grep -qF "\"<DOTPI>/${sub}:<DOTPI_DIR>/${sub}:ro\"" "$README"; then
    pass "T5 README mounts dotpi/${sub} read-only at <DOTPI_DIR>/${sub}"
  else
    fail "T5 README mounts dotpi/${sub} read-only" "line missing"
  fi
done
# shellcheck disable=SC2016 # the backticks are literal markdown, not command substitution
readme_default=$(grep -oE '`/home/agent/[^`]+`, the default' "$README" | sed -E 's/^`([^`]+)`.*/\1/')
if [[ -n "$dotpi_dir" && "$readme_default" == "$dotpi_dir" ]]; then
  pass "T5 README's stated DOTPI_DIR default matches the snippet's ARG"
else
  fail "T5 README's stated DOTPI_DIR default matches the snippet's ARG" "README '${readme_default}' vs snippet '${dotpi_dir}'"
fi
if grep -qE '^ +- "<DOTPI>:' "$README"; then
  fail "T5 README never mounts the whole checkout" "a whole-checkout line is present (rip-cage-dnwv)"
else
  pass "T5 README never mounts the whole checkout"
fi

# --- T6: reach-in facts, socket path derived from the herdr recipe ------------
herdr_sock=$(jq -r '.multiplexers[0].start' "$HERDR_BOOT" | sed -n 's/^export HERDR_SOCKET_PATH=\([^;]*\);.*/\1/p')
if [[ -n "$herdr_sock" ]] && grep -qF "export HERDR_SOCKET_PATH=${herdr_sock};" "$README"; then
  pass "T6 README exports the herdr recipe's socket path ($herdr_sock)"
else
  fail "T6 README exports the herdr recipe's socket path" "herdr='${herdr_sock}'"
fi
if grep -qE "msb exec <cage> -- bash -lc '.*' < /dev/null" "$README"; then
  pass "T6 README closes stdin on host-side msb exec"
else
  fail "T6 README closes stdin on host-side msb exec" "no '< /dev/null' reach-in example"
fi

# --- T7: no literal secret placeholder (rip-cage-ureo) -----------------------
# shellcheck disable=SC2016 # the literal placeholder text is the target, not an expansion
if grep -qE '\$MSB_|\$\{MSB_' "$RECIPE"/*; then
  fail "T7 no literal secret placeholder in the recipe" "found a \$MSB_ token"
else
  pass "T7 no literal secret placeholder in the recipe"
fi

echo ""
echo "=== ${TOTAL} checks, ${FAILURES} failed ==="
[[ "$FAILURES" -eq 0 ]]
