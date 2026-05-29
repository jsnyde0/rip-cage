#!/usr/bin/env bash
# Host-side unit tests for `rc config init` and the `rc up` no-config tip
# (rip-cage-97n). All tests are docker-free — they invoke rc as a subprocess
# inside an isolated $HOME and stub `ssh` via a PATH shim where needed.
#
# Coverage:
#   C1   detect_ssh_hosts: HTTPS-only remote → empty
#   C2   detect_ssh_hosts: scp-like SSH (git@host:path) → host
#   C3   detect_ssh_hosts: ssh://user@host/path → host
#   C4   detect_ssh_hosts: mixed remotes → only SSH hosts, deduped
#   C5   detect_ssh_hosts: non-git directory → empty
#   C6   detect_keys: ssh -G stub returns IdentityFile, key file present → basename
#   C7   detect_keys: ssh -G stub returns IdentityFile, key file missing → empty
#   C8   build_yaml: with hosts + keys → valid schema-conformant YAML
#   C9   build_yaml: no hosts or keys → still version: 1, hosts/keys commented out
#   C10  cmd_config_init: --yes writes file with detected hosts (HTTPS+SSH project)
#   C11  cmd_config_init: re-run with same proposal exits "already matches"
#   C12  cmd_config_init: re-run with proposal-divergence shows diff, --yes overwrites
#   C13  cmd_config_init: no SSH remotes → exits 0, no file written, prints skip msg
#   C14  emit_tip: no .rip-cage.yaml + SSH remote → tip lines printed
#   C15  emit_tip: .rip-cage.yaml present → silent
#   C16  emit_tip: non-git directory → silent
#   C17  emit_tip: git repo, HTTPS-only → silent
#   C18  detect_keys Tier 2 — ws under .../personal/<x>, key id_ed25519_personal loaded → picks personal
#   C19  detect_keys Tier 2 — host mapular.com, key comment 'x@mapular.com' → picks that key
#   C20  detect_keys Tier 2 — no comment/basename token match → empty

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TEST_HOME=""
TOTAL=20

pass() { echo "PASS C$1: $2"; }
fail() { echo "FAIL C$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

cleanup() { [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"; }
trap cleanup EXIT

# Source rc to access internal helpers (_config_init_*).
# rc has a top-level guard that runs only when invoked, not when sourced.
# shellcheck disable=SC1090
RC_SOURCE_ONLY=1 source "$RC" 2>/dev/null || true
# Some rc tops aren't sourcing-safe; if helpers aren't visible, fall back to
# subprocess invocation. Detect:
if ! declare -F _config_init_detect_ssh_hosts >/dev/null 2>&1; then
  USE_SUBPROCESS=1
else
  USE_SUBPROCESS=0
fi

# Fresh per-test workspace + git repo. Returns ws path on stdout.
mk_ws() {
  local ws
  ws=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-ws-XXXXXX")
  git -C "$ws" init -q 2>/dev/null
  git -C "$ws" config user.email t@t 2>/dev/null
  git -C "$ws" config user.name t 2>/dev/null
  echo "$ws"
}

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-home-XXXXXX")
mkdir -p "${TEST_HOME}/.ssh"

# ---------------------------------------------------------------------------
# Helper: invoke an internal helper. Uses bash -c against rc when sourcing
# isn't available. Args: helper_name, hosts_or_arg.
# ---------------------------------------------------------------------------
call_detect_ssh_hosts() {
  if [[ "$USE_SUBPROCESS" -eq 1 ]]; then
    bash -c 'source "$1" >/dev/null 2>&1 || true; _config_init_detect_ssh_hosts "$2"' _ "$RC" "$1"
  else
    _config_init_detect_ssh_hosts "$1"
  fi
}
call_detect_keys() {
  # Args: hosts [workspace]
  local _hosts="$1" _ws="${2:-/tmp}"
  if [[ "$USE_SUBPROCESS" -eq 1 ]]; then
    HOME="$TEST_HOME" bash -c 'source "$1" >/dev/null 2>&1 || true; _config_init_detect_keys "$2" "$3"' _ "$RC" "$_hosts" "$_ws"
  else
    HOME="$TEST_HOME" _config_init_detect_keys "$_hosts" "$_ws"
  fi
}
call_build_yaml() {
  if [[ "$USE_SUBPROCESS" -eq 1 ]]; then
    bash -c 'source "$1" >/dev/null 2>&1 || true; _config_init_build_yaml "$2" "$3"' _ "$RC" "$1" "$2"
  else
    _config_init_build_yaml "$1" "$2"
  fi
}
call_emit_tip() {
  # Captures stdout
  if [[ "$USE_SUBPROCESS" -eq 1 ]]; then
    bash -c 'source "$1" >/dev/null 2>&1 || true; _config_init_emit_tip "$2"' _ "$RC" "$1"
  else
    _config_init_emit_tip "$1"
  fi
}

# ---------------------------------------------------------------------------
# C1: detect_ssh_hosts on HTTPS-only repo → empty
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "https://github.com/foo/bar.git"
out=$(call_detect_ssh_hosts "$ws")
if [[ -z "$out" ]]; then pass 1 "HTTPS-only remote → no hosts"
else fail 1 "HTTPS-only remote" "expected empty, got: $out"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C2: detect_ssh_hosts on scp-like SSH remote → host
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "git@github.com:foo/bar.git"
out=$(call_detect_ssh_hosts "$ws")
if [[ "$out" == "github.com" ]]; then pass 2 "scp-like SSH → github.com"
else fail 2 "scp-like SSH" "expected 'github.com', got: $out"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C3: detect_ssh_hosts on ssh:// URL → host
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "ssh://git@gitlab.example.com:2222/foo/bar.git"
out=$(call_detect_ssh_hosts "$ws")
if [[ "$out" == "gitlab.example.com" ]]; then pass 3 "ssh:// URL → gitlab.example.com"
else fail 3 "ssh:// URL" "expected 'gitlab.example.com', got: $out"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C4: mixed remotes → only SSH hosts, deduped
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "git@github.com:foo/bar.git"
git -C "$ws" remote add upstream "https://github.com/foo/bar.git"
git -C "$ws" remote add mirror "git@gitlab.example.com:foo/bar.git"
out=$(call_detect_ssh_hosts "$ws")
expected=$'github.com\ngitlab.example.com'
if [[ "$out" == "$expected" ]]; then pass 4 "mixed remotes → only SSH hosts, deduped"
else fail 4 "mixed remotes" "expected '$expected', got: $out"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C5: non-git directory → empty
# ---------------------------------------------------------------------------
ws=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-nogit-XXXXXX")
out=$(call_detect_ssh_hosts "$ws")
if [[ -z "$out" ]]; then pass 5 "non-git directory → empty"
else fail 5 "non-git" "expected empty, got: $out"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C6: detect_keys with ssh stub returning IdentityFile + key file present → basename
# ---------------------------------------------------------------------------
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<STUB
#!/usr/bin/env bash
# Honors -G <host>; emits an identityfile line.
case " \$* " in
  *" -G github.com "*) echo "identityfile ${TEST_HOME}/.ssh/id_ed25519_personal" ;;
  *)                   echo "identityfile ${TEST_HOME}/.ssh/id_unknown" ;;
esac
exit 0
STUB
chmod +x "${stub_dir}/ssh"
# Create the key file so detect_keys accepts it
: > "${TEST_HOME}/.ssh/id_ed25519_personal"
PATH_SAVE="$PATH"
export PATH="${stub_dir}:$PATH"
out=$(call_detect_keys "github.com")
export PATH="$PATH_SAVE"
if [[ "$out" == "id_ed25519_personal" ]]; then pass 6 "ssh -G stub → key basename"
else fail 6 "ssh -G stub" "expected 'id_ed25519_personal', got: $out"; fi
rm "${TEST_HOME}/.ssh/id_ed25519_personal"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
# C7: detect_keys when key file is missing → empty (silent skip)
# ---------------------------------------------------------------------------
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<STUB
#!/usr/bin/env bash
echo "identityfile ${TEST_HOME}/.ssh/id_ed25519_does_not_exist"
exit 0
STUB
chmod +x "${stub_dir}/ssh"
PATH_SAVE="$PATH"
export PATH="${stub_dir}:$PATH"
out=$(call_detect_keys "github.com")
export PATH="$PATH_SAVE"
if [[ -z "$out" ]]; then pass 7 "missing key file → empty"
else fail 7 "missing key file" "expected empty, got: $out"; fi
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
# C8: build_yaml with hosts + keys → schema-conformant YAML
# ---------------------------------------------------------------------------
hosts=$'github.com\ngitlab.example.com'
keys=$'id_ed25519_personal'
yaml=$(call_build_yaml "$hosts" "$keys")
if echo "$yaml" | grep -q "^version: 1$" \
   && echo "$yaml" | grep -q "^ssh:$" \
   && echo "$yaml" | grep -q "^  allowed_hosts:$" \
   && echo "$yaml" | grep -q "^    - github.com$" \
   && echo "$yaml" | grep -q "^    - gitlab.example.com$" \
   && echo "$yaml" | grep -q "^  allowed_keys:$" \
   && echo "$yaml" | grep -q "^    - id_ed25519_personal$"; then
  pass 8 "build_yaml with hosts + keys → schema-conformant"
else
  fail 8 "build_yaml" "missing expected lines in:"$'\n'"$yaml"
fi

# ---------------------------------------------------------------------------
# C9: build_yaml with no hosts or keys — version: 1 still present, sections commented
# ---------------------------------------------------------------------------
yaml=$(call_build_yaml "" "")
if echo "$yaml" | grep -q "^version: 1$" \
   && echo "$yaml" | grep -q "^  allowed_hosts: \[\]$"; then
  pass 9 "build_yaml empty inputs → version + empty allowed_hosts"
else
  fail 9 "build_yaml empty" "missing expected lines in:"$'\n'"$yaml"
fi

# ---------------------------------------------------------------------------
# C10: cmd_config_init --yes writes the file (HTTPS + SSH project)
# Test isolates HOME and PATH. ssh stub returns no IdentityFile so keys are empty,
# but allowed_hosts should be populated from the SSH remote.
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "git@github.com:foo/bar.git"
git -C "$ws" remote add upstream "https://github.com/foo/bar.git"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${stub_dir}/ssh"
(cd "$ws" && PATH="${stub_dir}:$PATH" HOME="$TEST_HOME" "$RC" config init --yes >/dev/null 2>&1)
rc=$?
if [[ $rc -eq 0 && -f "${ws}/.rip-cage.yaml" ]] \
   && grep -q "^    - github.com$" "${ws}/.rip-cage.yaml" \
   && grep -q "^version: 1$" "${ws}/.rip-cage.yaml"; then
  pass 10 "rc config init --yes wrote file with detected SSH host"
else
  fail 10 "rc config init --yes" "rc=$rc, file=$(ls "${ws}/.rip-cage.yaml" 2>&1):"$'\n'"$(cat "${ws}/.rip-cage.yaml" 2>&1 || echo MISSING)"
fi
rm -rf "$stub_dir"
WS_C10="$ws"

# ---------------------------------------------------------------------------
# C11: re-run with same input → "already matches", no rewrite
# Reuses C10's workspace; same ssh stub absent so detection produces same YAML.
# ---------------------------------------------------------------------------
ws="$WS_C10"
mtime_before=$(stat -c %Y "${ws}/.rip-cage.yaml" 2>/dev/null || stat -f %m "${ws}/.rip-cage.yaml")
sleep 1
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${stub_dir}/ssh"
out=$(cd "$ws" && PATH="${stub_dir}:$PATH" HOME="$TEST_HOME" "$RC" config init --yes 2>&1)
mtime_after=$(stat -c %Y "${ws}/.rip-cage.yaml" 2>/dev/null || stat -f %m "${ws}/.rip-cage.yaml")
if echo "$out" | grep -q "already matches" && [[ "$mtime_before" == "$mtime_after" ]]; then
  pass 11 "re-run with same proposal → 'already matches', file unchanged"
else
  fail 11 "re-run idempotent" "out='$out' mtime: $mtime_before → $mtime_after"
fi
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
# C12: divergence — edit existing file then re-run, expect diff and overwrite
# ---------------------------------------------------------------------------
ws="$WS_C10"
echo "# user edit" >> "${ws}/.rip-cage.yaml"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${stub_dir}/ssh"
out=$(cd "$ws" && PATH="${stub_dir}:$PATH" HOME="$TEST_HOME" "$RC" config init --yes 2>&1)
if echo "$out" | grep -q "differs from proposed" \
   && ! grep -q "user edit" "${ws}/.rip-cage.yaml"; then
  pass 12 "divergence: diff shown + --yes overwrites"
else
  fail 12 "divergence" "out='$out' file:"$'\n'"$(cat "${ws}/.rip-cage.yaml")"
fi
rm -rf "$stub_dir"
rm -rf "$WS_C10"

# ---------------------------------------------------------------------------
# C13: no SSH remotes at all → exits 0, no file written, prints skip msg
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "https://github.com/foo/bar.git"
out=$(cd "$ws" && HOME="$TEST_HOME" "$RC" config init --yes 2>&1)
rc=$?
if [[ $rc -eq 0 && ! -f "${ws}/.rip-cage.yaml" ]] && echo "$out" | grep -q "Nothing to lock down"; then
  pass 13 "no SSH remotes → skip, no file"
else
  fail 13 "no SSH remotes" "rc=$rc, file=$(ls "${ws}/.rip-cage.yaml" 2>&1) out='$out'"
fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C14: emit_tip — no .rip-cage.yaml + SSH remote → tip lines printed
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "git@github.com:foo/bar.git"
out=$(call_emit_tip "$ws")
if echo "$out" | grep -q "no .rip-cage.yaml" && echo "$out" | grep -q "rc config init"; then
  pass 14 "emit_tip with SSH remote, no config → tip printed"
else
  fail 14 "emit_tip SSH" "expected tip, got: '$out'"
fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C15: emit_tip — .rip-cage.yaml present → silent
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "git@github.com:foo/bar.git"
echo "version: 1" > "${ws}/.rip-cage.yaml"
out=$(call_emit_tip "$ws")
if [[ -z "$out" ]]; then pass 15 "emit_tip with config file → silent"
else fail 15 "emit_tip silent" "expected empty, got: '$out'"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C16: emit_tip — non-git directory → silent
# ---------------------------------------------------------------------------
ws=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-nogit-XXXXXX")
out=$(call_emit_tip "$ws")
if [[ -z "$out" ]]; then pass 16 "emit_tip non-git → silent"
else fail 16 "emit_tip non-git" "expected empty, got: '$out'"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C17: emit_tip — git repo, HTTPS-only remotes → silent
# ---------------------------------------------------------------------------
ws=$(mk_ws)
git -C "$ws" remote add origin "https://github.com/foo/bar.git"
out=$(call_emit_tip "$ws")
if [[ -z "$out" ]]; then pass 17 "emit_tip HTTPS-only → silent"
else fail 17 "emit_tip HTTPS-only" "expected empty, got: '$out'"; fi
rm -rf "$ws"

# ---------------------------------------------------------------------------
# C18: Tier 2 fallback — workspace under .../personal/, key basename matches
#      "personal" parent dir token; ssh -G yields nothing, ssh-add -L provides
#      the loaded keys; helper picks id_ed25519_personal via basename match.
# ---------------------------------------------------------------------------
TEST_HOME2=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-h2-XXXXXX")
mkdir -p "${TEST_HOME2}/.ssh"
mkdir -p "${TEST_HOME2}/code/personal"
ws=$(mktemp -d "${TEST_HOME2}/code/personal/myproj-XXXXXX")
echo "ssh-ed25519 BLOB_PERSONAL_C18 me@personal.example" > "${TEST_HOME2}/.ssh/id_ed25519_personal.pub"
echo "ssh-ed25519 BLOB_WORK_C18 jonatan@mapular.com" > "${TEST_HOME2}/.ssh/id_ed25519_work.pub"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${stub_dir}/ssh"
cat > "${stub_dir}/ssh-add" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -L)
    echo "ssh-ed25519 BLOB_PERSONAL_C18 me@personal.example"
    echo "ssh-ed25519 BLOB_WORK_C18 jonatan@mapular.com"
    ;;
esac
STUB
chmod +x "${stub_dir}/ssh-add"
PATH_SAVE="$PATH"
HOME_SAVE="$HOME"
export PATH="${stub_dir}:$PATH"
export HOME="$TEST_HOME2"
out=$(_config_init_detect_keys "github.com" "$ws")
export PATH="$PATH_SAVE"
export HOME="$HOME_SAVE"
if [[ "$out" == "id_ed25519_personal" ]]; then
  pass 18 "Tier 2: ws parent 'personal' → id_ed25519_personal"
else
  fail 18 "Tier 2 personal" "expected 'id_ed25519_personal', got: '$out'"
fi
rm -rf "$stub_dir" "$TEST_HOME2"

# ---------------------------------------------------------------------------
# C19: Tier 2 — host token derived from gitlab.mapular.com matches key comment
#      'jonatan@mapular.com' → picks that key. Validates the bead's stated
#      "key-comment heuristic correctly picks id_ed25519_work for a mapular.com
#      remote" acceptance test.
# ---------------------------------------------------------------------------
TEST_HOME2=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-h2-XXXXXX")
mkdir -p "${TEST_HOME2}/.ssh"
ws=$(mktemp -d "${TEST_HOME2}/proj-XXXXXX")
echo "ssh-ed25519 BLOB_WORK_C19 jonatan@mapular.com" > "${TEST_HOME2}/.ssh/id_ed25519_work.pub"
echo "ssh-ed25519 BLOB_OTHER_C19 me@personal.example" > "${TEST_HOME2}/.ssh/id_ed25519_other.pub"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${stub_dir}/ssh"
cat > "${stub_dir}/ssh-add" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -L)
    echo "ssh-ed25519 BLOB_OTHER_C19 me@personal.example"
    echo "ssh-ed25519 BLOB_WORK_C19 jonatan@mapular.com"
    ;;
esac
STUB
chmod +x "${stub_dir}/ssh-add"
PATH_SAVE="$PATH"
HOME_SAVE="$HOME"
export PATH="${stub_dir}:$PATH"
export HOME="$TEST_HOME2"
out=$(_config_init_detect_keys "gitlab.mapular.com" "$ws")
export PATH="$PATH_SAVE"
export HOME="$HOME_SAVE"
if [[ "$out" == "id_ed25519_work" ]]; then
  pass 19 "Tier 2: 'mapular' token in comment → id_ed25519_work"
else
  fail 19 "Tier 2 mapular" "expected 'id_ed25519_work', got: '$out'"
fi
rm -rf "$stub_dir" "$TEST_HOME2"

# ---------------------------------------------------------------------------
# C20: Tier 2 — no token match → empty output (silent skip).
# ---------------------------------------------------------------------------
TEST_HOME2=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-h2-XXXXXX")
mkdir -p "${TEST_HOME2}/.ssh"
ws=$(mktemp -d "${TEST_HOME2}/zzz-XXXXXX")
echo "ssh-ed25519 BLOB_C20 unrelated@example.org" > "${TEST_HOME2}/.ssh/id_ed25519_xyz.pub"
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/rc-cfginit-stub-XXXXXX")
cat > "${stub_dir}/ssh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${stub_dir}/ssh"
cat > "${stub_dir}/ssh-add" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -L) echo "ssh-ed25519 BLOB_C20 unrelated@example.org" ;;
esac
STUB
chmod +x "${stub_dir}/ssh-add"
PATH_SAVE="$PATH"
HOME_SAVE="$HOME"
export PATH="${stub_dir}:$PATH"
export HOME="$TEST_HOME2"
out=$(_config_init_detect_keys "github.com" "$ws")
export PATH="$PATH_SAVE"
export HOME="$HOME_SAVE"
if [[ -z "$out" ]]; then
  pass 20 "Tier 2: no token match → empty"
else
  fail 20 "Tier 2 no-match" "expected empty, got: '$out'"
fi
rm -rf "$stub_dir" "$TEST_HOME2"

# ---------------------------------------------------------------------------
PASSED=$((TOTAL - FAILURES))
echo ""
echo "======================================"
echo "test-config-init: ${PASSED}/${TOTAL} passed"
echo "======================================"
exit $FAILURES
