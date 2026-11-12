#!/usr/bin/env bash
# share/rip-cage/guest-file-covers.sh -- the IN-GUEST half of the protected-paths
# rule (rip-cage-849o). HOST-SIDE FILE: rc reads it and runs its text inside
# the cage as root, `msb exec -u root <cage> -- bash -c "<this file>" rc-cover
# <guest path>...`, after boot and BEFORE init-rip-cage.sh. It is never baked
# into the image, so an extension Dockerfile cannot replace it, and its target
# list is argv from rc on the host, recomputed at every `rc up` (create and
# resume) -- there is no guest-side copy an agent could edit before it runs.
#
# WHY IT EXISTS. A protected FILE inside a READ-ONLY mount cannot be covered by
# msb: msb must create the bind target in the ro share and agentd dies at boot
# (rip-cage-2wsi; upstream superradcompany/microsandbox#2000). In-guest root can
# do it: `mount --bind -o ro <empty> <file>` needs no write access to the share
# (probe-proven on msb 0.7.8). _protected_paths_enforce names these targets;
# cmd_up runs this script with them. When msb fixes #2000, delete this file and
# the ro branch in _protected_paths_enforce that feeds it.
#
# FAIL CLOSED. Every target must end up covered AND read zero bytes, or this
# exits non-zero naming it; rc then stops the cage before init, so no agent
# runs beside an uncovered file. An absent target fails too -- rc found it on
# the host moments ago, and a cover rc cannot confirm is not a cover.
#
# THE RECORD. On success it writes the covered paths, one per line, to
# /run/rip-cage/file-covers (root-owned, 0444). The floor probe reads that
# record and asserts each listed file still reads empty. Zero targets write an
# empty record, so a stale one from an earlier run never survives.
#
# STRENGTH. Same as every other cover: a visibility default, not a boundary. In-
# guest root (an exploit, or an operator's own sudo rule) can umount it; the
# agent's shipped sudo grant reaches no root (ADR-002 D12). See
# cli/lib/protected_paths.sh's header.
#
# RC_GUEST_COVER_RUN_DIR relocates the record for the host test only; rc never
# sets it.
set -euo pipefail

_dir="${RC_GUEST_COVER_RUN_DIR:-/run/rip-cage}"
mkdir -p "$_dir"
chmod 0755 "$_dir"
_empty="${_dir}/file-cover.empty"
: > "$_empty"
chmod 0444 "$_empty"
_rec="${_dir}/file-covers"
_tmp="${_rec}.tmp.$$"
: > "$_tmp"
trap 'rm -f "$_tmp"' EXIT

_die() {
  echo "[rip-cage] ERROR: could not cover the protected file $1 inside its read-only mount: $2. Stopping before init so no agent runs beside it (ADR-031 D2, fail closed; rip-cage-849o)." >&2
  exit 1
}

for _f in "$@"; do
  if [[ ! -e "$_f" && ! -L "$_f" ]]; then
    _die "$_f" "it does not exist in the cage"
  fi
  if ! _err=$(mount --bind -o ro "$_empty" "$_f" 2>&1); then
    _die "$_f" "mount --bind failed (${_err})"
  fi
  if [[ "$(head -c 1 -- "$_f" 2>/dev/null | wc -c)" -ne 0 ]]; then
    _die "$_f" "the cover was applied but the file still reads content"
  fi
  printf '%s\n' "$_f" >> "$_tmp"
done

chmod 0444 "$_tmp"
mv -f "$_tmp" "$_rec"
echo "[rip-cage] covered $# protected file(s) inside read-only mounts"
