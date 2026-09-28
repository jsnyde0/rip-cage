#!/usr/bin/env bash
# tests/test-auth-secret-live.sh -- container-tier proof that the Claude login
# reaches the guest ONLY through msb --secret (rip-cage-ely4.7.17).
#
# Boots ONE scratch cage from the shipped template config
# (share/rip-cage/cage.yaml.template) under a temp HOME and XDG_CONFIG_HOME, and
# asserts:
#   L1  no /home/agent/.claude/.credentials.json in the guest
#   L2  the guest's CLAUDE_CODE_OAUTH_TOKEN is exactly the placeholder $MSB_CCTOK
#   L3  the real token appears nowhere in the guest's environment (checked by
#       grep -F -f against the host file, never by printing either side)
#   L4  `claude -p` exits 0 with non-empty output against api.anthropic.com
#
# The real token is needed for L4. Its only touch is a `cp -p` of the host
# secrets file into the temp XDG tree, deleted in teardown. Nothing here
# prints, logs or echoes its content. Source file: RC_LIVE_CCTOK_SRC, default
# ~/.config/rip-cage/secrets/CCTOK. Absent -> SKIP (no token, nothing to prove).
#
# Image: RC_IMAGE, REQUIRED to be an explicit scratch tag, never
# rip-cage:latest (rip-cage-ely4.7.17 fix round 3, finding 4). `rc up`'s
# image-present branch still takes the image-absent (pull+tag+load) path when
# the LOCAL tag's org.opencontainers.image.version label doesn't match rc's
# own VERSION file (_image_is_current, cli/build.sh) -- not just when the tag
# is missing entirely. That is exactly the shape of this bead's own INCIDENT
# note: a real non-dry-run rc up reached that branch and re-tagged the
# operator's production rip-cage:latest. Build a scratch tag with
# `RC_IMAGE=<tag> rc build --file cage/Dockerfile` to prove an unreleased tree.
#
# NEEDS_CONTAINER (registered in tests/run-host.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC="${REPO_ROOT}/rc"
IMAGE="${RC_IMAGE:-rip-cage:latest}"
REAL_HOME="$HOME"
CCTOK_SRC="${RC_LIVE_CCTOK_SRC:-${REAL_HOME}/.config/rip-cage/secrets/CCTOK}"

FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ -- $2}"; FAILS=$((FAILS + 1)); }

if [[ ! -f "$CCTOK_SRC" ]]; then
  echo "SKIP: no host CCTOK secrets file at ${CCTOK_SRC} (run 'claude setup-token', save it there, chmod 600)"
  exit 0
fi
# rip-cage-ely4.7.17 fix round 3, finding 4: never run against rip-cage:latest
# at all -- the operator's production tag is exactly what an earlier round's
# INCIDENT rewrote. Before any rc call.
if [[ -z "${RC_IMAGE:-}" || "$RC_IMAGE" == "rip-cage:latest" ]]; then
  echo "SKIP: RC_IMAGE must be set to an explicit scratch tag other than rip-cage:latest -- this proof never runs rc up against the operator's production tag. Build one: RC_IMAGE=<tag> rc build --file cage/Dockerfile"
  exit 0
fi
command -v msb >/dev/null 2>&1 || { echo "SKIP: msb not on PATH"; exit 0; }
msb image inspect "$IMAGE" --format json >/dev/null 2>&1 || { echo "SKIP: image ${IMAGE} not in msb's cache"; exit 0; }
# rc up's image-absent branch pulls and re-tags. Require the image locally in
# docker too, and pin rc to the same tag, so this test can never trigger a pull
# or touch an image it did not name.
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "SKIP: image ${IMAGE} not in docker's store (refusing to let rc up pull)"; exit 0; }
# rc up ALSO takes that same pull+tag path when the tag EXISTS but carries a
# stale version label -- reuse rc's OWN _image_is_current (cli/build.sh),
# sourced rather than re-implemented, same idiom as container_name below, so
# this guard can never drift from the check rc up itself makes.
if ! ( RC_IMAGE="$IMAGE" bash -c "source '${RC}' 2>/dev/null; _image_is_current" ); then
  echo "SKIP: ${IMAGE} is not current per rc's own _image_is_current check (org.opencontainers.image.version label doesn't match rc's VERSION file) -- rc up would take the image-absent branch and pull/tag/load onto it. Build a fresh scratch tag: RC_IMAGE=${IMAGE} rc build --file cage/Dockerfile"
  exit 0
fi
export RC_IMAGE="$IMAGE"

# macOS: msb does not follow a host-side symlink in a mount source, and /tmp is
# one; write under /private/tmp.
_tmp_root=/tmp
[[ -d /private/tmp ]] && _tmp_root=/private/tmp
T=$(mktemp -d "${_tmp_root}/rc-live-auth.XXXXXX")
T=$(cd "$T" && pwd -P)

cleanup_tmp() {
  rm -f "${T}/xdg/rip-cage/secrets/CCTOK" 2>/dev/null
  rm -rf "$T"
}
trap cleanup_tmp EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/xdg"
# Same pins test-e2e-lifecycle.sh uses under a scratch HOME: the real msb home
# (image cache) and the real docker context, and nothing else from the real HOME.
export MSB_HOME="${REAL_HOME}/.microsandbox"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/skills"
echo '{}' > "$HOME/.claude.json"
[[ -e "${REAL_HOME}/.docker" ]] && ln -sfn "${REAL_HOME}/.docker" "${HOME}/.docker"
unset CCTOK

WS="${T}/ws"
mkdir -p "$WS"
git -C "$WS" init -q
echo "# live auth proof" > "$WS/README"
export RC_ALLOWED_ROOTS="$T"

NAME=$(bash -c "source '${RC}' 2>/dev/null; container_name '$WS'")
[[ -n "$NAME" ]] || { echo "FATAL: could not derive cage name"; exit 1; }

mkdir -p "${XDG_CONFIG_HOME}/rip-cage/projects" "${XDG_CONFIG_HOME}/rip-cage/secrets"
CONF="${XDG_CONFIG_HOME}/rip-cage/projects/${NAME}.yaml"
# The shipped template VERBATIM, placeholders filled (rip-cage-mxr8 removed the
# workaround that dropped three colliding mount lines here).
sed -e "s#<ABSOLUTE_PATH_TO_YOUR_PROJECT>#${WS}#g" \
    -e "s#<ABSOLUTE_PATH_TO_YOUR_HOME>#${HOME}#g" \
    -e "s#<CAGE-NAME>#${NAME}#g" \
    -e "s#^image: rip-cage:latest#image: ${IMAGE}#" \
    "${REPO_ROOT}/share/rip-cage/cage.yaml.template" > "$CONF"
cp -p "$CCTOK_SRC" "${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK"
TOKFILE="${XDG_CONFIG_HOME}/rip-cage/secrets/CCTOK"

# shellcheck source=tests/_scratch-cage-lib.sh
source "${SCRIPT_DIR}/_scratch-cage-lib.sh"
scratch_cage_register "$NAME"

echo "cage=${NAME} image=${IMAGE}"
echo "conf=${CONF} (shipped template, placeholders filled)"

# rc auth must accept the copied file (host tier covers the failure cases).
if "$RC" auth >/dev/null 2>&1; then pass "rc auth accepts the 0600 setup-token file"; else fail "rc auth rejected the copied token file"; fi

# gexec SECS CMD... -- one guest command, stdin closed and time-bounded.
# macOS has no timeout(1); perl alarm SIGALRMs the exec'd msb (exit 142).
# An unbounded msb exec with inherited stdin once hung >10 min here.
gexec() {
  local _secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$_secs" msb exec "$NAME" -- "$@" < /dev/null
}

UP_LOG="${T}/up.log"
"$RC" up "$WS" < /dev/null > "$UP_LOG" 2>&1
up_rc=$?
if [[ "$(msb inspect "$NAME" --format json 2>/dev/null | jq -r '.status // .state // empty')" =~ ^[Rr]unning$ ]] || gexec 30 true >/dev/null 2>&1; then
  pass "rc up booted the template cage (rc up exit ${up_rc})"
else
  fail "rc up did not produce a running cage (exit ${up_rc})" "log tail: $(tail -5 "$UP_LOG" | tr '\n' ' ')"
  exit 1
fi

# M1-M3 (rip-cage-mxr8): the template boots with init exit 0, rc's skills
# projection is the symlink, and no Claude-home mount warning fired.
if [[ $up_rc -eq 0 ]]; then pass "M1 rc up (init included) exit 0 on the template config"; else fail "M1 rc up exit ${up_rc}" "log tail: $(tail -5 "$UP_LOG" | tr '\n' ' ')"; fi
skills_link=$(gexec 30 readlink /home/agent/.claude/skills 2>/dev/null)
if [[ "$skills_link" == "/home/agent/.rc-context/skills" ]]; then pass "M2 ~/.claude/skills -> ${skills_link}"; else fail "M2 ~/.claude/skills is not the rc projection symlink" "readlink=${skills_link:-<none>}"; fi
if grep -q "does not mount ~/.claude\|mounts ~/.claude/skills itself" "$UP_LOG"; then fail "M3 rc up warned about Claude-home mounts on the template" "$(grep 'Warning: cage config' "$UP_LOG" | head -2 | tr '\n' ' ')"; else pass "M3 no Claude-home mount warning on the template"; fi

# L1
gexec 30 test -e /home/agent/.claude/.credentials.json >/dev/null 2>&1
l1_rc=$?
if [[ $l1_rc -eq 1 ]]; then
  pass "L1 no /home/agent/.claude/.credentials.json in the guest"
elif [[ $l1_rc -eq 0 ]]; then
  fail "L1 /home/agent/.claude/.credentials.json EXISTS in the guest"
else
  fail "L1 probe did not answer (exit ${l1_rc})"
fi

# L2 -- the placeholder is not a secret; printing it is the proof.
# shellcheck disable=SC2016  # expands in the guest shell, not here
guest_tok=$(gexec 30 sh -c 'printf %s "${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}"' 2>/dev/null)
# shellcheck disable=SC2016  # the literal placeholder string
if [[ "$guest_tok" == '$MSB_CCTOK' ]]; then
  pass "L2 guest CLAUDE_CODE_OAUTH_TOKEN=${guest_tok} (placeholder only)"
else
  # Never echo a non-placeholder value: it could be the real token.
  fail "L2 guest CLAUDE_CODE_OAUTH_TOKEN is not the placeholder" "length=${#guest_tok}"
fi

# L3 -- grep the captured guest environment for the real token without
# printing either. Covers the exec environment and PID 1's environment.
ENV_DUMP="${T}/guest-env"
gexec 30 sh -c 'env; tr "\0" "\n" < /proc/1/environ 2>/dev/null' > "$ENV_DUMP" 2>/dev/null
if [[ ! -s "$ENV_DUMP" ]]; then
  fail "L3 could not capture the guest environment"
elif grep -qF -f "$TOKFILE" "$ENV_DUMP"; then
  fail "L3 the REAL token appears in the guest environment"
else
  pass "L3 real token absent from guest env and PID 1 environ ($(wc -l < "$ENV_DUMP" | tr -d ' ') lines scanned)"
fi
rm -f "$ENV_DUMP"

# L4 -- macOS has no timeout(1); perl alarm bounds the call.
CL_OUT="${T}/claude.out"
gexec 180 bash -lc 'command -v claude >&2; claude -p "Reply with exactly the word ok and nothing else. Do not use tools."' \
  > "$CL_OUT" 2>&1
cl_rc=$?
if grep -qF -f "$TOKFILE" "$CL_OUT"; then
  fail "L4 claude -p output contains the real token (not shown)"
elif [[ $cl_rc -eq 0 && -s "$CL_OUT" ]]; then
  pass "L4 claude -p exit 0, output: $(head -c 200 "$CL_OUT" | tr '\n' ' ')"
else
  fail "L4 claude -p exit ${cl_rc}" "output: $(head -c 400 "$CL_OUT" | tr '\n' ' ')"
fi

# M4 (rip-cage-mxr8): a PRE-mxr8 config -- no session lines, the old skills
# line still present -- boots, and rc up names both problems before msb
# instead of init failing. Same cage name, recreated via --replace.
LEGACY_CONF="${T}/legacy.yaml"
sed -e '\#/.claude/projects:/home/agent/.claude/projects"#d' \
    -e '\#/.claude/sessions:/home/agent/.claude/sessions"#d' \
    -e "s#^  - \"${WS}:/workspace\"#&\\
  - \"${HOME}/.claude/skills:/home/agent/.claude/skills:ro\"#" \
    "$CONF" > "$LEGACY_CONF"
if grep -qF "${HOME}/.claude/skills:/home/agent/.claude/skills:ro" "$LEGACY_CONF"; then
  cp "$LEGACY_CONF" "$CONF"
  LEG_LOG="${T}/up-legacy.log"
  "$RC" up --replace "$WS" < /dev/null > "$LEG_LOG" 2>&1
  leg_rc=$?
  if [[ $leg_rc -eq 0 ]]; then pass "M4a legacy config boots, rc up exit 0"; else fail "M4a legacy config rc up exit ${leg_rc}" "log tail: $(tail -5 "$LEG_LOG" | tr '\n' ' ')"; fi
  if grep -q "does not mount ~/.claude/projects" "$LEG_LOG" && grep -q "does not mount ~/.claude/sessions" "$LEG_LOG"; then pass "M4b rc up names both missing session lines"; else fail "M4b missing-session-line warning absent"; fi
  if grep -q "mounts ~/.claude/skills itself" "$LEG_LOG"; then pass "M4c rc up names the legacy skills line"; else fail "M4c legacy skills-line warning absent"; fi
  # shellcheck disable=SC2016  # awk program runs in the guest
  if gexec 30 awk '$5 == "/home/agent/.claude/skills" { f=1 } END { exit !f }' /proc/self/mountinfo >/dev/null 2>&1; then pass "M4d init left the config's skills mount in place"; else fail "M4d ~/.claude/skills is not the config mount after init"; fi
else
  fail "M4 could not build the legacy config fixture"
fi

echo ""
if [[ $FAILS -eq 0 ]]; then echo "ALL LIVE CHECKS PASSED"; exit 0; fi
echo "${FAILS} LIVE CHECK(S) FAILED"
exit 1
