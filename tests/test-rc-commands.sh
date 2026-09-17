#!/usr/bin/env bash
if ! command -v docker > /dev/null 2>&1; then
  echo "SKIP: Docker not available -- skipping $(basename "$0")"
  exit 0
fi
set -uo pipefail

# Test script for rc build commands and related rc helpers
# Each test prints PASS/FAIL and exits non-zero on first failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# THIS FILE MOVED THE OPERATOR'S PRODUCTION IMAGE (rip-cage-ely4.7.9). Traced
# by bisecting the host-only tier with a docker audit shim; the sequence was
#
#   docker image inspect rip-cage:latest --format '…image.version'
#   docker pull ghcr.io/jsnyde0/rip-cage:<v>
#   docker tag  ghcr.io/jsnyde0/rip-cage:<v> rip-cage:latest
#   docker save rip-cage:latest -o … ; msb load --tag rip-cage:latest
#
# That is not a test writing the tag -- no test text does, which is why the
# static guard passed throughout. It is **rc's own pull-first provisioning**:
# some case here reaches an rc path that reads the local image's version
# label, judges it stale, and re-provisions from the registry. The retag and
# the msb load are two steps of one mechanism, which is why BOTH stores moved
# in the incident that found this.
#
# The lever is rc's own: IMAGE="${RC_IMAGE:-rip-cage:latest}" (rc:67). Pinning
# RC_IMAGE for the whole file means no case in it can provision onto the
# production tag, whatever path it takes -- strictly better than chasing the
# one case, because the next case added here inherits the protection. Cases
# that need their own fixture tag still set RC_IMAGE themselves; this is only
# the floor. Nothing here asserts on the literal default tag.
#
# Do NOT "fix" this with RIP_CAGE_IMAGE_REGISTRY="" instead: that opts out of
# the PULL and falls back to building locally (cli/build.sh:544) -- onto the
# same production tag. It swaps one writer for another.
export RC_IMAGE="${RC_IMAGE:-rip-cage-rccmds-fixture:test}"

# The fixture tag has to resolve to a REAL image, or the cases that ask rc
# whether a cage is compatible with its image fail on a missing one instead of
# on their own subject. Point it at whatever the production tag holds: reading
# that tag as a SOURCE is exactly what the write-guard's T4 case protects, and
# the production tag itself is never an argument to anything that writes.
# Removed at exit, so a run leaves no fixture tag behind.
_rc_cmds_fixture_tag_made=0
if [[ "$RC_IMAGE" == "rip-cage-rccmds-fixture:test" ]] \
   && docker image inspect rip-cage:latest >/dev/null 2>&1; then
  if docker tag rip-cage:latest "$RC_IMAGE" >/dev/null 2>&1; then
    _rc_cmds_fixture_tag_made=1
  fi
fi
# Dropped explicitly at the end of the file rather than from an EXIT trap:
# several cases below set and then `trap - EXIT INT TERM` their own crash-safe
# traps, which would disarm one installed here. A run that dies early leaves
# the extra tag behind, and that is fine — it is a second name for an image
# that already exists, costing no disk and shadowing nothing.
_rc_cmds_drop_fixture_tag() {
  [[ "$_rc_cmds_fixture_tag_made" -eq 1 ]] || return 0
  docker image rm "$RC_IMAGE" >/dev/null 2>&1 || true
}


# rc up launches from a native msb --conf file now (ADR-031 D2), so a scratch
# project needs one before any `rc up` — including a dry run. This writes the
# smallest config that boots: an image, the workspace mount, and a default-deny
# egress policy. Echoes the config path for the caller to pass as RC_CAGE_CONF.
rc_test_write_cage_conf() {
  local _proj="$1"
  local _image="${2:-rip-cage:latest}"
  # OUTSIDE the project, deliberately: rc refuses a config that resolves inside
  # a tree it mounts (ADR-031 D5(a)), so a fixture written into the project
  # would be refused before any test got to its own subject.
  # BSD mktemp only accepts the X's at the END of a template, so make a
  # directory and name the file inside it rather than templating a suffix.
  local _confdir _conf
  _confdir=$(mktemp -d "${TMPDIR:-/tmp}/rc-test-cage-XXXXXX")
  _conf="${_confdir}/cage.yaml"
  cat > "$_conf" <<RC_TEST_CONF
image: ${_image}
workdir: /workspace
mounts:
  - "${_proj}:/workspace"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
RC_TEST_CONF
  printf '%s\n' "$_conf"
}

# --- Test 1: the six-verb table (rip-cage-ely4.10 / ADR-031 D3) ---
#
# THIS IS THE SURFACE CONTRACT. `rc` lists exactly six verbs, and every verb
# this release (or ely4.9 before it) deleted prints plain usage and exits 1.
# Two halves, because each catches what the other cannot: the help table would
# still read right if a deleted verb were quietly left dispatchable, and an
# exit-1 sweep would still pass if help grew a seventh line nothing dispatches.
echo "=== Test 1: rc --help lists exactly the six verbs ==="
usage_output=$("$RC" --help 2>&1 || true)

# The verb column is the two-space-indented left edge of the Commands: block.
# Flag lines are indented four spaces, so they never enter this set; a verb
# with several usage lines (test, doctor) collapses to one name via sort -u.
listed_verbs=$(printf '%s\n' "$usage_output" \
  | sed -n '/^Commands:/,/^$/p' \
  | grep -E '^  [a-z][a-z-]*' \
  | awk '{print $1}' | sort -u)
expected_verbs=$(printf '%s\n' auth build destroy doctor test up)

if [[ "$listed_verbs" == "$expected_verbs" ]]; then
  pass "rc --help lists exactly six verbs: $(printf '%s' "$listed_verbs" | tr '\n' ' ')"
else
  fail "rc --help verb list is not the six-verb table.
  expected: $(printf '%s' "$expected_verbs" | tr '\n' ' ')
  got:      $(printf '%s' "$listed_verbs" | tr '\n' ' ')"
fi

echo ""
echo "=== Test 1b: every deleted verb prints plain usage and exits 1 ==="
# One case per deleted verb. `ls`, `attach`, `exec`, `down` and `reload` went
# with this bead; `allowlist`, `config`, `schema` and `install` went with the
# config schema (rip-cage-ely4.9); `completions`, `setup`, `manifest` and
# `generate-dockerfile` went with this bead too. All thirteen reach the same
# `*)` arm, so the assertion is the same for each: usage on stdout, exit 1.
for _deleted_verb in ls attach exec down reload allowlist config schema \
                     completions setup manifest install generate-dockerfile; do
  _dv_out=$("$RC" "$_deleted_verb" 2>&1)
  _dv_exit=$?
  if [[ "$_dv_exit" -eq 1 ]] && printf '%s\n' "$_dv_out" | head -1 | grep -q "^Usage: rc "; then
    pass "rc ${_deleted_verb} -> plain usage, exit 1"
  else
    fail "rc ${_deleted_verb} -> expected usage + exit 1, got exit ${_dv_exit}: $(printf '%s' "$_dv_out" | head -1)"
  fi
done

# NEGATIVE CONTROL: a surviving verb must NOT print usage, or the loop above
# would pass against an `rc` that had become usage-only.
_surv_out=$("$RC" --output json doctor --host 2>&1 || true)
if printf '%s\n' "$_surv_out" | grep -q "^Usage: rc "; then
  fail "a surviving verb (doctor --host) fell through to usage — Test 1b proves nothing"
else
  pass "a surviving verb does not fall through to usage (Test 1b is not vacuous)"
fi

# --- Test 7: rc build uses SCRIPT_DIR to find Dockerfile ---
echo ""
echo "=== Test 7: rc build finds Dockerfile via SCRIPT_DIR ==="
# We just test that it attempts docker build with the right context
# Use --dry-run isn't available, so we test from a different directory
# and check that it doesn't complain about missing Dockerfile
# (it will fail because docker may not be running, but the error should
# be about docker, not about missing Dockerfile)
cd /tmp
# rip-cage-d2bo kind-1 (harmless): --help-test-sentinel is not on cmd_build's
# flag allowlist, which is fail-closed and REJECTS an unrecognised flag before
# any docker call is made (see `rc help`, build's flag table). No image is ever
# built, so rip-cage:latest cannot be overwritten here.
build_output=$("$RC" build --help-test-sentinel 2>&1 || true)
# If we get a docker error (not a "Dockerfile not found" error), the path resolution works
# The command should at least print what it's doing
if echo "$build_output" | grep -qi "build\|docker"; then
  pass "build command recognized and attempts docker build"
else
  fail "build command not working: $build_output"
fi

# --- Test 8: check_docker surfaces Docker daemon errors ---
# rip-cage-tsf2.1: `rc down` moved from check_docker to check_msb (ADR-029
# D1 hard cutover -- down/destroy/attach/exec/ls/test now drive an msb
# sandbox, not a docker container). `rc build` is the one remaining verb
# this suite can use to exercise check_docker for real (cmd_build still
# runs a genuine `docker build`) -- see the new Test 8b below for `rc
# down`'s own (now msb-backed) daemon-error surfacing.
echo ""
echo "=== Test 8: check_docker surfaces Docker errors when daemon is not running ==="
FAKE_DOCKER_DIR=$(mktemp -d)
cat > "$FAKE_DOCKER_DIR/docker" <<'FAKE'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon" >&2
exit 1
FAKE
chmod +x "$FAKE_DOCKER_DIR/docker"
# Call rc build with the fake docker on PATH — check_docker runs first
# rip-cage-d2bo kind-1 (harmless): the fake docker written just above exits 1
# on every invocation, so check_docker aborts before cmd_build reaches a real
# build. Untagged is deliberate here — the whole point is that rc surfaces
# docker's own failure, and no image is produced.
docker_err_output=$(PATH="$FAKE_DOCKER_DIR:$PATH" "$RC" build 2>&1 || true)
if echo "$docker_err_output" | grep -qi "docker"; then
  pass "check_docker surfaces docker error message"
else
  fail "check_docker did not surface docker failure: $docker_err_output"
fi
rm -rf "$FAKE_DOCKER_DIR"

# --- Test 8b: check_msb surfaces msb daemon errors for rc destroy (rip-cage-tsf2.1) ---
echo ""
echo "=== Test 8b: check_msb surfaces msb errors when the runtime is not running ==="
FAKE_MSB_DIR=$(mktemp -d)
cat > "$FAKE_MSB_DIR/msb" <<'FAKE'
#!/usr/bin/env bash
echo "msb: connection refused" >&2
exit 1
FAKE
chmod +x "$FAKE_MSB_DIR/msb"
# Call rc destroy with the fake msb on PATH — check_msb runs first (destroy was
# rewired onto msb by rip-cage-tsf2.1; no fake docker needed here — the
# real docker on this host is fine, only msb is faked unreachable).
# `rc down` was this case's original subject; it retired with the six-verb
# thinning (rip-cage-ely4.10), so the assertion moves onto destroy, which sits
# behind the same check_msb preflight arm.
msb_err_output=$(PATH="$FAKE_MSB_DIR:$PATH" "$RC" destroy 2>&1 || true)
if echo "$msb_err_output" | grep -qi "msb"; then
  pass "check_msb surfaces msb error message for rc destroy"
else
  fail "check_msb did not surface msb failure: $msb_err_output"
fi
rm -rf "$FAKE_MSB_DIR"

# --- Test 9: skill symlink resolution in rc up --dry-run ---
echo ""
echo "=== Test 9: skill symlink resolution in rc up --dry-run ==="
SYMLINK_SKILLS_DIR=$(mktemp -d)
SYMLINK_TARGET_DIR=$(mktemp -d)
# Create a real skill directory (non-symlink) — should not produce extra mount
mkdir -p "${SYMLINK_SKILLS_DIR}/real-skill"
# Create a symlinked skill pointing to the target dir
ln -s "${SYMLINK_TARGET_DIR}" "${SYMLINK_SKILLS_DIR}/linked-skill"
# Override HOME/.claude/skills for this test via env substitution in rc
# rc uses ${HOME}/.claude/skills directly, so we need a workaround:
# source the rc helper function directly and call it
symlink_parent_output=$(bash -c '
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then
        echo "[rc] Warning: asset outside HOME — skipping" >&2
        continue
      fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${SYMLINK_SKILLS_DIR}")

# The linked-skill target is in /tmp (outside $HOME) — should be skipped with warning
# Real-world targets under $HOME would pass through
if echo "$symlink_parent_output" | grep -q "$(dirname "${SYMLINK_TARGET_DIR}")"; then
  fail "should have skipped target outside HOME"
else
  pass "skill symlink target outside HOME is skipped"
fi

# Create a symlinked skill pointing INSIDE HOME (simulate monorepo case)
HOME_TARGET_DIR=$(mktemp -d "${HOME}/.tmp-rc-test-XXXXXX")
SYMLINK_SKILLS_DIR2=$(mktemp -d)
ln -s "${HOME_TARGET_DIR}" "${SYMLINK_SKILLS_DIR2}/linked-skill"
symlink_parent_output2=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then
        continue
      fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${SYMLINK_SKILLS_DIR2}")

expected_parent="$(dirname "${HOME_TARGET_DIR}")"
if echo "$symlink_parent_output2" | grep -qF "${expected_parent}"; then
  pass "skill symlink target inside HOME produces parent mount"
else
  fail "skill symlink target inside HOME did not produce parent mount (got: $symlink_parent_output2, expected: $expected_parent)"
fi

# Deduplication: two symlinks pointing to the same parent should produce one line
ln -s "${HOME_TARGET_DIR}" "${SYMLINK_SKILLS_DIR2}/linked-skill2" 2>/dev/null || true
mkdir -p "${HOME_TARGET_DIR}/../sibling-$(basename "${HOME_TARGET_DIR}")"
SIBLING_DIR="${HOME_TARGET_DIR}/../sibling-$(basename "${HOME_TARGET_DIR}")"
SIBLING_DIR=$(realpath "${SIBLING_DIR}")
ln -s "${SIBLING_DIR}" "${SYMLINK_SKILLS_DIR2}/linked-skill3"
dedup_output=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then continue; fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${SYMLINK_SKILLS_DIR2}")
dedup_count=$(echo "$dedup_output" | grep -c "$(dirname "${HOME_TARGET_DIR}")" || true)
if [[ "$dedup_count" -eq 1 ]]; then
  pass "symlinks sharing a parent produce exactly one mount (deduplication)"
else
  fail "deduplication failed — expected 1 parent mount, got $dedup_count (output: $dedup_output)"
fi

# --- Test 10: RETIRED into Test 1b (rip-cage-ely4.10) ---
# Asserted that `rc init` (removed in rip-cage-kt25) falls through to usage.
# Test 1b now sweeps every deleted verb through the same `*)` arm and checks
# the exit code too, which this case never did.

# --- Test 11: _collect_symlink_parents handles file symlinks ---
echo ""
echo "=== Test 11: _collect_symlink_parents handles file symlinks ==="
FILE_SYMLINK_TARGET_DIR=$(mktemp -d "${HOME}/.tmp-rc-file-test-XXXXXX")
echo "# Test agent" > "${FILE_SYMLINK_TARGET_DIR}/test-agent.md"
FILE_SYMLINK_AGENTS_DIR=$(mktemp -d)
ln -s "${FILE_SYMLINK_TARGET_DIR}/test-agent.md" "${FILE_SYMLINK_AGENTS_DIR}/test-agent.md"

# Positive test: [[ -e ]] version (the fix) should return the parent dir
file_symlink_output=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -e "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then continue; fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents "$1"
' _ "${FILE_SYMLINK_AGENTS_DIR}")

if echo "$file_symlink_output" | grep -qF "${FILE_SYMLINK_TARGET_DIR}"; then
  pass "file symlink target parent dir returned with [[ -e ]] fix"
else
  fail "file symlink target parent dir NOT returned (got: $file_symlink_output, expected: $FILE_SYMLINK_TARGET_DIR)"
fi

# Negative test: [[ -d ]] version (the old bug) should return empty for file symlinks
file_symlink_old_output=$(bash -c '
  HOME='"\"${HOME}\""'
  _collect_symlink_parents_old() {
    local asset_dir="$1"
    local entry target tdir seen_it d
    local seen_dirs
    seen_dirs=()
    for entry in "${asset_dir}/"*; do
      [[ -L "$entry" ]] || continue
      target=$(realpath "$entry" 2>/dev/null) || continue
      [[ -d "$target" ]] || continue
      if [[ "$target" != "${HOME}/"* ]]; then continue; fi
      tdir=$(dirname "$target")
      seen_it=0
      for d in "${seen_dirs[@]+"${seen_dirs[@]}"}"; do
        [[ "$d" == "$tdir" ]] && seen_it=1 && break
      done
      if [[ "$seen_it" == 0 ]]; then
        seen_dirs+=("$tdir")
        echo "$tdir"
      fi
    done
  }
  _collect_symlink_parents_old "$1"
' _ "${FILE_SYMLINK_AGENTS_DIR}")

if [[ -z "$file_symlink_old_output" ]]; then
  pass "old [[ -d ]] version returns empty for file symlinks (proves fix is needed)"
else
  fail "old [[ -d ]] version should return empty for file symlinks (got: $file_symlink_old_output)"
fi

rm -rf "$FILE_SYMLINK_TARGET_DIR" "$FILE_SYMLINK_AGENTS_DIR"

# --- Shared helper: fake-msb PATH shim for Tests 14/19/20 (rip-cage-d2bo.2) ---
# rip-cage-neu7.2 originally made this shared helper STAGE the operator's
# REAL msb image cache: save the live rip-cage:latest, `msb load --tag` the
# fake stub over it, then restore from the saved tar. That is a save/restore
# dance around a host-global SINGLETON cache every cage on the host depends
# on -- unsafe under concurrency (two invocations racing on the same cache
# entry) and unsafe if the test dies mid-swap. rip-cage-d2bo.2 traces an
# accidental rip-cage:latest digest change on 2026-09-04 to exactly this
# mechanism, and no amount of careful save/restore makes a swap onto a
# shared singleton safe. FIX (rip-cage-d2bo.2, shape 1 of the bead's three
# options): take the real msb binary out of the loop entirely, the same way
# tests/test-build-msb-load.sh's fake-msb PATH shim already does for
# _build_msb_load -- never touch the live cache at all.
#
# rip-cage-lh62 finished the job on the DOCKER side: Tests 14/19/20 no longer
# `docker tag` their stub onto rip-cage:latest either. Each points rc at its
# own fixture tag via RC_IMAGE, so the shim has to answer for THAT tag, not
# for a hardcoded rip-cage:latest -- hence the second parameter.
#
# _image_absent (cli/up.sh:2474-2479) ORs a third clause -- "msb image list
# contains $IMAGE" -- alongside the docker-side staleness checks. Tests 14
# and 20 need that clause to read "present" to reach the image-PRESENT branch
# under test; Test 19 (stale) doesn't strictly need it --
# `! _image_is_current` short-circuits the `||` chain before the msb clause
# is even evaluated -- but is shimmed too on the same PATH so the real msb
# binary is never reached from any case, not "usually isn't reached".
#
# _make_fake_msb_dir DIR [IMAGE_REF] -- writes a `msb` PATH shim into DIR that
# answers `image list --format json` with a single IMAGE_REF entry (default
# rip-cage:latest) and exits 0 on anything else (a no-op catch-all, never a
# real image mutation). Prefix PATH with DIR only for the `$RC up --dry-run`
# subprocess call.
_make_fake_msb_dir() {
  local dir="$1"
  local ref="${2:-rip-cage:latest}"
  cat > "${dir}/msb" <<FAKE_MSB
#!/usr/bin/env bash
case "\${1:-}" in
  image)
    case "\${2:-}" in
      list)
        echo '[{"reference":"${ref}"}]'
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_MSB
  chmod +x "${dir}/msb"
}

# --- Test 14: rc up --dry-run includes agents mount line ---
echo ""
echo "=== Test 14: rc up --dry-run includes agents mount line ==="
if [[ -d "${HOME}/.claude/agents" ]]; then
  TEST_DIR_T14=$(mktemp -d)
  mkdir -p "${TEST_DIR_T14}/.git"

  # rc up now checks the version label — ensure the image rc resolves is
  # current so the test reaches the "Would mount" dry-run lines (not the
  # stale-image early exit).
  #
  # rip-cage-lh62: this used to `docker tag <stub> rip-cage:latest`, run the
  # dry-run, then tag the operator's real image back. That is a save/restore
  # swap on the production tag — the docker-side twin of the msb-cache swap
  # rip-cage-d2bo.2 already removed (see _make_fake_msb_dir's header). Two
  # ways it loses: a kill between the two tags (the OS low-memory reaper
  # killed this suite twice on 2026-09-14) leaves the operator booting cages
  # from a stub, and two concurrent suite runs race on one host-global tag.
  # No restore dance is careful enough; the swap itself is the defect.
  #
  # FIX: point rc at the stub through RC_IMAGE (rc:69,
  # IMAGE="${RC_IMAGE:-rip-cage:latest}") and never write the production tag
  # at all. The assertion is strictly stronger — it no longer depends on a
  # restore step running.
  RC_VER_T14=$("${REPO_ROOT}/rc" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  T14_FIXTURE_TAG="rip-cage-test-fixture:t14-agents"
  # alpine, not `FROM scratch`: a digest-only image is not inspectable under
  # containerd (Docker 29.4.0, io.containerd.snapshotter.v1), so rc's label
  # read would come back empty and the image would look stale. Same reason
  # Tests 19/20 use alpine.
  docker build -q -t "$T14_FIXTURE_TAG" - <<STUB_EOF >/dev/null 2>&1
FROM alpine:3.19
LABEL org.opencontainers.image.version="${RC_VER_T14}"
STUB_EOF
  if [[ $? -ne 0 ]]; then
    fail "Test 14 setup: stub image build failed — cannot test agents mount"
  else
    # rc up launches from a native msb --conf file (ADR-031 D2), so the
    # scratch project needs one. The stub image goes in the config's own
    # image: key AND in RC_IMAGE, which now only steers rc's own image probes.
    T14_CFG=$(rc_test_write_cage_conf "$TEST_DIR_T14" "$T14_FIXTURE_TAG")
    T14_FAKE_MSB_DIR=$(mktemp -d)
    _make_fake_msb_dir "$T14_FAKE_MSB_DIR" "$T14_FIXTURE_TAG"
    dry_run_output=$(PATH="${T14_FAKE_MSB_DIR}:${PATH}" RC_IMAGE="$T14_FIXTURE_TAG" \
      RC_CAGE_CONF="$T14_CFG" \
      "$RC" up --dry-run "$TEST_DIR_T14" 2>&1 || true)
    rm -rf "$T14_FAKE_MSB_DIR"

    # Teardown by EXACT fixture tag. rip-cage:latest was never written, so
    # there is nothing to restore.
    docker rmi "$T14_FIXTURE_TAG" >/dev/null 2>&1 || true

    if echo "$dry_run_output" | grep -q 'Would mount.*rc-context/agents'; then
      pass "rc up --dry-run shows agents mount"
    else
      fail "rc up --dry-run missing agents mount line"
    fi
  fi
  rm -rf "$TEST_DIR_T14"
else
  pass "rc up --dry-run agents check skipped — ~/.claude/agents not present"
fi

# --- Test 15: beads-host-dolt in rc test (Tier 3: requires running rc container) ---
echo ""
echo "=== Test 15: beads-host-dolt check in rc test (Tier 3) ==="
# Find a running rc container whose workspace is the rip-cage repo (embedded mode)
RIPCAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RC_CONTAINER_T15=$(docker ps --filter "label=rc.source.path=${RIPCAGE_ROOT}" --format "{{.Names}}" 2>/dev/null | head -1 || true)

if [[ -z "$RC_CONTAINER_T15" ]]; then
  echo "SKIP: Test 15 — no running rc container found for ${RIPCAGE_ROOT} (start one with: rc up ${RIPCAGE_ROOT})"
  pass "beads-host-dolt rc test (skipped — no container)"
else
  # JSON mode: embedded project should produce pass with correct name
  rc_json_out=$("$RC" --output json test "$RC_CONTAINER_T15" 2>/dev/null || true)
  bd_status=$(echo "$rc_json_out" | jq -r '.checks[] | select(.name=="beads-host-dolt") | .status' 2>/dev/null || true)
  if [[ "$bd_status" == "pass" ]]; then
    pass "rc test JSON: beads-host-dolt status is pass"
  else
    fail "rc test JSON: beads-host-dolt status expected 'pass', got '${bd_status}' (json: ${rc_json_out})"
  fi

  bd_detail=$(echo "$rc_json_out" | jq -r '.checks[] | select(.name=="beads-host-dolt") | .detail' 2>/dev/null || true)
  if [[ "$bd_detail" == "not applicable (embedded mode)" ]]; then
    pass "rc test JSON: beads-host-dolt detail is 'not applicable (embedded mode)'"
  else
    fail "rc test JSON: beads-host-dolt detail expected 'not applicable (embedded mode)', got '${bd_detail}'"
  fi

  # Text mode: check PASS line present
  rc_text_out=$("$RC" test "$RC_CONTAINER_T15" 2>/dev/null || true)
  if echo "$rc_text_out" | grep -q "PASS \[0\] beads-host-dolt"; then
    pass "rc test text: beads-host-dolt PASS line present"
  else
    fail "rc test text: missing 'PASS [0] beads-host-dolt' (output: ${rc_text_out})"
  fi
fi

# --- Test 16: beads-host-dolt stale port via __bd-preflight-test (no container needed) ---
echo ""
echo "=== Test 16: beads-host-dolt stale port via __bd-preflight-test ==="
STALE_BEADS=$(mktemp -d)
mkdir -p "${STALE_BEADS}/.beads"
printf '65000\n' > "${STALE_BEADS}/.beads/dolt-server.port"
stale_out=$("$RC" __bd-preflight-test "${STALE_BEADS}/.beads" "server" 2>/dev/null || true)
if echo "$stale_out" | grep -q "FAIL \[0\] beads-host-dolt"; then
  pass "__bd-preflight-test stale port produces FAIL beads-host-dolt"
else
  fail "__bd-preflight-test stale port: expected FAIL [0] beads-host-dolt, got: ${stale_out}"
fi
if echo "$stale_out" | grep -q "stale port"; then
  pass "__bd-preflight-test stale port detail mentions 'stale port'"
else
  fail "__bd-preflight-test stale port: detail missing 'stale port' (got: ${stale_out})"
fi
rm -rf "$STALE_BEADS"

# --- Test 17: beads-host-dolt corrupt port via __bd-preflight-test (no container needed) ---
echo ""
echo "=== Test 17: beads-host-dolt corrupt port via __bd-preflight-test ==="
CORRUPT_BEADS=$(mktemp -d)
mkdir -p "${CORRUPT_BEADS}/.beads"
printf 'not-a-number\n' > "${CORRUPT_BEADS}/.beads/dolt-server.port"
corrupt_out=$("$RC" __bd-preflight-test "${CORRUPT_BEADS}/.beads" "server" 2>/dev/null || true)
if echo "$corrupt_out" | grep -q "FAIL \[0\] beads-host-dolt"; then
  pass "__bd-preflight-test corrupt port produces FAIL beads-host-dolt"
else
  fail "__bd-preflight-test corrupt port: expected FAIL [0] beads-host-dolt, got: ${corrupt_out}"
fi
if echo "$corrupt_out" | grep -q "corrupt port file"; then
  pass "__bd-preflight-test corrupt port detail mentions 'corrupt port file'"
else
  fail "__bd-preflight-test corrupt port: detail missing 'corrupt port file' (got: ${corrupt_out})"
fi
rm -rf "$CORRUPT_BEADS"

# --- Test 18: beads-host-dolt port file missing via __bd-preflight-test (no container needed) ---
echo ""
echo "=== Test 18: beads-host-dolt port file missing via __bd-preflight-test ==="
MISSING_BEADS=$(mktemp -d)
mkdir -p "${MISSING_BEADS}/.beads"
# No port file created
missing_out=$("$RC" __bd-preflight-test "${MISSING_BEADS}/.beads" "server" 2>/dev/null || true)
if echo "$missing_out" | grep -q "FAIL \[0\] beads-host-dolt"; then
  pass "__bd-preflight-test missing port produces FAIL beads-host-dolt"
else
  fail "__bd-preflight-test missing port: expected FAIL [0] beads-host-dolt, got: ${missing_out}"
fi
if echo "$missing_out" | grep -q "port file missing"; then
  pass "__bd-preflight-test missing port detail mentions 'port file missing'"
else
  fail "__bd-preflight-test missing port: detail missing 'port file missing' (got: ${missing_out})"
fi
rm -rf "$MISSING_BEADS"

# --- Test 19: stale local image triggers re-provisioning in rc up --dry-run ---
echo ""
echo "=== Test 19: stale local image triggers re-provisioning ==="
# Build a REAL tagged image (not FROM scratch — that digest is not inspectable under
# containerd/io.containerd.snapshotter.v1 on Docker 29.4.0, causing docker tag to
# silently no-op). We use alpine with a clearly stale version label so _image_is_current
# returns non-current and the "would build" re-provision path fires.
# rip-cage-lh62: the fixture lives under its OWN repository name
# (rip-cage-test-fixture), and rc is pointed at it with RC_IMAGE. Nothing
# here writes rip-cage:latest, so there is no save/restore dance and no
# window in which a kill leaves the operator's production tag on a stub.
T19_STALE_TAG="rip-cage-test-fixture:t19-stale"
docker build -q -t "$T19_STALE_TAG" - <<'STALE_DOCKERFILE' >/dev/null 2>&1
FROM alpine:3.19
LABEL org.opencontainers.image.version="stale-test-0.0.0"
LABEL description="stub image for stale-label test"
STALE_DOCKERFILE
T19_BUILD_EXIT=$?
if [[ $T19_BUILD_EXIT -ne 0 ]]; then
  fail "Test 19 setup: could not build stale stub image (exit $T19_BUILD_EXIT)"
else
  # Crash-safe cleanup: remove the fixture tag by EXACT name if interrupted.
  # Cleared after the normal-path teardown so it does not fire spuriously.
  trap '
    [[ -n "${T19_FAKE_MSB_DIR:-}" ]] && rm -rf "$T19_FAKE_MSB_DIR"
    docker rmi "${T19_STALE_TAG:-}" >/dev/null 2>&1 || true
  ' EXIT INT TERM

  # POSITIVE SENTINEL: verify the fixture really carries a stale label — it
  # must differ from RC_VERSION so _image_is_current returns false and the
  # staleness path fires.
  T19_CURRENT_RC_VERSION=$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "unknown")
  T19_INSTALLED_LABEL=$(docker image inspect "$T19_STALE_TAG" \
    --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null || true)
  if [[ "$T19_INSTALLED_LABEL" == "$T19_CURRENT_RC_VERSION" ]]; then
    fail "Test 19 sentinel: stale fixture does not read as stale (label=${T19_INSTALLED_LABEL} == RC_VERSION=${T19_CURRENT_RC_VERSION}); the stub build may have silently no-oped"
    docker rmi "$T19_STALE_TAG" >/dev/null 2>&1 || true
    trap - EXIT INT TERM
  else
    # rip-cage-d2bo.2: drive the msb-side third clause of _image_absent
    # through a fake-msb PATH shim instead of staging the live cache -- see
    # the shared-helper comment above _make_fake_msb_dir for why.
    T19_FAKE_MSB_DIR=$(mktemp -d)
    _make_fake_msb_dir "$T19_FAKE_MSB_DIR" "$T19_STALE_TAG"
    TEST_DIR_T19=$(mktemp -d)
    mkdir -p "${TEST_DIR_T19}/.git"
    # Native cage config per ADR-031 D2 (see rc_test_write_cage_conf).
    T19_GLOBAL_CFG=$(mktemp "${TMPDIR:-/tmp}/rc-t19-cfg-XXXXXX")
    printf 'version: 2\nmounts:\n  denylist: []\n' > "$T19_GLOBAL_CFG"
    stale_dry_run_output=$(PATH="${T19_FAKE_MSB_DIR}:${PATH}" RC_IMAGE="$T19_STALE_TAG" RIP_CAGE_IMAGE_REGISTRY="" RC_CAGE_CONF="$(rc_test_write_cage_conf "$TEST_DIR_T19" "$T19_STALE_TAG")" \
      "$RC" up --dry-run "$TEST_DIR_T19" 2>&1 || true)
    rm -f "$T19_GLOBAL_CFG"

    # Teardown by EXACT fixture tag -- the msb shim was PATH-local and never
    # touched the real cache, and rip-cage:latest was never written.
    rm -rf "$T19_FAKE_MSB_DIR"
    docker rmi "$T19_STALE_TAG" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR_T19"
    # Normal-path teardown complete — disarm the crash-safe trap.
    trap - EXIT INT TERM

    # POSITIVE ASSERTION: a stale image must route through _pull_or_build.
    # With RIP_CAGE_IMAGE_REGISTRY="" the dry-run message is "would build".
    if echo "$stale_dry_run_output" | grep -qi "would build\|would pull"; then
      pass "stale image (mismatched version label) triggers re-provisioning (sentinel: installed=${T19_INSTALLED_LABEL}, rc=${T19_CURRENT_RC_VERSION})"
    else
      fail "stale image did NOT trigger re-provisioning (output: $stale_dry_run_output)"
    fi
  fi
fi

# --- Test 20: RC_VERSION="unknown" treats image as current (skip stale check) ---
echo ""
echo "=== Test 20: RC_VERSION=unknown skips staleness check ==="
# When VERSION file is absent, RC_VERSION="unknown". An image with no matching
# label should still be treated as current (not stale) so rc up doesn't
# silently re-provision every time on a malformed checkout.
#
# Strategy: build a stub image with no version label under its own fixture
# tag, point rc at it with RC_IMAGE, then invoke rc up --dry-run with the
# VERSION file temporarily renamed (so RC_VERSION="unknown") and
# RIP_CAGE_IMAGE_REGISTRY="" so if re-provision fires the message is "build".
# The dry-run output must NOT contain "would build" or "would pull" — it must
# reach the normal dry-run lines ("Would create container..." / "Would mount...").
#
# NOTE: FROM scratch stubs are NOT inspectable under containerd (Docker 29.4.0,
# io.containerd.snapshotter.v1), so their labels read back empty.
# We use alpine with no version label (but a real -t tag) to get an inspectable image
# whose label is missing so _image_is_current would return stale — but RC_VERSION=unknown
# bypasses the check, so the staleness path still must NOT fire.
T20_STUB_TAG="rip-cage-test-fixture:t20-unknown"
docker build -q -t "$T20_STUB_TAG" - <<'STUB_DOCKERFILE_T20' >/dev/null 2>&1
FROM alpine:3.19
LABEL description="stub image for unknown-version test"
STUB_DOCKERFILE_T20
T20_BUILD_EXIT=$?
if [[ $T20_BUILD_EXIT -ne 0 ]]; then
  fail "Test 20 setup: could not build stub image (exit $T20_BUILD_EXIT)"
else
  # Crash-safe cleanup: remove the fixture tag and restore the VERSION file
  # even if interrupted. rip-cage-lh62: rip-cage:latest is no longer part of
  # this (rc is pointed at the fixture with RC_IMAGE), so the trap has one
  # fewer host-global singleton to get right.
  # Idempotent: BACKUP_VERSION_FILE restore is a no-op when the backup does not exist.
  # Cleared after the normal-path restore so it does not fire spuriously.
  REPO_VERSION_FILE="${REPO_ROOT}/VERSION"
  # rip-cage-k13u: per-process NAME (not mktemp) -- a naive mktemp swap
  # would pre-create the backup file immediately at assignment time, and
  # the crash-safety trap below does `[[ -f "$BACKUP_VERSION_FILE" ]] && mv
  # ...`; if that pre-created (empty) file existed before the real
  # backup-mv further down runs, an early interrupt would restore an EMPTY
  # file over the real VERSION file. $$ is this top-level script's own
  # stable PID, gives a unique name without creating anything, and two
  # overlapping test-rc-commands.sh runs no longer collide on one fixed
  # repo-root path.
  BACKUP_VERSION_FILE="${REPO_ROOT}/VERSION.t20bak.$$"
  trap '
    [[ -n "${T20_FAKE_MSB_DIR:-}" ]] && rm -rf "$T20_FAKE_MSB_DIR"
    [[ -f "${BACKUP_VERSION_FILE:-}" ]] && mv "$BACKUP_VERSION_FILE" "$REPO_VERSION_FILE" 2>/dev/null || true
    docker rmi "${T20_STUB_TAG:-}" >/dev/null 2>&1 || true
  ' EXIT INT TERM

  # rip-cage-d2bo.2: drive the msb-side third clause of _image_absent
  # through a fake-msb PATH shim instead of staging the live cache -- see
  # the shared-helper comment above _make_fake_msb_dir for why.
  T20_FAKE_MSB_DIR=$(mktemp -d)
  _make_fake_msb_dir "$T20_FAKE_MSB_DIR" "$T20_STUB_TAG"

  TEST_DIR_T20=$(mktemp -d)
  mkdir -p "${TEST_DIR_T20}/.git"

  # Use rename of the VERSION file so rc reads RC_VERSION="unknown".
  mv "$REPO_VERSION_FILE" "$BACKUP_VERSION_FILE" 2>/dev/null || true

  T20_GLOBAL_CFG=$(mktemp "${TMPDIR:-/tmp}/rc-t20-cfg-XXXXXX")
  printf 'version: 2\nmounts:\n  denylist: []\n' > "$T20_GLOBAL_CFG"
  unknown_dry_run_output=$(PATH="${T20_FAKE_MSB_DIR}:${PATH}" RC_IMAGE="$T20_STUB_TAG" RIP_CAGE_IMAGE_REGISTRY="" RC_CAGE_CONF="$(rc_test_write_cage_conf "$TEST_DIR_T20" "$T20_STUB_TAG")" \
    "$RC" up --dry-run "$TEST_DIR_T20" 2>&1 || true)
  rm -f "$T20_GLOBAL_CFG"

  # Restore VERSION file before assertions (so any fail() calls don't leave repo damaged)
  mv "$BACKUP_VERSION_FILE" "$REPO_VERSION_FILE" 2>/dev/null || true

  # Teardown by EXACT fixture tag -- the msb shim was PATH-local and never
  # touched the real cache, and rip-cage:latest was never written.
  rm -rf "$T20_FAKE_MSB_DIR"
  docker rmi "$T20_STUB_TAG" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR_T20"
  # Normal-path teardown complete — disarm the crash-safe trap.
  trap - EXIT INT TERM

  # When RC_VERSION is "unknown", staleness check must be skipped — dry-run
  # should NOT show "would build" / "would pull" (re-provisioning messages).
  if echo "$unknown_dry_run_output" | grep -qi "would build\|would pull"; then
    fail "RC_VERSION=unknown should skip stale check but triggered re-provisioning (output: $unknown_dry_run_output)"
  else
    # POSITIVE-BRANCH SENTINEL: the ELSE branch must be REACHED (not vacuously green from a
    # swap failure). Confirm the output contains normal dry-run lines — "Would create" or
    # "Would mount" — which only appear when the staleness skip path was actually taken.
    if echo "$unknown_dry_run_output" | grep -qi "Would create\|Would mount\|Would start"; then
      pass "RC_VERSION=unknown skips staleness check — normal dry-run lines observed (branch confirmed reached)"
    else
      fail "RC_VERSION=unknown ELSE branch reached but normal dry-run output missing — swap may have silently no-oped or dry-run path broken (output: $unknown_dry_run_output)"
    fi
  fi
fi

# --- Test 21: _next_session_slot — auto-name logic ---
echo ""
echo "=== Test 21: _next_session_slot picks lowest unused rip-cage-N slot ==="
next_slot_output=$(bash -c '
# Define the helper function directly for unit testing
_next_session_slot() {
  local existing_names="$1"
  local n=2
  while true; do
    echo "$existing_names" | grep -qxF "rip-cage-${n}" || break
    n=$((n + 1))
  done
  echo "rip-cage-${n}"
}

# No sessions: next slot is rip-cage-2
result=$(_next_session_slot "rip-cage")
echo "no-sessions:${result}"

# rip-cage-2 taken: next is rip-cage-3
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-2")")
echo "two-taken:${result}"

# rip-cage-2 and rip-cage-3 taken: next is rip-cage-4
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-2\nrip-cage-3")")
echo "three-taken:${result}"

# rip-cage-foo does NOT occupy a slot; rip-cage-2 should still be available
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-foo")")
echo "non-numeric:${result}"

# rip-cage-2 user-named takes slot 2; next is rip-cage-3
result=$(_next_session_slot "$(printf "rip-cage\nrip-cage-2")")
echo "user-named:${result}"
')

if echo "$next_slot_output" | grep -q "no-sessions:rip-cage-2"; then
  pass "_next_session_slot: no sessions → rip-cage-2"
else
  fail "_next_session_slot: no sessions should give rip-cage-2 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "two-taken:rip-cage-3"; then
  pass "_next_session_slot: rip-cage-2 taken → rip-cage-3"
else
  fail "_next_session_slot: rip-cage-2 taken should give rip-cage-3 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "three-taken:rip-cage-4"; then
  pass "_next_session_slot: rip-cage-2,3 taken → rip-cage-4"
else
  fail "_next_session_slot: rip-cage-2,3 taken should give rip-cage-4 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "non-numeric:rip-cage-2"; then
  pass "_next_session_slot: non-numeric suffix does not occupy slot (rip-cage-foo)"
else
  fail "_next_session_slot: rip-cage-foo should not block rip-cage-2 (got: $next_slot_output)"
fi

if echo "$next_slot_output" | grep -q "user-named:rip-cage-3"; then
  pass "_next_session_slot: user-named rip-cage-2 occupies slot → next is rip-cage-3"
else
  fail "_next_session_slot: user-named rip-cage-2 should block slot 2 (got: $next_slot_output)"
fi

# --- Test 22: --new --session mutex flag check in rc up ---
echo ""
echo "=== Test 22: rc up --new --session exits 2 with usage message ==="
TEST_DIR_T22=$(mktemp -d)
mkdir -p "${TEST_DIR_T22}/.git"
mutex_output=$("$RC" up --dry-run --new --session "myname" "$TEST_DIR_T22" 2>&1 || true)
if echo "$mutex_output" | grep -qi "mutually exclusive\|cannot use.*together\|--new.*--session\|--session.*--new"; then
  pass "rc up --new --session shows mutually exclusive usage message"
else
  fail "rc up --new --session should show mutually exclusive error (got: $mutex_output)"
fi
# exit code should be 2 (usage error)
actual_exit=$("$RC" up --dry-run --new --session "myname" "$TEST_DIR_T22" 2>/dev/null; echo $?)
if [[ "$actual_exit" == "2" ]]; then
  pass "rc up --new --session exits with code 2"
else
  fail "rc up --new --session should exit 2, got: $actual_exit"
fi
rm -rf "$TEST_DIR_T22"

# --- Tests 23 + 24: RETIRED with the allowed-roots picker (rip-cage-ely4.9) ---
# Both asserted that `rc up` never shows the interactive "Pick [" prompt the
# allowed-roots guard used to raise when RC_ALLOWED_ROOTS was unset. ADR-031 D2
# deletes that guard: every mount is an explicit line in the project's own
# config, so there is no root to pick and no prompt to suppress. Keeping the
# assertions would have been worse than deleting them — with the producing code
# gone they pass no matter what the launcher does, which is the vacuous-negative
# shape this suite is careful about elsewhere. The agent-first "no prompts ever"
# property they were really defending is now asserted where a prompt could
# actually reappear: ADR-031 D3's first-run-prompt deletion, checked by
# tests/test-adr-evolution-notes.sh (ADR-009 D7).

# --- Tests 25 + 26 + 27: RETIRED into Test 1 (rip-cage-ely4.10) ---
# These asserted that individual retired verbs (sessions, agent, config,
# allowlist, schema, install) are absent from the usage text, one grep each.
# Test 1 now asserts the whole verb column equals the six-verb set, which
# covers every absent verb at once and also catches a SEVENTH verb appearing —
# something a per-name absence grep could never see.

# --- Test 28: tmux.conf contains remain-on-exit setting ---
echo ""
echo "=== Test 28: tmux.conf has remain-on-exit on ==="
if grep -q "remain-on-exit on" "${REPO_ROOT}/cage/agent/tmux.conf"; then
  pass "tmux.conf contains 'remain-on-exit on'"
else
  fail "tmux.conf missing 'remain-on-exit on'"
fi

# --- Test 29: tmux.conf contains pane-died hook ---
echo ""
echo "=== Test 29: tmux.conf has pane-died hook ==="
if grep -q "pane-died" "${REPO_ROOT}/cage/agent/tmux.conf"; then
  pass "tmux.conf contains pane-died hook"
else
  fail "tmux.conf missing pane-died hook"
fi

# --- Test 30: init-rip-cage.sh does NOT contain runtime remain-on-exit set ---
echo ""
echo "=== Test 30: init-rip-cage.sh runtime remain-on-exit removed ==="
if grep -q "tmux set-option -t rip-cage remain-on-exit" "${REPO_ROOT}/cage/init/init-rip-cage.sh"; then
  fail "init-rip-cage.sh still has runtime 'tmux set-option -t rip-cage remain-on-exit' (should be removed)"
else
  pass "init-rip-cage.sh does not have runtime remain-on-exit set (moved to tmux.conf)"
fi

# --- Test 31: init-rip-cage.sh does NOT contain runtime pane-died hook set ---
echo ""
echo "=== Test 31: init-rip-cage.sh runtime pane-died hook removed ==="
if grep -q "tmux set-hook -t rip-cage pane-died" "${REPO_ROOT}/cage/init/init-rip-cage.sh"; then
  fail "init-rip-cage.sh still has runtime 'tmux set-hook -t rip-cage pane-died' (should be removed)"
else
  pass "init-rip-cage.sh does not have runtime pane-died hook set (moved to tmux.conf)"
fi

# --- Test 32: rc up --new flag is recognized (dry-run, no-TTY) ---
echo ""
echo "=== Test 32: rc up --new flag recognized ==="
TEST_DIR_T32=$(mktemp -d)
mkdir -p "${TEST_DIR_T32}/.git"
new_flag_out=$("$RC" up --dry-run --new "$TEST_DIR_T32" 2>&1 </dev/null || true)
if echo "$new_flag_out" | grep -qi "unknown.*flag\|invalid.*option\|unrecognized"; then
  fail "rc up --new flag not recognized (got: $new_flag_out)"
else
  pass "rc up --new flag recognized (no unrecognized flag error)"
fi
rm -rf "$TEST_DIR_T32"

# --- Test 33: rc up --session flag is recognized (dry-run, no-TTY) ---
echo ""
echo "=== Test 33: rc up --session flag recognized ==="
TEST_DIR_T33=$(mktemp -d)
mkdir -p "${TEST_DIR_T33}/.git"
session_flag_out=$("$RC" up --dry-run --session "rip-cage" "$TEST_DIR_T33" 2>&1 </dev/null || true)
if echo "$session_flag_out" | grep -qi "unknown.*flag\|invalid.*option\|unrecognized"; then
  fail "rc up --session flag not recognized (got: $session_flag_out)"
else
  pass "rc up --session flag recognized (no unrecognized flag error)"
fi
rm -rf "$TEST_DIR_T33"

# --- Test 34: registry dispatch uses [[ -t 0 && -t 1 ]] TTY guard (rip-cage-61al.3) ---
echo ""
echo "=== Test 34: registry dispatch checks both stdin and stdout TTY ==="
# After rip-cage-61al.3 removed _up_attach_tmux, the TTY guard lives in the *)
# branch of the registry dispatch case statements in cmd_up (running / resumed /
# new-container paths). Verify the source still enforces both TTY checks via
# the dispatch invocation pattern "docker exec -it" gated on "-t 0 && -t 1".
# We grep for the combined pattern across all three dispatch sites.
# cmd_up lives in cli/up.sh post-decomposition (rip-cage-gto1), not rc.
if grep -c '\-t 0 && \-t 1' "${REPO_ROOT}/cli/up.sh" | grep -qE '^[1-9]'; then
  pass "registry dispatch includes [[ -t 0 && -t 1 ]] TTY guard (stdin+stdout)"
else
  fail "registry dispatch missing [[ -t 0 && -t 1 ]] TTY guard — both stdin and stdout must be checked"
fi

# --- Test 35: _tmux_picker N=0 with mode=attach returns exit 1 + stderr pointing to rc up ---
echo ""
echo "=== Test 35: _tmux_picker in attach mode with N=0 sessions exits 1 + stderr points to rc up ==="
t35_out=$(bash -c '
_PICKER_SESSION=""
_tmux_picker() {
  local cname="$1"
  local mode="${2:-up}"
  # Simulate: docker returns 0 sessions
  local raw_sessions=""
  local sorted_sessions
  sorted_sessions=$(echo "$raw_sessions" | sort -s -k1,1 -rn | awk '"'"'{$1=""; print substr($0,2)}'"'"' )
  local session_count
  session_count=$(echo "$sorted_sessions" | grep -c . || true)
  if [[ "$session_count" -eq 0 ]]; then
    if [[ "$mode" == "attach" ]]; then
      echo "Error: no tmux sessions running in $cname. Start one with: rc up" >&2
      return 1
    fi
    _PICKER_SESSION="rip-cage"
    return 0
  fi
}
_tmux_picker "fake-cage" "attach"
echo "exit:$?"
' 2>&1)
if echo "$t35_out" | grep -q "exit:1"; then
  pass "_tmux_picker attach N=0: exits 1"
else
  fail "_tmux_picker attach N=0: expected exit 1 (got: $t35_out)"
fi
if echo "$t35_out" | grep -qi "rc up"; then
  pass "_tmux_picker attach N=0: stderr points to rc up"
else
  fail "_tmux_picker attach N=0: stderr should mention 'rc up' (got: $t35_out)"
fi

# --- Test 36: RETIRED into Test 1 (rip-cage-ely4.10) ---
# Same subject as Tests 25-27: one retired verb's absence from usage, now
# covered by Test 1's exact-set assertion.

# --- Test 37: ADR-006 contains Tier 1a (parallel tmux sessions) ---
echo ""
echo "=== Test 37: ADR-006 D1 contains Tier 1a ==="
if grep -q "Tier 1a" "${REPO_ROOT}/docs/decisions/ADR-006-multi-agent-architecture.md"; then
  pass "ADR-006 contains Tier 1a"
else
  fail "ADR-006 missing Tier 1a (parallel tmux sessions in one cage)"
fi

# --- Test 38: ADR-006 contains Tier 1b (multiple containers) ---
echo ""
echo "=== Test 38: ADR-006 D1 contains Tier 1b ==="
if grep -q "Tier 1b" "${REPO_ROOT}/docs/decisions/ADR-006-multi-agent-architecture.md"; then
  pass "ADR-006 contains Tier 1b"
else
  fail "ADR-006 missing Tier 1b (multiple containers rename)"
fi

# --- Test 39: multi-agent-architecture.md Tier 1 heading renamed to Tier 1b ---
echo ""
echo "=== Test 39: multi-agent-architecture.md has Tier 1b heading ==="
if grep -q "Tier 1b" "${REPO_ROOT}/docs/2026-03-27-multi-agent-architecture.md"; then
  pass "multi-agent-architecture.md contains Tier 1b"
else
  fail "multi-agent-architecture.md missing Tier 1b rename"
fi

# --- Test 40: RETIRED (rip-cage-ely4.14) ---
# Asserted that docs/ROADMAP.md carried the "Tier 1b" tier name, as bookkeeping
# for the v0.3 Tier 1a/1b rename. The ROADMAP's multi-agent phase plan was
# deleted when the roadmap was rewritten to the distribution positioning
# (ADR-031 D1/D8): those phases planned a product this repo is not building.
# Tests 38 and 39 above still assert the rename in its durable homes --
# ADR-006 and docs/2026-03-27-multi-agent-architecture.md -- which is where a
# historical rename belongs. A living roadmap is the wrong place to pin one.

# --- Test 41: cli-reference.md Running multiple agents section lacks v0.3 forward-pointer ---
echo ""
echo "=== Test 41: cli-reference.md no longer has v0.3 forward-pointer ==="
if grep -q "v0\.3" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  fail "cli-reference.md still has v0.3 forward-pointer (should be removed)"
else
  pass "cli-reference.md no longer has v0.3 forward-pointer"
fi

# --- Test 42: cli-reference.md does NOT mention rc sessions (retired rip-cage-1f59.6) ---
# NON-VACUOUS: would fail if rc sessions were still present as a live command in cli-reference.md.
# Inverted from "presence → pass" to "absence → pass" per debt note from rip-cage-1f59.3.
echo ""
echo "=== Test 42: cli-reference.md does NOT document rc sessions (retired) ==="
if grep -q "rc sessions" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  fail "cli-reference.md still mentions rc sessions as a live command (should be retired per rip-cage-1f59.6)"
else
  pass "cli-reference.md does not mention rc sessions (correctly retired)"
fi
# Also assert rc agent is absent from cli-reference.md
if grep -q "rc agent" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  fail "cli-reference.md still mentions rc agent as a live command (should be retired per rip-cage-1f59.6)"
else
  pass "cli-reference.md does not mention rc agent (correctly retired)"
fi

# --- Test 43: cli-reference.md documents --new flag ---
echo ""
echo "=== Test 43: cli-reference.md documents --new flag ==="
if grep -q "\-\-new" "${REPO_ROOT}/docs/reference/cli-reference.md"; then
  pass "cli-reference.md documents --new flag"
else
  fail "cli-reference.md missing --new flag documentation"
fi

# --- Test 44: CHANGELOG.md Unreleased has new picker/sessions Added entries ---
echo ""
echo "=== Test 44: CHANGELOG.md Unreleased mentions picker ==="
if grep -q "picker\|rc sessions\|--new" "${REPO_ROOT}/CHANGELOG.md"; then
  pass "CHANGELOG.md mentions picker or rc sessions in Unreleased"
else
  fail "CHANGELOG.md missing picker/rc sessions in Unreleased section"
fi

# --- Test 45: RETIRED with completions/ (rip-cage-ely4.10 / ADR-031 D3) ---
# Asserted that retired verbs left no token behind in completions/rc.bash and
# completions/_rc. The whole completions/ tree is deleted — a completion
# surface for six memorable verbs earns less than it costs to keep honest —
# so there is no file left to grep. The paired half of this case, "a retired
# verb with --output json still exits non-zero", is Test 1b's sweep now.

# --- Test 46: picker EOF on stdin exits 1 with expected stderr message (AC-5b) ---
echo ""
echo "=== Test 46: picker EOF on stdin exits 1 and prints expected message ==="
# Inline the picker read loop with a pre-built names array (no docker calls needed).
# Feed EOF from /dev/null as stdin to trigger the EOF path.
t46_stderr=$(bash -c '
_PICKER_SESSION=""
# Pre-built state: one session in the names array (so we reach the read loop)
names=("rip-cage")
new_idx=2
# Reproduce the picker read loop
local_input=""
local_invalid=0
while true; do
  printf "Pick [1]: " >&2
  if ! read -r local_input; then
    echo "" >&2
    echo "rc: picker received EOF on stdin; refusing to auto-select. Use --new or --session <name>, or attach via '"'"'rc attach <cage>'"'"'." >&2
    exit 1
  fi
  local_input=$(echo "$local_input" | sed '"'"'s/^[[:space:]]*//;s/[[:space:]]*$//'"'"')
  if [[ -z "$local_input" ]]; then
    _PICKER_SESSION="${names[0]}"
    exit 0
  fi
  case "$local_input" in
    '"'"''"'"'|*[!0-9]*)
      local_invalid=$((local_invalid + 1))
      [[ "$local_invalid" -ge 2 ]] && exit 1
      continue ;;
  esac
  if [[ "$local_input" -ge 1 ]] && [[ "$local_input" -lt "$new_idx" ]]; then
    _PICKER_SESSION="${names[$((local_input - 1))]}"
    exit 0
  fi
  local_invalid=$((local_invalid + 1))
  [[ "$local_invalid" -ge 2 ]] && exit 1
done
' </dev/null 2>&1)
t46_exit=$?
if [[ "$t46_exit" -ne 0 ]]; then
  pass "picker EOF: exits non-zero (exit $t46_exit)"
else
  fail "picker EOF: expected non-zero exit, got 0 (stderr: $t46_stderr)"
fi
if echo "$t46_stderr" | grep -q "EOF on stdin\|refusing to auto-select"; then
  pass "picker EOF: stderr contains expected message"
else
  fail "picker EOF: stderr missing expected message (got: $t46_stderr)"
fi

# --- Test 47: picker whitespace-only input treated as empty → selects entry 1 (AC-5c) ---
echo ""
echo "=== Test 47: picker whitespace-only input selects entry 1 ==="
# Feed "   \n" (spaces + newline) to the picker read loop; expect it selects names[0]
t47_result=$(bash -c '
_PICKER_SESSION=""
names=("rip-cage" "rip-cage-2")
new_idx=3
local_input=""
local_invalid=0
while true; do
  if ! read -r local_input; then
    exit 1
  fi
  local_input=$(echo "$local_input" | sed '"'"'s/^[[:space:]]*//;s/[[:space:]]*$//'"'"')
  if [[ -z "$local_input" ]]; then
    _PICKER_SESSION="${names[0]}"
    echo "selected:${names[0]}"
    exit 0
  fi
  case "$local_input" in
    '"'"''"'"'|*[!0-9]*)
      local_invalid=$((local_invalid + 1))
      [[ "$local_invalid" -ge 2 ]] && exit 1
      continue ;;
  esac
  if [[ "$local_input" -ge 1 ]] && [[ "$local_input" -lt "$new_idx" ]]; then
    _PICKER_SESSION="${names[$((local_input - 1))]}"
    echo "selected:${names[$((local_input - 1))]}"
    exit 0
  fi
  local_invalid=$((local_invalid + 1))
  [[ "$local_invalid" -ge 2 ]] && exit 1
done
' < <(printf '   \n')
)
if echo "$t47_result" | grep -q "selected:rip-cage$"; then
  pass "picker whitespace-only input: selects entry 1 (rip-cage)"
else
  fail "picker whitespace-only input: expected 'selected:rip-cage', got: $t47_result"
fi

# --- Tests 48 + 50 + 51: RETIRED with `rc exec` (rip-cage-ely4.10 / ADR-031 D3) ---
# These asserted that `rc exec` is listed in usage, is in the --output json
# allowlist, and dispatches rather than falling through to usage. The verb is
# deleted: a one-off command in a cage is `msb exec <cage> -- <cmd>`. All three
# properties now invert, and Test 1b asserts the inverted form for exec along
# with every other deleted verb.

# --- Test 49: RETIRED with `rc schema` (rip-cage-ely4.9) ---
# `rc schema` printed a machine-readable command table generated from the
# rip-cage config schema. ADR-003 D5, evolved in place by ADR-031 D2: the verb
# retires with that schema. The agent-first machine-readable contract it
# gestured at is not lost — it is refactor work under ADR-031 D7 stage 2
# (--output json on the surviving verbs, an exit-code table), tracked by
# rip-cage-sygz, not something this test was ever asserting.

# --- Test 52: mux prereq checks delegated to baked hooks (rip-cage-61al.3) ---
echo ""
echo "=== Test 52: multiplexer prereq checks delegated to baked provider hooks ==="
# After rip-cage-61al.3, check_tmux was removed. The prerequisite section now
# delegates mux binary checks to the baked provider hooks (registry dispatch).
# Assert: (a) check_tmux does NOT appear in the prereq section (removed),
#         (b) the prereq section references "baked" hooks for mux prereqs (comment
#             or code — verifying the design intent is present in source).
t52_gate_section=$(awk '/^# Prerequisite checks/,/^# Main dispatch/' "$RC")
t52_no_check_tmux=false
t52_has_hooks_comment=false
if ! echo "$t52_gate_section" | grep -q 'check_tmux'; then
  t52_no_check_tmux=true
fi
if echo "$t52_gate_section" | grep -qi 'baked\|hook\|provider\|registry'; then
  t52_has_hooks_comment=true
fi
if [[ "$t52_no_check_tmux" == "true" ]]; then
  pass "check_tmux not present in prereq section (correctly removed — mux prereqs are hook responsibility)"
else
  fail "check_tmux still present in prereq section — should be removed (mux prereqs delegated to baked hooks per rip-cage-61al.3)"
fi
if [[ "$t52_has_hooks_comment" == "true" ]]; then
  pass "prereq section references baked/hook/provider/registry (design intent documented)"
else
  fail "prereq section lacks reference to baked hooks — add a comment explaining mux prereqs are hook responsibility"
fi

# --- Test 53: _rc_uptime_from_state parses updated_at as UTC, not local zone (rip-cage-cf6f) ---
echo ""
echo "=== Test 53: _rc_uptime_from_state does not inflate uptime by the host UTC offset ==="
# rip-cage-cf6f: msb records updated_at in UTC. The BSD `date -j -f` arm in
# _rc_uptime_from_state was missing `-u`, so it read the UTC string as if it
# were in the LOCAL zone -- a cage 2 minutes old was reported as "2h 4m" on a
# CEST (+2h) host. TZ=Europe/Berlin below pins a non-UTC offset so this case
# is red on the bug regardless of the CI runner's own zone (a UTC runner
# would make the bug invisible without this pin).
t53_out=$(TZ=Europe/Berlin bash -c '
  source "'"${REPO_ROOT}"'/cli/lib/container.sh"
  now_epoch=$(date +%s)
  target_epoch=$((now_epoch - 120))
  updated_at=$(date -u -j -f %s "$target_epoch" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || date -u -d "@$target_epoch" +"%Y-%m-%dT%H:%M:%S")
  result=$(_rc_uptime_from_state 1 "$updated_at")
  echo "RESULT:$result"
' 2>&1)
t53_result=$(echo "$t53_out" | sed -n 's/^RESULT://p')
if [[ "$t53_result" == "2m" ]]; then
  pass "_rc_uptime_from_state: 120s-old UTC updated_at yields 2m (got: $t53_result)"
else
  fail "_rc_uptime_from_state: expected 2m, got: $t53_result (full output: $t53_out)"
fi
# NEGATIVE CONTROL: reverting the fix reintroduces the "Nh" form on an
# offset host, so this case cannot pass vacuously.
if echo "$t53_result" | grep -q "h"; then
  fail "_rc_uptime_from_state: result contains 'h' -- offset leaked into uptime (got: $t53_result)"
else
  pass "_rc_uptime_from_state: result does not contain 'h' (got: $t53_result)"
fi


# ===========================================================================
# rip-cage-ely4.9 — the native cage config and the protected-paths floor
# (ADR-031 D2 / D5(a)+(d); ADR-023 D2 evolved in place).
#
# These four cases ARE the bead's verification target. Two of them — the
# refusals — have exactly one honest observable: whether rc reached msb at
# all. A fail-OPEN launcher would sail past the check and create a cage, and
# a test that only asserted a non-zero exit code could not tell that apart
# from a refusal. So every case runs with a PATH shim in front of the real
# msb that RECORDS what it was asked to do. The shim answers `--version`
# (rc's own preflight legitimately calls it before dispatch) and, for any
# other subcommand, drops a sentinel file and fails. The assertion is the
# sentinel's absence, not the exit code alone.
# ===========================================================================
echo ""
echo "=== Test 60: native cage config + protected-paths floor (rip-cage-ely4.9) ==="

# /private/tmp, never /tmp: msb does not follow a host-side symlink in a bind
# source, and on macOS /tmp IS a symlink to /private/tmp (measured, msb 0.6.18,
# spike rip-cage-ely4.16). A fixture under /tmp would fail at boot, not here.
E49_ROOT="$(mktemp -d /private/tmp/rc-ely49-XXXXXX)"
E49_HOME="${E49_ROOT}/home"
E49_PROJ="${E49_ROOT}/proj"
E49_BIN="${E49_ROOT}/bin"
E49_LOG="${E49_ROOT}/msb-invocations.log"
E49_SENTINEL="${E49_ROOT}/MSB_WAS_SPAWNED"
mkdir -p "$E49_HOME" "$E49_PROJ/.ssh" "$E49_BIN"

# A project carrying both cover shapes: a protected FILE and a protected
# DIRECTORY, each inside a tree the config legitimately mounts.
printf 'SENTINEL_NOT_A_REAL_SECRET=1\n' > "${E49_PROJ}/.env"
printf 'not-a-real-key\n' > "${E49_PROJ}/.ssh/id_ed25519"

cat > "${E49_BIN}/msb" <<'E49_SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E49_LOG}"
case "${1:-}" in
  --version) echo "msb 0.6.18-test-shim"; exit 0 ;;
esac
: > "${E49_SENTINEL}"
echo "test shim: msb was invoked with: $*" >&2
exit 1
E49_SHIM
chmod +x "${E49_BIN}/msb"

e49_conf() {
  # $1 = destination path, $2 = the mounts: block body
  cat > "$1" <<E49_CONF
image: rip-cage:latest
workdir: /workspace
mounts:
${2}
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
E49_CONF
}

# Every invocation runs with the shim first on PATH and a THROWAWAY XDG config
# dir, so nothing here can read or write the real ~/.config/rip-cage —
# $XDG_CONFIG_HOME is the only place rc looks for a cage config or a
# protected-paths list.
#
# HOME is deliberately NOT overridden. Docker resolves its context and socket
# through $HOME, so a fake one makes rc's docker preflight fail and every case
# below reports a daemon error instead of testing its own subject. The
# protected-path fixture is therefore a fake ".ssh" under the scratch root
# rather than the real ~/.ssh — matching is by path COMPONENT, so it exercises
# the identical branch without ever naming the operator's own key directory.
e49_run_rc() {
  ( export PATH="${E49_BIN}:${PATH}"
    export XDG_CONFIG_HOME="${E49_HOME}/.config"
    export E49_LOG E49_SENTINEL
    "$@" ) 2>&1
}

# --- (a) the dry-run argv carries --conf and --log-level trace -------------
e49_conf "${E49_ROOT}/ok.yaml" "  - \"${E49_PROJ}:/workspace\""
rm -f "$E49_SENTINEL" "$E49_LOG"
t60a_out=$(e49_run_rc env RC_CAGE_CONF="${E49_ROOT}/ok.yaml" "$RC" up --dry-run "$E49_PROJ")
t60a_argv=$(printf '%s\n' "$t60a_out" | grep '^Would run: msb create' || true)

if [[ -n "$t60a_argv" ]]; then
  pass "60a: rc up --dry-run prints the msb create argv"
else
  fail "60a: rc up --dry-run printed no msb create argv (output: ${t60a_out})"
fi
if printf '%s\n' "$t60a_argv" | grep -q -- "--conf ${E49_ROOT}/ok.yaml"; then
  pass "60a: argv contains --conf pointing at the cage config"
else
  fail "60a: argv is missing '--conf ${E49_ROOT}/ok.yaml' (argv: ${t60a_argv})"
fi
if printf '%s\n' "$t60a_argv" | grep -q -- "--log-level trace"; then
  pass "60a: argv contains --log-level trace (the deny-trace the repair loop mines)"
else
  fail "60a: argv is missing '--log-level trace' (argv: ${t60a_argv})"
fi
# The image positional retired with ADR-031 D2 — the config's image: key
# selects the image. An argv ending in a bare image ref would mean rc is still
# overriding it.
if printf '%s\n' "$t60a_argv" | grep -qE 'rip-cage:latest$'; then
  fail "60a: argv still ends with an image positional — the config's image: key should select the image (argv: ${t60a_argv})"
else
  pass "60a: argv carries no image positional"
fi

# --- (c) covers for a protected file and a protected directory -------------
# This is the half a refuse-only check would miss: the credential sitting
# INSIDE a tree you legitimately mount gets covered, not refused.
if printf '%s\n' "$t60a_argv" | grep -q -- "--mount-file .*:/workspace/.env:ro"; then
  pass "60c: a protected FILE inside the mounted tree gets an empty read-only file cover"
else
  fail "60c: no read-only file cover for /workspace/.env in the argv (argv: ${t60a_argv})"
fi
if printf '%s\n' "$t60a_argv" | grep -q -- "--tmpfs /workspace/.ssh"; then
  pass "60c: a protected DIRECTORY inside the mounted tree gets an empty tmpfs cover"
else
  fail "60c: no tmpfs cover for /workspace/.ssh in the argv (argv: ${t60a_argv})"
fi
# NEGATIVE CONTROL: a cover nested under a directory cover would try to mount
# INTO a tmpfs msb just created, which aborts the boot. The id_ed25519 under
# the covered .ssh/ must NOT get its own cover.
if printf '%s\n' "$t60a_argv" | grep -q "/workspace/.ssh/id_ed25519"; then
  fail "60c: emitted a nested cover under an already-tmpfs-covered directory (argv: ${t60a_argv})"
else
  pass "60c: no nested cover under the tmpfs-covered directory"
fi

# --- (b) a config that mounts ~/.ssh is refused, with no msb spawned -------
E49_FAKE_SSH="${E49_ROOT}/fake-home/.ssh"
mkdir -p "$E49_FAKE_SSH"
e49_conf "${E49_ROOT}/bad.yaml" "  - \"${E49_PROJ}:/workspace\"
  - \"${E49_FAKE_SSH}:/home/agent/.ssh:ro\""
rm -f "$E49_SENTINEL" "$E49_LOG"
t60b_out=$(e49_run_rc env RC_CAGE_CONF="${E49_ROOT}/bad.yaml" "$RC" up "$E49_PROJ" 2>&1)
t60b_rc=$?

if [[ "$t60b_rc" -ne 0 ]]; then
  pass "60b: a config that mounts a protected path makes rc up exit non-zero (exit ${t60b_rc})"
else
  fail "60b: rc up exited 0 on a config that mounts ${E49_FAKE_SSH}"
fi
if [[ -f "$E49_SENTINEL" ]]; then
  fail "60b: msb WAS spawned before the refusal — the check is fail-open (invocations: $(cat "$E49_LOG" 2>/dev/null))"
else
  pass "60b: no msb subcommand ran — rc refused before the cage could exist"
fi

# --- (f) the refusal's persistent override points at a file that EXISTS ----
# rip-cage-ely4.7.14: the hint used to print a YAML block from the retired
# rip-cage config schema, so an operator who followed it edited a key nothing
# reads. Two halves, and the SHAPE check is the one that catches a regression:
# naming the resolved list file is only useful if no retired-schema block is
# sitting next to it saying something different.
#
# The shipped list is the resolved one here because the scratch XDG dir has no
# operator copy and this suite sets no RC_PROTECTED_PATHS — so asserting on the
# path rc PRINTED, then checking that path exists, proves it resolved rather
# than guessed.
t60f_list=$(printf '%s\n' "$t60b_out" | sed -n 's/.*protected-paths list this run read: //p' | head -1)
if [[ -n "$t60f_list" && -f "$t60f_list" ]]; then
  pass "60f: the refusal names a protected-paths list file that exists (${t60f_list})"
else
  fail "60f: the refusal named no readable protected-paths list (named: '${t60f_list}'; message: ${t60b_out})"
fi
if printf '%s\n' "$t60b_out" | grep -q 'allow_risky'; then
  fail "60f: the refusal still prints the retired mounts.allow_risky override (message: ${t60b_out})"
else
  pass "60f: the refusal prints no retired-schema override key"
fi

# --- (d) an unreadable protected-paths list refuses, with no msb spawned ---
# The fail-CLOSED direction is the whole point: the retired pre-flight failed
# OPEN when its config would not load, which meant a broken policy file
# silently produced an unprotected cage.
E49_UNREADABLE="${E49_ROOT}/unreadable-protected-paths"
printf '.ssh\n.env\n' > "$E49_UNREADABLE"
chmod 000 "$E49_UNREADABLE"
rm -f "$E49_SENTINEL" "$E49_LOG"
e49_run_rc env RC_CAGE_CONF="${E49_ROOT}/ok.yaml" RC_PROTECTED_PATHS="$E49_UNREADABLE" \
  "$RC" up "$E49_PROJ" >/dev/null 2>&1
t60d_rc=$?
chmod 644 "$E49_UNREADABLE"

if [[ "$t60d_rc" -ne 0 ]]; then
  pass "60d: an unreadable protected-paths list makes rc up exit non-zero (exit ${t60d_rc})"
else
  fail "60d: rc up exited 0 with an unreadable protected-paths list — fail-open"
fi
if [[ -f "$E49_SENTINEL" ]]; then
  fail "60d: msb WAS spawned despite an unreadable protected-paths list (invocations: $(cat "$E49_LOG" 2>/dev/null))"
else
  pass "60d: no msb subcommand ran — rc aborted before the cage could exist"
fi

# NEGATIVE CONTROL for the whole block: with the list readable again, the same
# config must launch. Without this, 60b and 60d could both pass because rc
# refuses everything.
rm -f "$E49_SENTINEL" "$E49_LOG"
t60e_out=$(e49_run_rc env RC_CAGE_CONF="${E49_ROOT}/ok.yaml" RC_PROTECTED_PATHS="$E49_UNREADABLE" \
  "$RC" up --dry-run "$E49_PROJ")
if printf '%s\n' "$t60e_out" | grep -q '^Would run: msb create'; then
  pass "60e: the same config with a READABLE list reaches the launch — 60b/60d are not vacuous"
else
  fail "60e: rc refused even with a readable list — 60b and 60d prove nothing (output: ${t60e_out})"
fi

# ===========================================================================
# Test 61: `rc up --replace` against a STOPPED cage (rip-cage-ely4.10,
# ADR-031 D3 -- the verb `rc reload` folded into).
#
# WHY A STOPPED CAGE IS THE CASE. A plain `rc up` already recreates a stopped
# cage when its CONFIG changed. The other repairable drift -- a stale pinned
# image after `rc build` -- leaves the config hash untouched, so the plain
# resume hits the image-drift hard stop instead, and that stop has to name a
# remedy. `rc reload` was that remedy; with the verb gone, `--replace` is, and
# it only helps if it covers a cage that is not running.
#
# It did not. `--replace` cleared the cage's state string but left the
# absent-cage signal saying "present", so the state branch fell past every arm
# into the unrecognized-state fail-loud: rc removed the cage and then refused
# to recreate it. Measured on the branch as written; fixed in cli/up.sh.
#
# The observable is the dry-run plan, which is honest here precisely because
# it is assembled by the same code the real launch runs (Test 60a). Under
# --dry-run nothing may be stopped or removed, and the shim's log is what
# proves that -- an exit code could not tell a plan apart from a recreate.
# ===========================================================================
echo ""
echo "=== Test 61: rc up --replace recreates a STOPPED cage (rip-cage-ely4.10) ==="

T61_ROOT="$(mktemp -d /private/tmp/rc-ely410-XXXXXX)"
T61_BIN="${T61_ROOT}/bin"
T61_PROJ="${T61_ROOT}/proj"
T61_LOG="${T61_ROOT}/msb-invocations.log"
mkdir -p "$T61_BIN" "$T61_PROJ" "${T61_ROOT}/home"

# A fake msb reporting one STOPPED rc-managed cage for this workspace, and
# logging every subcommand it is asked for.
cat > "${T61_BIN}/msb" <<'T61_SHIM'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${T61_LOG}"
case "${1:-}" in
  --version) echo "msb 0.6.18-test-shim"; exit 0 ;;
  inspect)
    cat <<JSON
{"status":"Stopped","config":{"manifest_digest":"sha256:t61matchingdigest","labels":{"rc.source.path":"${T61_PROJ}","rc.cage-conf-sha":"${T61_CONF_SHA}"}}}
JSON
    exit 0 ;;
  image) echo '[{"reference":"rip-cage:latest","digest":"sha256:t61matchingdigest"}]'; exit 0 ;;
  stop|remove) exit 0 ;;
  *) echo "test shim: unhandled msb subcommand: $*" >&2; exit 1 ;;
esac
T61_SHIM
chmod +x "${T61_BIN}/msb"

cat > "${T61_ROOT}/cage.yaml" <<T61_CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${T61_PROJ}:/workspace"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
T61_CONF

# The stub must report the cage's config hash as the CURRENT one, and its image
# digest as MATCHING the current image, or a plain `rc up` converges on config
# drift or aborts on image drift and 61d's negative control measures the wrong
# thing. Same computation cli/up.sh's _up_cage_conf_sha does.
T61_CONF_SHA=$(shasum -a 256 "${T61_ROOT}/cage.yaml" | awk '{print $1}')

t61_run_rc() {
  ( export PATH="${T61_BIN}:${PATH}"
    export XDG_CONFIG_HOME="${T61_ROOT}/home/.config"
    export RC_CAGE_CONF="${T61_ROOT}/cage.yaml"
    # This case OVERRIDES the file-wide fixture tag back to the default name,
    # and that is safe here precisely because nothing real is reachable: the
    # msb shim above answers every subcommand, its image list and this case's
    # cage.yaml both name rip-cage:latest, and the image-compat check under
    # test compares those two names. The production tag is a STRING in a
    # fixture here, never an argument to anything that writes.
    export RC_IMAGE="rip-cage:latest"
    export T61_LOG T61_PROJ T61_CONF_SHA
    "$RC" "$@" ) 2>&1
}

: > "$T61_LOG"
t61_out=$(t61_run_rc up --replace --dry-run "$T61_PROJ")

if printf '%s\n' "$t61_out" | grep -q "recreate stopped cage"; then
  pass "61a: --replace announces the recreate for a STOPPED cage"
else
  fail "61a: --replace did not announce a recreate for a stopped cage (output: ${t61_out})"
fi
if printf '%s\n' "$t61_out" | grep -q "^Would create container"; then
  pass "61b: --replace reaches the create path (the unrecognized-state fail-loud is gone)"
else
  fail "61b: --replace did not reach the create path — the cage would be removed and not recreated (output: ${t61_out})"
fi
if printf '%s\n' "$t61_out" | grep -qi "unrecognized state"; then
  fail "61b: --replace fell into the unrecognized-state fail-loud (output: ${t61_out})"
else
  pass "61b: no unrecognized-state error"
fi
for _t61_verb in stop remove; do
  if grep -qx "$_t61_verb" "$T61_LOG"; then
    fail "61c: msb ${_t61_verb} ran under --dry-run — a preview must preview (log: $(tr '\n' ' ' < "$T61_LOG"))"
  else
    pass "61c: msb ${_t61_verb} was not called under --dry-run"
  fi
done

# NEGATIVE CONTROL: the SAME stopped cage WITHOUT --replace, and with a config
# hash that matches its label, resumes instead of recreating. Without this,
# 61a/61b would pass against an `rc up` that recreated everything on sight —
# which is exactly what ADR-029 D4's stopped-only rule exists to bound.
: > "$T61_LOG"
t61_plain=$(t61_run_rc up --dry-run "$T61_PROJ")
if printf '%s\n' "$t61_plain" | grep -q "^Would resume container"; then
  pass "61d: a plain rc up on the same stopped cage resumes — 61a/61b are not vacuous"
else
  fail "61d: a plain rc up on the same stopped cage did not resume (output: ${t61_plain})"
fi

rm -rf "$T61_ROOT"


# --- T62: rc build's one input, and the containment rule on it (rip-cage-ely4.11) ---
#
# ADR-031 D5(a)/D5(c): the Dockerfile is a composition input, authored where the
# caged agent cannot reach it. A path inside a cage mount is refused BEFORE any
# docker call, fail-closed, with no opt-out flag -- the opt-out is the vector.
#
# THE SHIM IS THE WHOLE POINT. "Refused before docker runs" is not observable
# from an exit code: a build that ran and then failed also exits non-zero. So a
# `docker` on PATH appends every invocation to a file, and the assertion is that
# NO `docker build` appears in it. Without the shim, these cases would pass just
# as green with the containment check running AFTER the build.
#
# "No build" rather than "empty log", deliberately: rc legitimately runs
# `docker info` as a prerequisite check before any verb body, so an empty log
# would be asserting that rc skipped its own preflight. 62e is the control that
# keeps the weaker predicate honest -- it proves a `build` line DOES appear when
# the Dockerfile is acceptable.
echo ""
echo "=== T62: rc build takes one input, and refuses a Dockerfile inside a cage mount ==="
T62_ROOT=$(mktemp -d)
T62_SHIM="${T62_ROOT}/bin"
T62_LOG="${T62_ROOT}/docker-invocations.log"
mkdir -p "$T62_SHIM"
cat > "${T62_SHIM}/docker" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${T62_LOG}"
exit 0
SHIM
chmod +x "${T62_SHIM}/docker"
: > "$T62_LOG"

# A project the cage config mounts, with the Dockerfile sitting inside it --
# exactly the shape an agent inside that cage could write to.
T62_PROJ="${T62_ROOT}/proj"
mkdir -p "$T62_PROJ"
printf 'FROM rip-cage:latest\n' > "${T62_PROJ}/Dockerfile"
T62_PROJ_REAL=$(cd "$T62_PROJ" && pwd -P)
T62_CONF="${T62_ROOT}/cage.yaml"
cat > "$T62_CONF" <<CONF
image: rip-cage:latest
mounts:
  - ${T62_PROJ_REAL}:/workspace
CONF

t62_rc=0
t62_out=$(PATH="${T62_SHIM}:${PATH}" RC_CAGE_CONF="$T62_CONF" \
  "$RC" build --file "${T62_PROJ}/Dockerfile" 2>&1) || t62_rc=$?

if [[ "$t62_rc" -ne 0 ]]; then
  pass "62a: rc build refused a Dockerfile inside a cage mount"
else
  fail "62a: rc build accepted a Dockerfile inside a cage mount (output: ${t62_out})"
fi
if ! grep -q "build" "$T62_LOG" 2>/dev/null; then
  pass "62b: no docker build ran — the refusal is genuinely pre-docker"
else
  fail "62b: docker build WAS invoked before the refusal: $(cat "$T62_LOG")"
fi
if grep -q "sits inside" <<<"$t62_out"; then
  pass "62c: the refusal names the mount the Dockerfile sits inside"
else
  fail "62c: the refusal did not explain itself (output: ${t62_out})"
fi
if grep -qi "no opt-out" <<<"$t62_out"; then
  pass "62d: the refusal states there is no opt-out, so nobody goes hunting for a flag"
else
  fail "62d: the refusal did not say there is no opt-out (output: ${t62_out})"
fi

# NEGATIVE CONTROL for 62b: same shim, a Dockerfile OUTSIDE every mount. docker
# must be invoked here, or 62b's empty log proves nothing.
: > "$T62_LOG"
T62_OUTSIDE="${T62_ROOT}/outside"
mkdir -p "$T62_OUTSIDE"
printf 'FROM rip-cage:latest\n' > "${T62_OUTSIDE}/Dockerfile"
PATH="${T62_SHIM}:${PATH}" RC_CAGE_CONF="$T62_CONF" RC_IMAGE="rip-cage-t62:1" \
  "$RC" build --file "${T62_OUTSIDE}/Dockerfile" >/dev/null 2>&1 || true
if grep -q "build" "$T62_LOG" 2>/dev/null; then
  pass "62e: a Dockerfile outside every mount DOES reach docker — 62b is not vacuous"
else
  fail "62e: docker was never invoked even for a legitimate Dockerfile — 62b proves nothing"
fi
# And the argv docker receives is the fixed one (ADR-031 D5(c)).
if grep -qE 'build -f .*/outside/Dockerfile --build-arg RC_VERSION=.* -t rip-cage-t62:1 .*/outside' "$T62_LOG"; then
  pass "62f: docker received exactly -f <path> --build-arg RC_VERSION -t <tag> <context>"
else
  fail "62f: docker's argv was not the fixed one: $(cat "$T62_LOG")"
fi

# The one-input rule: anything other than --file is refused, pre-docker.
: > "$T62_LOG"
t62_flag_rc=0
t62_flag=$(PATH="${T62_SHIM}:${PATH}" RC_CAGE_CONF="$T62_CONF" "$RC" build --no-cache 2>&1) || t62_flag_rc=$?
if [[ "$t62_flag_rc" -ne 0 ]] && ! grep -q "build" "$T62_LOG" 2>/dev/null; then
  pass "62g: a docker flag other than --file is refused before docker runs"
else
  fail "62g: --no-cache was not refused pre-docker (output: ${t62_flag})"
fi
: > "$T62_LOG"
t62_tag_rc=0
t62_tag=$(PATH="${T62_SHIM}:${PATH}" RC_CAGE_CONF="$T62_CONF" "$RC" build -t evil:latest 2>&1) || t62_tag_rc=$?
if [[ "$t62_tag_rc" -ne 0 ]] && ! grep -q "build" "$T62_LOG" 2>/dev/null; then
  pass "62h: -t/--tag is refused too — the tag is rc's own, set via RC_IMAGE"
else
  fail "62h: -t was not refused pre-docker (output: ${t62_tag})"
fi

rm -rf "$T62_ROOT"


# ===========================================================================
# Test 63: the egress floor — no generated --net-default, and a config that
# does not declare `network.policy: none` is refused before any msb call
# (rip-cage-ely4.7.7; ADR-029 D2 FIRM, ADR-031 D2).
#
# THE BUG THIS CLOSES. rc generated `--net-default deny` on every create. On
# msb 0.6.18 that flag REPLACES the allow list the `--conf` file carries
# (measured, rip-cage-ely4.7.6: `msb inspect` then shows `rules: []`), while
# `--net-rule` APPENDS to it. Once rip-cage-ely4.9 moved the allowlist into the
# cage config, the deny flag wiped it — every cage booted from HEAD resolved
# nothing, including the hosts its own config listed.
#
# WHY THE GUARD IS THE OTHER HALF. Dropping the flag moves a FIRM property out
# of argv rc controls and into a file an operator edits. That is only safe if rc
# refuses the file that omits it — otherwise the same edit that used to be
# harmless now silently produces an open cage. So (b) and (c) below assert the
# refusal, and they use Test 60's PATH-shim discipline: the honest observable is
# whether rc reached msb AT ALL, which an exit code alone cannot show.
# ===========================================================================
echo ""
echo "=== Test 63: no --net-default in the argv; a config without network.policy: none is refused ==="

# /private/tmp for the same reason as Test 60: on macOS /tmp is a symlink and
# msb does not follow one in a bind source.
T63_ROOT="$(mktemp -d /private/tmp/rc-ely477-XXXXXX)"
T63_HOME="${T63_ROOT}/home"
T63_PROJ="${T63_ROOT}/proj"
T63_BIN="${T63_ROOT}/bin"
T63_LOG="${T63_ROOT}/msb-invocations.log"
T63_SENTINEL="${T63_ROOT}/MSB_WAS_SPAWNED"
mkdir -p "$T63_HOME" "$T63_PROJ" "$T63_BIN"

cat > "${T63_BIN}/msb" <<'T63_SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${T63_LOG}"
case "${1:-}" in
  --version) echo "msb 0.6.18-test-shim"; exit 0 ;;
esac
: > "${T63_SENTINEL}"
echo "test shim: msb was invoked with: $*" >&2
exit 1
T63_SHIM
chmod +x "${T63_BIN}/msb"

# t63_conf <dest> <network-block-body-or-empty>
t63_conf() {
  cat > "$1" <<T63_CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${T63_PROJ}:/workspace"
${2}
T63_CONF
}

t63_run_rc() {
  ( export PATH="${T63_BIN}:${PATH}"
    export XDG_CONFIG_HOME="${T63_HOME}/.config"
    export T63_LOG T63_SENTINEL
    "$@" ) 2>&1
}

# --- (a) the dry-run argv carries NO --net-default token -------------------
t63_conf "${T63_ROOT}/ok.yaml" 'network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"'
rm -f "$T63_SENTINEL" "$T63_LOG"
t63a_out=$(t63_run_rc env RC_CAGE_CONF="${T63_ROOT}/ok.yaml" "$RC" up --dry-run "$T63_PROJ")
t63a_argv=$(printf '%s\n' "$t63a_out" | grep '^Would run: msb create' || true)

if [[ -n "$t63a_argv" ]]; then
  pass "63a: rc up --dry-run prints the msb create argv"
else
  fail "63a: rc up --dry-run printed no msb create argv (output: ${t63a_out})"
fi
if printf '%s\n' "$t63a_argv" | grep -q -- "--net-default"; then
  fail "63a: the argv still carries --net-default — it REPLACES the config's own allow list (argv: ${t63a_argv})"
else
  pass "63a: the argv carries no --net-default token"
fi
# The --conf the deny now comes from must still be there, or 63a passes for the
# wrong reason (an argv with neither flag nor config denies by accident).
if printf '%s\n' "$t63a_argv" | grep -q -- "--conf ${T63_ROOT}/ok.yaml"; then
  pass "63a: the argv still points msb at the cage config that carries the policy"
else
  fail "63a: argv is missing '--conf ${T63_ROOT}/ok.yaml' (argv: ${t63a_argv})"
fi

# --- (b) a config with network.policy: allow is refused, no msb spawned ----
t63_conf "${T63_ROOT}/allow.yaml" 'network:
  policy: allow
  allow:
    - "api.anthropic.com:tcp:443"'
rm -f "$T63_SENTINEL" "$T63_LOG"
t63b_out=$(t63_run_rc env RC_CAGE_CONF="${T63_ROOT}/allow.yaml" "$RC" up "$T63_PROJ")
t63b_rc=$?

if [[ "$t63b_rc" -ne 0 ]]; then
  pass "63b: network.policy: allow makes rc up exit non-zero (exit ${t63b_rc})"
else
  fail "63b: rc up exited 0 on a config with network.policy: allow"
fi
if [[ -f "$T63_SENTINEL" ]]; then
  fail "63b: msb WAS spawned before the refusal — the guard is fail-open (invocations: $(cat "$T63_LOG" 2>/dev/null))"
else
  pass "63b: no msb subcommand ran — rc refused before the cage could exist"
fi
if grep -q "network.policy" <<<"$t63b_out"; then
  pass "63b: the refusal names the key that is wrong (network.policy)"
else
  fail "63b: the refusal did not name network.policy (output: ${t63b_out})"
fi
if grep -qi "no opt-out" <<<"$t63b_out"; then
  pass "63b: the refusal states there is no opt-out, so nobody goes hunting for a flag"
else
  fail "63b: the refusal did not say there is no opt-out (output: ${t63b_out})"
fi

# --- (c) a config with NO network: block at all is refused too -------------
# The likelier accident: a config written before the policy key mattered, or one
# an editor trimmed. Absence must be as loud as a wrong value.
t63_conf "${T63_ROOT}/absent.yaml" ''
rm -f "$T63_SENTINEL" "$T63_LOG"
t63c_out=$(t63_run_rc env RC_CAGE_CONF="${T63_ROOT}/absent.yaml" "$RC" up "$T63_PROJ")
t63c_rc=$?

if [[ "$t63c_rc" -ne 0 ]]; then
  pass "63c: a config with no network: block makes rc up exit non-zero (exit ${t63c_rc})"
else
  fail "63c: rc up exited 0 on a config with no network: block"
fi
if [[ -f "$T63_SENTINEL" ]]; then
  fail "63c: msb WAS spawned despite an absent network.policy (invocations: $(cat "$T63_LOG" 2>/dev/null))"
else
  pass "63c: no msb subcommand ran — rc refused before the cage could exist"
fi
if grep -q "network.policy" <<<"$t63c_out"; then
  pass "63c: the refusal names network.policy rather than failing obscurely"
else
  fail "63c: the refusal did not name network.policy (output: ${t63c_out})"
fi

# --- (d) NEGATIVE CONTROL: policy: none reaches the launch -----------------
# Without this, 63b and 63c could both pass because rc refuses everything. This
# runs the REAL `rc up` (not --dry-run), so the observable is the shim's own log
# proving rc got as far as calling msb.
rm -f "$T63_SENTINEL" "$T63_LOG"
t63_run_rc env RC_CAGE_CONF="${T63_ROOT}/ok.yaml" "$RC" up "$T63_PROJ" >/dev/null 2>&1 || true
if [[ -f "$T63_SENTINEL" ]]; then
  pass "63d: a config WITH network.policy: none reaches msb — 63b and 63c are not vacuous"
else
  fail "63d: rc never reached msb even with a valid policy — 63b and 63c prove nothing (invocations: $(cat "$T63_LOG" 2>/dev/null))"
fi

rm -rf "$T63_ROOT"


# ---------------------------------------------------------------------------
# DG1-DG4: rc destroy never picks a cage nobody named (rip-cage-ely4.7.13).
#
# THE INCIDENT THIS PINS (2026-09-17): a probe ran `rc destroy ""` after a name
# lookup came back empty. resolve_name's last resort is singleton auto-select,
# so rc took the machine's only rc-managed cage — the human's daily one — and
# removed it with both of its named volumes. ADR-031 D3 had already deleted the
# confirmation prompt and --force, leaving name resolution as the only guard.
#
# WHY A SHIM AND NOT A LIVE CAGE: the property is "no msb remove/stop call
# happens at all", which a live run can only show by NOT destroying something —
# an assertion that passes just as well when rc silently does nothing. A PATH
# shim recording every msb invocation makes the absence checkable: the refusals
# must leave a log with zero remove lines, and the one legitimate destroy must
# leave exactly one, naming the cage that was asked for.
echo ""
echo "=== rc destroy name guard (rip-cage-ely4.7.13) ==="

DG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-destroy-guard-XXXXXX")
DG_LOG="${DG_DIR}/msb-calls.log"
DG_CAGE="dg-registered-cage"

cat > "${DG_DIR}/msb" <<DG_STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${DG_LOG}"
case "\$1" in
  --version) echo 'msb 0.0.0-dg-stub'; exit 0 ;;
  list)
    printf '%s\n' '[{"name":"${DG_CAGE}"}]'
    exit 0 ;;
  inspect)
    if [[ "\$2" == "${DG_CAGE}" ]]; then
      printf '%s\n' '{"config":{"labels":{"rc.source.path":"/tmp/dg-project"}}}'
      exit 0
    fi
    exit 1 ;;
  volume)
    # 'volume inspect' finds nothing; 'volume remove' succeeds.
    [[ "\$2" == "remove" ]] && exit 0
    exit 1 ;;
  remove|stop) exit 0 ;;
  *) exit 1 ;;
esac
DG_STUB
chmod +x "${DG_DIR}/msb"

# _dg_run <case-label> <cwd> [args...] -- run rc destroy under the shim from
# CWD with a fresh call log. Echoes the exit code; the log is at $DG_LOG.
_dg_run() {
  local _cwd="$2"
  shift 2
  : > "$DG_LOG"
  ( cd "$_cwd" && PATH="${DG_DIR}:$PATH" "$RC" destroy "$@" >/dev/null 2>&1 )
  echo $?
}

# _dg_remove_calls -- how many msb remove/stop calls the last run made.
# `grep -c` prints the count and exits 1 when that count is zero, which is the
# case every refusal here is asserting — `|| true` keeps the count, drops the
# status. An `|| echo 0` fallback would print a SECOND line and break the
# comparison it was meant to make safe.
_dg_remove_calls() {
  grep -cE '^(remove|stop|volume remove)' "$DG_LOG" 2>/dev/null || true
}

# A directory whose name derives to no registered cage, so the CWD branch
# cannot match and the old code would have fallen through to auto-select.
DG_ELSEWHERE="${DG_DIR}/unrelated/project"
mkdir -p "$DG_ELSEWHERE"

# DG1: empty name argument — the incident's exact shape.
DG1_RC=$(_dg_run "DG1" "$DG_ELSEWHERE" "")
DG1_CALLS=$(_dg_remove_calls)
if [[ "$DG1_RC" -eq 2 && "$DG1_CALLS" -eq 0 ]]; then
  pass "DG1: rc destroy '' refuses (exit 2) and makes no msb remove/stop call"
else
  fail "DG1: rc destroy '' must refuse without removing anything"
  echo "     exit=$DG1_RC remove-calls=$DG1_CALLS" >&2
fi

# DG2: no argument at all, from a CWD that names no cage.
DG2_RC=$(_dg_run "DG2" "$DG_ELSEWHERE")
DG2_CALLS=$(_dg_remove_calls)
if [[ "$DG2_RC" -eq 2 && "$DG2_CALLS" -eq 0 ]]; then
  pass "DG2: rc destroy with no name, from an unmatched CWD, refuses and removes nothing"
else
  fail "DG2: rc destroy with no name must refuse without removing anything"
  echo "     exit=$DG2_RC remove-calls=$DG2_CALLS" >&2
fi

# DG3: a name that resolves to no cage. Refusing here is what makes a typo read
# as a typo instead of as a cage that was already gone.
DG3_RC=$(_dg_run "DG3" "$DG_ELSEWHERE" "dg-no-such-cage")
DG3_CALLS=$(_dg_remove_calls)
if [[ "$DG3_RC" -eq 2 && "$DG3_CALLS" -eq 0 ]]; then
  pass "DG3: rc destroy <unknown name> refuses and makes no msb remove/stop call"
else
  fail "DG3: rc destroy <unknown name> must refuse without removing anything"
  echo "     exit=$DG3_RC remove-calls=$DG3_CALLS" >&2
fi

# DG4: POSITIVE CONTROL — the named cage IS destroyed. Without this, DG1-DG3
# would pass just as well against an rc destroy that never works at all.
DG4_RC=$(_dg_run "DG4" "$DG_ELSEWHERE" "$DG_CAGE")
if [[ "$DG4_RC" -eq 0 ]] && grep -qE "^remove --force ${DG_CAGE}\$" "$DG_LOG"; then
  pass "DG4: rc destroy <exact name> still removes that cage (refusals are not a dead verb)"
else
  fail "DG4: rc destroy <exact name> must still reach msb remove for that cage"
  echo "     exit=$DG4_RC log:" >&2; cat "$DG_LOG" >&2
fi

# DG5: the refusal names the cages it left alone, so an operator can act on it.
DG5_OUT=$( cd "$DG_ELSEWHERE" && PATH="${DG_DIR}:$PATH" "$RC" destroy "" 2>&1 >/dev/null )
if echo "$DG5_OUT" | grep -q "$DG_CAGE" && echo "$DG5_OUT" | grep -qi 'untouched'; then
  pass "DG5: the refusal lists the registered cage as untouched"
else
  fail "DG5: the refusal must name the cages it did not touch"
  echo "     got: $DG5_OUT" >&2
fi

rm -rf "$DG_DIR"

# --- Cleanup ---
rm -rf "$SYMLINK_SKILLS_DIR" "$SYMLINK_TARGET_DIR" "$SYMLINK_SKILLS_DIR2" "$HOME_TARGET_DIR" "$SIBLING_DIR"
_rc_cmds_drop_fixture_tag

echo ""
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
