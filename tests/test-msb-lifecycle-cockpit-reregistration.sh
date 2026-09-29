#!/usr/bin/env bash
# tests/test-msb-lifecycle-cockpit-reregistration.sh -- effect-based proof
# for bead rip-cage-rj68 (S6) criterion 3: "After resume, cockpit/herdr
# state is re-registered." Since rip-cage-8jg5.1 it is also the live proof
# of the examples/herdr recipe's boot hooks on the pinned herdr release.
#
# IMAGE UNDER TEST: an image built from examples/herdr/Dockerfile.snippet
# (RC_TEST_IMAGE, default rip-cage:latest). The test drives the herdr the
# image carries and the multiplexers[] entry the snippet merged into the
# image's boot descriptor -- it installs nothing of its own. Build one with:
#   printf 'FROM rip-cage:latest\n' > Dockerfile; cat examples/herdr/Dockerfile.snippet >> Dockerfile
#   (plus boot-fragment.json + scripted-attach.py beside it)
#   RC_IMAGE=<tag> ./rc build --file Dockerfile
#
# What it proves, in order:
#   - in-cage `herdr --version` equals the snippet's pin (a stale cached
#     image fails here, rip-cage-i3wv);
#   - rc's own _up_init_container (the function cli/up.sh's create AND resume
#     paths call) runs init-rip-cage.sh, which runs the descriptor's herdr
#     `start`: server up on the relocated socket, `herdr integration install`
#     succeeds for every agent on PATH, scripted-attach exits clean;
#   - the descriptor's `attach` command attaches a client under a PTY and
#     stays attached (no socket miss: Rust's io::Error debug form
#     'Os { code: 2, kind: NotFound, ... }' or its 'No such file or directory'
#     text — the strings the rip-cage-8jg5.1 round-2 run logged, M5 of its review);
#   - after a graceful stop/start (fresh kernel boot) the old server is gone
#     and a re-run of _up_init_container registers a NEW one.
# NOT exercised: `rc up` end to end (cage config, mounts, secrets) and a
# human at the attached TUI.
#
# NEEDS_MSB + an image carrying herdr + python3 (host-side PTY). Self-skips
# otherwise. The guest gets no network. RC_TEST_MEMORY caps it (default 1G).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
SNIPPET="${REPO_ROOT}/examples/herdr/Dockerfile.snippet"
IMAGE="${RC_TEST_IMAGE:-rip-cage:latest}"
MEMORY="${RC_TEST_MEMORY:-1G}"
SOCK=/tmp/rip-cage-herdr.sock
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }
abort() {
  echo ""
  echo "=== test-msb-lifecycle-cockpit-reregistration.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
}

MSB_BIN="$(command -v msb || true)"
if [[ -z "$MSB_BIN" ]]; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available (needed for the host-side attach PTY) -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

EXPECTED_VERSION=$(sed -n 's#.*releases/download/v\([0-9][0-9.]*\)/herdr-linux.*#\1#p' "$SNIPPET" | head -1)
if [[ -z "$EXPECTED_VERSION" ]]; then
  echo "FAIL: could not read the pinned herdr version from ${SNIPPET}"
  exit 1
fi

NAME="cockpit-reg-$$"
WORK=$(mktemp -d)
ATTACH_PID=""
cleanup() {
  [[ -n "$ATTACH_PID" ]] && kill "$ATTACH_PID" >/dev/null 2>&1
  msb remove --force "$NAME" >/dev/null 2>&1 || true
  rm -f "$WORK"/*
  rmdir "$WORK" 2>/dev/null
}
trap cleanup EXIT

# RC_MULTIPLEXER must be a GUEST env var (init-rip-cage.sh reads
# `${RC_MULTIPLEXER:-none}`); a real `rc up` bakes it at create time via -e.
if ! msb create "$IMAGE" --name "$NAME" --memory "$MEMORY" --net-default deny \
    -e RC_MULTIPLEXER=herdr >/dev/null 2>&1; then
  fail "setup: msb create failed"
  abort
fi

if ! msb exec "$NAME" -- sh -c 'command -v herdr' </dev/null >/dev/null 2>&1; then
  echo "SKIP: ${IMAGE} carries no herdr -- build an image from examples/herdr/Dockerfile.snippet and set RC_TEST_IMAGE -- skipping $(basename "$0")"
  exit 0
fi
VERSION_OUT=$(msb exec "$NAME" -- herdr --version </dev/null 2>&1)
if [[ "$VERSION_OUT" == "herdr ${EXPECTED_VERSION}" ]]; then
  pass "setup: in-cage herdr --version reads '${VERSION_OUT}', the pin in examples/herdr/Dockerfile.snippet"
else
  fail "setup: in-cage herdr is not the snippet's pin v${EXPECTED_VERSION} (stale image? rip-cage-i3wv)" "$VERSION_OUT"
  abort
fi

# server_pid -> pid of the running herdr server, or empty.
server_pid() { msb exec "$NAME" -- pgrep -f 'herdr server' </dev/null 2>/dev/null | head -1; }
# server_running -> "yes" when the server answers on the relocated socket.
server_running() {
  msb exec "$NAME" -- sh -c "HERDR_SOCKET_PATH=${SOCK} herdr status server --json" </dev/null 2>/dev/null \
    | grep -q '"running":true' && echo yes
}

# shellcheck source=/dev/null
source "$RC" 2>/dev/null

echo ""
echo "=== FIRST-BOOT: rc's own _up_init_container runs the descriptor's herdr start hook ==="
_UP_INIT_OK=""
_up_init_container "$NAME" </dev/null >"$WORK/init1.out" 2>&1
if [[ "$_UP_INIT_OK" == "true" ]]; then
  pass "FIRST-BOOT: _up_init_container reports success"
else
  fail "FIRST-BOOT: _up_init_container reported failure" "$(cat "$WORK/init1.out")"
fi
if grep -q "multiplexer=herdr: start command completed" "$WORK/init1.out"; then
  pass "FIRST-BOOT: init-rip-cage.sh's own log confirms the herdr start command ran"
else
  fail "FIRST-BOOT: expected the herdr start-command completion line" "$(cat "$WORK/init1.out")"
fi
# shellcheck disable=SC2016  # expands in the guest shell, on purpose
AGENTS=$(msb exec "$NAME" -- sh -c 'for a in pi claude; do command -v "$a" >/dev/null 2>&1 && echo "$a"; done' </dev/null 2>/dev/null)
if [[ -z "$AGENTS" ]]; then
  fail "FIRST-BOOT: neither pi nor claude is on the image's PATH -- the integration-install leg has nothing to install"
fi
for _agent in $AGENTS; do
  if grep -q "herdr integration installed: ${_agent}" "$WORK/init1.out"; then
    pass "FIRST-BOOT: herdr integration install ${_agent} succeeded"
  else
    fail "FIRST-BOOT: expected 'herdr integration installed: ${_agent}'" "$(grep -i 'integration' "$WORK/init1.out")"
  fi
done
if grep -q "WARNING: herdr" "$WORK/init1.out"; then
  fail "FIRST-BOOT: the start hook logged a herdr WARNING" "$(grep 'WARNING: herdr' "$WORK/init1.out")"
else
  pass "FIRST-BOOT: no herdr WARNING from the start hook (integration installs and scripted-attach exited clean)"
fi
PID1=$(server_pid)
if [[ -n "$PID1" && "$(server_running)" == "yes" ]]; then
  pass "FIRST-BOOT: a real herdr server (pid ${PID1}) answers on the relocated socket ${SOCK}"
else
  fail "FIRST-BOOT: expected a herdr server answering on ${SOCK}" "pid='${PID1}' log: $(msb exec "$NAME" -- cat /tmp/rip-cage-mux-herdr.log </dev/null 2>&1 | tail -5)"
fi

echo ""
echo "=== ATTACH: the descriptor's attach command attaches a client under a PTY ==="
ATTACH_CMD=$(msb exec "$NAME" -- sh -c 'jq -r ".multiplexers[] | select(.name == \"herdr\") | .attach" /etc/rip-cage/boot.json' </dev/null 2>/dev/null)
if [[ -z "$ATTACH_CMD" ]]; then
  fail "ATTACH: could not read the herdr attach command from the image's boot descriptor" \
    "$(msb exec "$NAME" -- ls /etc/rip-cage </dev/null 2>&1)"
else
  cat > "$WORK/attach.py" <<'PYEOF'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time
msb, name, cmd, out_path = sys.argv[1:5]
master_fd, slave_fd = pty.openpty()
fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
proc = subprocess.Popen([msb, "exec", "-t", name, "--", "sh", "-c", cmd],
                        stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, start_new_session=True)
os.close(slave_fd)
buf = b""
deadline = time.time() + 6
while time.time() < deadline:
    r, _, _ = select.select([master_fd], [], [], 0.2)
    if r:
        try:
            buf += os.read(master_fd, 65536)
        except OSError:
            break
alive = proc.poll() is None
open(out_path, "wb").write(buf)
print("alive" if alive else "exited:%s" % proc.returncode)
proc.terminate()
try:
    proc.wait(timeout=5)
except Exception:
    proc.kill()
PYEOF
  ATTACH_STATE=$(python3 "$WORK/attach.py" "$MSB_BIN" "$NAME" "$ATTACH_CMD" "$WORK/attach.out" 2>&1)
  if [[ "$ATTACH_STATE" == "alive" ]] && ! grep -aq "kind: NotFound\|No such file or directory" "$WORK/attach.out" && [[ -s "$WORK/attach.out" ]]; then
    pass "ATTACH: the attach command held a client attached for 6s and drew output ($(wc -c <"$WORK/attach.out" | tr -d ' ') bytes), no socket error"
  else
    fail "ATTACH: expected the attach client to stay attached with no error" "state='${ATTACH_STATE}' output: $(tr -cd '[:print:]\n' <"$WORK/attach.out" | tail -c 400)"
  fi
fi

echo ""
echo "=== RESUME: graceful stop + start (fresh kernel boot) loses the old registration ==="
msb stop "$NAME" >/dev/null 2>&1
msb start "$NAME" >/dev/null 2>&1
PID_GONE=$(server_pid)
if [[ -z "$PID_GONE" ]]; then
  pass "RESUME setup: the pre-resume herdr process is gone after the fresh boot (proves this isn't a no-op restart)"
else
  fail "RESUME setup: expected no herdr process immediately post-resume" "got pid '${PID_GONE}'"
fi

echo ""
echo "=== RE-REGISTER: _up_init_container re-run on resume produces a NEW, real herdr registration ==="
_UP_INIT_OK=""
_up_init_container "$NAME" </dev/null >"$WORK/init2.out" 2>&1
if [[ "$_UP_INIT_OK" == "true" ]]; then
  pass "RE-REGISTER: post-resume _up_init_container reports success"
else
  fail "RE-REGISTER: post-resume _up_init_container reported failure" "$(cat "$WORK/init2.out")"
fi
PID2=$(server_pid)
if [[ -n "$PID2" && "$(server_running)" == "yes" ]]; then
  pass "RE-REGISTER: a real herdr server (pid ${PID2}) answers on ${SOCK} post-resume"
else
  fail "RE-REGISTER: expected a post-resume herdr server answering on ${SOCK}" "pid='${PID2}'"
fi
# A fresh boot restarts pid numbering, so equal pids are possible in
# principle; the RESUME check above (no server before re-init) is what proves
# PID2 is a new process. A differing pid is corroboration, not the proof.
echo "INFO  pid before resume ${PID1:-<none>}, after re-init ${PID2:-<none>}"

echo ""
echo "=== test-msb-lifecycle-cockpit-reregistration.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
