#!/usr/bin/env bash
# tests/_cage-lookup-lib.sh -- find a cage by name, by state, or by the host
# directory it was created from.
#
# WHY THIS EXISTS (rip-cage-ely4.7.3). `rc ls` retired with the six-verb
# thinning (ADR-031 D3). Container-tier suites used it three ways:
#
#   does cage NAME exist            .[] | select(.name==$n)
#   is cage NAME running            .[] | select(.name==$n and .status=="running")
#   which cage came from DIR        .[] | select(.source_path==$ws) | .name
#
# `msb list --format json` is the successor listing, but NOT a drop-in: it
# emits {created_at, image, name, status} and nothing else. Two consequences a
# mechanical swap would get silently wrong:
#
#   * status is Capitalized ("Running" / "Stopped"), so a filter carried over
#     from rc's lowercase vocabulary matches nothing and the assertion passes
#     vacuously -- it reads "no such cage" as "cage not running".
#   * there is NO source_path field. The host directory a cage was created
#     from lives in the `rc.source.path` LABEL, reachable only through a
#     second call, `msb inspect <name> --format json`.
#
# tests/run-host.sh and tests/run-one.sh each already hand-rolled that
# list-then-inspect walk, with a comment on each copy warning about the other.
# This library is the single home for it, so the next suite that needs the
# lookup does not become the third copy.
#
# Usage, from any test:
#   source "${SCRIPT_DIR}/_cage-lookup-lib.sh"
#   name=$(cage_name_for_source "$TEST_WS")   # "" when no cage matches
#   cage_exists "$name"                        # exit 0 / 1
#   cage_is_running "$name"                    # exit 0 / 1
#   for n in $(cage_names_running); do ...; done

# cage_exists <name>
#
# Exit 0 iff msb knows a sandbox by that exact name, whatever its state.
cage_exists() {
  local _n="${1:-}"
  [[ -n "$_n" ]] || return 1
  msb list --format json 2>/dev/null \
    | jq -e --arg n "$_n" '.[] | select(.name == $n)' >/dev/null 2>&1
}

# cage_is_running <name>
#
# Exit 0 iff msb reports that sandbox in a running state. The comparison is
# case-folded on purpose: the state vocabulary is msb's to name, and a suite
# asserting liveness should not go quietly red the day it capitalizes
# differently. Matching the WRONG case fails open here -- it would report a
# live cage as stopped -- so folding is the fail-loud direction.
cage_is_running() {
  local _n="${1:-}"
  [[ -n "$_n" ]] || return 1
  msb list --format json 2>/dev/null \
    | jq -e --arg n "$_n" \
        '.[] | select(.name == $n and (.status | ascii_downcase) == "running")' \
    >/dev/null 2>&1
}

# cage_names_running
#
# Print every running sandbox's name, one per line.
cage_names_running() {
  msb list --format json 2>/dev/null \
    | jq -r '.[] | select((.status | ascii_downcase) == "running") | .name' 2>/dev/null \
    || true
}

# cage_name_for_source <host-dir>
#
# Print the name of the cage created from HOST-DIR, or nothing when none
# matches. First match wins, mirroring the `| head -1` every call site used.
#
# The path is RESOLVED before comparison, the same way rc resolves it when it
# writes the label: on macOS $TMPDIR lives under /var, itself a symlink to
# /private/var, so an unresolved fixture path never equals the stored label.
cage_name_for_source() {
  local _want="${1:-}"
  [[ -n "$_want" ]] || return 0
  _want=$(cd "$_want" 2>/dev/null && pwd -P) || _want="${1}"

  local _n _label
  for _n in $(msb list --format json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true); do
    _label=$(msb inspect "$_n" --format json 2>/dev/null \
      | jq -r '.config.labels["rc.source.path"] // empty' 2>/dev/null || true)
    [[ -z "$_label" ]] && continue
    if [[ "$_label" == "$_want" ]]; then
      printf '%s\n' "$_n"
      return 0
    fi
  done
  return 0
}
