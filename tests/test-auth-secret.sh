#!/usr/bin/env bash
set -uo pipefail

# tests/test-auth-secret.sh -- host-tier tests for the msb --secret CCTOK
# non-possession bridge (rip-cage-ely4.7.17). The keychain -> mounted
# ~/.claude/.credentials.json possession path is retired, no fallback
# (ADR-031 D1/D5(a)); `rc auth` and the `rc up` pre-check are the only
# surfaces left, and this file is their host-tier proof.
#
# No container is booted here -- `rc auth` never touches msb/docker at all.
#
# EVERY `rc up` call in this file, --dry-run included, runs with FAKE docker
# + msb on PATH (see _fake_runtime_bin below, same call-logged-shim idiom as
# tests/test-build-msb-load.sh). This file never reaches the real docker or
# msb binary for anything beyond the read-only image-identity captures the
# fix-round harness itself takes at start/end.
#
# WHY --dry-run ALSO needs fakes, not just the non-dry-run case: `rc up
# --dry-run` is NOT side-effect-free with real binaries. cli/up.sh's
# image-present branch runs the docker->msb layer-drift resync
# (_build_msb_load: docker save + msb load --tag of the image,
# rip-cage-7bs3/rip-cage-0v47) BEFORE the --dry-run exit -- it sits in the
# same before-any-`msb create` block as the CCTOK gate below, not behind the
# dry-run check. On 2026-09-28 this file's --dry-run cases (e)/(f2), run
# against the real binaries, rewrote the operator's msb `rip-cage:latest`
# cache this way (fix round 2 INCIDENT, brain:rip-cage). check_docker/
# check_msb (`docker info` / `msb --version`) also ran for real up to that
# point; the fakes satisfy those too, so no verb this file exercises ever
# reaches a real binary.
#
# Test (f) is the one NON-dry-run `rc up` in this file, and it is the one an
# earlier round ran from a git worktree of HEAD, where the CCTOK gate did not
# yet exist -- the real `rc up` fell through to the image-provisioning path
# and pulled+tagged+msb-loaded a real image (INCIDENT 2026-09-28, brain:
# rip-cage). Fix: (f), and now (e)/(f2) too, put FAKE docker + msb on PATH
# so check_docker/check_msb still pass (they only need `docker info` / `msb
# --version` to exit 0), the fake's empty-stdout answers make the
# image/container-presence probes read "absent" (so the dry-run's
# image-present-only resync branch is never entered), and each case's call
# log is asserted to hold NO pull/tag/save/load/create call from either
# binary -- side-effect-free no matter which gate runs first or is later
# removed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# A dummy setup-token-shaped value: "sk-ant-oat" + 100 chars from
# [A-Za-z0-9_-] = 110 total, comfortably above _AUTH_CCTOK_MIN_LEN (80,
# cli/auth.sh) and below a real token's observed ~118. Never a real token --
# this repo never reads a real one but for a human-seeded file outside every
# test tree (RULING 2026-09-28 point 4 on the parent bead).
DUMMY_TOKEN="sk-ant-oatodJFCrnl2edlBDdz1C5Jau2RJtBRnlWmTSHf6pWkLUyifDLkDmWJ6UuVTAIjvFu7WICPhDeOZIiBOB-Y6sHrFH2ZUCr-lgotu2iX"

# _link_real_docker <scratch-home> -- give a scratch HOME the real docker
# CLI context (so `docker info` still resolves OrbStack/Desktop) without
# giving it anything else real (same idiom as tests/test-e2e-lifecycle.sh).
REAL_DOCKER_CFG="${HOME}/.docker"
_link_real_docker() {
  [[ -e "$REAL_DOCKER_CFG" ]] || return 0
  ln -sfn "$REAL_DOCKER_CFG" "${1}/.docker" 2>/dev/null || true
}

# _fake_runtime_bin -- create a scratch PATH dir carrying fake `docker` and
# `msb` executables. Each answers only its own preflight probe (`docker
# info`, `msb --version`) with exit 0; every invocation -- preflight or
# otherwise -- is appended to $1 (the call-log file) as "docker <args>" or
# "msb <args>", one line per call, so a caller can assert on exactly what was
# invoked. Echoes the bin dir.
_fake_runtime_bin() {
  local _log="$1" _bin
  _bin=$(mktemp -d /private/tmp/rc-auth-secret-fakebin-XXXXXX)
  cat > "${_bin}/docker" <<FAKEEOF
#!/usr/bin/env bash
echo "docker \$*" >> "${_log}"
case "\${1:-}" in
  info) exit 0 ;;
  *) exit 0 ;;
esac
FAKEEOF
  chmod +x "${_bin}/docker"
  cat > "${_bin}/msb" <<FAKEEOF
#!/usr/bin/env bash
echo "msb \$*" >> "${_log}"
case "\${1:-}" in
  --version) exit 0 ;;
  *) exit 0 ;;
esac
FAKEEOF
  chmod +x "${_bin}/msb"
  printf '%s\n' "${_bin}"
}

# _fresh_home -- a scratch HOME + XDG_CONFIG_HOME pair, isolated from the
# real ~/.claude, ~/.config/rip-cage and the real keychain (never read; this
# suite has no code path left that would even try).
_fresh_home() {
  local _h
  # /private/tmp, never /tmp: msb does not follow a host-side symlink in a
  # bind source, and on macOS /tmp IS a symlink to /private/tmp (measured,
  # msb 0.6.18, spike rip-cage-ely4.16). rc up's mount-side floor resolves
  # paths before this matters for --dry-run too, so stay consistent.
  _h=$(mktemp -d /private/tmp/rc-auth-secret-XXXXXX)
  _link_real_docker "$_h"
  printf '%s\n' "$_h"
}

_cctok_file() {
  echo "${1}/.config/rip-cage/secrets/CCTOK"
}

# _write_cctok <home> <mode> <value> -- seed the secrets/CCTOK file.
_write_cctok() {
  local _home="$1" _mode="$2" _value="$3" _file
  _file=$(_cctok_file "$_home")
  mkdir -p "$(dirname "$_file")"
  printf '%s' "$_value" > "$_file"
  chmod "$_mode" "$_file"
}

# _cctok_conf <home> <proj> -- a minimal-but-real cage config declaring the
# CCTOK secret exactly as the shipped template does (share/rip-cage/cage.yaml.template).
_cctok_conf() {
  local _home="$1" _proj="$2" _conf="${1}/cage.yaml"
  cat > "$_conf" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${_proj}:/workspace"
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
  printf '%s\n' "$_conf"
}

# _plain_conf <home> <proj> -- a minimal-but-real cage config with NO secrets
# block at all (the common case: rc up must never look for CCTOK here).
_plain_conf() {
  local _proj="$2" _conf="${1}/cage.yaml"
  cat > "$_conf" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${_proj}:/workspace"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CONF
  printf '%s\n' "$_conf"
}

# =============================================================================
# (a) rc auth, no file at all -> non-zero, stderr names the path + setup-token
# =============================================================================
echo "=== Test (a): rc auth with no CCTOK file ==="
HOME_A=$(_fresh_home)
out_a=$(HOME="$HOME_A" XDG_CONFIG_HOME="${HOME_A}/.config" bash "$RC" auth 2>&1)
rc_a=$?
if [[ $rc_a -ne 0 ]]; then
  pass "(a) rc auth exits non-zero with no CCTOK file"
else
  fail "(a) rc auth exited 0 with no CCTOK file"
fi
if echo "$out_a" | grep -qF "$(_cctok_file "$HOME_A")"; then
  pass "(a) stderr names the exact CCTOK file path"
else
  fail "(a) stderr did not name the CCTOK file path: $out_a"
fi
if echo "$out_a" | grep -q "claude setup-token"; then
  pass "(a) stderr names the one-time 'claude setup-token' step"
else
  fail "(a) stderr did not mention 'claude setup-token': $out_a"
fi
# rip-cage-ely4.7.17 fix round 1, finding 3: an ANTHROPIC_API_KEY user gets
# told how to opt out of the CCTOK gate entirely, not just how to satisfy it.
if echo "$out_a" | grep -q "ANTHROPIC_API_KEY" && echo "$out_a" | grep -q "secrets: CCTOK"; then
  pass "(a) stderr tells an ANTHROPIC_API_KEY user how to delete the CCTOK block instead"
else
  fail "(a) stderr did not mention the ANTHROPIC_API_KEY escape hatch: $out_a"
fi
rm -rf "$HOME_A"

# =============================================================================
# (b) rc auth, 0644 file -> fails naming chmod 600
# =============================================================================
echo ""
echo "=== Test (b): rc auth with a 0644 CCTOK file ==="
HOME_B=$(_fresh_home)
_write_cctok "$HOME_B" 644 "$DUMMY_TOKEN"
out_b=$(HOME="$HOME_B" XDG_CONFIG_HOME="${HOME_B}/.config" bash "$RC" auth 2>&1)
rc_b=$?
if [[ $rc_b -ne 0 ]]; then
  pass "(b) rc auth exits non-zero on a 0644 file"
else
  fail "(b) rc auth exited 0 on a 0644 file"
fi
if echo "$out_b" | grep -q "chmod 600"; then
  pass "(b) stderr names the 'chmod 600' fix"
else
  fail "(b) stderr did not mention 'chmod 600': $out_b"
fi
if echo "$out_b" | grep -q "$DUMMY_TOKEN"; then
  fail "(b) the token value leaked into output"
else
  pass "(b) the token value never appears in output"
fi
rm -rf "$HOME_B"

# =============================================================================
# (c) rc auth, 0600 but malformed value -> fails
# =============================================================================
echo ""
echo "=== Test (c): rc auth with a malformed 0600 CCTOK value ==="
HOME_C=$(_fresh_home)
_write_cctok "$HOME_C" 600 "not-a-real-token"
out_c=$(HOME="$HOME_C" XDG_CONFIG_HOME="${HOME_C}/.config" bash "$RC" auth 2>&1)
rc_c=$?
if [[ $rc_c -ne 0 ]]; then
  pass "(c) rc auth exits non-zero on a malformed value"
else
  fail "(c) rc auth exited 0 on a malformed value"
fi
if echo "$out_c" | grep -qi "setup-token-shaped\|malformed\|does not hold"; then
  pass "(c) stderr names the shape problem"
else
  fail "(c) stderr did not describe the shape problem: $out_c"
fi
rm -rf "$HOME_C"

# Also cover: multi-line value is malformed (embedded newline, not just a
# trailing one -- $(...) already strips a single trailing newline).
echo ""
echo "=== Test (c2): rc auth with a multi-line CCTOK value ==="
HOME_C2=$(_fresh_home)
_write_cctok "$HOME_C2" 600 "${DUMMY_TOKEN}
second-line"
HOME="$HOME_C2" XDG_CONFIG_HOME="${HOME_C2}/.config" bash "$RC" auth >/dev/null 2>&1
rc_c2=$?
if [[ $rc_c2 -ne 0 ]]; then
  pass "(c2) rc auth exits non-zero on a multi-line value"
else
  fail "(c2) rc auth exited 0 on a multi-line value"
fi
rm -rf "$HOME_C2"

# =============================================================================
# (c3)-(c6) shape-check mutation coverage (rip-cage-ely4.7.17 fix round 1,
# finding 2): each of (c3)-(c5) breaks exactly ONE of the three shape rules
# in cli/auth.sh:_auth_cctok_check (prefix / charset / length floor) while
# holding the other two valid, so each test is falsified by exactly one
# rule. (c6) is the positive control for the fourth clause -- a trailing
# newline is TOLERATED, not a shape violation.
# =============================================================================

# (c3) wrong prefix, otherwise a long, all-valid-charset value -- breaks
# ONLY the "sk-ant-oat" prefix rule.
echo ""
echo "=== Test (c3): right charset and length, WRONG prefix -> malformed ==="
HOME_C3=$(_fresh_home)
_write_cctok "$HOME_C3" 600 "sk-ant-xatPtYgjmUhBel31iEl2hpChYgCfrL1spNxnyVmihA-2O76UMFxFkM-R5Kjp1vRt_1fjORS-6ilI8ihN5KXSc7Tvo-hBKqFYY-kv5ZJ"
out_c3=$(HOME="$HOME_C3" XDG_CONFIG_HOME="${HOME_C3}/.config" bash "$RC" auth 2>&1)
rc_c3=$?
if [[ $rc_c3 -ne 0 ]]; then
  pass "(c3) rc auth exits non-zero on a wrong-prefix value"
else
  fail "(c3) rc auth exited 0 on a wrong-prefix value"
fi
if echo "$out_c3" | grep -qi "malformed\|does not hold"; then
  pass "(c3) stderr names the shape problem"
else
  fail "(c3) stderr did not describe the shape problem: $out_c3"
fi
rm -rf "$HOME_C3"

# (c4) right prefix, valid charset, but only 40 characters total -- breaks
# ONLY the length-floor rule (_AUTH_CCTOK_MIN_LEN=80, cli/auth.sh).
echo ""
echo "=== Test (c4): right prefix and charset, TOO SHORT -> malformed ==="
HOME_C4=$(_fresh_home)
_write_cctok "$HOME_C4" 600 "sk-ant-oatPtYgjmUhBel31iEl2hpChYgCfrL1sp"
out_c4=$(HOME="$HOME_C4" XDG_CONFIG_HOME="${HOME_C4}/.config" bash "$RC" auth 2>&1)
rc_c4=$?
if [[ $rc_c4 -ne 0 ]]; then
  pass "(c4) rc auth exits non-zero on a too-short value"
else
  fail "(c4) rc auth exited 0 on a too-short value"
fi
if echo "$out_c4" | grep -qi "malformed\|does not hold"; then
  pass "(c4) stderr names the shape problem"
else
  fail "(c4) stderr did not describe the shape problem: $out_c4"
fi
rm -rf "$HOME_C4"

# (c5) right prefix, long enough, but the body contains '/' and ':' (a
# pasted URL) -- breaks ONLY the [A-Za-z0-9_-] charset rule.
echo ""
echo "=== Test (c5): right prefix and length, contains '/' and ':' -> malformed ==="
HOME_C5=$(_fresh_home)
_write_cctok "$HOME_C5" 600 "sk-ant-oathttps://example.com/path:1234/PtYgjmUhBel31iEl2hpChYgCfrL1spNxnyVmihA-2O76UMFxFkM-R5Kjp1vR"
out_c5=$(HOME="$HOME_C5" XDG_CONFIG_HOME="${HOME_C5}/.config" bash "$RC" auth 2>&1)
rc_c5=$?
if [[ $rc_c5 -ne 0 ]]; then
  pass "(c5) rc auth exits non-zero on a value containing '/' and ':'"
else
  fail "(c5) rc auth exited 0 on a value containing '/' and ':'"
fi
if echo "$out_c5" | grep -qi "malformed\|does not hold"; then
  pass "(c5) stderr names the shape problem"
else
  fail "(c5) stderr did not describe the shape problem: $out_c5"
fi
rm -rf "$HOME_C5"

# (c6) positive control: a WELL-SHAPED value with one trailing newline byte
# in the file (e.g. `echo "$TOKEN" > file` instead of `printf '%s'`) is
# TOLERATED, not malformed -- $(cat) already strips exactly one trailing
# newline before _auth_cctok_check ever sees the value.
echo ""
echo "=== Test (c6): well-shaped value with a trailing newline -> still valid ==="
HOME_C6=$(_fresh_home)
CCTOK_C6=$(_cctok_file "$HOME_C6")
mkdir -p "$(dirname "$CCTOK_C6")"
printf '%s\n' "$DUMMY_TOKEN" > "$CCTOK_C6"
chmod 600 "$CCTOK_C6"
out_c6=$(HOME="$HOME_C6" XDG_CONFIG_HOME="${HOME_C6}/.config" bash "$RC" auth 2>&1)
rc_c6=$?
if [[ $rc_c6 -eq 0 ]]; then
  pass "(c6) rc auth exits 0 on a well-shaped value with a trailing newline"
else
  fail "(c6) rc auth exited $rc_c6 on a well-shaped value with a trailing newline: $out_c6"
fi
rm -rf "$HOME_C6"

# =============================================================================
# (d) rc auth, 0600 well-shaped -> exits 0; token value never on stdout/stderr
# =============================================================================
echo ""
echo "=== Test (d): rc auth with a well-shaped 0600 CCTOK file ==="
HOME_D=$(_fresh_home)
_write_cctok "$HOME_D" 600 "$DUMMY_TOKEN"
out_d=$(HOME="$HOME_D" XDG_CONFIG_HOME="${HOME_D}/.config" bash "$RC" auth 2>&1)
rc_d=$?
if [[ $rc_d -eq 0 ]]; then
  pass "(d) rc auth exits 0 on a well-shaped 0600 file"
else
  fail "(d) rc auth exited $rc_d on a well-shaped 0600 file: $out_d"
fi
if echo "$out_d" | grep -qF "$DUMMY_TOKEN"; then
  fail "(d) the token value leaked into stdout/stderr"
else
  pass "(d) the token value never appears in stdout/stderr"
fi
# --output json: same verdict, still never the token value.
out_d_json=$(HOME="$HOME_D" XDG_CONFIG_HOME="${HOME_D}/.config" bash "$RC" --output json auth 2>&1)
rc_d_json=$?
if [[ $rc_d_json -eq 0 ]] && echo "$out_d_json" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  pass "(d) --output json reports status ok"
else
  fail "(d) --output json did not report status ok: $out_d_json"
fi
if echo "$out_d_json" | grep -qF "$DUMMY_TOKEN"; then
  fail "(d) the token value leaked into --output json"
else
  pass "(d) --output json never carries the token value"
fi
rm -rf "$HOME_D"

# 'rc auth refresh' (or any other subcommand/arg) is a usage error pointing
# at bare 'rc auth' -- the possession-era refresh verb is retired.
echo ""
echo "=== Test (d2): rc auth refresh is a retired-usage error ==="
HOME_D2=$(_fresh_home)
out_d2=$(HOME="$HOME_D2" XDG_CONFIG_HOME="${HOME_D2}/.config" bash "$RC" auth refresh 2>&1)
rc_d2=$?
if [[ $rc_d2 -ne 0 ]]; then
  pass "(d2) rc auth refresh exits non-zero"
else
  fail "(d2) rc auth refresh exited 0 (should be a usage error)"
fi
if echo "$out_d2" | grep -qi "usage: rc auth$" ; then
  pass "(d2) stderr points at bare 'rc auth'"
else
  fail "(d2) stderr did not point at bare 'rc auth': $out_d2"
fi
rm -rf "$HOME_D2"

# =============================================================================
# (e) rc up --dry-run argv carries NO .credentials.json mount, even when
#     $HOME/.claude/.credentials.json exists in the temp HOME.
# =============================================================================
echo ""
echo "=== Test (e): rc up --dry-run never mounts .credentials.json ==="
HOME_E=$(_fresh_home)
PROJ_E="${HOME_E}/proj"
mkdir -p "$PROJ_E" "${HOME_E}/.claude"
git -C "$PROJ_E" init -q >/dev/null 2>&1
echo '{"fake":"creds"}' > "${HOME_E}/.claude/.credentials.json"
CONF_E=$(_plain_conf "$HOME_E" "$PROJ_E")
CALL_LOG_E=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_E=$(_fake_runtime_bin "$CALL_LOG_E")
out_e=$(HOME="$HOME_E" XDG_CONFIG_HOME="${HOME_E}/.config" RC_CAGE_CONF="$CONF_E" PATH="${FAKE_BIN_E}:${PATH}" bash "$RC" up --dry-run "$PROJ_E" 2>&1)
rc_e=$?
argv_line_e=$(printf '%s\n' "$out_e" | grep '^Would run: msb create' || true)
if [[ $rc_e -eq 0 && -n "$argv_line_e" ]]; then
  pass "(e) rc up --dry-run produced the msb create argv"
else
  fail "(e) rc up --dry-run did not produce the msb create argv (exit=$rc_e): $out_e"
fi
if printf '%s\n' "$out_e" | grep -q "credentials.json"; then
  fail "(e) the dry-run output (Would-mount lines or argv) mentions credentials.json: $out_e"
else
  pass "(e) no credentials.json mount anywhere in the dry-run output, despite the file existing in HOME"
fi
# The REAL assertion this fix round exists for (same idiom as (f) below): the
# --dry-run preflight never reaches a provisioning-shaped docker/msb call,
# regardless of what "Would run:" prints.
if [[ -s "$CALL_LOG_E" ]] && grep -Eq '^(docker (pull|tag|save)|msb (load|create))\b' "$CALL_LOG_E"; then
  fail "(e) the call log shows a provisioning call from --dry-run: $(cat "$CALL_LOG_E")"
else
  pass "(e) the call log holds no docker pull/tag/save or msb load/create call"
fi
rm -rf "$HOME_E" "$FAKE_BIN_E" "$CALL_LOG_E"

# =============================================================================
# (f) rc up with the template-declared CCTOK secret and no file/env -> fails
#     before msb, with the same message rc auth gives.
# =============================================================================
echo ""
echo "=== Test (f): rc up fails before msb when CCTOK is declared and absent ==="
HOME_F=$(_fresh_home)
PROJ_F="${HOME_F}/proj"
mkdir -p "$PROJ_F"
git -C "$PROJ_F" init -q >/dev/null 2>&1
CONF_F=$(_cctok_conf "$HOME_F" "$PROJ_F")
CALL_LOG_F=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_F=$(_fake_runtime_bin "$CALL_LOG_F")
out_f=$(HOME="$HOME_F" XDG_CONFIG_HOME="${HOME_F}/.config" RC_CAGE_CONF="$CONF_F" PATH="${FAKE_BIN_F}:${PATH}" bash "$RC" up "$PROJ_F" 2>&1 </dev/null)
rc_f=$?
if [[ $rc_f -ne 0 ]]; then
  pass "(f) rc up exits non-zero when CCTOK is declared and no token is available"
else
  fail "(f) rc up exited 0 despite the declared CCTOK secret having no valid token"
fi
if echo "$out_f" | grep -qF "$(_cctok_file "$HOME_F")" && echo "$out_f" | grep -q "claude setup-token"; then
  pass "(f) rc up's failure names the same file + one-time step as rc auth"
else
  fail "(f) rc up's failure message did not match rc auth's: $out_f"
fi
# The REAL assertion this finding exists for: the refusal happens before ANY
# provisioning-shaped call reaches docker or msb. A dead `grep -q '^Would
# run:'` check (a --dry-run-only string) would pass trivially on a real
# invocation regardless of whether provisioning ran -- this greps the actual
# call log instead.
if [[ -s "$CALL_LOG_F" ]] && grep -Eq '^(docker (pull|tag|save)|msb (load|create))\b' "$CALL_LOG_F"; then
  fail "(f) the call log shows a provisioning call despite the CCTOK refusal: $(cat "$CALL_LOG_F")"
else
  pass "(f) the call log holds no docker pull/tag or msb load/create call"
fi
rm -rf "$HOME_F" "$FAKE_BIN_F" "$CALL_LOG_F"

# Negative control: the same CCTOK-declaring config, WITH a valid token,
# reaches argv assembly (proves (f) is a real refusal, not rc up always
# failing on a secrets: block).
echo ""
echo "=== Test (f2): rc up --dry-run with a VALID CCTOK reaches argv assembly ==="
HOME_F2=$(_fresh_home)
PROJ_F2="${HOME_F2}/proj"
mkdir -p "$PROJ_F2"
git -C "$PROJ_F2" init -q >/dev/null 2>&1
_write_cctok "$HOME_F2" 600 "$DUMMY_TOKEN"
CONF_F2=$(_cctok_conf "$HOME_F2" "$PROJ_F2")
CALL_LOG_F2=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_F2=$(_fake_runtime_bin "$CALL_LOG_F2")
out_f2=$(HOME="$HOME_F2" XDG_CONFIG_HOME="${HOME_F2}/.config" RC_CAGE_CONF="$CONF_F2" PATH="${FAKE_BIN_F2}:${PATH}" bash "$RC" up --dry-run "$PROJ_F2" 2>&1)
if printf '%s\n' "$out_f2" | grep -q '^Would run: msb create'; then
  pass "(f2) a valid CCTOK reaches argv assembly (negative control for (f))"
else
  fail "(f2) a valid CCTOK still refused rc up --dry-run: $out_f2"
fi
if echo "$out_f2" | grep -qF "$DUMMY_TOKEN"; then
  fail "(f2) the token value leaked into rc up --dry-run output"
else
  pass "(f2) the token value never appears in rc up --dry-run output"
fi
# Same real assertion as (e)/(f): a VALID CCTOK reaching argv assembly must
# still never touch a provisioning-shaped docker/msb call under --dry-run.
if [[ -s "$CALL_LOG_F2" ]] && grep -Eq '^(docker (pull|tag|save)|msb (load|create))\b' "$CALL_LOG_F2"; then
  fail "(f2) the call log shows a provisioning call from --dry-run: $(cat "$CALL_LOG_F2")"
else
  pass "(f2) the call log holds no docker pull/tag/save or msb load/create call"
fi
rm -rf "$HOME_F2" "$FAKE_BIN_F2" "$CALL_LOG_F2"


echo ""
echo "======================================"
if [[ $FAILURES -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$FAILURES TEST(S) FAILED"
  exit 1
fi
