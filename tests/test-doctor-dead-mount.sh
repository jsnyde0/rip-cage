#!/usr/bin/env bash
# Unit tests for rc doctor's generic dead-handle detection over single-file
# Docker bind mounts (rip-cage-uben).
#
# A host atomic-rename (write tmp + rename over — the standard safe-rewrite
# idiom) severs the inode a single-FILE bind mount tracks: `docker inspect`
# keeps listing the mount, but the in-cage destination path goes ENOENT.
# DIRECTORY mounts are immune (the dentry re-resolves) and must be skipped
# with no extra `docker exec` probe (no "stat storm").
#
# DESTINATION-FIRST predicate (rip-cage-uben live-negative-control fix,
# 2026-07-06): the in-cage destination is probed BEFORE looking at the host
# source's type/existence. A healthy destination is reported HEALTHY
# unconditionally, regardless of host source state — a working mount is
# never a fault, even when the host source path is never host-visible at
# all (e.g. the ssh-agent-forwarding socket, materialized only inside the
# container's mount namespace on macOS/OrbStack). Only a DEAD destination
# triggers a look at the host source, to give an honest, differentiated
# diagnosis instead of always claiming atomic-rename.
#
# Tests two pure helpers extracted from rc via the awk-extraction idiom (same
# as test-doctor-version-skew.sh / test-ls-mode-source.sh), with `docker`
# stubbed via a PATH shim (same idiom as test-credential-mounts.sh
# CM8-CM10/CM19-CM21) — host-only, no live cage required:
#   _doctor_dead_file_mounts <name>            — raw enumeration
#   _doctor_format_dead_mounts <name> <src_path> — doctor-probe display string
#
# Coverage:
#   D1  dead handle: mount listed, host source still a regular file, in-cage
#       destination dead -> FAIL line naming the destination path + repair
#       hint ("rc down ... && rc up ...") + the raw helper reports exit 0
#       (probe failures never abort `rc doctor` itself — matches existing
#       convention: cmd_doctor only exits non-zero on container-not-found).
#   D2  healthy single-file mount -> no FAIL false positive (OK line).
#   D3  directory-sourced bind mount -> ignored: no docker exec probe issued
#       against its destination (no stat storm), no false positive.
#   D4  destination dead AND host source genuinely deleted (not renamed) ->
#       distinct wording (WARN prefix + "deleted, not renamed" phrasing
#       asserted directly, not via absence of an "atomic rename"/
#       "atomic-rename" string variant -- that diagnosis requires the host
#       path to still resolve to a regular file).
#   D5  Mounts array with MULTIPLE single-file binds, mixed dead/healthy ->
#       both dead destinations reported (join-logic at rc:6721-6723), the
#       healthy one in the same array is not flagged; same stub also proves
#       the empty-Mounts-array branch ("no single-file bind mounts to check").
#   D6  REGRESSION (live negative-control, ssh-agent socket): host source
#       path does NOT exist at all (not host-visible -- OrbStack magic path),
#       but the in-cage destination IS healthy -> reported HEALTHY only, NOT
#       a WARN/FAIL of any kind. Guards the cry-wolf bug where every healthy
#       macOS cage WARNed forever on the ssh-agent-socket mount.
#   D7  destination dead AND host source exists but is NOT a regular file
#       (a FIFO, standing in for a socket) -> plain WARN wording, distinct
#       from both the atomic-rename FAIL and the "deleted, not renamed" WARN
#       (source here is neither a plain file nor missing -- it exists as a
#       non-regular file).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${SCRIPT_DIR}/../rc"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

DOCTOR_DM_TMP=$(mktemp -d)
trap 'rm -rf "$DOCTOR_DM_TMP"' EXIT

echo "=== test-doctor-dead-mount.sh ==="
echo ""

# ---------------------------------------------------------------------------
# D1: dead handle -- host source still a regular file, in-cage stat fails.
# ---------------------------------------------------------------------------
echo "-- D1: dead handle detected --"

D1_HOST_FILE="${DOCTOR_DM_TMP}/d1-credentials.json"
printf '{"fake":"creds"}' > "$D1_HOST_FILE"
D1_DST="/home/agent/.claude/.credentials.json"

D1_MOUNTS_JSON=$(cat <<JSON
[{"Type":"bind","Source":"${D1_HOST_FILE}","Destination":"${D1_DST}"}]
JSON
)

D1_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dm-d1-stub-XXXXXX")
cat > "${D1_STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"json .Mounts"*) echo '${D1_MOUNTS_JSON}'; exit 0 ;;
  *"test -e ${D1_DST}"*) exit 1 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${D1_STUB_DIR}/docker"

D1_RAW_EXIT=0
D1_RAW=$(PATH="${D1_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_dead_file_mounts 'd1-cage'
") || D1_RAW_EXIT=$?

if [[ "$D1_RAW" == *"DEAD ${D1_DST}"* ]]; then
  pass "D1a raw helper reports DEAD for the severed destination"
else
  fail "D1a raw helper reports DEAD for the severed destination" "got: $D1_RAW"
fi
if [[ "$D1_RAW_EXIT" -eq 0 ]]; then
  pass "D1b raw helper exits 0 even when it finds a dead handle (probe, not abort)"
else
  fail "D1b raw helper exits 0 even when it finds a dead handle" "got exit $D1_RAW_EXIT"
fi

D1_FMT_EXIT=0
D1_FMT=$(PATH="${D1_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  eval \"\$(awk '
    /^_doctor_format_dead_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_format_dead_mounts 'd1-cage' '/some/workspace/path'
") || D1_FMT_EXIT=$?

if [[ "$D1_FMT" == FAIL* ]]; then
  pass "D1c formatted probe starts with FAIL"
else
  fail "D1c formatted probe starts with FAIL" "got: $D1_FMT"
fi
if [[ "$D1_FMT" == *"$D1_DST"* ]]; then
  pass "D1d formatted probe names the dead destination path"
else
  fail "D1d formatted probe names the dead destination path" "got: $D1_FMT"
fi
if [[ "$D1_FMT" == *"rc down"* && "$D1_FMT" == *"rc up"* ]]; then
  pass "D1e formatted probe includes the repair hint (rc down / rc up)"
else
  fail "D1e formatted probe includes the repair hint (rc down / rc up)" "got: $D1_FMT"
fi
if [[ "$D1_FMT_EXIT" -eq 0 ]]; then
  pass "D1f formatter itself exits 0 (matches cmd_doctor's exit-code convention: probe FAIL text, not process abort)"
else
  fail "D1f formatter exits 0" "got exit $D1_FMT_EXIT"
fi
rm -rf "${D1_STUB_DIR}"
rm -f "$D1_HOST_FILE"

# ---------------------------------------------------------------------------
# D2: healthy single-file mount -- host source is a file, in-cage stat OK.
# ---------------------------------------------------------------------------
echo ""
echo "-- D2: healthy single-file mount --"

D2_HOST_FILE="${DOCTOR_DM_TMP}/d2-credentials.json"
printf '{"fake":"creds"}' > "$D2_HOST_FILE"
D2_DST="/home/agent/.claude/.credentials.json"

D2_MOUNTS_JSON=$(cat <<JSON
[{"Type":"bind","Source":"${D2_HOST_FILE}","Destination":"${D2_DST}"}]
JSON
)

D2_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dm-d2-stub-XXXXXX")
cat > "${D2_STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"json .Mounts"*) echo '${D2_MOUNTS_JSON}'; exit 0 ;;
  *"test -e ${D2_DST}"*) exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${D2_STUB_DIR}/docker"

D2_FMT=$(PATH="${D2_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  eval \"\$(awk '
    /^_doctor_format_dead_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_format_dead_mounts 'd2-cage' '/some/workspace/path'
")

if [[ "$D2_FMT" == OK* ]]; then
  pass "D2a healthy mount -> OK, no false-positive FAIL"
else
  fail "D2a healthy mount -> OK" "got: $D2_FMT"
fi
if [[ "$D2_FMT" != *FAIL* ]]; then
  pass "D2b healthy mount output does not contain FAIL anywhere"
else
  fail "D2b healthy mount output does not contain FAIL anywhere" "got: $D2_FMT"
fi
rm -rf "${D2_STUB_DIR}"
rm -f "$D2_HOST_FILE"

# ---------------------------------------------------------------------------
# D3: directory-sourced bind mount is ignored -- no docker exec probe issued
# against it (no stat storm), and it never produces a false positive.
# ---------------------------------------------------------------------------
echo ""
echo "-- D3: directory mount ignored --"

D3_HOST_DIR="${DOCTOR_DM_TMP}/d3-workspace-dir"
mkdir -p "$D3_HOST_DIR"
D3_DST="/workspace"
D3_MARKER="${DOCTOR_DM_TMP}/d3-exec-called-marker"
rm -f "$D3_MARKER"

D3_MOUNTS_JSON=$(cat <<JSON
[{"Type":"bind","Source":"${D3_HOST_DIR}","Destination":"${D3_DST}"}]
JSON
)

D3_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dm-d3-stub-XXXXXX")
cat > "${D3_STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"json .Mounts"*) echo '${D3_MOUNTS_JSON}'; exit 0 ;;
  *"test -e ${D3_DST}"*) touch '${D3_MARKER}'; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${D3_STUB_DIR}/docker"

D3_RAW=$(PATH="${D3_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_dead_file_mounts 'd3-cage'
")

if [[ -f "$D3_MARKER" ]]; then
  fail "D3a directory mount does not trigger a docker exec probe" "marker file was created -- docker exec was called against a directory-sourced mount"
else
  pass "D3a directory mount does not trigger a docker exec probe (no stat storm)"
fi
if [[ "$D3_RAW" != *"$D3_DST"* ]]; then
  pass "D3b directory mount produces no finding at all (silently skipped)"
else
  fail "D3b directory mount produces no finding at all" "got: $D3_RAW"
fi
rm -rf "${D3_STUB_DIR}"

# ---------------------------------------------------------------------------
# D4: host source genuinely deleted (not renamed) -- distinct wording, must
# NOT claim "atomic rename" (that diagnosis requires the host path to still
# resolve to a file; a plain deletion is a different, honest story).
# ---------------------------------------------------------------------------
echo ""
echo "-- D4: host source genuinely deleted --"

D4_HOST_FILE="${DOCTOR_DM_TMP}/d4-does-not-exist.json"
rm -f "$D4_HOST_FILE"   # ensure absent
D4_DST="/home/agent/.claude.json"

D4_MOUNTS_JSON=$(cat <<JSON
[{"Type":"bind","Source":"${D4_HOST_FILE}","Destination":"${D4_DST}"}]
JSON
)

D4_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dm-d4-stub-XXXXXX")
cat > "${D4_STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"json .Mounts"*) echo '${D4_MOUNTS_JSON}'; exit 0 ;;
  *"test -e ${D4_DST}"*) exit 1 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${D4_STUB_DIR}/docker"

D4_FMT=$(PATH="${D4_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  eval \"\$(awk '
    /^_doctor_format_dead_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_format_dead_mounts 'd4-cage' '/some/workspace/path'
")

if [[ "$D4_FMT" == WARN* ]]; then
  pass "D4a deleted-source case reports WARN (not FAIL — distinct severity from the atomic-rename hazard)"
else
  fail "D4a deleted-source case reports WARN" "got: $D4_FMT"
fi
if [[ "$D4_FMT" == *"deleted, not renamed"* ]]; then
  pass "D4a2 deleted-source case names the honest 'deleted, not renamed' story directly (not a hyphen/space string-diff proxy)"
else
  fail "D4a2 deleted-source case names 'deleted, not renamed' directly" "got: $D4_FMT"
fi
if [[ "$D4_FMT" == *"${D4_HOST_FILE}"* || "$D4_FMT" == *"${D4_DST}"* ]]; then
  pass "D4b deleted-source case names the missing path"
else
  fail "D4b deleted-source case names the missing path" "got: $D4_FMT"
fi
rm -rf "${D4_STUB_DIR}"

# ---------------------------------------------------------------------------
# D5: Mounts array with MULTIPLE single-file binds -- two dead, one healthy.
# Covers the join-logic at rc:6721-6723 (dead_list joined "path1, path2") and
# the mixed-array path (a healthy sibling in the SAME array must not be
# flagged). Reuses the same stub for the empty-Mounts-array branch too (swaps
# only the mounts-json fixture file content -- no second stub dir needed).
# ---------------------------------------------------------------------------
echo ""
echo "-- D5: multiple single-file binds, mixed dead/healthy --"

D5_HOST_FILE_1="${DOCTOR_DM_TMP}/d5-dead1.json"
D5_HOST_FILE_2="${DOCTOR_DM_TMP}/d5-dead2.json"
D5_HOST_FILE_3="${DOCTOR_DM_TMP}/d5-healthy.json"
printf '{"fake":"creds1"}' > "$D5_HOST_FILE_1"
printf '{"fake":"creds2"}' > "$D5_HOST_FILE_2"
printf '{"fake":"creds3"}' > "$D5_HOST_FILE_3"

D5_DST_1="/home/agent/.claude/.credentials.json"
D5_DST_2="/home/agent/.claude.json"
D5_DST_3="/home/agent/.pi/agent/auth.json"

D5_MOUNTS_FILE="${DOCTOR_DM_TMP}/d5-mounts.json"
cat > "$D5_MOUNTS_FILE" <<JSON
[{"Type":"bind","Source":"${D5_HOST_FILE_1}","Destination":"${D5_DST_1}"},
 {"Type":"bind","Source":"${D5_HOST_FILE_2}","Destination":"${D5_DST_2}"},
 {"Type":"bind","Source":"${D5_HOST_FILE_3}","Destination":"${D5_DST_3}"}]
JSON

D5_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dm-d5-stub-XXXXXX")
cat > "${D5_STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"json .Mounts"*) cat "${D5_MOUNTS_FILE}"; exit 0 ;;
  *"test -e ${D5_DST_1}"*) exit 1 ;;
  *"test -e ${D5_DST_2}"*) exit 1 ;;
  *"test -e ${D5_DST_3}"*) exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${D5_STUB_DIR}/docker"

D5_RAW=$(PATH="${D5_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_dead_file_mounts 'd5-cage'
")

if [[ "$D5_RAW" == *"DEAD ${D5_DST_1}"* && "$D5_RAW" == *"DEAD ${D5_DST_2}"* ]]; then
  pass "D5a raw helper reports DEAD for BOTH severed destinations in a mixed array"
else
  fail "D5a raw helper reports DEAD for both severed destinations" "got: $D5_RAW"
fi
if [[ "$D5_RAW" == *"HEALTHY ${D5_DST_3}"* ]]; then
  pass "D5b raw helper reports HEALTHY for the third (healthy) destination in the same array"
else
  fail "D5b raw helper reports HEALTHY for the healthy destination" "got: $D5_RAW"
fi

D5_FMT=$(PATH="${D5_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  eval \"\$(awk '
    /^_doctor_format_dead_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_format_dead_mounts 'd5-cage' '/some/workspace/path'
")

if [[ "$D5_FMT" == FAIL* ]]; then
  pass "D5c formatted probe starts with FAIL when any mount in the array is dead"
else
  fail "D5c formatted probe starts with FAIL" "got: $D5_FMT"
fi
if [[ "$D5_FMT" == *"${D5_DST_1}, ${D5_DST_2}"* ]]; then
  pass "D5d formatted probe joins BOTH dead destinations (\"path1, path2\" join logic)"
else
  fail "D5d formatted probe joins both dead destinations" "got: $D5_FMT"
fi
if [[ "$D5_FMT" != *"${D5_DST_3}"* ]]; then
  pass "D5e formatted probe does NOT flag the healthy destination from the same array"
else
  fail "D5e formatted probe does not flag the healthy destination" "got: $D5_FMT"
fi

# D5f: same stub, empty Mounts array -> "no single-file bind mounts to check".
printf '[]' > "$D5_MOUNTS_FILE"

D5_EMPTY_FMT=$(PATH="${D5_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  eval \"\$(awk '
    /^_doctor_format_dead_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_format_dead_mounts 'd5-empty-cage' '/some/workspace/path'
")

if [[ "$D5_EMPTY_FMT" == "OK — no single-file bind mounts to check" ]]; then
  pass "D5f empty Mounts array -> OK, 'no single-file bind mounts to check' branch"
else
  fail "D5f empty Mounts array -> no-mounts-to-check branch" "got: $D5_EMPTY_FMT"
fi

rm -rf "${D5_STUB_DIR}"

# ---------------------------------------------------------------------------
# D6: REGRESSION -- ssh-agent-forwarding socket. Host source path does NOT
# exist at all as a host-visible file (on macOS/OrbStack, the socket is
# materialized only inside the container's mount namespace -- the host stat
# genuinely fails), but the in-cage destination IS healthy. Must be reported
# HEALTHY ONLY -- no WARN, no FAIL, nothing alarming. This is the exact live
# negative-control failure: destination-first must short-circuit to healthy
# BEFORE ever looking at (and WARNing on) the host source's non-existence.
# ---------------------------------------------------------------------------
echo ""
echo "-- D6: ssh-agent-socket regression (missing host source + healthy destination) --"

D6_HOST_SOCK="${DOCTOR_DM_TMP}/does-not-exist/ssh-auth.sock"
# Deliberately do NOT create this path or its parent dir -- the whole point
# is that it is NEVER host-visible (OrbStack materializes it only in-cage).
D6_DST="/run/host-services/ssh-auth.sock"

D6_MOUNTS_JSON=$(cat <<JSON
[{"Type":"bind","Source":"${D6_HOST_SOCK}","Destination":"${D6_DST}"}]
JSON
)

D6_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dm-d6-stub-XXXXXX")
cat > "${D6_STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"json .Mounts"*) echo '${D6_MOUNTS_JSON}'; exit 0 ;;
  *"test -e ${D6_DST}"*) exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${D6_STUB_DIR}/docker"

D6_RAW=$(PATH="${D6_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_dead_file_mounts 'd6-cage'
")

if [[ "$D6_RAW" == "HEALTHY ${D6_DST}" ]]; then
  pass "D6a raw helper reports ONLY 'HEALTHY <dst>' for a missing-host-source + healthy-destination mount (no other line)"
else
  fail "D6a raw helper reports only HEALTHY for the ssh-agent-socket case" "got: $D6_RAW"
fi

D6_FMT=$(PATH="${D6_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  eval \"\$(awk '
    /^_doctor_format_dead_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_format_dead_mounts 'd6-cage' '/some/workspace/path'
")

if [[ "$D6_FMT" == OK* ]]; then
  pass "D6b formatted probe is OK for the ssh-agent-socket case (no cry-wolf WARN on healthy macOS cages)"
else
  fail "D6b formatted probe is OK for the ssh-agent-socket case" "got: $D6_FMT"
fi
if [[ "$D6_FMT" != *WARN* && "$D6_FMT" != *FAIL* ]]; then
  pass "D6c formatted probe contains no WARN or FAIL wording at all"
else
  fail "D6c formatted probe contains no WARN or FAIL wording" "got: $D6_FMT"
fi
rm -rf "${D6_STUB_DIR}"

# ---------------------------------------------------------------------------
# D7: destination dead, host source EXISTS but is NOT a regular file (a FIFO,
# standing in for a socket that IS host-visible, e.g. on native Linux
# Docker). Must get plain wording distinct from both the atomic-rename FAIL
# and the "deleted, not renamed" WARN -- the source here is neither a plain
# file nor genuinely missing.
# ---------------------------------------------------------------------------
echo ""
echo "-- D7: dead destination, non-regular-file host source (FIFO) --"

D7_HOST_FIFO="${DOCTOR_DM_TMP}/d7-some.sock"
mkfifo "$D7_HOST_FIFO"
D7_DST="/run/host-services/ssh-auth.sock"

D7_MOUNTS_JSON=$(cat <<JSON
[{"Type":"bind","Source":"${D7_HOST_FIFO}","Destination":"${D7_DST}"}]
JSON
)

D7_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dm-d7-stub-XXXXXX")
cat > "${D7_STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *"json .Mounts"*) echo '${D7_MOUNTS_JSON}'; exit 0 ;;
  *"test -e ${D7_DST}"*) exit 1 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "${D7_STUB_DIR}/docker"

D7_RAW=$(PATH="${D7_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_dead_file_mounts 'd7-cage'
")

if [[ "$D7_RAW" == *"DEAD_OTHER ${D7_DST}"* ]]; then
  pass "D7a raw helper reports DEAD_OTHER (not plain DEAD) for a dead destination with a non-regular-file source"
else
  fail "D7a raw helper reports DEAD_OTHER for non-regular-file source" "got: $D7_RAW"
fi

D7_FMT=$(PATH="${D7_STUB_DIR}:$PATH" bash -c "
  eval \"\$(awk '
    /^_doctor_dead_file_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  eval \"\$(awk '
    /^_doctor_format_dead_mounts\(\)/ { found=1 }
    found { print }
    found && /^\}\$/ { exit }
  ' '$RC')\"
  _doctor_format_dead_mounts 'd7-cage' '/some/workspace/path'
")

if [[ "$D7_FMT" == WARN* ]]; then
  pass "D7b formatted probe reports WARN (not FAIL) for a dead destination with a non-regular-file source"
else
  fail "D7b formatted probe reports WARN for non-regular-file source" "got: $D7_FMT"
fi
if [[ "$D7_FMT" != *"replaced by atomic rename"* ]]; then
  pass "D7c formatted probe does not CLAIM the atomic-rename diagnosis (a disclaiming mention like 'not the atomic-rename hazard' is fine; attributing the cause to it is not)"
else
  fail "D7c formatted probe does not claim atomic-rename as the cause" "got: $D7_FMT"
fi
if [[ "$D7_FMT" != *"deleted, not renamed"* ]]; then
  pass "D7d formatted probe does not reuse the 'deleted, not renamed' (source-missing) wording -- the source is NOT missing, just non-regular"
else
  fail "D7d formatted probe does not reuse the source-missing wording" "got: $D7_FMT"
fi
if [[ "$D7_FMT" == *"${D7_DST}"* ]]; then
  pass "D7e formatted probe names the dead destination path"
else
  fail "D7e formatted probe names the dead destination path" "got: $D7_FMT"
fi
rm -rf "${D7_STUB_DIR}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== doctor-dead-mount tests: $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
exit 0
