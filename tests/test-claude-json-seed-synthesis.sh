#!/usr/bin/env bash
# test-claude-json-seed-synthesis.sh — NEEDS_CONTAINER host-tier test
#
# Verifies init-rip-cage.sh's R4 seed-synthesis extension (rip-cage-vwka):
# when the host Claude config is NOT mounted and no ~/.claude/.claude.json.seed
# exists yet, init writes a minimal synthesized seed carrying
# hasCompletedOnboarding:true — so interactive claude skips the theme+login
# onboarding screens instead of hitting an unusable-in-cage browser OAuth login
# wall (proven manually 2026-07-06). When the config IS mounted, the snapshot
# (rip-cage-p1p, R4) must stay byte-identical, and synthesis must never clobber
# an existing seed.
#
# WHAT DECIDES WHICH CASE A CAGE IS IN (rip-cage-ely4.7.10): one mount line in
# the cage's own config file, read-only — the line the shipped template carries
# (share/rip-cage/cage.yaml.template) and tests/_cage-conf-lib.sh reproduces.
# rc adds no Claude-config mount of its own, so a cage whose config omits the
# line simply has no such file in-cage.
#
# Coverage, across two cages: NP (fixture HOME without the file, so the config
# carries no mount line) and PC (fixture HOME with it, so the config mounts it
# read-only).
#   V1  — seed synthesized when the config carries no mount line (NP)
#   V1b — synthesized seed carries no oauthAccount / credential-shaped fields
#   V2  — synthesis never clobbers an existing seed: a sentinel written into
#         the seed survives a second init run (real msb-stop + rc-up resume,
#         same call site as the rip-cage-p1p snapshot ordering)
#   V3  — positive control: the mounted path still snapshots byte-identical to
#         the host fixture (R4 ordering untouched) (PC)
#   V4  — claude-wrapper 'no seed snapshot' WARNING does not fire once a seed
#         is present. Copies the UNMODIFIED canonical wrapper
#         (examples/claude/claude-session-wrapper.sh) into the cage and stubs
#         only REAL_CLAUDE (so exec doesn't spend a real model call) — the
#         wrapper source itself is never edited, only a container-local copy.
#   V5  — genuinely-broken case: the WARNING still fires when no seed exists
#         at all (keeps the wrapper's fail-loud fallback alive per the bead's
#         explicit constraint — this is NOT a regression to fix away)
#   V6  — the synthesized fallback does NOT fire when the mount is present (PC)
#   V6b — the in-cage file really is read-only: an append fails (PC)
#   V6c — msb inspect reports the mount with the mode the config declared (PC)
#
# CRITICAL: run-host.sh exports RC_CONFIG_GLOBAL pointing to a benign fixture
# for the whole suite. Standalone runs must not inherit a dev machine's real
# global config (e.g. a promoted network.egress.mediator that requires
# egress=on — see rip-cage-u2ro). unset here and sandbox HOME/XDG_CONFIG_HOME
# per cage, matching the test-auto-seed.sh pattern.
unset RC_CONFIG_GLOBAL

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/_cage-lookup-lib.sh
source "${SCRIPT_DIR}/_cage-lookup-lib.sh"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

# This suite sandboxes HOME so rc reads a fixture tree. Docker resolves its
# CONTEXT through $HOME/.docker, so a sandboxed HOME makes `docker info` fail
# and cases report a daemon error instead of their own subject. Point
# DOCKER_CONFIG at the real one: the isolation needed is over rip-cage's own
# config, not over the container runtime.
RC_TEST_REAL_DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
export RC_TEST_REAL_DOCKER_CONFIG

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_cage-conf-lib.sh"

WRAPPER_SRC="${REPO_ROOT}/examples/claude/claude-session-wrapper.sh"

# REAL_MSB_HOME (msb-port note, rip-cage-neu7.14 Batch E — mirrors
# test-mount-mode-e2e.sh / test-multiplexer-lifecycle.sh /
# test-agent-mail-concurrent.sh): each cage setup below overrides HOME to a
# throwaway mktemp dir to isolate that cage's ~/.claude.json fixture. msb
# keys its own sandbox-relay-socket state dir off $HOME at `rc up` call
# time; with HOME pointed at a deep mktemp path, the derived AF_UNIX relay
# socket path overflows the 104-byte Unix socket path limit ("agent relay
# socket path is too long"), and `rc up` fails to create the container
# outright (verified live during this port). Pinning MSB_HOME to the real,
# unmodified microsandbox home for every `rc up` call below sidesteps it.
REAL_MSB_HOME="${HOME}/.microsandbox"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# Guards
#
# msb-port note (rip-cage-neu7.14, Batch E): `rc up` now creates msb
# sandboxes invisible to docker ps/exec/cp/stop -- cage resolution, exec,
# stdin-file transfer, and stop/resume below are rewired onto the msb-native
# surface (canonical pattern: /tmp/msb-port-canonical.md). `docker image
# inspect rip-cage:latest` stays: it is an image-level check (the image is
# still `docker build`-produced), not a cage-runtime check.
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not available"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available"
  exit 0
fi
if ! docker image inspect rip-cage:latest >/dev/null 2>&1; then
  echo "SKIP: rip-cage:latest not built — run ./rc build first"
  exit 0
fi

echo "=== test-claude-json-seed-synthesis.sh ==="

NP_HOME=""; NP_WS_ROOT=""; NP_NAME=""
PC_HOME=""; PC_WS_ROOT=""; PC_NAME=""

# HARDENED CLEANUP SHAPE (rip-cage-neu7.14, Batch E msb port; incident
# guardrail — see /tmp/msb-port-canonical.md). CREATED_CAGES holds ONLY the
# cage names this run actually created, appended via _track in THIS (parent)
# shell right after each cage's name is resolved below — never inside a
# $(...) subshell (rip-cage-neu7.12 lesson: array mutations inside a
# captured subshell never propagate to the trap). cleanup() destroys ONLY
# these tracked names via a single `rc destroy --force` each (replaces the
# separate `docker rm -f` + `docker volume rm rc-state-*` pair — rc destroy
# removes the sandbox AND its rc-state/rc-history volumes together). NEVER
# an `rc ls`/`msb list` enumeration matched by pattern/glob.
CREATED_CAGES=()
_track() { [[ -n "${1:-}" ]] && CREATED_CAGES+=("$1"); }

cleanup() {
  local c _d_out _d_rc
  for c in "${CREATED_CAGES[@]:-}"; do
    if [[ -n "$c" ]]; then
      _d_out=$("$RC" destroy "$c" 2>&1)
      _d_rc=$?
      if [[ "$_d_rc" -ne 0 ]]; then
        echo "WARNING: failed to destroy '$c' (exit ${_d_rc}): ${_d_out}" >&2
      fi
    fi
  done
  [[ -n "$NP_HOME" && -d "$NP_HOME" ]] && rm -rf "$NP_HOME"
  [[ -n "$NP_WS_ROOT" && -d "$NP_WS_ROOT" ]] && rm -rf "$NP_WS_ROOT"
  [[ -n "$PC_HOME" && -d "$PC_HOME" ]] && rm -rf "$PC_HOME"
  [[ -n "$PC_WS_ROOT" && -d "$PC_WS_ROOT" ]] && rm -rf "$PC_WS_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Setup: NP cage — fixture HOME has no Claude config file, so its cage config
# carries no mount line for one and the cage boots without it. A
# CLAUDE_CODE_OAUTH_TOKEN placeholder rides in via --env-file.
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup: NP cage (cage config carries no Claude-config mount) ==="
NP_WS_ROOT=$(mktemp -d)
NP_HOME=$(mktemp -d)
NP_WS="${NP_WS_ROOT}/np-cage"
mkdir -p "$NP_WS"
git -C "$NP_WS" init -q
NP_ENVFILE="${NP_WS_ROOT}/np.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=placeholder-token-vwka\n' > "$NP_ENVFILE"
chmod 600 "$NP_ENVFILE"
NP_UP_OUT="${NP_WS_ROOT}/np-up.out"
# Generate the config in its own statement, with HOME pointed at the fixture:
# the generator reads HOME to decide whether to carry the template's
# host-Claude-config mount line, and burying that dependency in the env prefix
# of the `rc up` call below hides it behind bash's assignment ordering. This
# HOME has no such file, so the cage boots without the mount — the input V1
# needs.
NP_CONF=$(HOME="$NP_HOME" cage_conf_for "$NP_WS")
HOME="$NP_HOME" DOCKER_CONFIG="$RC_TEST_REAL_DOCKER_CONFIG" MSB_HOME="$REAL_MSB_HOME" \
  RC_SKIP_KEYCHAIN_EXTRACTION=1 \
  ANTHROPIC_API_KEY="" \
  RC_CAGE_CONF="$NP_CONF" \
  RIP_CAGE_EGRESS=off \
  "$RC" up "$NP_WS" --env-file "$NP_ENVFILE" </dev/null >"$NP_UP_OUT" 2>&1 || true
NP_NAME=$(cage_name_for_source "$NP_WS")

NP_LIVE=false
if [[ -z "$NP_NAME" ]]; then
  fail "NP cage did not start (see $NP_UP_OUT)"
else
  _track "$NP_NAME"
  NP_LOG=$(cat "$NP_UP_OUT" 2>/dev/null || true)
  # Gate on the init sentinel so an absence assertion below can't pass
  # vacuously against an empty capture (rip-cage-igm discipline).
  if printf '%s\n' "$NP_LOG" | grep -q '\[rip-cage\] pi '; then
    NP_LIVE=true
    pass "NP cage booted (init sentinel present)"
  else
    fail "NP cage init sentinel absent — init output not captured" "(see $NP_UP_OUT)"
  fi
fi

# ---------------------------------------------------------------------------
# V1 / V1b
# ---------------------------------------------------------------------------
if [[ "$NP_LIVE" == "true" ]]; then
  echo ""
  echo "=== V1: seed synthesized when mount absent ==="
  NP_SEED=$(msb exec "$NP_NAME" -- cat /home/agent/.claude/.claude.json.seed 2>/dev/null || true)
  if [[ -z "$NP_SEED" ]]; then
    fail "V1: /home/agent/.claude/.claude.json.seed missing or empty in the NP cage"
  else
    pass "V1: /home/agent/.claude/.claude.json.seed present and non-empty"
    if echo "$NP_SEED" | jq -e '.hasCompletedOnboarding == true' >/dev/null 2>&1; then
      pass "V1: synthesized seed has hasCompletedOnboarding:true"
    else
      fail "V1: synthesized seed missing hasCompletedOnboarding:true" "content: $NP_SEED"
    fi

    echo ""
    echo "=== V1b: synthesized seed carries no credential-shaped fields ==="
    if echo "$NP_SEED" | jq -e 'has("oauthAccount")' >/dev/null 2>&1; then
      fail "V1b: synthesized seed unexpectedly has oauthAccount" "content: $NP_SEED"
    else
      pass "V1b: synthesized seed has no oauthAccount key"
    fi
    if echo "$NP_SEED" | jq -e 'has("claudeAiOauth")' >/dev/null 2>&1; then
      fail "V1b: synthesized seed unexpectedly has claudeAiOauth" "content: $NP_SEED"
    else
      pass "V1b: synthesized seed has no claudeAiOauth key"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# V2: synthesis never clobbers an existing seed. Overwrite the seed with a
# sentinel, then drive a REAL resume (msb stop + rc up — msb-port note,
# rip-cage-neu7.14: `docker stop` has no docker analog under msb; state-
# preserving stop is `msb stop`, resume is still `rc up`) — the same call
# site (_up_init_container) that runs on the mounted-case ordering — and
# confirm the sentinel survives untouched.
# ---------------------------------------------------------------------------
if [[ "$NP_LIVE" == "true" ]]; then
  echo ""
  echo "=== V2: synthesis never clobbers an existing seed ==="
  V2_SENTINEL='{"sentinel-vwka":"do-not-clobber","hasCompletedOnboarding":true}'
  msb exec "$NP_NAME" -- sh -c "printf '%s' '${V2_SENTINEL}' > /home/agent/.claude/.claude.json.seed"
  msb stop "$NP_NAME" >/dev/null 2>&1
  NP_RESUME_OUT="${NP_WS_ROOT}/np-resume.out"
  HOME="$NP_HOME" DOCKER_CONFIG="$RC_TEST_REAL_DOCKER_CONFIG" MSB_HOME="$REAL_MSB_HOME" \
    RC_SKIP_KEYCHAIN_EXTRACTION=1 \
    ANTHROPIC_API_KEY="" \
    RC_CAGE_CONF="$NP_CONF" \
    RIP_CAGE_EGRESS=off \
    "$RC" up "$NP_WS" </dev/null >"$NP_RESUME_OUT" 2>&1 || true
  NP_RESUME_LOG=$(cat "$NP_RESUME_OUT" 2>/dev/null || true)
  if ! printf '%s\n' "$NP_RESUME_LOG" | grep -q '\[rip-cage\] pi '; then
    fail "V2: resume init sentinel absent — cannot trust post-resume seed state" "(see $NP_RESUME_OUT)"
  else
    NP_SEED_AFTER=$(msb exec "$NP_NAME" -- cat /home/agent/.claude/.claude.json.seed 2>/dev/null || true)
    if [[ "$NP_SEED_AFTER" == "$V2_SENTINEL" ]]; then
      pass "V2: pre-existing seed sentinel survived a second init run (resume) unchanged"
    else
      fail "V2: pre-existing seed was overwritten by a second init run" "before=$V2_SENTINEL after=$NP_SEED_AFTER"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# V4 / V5: claude-wrapper WARNING behavior. Reuses the NP cage
# (a seed is present after V1/V2). Copies the real, unmodified canonical
# wrapper into the container and stubs only REAL_CLAUDE so exec is harmless.
# ---------------------------------------------------------------------------
if [[ "$NP_LIVE" == "true" ]]; then
  echo ""
  echo "=== V4: claude-wrapper WARNING does not fire when a seed is present ==="
  # msb-port note (rip-cage-neu7.14, Batch E): `docker cp` has no msb
  # equivalent. Routed via `msb exec ... tee <dst> < <src>` (msb exec
  # forwards stdin) instead. Bonus simplification over the docker-cp path:
  # `docker cp` always wrote as root regardless of the container's default
  # user (hence the old `docker exec -u root chown` step below it); `msb
  # exec` with no `-u` runs as the sandbox's own default user, which is
  # already `agent` (verified live: a probe file written this way lands
  # `-rw-r--r-- agent agent`) — so the chown workaround is dropped, not
  # forced-ported.
  if msb exec "$NP_NAME" -- tee /tmp/wrapper-under-test.sh < "$WRAPPER_SRC" >/dev/null 2>&1; then
    msb exec "$NP_NAME" -- sed -i 's#^REAL_CLAUDE=/usr/bin/claude#REAL_CLAUDE=/bin/true#' /tmp/wrapper-under-test.sh
    msb exec "$NP_NAME" -- chmod +x /tmp/wrapper-under-test.sh
    msb exec "$NP_NAME" -- rm -rf /home/agent/.claude-sessions/vwka-v4-test
    V4_OUT=$(msb exec -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/vwka-v4-test "$NP_NAME" -- /tmp/wrapper-under-test.sh --version 2>&1)
    V4_EXIT=$?
    if [[ $V4_EXIT -ne 0 ]]; then
      fail "V4: patched wrapper invocation failed (exit $V4_EXIT)" "$V4_OUT"
    elif echo "$V4_OUT" | grep -q 'no ~/.claude/.claude.json.seed snapshot found'; then
      fail "V4: WARNING fired despite a seed being present" "$V4_OUT"
    else
      pass "V4: no 'no seed snapshot' WARNING when a seed is present"
    fi

    echo ""
    echo "=== V5: genuinely-broken case — WARNING still fires when no seed exists ==="
    msb exec "$NP_NAME" -- sh -c "mv /home/agent/.claude/.claude.json.seed /tmp/seed-moved-aside-vwka.json"
    msb exec "$NP_NAME" -- rm -rf /home/agent/.claude-sessions/vwka-v5-test
    V5_OUT=$(msb exec -e CLAUDE_CONFIG_DIR=/home/agent/.claude-sessions/vwka-v5-test "$NP_NAME" -- /tmp/wrapper-under-test.sh --version 2>&1)
    V5_EXIT=$?
    if [[ $V5_EXIT -ne 0 ]]; then
      fail "V5: patched wrapper invocation failed (exit $V5_EXIT)" "$V5_OUT"
    elif echo "$V5_OUT" | grep -q 'no ~/.claude/.claude.json.seed snapshot found'; then
      pass "V5: WARNING still fires when no seed exists (genuinely-broken case preserved)"
    else
      fail "V5: WARNING did not fire despite no seed existing" "$V5_OUT"
    fi
  else
    fail "V4/V5: msb exec tee of the canonical wrapper into the cage failed"
  fi
fi

# ---------------------------------------------------------------------------
# Setup: mounted-config cage — the host Claude config fixture IS mounted,
# read-only, because the cage config declares it (rip-cage-ely4.7.10). Positive
# control for V3 and the subject of V6/V6b.
# ---------------------------------------------------------------------------
echo ""
echo "=== Setup: cage whose config mounts the host Claude config file ==="
PC_WS_ROOT=$(mktemp -d)
PC_HOME=$(mktemp -d)
PC_WS="${PC_WS_ROOT}/pc-cage"
mkdir -p "$PC_WS"
git -C "$PC_WS" init -q
PC_SENTINEL='{"possession-sentinel-vwka":"abc123","hasCompletedOnboarding":true}'
printf '%s' "$PC_SENTINEL" > "${PC_HOME}/.claude.json"
PC_UP_OUT="${PC_WS_ROOT}/pc-up.out"
# Fixture written FIRST, then the config generated against that HOME: the
# generator carries the mount line only when the file is there to mount.
PC_CONF=$(HOME="$PC_HOME" cage_conf_for "$PC_WS")
HOME="$PC_HOME" DOCKER_CONFIG="$RC_TEST_REAL_DOCKER_CONFIG" MSB_HOME="$REAL_MSB_HOME" \
  RC_SKIP_KEYCHAIN_EXTRACTION=1 \
  ANTHROPIC_API_KEY=sk-test-vwka-pc \
  RC_CAGE_CONF="$PC_CONF" \
  RIP_CAGE_EGRESS=off \
  "$RC" up "$PC_WS" </dev/null >"$PC_UP_OUT" 2>&1 || true
PC_NAME=$(cage_name_for_source "$PC_WS")

PC_LIVE=false
if [[ -z "$PC_NAME" ]]; then
  fail "mounted-config cage did not start (see $PC_UP_OUT)"
else
  _track "$PC_NAME"
  PC_LOG=$(cat "$PC_UP_OUT" 2>/dev/null || true)
  if printf '%s\n' "$PC_LOG" | grep -q '\[rip-cage\] pi '; then
    PC_LIVE=true
    pass "mounted-config cage booted (init sentinel present)"
  else
    fail "mounted-config cage init sentinel absent" "(see $PC_UP_OUT)"
  fi
fi

# ---------------------------------------------------------------------------
# V3 / V6 / V6b: the config-declared mount, end to end (R4 / rip-cage-p1p
# ordering untouched; mount relocated by rip-cage-ely4.7.10).
# ---------------------------------------------------------------------------
if [[ "$PC_LIVE" == "true" ]]; then
  echo ""
  echo "=== V3: init snapshots the mounted host config byte-identical ==="
  PC_SEED=$(msb exec "$PC_NAME" -- cat /home/agent/.claude/.claude.json.seed 2>/dev/null || true)
  if [[ "$PC_SEED" == "$PC_SENTINEL" ]]; then
    pass "V3: seed is byte-identical to the mounted host Claude config fixture"
  else
    fail "V3: seed does not match the mounted host fixture" "expected=$PC_SENTINEL got=$PC_SEED"
  fi

  echo ""
  echo "=== V6: the synthesized fallback does NOT fire when the mount is there ==="
  if echo "$PC_SEED" | grep -q 'theme.*dark'; then
    fail "V6: synthesized minimal fallback fired despite the mount being present" "content: $PC_SEED"
  else
    pass "V6: synthesized minimal fallback (theme:dark sentinel) did NOT fire"
  fi

  echo ""
  echo "=== V6b: the config declared the mount :ro, so in-cage writes fail ==="
  PC_WRITE_OUT=$(msb exec "$PC_NAME" -- sh -c 'echo blocked >> /home/agent/.claude.json' 2>&1)
  PC_WRITE_EXIT=$?
  if [[ $PC_WRITE_EXIT -ne 0 ]] && echo "$PC_WRITE_OUT" | grep -qi 'read-only\|permission denied'; then
    pass "V6b: write to the in-cage Claude config fails (mount is read-only)"
  else
    fail "V6b: write to the in-cage Claude config unexpectedly succeeded" "exit=$PC_WRITE_EXIT out=$PC_WRITE_OUT"
  fi

  echo ""
  echo "=== V6c: msb inspect reports the mount with the mode the config declared ==="
  # msb reports a bind mount's mode as options.readonly, not as a ':ro' suffix
  # on a string (measured, msb 0.6.18 — a mount entry is
  # {"type":"Bind","guest":...,"host":...,"options":{"readonly":true,...}}).
  PC_MOUNT_RO=$(msb inspect "$PC_NAME" --format json 2>/dev/null \
    | jq -r '.config.mounts // [] | map(select(.guest == "/home/agent/.claude.json")) | .[0].options.readonly // empty')
  if [[ -z "$PC_MOUNT_RO" ]]; then
    fail "V6c: msb inspect shows no bind mount at the in-cage Claude config path"
  elif [[ "$PC_MOUNT_RO" == "true" ]]; then
    pass "V6c: msb inspect reports the mount readonly, as the config declared"
  else
    fail "V6c: msb inspect reports the mount writable despite the config's :ro" "readonly=$PC_MOUNT_RO"
  fi
fi

echo ""
echo "=== Summary: $FAILURES failure(s) ==="
exit $FAILURES
