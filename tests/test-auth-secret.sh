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
  strict: false
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
  strict: false
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

# =============================================================================
# (h)/(i) rip-cage-ely4.7.17 fix round 3, finding 1: _auth_file_mode
# (cli/auth.sh) must not concatenate a GNU `stat -f` failure's stdout with the
# GNU `stat -c` fallback's stdout. A fake `stat` on PATH stands in for each
# platform's real binary -- `rc auth` must accept a 0600 file under BOTH.
# =============================================================================

# _fake_stat_gnu <bindir> -- GNU coreutils shape: `-f FORMAT FILE` is "report
# the FILESYSTEM", not the file, so a file-mode format string like '%Lp'
# prints filesystem-status junk to stdout and still exits 1. `-c '%a' FILE`
# is the real GNU file-mode query and succeeds.
_fake_stat_gnu() {
  cat > "${1}/stat" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  -f)
    echo "1234567890 512 4096 65535 0 0 0 some junk filesystem status"
    exit 1
    ;;
  -c)
    if [[ "$2" == "%a" ]]; then
      # Real mode is always 0600 in this test's fixtures.
      echo "600"
      exit 0
    fi
    exit 1
    ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "${1}/stat"
}

# _fake_stat_bsd <bindir> -- BSD/macOS shape: `-f '%Lp' FILE` succeeds; `-c`
# is not a BSD stat flag at all and errors with empty stdout.
_fake_stat_bsd() {
  cat > "${1}/stat" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  -f)
    if [[ "$2" == "%Lp" ]]; then
      echo "600"
      exit 0
    fi
    exit 1
    ;;
  -c)
    exit 1
    ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "${1}/stat"
}

echo ""
echo "=== Test (h): rc auth passes on a 0600 file under a GNU-shaped fake stat ==="
HOME_H=$(_fresh_home)
_write_cctok "$HOME_H" 600 "$DUMMY_TOKEN"
STAT_BIN_H=$(mktemp -d /private/tmp/rc-auth-secret-fakestat-XXXXXX)
_fake_stat_gnu "$STAT_BIN_H"
out_h=$(HOME="$HOME_H" XDG_CONFIG_HOME="${HOME_H}/.config" PATH="${STAT_BIN_H}:${PATH}" bash "$RC" auth 2>&1)
rc_h=$?
if [[ $rc_h -eq 0 ]]; then
  pass "(h) rc auth exits 0 on a 0600 file under a GNU-shaped fake stat"
else
  fail "(h) rc auth exited $rc_h on a 0600 file under a GNU-shaped fake stat: $out_h"
fi
rm -rf "$HOME_H" "$STAT_BIN_H"

echo ""
echo "=== Test (i): rc auth passes on a 0600 file under a BSD-shaped fake stat ==="
HOME_I=$(_fresh_home)
_write_cctok "$HOME_I" 600 "$DUMMY_TOKEN"
STAT_BIN_I=$(mktemp -d /private/tmp/rc-auth-secret-fakestat-XXXXXX)
_fake_stat_bsd "$STAT_BIN_I"
out_i=$(HOME="$HOME_I" XDG_CONFIG_HOME="${HOME_I}/.config" PATH="${STAT_BIN_I}:${PATH}" bash "$RC" auth 2>&1)
rc_i=$?
if [[ $rc_i -eq 0 ]]; then
  pass "(i) rc auth exits 0 on a 0600 file under a BSD-shaped fake stat"
else
  fail "(i) rc auth exited $rc_i on a 0600 file under a BSD-shaped fake stat: $out_i"
fi
rm -rf "$HOME_I" "$STAT_BIN_I"

# =============================================================================
# (j)/(j2)/(k) rip-cage-ely4.7.17 fix round 4: ONE predicate,
# _mount_src_exposes_secrets_dir (cli/lib/protected_paths.sh), for "does this
# mount source equal or contain $XDG_CONFIG_HOME/rip-cage/secrets" -- true
# only when that directory EXISTS. Fix round 3's version had no existence
# check (over-broad: refused a plain ~/.config mount even when the secrets
# dir had never been created) -- (j) now creates the dir first, and (j2) is
# the new negative control proving the directory's absence changes the
# verdict. The refusal now carries its own JSON error code
# (SECRETS_DIR_INSIDE_MOUNT, distinct from CAGE_CONFIG_INSIDE_MOUNT).
# =============================================================================

# _conf_with_extra_mount <home> <proj> <extra-host> <extra-guest> -- a plain
# (no CCTOK) cage config with one extra mount line beyond the workspace, for
# probing an arbitrary host path directly. Same no-secret shape as
# _plain_conf.
_conf_with_extra_mount() {
  local _home="$1" _proj="$2" _extra_host="$3" _extra_guest="$4" _conf="${1}/cage.yaml"
  cat > "$_conf" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${_proj}:/workspace"
  - "${_extra_host}:${_extra_guest}:ro"
network:
  policy: none
  strict: false
  allow:
    - "api.anthropic.com:tcp:443"
CONF
  printf '%s\n' "$_conf"
}

echo ""
echo "=== Test (j): rc up refuses a config mounting XDG_CONFIG_HOME when the secrets dir EXISTS ==="
HOME_J=$(_fresh_home)
PROJ_J="${HOME_J}/proj"
mkdir -p "$PROJ_J" "${HOME_J}/.config/rip-cage/secrets"
git -C "$PROJ_J" init -q >/dev/null 2>&1
CONF_J=$(_conf_with_extra_mount "$HOME_J" "$PROJ_J" "${HOME_J}/.config" "/home/agent/.config-leak")
CALL_LOG_J=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_J=$(_fake_runtime_bin "$CALL_LOG_J")
out_j=$(HOME="$HOME_J" XDG_CONFIG_HOME="${HOME_J}/.config" RC_CAGE_CONF="$CONF_J" PATH="${FAKE_BIN_J}:${PATH}" bash "$RC" --output json up --dry-run "$PROJ_J" 2>&1)
rc_j=$?
if [[ $rc_j -ne 0 ]]; then
  pass "(j) rc up refuses a config mounting the secrets dir's parent when the dir exists"
else
  fail "(j) rc up exited 0 despite mounting the secrets dir's parent (dir exists): $out_j"
fi
if echo "$out_j" | grep -qF "${HOME_J}/.config/rip-cage/secrets"; then
  pass "(j) the refusal names the secrets dir"
else
  fail "(j) the refusal did not name the secrets dir: $out_j"
fi
if echo "$out_j" | grep -q '"code":"SECRETS_DIR_INSIDE_MOUNT"' || echo "$out_j" | grep -q 'SECRETS_DIR_INSIDE_MOUNT'; then
  pass "(j) the JSON error carries its own SECRETS_DIR_INSIDE_MOUNT code"
else
  fail "(j) the JSON error did not carry SECRETS_DIR_INSIDE_MOUNT: $out_j"
fi
if [[ -s "$CALL_LOG_J" ]] && grep -Eq '^(docker (pull|tag|save)|msb (load|create))\b' "$CALL_LOG_J"; then
  fail "(j) the call log shows a provisioning call despite the refusal: $(cat "$CALL_LOG_J")"
else
  pass "(j) the call log holds no docker pull/tag/save or msb load/create call (refused before any msb call)"
fi
rm -rf "$HOME_J" "$FAKE_BIN_J" "$CALL_LOG_J"

echo ""
echo "=== Test (j2): the SAME mount is NOT refused when the secrets dir is ABSENT ==="
HOME_J2=$(_fresh_home)
PROJ_J2="${HOME_J2}/proj"
mkdir -p "$PROJ_J2" "${HOME_J2}/.config"
git -C "$PROJ_J2" init -q >/dev/null 2>&1
# No secrets/ subdir created, and no CCTOK block in the config -- this is the
# API-key-only user's plain "~/.config for nvim" case the over-broad half of
# the old check refused with no way past it.
CONF_J2=$(_conf_with_extra_mount "$HOME_J2" "$PROJ_J2" "${HOME_J2}/.config" "/home/agent/.config-leak")
CALL_LOG_J2=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_J2=$(_fake_runtime_bin "$CALL_LOG_J2")
out_j2=$(HOME="$HOME_J2" XDG_CONFIG_HOME="${HOME_J2}/.config" RC_CAGE_CONF="$CONF_J2" PATH="${FAKE_BIN_J2}:${PATH}" bash "$RC" up --dry-run "$PROJ_J2" 2>&1)
rc_j2=$?
argv_line_j2=$(printf '%s\n' "$out_j2" | grep '^Would run: msb create' || true)
if [[ $rc_j2 -eq 0 && -n "$argv_line_j2" ]]; then
  pass "(j2) rc up --dry-run reaches argv assembly when the secrets dir does not exist"
else
  fail "(j2) rc up --dry-run did not reach argv assembly (exit=$rc_j2): $out_j2"
fi
if echo "$out_j2" | grep -q "SECRETS_DIR_INSIDE_MOUNT"; then
  fail "(j2) the secrets-dir refusal fired despite the directory not existing: $out_j2"
else
  pass "(j2) no secrets-dir refusal when the directory does not exist"
fi
if [[ -s "$CALL_LOG_J2" ]] && grep -Eq '^(docker (pull|tag|save)|msb (load|create))\b' "$CALL_LOG_J2"; then
  fail "(j2) the call log shows a provisioning call from --dry-run: $(cat "$CALL_LOG_J2")"
else
  pass "(j2) the call log holds no docker pull/tag/save or msb load/create call"
fi
rm -rf "$HOME_J2" "$FAKE_BIN_J2" "$CALL_LOG_J2"

echo ""
echo "=== Test (k): rc up with an unrelated mount is NOT refused by the secrets-dir check ==="
HOME_K=$(_fresh_home)
PROJ_K="${HOME_K}/proj"
mkdir -p "$PROJ_K"
git -C "$PROJ_K" init -q >/dev/null 2>&1
CONF_K=$(_plain_conf "$HOME_K" "$PROJ_K")
CALL_LOG_K=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_K=$(_fake_runtime_bin "$CALL_LOG_K")
out_k=$(HOME="$HOME_K" XDG_CONFIG_HOME="${HOME_K}/.config" RC_CAGE_CONF="$CONF_K" PATH="${FAKE_BIN_K}:${PATH}" bash "$RC" up --dry-run "$PROJ_K" 2>&1)
rc_k=$?
if [[ $rc_k -eq 0 ]]; then
  pass "(k) rc up with an unrelated mount is not refused"
else
  fail "(k) rc up with an unrelated mount was refused: $out_k"
fi
if echo "$out_k" | grep -qi "secrets"; then
  fail "(k) an unrelated mount unexpectedly triggered the secrets-dir refusal wording: $out_k"
else
  pass "(k) no secrets-dir refusal wording on an unrelated mount"
fi
rm -rf "$HOME_K" "$FAKE_BIN_K" "$CALL_LOG_K"

# =============================================================================
# (l)/(l2) rip-cage-ely4.7.17 fix round 4: the too-narrow half of the defect
# -- rc's OWN generated mounts (a skill symlink target's parent dir, mounted
# by _collect_symlink_parents / the skill loop in _up_prepare_docker_mounts)
# were never checked against the secrets dir at all, config-mount-only check
# or not. Same predicate, warn-and-skip posture (ADR-023 D6), applied here.
# =============================================================================
echo ""
echo "=== Test (l): a skill symlink whose target's parent is XDG_CONFIG_HOME is skipped when secrets EXISTS ==="
HOME_L=$(_fresh_home)
PROJ_L="${HOME_L}/proj"
mkdir -p "$PROJ_L" "${HOME_L}/.claude/skills" "${HOME_L}/.config/skill-target" "${HOME_L}/.config/rip-cage/secrets"
git -C "$PROJ_L" init -q >/dev/null 2>&1
ln -s "${HOME_L}/.config/skill-target" "${HOME_L}/.claude/skills/my-skill"
CONF_L=$(_plain_conf "$HOME_L" "$PROJ_L")
CALL_LOG_L=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_L=$(_fake_runtime_bin "$CALL_LOG_L")
out_l=$(HOME="$HOME_L" XDG_CONFIG_HOME="${HOME_L}/.config" RC_CAGE_CONF="$CONF_L" PATH="${FAKE_BIN_L}:${PATH}" bash "$RC" up --dry-run "$PROJ_L" 2>&1)
rc_l=$?
argv_line_l=$(printf '%s\n' "$out_l" | grep '^Would run: msb create' || true)
if [[ $rc_l -eq 0 && -n "$argv_line_l" ]]; then
  pass "(l) rc up --dry-run still reaches argv assembly (warn-and-skip, not a refusal)"
else
  fail "(l) rc up --dry-run did not reach argv assembly (exit=$rc_l): $out_l"
fi
if printf '%s\n' "$argv_line_l" | grep -qF "${HOME_L}/.config:"; then
  fail "(l) the msb create argv still carries the skill symlink parent mount: $argv_line_l"
else
  pass "(l) the msb create argv does NOT carry the skill symlink parent mount"
fi
if echo "$out_l" | grep -q "skipping skill symlink mount ${HOME_L}/.config" && echo "$out_l" | grep -qF "$(printf '%s' "${HOME_L}/.config/rip-cage/secrets")"; then
  pass "(l) stderr carries the skip warning naming the mount and the secrets dir"
else
  fail "(l) stderr did not carry the expected skip warning: $out_l"
fi
if [[ -s "$CALL_LOG_L" ]] && grep -Eq '^(docker (pull|tag|save)|msb (load|create))\b' "$CALL_LOG_L"; then
  fail "(l) the call log shows a provisioning call from --dry-run: $(cat "$CALL_LOG_L")"
else
  pass "(l) the call log holds no docker pull/tag/save or msb load/create call"
fi
rm -rf "$HOME_L" "$FAKE_BIN_L" "$CALL_LOG_L"

echo ""
echo "=== Test (l2): the SAME skill symlink mount IS present when secrets is ABSENT ==="
HOME_L2=$(_fresh_home)
PROJ_L2="${HOME_L2}/proj"
mkdir -p "$PROJ_L2" "${HOME_L2}/.claude/skills" "${HOME_L2}/.config/skill-target"
git -C "$PROJ_L2" init -q >/dev/null 2>&1
ln -s "${HOME_L2}/.config/skill-target" "${HOME_L2}/.claude/skills/my-skill"
CONF_L2=$(_plain_conf "$HOME_L2" "$PROJ_L2")
CALL_LOG_L2=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_L2=$(_fake_runtime_bin "$CALL_LOG_L2")
out_l2=$(HOME="$HOME_L2" XDG_CONFIG_HOME="${HOME_L2}/.config" RC_CAGE_CONF="$CONF_L2" PATH="${FAKE_BIN_L2}:${PATH}" bash "$RC" up --dry-run "$PROJ_L2" 2>&1)
rc_l2=$?
argv_line_l2=$(printf '%s\n' "$out_l2" | grep '^Would run: msb create' || true)
if [[ $rc_l2 -eq 0 && -n "$argv_line_l2" ]]; then
  pass "(l2) rc up --dry-run reaches argv assembly"
else
  fail "(l2) rc up --dry-run did not reach argv assembly (exit=$rc_l2): $out_l2"
fi
if printf '%s\n' "$argv_line_l2" | grep -qF "${HOME_L2}/.config:"; then
  pass "(l2) the msb create argv carries the skill symlink parent mount when secrets is absent"
else
  fail "(l2) the msb create argv did not carry the skill symlink parent mount: $argv_line_l2"
fi
if echo "$out_l2" | grep -q "skipping skill symlink mount"; then
  fail "(l2) an unexpected skip warning fired despite the secrets dir not existing: $out_l2"
else
  pass "(l2) no skip warning when the secrets dir does not exist"
fi
rm -rf "$HOME_L2" "$FAKE_BIN_L2" "$CALL_LOG_L2"


echo ""
# (m) rip-cage-ely4.7.17: the worktree mount's source is dirname(dirname(gitdir))
# from the workspace .git FILE (workspace content), mounted read-write. It must
# never be a dir containing the secrets dir. General hostile-gitdir hole:
# rip-cage-qyer.
echo "=== Test (m): a worktree gitdir whose main .git would be XDG_CONFIG_HOME is skipped when secrets EXISTS ==="
HOME_M=$(_fresh_home)
PROJ_M="${HOME_M}/proj"
mkdir -p "$PROJ_M" "${HOME_M}/.config/worktrees/wt1" "${HOME_M}/.config/rip-cage/secrets"
echo "gitdir: ${HOME_M}/.config/worktrees/wt1" > "${PROJ_M}/.git"
CONF_M=$(_plain_conf "$HOME_M" "$PROJ_M")
CALL_LOG_M=$(mktemp /private/tmp/rc-auth-secret-calllog-XXXXXX)
FAKE_BIN_M=$(_fake_runtime_bin "$CALL_LOG_M")
out_m=$(HOME="$HOME_M" XDG_CONFIG_HOME="${HOME_M}/.config" RC_CAGE_CONF="$CONF_M" PATH="${FAKE_BIN_M}:${PATH}" bash "$RC" up --dry-run "$PROJ_M" 2>&1)
argv_line_m=$(printf '%s\n' "$out_m" | grep '^Would run: msb create' || true)
if [[ -z "$argv_line_m" ]]; then
  fail "(m) rc up --dry-run did not reach argv assembly: $out_m"
elif printf '%s\n' "$argv_line_m" | grep -q '/workspace/.git-main'; then
  fail "(m) the msb create argv carries the worktree mount over the secrets dir: $argv_line_m"
else
  pass "(m) the msb create argv carries NO /workspace/.git-main mount"
fi
if echo "$out_m" | grep -q "skipping worktree mount"; then
  pass "(m) stderr names the skipped worktree mount"
else
  fail "(m) stderr did not carry the worktree skip warning: $out_m"
fi
if [[ -s "$CALL_LOG_M" ]] && grep -Eq '^(docker (pull|tag|save)|msb (load|create))\b' "$CALL_LOG_M"; then
  fail "(m) the call log shows a provisioning call from --dry-run: $(cat "$CALL_LOG_M")"
else
  pass "(m) the call log holds no docker pull/tag/save or msb load/create call"
fi
rm -rf "$HOME_M" "$FAKE_BIN_M" "$CALL_LOG_M"

echo ""
echo "======================================"
if [[ $FAILURES -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$FAILURES TEST(S) FAILED"
  exit 1
fi
