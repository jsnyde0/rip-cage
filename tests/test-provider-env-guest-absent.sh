#!/usr/bin/env bash
# tests/test-provider-env-guest-absent.sh -- container-tier proof for
# rip-cage-565x R10 / rip-cage-rsh9.4 (ADR-031 D1 non-possession, ADR-019 D5):
# provider API keys exported in the host shell never reach the guest. The
# host-tier sibling (test-up-provider-env-not-forwarded.sh) checks rc's argv;
# this one boots a real cage and checks the guest's own environment.
#
# One scratch cage from the shipped template, plus an OPENROUTER secrets:
# binding with an env: line (the pi-providers recipe shape).
#   G1  rc up exits 0 with fake provider keys exported; no fake value in rc's output
#   G2  `env` in the guest holds no fake value
#   G3  no user process's environ holds a fake value; read as root, and an
#       environ that exists but cannot be read fails the check
#   G4  positive control: OPENROUTER_API_KEY in the guest IS the msb
#       placeholder, so the env capture in G2/G3 can see a provider var at all
#
# No real credential is used (fake CCTOK and OPENROUTER secret files).
#
# Image: RC_IMAGE, REQUIRED to be an explicit scratch tag, never
# rip-cage:latest. Build one: RC_IMAGE=<tag> rc build --file cage/Dockerfile
#
# NEEDS_CONTAINER.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"
REAL_HOME="$HOME"

FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ -- $2}"; FAILS=$((FAILS + 1)); }

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
if [[ -z "${RC_IMAGE:-}" ]]; then
  echo "SKIP: RC_IMAGE must be set to an explicit scratch tag other than rip-cage:latest. Build one: RC_IMAGE=<tag> rc build --file cage/Dockerfile"
  exit 0
fi
if scratch_image_is_production "$RC_IMAGE"; then
  echo "FAIL: RC_IMAGE=${RC_IMAGE} names the operator's production tag (rip-cage:latest) -- this test never boots a cage on it. Build a scratch tag: RC_IMAGE=<tag> rc build --file cage/Dockerfile"
  exit 1
fi
IMAGE="$RC_IMAGE"
command -v msb >/dev/null 2>&1 || { echo "SKIP: msb not on PATH"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
msb image inspect "$IMAGE" --format json >/dev/null 2>&1 || { echo "SKIP: image ${IMAGE} not in msb's cache"; exit 0; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "SKIP: image ${IMAGE} not in docker's store (refusing to let rc up pull)"; exit 0; }
if ! ( RC_IMAGE="$IMAGE" bash -c "source '${RC}' 2>/dev/null; _image_is_current" ); then
  echo "SKIP: ${IMAGE} is not current per rc's own _image_is_current check. Rebuild: RC_IMAGE=${IMAGE} rc build --file cage/Dockerfile"
  exit 0
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_host-sandbox-lib.sh"
T=$(_host_scratch_mktemp_d rc-live-provenv)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/xdg"
export MSB_HOME="${REAL_HOME}/.microsandbox"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/skills"
echo '{}' > "$HOME/.claude.json"
[[ -e "${REAL_HOME}/.docker" ]] && ln -sfn "${REAL_HOME}/.docker" "${HOME}/.docker"
unset CCTOK

WS="${T}/ws"
mkdir -p "$WS"
git -C "$WS" init -q -b main

NAME=$(bash -c "source '${RC}' 2>/dev/null; container_name '$WS'")
[[ -n "$NAME" ]] || { echo "FATAL: could not derive cage name"; exit 1; }
SECRETS="${XDG_CONFIG_HOME}/rip-cage/secrets"
CONF="${XDG_CONFIG_HOME}/rip-cage/projects/${NAME}.yaml"
mkdir -p "${XDG_CONFIG_HOME}/rip-cage/projects" "$SECRETS"
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${HOME}#g" \
    -e "s#<CAGE-NAME>#${NAME}#g" \
    -e "s#^image: rip-cage:latest#image: ${IMAGE}#" \
    "${REPO_ROOT}/share/rip-cage/cage.yaml.template" > "$CONF"
# shellcheck disable=SC2016  # $MSB_OPENROUTER is the literal placeholder text
yq -i '.secrets.OPENROUTER.allow = ["openrouter.ai"]
       | .env.OPENROUTER_API_KEY = "$MSB_OPENROUTER"
       | .network.allow += ["openrouter.ai:tcp:443"]' "$CONF"
( umask 077; printf 'sk-ant-oat01-%s' "$(printf 'x%.0s' $(seq 1 90))" > "${SECRETS}/CCTOK" )
( umask 077; printf 'fake-openrouter-secret-565x' > "${SECRETS}/OPENROUTER" )

scratch_cage_register "$NAME"
echo "cage=${NAME} image=${IMAGE}"

g() {  # g <secs> <command...> -- run in the guest, stdin closed
  perl -e 'alarm shift; exec @ARGV' "$1" msb exec "$NAME" -- "${@:2}" < /dev/null 2>&1
}

# The retired passthrough list (git show 404a866:cli/up.sh): every name set.
PROVIDER_KEYS=(
  ANTHROPIC_API_KEY AZURE_OPENAI_API_KEY OPENAI_API_KEY GEMINI_API_KEY
  MISTRAL_API_KEY GROQ_API_KEY CEREBRAS_API_KEY XAI_API_KEY
  OPENROUTER_API_KEY AI_GATEWAY_API_KEY ZAI_API_KEY OPENCODE_API_KEY
  KIMI_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY
)
for _k in "${PROVIDER_KEYS[@]}"; do export "${_k}=fake-x-${_k}"; done

if "$RC" up "$WS" < /dev/null > "${T}/up.log" 2>&1; then
  if grep -q 'fake-x' "${T}/up.log"; then
    fail "G1 a fake provider value reached rc's output" "$(grep 'fake-x' "${T}/up.log" | head -2)"
  else
    pass "G1 rc up exit 0, no fake provider value in its output"
  fi
else
  fail "G1 rc up" "log tail: $(tail -5 "${T}/up.log" | tr '\n' ' ')"
  echo "${FAILS} LIVE CHECK(S) FAILED"; exit 1
fi

out=$(g 30 sh -c 'env | grep -c fake-x')
if [[ "$out" == "0" ]]; then
  pass "G2 guest env holds no fake provider value"
else
  fail "G2 guest env" "grep -c fake-x -> '${out}'"
fi

# Runs as root so every user process's environ is readable; prints "<hits>
# <unread>", where unread counts environs that still exist but failed to read.
# Skipped, not counted: a pid with no VmSize (a kernel thread -- no address
# space, so no environ; open() fails ESRCH) and a pid that exited mid-scan.
# Both numbers must be 0.
# shellcheck disable=SC2016  # guest-side script, expands in the guest
out=$(perl -e 'alarm shift; exec @ARGV' 30 msb exec -u root "$NAME" -- sh -c '
  hits=0; unread=0
  for d in /proc/[0-9]*; do
    grep -q "^VmSize:" "$d/status" 2>/dev/null || continue
    if e=$( { tr "\0" "\n" < "$d/environ"; } 2>/dev/null); then
      case "$e" in *fake-x*) hits=$((hits + 1)) ;; esac
    elif [ -e "$d/environ" ]; then
      unread=$((unread + 1))
    fi
  done
  echo "$hits $unread"' < /dev/null 2>&1)
if [[ "$out" == "0 0" ]]; then
  pass "G3 no guest user-process environ holds a fake provider value (all read, as root)"
else
  fail "G3 guest process environ" "hits/unread -> '${out}'"
fi

out=$(g 30 printenv OPENROUTER_API_KEY | tr -d '\r\n')
# shellcheck disable=SC2016  # literal placeholder, must not expand
if [[ "$out" == '$MSB_OPENROUTER' ]]; then
  pass "G4 positive control: guest OPENROUTER_API_KEY is the msb placeholder"
else
  fail "G4 positive control" "OPENROUTER_API_KEY in guest = '${out:0:12}...'"
fi

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "All live checks passed"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"; exit 1
