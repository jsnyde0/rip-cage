#!/usr/bin/env bash
# tests/test-dotpi-factory-reach.sh -- host-only tests for the reach wrapper
# examples/dotpi-factory/cage-reach (rip-cage-8jg5.8, rip-cage side of
# dotpi-5nuz).
#
# A fake msb on PATH plays `msb exec <cage> -- <argv...>`: it reads its stdin to
# EOF into a file (so an open stdin both hangs it and shows up as a leak), logs
# its argv, then runs the argv on the host with RC_MULTIPLEXER and
# RC_BOOT_DESCRIPTOR set the way a cage's env carries them, and with the host
# shell's own multiplexer vars unset, as a guest never inherits them. The
# wrapper's guest half therefore runs for real, against a fixture descriptor.
#
#   R1  stdin closed: caller's stdin is an open pipe holding data; the wrapper
#       returns within 5s and the fake saw an empty stdin
#   R2  multiplexer env exported from the descriptor: the herdr recipe's socket
#       path, and a second descriptor's different path (not hardcoded); a
#       computed export (SHELL="$...") is skipped; RC_MULTIPLEXER=none exports
#       nothing
#   R3  argv passed verbatim (spaces, quotes, $, empty arg, glob, a leading -)
#   R4  inner exit status propagated; stdout and stderr stay separate
#   R5  usage refusal without `--`, msb never called
#   R6  static: executable, bash -n clean, names no multiplexer, README states
#       the contract and the reach line, cage-ops cites the wrapper
#
# Positive-sentinel discipline: every failure increments FAILURES.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
REACH="${REPO_ROOT}/examples/dotpi-factory/cage-reach"
README="${REPO_ROOT}/examples/dotpi-factory/README.md"
CAGE_OPS="${REPO_ROOT}/.claude/skills/cage-ops/SKILL.md"
HERDR_BOOT="${REPO_ROOT}/examples/herdr/boot-fragment.json"

FAILURES=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

echo "=== test-dotpi-factory-reach.sh (rip-cage-8jg5.8) ==="

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not on PATH (the guest half reads the descriptor with jq)"
  exit 0
fi

T=$(mktemp -d /private/tmp/rc-reach-XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "${T}/bin"

cat > "${T}/bin/msb" <<'FAKEEOF'
#!/usr/bin/env bash
cat > "${FAKE_DIR}/stdin"
printf '%s\n' "$@" > "${FAKE_DIR}/argv"
[ "$1" = exec ] || exit 99
shift; shift
[ "$1" = -- ] || exit 98
shift
exec env -u HERDR_SOCKET_PATH -u OTHER_VAR -u DECOY_VAR RC_MULTIPLEXER="${FAKE_MUX}" RC_BOOT_DESCRIPTOR="${FAKE_DESC}" "$@"
FAKEEOF
chmod +x "${T}/bin/msb"

# A second descriptor with another socket path and a computed export.
cat > "${T}/other.json" <<'EOF'
{ "multiplexers": [
  { "name": "herdr", "start": "export SHELL=\"$x\"; export OTHER_VAR=1 && export HERDR_SOCKET_PATH=/start/loses.sock; export TICK_VAR=a`b`; export QUOTE_VAR=it's; export SLASH_VAR=a\\b; run", "attach": "export HERDR_SOCKET_PATH=/private/tmp/elsewhere.sock; exec herdr" },
  { "name": "decoy", "start": "export DECOY_VAR=bad; true", "attach": "true" }
] }
EOF

# reach <mux> <descriptor> <argv...>: stdout -> $T/out, stderr -> $T/err, rc -> $rc.
# The caller's stdin is a pipe carrying data; with HOLD_STDIN=1 it stays open
# for 8s. perl alarm bounds the call
# (macOS has no timeout(1)); 142 = SIGALRM.
reach() {
  local mux=$1 desc=$2
  shift 2
  rm -f "${T}/stdin" "${T}/argv"
  # The wrapper takes the cage name first; the tests always pass fake-cage.
  set -- fake-cage -- "$@"
  { echo LEAKED; [ -n "${HOLD_STDIN:-}" ] && sleep 8; } | FAKE_DIR="$T" FAKE_MUX="$mux" FAKE_DESC="$desc" PATH="${T}/bin:${PATH}" \
    perl -e 'alarm 5; exec @ARGV' "$REACH" "$@" > "${T}/out" 2> "${T}/err"
  rc=${PIPESTATUS[1]}
}

# --- R1 stdin closed ----------------------------------------------------------
HOLD_STDIN=1 reach herdr "$HERDR_BOOT" true
if [[ $rc -eq 142 ]]; then
  fail "R1 wrapper returns with an open caller stdin" "hung, killed after 5s"
elif [[ $rc -eq 0 && -f "${T}/stdin" && ! -s "${T}/stdin" ]]; then
  pass "R1 stdin closed: returned promptly, msb saw an empty stdin"
else
  fail "R1 stdin closed" "rc=$rc stdin=$(cat "${T}/stdin" 2>/dev/null)"
fi
rm -f "${T}/argv"
FAKE_DIR="$T" FAKE_MUX=none FAKE_DESC="$HERDR_BOOT" PATH="${T}/bin:${PATH}" "$REACH" my-cage -- true < /dev/null
argv_head=$(head -3 "${T}/argv" | tr '\n' ' ')
if [[ "$argv_head" == "exec my-cage -- " ]]; then
  pass "R1 calls msb exec <cage> -- ..."
else
  fail "R1 calls msb exec <cage> -- ..." "argv head '${argv_head}'"
fi

# --- R2 multiplexer env from the descriptor ------------------------------------
want=$(jq -r '.multiplexers[] | select(.name=="herdr") | .attach' "$HERDR_BOOT" | sed -n 's/.*HERDR_SOCKET_PATH=\([^; ]*\).*/\1/p')
# shellcheck disable=SC2016  # expanded by the inner sh at call time
reach herdr "$HERDR_BOOT" sh -c 'printf %s "${HERDR_SOCKET_PATH-unset}"'
got=$(cat "${T}/out")
if [[ -n "$want" && "$got" == "$want" ]]; then
  pass "R2 exports the herdr recipe's socket path from its descriptor ($want)"
else
  fail "R2 exports the recipe's socket path" "want '$want' got '$got'"
fi
# shellcheck disable=SC2016  # expanded by the inner sh at call time
reach herdr "${T}/other.json" sh -c 'printf "%s|%s|%s|%s|%s|%s|%s" "${HERDR_SOCKET_PATH-unset}" "${OTHER_VAR-unset}" "${SHELL-unset}" "${DECOY_VAR-unset}" "${TICK_VAR-unset}" "${QUOTE_VAR-unset}" "${SLASH_VAR-unset}"'
got=$(cat "${T}/out")
if [[ "$got" == "/private/tmp/elsewhere.sock|1|${SHELL-unset}|unset|unset|unset|unset" ]]; then
  pass "R2 a different descriptor gives its own value; attach beats start for the same name; computed or quoted exports (\$, backtick, quote, backslash) skipped; other multiplexers ignored"
else
  fail "R2 descriptor-driven, not hardcoded" "got '$got'"
fi
# shellcheck disable=SC2016  # expanded by the inner sh at call time
reach none "$HERDR_BOOT" sh -c 'printf %s "${HERDR_SOCKET_PATH-unset}"'
if [[ "$(cat "${T}/out")" == unset && ! -s "${T}/err" ]]; then
  pass "R2 RC_MULTIPLEXER=none exports nothing and says nothing"
else
  fail "R2 no multiplexer" "out '$(cat "${T}/out")' err '$(cat "${T}/err")'"
fi
# shellcheck disable=SC2016  # expanded by the inner sh at call time
reach herdr "${T}/missing.json" sh -c 'printf %s "${HERDR_SOCKET_PATH-unset}"'
if [[ $rc -eq 0 && "$(cat "${T}/out")" == unset ]] && grep -q unreadable "${T}/err"; then
  pass "R2 unreadable descriptor: warns on stderr, still runs the command"
else
  fail "R2 unreadable descriptor" "rc=$rc out '$(cat "${T}/out")' err '$(cat "${T}/err")'"
fi

# --- R3 argv verbatim ---------------------------------------------------------
# shellcheck disable=SC2016  # literal $ args: the test proves they pass through unexpanded
reach herdr "$HERDR_BOOT" printf '[%s]\n' 'a b' "c'd" '$HOME' '' '*' 'x"y' '-n'
# shellcheck disable=SC2016  # same literal args, printed locally as the expected value
expected=$(printf '[%s]\n' 'a b' "c'd" '$HOME' '' '*' 'x"y' '-n')
if [[ "$(cat "${T}/out")" == "$expected" ]]; then
  pass "R3 argv passed verbatim"
else
  fail "R3 argv passed verbatim" "got '$(cat "${T}/out")'"
fi

# argv[0] that looks like an option still runs as the command, never as an
# option of the guest's exec (-a NAME would swallow it; -c would clear the env).
printf '#!/bin/sh\necho "dash-a ran: $*"\n' > "${T}/bin/-a"
chmod +x "${T}/bin/-a"
reach herdr "$HERDR_BOOT" -a hello
if [[ "$(cat "${T}/out")" == "dash-a ran: hello" ]]; then
  pass "R3 an argv[0] starting with - runs as the command"
else
  fail "R3 an argv[0] starting with - runs as the command" "out '$(cat "${T}/out")' rc=$rc"
fi

# --- R4 exit status, stdout/stderr ---------------------------------------------
reach herdr "$HERDR_BOOT" sh -c 'echo to-out; echo to-err >&2; exit 37'
if [[ $rc -eq 37 && "$(cat "${T}/out")" == to-out && "$(cat "${T}/err")" == to-err ]]; then
  pass "R4 exit 37 propagated; stdout and stderr separate"
else
  fail "R4 exit status and streams" "rc=$rc out '$(cat "${T}/out")' err '$(cat "${T}/err")'"
fi

# --- R5 usage -----------------------------------------------------------------
rm -f "${T}/argv"
FAKE_DIR="$T" FAKE_MUX=none FAKE_DESC=x PATH="${T}/bin:${PATH}" "$REACH" my-cage true > /dev/null 2> "${T}/err" < /dev/null
urc=$?
if [[ $urc -eq 2 && ! -f "${T}/argv" ]] && grep -q '^usage: cage-reach <cage> -- <argv...>' "${T}/err"; then
  pass "R5 missing -- refused with usage, msb not called"
else
  fail "R5 usage refusal" "rc=$urc err '$(cat "${T}/err")'"
fi

# --- R6 static ----------------------------------------------------------------
if [[ -x "$REACH" ]] && bash -n "$REACH"; then pass "R6 wrapper executable and bash -n clean"; else fail "R6 wrapper executable and parses" "$REACH"; fi
if grep -v '^#' "$REACH" | grep -qiE 'herdr|tmux|zellij|HERDR_SOCKET'; then
  fail "R6 wrapper code names no multiplexer (ADR-027 D4)" "found one"
else
  pass "R6 wrapper code names no multiplexer (ADR-027 D4)"
fi
if grep -qF 'cage-reach <cage> -- <argv...>' "$README" && grep -qF '["<abs path to cage-reach>", "<cage>", "--"]' "$README"; then
  pass "R6 README states the invocation and the reach line"
else
  fail "R6 README contract" "invocation or reach line missing"
fi
if grep -q 'examples/dotpi-factory/cage-reach' "$CAGE_OPS"; then
  pass "R6 cage-ops cites the wrapper"
else
  fail "R6 cage-ops cites the wrapper" "no examples/dotpi-factory/cage-reach in $CAGE_OPS"
fi

echo ""
echo "TOTAL: $TOTAL  FAILED: $FAILURES"
[[ $FAILURES -eq 0 ]]
