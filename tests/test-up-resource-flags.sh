#!/usr/bin/env bash
set -uo pipefail

# tests/test-up-resource-flags.sh -- host-tier proof for rip-cage-g3ey: the
# cage config's cpus:/memory: reach msb unless the operator overrides them on
# the rc up command line. msb's --cpus/--memory flags beat the --conf file, so
# rc passing a default of its own would silently replace the config's values.
#
#   R1  config cpus: 3 / memory: 6G, bare `rc up --dry-run`: the msb create
#       argv carries NO --cpus/--memory token.
#   R2  `rc up --cpus 4 --memory 8g --dry-run`: exactly --cpus=4 --memory=8g.
#   R3  stopped-cage converge (the resume path): the recreate forwards no
#       --cpus/--memory when none was given, and forwards them when given.
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

T=$(mktemp -d /private/tmp/rc-resource-flags-XXXXXX)
T=$(cd "$T" && pwd -P)
_FAKE_RT=$(fake_runtime_bin)
trap 'rm -rf "$T" "$_FAKE_RT"' EXIT
export PATH="${_FAKE_RT}:${PATH}"

WS="${T}/proj/ws"
mkdir -p "$WS"
CONF=$(cage_conf_for "$WS")
printf 'cpus: 3\nmemory: 6G\n' >> "$CONF"

# The create argv, one token per line, from the dry-run's "Would run" line.
create_argv() {
  RC_CAGE_CONF="$CONF" "$RC" up --dry-run "$@" "$WS" 2>&1 \
    | grep '^Would run: msb create' | head -1 | tr ' ' '\n'
}

echo "=== R1: config values, no flags -> no --cpus/--memory token ==="
R1=$(create_argv)
if [[ -z "$R1" ]]; then
  fail "R1 no 'Would run: msb create' line"
elif grep -qE '^--(cpus|memory|memory-swap|pids-limit)=' <<<"$R1"; then
  fail "R1 argv carries an rc resource default: $(grep -E '^--(cpus|memory)' <<<"$R1" | tr '\n' ' ')"
else
  pass "R1 bare rc up passes no --cpus/--memory; the config's cpus: 3 / memory: 6G apply"
fi

echo "=== R2: --cpus 4 --memory 8g -> exactly those ==="
R2=$(create_argv --cpus 4 --memory 8g | grep -E '^--(cpus|memory)=' | tr '\n' ' ')
if [[ "$R2" == "--cpus=4 --memory=8g " ]]; then
  pass "R2 explicit flags reach msb exactly: ${R2}"
else
  fail "R2 expected '--cpus=4 --memory=8g', got '${R2}'"
fi

echo "=== R3: stopped-cage converge forwards only given flags ==="
# Drive cmd_up to the converge branch with the state reads stubbed, and swap
# cmd_up for a recorder once the old cage is removed, so the recursive call's
# argv is what gets captured, behind a RECREATE marker the log lines never
# print. Run under /bin/bash when it is bash 3.2 (stock macOS, what rc's
# `#!/usr/bin/env bash` meets there): a bare converge leaves the forwarded
# array empty, which `set -u` on 3.2 turns into a crash (ADR-008 D5).
R3_BASH=bash
[[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == 3 ]] && R3_BASH=/bin/bash
converge_args() {
  RC_CAGE_CONF="$CONF" "$R3_BASH" -c '
    source "$1"; shift
    set -euo pipefail   # rc sets this only when executed, not sourced
    _msb_sandbox_state() { echo "exited"; }
    _up_converge_needed() { return 0; }
    _up_resolve_resume_image_drift_stopped() { :; }
    _up_warn_transcript_loss() { :; }
    _msb_stop_graceful() { :; }
    _msb_remove() { cmd_up() { echo RECREATE; printf "%s\n" "$@"; }; }
    cmd_up "$@"
  ' r3 "$RC" "$@" "$WS" 2>/dev/null | sed -n '/^RECREATE$/,$p' | sed 1d
}
echo "(R3 shell: ${R3_BASH})"
R3A=$(converge_args)
R3B=$(converge_args --cpus 4 --memory 8g)
if [[ -z "$R3A" || -z "$R3B" ]]; then
  fail "R3 converge never reached the recreate (bare: '$(tr '\n' ' ' <<<"$R3A")', flagged: '$(tr '\n' ' ' <<<"$R3B")')"
elif grep -qE '^--(cpus|memory|pids-limit)$' <<<"$R3A"; then
  fail "R3a bare converge forwards a resource flag: $(tr '\n' ' ' <<<"$R3A")"
elif [[ "$(tr '\n' ' ' <<<"$R3B")" != *"--cpus 4 --memory 8g "* ]]; then
  fail "R3b explicit flags not forwarded: $(tr '\n' ' ' <<<"$R3B")"
else
  pass "R3 converge forwards no resource flag bare, and --cpus 4 --memory 8g when given"
fi

echo ""
[[ "$FAILURES" -eq 0 ]] && { echo "All tests passed"; exit 0; }
echo "${FAILURES} test(s) failed"; exit 1
