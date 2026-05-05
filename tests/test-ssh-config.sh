#!/usr/bin/env bash
# Integration test suite for rip-cage SSH identity routing (ADR-020).
#
# Exercises cross-slot observable behaviors of P1-P5:
#   P1 = github.com identity resolver       (test-ssh-resolver.sh)
#   P2 = host-config translation engine     (test-ssh-translator.sh)
#   P3 = pubkey allowlist mount             (test-ssh-mount.sh)
#   P4 = in-cage preflight + sentinels      (test-ssh-preflight.sh)
#   P5 = visibility surfaces                (test-ssh-visibility.sh)
#
# This suite contains 17 numbered checks. Checks requiring live
# network access emit [N/17] SKIP rather than PASS or FAIL. The suite
# exits 0 when every non-skipped check passes.
#
# Runs host-side. No live container or network required for checks 1-13, 15-17.
# Check 14 (live-GitHub greeting) SKIPs unless RC_TEST_E2E is set and network is reachable.
#
# AC8 mapping:
#   Check 6  — IgnoreUnknown shim parity (individually numbered per AC8)
#   Check 16 — sentinel write-path/ownership (individually numbered per AC8;
#               host-side proxy: root:644 enforced inside container by docker
#               exec --user root, not verifiable without a live container)
#
# ADRs: ADR-013 (test tiers), ADR-020 (SSH identity routing)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FIXTURES="${SCRIPT_DIR}/fixtures/ssh-config"

FAILURES=0
TMPDIR_TEST=""
TOTAL=17

# ---------------------------------------------------------------------------
# Reporting helpers — each check prints exactly one line.
# ---------------------------------------------------------------------------
_pass() { echo "[$1/$TOTAL] PASS $2"; }
_fail() { echo "[$1/$TOTAL] FAIL $2 — $3"; FAILURES=$((FAILURES + 1)); }
_skip() { echo "[$1/$TOTAL] SKIP $2 (requires live GitHub)"; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  if [[ -n "${TMPDIR_TEST:-}" && -d "${TMPDIR_TEST:-}" ]]; then
    rm -rf "$TMPDIR_TEST"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Setup: isolated HOME with .ssh/ structure.
# ---------------------------------------------------------------------------
TMPDIR_TEST=$(mktemp -d)
export HOME="${TMPDIR_TEST}"
SSH_DIR="${TMPDIR_TEST}/.ssh"
mkdir -p "$SSH_DIR"

# Stub .pub files (no private keys — ADR-020 D1)
touch "${SSH_DIR}/id_ed25519_work.pub"
touch "${SSH_DIR}/id_ed25519_personal.pub"
touch "${SSH_DIR}/known_hosts"

# Unrelated .pub — must NOT appear in mount set when not referenced by any Host block
touch "${SSH_DIR}/id_unrelated.pub"

# Prepare fixture files in temp SSH_DIR (the translator requires files on the
# real filesystem; fixtures use _SSH_HOME_ as a placeholder for the actual path)
sed "s|_SSH_HOME_|${SSH_DIR}|g" "${FIXTURES}/host-config-full.conf" > "${SSH_DIR}/config-full"
cp "${FIXTURES}/included.conf" "${SSH_DIR}/included.conf"
cp "${FIXTURES}/host-config-minimal.conf" "${SSH_DIR}/config-minimal"
cp "${FIXTURES}/host-config-with-github.conf" "${SSH_DIR}/config-with-github"

# Cache dir for translated output
CACHE_DIR="${TMPDIR_TEST}/.cache/rip-cage/integration-test"
mkdir -p "$CACHE_DIR"
TRANSLATED="${CACHE_DIR}/ssh-config"

# Sentinel dir (override for test mode — preflight + zshrc + init both honour this)
SENTINEL_DIR="${TMPDIR_TEST}/sentinels"
mkdir -p "$SENTINEL_DIR"
export RC_PREFLIGHT_SENTINEL_DIR="$SENTINEL_DIR"
export RC_SENTINEL_DIR="$SENTINEL_DIR"

# Docker stub bin (makes cli-level tests work without a live docker daemon)
STUB_BIN="${TMPDIR_TEST}/stub-bin"
mkdir -p "$STUB_BIN"

# Stub docker: intercepts "docker exec … ssh -T … git@github.com" for greeting
# probes; for everything else (inspect, label reads) returns plausible output.
export TMPDIR_TEST_STUB="${TMPDIR_TEST}"
cat > "${STUB_BIN}/docker" <<'DOCKERSTUB'
#!/usr/bin/env bash
GREETING_FILE="${TMPDIR_TEST_STUB}/greeting"
STUB_RC_FILE="${TMPDIR_TEST_STUB}/stub_rc"
STUB_GREETING="Hi stub-user!"
STUB_RC=0
[[ -f "$GREETING_FILE" ]] && STUB_GREETING=$(cat "$GREETING_FILE")
[[ -f "$STUB_RC_FILE" ]]  && STUB_RC=$(cat "$STUB_RC_FILE")

if [[ "$1" == "exec" ]]; then
  shift
  while [[ $# -gt 0 && "$1" != "ssh" ]]; do shift; done
  if [[ "$1" == "ssh" ]]; then
    if [[ "$STUB_RC" == "0" ]]; then echo "$STUB_GREETING" >&2; exit 0; else exit 255; fi
  fi
fi

# inspect calls (used by _resolve_github_identity layer 2)
if [[ "$1" == "inspect" ]]; then
  # Emit the label value from STUB_LABEL_FILE if set; else empty
  LABEL_FILE="${TMPDIR_TEST_STUB}/stub_label"
  if [[ -f "$LABEL_FILE" ]]; then cat "$LABEL_FILE"; else echo ""; fi
  exit 0
fi

# Default: succeed silently
exit 0
DOCKERSTUB
chmod +x "${STUB_BIN}/docker"

# Helper: set greeting for stub
_set_greeting() { printf '%s' "$1" > "${TMPDIR_TEST}/greeting"; printf '0' > "${TMPDIR_TEST}/stub_rc"; }
# Helper: seed stub container label for layer-2 resume tests
_set_container_label() { printf '%s' "$1" > "${TMPDIR_TEST}/stub_label"; }

_set_greeting "Hi stub-user!"
_set_container_label ""

# ---------------------------------------------------------------------------
# Source rc to get function definitions.
# ---------------------------------------------------------------------------
_source_rc_functions() {
  set +e
  # shellcheck source=../rc
  source "$RC" 2>/dev/null
  set -e
}
_source_rc_functions

# Temporary rules file for resolution tests
RULES_FILE="${TMPDIR_TEST}/identity-rules"

# ===========================================================================
# CHECK 1/17: Transform — path rewrite
# ---------------------------------------------------------------------------
# Every IdentityFile tilde/absolute path under $HOME/.ssh/ must be rewritten
# to /home/agent/.ssh/<basename>. This transform is fundamental to "the cage
# can read the config without path errors".
# ===========================================================================
_translate_ssh_config "${SSH_DIR}/config-full" "$TRANSLATED" ""

_bad_paths=$(grep -v '^\s*#' "$TRANSLATED" | grep '~/.ssh/' || true)
_id_paths=$(grep -v '^\s*#' "$TRANSLATED" | grep -i '^\s*IdentityFile' || true)
_all_agent_paths=true
while IFS= read -r _line; do
  [[ -z "$_line" ]] && continue
  _p="${_line#*IdentityFile }"
  [[ "$_p" != /home/agent/.ssh/* ]] && _all_agent_paths=false
done <<< "$_id_paths"

if [[ -z "$_bad_paths" && "$_all_agent_paths" == "true" ]]; then
  _pass 1 "path rewrite: tilde paths → /home/agent/.ssh/<basename>"
else
  _reason=""
  [[ -n "$_bad_paths" ]] && _reason="tilde paths remain"
  [[ "$_all_agent_paths" == "false" ]] && _reason="${_reason:+$_reason; }IdentityFile not /home/agent/.ssh/"
  _fail 1 "path rewrite" "$_reason"
fi

# ===========================================================================
# CHECK 2/17: Transform — in-home Include inline (content inlined, paths rewritten)
# ---------------------------------------------------------------------------
# The full fixture has `Include _SSH_HOME_/included.conf`. After translation
# the Include directive itself must be gone (inlined) and the inlined content
# (Host internal + its IdentityFile) must have paths rewritten too.
# ===========================================================================
_has_host_internal=$(grep -c "^Host internal" "$TRANSLATED" || true)
_include_present=$(grep -c "^Include " "$TRANSLATED" || true)
_inlined_id=$(grep -v '^\s*#' "$TRANSLATED" | grep "IdentityFile /home/agent/.ssh/id_ed25519_internal" || true)

if [[ "$_has_host_internal" -ge 1 && "$_include_present" -eq 0 && -n "$_inlined_id" ]]; then
  _pass 2 "in-home Include inline: Host internal present, Include gone, inlined IdentityFile rewritten"
else
  _reason=""
  [[ "$_has_host_internal" -lt 1 ]] && _reason="Host internal not found"
  [[ "$_include_present" -gt 0 ]] && _reason="${_reason:+$_reason; }Include directives still present"
  [[ -z "$_inlined_id" ]] && _reason="${_reason:+$_reason; }id_ed25519_internal not rewritten to /home/agent/"
  _fail 2 "in-home Include inline" "$_reason"
fi

# ===========================================================================
# CHECK 3/17: Transform — out-of-home Include strip
# ---------------------------------------------------------------------------
# The full fixture has `Include /etc/orbstack/ssh/config` (outside $HOME/.ssh/).
# After translation it must be replaced by a `# rip-cage: stripped (Include…`
# comment and must NOT appear as an active directive.
# ===========================================================================
_stripped_comment=$(grep "# rip-cage: stripped (Include" "$TRANSLATED" || true)
_active_orbstack=$(grep -v '^\s*#' "$TRANSLATED" | grep '/etc/orbstack' || true)

if [[ -n "$_stripped_comment" && -z "$_active_orbstack" ]]; then
  _pass 3 "out-of-home Include strip: replaced by rip-cage comment, no active path"
else
  _reason=""
  [[ -z "$_stripped_comment" ]] && _reason="stripped comment absent"
  [[ -n "$_active_orbstack" ]] && _reason="${_reason:+$_reason; }orbstack path still active"
  _fail 3 "out-of-home Include strip" "$_reason"
fi

# ===========================================================================
# CHECK 4/17: Transform — host-only directive strip
# ---------------------------------------------------------------------------
# ProxyCommand, ProxyJump, ControlMaster, ControlPath, Match exec, IdentityAgent
# must each appear only in `# rip-cage: stripped (host-only)` comments, never
# as active directives. Leaving them active produces "No such file" at SSH-time.
# ===========================================================================
_directives=("ProxyCommand" "ProxyJump" "ControlMaster" "ControlPath" "IdentityAgent")
_bad_active=""
for _d in "${_directives[@]}"; do
  _active=$(grep -v '^\s*#' "$TRANSLATED" | grep -i "^\s*${_d}" || true)
  [[ -n "$_active" ]] && _bad_active="${_bad_active}${_d} "
done
# Check Match exec specifically (grep pattern needs care)
_match_exec_active=$(grep -v '^\s*#' "$TRANSLATED" | grep -iE '^\s*Match\s+exec' || true)
[[ -n "$_match_exec_active" ]] && _bad_active="${_bad_active}Match-exec "
_stripped_hostonly=$(grep "# rip-cage: stripped (host-only)" "$TRANSLATED" || true)

if [[ -z "$_bad_active" && -n "$_stripped_hostonly" ]]; then
  _pass 4 "host-only directives stripped: ProxyCommand/ProxyJump/ControlMaster/ControlPath/IdentityAgent/Match-exec absent as active directives"
else
  _reason=""
  [[ -n "$_bad_active" ]] && _reason="active host-only directives: ${_bad_active}"
  [[ -z "$_stripped_hostonly" ]] && _reason="${_reason:+$_reason; }no stripped (host-only) comment found"
  _fail 4 "host-only directive strip" "$_reason"
fi

# ===========================================================================
# CHECK 5/17: Transform — ADR-014 D2 directive override
# ---------------------------------------------------------------------------
# The full fixture has `BatchMode no` and `StrictHostKeyChecking accept-new`
# inside Host blocks. These must be overridden to `BatchMode yes` and
# `StrictHostKeyChecking yes` with a `# rip-cage: overridden (ADR-014 D2)`
# annotation. Without this, the cage gets interactive SSH prompts.
# ===========================================================================
_batchmode_no=$(grep -v '^\s*#' "$TRANSLATED" | grep -i '^\s*BatchMode\s*no' || true)
_batchmode_yes=$(grep -v '^\s*#' "$TRANSLATED" | grep -i '^\s*BatchMode\s*yes' || true)
_strict_bad=$(grep -v '^\s*#' "$TRANSLATED" | grep -i '^\s*StrictHostKeyChecking\s*accept-new' || true)
_strict_ok=$(grep -v '^\s*#' "$TRANSLATED" | grep -i '^\s*StrictHostKeyChecking\s*yes' || true)
_d2_comment=$(grep "# rip-cage: overridden (ADR-014 D2)" "$TRANSLATED" || true)

if [[ -z "$_batchmode_no" && -n "$_batchmode_yes" && -z "$_strict_bad" && -n "$_strict_ok" && -n "$_d2_comment" ]]; then
  _pass 5 "ADR-014 D2 override: BatchMode yes, StrictHostKeyChecking yes, annotation present"
else
  _reason=""
  [[ -n "$_batchmode_no" ]] && _reason="BatchMode no still active"
  [[ -z "$_batchmode_yes" ]] && _reason="${_reason:+$_reason; }BatchMode yes absent"
  [[ -n "$_strict_bad" ]] && _reason="${_reason:+$_reason; }StrictHostKeyChecking accept-new still active"
  [[ -z "$_strict_ok" ]] && _reason="${_reason:+$_reason; }StrictHostKeyChecking yes absent"
  [[ -z "$_d2_comment" ]] && _reason="${_reason:+$_reason; }ADR-014 D2 annotation absent"
  _fail 5 "ADR-014 D2 directive override" "$_reason"
fi

# ===========================================================================
# CHECK 6/17: IgnoreUnknown shim parity (AC8 dedicated check)
# ---------------------------------------------------------------------------
# The translated config must lead with IgnoreUnknown as the first non-blank,
# non-comment directive — for both full-config translation (check uses already-
# translated TRANSLATED from checks 1-5) and minimal-config translation (a
# config with no Host blocks). This shim is the macOS-safe OpenSSH compatibility
# directive; without it, OpenSSH on Linux rejects the rip-cage-specific
# directives and the entire config fails to parse.
# ===========================================================================
# Parity 1: full-config translation (already translated to $TRANSLATED above)
_first_directive_full=$(grep -v '^\s*#\|^\s*$' "$TRANSLATED" | head -1)

# Parity 2: minimal-config translation
_shim_out="${CACHE_DIR}/ssh-config-shim-check"
_translate_ssh_config "${SSH_DIR}/config-minimal" "$_shim_out" "id_ed25519_personal"
_first_directive_min=$(grep -v '^\s*#\|^\s*$' "$_shim_out" | head -1)

if [[ "$_first_directive_full" == IgnoreUnknown* && "$_first_directive_min" == IgnoreUnknown* ]]; then
  _pass 6 "IgnoreUnknown shim parity: first non-blank non-comment directive in both full-config and minimal-config translations"
else
  _reason=""
  [[ "$_first_directive_full" != IgnoreUnknown* ]] && _reason="full-config first directive: '${_first_directive_full}'"
  [[ "$_first_directive_min" != IgnoreUnknown* ]] && _reason="${_reason:+$_reason; }minimal-config first directive: '${_first_directive_min}'"
  _fail 6 "IgnoreUnknown shim parity" "$_reason"
fi

# ===========================================================================
# CHECK 7/17: Transform — synthesized Host github.com with IdentitiesOnly yes
# ---------------------------------------------------------------------------
# When a pin is resolved and the user's config has no Host github.com block,
# the translator appends a synthesized block containing IdentitiesOnly yes.
# This is the correctness contract for D4: IdentitiesOnly prevents first-key-wins.
# (Uses the same minimal output as check 6.)
# ===========================================================================
_github_block=$(grep "^Host github.com" "$_shim_out" || true)
_identities_only=$(grep -v '^\s*#' "$_shim_out" | grep -i 'IdentitiesOnly yes' || true)

if [[ -n "$_github_block" && -n "$_identities_only" ]]; then
  _pass 7 "synthesized Host github.com with IdentitiesOnly yes"
else
  _reason=""
  [[ -z "$_github_block" ]] && _reason="Host github.com block absent"
  [[ -z "$_identities_only" ]] && _reason="${_reason:+$_reason; }IdentitiesOnly yes absent"
  _fail 7 "synthesized Host github.com + IdentitiesOnly yes" "$_reason"
fi

# ===========================================================================
# CHECK 8/17: Pubkey allowlist — only .pub files in the mount set
# ---------------------------------------------------------------------------
# _derive_pubkey_allowlist parses the translated config and emits basenames.
# Every emitted basename must end with .pub — no private-key names allowed.
# Private key names without .pub suffix would violate ADR-017 D1.
# ===========================================================================
_translate_ssh_config "${SSH_DIR}/config-full" "$TRANSLATED" ""

_allowlist=$(_derive_pubkey_allowlist "$TRANSLATED")
_bad_pub_entries=""
while IFS= read -r _entry; do
  [[ -z "$_entry" ]] && continue
  [[ "$_entry" != *.pub ]] && _bad_pub_entries="${_bad_pub_entries}${_entry} "
done <<< "$_allowlist"

if [[ -z "$_bad_pub_entries" && -n "$_allowlist" ]]; then
  _pass 8 "pubkey allowlist: all entries have .pub suffix (no private-key basenames)"
else
  _reason=""
  [[ -z "$_allowlist" ]] && _reason="allowlist is empty"
  [[ -n "$_bad_pub_entries" ]] && _reason="non-.pub entries: ${_bad_pub_entries}"
  _fail 8 "pubkey allowlist — only .pub entries" "$_reason"
fi

# ===========================================================================
# CHECK 9/17: Pubkey mount — no non-.pub file in mount set
# ---------------------------------------------------------------------------
# _build_ssh_mount_args generates --mount args. Inspect every src= value:
# files under .ssh/ must be .pub, known_hosts, or the translated config itself.
# id_unrelated.pub (created above but not referenced) must NOT appear.
# ===========================================================================
_mount_args=()
_build_ssh_mount_args "$TRANSLATED" "integration-test" _mount_args

_private_key_mounts=""
_unrelated_mounts=""
for _arg in "${_mount_args[@]}"; do
  if [[ "$_arg" =~ src=([^,]+) ]]; then
    _src="${BASH_REMATCH[1]}"
    if [[ "$_src" == *"/.ssh/"* ]]; then
      _bn="${_src##*/}"
      # Must not be a private key (file under .ssh without .pub suffix, config, or known_hosts)
      if [[ "$_bn" != *.pub && "$_bn" != "config" && "$_bn" != "known_hosts" ]]; then
        _private_key_mounts="${_private_key_mounts}${_src} "
      fi
      # Unrelated pub should not appear (not referenced by any IdentityFile)
      [[ "$_bn" == "id_unrelated.pub" ]] && _unrelated_mounts="${_unrelated_mounts}${_src} "
    fi
  fi
done

if [[ -z "$_private_key_mounts" && -z "$_unrelated_mounts" ]]; then
  _pass 9 "pubkey mount: no private-key paths; unreferenced id_unrelated.pub excluded"
else
  _reason=""
  [[ -n "$_private_key_mounts" ]] && _reason="private-key paths in mounts: ${_private_key_mounts}"
  [[ -n "$_unrelated_mounts" ]] && _reason="${_reason:+$_reason; }unreferenced .pub mounted: ${_unrelated_mounts}"
  _fail 9 "pubkey mount — no non-.pub in mount set" "$_reason"
fi

# ===========================================================================
# CHECK 10/17: Resolution layer 1 — CLI flag wins
# ---------------------------------------------------------------------------
# _resolve_github_identity(cli_flag, container, path, rules_file) with a
# non-empty cli_flag must return the cli_flag value regardless of rules file.
# ===========================================================================
cat > "$RULES_FILE" <<'RULES'
~/code/mapular/*    id_ed25519_work
~/code/personal/*   id_ed25519_personal
RULES

# CLI flag beats rules-file match (path would match personal, flag says work)
_r10=$(_resolve_github_identity "id_ed25519_work" "" "${HOME}/code/personal/my-project" "$RULES_FILE")
if [[ "$_r10" == "id_ed25519_work" ]]; then
  _pass 10 "resolution layer 1 (CLI flag): id_ed25519_work returned regardless of rules-file match"
else
  _fail 10 "resolution layer 1 (CLI flag)" "expected id_ed25519_work, got '${_r10}'"
fi

# ===========================================================================
# CHECK 11/17: Resolution layer 2 — container label/resume preserved
# ---------------------------------------------------------------------------
# When a container already has rc.github-identity=id_ed25519_work label (resume),
# _resolve_github_identity with no CLI flag reads the label and returns it.
# We simulate label reading: the function calls docker inspect internally;
# we use the stub docker that returns our planted label value.
# ===========================================================================
# Stub docker inspect to return the label value
# The rc function _resolve_github_identity calls: docker inspect --format '...' "$container"
# We plant a stub that returns the label value for any inspect call.
cat > "${STUB_BIN}/docker" <<'DOCKERSTUB2'
#!/usr/bin/env bash
GREETING_FILE="${TMPDIR_TEST_STUB}/greeting"
STUB_RC_FILE="${TMPDIR_TEST_STUB}/stub_rc"
STUB_GREETING="Hi stub-user!"
STUB_RC=0
[[ -f "$GREETING_FILE" ]] && STUB_GREETING=$(cat "$GREETING_FILE")
[[ -f "$STUB_RC_FILE" ]]  && STUB_RC=$(cat "$STUB_RC_FILE")

if [[ "$1" == "exec" ]]; then
  shift
  while [[ $# -gt 0 && "$1" != "ssh" ]]; do shift; done
  if [[ "$1" == "ssh" ]]; then
    if [[ "$STUB_RC" == "0" ]]; then echo "$STUB_GREETING" >&2; exit 0; else exit 255; fi
  fi
fi

if [[ "$1" == "inspect" ]]; then
  LABEL_FILE="${TMPDIR_TEST_STUB}/stub_label"
  [[ -f "$LABEL_FILE" ]] && cat "$LABEL_FILE" || echo ""
  exit 0
fi

# ps: return empty (no containers listed)
if [[ "$1" == "ps" ]]; then
  exit 0
fi

exit 0
DOCKERSTUB2
chmod +x "${STUB_BIN}/docker"

# Plant the label for a fake container name
_set_container_label "id_ed25519_work"

# Resolve with stub docker in PATH: no CLI flag, existing container "my-cage"
_r11=$(PATH="${STUB_BIN}:${PATH}" _resolve_github_identity "" "my-cage" "${HOME}/code/personal/rip-cage" "$RULES_FILE")

_set_container_label ""  # reset

if [[ "$_r11" == "id_ed25519_work" ]]; then
  _pass 11 "resolution layer 2 (label/resume): id_ed25519_work preserved from container label"
else
  _fail 11 "resolution layer 2 (label/resume)" "expected id_ed25519_work from label, got '${_r11}'"
fi

# ===========================================================================
# CHECK 12/17: Resolution layer 3 — rules-file match
# ---------------------------------------------------------------------------
# With no CLI flag and no container label, the rules file is consulted.
# A path matching ~/code/mapular/* must return id_ed25519_work.
# This check fails independently when the rules-file lookup is broken,
# even if the no-match fallback (layer 4) still works correctly.
# ===========================================================================
_r12=$(_resolve_github_identity "" "" "${HOME}/code/mapular/mapular-gtm" "$RULES_FILE")

if [[ "$_r12" == "id_ed25519_work" ]]; then
  _pass 12 "resolution layer 3 (rules-file match): ~/code/mapular/* matched → id_ed25519_work"
else
  _fail 12 "resolution layer 3 (rules-file match)" "expected id_ed25519_work, got '${_r12}'"
fi

# ===========================================================================
# CHECK 13/17: Resolution layer 4 — no-match fallback (loud unset)
# ---------------------------------------------------------------------------
# When no CLI flag, no container label, and no rules-file match, the resolver
# returns empty string. This triggers the "loud unset" banner path — no silent
# first-key-wins. A path under /tmp does not match ~/code/* patterns.
# This check fails independently when the no-match fallback is broken,
# even if rules-file matching (layer 3) still works correctly.
# ===========================================================================
_r13=$(_resolve_github_identity "" "" "/tmp/some-project" "$RULES_FILE")

if [[ -z "$_r13" ]]; then
  _pass 13 "resolution layer 4 (no-match): unmatched path → empty (loud unset)"
else
  _fail 13 "resolution layer 4 (no-match)" "expected empty, got '${_r13}'"
fi

# ===========================================================================
# CHECK 14/17: Explicit-pin missing-pubkey abort
# ---------------------------------------------------------------------------
# When the resolved identity names a key whose .pub file does not exist on
# the host, rc up must abort (exit non-zero) and the error must name the
# missing file. `_assert_pubkey_exists_or_die` implements this for layers 1-3.
# ===========================================================================
_exit14=0
_stderr14=$(_assert_pubkey_exists_or_die "id_ed25519_missing" "explicit" 2>&1) || _exit14=$?

if [[ "$_exit14" -ne 0 && $(echo "$_stderr14" | grep -c "id_ed25519_missing") -ge 1 ]]; then
  _pass 14 "explicit-pin missing-pubkey abort: exit non-zero, error names id_ed25519_missing"
else
  _reason=""
  [[ "$_exit14" -eq 0 ]] && _reason="exited 0 (should be non-zero)"
  [[ $(echo "$_stderr14" | grep -c "id_ed25519_missing") -lt 1 ]] && _reason="${_reason:+$_reason; }missing filename absent from error"
  _fail 14 "explicit-pin missing-pubkey abort" "$_reason"
fi

# ===========================================================================
# CHECK 15/17: Live-GitHub greeting probe (SKIP unless RC_TEST_E2E + network)
# ---------------------------------------------------------------------------
# When the cage has a working ssh-agent and can reach github.com, the greeting
# probe `ssh -T git@github.com` returns "Hi <user>!". This check verifies the
# probe returns a username (non-empty, no error). Requires live network and
# a loaded ssh-agent key. SKIPped in standard host-side runs per ADR-013 D1.
# ===========================================================================
_can_reach_github=false
if [[ "${RC_TEST_E2E:-}" == "1" ]]; then
  # Quick TCP probe to github.com:22 with 5s timeout
  if timeout 5 bash -c 'cat /dev/null > /dev/tcp/github.com/22' 2>/dev/null; then
    _can_reach_github=true
  fi
fi

if [[ "$_can_reach_github" == "true" ]]; then
  _greeting=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no git@github.com 2>&1 \
    | sed -n 's/^Hi \([^!]*\)!.*/\1/p' || true)
  if [[ -n "$_greeting" ]]; then
    _pass 15 "live-GitHub greeting probe returned user: ${_greeting}"
  else
    _fail 15 "live-GitHub greeting probe" "greeting empty — check ssh-agent keys loaded"
  fi
else
  _skip 15 "live-GitHub greeting probe"
fi

# ===========================================================================
# CHECK 16/17: Sentinel write-path/ownership (AC8 dedicated check)
# ---------------------------------------------------------------------------
# _up_github_identity_preflight must write sentinel files to the path set by
# RC_PREFLIGHT_SENTINEL_DIR. This check calls the preflight function with
# source_layer=disabled (no docker call needed, cleanest test-mode path) and
# verifies: (a) both sentinel files are created at the expected path, and
# (b) each file contains the expected content string.
#
# Host-side proxy note: in test mode files are owned by the current user (not
# root:644). The root:644 ownership invariant is enforced inside the container
# by `docker exec --user root … chmod 644`, which is not verifiable without a
# live container. The proxy here is strictly stronger than a code-inspection
# check: it asserts the writer actually creates the files with the correct
# content shape, not just that readers don't write.
# ===========================================================================
_sent_dir="${TMPDIR_TEST}/sentinels-check16"
mkdir -p "$_sent_dir"

RC_PREFLIGHT_SENTINEL_DIR="$_sent_dir" _up_github_identity_preflight "test-container" "" "disabled" 2>/dev/null || true

_gi_file="${_sent_dir}/github-identity"
_src_file="${_sent_dir}/ssh-config-source"

_gi_content=""
_src_content=""
[[ -f "$_gi_file" ]] && _gi_content=$(cat "$_gi_file")
[[ -f "$_src_file" ]] && _src_content=$(cat "$_src_file")

if [[ -f "$_gi_file" && -f "$_src_file" && "$_gi_content" == "disabled" && "$_src_content" == "disabled" ]]; then
  _pass 16 "sentinel write-path: both sentinel files created at RC_PREFLIGHT_SENTINEL_DIR with expected content (host-side proxy; root:644 enforced inside container by docker exec --user root)"
else
  _reason=""
  [[ ! -f "$_gi_file" ]] && _reason="github-identity sentinel file not created"
  [[ ! -f "$_src_file" ]] && _reason="${_reason:+$_reason; }ssh-config-source sentinel file not created"
  [[ -f "$_gi_file" && "$_gi_content" != "disabled" ]] && _reason="${_reason:+$_reason; }github-identity content='${_gi_content}' (expected 'disabled')"
  [[ -f "$_src_file" && "$_src_content" != "disabled" ]] && _reason="${_reason:+$_reason; }ssh-config-source content='${_src_content}' (expected 'disabled')"
  _fail 16 "sentinel write-path/ownership" "$_reason"
fi

# ===========================================================================
# CHECK 17/17: Resume + opt-out behaviors
# ---------------------------------------------------------------------------
# (a) Re-translation idempotent: _translate_ssh_config run twice on the same
#     input produces identical output (stable per-container path is always
#     overwritten, never stale). This is the host-side property of resume.
# (b) CLI-override-on-resume: _up_resolve_resume_github_identity errors loud
#     when the existing container label differs from the new CLI flag value.
#     This prevents silent identity drift across resume calls.
# (c) --no-ssh-config: _resolve_ssh_config_posture("off","","on") → posture=off;
#     posture=off → _build_ssh_mount_args_with_posture returns empty mount args.
# (d) --no-forward-ssh implies off: _resolve_ssh_config_posture("","","off") → off.
# (e) --no-forward-ssh --ssh-config overrides: _resolve_ssh_config_posture("","on","off") → on.
# ===========================================================================
_out16a="${CACHE_DIR}/ssh-config-run1"
_out16b="${CACHE_DIR}/ssh-config-run2"
_translate_ssh_config "${SSH_DIR}/config-full" "$_out16a" "id_ed25519_personal"
_translate_ssh_config "${SSH_DIR}/config-full" "$_out16b" "id_ed25519_personal"
_idempotent=false
diff "$_out16a" "$_out16b" >/dev/null 2>&1 && _idempotent=true

# CLI-override-on-resume: _up_resolve_resume_github_identity(name, path, cli_flag)
# should exit non-zero when existing container label != cli_flag (both non-empty).
# The stub docker returns "id_ed25519_work" for any inspect call (planted label).
_set_container_label "id_ed25519_work"
_resume_exit=0
_resume_err=$(PATH="${STUB_BIN}:${PATH}" _up_resolve_resume_github_identity "my-cage" "/some/path" "id_ed25519_personal" 2>&1) || _resume_exit=$?
_set_container_label ""

_posture_no_ssh=$(_resolve_ssh_config_posture "off" "" "on")
_posture_no_fwd=$(_resolve_ssh_config_posture "" "" "off")
_posture_override=$(_resolve_ssh_config_posture "" "on" "off")

_no_ssh_mounts=()
_build_ssh_mount_args_with_posture "$TRANSLATED" "integration-test" _no_ssh_mounts "off"

if [[ "$_idempotent" == "true" \
   && "$_resume_exit" -ne 0 \
   && "$_posture_no_ssh" == "off" \
   && "$_posture_no_fwd" == "off" \
   && "$_posture_override" == "on" \
   && "${#_no_ssh_mounts[@]}" -eq 0 ]]; then
  _pass 17 "resume idempotent; CLI-override-on-resume exits non-zero; --no-ssh-config posture=off; --no-forward-ssh implies off; --ssh-config overrides to on"
else
  _reason=""
  [[ "$_idempotent" == "false" ]] && _reason="two runs on same input differ"
  [[ "$_resume_exit" -eq 0 ]] && _reason="${_reason:+$_reason; }CLI-override-on-resume exited 0 (should be non-zero)"
  [[ "$_posture_no_ssh" != "off" ]] && _reason="${_reason:+$_reason; }--no-ssh-config posture='${_posture_no_ssh}' (expected off)"
  [[ "$_posture_no_fwd" != "off" ]] && _reason="${_reason:+$_reason; }--no-forward-ssh posture='${_posture_no_fwd}' (expected off)"
  [[ "$_posture_override" != "on" ]] && _reason="${_reason:+$_reason; }--no-forward-ssh --ssh-config posture='${_posture_override}' (expected on)"
  [[ "${#_no_ssh_mounts[@]}" -ne 0 ]] && _reason="${_reason:+$_reason; }posture=off produced ${#_no_ssh_mounts[@]} mounts"
  _fail 17 "resume + opt-out behaviors" "$_reason"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "--- Results: ${FAILURES} failure(s) out of ${TOTAL} checks ---"
exit "$FAILURES"
