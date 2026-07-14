#!/usr/bin/env bash
# test-container-name.sh — regression tests for container_name() collision-hash
# disambiguation (rip-cage-a0h item (c)).
#
# The disambiguation logic already exists (rc:506-513 container_name,
# rc:~4594-4618 the cmd_up disambiguation block) — this file only ADDS the
# missing regression test proving:
#   T1  Two paths with identical parent/basename both derive the SAME base
#       name from container_name() (the collision precondition).
#   T2  When a sandbox named after that base already exists (per an msb
#       PATH-shim `rc.source.path` label) for a DIFFERENT path, resolving a
#       second, colliding project fires disambiguation: the resulting name
#       gets a `-<4char-hash>` suffix and is DISTINCT from the first
#       project's name. Driven through the REAL `rc up --dry-run --output
#       json` path (not a reimplementation) via a docker+msb PATH-shim mock
#       — precedent: tests/test-image-drift-resume.sh.
#   T3  The resulting rc-state-<name> / rc-history-<name> volume mount args
#       (as produced by the REAL _up_prepare_docker_mounts) are distinct for
#       the two projects' names.
#
# Host-only: no real docker/msb daemon or sandboxes — driven entirely
# through the docker+msb PATH-shims + sourced rc functions. Registered in
# tests/run-host.sh alongside test-bd-host-preflight.sh / test-symlink-
# follow.sh.
#
# rip-cage-5iti (S10, msb migration test-suite port): T2's collision lookup
# (existing_path=$(_msb_label "$name" "rc.source.path")) was rewritten onto
# msb by rip-cage-rj68 (S6) -- it now reads `msb inspect NAME --format
# json`, not `docker inspect --format`. The docker stub still covers the
# (unchanged, still-docker-side) image-provisioning check
# (`docker image inspect $IMAGE`); an msb stub was added alongside it for
# the collision-lookup + `msb image list` provisioning check.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_HOME=""
STUB_DIR=""

pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2 -- $3"; FAILURES=$((FAILURES + 1)); }

# tests/run-host.sh exports RC_CONFIG_GLOBAL at driver level, which would
# shadow the per-test XDG sandboxes below — unset so per-call XDG_CONFIG_HOME
# wins (mirrors test-image-drift-resume.sh / test-credential-mounts.sh).
unset RC_CONFIG_GLOBAL

# shellcheck disable=SC2329
cleanup() {
  [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  [[ -n "${STUB_DIR:-}" && -d "${STUB_DIR:-}" ]] && rm -rf "$STUB_DIR"
  return 0
}
trap cleanup EXIT

# The real RC_VERSION baked into rc (read from VERSION file at SCRIPT_DIR).
# The docker stub echoes this back for the image-version-label inspect so
# _image_is_current() succeeds and cmd_up doesn't divert into the
# would_pull/would_build dry-run branch (which omits name/name_disambiguated).
RC_VERSION_VAL=$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "unknown")

# ---------------------------------------------------------------------------
# Fake docker: minimal stub covering exactly what cmd_up's dry-run path needs
# before reaching the JSON output — image-current check + rc.source.path
# collision lookup + State.Status (always "not found", i.e. fresh container).
# Configured via env vars read at RUNTIME:
#   CN_EXISTING_NAME   the (undisambiguated) container name that already
#                       "exists" (per the docker mock)
#   CN_EXISTING_PATH   the rc.source.path label value that container carries
# ---------------------------------------------------------------------------
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-cn-stub-XXXXXX")
cat > "${STUB_DIR}/docker" <<STUB
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  image)
    shift
    if [[ "\${1:-}" == "inspect" ]]; then
      shift
      _fmt=""
      while [[ \$# -gt 0 ]]; do
        case "\$1" in
          --format) shift; _fmt="\${1:-}"; shift ;;
          *) shift ;;
        esac
      done
      case "\$_fmt" in
        *org.opencontainers.image.version*) echo "${RC_VERSION_VAL}"; exit 0 ;;
        *) exit 0 ;;
      esac
    fi
    exit 0
    ;;
  inspect)
    shift
    _fmt="" _name=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --format) shift; _fmt="\${1:-}"; shift ;;
        *) _name="\$1"; shift ;;
      esac
    done
    case "\$_fmt" in
      *rc.source.path*)
        if [[ "\$_name" == "\${CN_EXISTING_NAME:-}" ]]; then
          echo "\${CN_EXISTING_PATH:-}"
          exit 0
        fi
        exit 1
        ;;
      '{{.State.Status}}')
        exit 1
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/docker"

# Fake msb: covers the msb-side collision lookup (_msb_label, backed by
# `msb inspect NAME --format json`) + the msb-local-image-presence check
# (`msb image list --format json`) cmd_up's provisioning check ORs against
# the docker-side check above.
cat > "${STUB_DIR}/msb" <<'STUB'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  image)
    if [[ "${2:-}" == "list" ]]; then
      echo '[{"reference":"rip-cage:latest","digest":"sha256:0000000000000000000000000000000000000000000000000000000000fa"}]'
      exit 0
    fi
    exit 1
    ;;
  inspect)
    _name="${2:-}"
    if [[ "$_name" == "${CN_EXISTING_NAME:-}" ]]; then
      printf '{"status":"Stopped","config":{"manifest_digest":"","labels":{"rc.source.path":"%s"}}}' "${CN_EXISTING_PATH:-}"
      exit 0
    fi
    exit 1
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/msb"

# Build a minimal sandbox: global config (ADR-023 preflight requires one) +
# empty tools.yaml (default bundled stack). Sets TEST_HOME. Two workspace
# dirs (A, B) with IDENTICAL parent-basename/basename ("proj"/"foo") but
# DIFFERENT full paths — the collision precondition.
setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-cn-test-XXXXXX")
  mkdir -p "${TEST_HOME}/.config/rip-cage"
  cat > "${TEST_HOME}/.config/rip-cage/config.yaml" <<'YAML'
version: 2
mounts:
  denylist: []
  allow_risky: null
YAML
  touch "${TEST_HOME}/.config/rip-cage/tools.yaml"
  WS_A="${TEST_HOME}/teamA/proj/foo"
  WS_B="${TEST_HOME}/teamB/proj/foo"
  mkdir -p "$WS_A" "$WS_B"
}

teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" WS_A="" WS_B=""
}

# ===========================================================================
# T1 — container_name() collision precondition: two paths with identical
# parent/basename both derive the SAME base name.
# ===========================================================================
test_t1_collision_precondition() {
  setup_sandbox

  local name_a name_b
  name_a=$(HOME="$TEST_HOME" bash -c "source '$RC'; container_name '$WS_A'")
  name_b=$(HOME="$TEST_HOME" bash -c "source '$RC'; container_name '$WS_B'")

  if [[ -n "$name_a" && "$name_a" == "$name_b" && "$name_a" == "proj-foo" ]]; then
    pass "T1" "container_name() derives identical base name ('$name_a') for both colliding paths"
  else
    fail "T1" "container_name collision precondition" "name_a=$name_a name_b=$name_b (expected both = proj-foo)"
  fi

  teardown_sandbox
}

# ===========================================================================
# T2 — disambiguation fires via the REAL `rc up --dry-run --output json`
# path when project B's derived name collides with an existing container
# whose rc.source.path label belongs to project A.
# ===========================================================================
NAME_B_DISAMBIGUATED=""  # populated for T3 to reuse

test_t2_disambiguation_fires() {
  setup_sandbox

  local base_name
  base_name="proj-foo"

  local out exit_code=0
  out=$(PATH="${STUB_DIR}:${PATH}" \
    HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" \
    RC_ALLOWED_ROOTS="$WS_B" \
    CN_EXISTING_NAME="$base_name" CN_EXISTING_PATH="$WS_A" \
    "$RC" --output json --dry-run up "$WS_B" 2>&1) || exit_code=$?

  local json_line name name_disambiguated
  json_line=$(echo "$out" | grep -m1 '^{' || true)
  name=$(echo "$json_line" | jq -r '.name // empty' 2>/dev/null)
  name_disambiguated=$(echo "$json_line" | jq -r '.name_disambiguated // empty' 2>/dev/null)

  if [[ "$exit_code" -eq 0 \
     && "$name_disambiguated" == "true" \
     && -n "$name" \
     && "$name" != "$base_name" \
     && "$name" == "${base_name}-"* ]]; then
    pass "T2" "collision fires disambiguation: name='$name' (base='$base_name'), name_disambiguated=true"
    NAME_B_DISAMBIGUATED="$name"
  else
    fail "T2" "disambiguation should fire with -<hash> suffix, distinct from base name" \
      "exit=$exit_code name=$name name_disambiguated=$name_disambiguated out=$out"
  fi

  teardown_sandbox
}

# ===========================================================================
# T3 — the resulting rc-state-<name> / rc-history-<name> volume mount args
# (as produced by the REAL _up_prepare_docker_mounts) are distinct for
# project A's name ("proj-foo") and project B's disambiguated name (from T2).
# ===========================================================================
test_t3_distinct_state_history_volumes() {
  if [[ -z "$NAME_B_DISAMBIGUATED" ]]; then
    fail "T3" "distinct rc-state-*/rc-history-* volumes" "skipped: T2 did not produce a disambiguated name"
    return
  fi

  setup_sandbox

  local name_a="proj-foo"
  local name_b="$NAME_B_DISAMBIGUATED"

  local mounts_a mounts_b
  mounts_a=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$WS_A' '$name_a'
    _prev=''
    for a in \"\${_UP_RUN_ARGS[@]}\"; do
      [[ \"\$_prev\" == '-v' ]] && echo \"MOUNT: \$a\"
      _prev=\"\$a\"
    done
  " 2>/dev/null)
  mounts_b=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" bash -c "
    source '$RC'
    _UP_RUN_ARGS=()
    wt_detected=false
    _up_prepare_docker_mounts '$WS_B' '$name_b'
    _prev=''
    for a in \"\${_UP_RUN_ARGS[@]}\"; do
      [[ \"\$_prev\" == '-v' ]] && echo \"MOUNT: \$a\"
      _prev=\"\$a\"
    done
  " 2>/dev/null)

  local state_a state_b history_a history_b
  state_a=$(echo "$mounts_a" | grep -c "rc-state-${name_a}:" || true)
  state_b=$(echo "$mounts_b" | grep -c "rc-state-${name_b}:" || true)
  history_a=$(echo "$mounts_a" | grep -c "rc-history-${name_a}:" || true)
  history_b=$(echo "$mounts_b" | grep -c "rc-history-${name_b}:" || true)

  local cross_a cross_b
  cross_a=$(echo "$mounts_a" | grep -c "rc-state-${name_b}:" || true)
  cross_b=$(echo "$mounts_b" | grep -c "rc-state-${name_a}:" || true)

  if [[ "$state_a" -gt 0 && "$state_b" -gt 0 && "$history_a" -gt 0 && "$history_b" -gt 0 \
     && "$cross_a" -eq 0 && "$cross_b" -eq 0 && "$name_a" != "$name_b" ]]; then
    pass "T3" "rc-state-*/rc-history-* volumes distinct: A='rc-state-${name_a}' B='rc-state-${name_b}'"
  else
    fail "T3" "distinct rc-state-*/rc-history-* volumes" \
      "name_a=$name_a name_b=$name_b state_a=$state_a state_b=$state_b history_a=$history_a history_b=$history_b mounts_a=$mounts_a mounts_b=$mounts_b"
  fi

  teardown_sandbox
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-container-name.sh — container_name() collision-hash disambiguation regression ==="
test_t1_collision_precondition
test_t2_disambiguation_fires
test_t3_distinct_state_history_volumes

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
