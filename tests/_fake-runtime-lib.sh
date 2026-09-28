#!/usr/bin/env bash
# tests/_fake-runtime-lib.sh -- fake `docker` + `msb` for host-tier `rc up`
# calls (rip-cage-47gy).
#
# `rc up` runs check_docker (`docker info`) and check_msb (`msb --version`)
# before cmd_up, and cmd_up reads both image stores before its --dry-run exit.
# A host-tier test that reaches `rc up` with the REAL binaries on PATH depends
# on this host's docker and msb, and on 2026-09-28 such a run rewrote msb's
# rip-cage:latest. A host-tier `rc up` call runs behind these fakes instead.
#
# fake_runtime_bin [CALL_LOG]
#   Create a temp dir holding `docker` and `msb` executables that exit 0 with
#   empty output for every verb, so both preflights pass, every cage probe
#   reads absent, and the image reads not-current (its version label comes
#   back empty), which sends rc up down the "Would pull" branch. When CALL_LOG
#   is given, each call is appended to it as "docker <args>" / "msb <args>".
#   Echoes the dir; the caller prepends it to PATH for the rc call (or the
#   whole file) and removes it when done.
#
# A case that needs a specific answer from docker or msb (an image present, a
# drift state) writes its own fixture -- see tests/test-up-dry-run-pure.sh.

fake_runtime_bin() {
  local _log="${1:-/dev/null}" _bin _tool
  _bin=$(mktemp -d "${TMPDIR:-/tmp}/rc-fake-runtime.XXXXXX")
  for _tool in docker msb; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> %q\nexit 0\n' "$_tool" "$_log" > "${_bin}/${_tool}"
    chmod +x "${_bin}/${_tool}"
  done
  printf '%s\n' "$_bin"
}
