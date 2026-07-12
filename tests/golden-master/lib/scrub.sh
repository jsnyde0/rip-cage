#!/usr/bin/env bash
# tests/golden-master/lib/scrub.sh — determinism scrub for captured rc
# output (rip-cage-9oyh §2). Sourced by capture.sh (which requires GM_ROOT
# and REPO_ROOT from lib/sandbox.sh to already be set) AND by the §3(i) e2e
# test (test-up-run-args-e2e.sh; its former helper-level companion,
# test-up-run-args-full-chain.sh, is RETIRED — rip-cage-5iti, S10), which
# reuses `gm_scrub_root_script` directly for its own per-run mktemp
# TEST_HOME root instead of a bespoke regex.
#
# Scrub classes (mirrors the harness spec §2 table):
#   - Absolute host paths: the fixed GM_ROOT scratch tree AND the repo
#     checkout path (REPO_ROOT — e.g. leaks via `command -v docker` finding
#     the fake-bin shim under the checkout) -> <GM_ROOT> / <REPO_ROOT>.
#     Both the nominal path and its OS-resolved realpath are scrubbed (macOS
#     /tmp -> /private/tmp symlink), AND both are scrubbed in their
#     `tr '/.' '-'`-SLUGIFIED form (`rc up`'s RC_HOST_PROJECT_KEY derivation
#     emits this — a plain path-substring scrub can't catch it, the slashes
#     are already gone). See `gm_scrub_root_script` for the ordering
#     invariant (realpath-before-nominal) this requires.
#   - $SCRIPT_DIR / moved-file CONTENT is intentionally NOT scrubbed here —
#     capture.sh captures file byte-content (e.g. `rc generate-dockerfile`
#     stdout) directly, so there is no raw SCRIPT_DIR path string inside it
#     to begin with. Where a path IS the observable (e.g. `rc setup` naming
#     ~/.zshrc under GM_HOME), the GM_ROOT scrub above still applies — the
#     PLACEHOLDER stays path-identical across the restructure because
#     GM_HOME never moves; only the REPO checkout's internal file layout
#     does.
#   - Timestamps/provenance: live ISO-8601 (`rc manifest reconcile`'s
#     "Reconciled ... on <TS>" comment) and the compact 14-digit backup
#     suffix (`tools.yaml.bak-<TS>`) -> <TS>.
set -u

_gm_sed_escape() {
  # Escape a literal string for safe use inside a sed '|'-delimited pattern.
  printf '%s' "$1" | sed -e 's/[]\/$*.^[]/\\&/g' -e 's/|/\\|/g'
}

# gm_scrub_root_script RAW_ROOT NAME [ALSO_BASENAME] — emit a `sed -E`
# script fragment that scrubs every form of RAW_ROOT into <NAME> /
# <NAME_SLUG>, in this order:
#   1. RAW_ROOT's OS-resolved realpath (if it differs from the raw string)
#   2. that realpath's `tr '/.' '-'`-slugified form
#   3. RAW_ROOT itself (the raw/nominal string)
#   4. RAW_ROOT's slugified form
#   5. (only when ALSO_BASENAME="true") RAW_ROOT's bare `basename` as a
#      STANDALONE token (not path-prefixed)
#
# ORDERING IS LOAD-BEARING for 1-4 (longest/most-specific match first,
# 2026-07-08 adversarial-review Finding 2): on macOS, realpath extends the
# nominal path with a leading /private (a symlink: /tmp -> /private/tmp,
# /var -> /private/var). If the nominal (SHORTER) substitution ran first, it
# would match the INNER substring of a realpath occurrence and rewrite it to
# "/private<NAME>" — corrupting the text so the realpath rule (now looking
# for a string that no longer exists verbatim) never fires. Scrubbing
# realpath FIRST consumes the full/longer occurrence before the nominal rule
# gets a chance to partially match it. This class of bug reproduces
# IDENTICALLY on every run (both rules apply to the same text the same way
# every time) — the under-scrub self-check's two-independent-roots diff is
# structurally blind to it; only a DIFFERENT absolute TMPDIR (a different
# machine/CI runner) surfaces the corruption.
#
# ALSO_BASENAME is OPT-IN, not default, because it is only safe for roots
# whose bare directory name is itself unique (a random mktemp leaf, or
# GM_ROOT's fixed-but-distinctive "rc-golden-master-root"). rc's
# `container_name()` derives cage/volume/mount identifiers from
# `basename(dirname(path))` alone — the full parent PATH is discarded, so a
# plain path-substring scrub (rules 1-4) never reaches that standalone
# token (e.g. a cage named "rc-up-args-e2e-qD7ZEn-workspace" embeds only the
# mktemp leaf dir's bare name, not a `/`-delimited path). Do NOT pass
# ALSO_BASENAME=true for REPO_ROOT: its basename is "rip-cage" or similar —
# a common, high-signal word that appears constantly in real `rc` output
# (image name "rip-cage:latest", container labels, ~/.config/rip-cage/...)
# — scrubbing it as a bare token would swallow real regressions, exactly
# the over-broad-scrub failure mode the mutation-canary self-check guards
# against.
gm_scrub_root_script() {
  local _raw="$1" _name="$2" _also_basename="${3:-false}"
  local _real
  _real=$(cd "$_raw" 2>/dev/null && pwd -P || true)
  local _script=""
  if [[ -n "$_real" && "$_real" != "$_raw" ]]; then
    _script="s|$(_gm_sed_escape "$_real")|<${_name}>|g; "
    _script="${_script}s|$(_gm_sed_escape "$(printf '%s' "$_real" | tr '/.' '-')")|<${_name}_SLUG>|g; "
  fi
  _script="${_script}s|$(_gm_sed_escape "$_raw")|<${_name}>|g; "
  _script="${_script}s|$(_gm_sed_escape "$(printf '%s' "$_raw" | tr '/.' '-')")|<${_name}_SLUG>|g"

  if [[ "$_also_basename" == "true" ]]; then
    local _base_raw _base_real
    _base_raw=$(basename "$_raw")
    _script="${_script}; s|$(_gm_sed_escape "$_base_raw")|<${_name}>|g"
    if [[ -n "$_real" && "$_real" != "$_raw" ]]; then
      _base_real=$(basename "$_real")
      if [[ "$_base_real" != "$_base_raw" ]]; then
        _script="${_script}; s|$(_gm_sed_escape "$_base_real")|<${_name}>|g"
      fi
    fi
  fi

  printf '%s' "$_script"
}

gm_scrub() {
  local _script
  _script="$(gm_scrub_root_script "$GM_ROOT" "GM_ROOT")"
  _script="${_script}; $(gm_scrub_root_script "$REPO_ROOT" "REPO_ROOT")"

  sed -E \
    -e "$_script" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<TS>/g' \
    -e 's/bak-[0-9]{14}/bak-<TS>/g' \
    -e 's/rc-reconcile-tmp\.[0-9]+/rc-reconcile-tmp.<PID>/g' \
    -e 's#/[A-Za-z0-9_./-]*/yq#<YQ_PATH>/yq#g'
}
