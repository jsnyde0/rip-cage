#!/usr/bin/env bash
set -euo pipefail
PASS=0
FAIL=0
TOTAL=0

# SKIP_AUTH=1: auth/beads/git-identity checks become INFO-only (no FAIL contribution).
# Use in integration tests running without real credentials.
SKIP_AUTH="${SKIP_AUTH:-0}"

check() {
  local name="$1" result="$2" detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [[ "$result" == "pass" ]]; then
    echo "PASS  [$TOTAL] $name${detail:+ — $detail}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  [$TOTAL] $name${detail:+ — $detail}"
    FAIL=$((FAIL + 1))
  fi
}

# check_auth: like check, but when SKIP_AUTH=1, a failing result is printed as
# INFO/SKIPPED and does NOT increment FAIL.
check_auth() {
  local name="$1" result="$2" detail="${3:-}"
  if [[ "$SKIP_AUTH" == "1" && "$result" != "pass" ]]; then
    TOTAL=$((TOTAL + 1))
    echo "INFO  [$TOTAL] $name (auth-skipped)${detail:+ — $detail}"
  else
    check "$name" "$result" "$detail"
  fi
}

# ---------------------------------------------------------------------------
# assert-present generic runner (rip-cage-m8zc) — sourced from shared lib
# ---------------------------------------------------------------------------
# Defines RC_ASSERTED_FILE default and _run_asserted_checks().
# Both this file and test-mount-seam-integration.sh source the SAME lib
# (no divorced copy — single-source principle).
# In-cage: both files live in /usr/local/lib/rip-cage/ — dirname resolves correctly.
# Host/CI: both files live in tests/ — dirname resolves correctly.
# shellcheck source=tests/_safety-stack-assert-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_safety-stack-assert-lib.sh"

echo "=== Rip Cage Health Check ==="
echo ""

# --- User & Environment ---
echo "-- User & Environment --"

# 1. Container user is agent
user=$(whoami 2>/dev/null || echo "unknown")
check "Container user is agent" "$([[ "$user" == "agent" ]] && echo pass || echo fail)" "$user"

# 2. Not running as root
uid=$(id -u 2>/dev/null || echo "0")
check "Not running as root" "$([[ "$uid" != "0" ]] && echo pass || echo fail)" "uid=$uid"

# 3. /workspace is mounted
check "/workspace is mounted" "$([[ -d /workspace ]] && echo pass || echo fail)"

# 4. /workspace is writable
if touch /workspace/.rc-test-write 2>/dev/null && rm -f /workspace/.rc-test-write; then
  check "/workspace is writable" "pass"
else
  check "/workspace is writable" "fail"
fi

echo ""
echo "-- Settings & Safety Stack --"

# 5. settings.json exists
check "settings.json exists" "$([[ -f ~/.claude/settings.json ]] && echo pass || echo fail)"

# 6. settings.json is valid JSON
if jq . < ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json is valid JSON" "pass"
else
  check "settings.json is valid JSON" "fail"
fi

# 7. settings.json has bypassPermissions mode
if jq -e '.permissions.defaultMode == "bypassPermissions"' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json has bypassPermissions mode" "pass"
else
  check "settings.json has bypassPermissions mode" "fail"
fi

# 8. managed-settings.json — floor-lock check (name-free, ADR-027 D1/D3).
# Asserts THREE properties, all without naming any specific guard:
#   (i)   managed-settings.json file + parent dir are root-owned (write-gate floor)
#   (ii)  .hooks.PreToolUse | length > 0 in the MANAGED file (layer-placement — at least
#         one hook is wired in the root-owned layer, not merely in agent-writable settings.json)
#   (iii) agent-writable settings.json self-disable vector: if managed-settings.json is ABSENT
#         but settings.json contains a PreToolUse hook, the hook lives in the agent-writable
#         layer and the agent could remove it (self-disable vector open).
#
# Composable recipe note (rip-cage-wlwc.2.2): managed-settings.json is provisioned by the
# examples/claude recipe, NOT baked into the base image. A cage built from the bare in-repo
# default manifest has no managed-settings.json; assertions only fire when the file is present.
if [[ -f /etc/claude-code/managed-settings.json ]]; then
  _ms8_file_owner=$(stat -c '%U' /etc/claude-code/managed-settings.json 2>/dev/null || echo "unknown")
  _ms8_dir_owner=$(stat -c '%U' /etc/claude-code 2>/dev/null || echo "unknown")
  _ms8_hook_count=$(jq '.hooks.PreToolUse | length' /etc/claude-code/managed-settings.json 2>/dev/null || echo "0")
  if [[ "$_ms8_file_owner" != "root" ]]; then
    check "managed-settings.json floor-lock: file + dir root-owned, PreToolUse wired in managed layer (ADR-027 D1/D3)" "fail" \
      "file owner='$_ms8_file_owner' (expected root) — agent can overwrite/replace"
  elif [[ "$_ms8_dir_owner" != "root" ]]; then
    check "managed-settings.json floor-lock: file + dir root-owned, PreToolUse wired in managed layer (ADR-027 D1/D3)" "fail" \
      "dir /etc/claude-code owner='$_ms8_dir_owner' (expected root) — agent can inject new files or unlink+replace"
  elif [[ "$_ms8_hook_count" -lt 1 ]]; then
    check "managed-settings.json floor-lock: file + dir root-owned, PreToolUse wired in managed layer (ADR-027 D1/D3)" "fail" \
      "managed-settings.json is root-owned BUT .hooks.PreToolUse | length = $_ms8_hook_count (no hook in managed layer — layer-placement floor not met)"
  else
    check "managed-settings.json floor-lock: file + dir root-owned, PreToolUse wired in managed layer (ADR-027 D1/D3)" "pass" \
      "file owner=$_ms8_file_owner dir owner=$_ms8_dir_owner PreToolUse hooks=$_ms8_hook_count"
  fi
  unset _ms8_file_owner _ms8_dir_owner _ms8_hook_count
  # (iii) agent-writable-settings.json self-disable-vector check: if PreToolUse ONLY in agent-writable
  # settings.json (not in managed), the hook can be self-disabled. Managed file is present, so
  # the self-disable vector is closed via managed layer (no additional check needed here).
else
  # managed-settings.json absent — check the self-disable vector in agent-writable settings.json.
  # If ANY PreToolUse hook lives only in agent-writable settings.json, report it as a vector.
  _ms8_agent_hooks=$(jq '.hooks.PreToolUse | length' ~/.claude/settings.json 2>/dev/null || echo "0")
  if [[ "$_ms8_agent_hooks" -gt 0 ]]; then
    check "managed-settings.json floor-lock: self-disable vector (ADR-027 D3)" "fail" \
      "managed-settings.json ABSENT but PreToolUse hooks found in agent-writable settings.json — hooks live in agent-writable layer (self-disable vector open)"
  else
    TOTAL=$((TOTAL + 1))
    echo "INFO  [$TOTAL] managed-settings.json absent — CC floor-lock is a composable recipe (examples/claude), not composed in this cage; no hooks in agent-writable settings.json (self-disable vector not applicable)"
  fi
  unset _ms8_agent_hooks
fi

# 9. settings.json denies .git/hooks writes (floor property, name-free)
if jq -e '.permissions.deny[] | select(startswith("Write(.git/hooks"))' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json denies .git/hooks writes" "pass"
else
  check "settings.json denies .git/hooks writes" "fail"
fi

# 10-assert. Generic assert-present check (rip-cage-m8zc).
# Runs every declared-required tool's baked check from the asserted-file.
# File absent = minimal cage (valid; no assertions baked). File present = run checks.
# Also verifies root-ownership of the file + parent dir (fail-closed trust requirement).
if [[ -f "${RC_ASSERTED_FILE}" ]]; then
  # Confirm the asserted-file and its parent dir are root-owned (fail-closed per F3 fix).
  _ssa_file_owner=$(stat -c '%U' "${RC_ASSERTED_FILE}" 2>/dev/null || echo "unknown")
  _ssa_dir_owner=$(stat -c '%U' "$(dirname "${RC_ASSERTED_FILE}")" 2>/dev/null || echo "unknown")
  if [[ "$_ssa_file_owner" == "root" && "$_ssa_dir_owner" == "root" ]]; then
    check "safety-stack-asserted file+dir root-owned (rip-cage-m8zc)" "pass" \
      "file=${RC_ASSERTED_FILE} owner=${_ssa_file_owner} dir owner=${_ssa_dir_owner}"
  else
    check "safety-stack-asserted NOT root-owned (rip-cage-m8zc)" "fail" \
      "file owner='${_ssa_file_owner}' dir owner='${_ssa_dir_owner}' (expected root:root) — agent-writable declaration is untrustworthy"
  fi
  unset _ssa_file_owner _ssa_dir_owner
  # Run all declared-required tool checks from the baked asserted-file (generic, name-free).
  _run_asserted_checks
else
  TOTAL=$((TOTAL + 1))
  echo "INFO  [$TOTAL] safety-stack-asserted absent (minimal cage — no required tools declared; valid state)"
fi

# Recipe-specific behavioral smoke tests have been moved to co-located recipe smoke tests
# (examples/dcg/smoke.sh, examples/ssh-bypass/smoke.sh) run by the generic name-free
# runner (run-recipe-smokes.sh) per rip-cage-wiwa (ADR-025 D2 clarification).

echo ""
echo "-- Auth --"

# 13. Auth present (credentials file OR API key)
if [[ -s ~/.claude/.credentials.json ]] || [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  check_auth "Auth present" "pass" "$([[ -s ~/.claude/.credentials.json ]] && echo "OAuth" || echo "API key")"
else
  check_auth "Auth present" "fail" "no credentials file and no ANTHROPIC_API_KEY"
fi

# 14. Token not expired (skip if using API key only)
if [[ -s ~/.claude/.credentials.json ]] && command -v jq &>/dev/null; then
  expiry=$(jq -r '.expiry // .expiresAt // empty' ~/.claude/.credentials.json 2>/dev/null || true)
  if [[ -n "$expiry" ]]; then
    expiry_epoch=$(date -d "$expiry" "+%s" 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${expiry%%.*}" "+%s" 2>/dev/null || true)
    now_epoch=$(date "+%s")
    if [[ -n "$expiry_epoch" ]] && [[ "$expiry_epoch" -gt "$now_epoch" ]]; then
      remaining=$(( (expiry_epoch - now_epoch) / 60 ))
      check_auth "Token not expired" "pass" "${remaining}m remaining"
    elif [[ -n "$expiry_epoch" ]]; then
      check_auth "Token not expired" "fail" "expired"
    else
      check_auth "Token not expired" "pass" "could not parse expiry (skipped)"
    fi
  else
    check_auth "Token not expired" "pass" "no expiry field (skipped)"
  fi
else
  check_auth "Token not expired" "pass" "no credentials file (skipped)"
fi

echo ""
echo "-- Git --"

# 15. git available and identity set
git_name=$(git config user.name 2>/dev/null || true)
git_email=$(git config user.email 2>/dev/null || true)
if [[ -n "$git_name" ]] && [[ -n "$git_email" ]]; then
  check_auth "git identity set" "pass" "$git_name <$git_email>"
else
  check_auth "git identity set" "fail" "name='$git_name' email='$git_email'"
fi

echo ""
echo "-- Tools --"

# 16-24. Tool availability checks
for tool_check in \
  "claude:claude --version" \
  "jq:jq --version" \
  "tmux:tmux -V" \
  "bd:bd --version" \
  "python3:python3 --version" \
  "uv:uv --version" \
  "node:node --version" \
  "bun:bun --version" \
  "gh:gh --version"; do
  tool_name="${tool_check%%:*}"
  tool_cmd="${tool_check#*:}"
  if command -v "$tool_name" &>/dev/null; then
    version=$($tool_cmd 2>&1 | head -1 || true)
    check "$tool_name available" "pass" "$version"
  else
    check "$tool_name available" "fail" "not installed"
  fi
done

echo ""
echo "-- Beads (functional) --"

# 25. bd can access beads data (embedded Dolt on bind mount, or host Dolt server)
if [ -d /workspace/.beads ]; then
  bd_output=$(cd /workspace && bd list 2>&1 || true)
  if echo "$bd_output" | grep -qE "(Total:|No issues found)"; then
    issue_count=$(echo "$bd_output" | sed -n 's/.*Total: \([0-9]*\).*/\1/p')
    check_auth "bd can access beads data" "pass" "${issue_count} issues"
  else
    bd_err=$(echo "$bd_output" | head -1)
    check_auth "bd can access beads data" "fail" "$bd_err"
  fi
else
  check_auth "bd can access beads data" "pass" "no .beads/ in workspace (skipped)"
fi

echo ""
echo "-- Beads Wrapper --"

# 26. bd is a shell script (shebang check — file command not available in container)
bd_shebang=$(head -c 2 /usr/local/bin/bd 2>/dev/null || true)
check "bd is a shell script (shebang check)" "$([[ "$bd_shebang" == "#!" ]] && echo pass || echo fail)" "$bd_shebang"

# 27. bd-real exists and is executable
check "bd-real exists and is executable" "$([[ -x /usr/local/bin/bd-real ]] && echo pass || echo fail)"

# 28. bd dolt start is blocked when BEADS_DOLT_SERVER_MODE=1
wrapper_block=$(BEADS_DOLT_SERVER_MODE=1 /usr/local/bin/bd dolt start 2>&1 || true)
if echo "$wrapper_block" | grep -q "BLOCKED"; then
  check "bd dolt start blocked (BEADS_DOLT_SERVER_MODE=1)" "pass"
else
  check "bd dolt start blocked (BEADS_DOLT_SERVER_MODE=1)" "fail" "$wrapper_block"
fi

# 29. --verbose flag bypass prevented
wrapper_verbose=$(BEADS_DOLT_SERVER_MODE=1 /usr/local/bin/bd --verbose dolt start 2>&1 || true)
if echo "$wrapper_verbose" | grep -q "BLOCKED"; then
  check "bd --verbose dolt start blocked (flag bypass prevented)" "pass"
else
  check "bd --verbose dolt start blocked (flag bypass prevented)" "fail" "$wrapper_verbose"
fi

# 30. bd dolt stop is NOT blocked (ADR-007 D2)
wrapper_stop=$(BEADS_DOLT_SERVER_MODE=1 /usr/local/bin/bd dolt stop 2>&1 || true)
if echo "$wrapper_stop" | grep -q "BLOCKED"; then
  check "bd dolt stop NOT blocked (ADR-007 D2)" "fail" "got BLOCKED unexpectedly"
else
  check "bd dolt stop NOT blocked (ADR-007 D2)" "pass"
fi

echo ""
echo "-- Network & Disk --"

# 31. DNS resolution
if getent hosts github.com >/dev/null 2>&1 || dig +short github.com >/dev/null 2>&1 || host github.com >/dev/null 2>&1; then
  check "DNS resolution (github.com)" "pass"
else
  check "DNS resolution (github.com)" "fail"
fi

# 32. Sufficient disk space (>1GB free on /workspace)
avail_kb=$(df /workspace 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
avail_gb=$(( avail_kb / 1048576 ))
if [[ "$avail_kb" -gt 1048576 ]]; then
  check "Disk space >1GB on /workspace" "pass" "${avail_gb}GB free"
else
  check "Disk space >1GB on /workspace" "fail" "${avail_gb}GB free"
fi

echo ""
echo "-- Git Hooks Protection --"

# 33. .git/hooks is read-only (write attempt fails)
# D11: physical enforcement against container escape via bind-mount
if [[ -d /workspace/.git/hooks ]]; then
  if touch /workspace/.git/hooks/.rc-test-write 2>/dev/null; then
    rm -f /workspace/.git/hooks/.rc-test-write
    check ".git/hooks is read-only (D11)" "fail" "write succeeded — hooks are NOT read-only"
  else
    check ".git/hooks is read-only (D11)" "pass"
  fi
else
  check ".git/hooks is read-only (D11)" "pass" "no .git/hooks directory (skipped)"
fi

# 34. Python write bypass blocked: python3 open() to .git/hooks must fail
# D11: verifies the ro sub-mount blocks filesystem-level writes, not just tool-level denies
if [[ -d /workspace/.git/hooks ]]; then
  python_result=$(python3 -c "open('/workspace/.git/hooks/test-probe', 'w')" 2>&1 || true)
  if echo "$python_result" | grep -qiE "(Read-only file system|Permission denied|OSError|IOError)"; then
    check "Python write to .git/hooks blocked (D11)" "pass"
  else
    check "Python write to .git/hooks blocked (D11)" "fail" "python3 open() succeeded or unexpected error: $python_result"
  fi
else
  check "Python write to .git/hooks blocked (D11)" "pass" "no .git/hooks directory (skipped)"
fi

# 35. KNOWN accepted risk: core.hooksPath redirect is a documented accepted risk
# An agent can redirect git hooks via `git config core.hooksPath` to a writable path.
# This is accepted: multi-step, deliberate, and consistent with container-as-boundary (D5).
# See: docs/2026-04-09-git-hooks-ro-bind-mount-design.md — Accepted Risks section.
check "KNOWN: core.hooksPath redirect is accepted risk (see design doc)" "pass" "documented in D11 design"

if [[ -d /workspace/.git-main ]]; then
  echo ""
  echo "-- Worktree Git --"

  # 36. Git functional: git status exits 0
  if git -C /workspace status >/dev/null 2>&1; then
    check "Git functional (git status exits 0)" "pass"
  else
    check "Git functional (git status exits 0)" "fail" "git status failed"
  fi

  # 37. Git pointer valid: /workspace/.git contains gitdir: pointing to an existing path
  git_file_content=$(cat /workspace/.git 2>/dev/null || true)
  if [[ "$git_file_content" == gitdir:\ * ]]; then
    gitdir_path="${git_file_content#gitdir: }"
    if [[ -e "$gitdir_path" ]]; then
      check "Git pointer valid (.git contains gitdir: to existing path)" "pass" "$gitdir_path"
    else
      check "Git pointer valid (.git contains gitdir: to existing path)" "fail" "path does not exist: $gitdir_path"
    fi
  else
    check "Git pointer valid (.git contains gitdir: to existing path)" "fail" "no gitdir: line in /workspace/.git"
  fi

  # 38. Worktree correct: git rev-parse --show-toplevel returns /workspace
  toplevel=$(git -C /workspace rev-parse --show-toplevel 2>/dev/null || true)
  check "Worktree correct (show-toplevel is /workspace)" "$([[ "$toplevel" == "/workspace" ]] && echo pass || echo fail)" "$toplevel"

  # 39. Hooks protected: /workspace/.git-main/hooks is read-only (write attempt fails)
  if touch /workspace/.git-main/hooks/.rc-test-write 2>/dev/null; then
    rm -f /workspace/.git-main/hooks/.rc-test-write
    check "Hooks protected (read-only mount)" "fail" "write succeeded — hooks are NOT read-only"
  else
    check "Hooks protected (read-only mount)" "pass"
  fi

  # 40. Objects accessible: git log --oneline -1 returns a commit
  git_log=$(git -C /workspace log --oneline -1 2>/dev/null || true)
  if [[ -n "$git_log" ]]; then
    check "Objects accessible (git log --oneline -1)" "pass" "$git_log"
  else
    check "Objects accessible (git log --oneline -1)" "fail" "no output from git log"
  fi
fi

echo ""
echo "-- Non-Interactive SSH Posture --"

# SSH_N1. BatchMode=yes is resolved via ssh -G
ssh_batchmode=$(ssh -G github.com 2>/dev/null | grep -E '^batchmode ' || true)
check "SSH BatchMode=yes resolved" "$([[ "$ssh_batchmode" == "batchmode yes" ]] && echo pass || echo fail)" "$ssh_batchmode"

# SSH_N2. StrictHostKeyChecking=yes (OpenSSH 9.2 on bookworm may normalize to 'true')
ssh_strict=$(ssh -G github.com 2>/dev/null | grep -E '^stricthostkeychecking ' || true)
check "SSH StrictHostKeyChecking=yes resolved" "$(echo "$ssh_strict" | grep -qE '^stricthostkeychecking (yes|true)$' && echo pass || echo fail)" "$ssh_strict"

# SSH_N3. UserKnownHostsFile is the dual-file form (ADR-022 D4 / rip-cage-g2q):
# filtered user-path file first (entries from ssh.allowed_hosts) + system-path
# floor (image-baked github.com pins). Both paths must appear in ssh -G output.
ssh_ukhf=$(ssh -G github.com 2>/dev/null | grep -E '^userknownhostsfile ' || true)
check "SSH UserKnownHostsFile dual-file (user filtered + system floor)" "$([[ "$ssh_ukhf" == "userknownhostsfile /home/agent/.ssh/known_hosts /etc/ssh/ssh_known_hosts" ]] && echo pass || echo fail)" "$ssh_ukhf"

# SSH_N4. GlobalKnownHostsFile points to pinned file
ssh_gkhf=$(ssh -G github.com 2>/dev/null | grep -E '^globalknownhostsfile ' || true)
check "SSH GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts" "$([[ "$ssh_gkhf" == "globalknownhostsfile /etc/ssh/ssh_known_hosts" ]] && echo pass || echo fail)" "$ssh_gkhf"

# SSH_N5. Pinned ED25519 key present in known_hosts
check "SSH pinned github.com ED25519 key present" "$(grep -q '^github.com ssh-ed25519 ' /etc/ssh/ssh_known_hosts 2>/dev/null && echo pass || echo fail)"

# SSH_N6: baseline posture holds when no user ~/.ssh/config is present.
# Verifies the system-provided /etc/ssh/ssh_config.d/00-rip-cage.conf applies
# by default. Does NOT test override-resistance — see ADR-014 D2 caveat.
ssh_n6_out=$(ssh -G github.com 2>/dev/null | grep -E '^(batchmode|stricthostkeychecking) ')
if echo "$ssh_n6_out" | grep -qE '^batchmode yes$' && echo "$ssh_n6_out" | grep -qE '^stricthostkeychecking (yes|true)$'; then
    check "SSH_N6 baseline posture (batchmode + stricthostkeychecking)" "pass"
else
    check "SSH_N6 baseline posture (batchmode + stricthostkeychecking)" "fail" "got: $ssh_n6_out"
fi

# SSH_N7. CLAUDE.md push-less text guards (two assertions — both must pass)
# SSH_N7a: CLAUDE.md contains no push-mandate language (ADR-014 D3).
if grep -qE 'git push.*(succeeds|required|mandatory|must)' /workspace/CLAUDE.md 2>/dev/null; then
    check "SSH_N7 CLAUDE.md no git-push mandate" "fail" "push mandate phrase detected"
else
    check "SSH_N7 CLAUDE.md no git-push mandate" "pass"
fi
check "CLAUDE.md has no bd dolt push mandate" "$(grep -qF 'bd dolt push' /workspace/CLAUDE.md 2>/dev/null && echo fail || echo pass)"

# SSH_N8. ConnectTimeout=10 resolved via ssh -G (rip-cage-it3)
ssh_ctimeout=$(ssh -G github.com 2>/dev/null | grep -E '^connecttimeout ' || true)
check "SSH ConnectTimeout=10 resolved" "$([[ "$ssh_ctimeout" == "connecttimeout 10" ]] && echo pass || echo fail)" "$ssh_ctimeout"

# SSH_N9. Pinned github.com ED25519 fingerprint matches SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
expected_fp="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
actual_fp=$(ssh-keygen -l -f /etc/ssh/ssh_known_hosts 2>/dev/null | awk '$NF=="(ED25519)" && /github\.com/ {print $2}' | head -1)
check "SSH pinned github.com ED25519 fingerprint matches" "$([[ "$actual_fp" == "$expected_fp" ]] && echo pass || echo fail)" "$actual_fp"

# SSH_N10. /etc/ssh/ssh_config.d/00-rip-cage.conf exists with mode 0644
ssh_conf="/etc/ssh/ssh_config.d/00-rip-cage.conf"
if [[ -f "$ssh_conf" ]]; then
    ssh_conf_mode=$(stat -c '%a' "$ssh_conf" 2>/dev/null || stat -f '%Lp' "$ssh_conf" 2>/dev/null || echo "?")
    check "SSH config file exists with mode 0644" "$([[ "$ssh_conf_mode" == "644" ]] && echo pass || echo fail)" "mode=$ssh_conf_mode"
else
    check "SSH config file exists with mode 0644" "fail" "missing: $ssh_conf"
fi

echo ""
echo "-- Mise (ADR-015) --"

# mise binary installed and executable
check "mise binary installed" "$([[ -x /usr/local/bin/mise ]] && echo pass || echo fail)"

# mise --version exits 0
if /usr/local/bin/mise --version >/dev/null 2>&1; then
  check "mise --version exits 0" "pass" "$(/usr/local/bin/mise --version 2>&1 | head -1)"
else
  check "mise --version exits 0" "fail"
fi

# mise activate hook present in .zshrc
if grep -q 'mise activate zsh' /home/agent/.zshrc 2>/dev/null; then
  check "mise activate zsh in .zshrc" "pass"
else
  check "mise activate zsh in .zshrc" "fail"
fi

# MISE_TRUSTED_CONFIG_PATHS env var set to /workspace
check "MISE_TRUSTED_CONFIG_PATHS=/workspace" "$([[ "${MISE_TRUSTED_CONFIG_PATHS:-}" == "/workspace" ]] && echo pass || echo fail)" "${MISE_TRUSTED_CONFIG_PATHS:-unset}"

# sudoers permits chown of mise cache dir
if sudo -n -l 2>/dev/null | grep -q 'chown.*agent.*mise'; then
  check "sudoers permits chown of mise cache dir" "pass"
else
  check "sudoers permits chown of mise cache dir" "fail"
fi

# mise cache dir exists (created by Dockerfile RUN mkdir or volume mount)
check "mise cache dir exists" "$([[ -d /home/agent/.local/share/mise ]] && echo pass || echo fail)"

# mise config.toml exists
check "mise config.toml exists" "$([[ -f /home/agent/.config/mise/config.toml ]] && echo pass || echo fail)"

# mise config.toml has idiomatic_version_file_enable_tools
if grep -q 'idiomatic_version_file_enable_tools' /home/agent/.config/mise/config.toml 2>/dev/null; then
  check "mise config.toml has idiomatic_version_file_enable_tools" "pass"
else
  check "mise config.toml has idiomatic_version_file_enable_tools" "fail"
fi

echo ""
echo "-- Cage Host-Network Awareness (ADR-016) --"

# SKIP_HOST_BRIDGE=1: air-gapped / offline cages. The resolution assertion
# becomes INFO-only (init still populates CAGE_HOST_ADDR with the literal
# fallback per ADR-016 D2, so the other assertions remain meaningful).
SKIP_HOST_BRIDGE="${SKIP_HOST_BRIDGE:-0}"

check_bridge() {
  local name="$1" result="$2" detail="${3:-}"
  if [[ "$SKIP_HOST_BRIDGE" == "1" && "$result" != "pass" ]]; then
    TOTAL=$((TOTAL + 1))
    echo "INFO  [$TOTAL] $name (host-bridge-skipped)${detail:+ — $detail}"
  else
    check "$name" "$result" "$detail"
  fi
}

# CAGE_HOST_ADDR populated by preflight probe and sourced into shell.
# Re-source cage-env in case this script was invoked without an interactive
# login shell that would have picked up the zshrc append. Fail the test if
# source itself errors — silent failure would mask a corrupt cage-env.
if [ -f /etc/rip-cage/cage-env ]; then
  if ! source /etc/rip-cage/cage-env; then
    check "cage-env is sourceable" "fail"
  fi
fi

if [ -n "${CAGE_HOST_ADDR:-}" ]; then
  check "CAGE_HOST_ADDR is set" "pass" "$CAGE_HOST_ADDR"
else
  check "CAGE_HOST_ADDR is set" "fail" "empty or unset"
fi

# CAGE_HOST_ADDR must actually resolve — guards against stale cage-env.
# On air-gapped cages, this legitimately fails; gated on SKIP_HOST_BRIDGE.
if [ -n "${CAGE_HOST_ADDR:-}" ] && getent hosts "$CAGE_HOST_ADDR" >/dev/null 2>&1; then
  check_bridge "CAGE_HOST_ADDR resolves" "pass"
else
  check_bridge "CAGE_HOST_ADDR resolves" "fail" "${CAGE_HOST_ADDR:-<unset>}"
fi

# settings.json .env.CAGE_HOST_ADDR MUST match the value written to cage-env
# on disk — coherency check, catches the silent-jq-skip regression. Reads
# cage-env's value directly (not the shell's $CAGE_HOST_ADDR) so a stale shell
# can't mask a disk/settings mismatch.
if [ -f ~/.claude/settings.json ] && [ -f /etc/rip-cage/cage-env ]; then
  _disk_val=$(sed -n 's/^export CAGE_HOST_ADDR="\(.*\)"$/\1/p' /etc/rip-cage/cage-env | head -1)
  _settings_val=$(jq -r '.env.CAGE_HOST_ADDR // empty' ~/.claude/settings.json 2>/dev/null)
  if [ -n "$_disk_val" ] && [ "$_disk_val" = "$_settings_val" ]; then
    check "settings.json env.CAGE_HOST_ADDR matches cage-env" "pass"
  else
    check "settings.json env.CAGE_HOST_ADDR matches cage-env" "fail" \
      "disk='$_disk_val' settings='$_settings_val'"
  fi
  unset _disk_val _settings_val
else
  check "settings.json env.CAGE_HOST_ADDR matches cage-env" "fail" "missing file"
fi

# Idempotency: exactly one `source /etc/rip-cage/cage-env` line in .zshrc.
if [ -f /home/agent/.zshrc ]; then
  _src_count=$(grep -c '/etc/rip-cage/cage-env' /home/agent/.zshrc || true)
  if [ "$_src_count" = "1" ]; then
    check ".zshrc sources cage-env exactly once" "pass"
  else
    check ".zshrc sources cage-env exactly once" "fail" "count=$_src_count"
  fi
  unset _src_count
fi

# Cage-topology section present exactly once — catches double-append regressions.
if [ -f ~/.claude/CLAUDE.md ]; then
  begin_count=$(grep -c 'begin:rip-cage-topology' ~/.claude/CLAUDE.md || true)
  end_count=$(grep -c 'end:rip-cage-topology' ~/.claude/CLAUDE.md || true)
  if [ "$begin_count" = "1" ] && [ "$end_count" = "1" ]; then
    check "Cage topology section present (exactly one marker pair)" "pass"
  else
    check "Cage topology section present (exactly one marker pair)" "fail" \
      "begin=$begin_count end=$end_count"
  fi
else
  check "Cage topology section present (exactly one marker pair)" "fail" "no CLAUDE.md"
fi

echo ""
echo "-- Version Manifest (rip-cage-7v4) --"
# Emits pinned-component versions so a future harness failure after an upgrade
# can be localized by diffing the manifest against a prior run. Always PASS —
# this is a snapshot, not a gate.
manifest_tool() {
    local label="$1" cmd="$2"
    local out
    out=$($cmd 2>&1 | head -1 || true)
    check "manifest: $label" "pass" "${out:-unavailable}"
}
manifest_tool "bd" "bd --version"
manifest_tool "dolt" "dolt version"
manifest_tool "claude" "claude --version"
manifest_tool "bun" "bun --version"
# dcg binary removed from base image (rip-cage-wlwc.10 / ADR-025 D2 — opt-in via examples/dcg recipe)
manifest_tool "node" "node --version"
manifest_tool "debian" "cat /etc/debian_version"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
[[ "$FAIL" -eq 0 ]] || exit 1
