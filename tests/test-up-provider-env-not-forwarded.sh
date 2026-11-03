#!/usr/bin/env bash
set -uo pipefail

# tests/test-up-provider-env-not-forwarded.sh -- host-tier proof for
# rip-cage-rsh9.4: a provider API key exported in the host shell never reaches
# the guest as a real value (ADR-031 D1 non-possession, ADR-019 D5). Provider
# keys ride a secrets: binding in the cage config instead.
#
#   P1  every name in the retired pre-fdbfe66 passthrough list (all 13 provider
#       keys) exported: the dry-run's msb create argv carries no value, and no
#       output line does.
#   P2  no auth.json -v mount on the argv by default.
#   P3  the non-secret pi knob PI_SKIP_VERSION_CHECK is still forwarded, so
#       the argv P1 inspects is the real one (not vacuously empty of -e).
#   P4  an empty-string knob (PI_CACHE_RETENTION="") is not forwarded
#       (ADR-019 D5: forwarded only when non-empty).
#
# Every rc call runs behind fake docker + msb (tests/_fake-runtime-lib.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"
# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
T=$(_host_scratch_mktemp_d rc-provider-env) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
_FAKE_RT=$(fake_runtime_bin)
trap 'rm -rf "$T" "$_FAKE_RT"' EXIT
export PATH="${_FAKE_RT}:${PATH}"

WS="${T}/proj/ws"
mkdir -p "$WS"
CONF=$(cage_conf_for "$WS")

# The full retired passthrough list (git show 404a866:cli/up.sh), so a
# reintroduced passthrough of any one name turns P1 red.
PROVIDER_KEYS=(
  ANTHROPIC_API_KEY AZURE_OPENAI_API_KEY OPENAI_API_KEY GEMINI_API_KEY
  MISTRAL_API_KEY GROQ_API_KEY CEREBRAS_API_KEY XAI_API_KEY
  OPENROUTER_API_KEY AI_GATEWAY_API_KEY ZAI_API_KEY OPENCODE_API_KEY
  KIMI_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY
)
PROVIDER_ENV=()
for _k in "${PROVIDER_KEYS[@]}"; do PROVIDER_ENV+=("${_k}=fake-x-${_k}"); done

OUT=$(env "${PROVIDER_ENV[@]}" \
  PI_SKIP_VERSION_CHECK=1 PI_CACHE_RETENTION= RC_CAGE_CONF="$CONF" "$RC" up --dry-run "$WS" 2>&1)
ARGV=$(grep '^Would run: msb create' <<<"$OUT" | head -1 | tr ' ' '\n')

echo "=== P1: exported provider keys absent from argv and output ==="
if [[ -z "$ARGV" ]]; then
  fail "P1 no 'Would run: msb create' line: $(tail -5 <<<"$OUT")"
elif grep -q 'fake-x' <<<"$OUT"; then
  fail "P1 a real provider key value reached rc's output: $(grep 'fake-x' <<<"$OUT" | head -3)"
else
  pass "P1 none of the exported key values appears in the argv or any output line"
fi

echo "=== P2: no auth.json mount by default ==="
if grep -q 'auth\.json' <<<"$ARGV"; then
  fail "P2 argv mounts an auth.json: $(grep 'auth\.json' <<<"$ARGV")"
else
  pass "P2 argv carries no auth.json mount"
fi

echo "=== P3: non-secret pi knob still forwarded ==="
if grep -qx 'PI_SKIP_VERSION_CHECK=1' <<<"$ARGV"; then
  pass "P3 PI_SKIP_VERSION_CHECK=1 forwarded"
else
  fail "P3 PI_SKIP_VERSION_CHECK=1 missing from argv: $(tr '\n' ' ' <<<"$ARGV" | cut -c1-300)"
fi

echo "=== P4: empty-string knob not forwarded ==="
if grep -q '^PI_CACHE_RETENTION=' <<<"$ARGV"; then
  fail "P4 empty PI_CACHE_RETENTION forwarded: $(grep '^PI_CACHE_RETENTION=' <<<"$ARGV")"
else
  pass "P4 empty PI_CACHE_RETENTION absent from argv"
fi

echo ""
[[ "$FAILURES" -eq 0 ]] && { echo "All tests passed"; exit 0; }
echo "${FAILURES} test(s) failed"; exit 1
