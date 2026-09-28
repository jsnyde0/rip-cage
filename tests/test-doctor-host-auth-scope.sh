#!/usr/bin/env bash
# tests/test-doctor-host-auth-scope.sh -- unit tests for `rc doctor`'s
# host_auth probe scoping (rip-cage-ely4.7.17 fix round 3, finding 3):
# _doctor_format_host_auth_probe NAME (cli/doctor.sh) must compute the
# host-side CCTOK verdict ONLY when NAME's own cage config declares the
# CCTOK secret -- an ANTHROPIC_API_KEY cage (no secrets: block at all) has no
# CCTOK file by design, and must read `n/a`, never `FAIL`.
#
# `msb` is stubbed via a PATH shim -- host-only, no live cage required, same
# idiom as tests/test-doctor-transcript-persistence.sh /
# tests/test-doctor-dead-mount.sh. This file's subshell sources
# cli/lib/msb_runtime.sh (defines _msb_label, which the probe reads the
# `rc.cage-conf` label through) and cli/auth.sh (defines _auth_cctok_check /
# _auth_cctok_file / _auth_cctok_fail_message, which the probe falls through
# to once a CCTOK declaration is confirmed) directly, and awk-extracts just
# _doctor_format_host_auth_probe from cli/doctor.sh.
#
# Coverage:
#   H1  cage config has no `secrets:` block at all (plain ANTHROPIC_API_KEY
#       cage) -> n/a, never FAIL, even though the host has no CCTOK file.
#   H2  cage config declares `secrets: CCTOK` and the host has no valid
#       CCTOK file -> FAIL (the real refusal case, unaffected by this fix).
#   H3  cage config declares `secrets: CCTOK` and the host DOES have a valid
#       CCTOK file -> OK (negative control -- proves H1 is real scoping, not
#       the probe always reading n/a).
#   H4  `rc.cage-conf` label absent entirely (legacy cage / msb inspect ok but
#       no label) -> n/a (can't affirmatively show a CCTOK declaration).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/cli/doctor.sh"
MSB_LIB="${REPO_ROOT}/cli/lib/msb_runtime.sh"
AUTH_LIB="${REPO_ROOT}/cli/auth.sh"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1 -- $2"; }

echo "=== test-doctor-host-auth-scope.sh ==="
echo ""

extract_probe() {
  awk '
    /^_doctor_format_host_auth_probe\(\)/ { found=1 }
    found { print }
    found && /^\}$/ { exit }
  ' "$RC"
}

DUMMY_TOKEN="sk-ant-oatodJFCrnl2edlBDdz1C5Jau2RJtBRnlWmTSHf6pWkLUyifDLkDmWJ6UuVTAIjvFu7WICPhDeOZIiBOB-Y6sHrFH2ZUCr-lgotu2iX"

_stub_msb_for_label() {
  local _dir="$1" _label_json="$2"
  cat > "${_dir}/msb" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" inspect "*) echo '${_label_json}'; exit 0 ;;
  *) echo "stub: unhandled args: \$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "${_dir}/msb"
}

# ---------------------------------------------------------------------------
# H1: no secrets: block at all -> n/a, never FAIL.
# ---------------------------------------------------------------------------
echo "-- H1: config declares no secrets block -- n/a, not FAIL --"
H1_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-dhas-h1-home-XXXXXX")
H1_XDG="${H1_HOME}/.config"
mkdir -p "$H1_XDG"
H1_CONF="${H1_HOME}/cage.yaml"
cat > "$H1_CONF" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${H1_HOME}/proj:/workspace"
env:
  ANTHROPIC_API_KEY: "\$MSB_ANTHROPIC_API_KEY"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CONF
H1_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dhas-h1-stub-XXXXXX")
_stub_msb_for_label "$H1_STUB_DIR" "{\"status\":\"Running\",\"config\":{\"labels\":{\"rc.cage-conf\":\"${H1_CONF}\"}}}"

H1_OUT=$(HOME="$H1_HOME" XDG_CONFIG_HOME="$H1_XDG" PATH="${H1_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  source '$AUTH_LIB'
  $(extract_probe)
  _doctor_format_host_auth_probe 'h1-cage'
")
if [[ "$H1_OUT" == n/a* ]]; then
  pass "H1a no secrets: block -> n/a"
else
  fail "H1a no secrets: block -> n/a" "got: $H1_OUT"
fi
if [[ "$H1_OUT" != FAIL* ]]; then
  pass "H1b never FAIL for an ANTHROPIC_API_KEY cage"
else
  fail "H1b never FAIL for an ANTHROPIC_API_KEY cage" "got: $H1_OUT"
fi
rm -rf "$H1_HOME" "$H1_STUB_DIR"

# ---------------------------------------------------------------------------
# H2: declares CCTOK, host has no valid file -> FAIL (unaffected by the fix).
# ---------------------------------------------------------------------------
echo ""
echo "-- H2: config declares secrets: CCTOK, host has no token -- FAIL --"
H2_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-dhas-h2-home-XXXXXX")
H2_XDG="${H2_HOME}/.config"
mkdir -p "$H2_XDG"
H2_CONF="${H2_HOME}/cage.yaml"
cat > "$H2_CONF" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${H2_HOME}/proj:/workspace"
secrets:
  CCTOK:
    allow:
      - "api.anthropic.com"
env:
  CLAUDE_CODE_OAUTH_TOKEN: "\$MSB_CCTOK"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CONF
H2_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dhas-h2-stub-XXXXXX")
_stub_msb_for_label "$H2_STUB_DIR" "{\"status\":\"Running\",\"config\":{\"labels\":{\"rc.cage-conf\":\"${H2_CONF}\"}}}"

H2_OUT=$(HOME="$H2_HOME" XDG_CONFIG_HOME="$H2_XDG" PATH="${H2_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  source '$AUTH_LIB'
  $(extract_probe)
  _doctor_format_host_auth_probe 'h2-cage'
")
if [[ "$H2_OUT" == FAIL* ]]; then
  pass "H2 declares CCTOK, no host file -> FAIL"
else
  fail "H2 declares CCTOK, no host file -> FAIL" "got: $H2_OUT"
fi
rm -rf "$H2_HOME" "$H2_STUB_DIR"

# ---------------------------------------------------------------------------
# H3: declares CCTOK, host has a valid file -> OK (negative control for H1).
# ---------------------------------------------------------------------------
echo ""
echo "-- H3: config declares secrets: CCTOK, host has a valid token -- OK --"
H3_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-dhas-h3-home-XXXXXX")
H3_XDG="${H3_HOME}/.config"
mkdir -p "${H3_XDG}/rip-cage/secrets"
printf '%s' "$DUMMY_TOKEN" > "${H3_XDG}/rip-cage/secrets/CCTOK"
chmod 600 "${H3_XDG}/rip-cage/secrets/CCTOK"
H3_CONF="${H3_HOME}/cage.yaml"
cp "$H2_CONF" "$H3_CONF" 2>/dev/null || cat > "$H3_CONF" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${H3_HOME}/proj:/workspace"
secrets:
  CCTOK:
    allow:
      - "api.anthropic.com"
env:
  CLAUDE_CODE_OAUTH_TOKEN: "\$MSB_CCTOK"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CONF
H3_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dhas-h3-stub-XXXXXX")
_stub_msb_for_label "$H3_STUB_DIR" "{\"status\":\"Running\",\"config\":{\"labels\":{\"rc.cage-conf\":\"${H3_CONF}\"}}}"

H3_OUT=$(HOME="$H3_HOME" XDG_CONFIG_HOME="$H3_XDG" PATH="${H3_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  source '$AUTH_LIB'
  $(extract_probe)
  _doctor_format_host_auth_probe 'h3-cage'
")
if [[ "$H3_OUT" == OK* ]]; then
  pass "H3 declares CCTOK, valid host file -> OK (proves H1 is real scoping)"
else
  fail "H3 declares CCTOK, valid host file -> OK" "got: $H3_OUT"
fi
if echo "$H3_OUT" | grep -qF "$DUMMY_TOKEN"; then
  fail "H3 the token value leaked into the probe output" "got: $H3_OUT"
else
  pass "H3 the token value never appears in the probe output"
fi
rm -rf "$H3_HOME" "$H3_STUB_DIR"

# ---------------------------------------------------------------------------
# H4: rc.cage-conf label absent entirely (legacy cage) -> n/a.
# ---------------------------------------------------------------------------
echo ""
echo "-- H4: no rc.cage-conf label at all -- n/a --"
H4_STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-dhas-h4-stub-XXXXXX")
_stub_msb_for_label "$H4_STUB_DIR" '{"status":"Running","config":{"labels":{}}}'

H4_OUT=$(PATH="${H4_STUB_DIR}:$PATH" bash -c "
  source '$MSB_LIB'
  source '$AUTH_LIB'
  $(extract_probe)
  _doctor_format_host_auth_probe 'h4-cage'
")
if [[ "$H4_OUT" == n/a* ]]; then
  pass "H4 no rc.cage-conf label -> n/a"
else
  fail "H4 no rc.cage-conf label -> n/a" "got: $H4_OUT"
fi
rm -rf "$H4_STUB_DIR"

echo ""
echo "======================================"
if [[ $FAILURES -eq 0 ]]; then
  echo "ALL TESTS PASSED ($TOTAL total)"
  exit 0
else
  echo "$FAILURES/$TOTAL TEST(S) FAILED"
  exit 1
fi
