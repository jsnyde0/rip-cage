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
#   empty output for every verb but `msb --version`, so both preflights pass, every cage probe
#   reads absent, and the image reads not-current (its version label comes
#   back empty), which sends rc up down the "Would pull" branch. When CALL_LOG
#   is given, each call is appended to it as "docker <args>" / "msb <args>".
#   Echoes the dir; the caller prepends it to PATH for the rc call (or the
#   whole file) and removes it when done.
#
#   `msb --version` answers "msb $FAKE_MSB_VERSION", read at call time, so a
#   case can put the fake below or above rc's msb floor (rip-cage-mssj). Unset,
#   it answers at the floor, so every other case passes check_msb_floor.
#
#   `msb inspect NAME --format json` prints the file $FAKE_MSB_INSPECT_FILE
#   names when it is set, read at call time (rip-cage-jdl2.3.2); unset, it
#   prints nothing, as before. Point it at JSON carrying status, config.labels
#   and config.mounts[].host to stand up an existing cage. start, stop and
#   create only record; `msb remove` also drops "<file>.removed" beside it,
#   after which inspect prints nothing again (the cage is gone). A case that
#   reuses the file removes the marker first. `msb image list --format json`
#   likewise prints $FAKE_MSB_IMAGE_LIST_FILE when set, so a stopped cage can
#   pass the resume image-drift guard (an image entry whose digest equals the
#   inspect JSON's config.manifest_digest).
#
# A case that needs a specific answer from docker or msb (an image present, a
# drift state) writes its own fixture -- see tests/test-up-dry-run-pure.sh.

fake_runtime_bin() {
  local _log="${1:-/dev/null}" _bin _tool
  _bin=$(mktemp -d "${TMPDIR:-/tmp}/rc-fake-runtime.XXXXXX")
  for _tool in docker msb; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> %q\n' "$_tool" "$_log" > "${_bin}/${_tool}"
    chmod +x "${_bin}/${_tool}"
  done
  # shellcheck disable=SC2016  # expanded by the fake at call time
  printf '[[ "${1:-}" == "--version" ]] && echo "msb ${FAKE_MSB_VERSION:-0.7.4}"\n' >> "${_bin}/msb"
  # shellcheck disable=SC2016  # expanded by the fake at call time
  # `msb remove` marks the inspect file consumed ("<file>.removed"), so after a
  # converge's remove the cage reads absent and the recursive create is reached.
  printf '[[ "${1:-}" == "remove" && -n "${FAKE_MSB_INSPECT_FILE:-}" ]] && : > "${FAKE_MSB_INSPECT_FILE}.removed"\n' >> "${_bin}/msb"
  printf '[[ "${1:-}" == "inspect" && -n "${FAKE_MSB_INSPECT_FILE:-}" && ! -e "${FAKE_MSB_INSPECT_FILE}.removed" ]] && cat "${FAKE_MSB_INSPECT_FILE}"\n' >> "${_bin}/msb"
  # shellcheck disable=SC2016  # expanded by the fake at call time
  printf '[[ "${1:-}" == "image" && "${2:-}" == "list" && -n "${FAKE_MSB_IMAGE_LIST_FILE:-}" ]] && cat "${FAKE_MSB_IMAGE_LIST_FILE}"\n' >> "${_bin}/msb"
  printf 'exit 0\n' >> "${_bin}/docker"
  printf 'exit 0\n' >> "${_bin}/msb"
  printf '%s\n' "$_bin"
}
