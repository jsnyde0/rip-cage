#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088,SC2015  # literal $MSB_* placeholders and guest-side ~ paths are intended; pass || fail is the suite idiom
# test-pi-e2e.sh - end-to-end in-cage pi smoke, one real `rc up` cage, two
# providers, each credential an msb secret the guest never holds
# (rip-cage-3w82).
#
#   openrouter    API key. Delta: secrets.OPENROUTER bound to openrouter.ai,
#                 env OPENROUTER_API_KEY = its placeholder, egress line.
#   openai-codex  OpenAI (ChatGPT) subscription. Delta: secrets.CODEX bound
#                 to chatgpt.com with a fake-JWT placeholder, a placeholder
#                 auth.json mounted :ro, egress line. Both host files come
#                 from examples/pi-providers/codex-secret.sh, run here.
#
# The config is the SHIPPED TEMPLATE plus exactly those deltas — the same ones
# .claude/skills/cage-config/recipes/pi-providers.md documents. The Anthropic
# subscription is never used for pi (human ruling, rip-cage-3w82); this test
# has no anthropic provider path.
#
# Runs under a scratch HOME and XDG_CONFIG_HOME, so the real ~/.pi is never
# mounted or written. Real credentials are COPIED from the operator's host
# files, never echoed:
#   openrouter    ${XDG_CONFIG_HOME:-~/.config}/rip-cage/secrets/OPENROUTER
#   openai-codex  the openai-codex login in the host pi's auth.json
# A provider with no host credential SKIPs; both absent skips the test.
#
# Env: RC_IMAGE (default rip-cage:latest), RC_PI_OPENROUTER_MODEL
# (default openai/gpt-4o-mini), RC_PI_CODEX_MODEL (default gpt-6.1-sol: the
# image's pi carries a stale codex catalog, so the id is passed explicitly).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"
CODEX_HELPER="${REPO_ROOT}/examples/pi-providers/codex-secret.sh"
REAL_HOME="$HOME"
REAL_XDG="${XDG_CONFIG_HOME:-${HOME}/.config}"
REAL_PI_AUTH="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}/auth.json"
IMAGE="${RC_IMAGE:-rip-cage:latest}"
OR_MODEL="${RC_PI_OPENROUTER_MODEL:-openai/gpt-4o-mini}"
CODEX_MODEL="${RC_PI_CODEX_MODEL:-gpt-6.1-sol}"
# Planted in the scratch host's ~/.pi/agent/auth.json. rc must never carry
# that file into the cage, so the guest must never see this string.
ANTHROPIC_SENTINEL="rc-e2e-sentinel-anthropic-must-not-reach-guest"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1${2:+ -- $2}"; FAILURES=$((FAILURES + 1)); }

command -v msb >/dev/null 2>&1 || { echo "SKIP: msb not on PATH"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "SKIP: ${IMAGE} not built — run ./rc build first"
  exit 0
fi

HAVE_OR=0; HAVE_CODEX=0
[[ -s "${REAL_XDG}/rip-cage/secrets/OPENROUTER" ]] && HAVE_OR=1
[[ -r "$REAL_PI_AUTH" ]] && [[ -n "$(jq -r '."openai-codex".access // empty' "$REAL_PI_AUTH" 2>/dev/null)" ]] && HAVE_CODEX=1
if [[ $HAVE_OR -eq 0 && $HAVE_CODEX -eq 0 ]]; then
  echo "SKIP: no pi provider credential on host — save an OpenRouter key at ${REAL_XDG}/rip-cage/secrets/OPENROUTER and/or /login to openai-codex in host pi"
  exit 0
fi

# shellcheck source=tests/_host-sandbox-lib.sh
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
T=$(_host_scratch_mktemp_d rc-pi-e2e)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/xdg"
export MSB_HOME="${REAL_HOME}/.microsandbox"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/skills" "$HOME/.pi/agent"
echo '{"hasCompletedOnboarding": true}' > "$HOME/.claude.json"
printf '{"anthropic":{"type":"oauth","access":"%s","refresh":"%s","expires":0}}' \
  "$ANTHROPIC_SENTINEL" "$ANTHROPIC_SENTINEL" > "$HOME/.pi/agent/auth.json"
[[ -e "${REAL_HOME}/.docker" ]] && ln -sfn "${REAL_HOME}/.docker" "${HOME}/.docker"
# rc forwards a fixed list of provider env vars by real value; none may be set
# here, or the guest would hold a real key and the non-possession probe lies.
unset CCTOK OPENROUTER CODEX OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY

SECRETS="${XDG_CONFIG_HOME}/rip-cage/secrets"
mkdir -p "${XDG_CONFIG_HOME}/rip-cage/projects" "$SECRETS"
# The template binds CCTOK; claude is not exercised, so a well-shaped fake does.
( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${SECRETS}/CCTOK" )

WS="${T}/ws"
mkdir -p "$WS"
echo "# pi e2e test" > "$WS/README"
NAME=$(bash -c "source '${RC}' 2>/dev/null; container_name '$WS'")
[[ -n "$NAME" ]] || { echo "FATAL: could not derive cage name"; exit 1; }
CONF="${XDG_CONFIG_HOME}/rip-cage/projects/${NAME}.yaml"
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${HOME}#g" \
    -e "s#<CAGE-NAME>#${NAME}#g" \
    -e "s#^image: rip-cage:latest#image: ${IMAGE}#" \
    "${REPO_ROOT}/share/rip-cage/cage.yaml.template" > "$CONF"

# --- the documented config deltas --------------------------------------------
OR_NEEDLE=""; CODEX_NEEDLE=""
if [[ $HAVE_OR -eq 1 ]]; then
  ( umask 077; cp "${REAL_XDG}/rip-cage/secrets/OPENROUTER" "${SECRETS}/OPENROUTER" )
  OR_NEEDLE=$(cat "${SECRETS}/OPENROUTER")
  yq -i '.secrets.OPENROUTER.allow = ["openrouter.ai"]
         | .env.OPENROUTER_API_KEY = "$MSB_OPENROUTER"
         | .network.allow += ["openrouter.ai:tcp:443"]' "$CONF"
fi
if [[ $HAVE_CODEX -eq 1 ]]; then
  if ! PI_AUTH="$REAL_PI_AUTH" "$CODEX_HELPER" >/dev/null; then
    fail "codex-secret.sh wrote the codex host files" "see its stderr above"
    HAVE_CODEX=0
  else
    # The signature segment: unique to the real token, absent from the placeholder.
    CODEX_NEEDLE=$(cut -d. -f3 "${SECRETS}/CODEX" | head -c 40)
    _placeholder=$(PI_AUTH="$REAL_PI_AUTH" "$CODEX_HELPER" --print-placeholder)
    P="$_placeholder" A="${XDG_CONFIG_HOME}/rip-cage/pi-codex/auth.json" \
      yq -i '.secrets.CODEX.allow = ["chatgpt.com"]
             | .secrets.CODEX.placeholder = strenv(P)
             | .mounts += [strenv(A) + ":/home/agent/.pi/agent/auth.json:ro"]
             | .network.allow += ["chatgpt.com:tcp:443"]' "$CONF"
  fi
fi

# --- one real rc up ------------------------------------------------------------
scratch_cage_register "$NAME"
if ! "$RC" up "$WS" </dev/null >"${T}/up.log" 2>&1; then
  fail "rc up exited non-zero" "$(tail -8 "${T}/up.log" | tr '\n' ' ')"
  exit "$FAILURES"
fi
pass "rc up: cage ${NAME} up from the shipped template plus the pi deltas"

gexec() { local _s="$1"; shift; msb exec "$NAME" -- timeout "$_s" "$@" </dev/null 2>&1; }

# --- the rw ~/.pi/agent pi's lockfile needs ----------------------------------
_owner=$(gexec 20 stat -c %U /home/agent/.pi/agent | tr -d '\r\n')
[[ "$_owner" == "agent" ]] && pass "~/.pi/agent is agent-owned (pi can create its lockfile)" \
  || fail "~/.pi/agent owner is '${_owner}', not agent"

# --- providers -------------------------------------------------------------------
if [[ $HAVE_OR -eq 1 ]]; then
  _env=$(gexec 20 printenv OPENROUTER_API_KEY | tr -d '\r\n')
  [[ "$_env" == '$MSB_OPENROUTER' ]] && pass "openrouter: guest env holds only the placeholder" \
    || fail "openrouter: guest OPENROUTER_API_KEY is not the placeholder"
  _out=$(gexec 90 pi -p --no-session --provider openrouter --model "$OR_MODEL" \
    'Reply with the literal string PI_E2E_OPENROUTER_OK and nothing else')
  grep -q 'PI_E2E_OPENROUTER_OK' <<<"$_out" && pass "openrouter: pi -p replied PI_E2E_OPENROUTER_OK" \
    || fail "openrouter: no PI_E2E_OPENROUTER_OK" "$(head -c 400 <<<"$_out")"
else
  echo "SKIP: openrouter — no ${REAL_XDG}/rip-cage/secrets/OPENROUTER on host"
fi

if [[ $HAVE_CODEX -eq 1 ]]; then
  _out=$(gexec 120 pi -p --no-session --provider openai-codex --model "$CODEX_MODEL" \
    'Reply with the literal string PI_E2E_CODEX_OK and nothing else')
  grep -q 'PI_E2E_CODEX_OK' <<<"$_out" && pass "openai-codex: pi -p replied PI_E2E_CODEX_OK" \
    || fail "openai-codex: no PI_E2E_CODEX_OK" "$(head -c 400 <<<"$_out")"
  _acc=$(gexec 20 jq -r '."openai-codex".refresh' /home/agent/.pi/agent/auth.json | tr -d '\r\n')
  [[ "$_acc" == "rc-placeholder-no-refresh" ]] && pass "openai-codex: guest auth.json still the placeholder after the call" \
    || fail "openai-codex: guest auth.json refresh is '${_acc}'"
else
  echo "SKIP: openai-codex — no openai-codex login in ${REAL_PI_AUTH}"
fi

# --- non-possession: no real credential anywhere the guest can read ----------
# Dumped guest-side, grepped host-side: the needles never enter the guest.
_dump=$(gexec 60 sh -c 'cat /proc/[0-9]*/environ 2>/dev/null; find /home/agent/.pi /workspace -type f -exec cat {} + 2>/dev/null' | tr '\0' '\n')
# Positive sentinel: the dump must reach the env pi runs under, or every
# absence below proves nothing.
if [[ ${#_dump} -lt 200 ]] || { [[ $HAVE_OR -eq 1 ]] && ! grep -qF 'OPENROUTER_API_KEY=' <<<"$_dump"; }; then
  fail "non-possession: guest dump did not capture the cage env (${#_dump} bytes)"
else
  _leak=0
  [[ -n "$OR_NEEDLE" ]] && grep -qF "$OR_NEEDLE" <<<"$_dump" && { _leak=1; fail "non-possession: the real OpenRouter key is readable in the guest"; }
  [[ -n "$CODEX_NEEDLE" ]] && grep -qF "$CODEX_NEEDLE" <<<"$_dump" && { _leak=1; fail "non-possession: the real openai-codex token is readable in the guest"; }
  grep -qF "$ANTHROPIC_SENTINEL" <<<"$_dump" && { _leak=1; fail "the host pi auth.json (anthropic sentinel) reached the guest"; }
  [[ $_leak -eq 0 ]] && pass "non-possession: no real key, no host pi auth.json in guest env, ~/.pi or /workspace (${#_dump} bytes scanned)"
fi

exit "$FAILURES"
