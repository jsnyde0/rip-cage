#!/usr/bin/env bash
set -euo pipefail
PASS=0
FAIL=0
TOTAL=0

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

# 8. settings.json has DCG hook wired
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/bin/dcg")' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json wires DCG hook" "pass"
else
  check "settings.json wires DCG hook" "fail"
fi

# 9. settings.json has compound blocker hook wired
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/lib/rip-cage/hooks/block-compound-commands.sh")' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json wires compound blocker" "pass"
else
  check "settings.json wires compound blocker" "fail"
fi

# 10. settings.json denies .git/hooks writes
if jq -e '.permissions.deny[] | select(startswith("Write(.git/hooks"))' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json denies .git/hooks writes" "pass"
else
  check "settings.json denies .git/hooks writes" "fail"
fi

# 11. DCG denies destructive command
dcg_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /usr/local/bin/dcg 2>/dev/null || true)
if echo "$dcg_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG denies destructive command" "pass"
else
  check "DCG denies destructive command" "fail" "$dcg_result"
fi

# 12. Compound blocker denies chain
compound_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls && rm foo"}}' | /usr/local/lib/rip-cage/hooks/block-compound-commands.sh 2>/dev/null || true)
if echo "$compound_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "Compound blocker denies chain" "pass"
else
  check "Compound blocker denies chain" "fail" "$compound_result"
fi

echo ""
echo "-- Auth --"

# 13. Auth present (credentials file OR API key)
if [[ -s ~/.claude/.credentials.json ]] || [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  check "Auth present" "pass" "$([[ -s ~/.claude/.credentials.json ]] && echo "OAuth" || echo "API key")"
else
  check "Auth present" "fail" "no credentials file and no ANTHROPIC_API_KEY"
fi

# 14. Token not expired (skip if using API key only)
if [[ -s ~/.claude/.credentials.json ]] && command -v jq &>/dev/null; then
  expiry=$(jq -r '.expiry // .expiresAt // empty' ~/.claude/.credentials.json 2>/dev/null || true)
  if [[ -n "$expiry" ]]; then
    expiry_epoch=$(date -d "$expiry" "+%s" 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${expiry%%.*}" "+%s" 2>/dev/null || true)
    now_epoch=$(date "+%s")
    if [[ -n "$expiry_epoch" ]] && [[ "$expiry_epoch" -gt "$now_epoch" ]]; then
      remaining=$(( (expiry_epoch - now_epoch) / 60 ))
      check "Token not expired" "pass" "${remaining}m remaining"
    elif [[ -n "$expiry_epoch" ]]; then
      check "Token not expired" "fail" "expired"
    else
      check "Token not expired" "pass" "could not parse expiry (skipped)"
    fi
  else
    check "Token not expired" "pass" "no expiry field (skipped)"
  fi
else
  check "Token not expired" "pass" "no credentials file (skipped)"
fi

echo ""
echo "-- Git --"

# 15. git available and identity set
git_name=$(git config user.name 2>/dev/null || true)
git_email=$(git config user.email 2>/dev/null || true)
if [[ -n "$git_name" ]] && [[ -n "$git_email" ]]; then
  check "git identity set" "pass" "$git_name <$git_email>"
else
  check "git identity set" "fail" "name='$git_name' email='$git_email'"
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
    check "bd can access beads data" "pass" "${issue_count} issues"
  else
    bd_err=$(echo "$bd_output" | head -1)
    check "bd can access beads data" "fail" "$bd_err"
  fi
else
  check "bd can access beads data" "pass" "no .beads/ in workspace (skipped)"
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

# SSH_N3. UserKnownHostsFile points to pinned file
ssh_ukhf=$(ssh -G github.com 2>/dev/null | grep -E '^userknownhostsfile ' || true)
check "SSH UserKnownHostsFile=/etc/ssh/ssh_known_hosts" "$([[ "$ssh_ukhf" == "userknownhostsfile /etc/ssh/ssh_known_hosts" ]] && echo pass || echo fail)" "$ssh_ukhf"

# SSH_N4. GlobalKnownHostsFile points to pinned file
ssh_gkhf=$(ssh -G github.com 2>/dev/null | grep -E '^globalknownhostsfile ' || true)
check "SSH GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts" "$([[ "$ssh_gkhf" == "globalknownhostsfile /etc/ssh/ssh_known_hosts" ]] && echo pass || echo fail)" "$ssh_gkhf"

# SSH_N5. Pinned ED25519 key present in known_hosts
check "SSH pinned github.com ED25519 key present" "$(grep -q '^github.com ssh-ed25519 ' /etc/ssh/ssh_known_hosts 2>/dev/null && echo pass || echo fail)"

# SSH_N6. Override-resistance: ~/.ssh/config with hostile overrides must not defeat Match final
# Safety note: set -euo pipefail is active in this file. The || true on ssh -G prevents
# pipefail from triggering. rm -f never fails. The hostile config is always cleaned up
# because no command between write and rm can cause a non-true exit.
mkdir -p ~/.ssh
printf 'Host github.com\n  StrictHostKeyChecking accept-new\n  BatchMode no\n' > ~/.ssh/config
ssh_override=$(ssh -G github.com 2>/dev/null | grep -E '^batchmode ' || true)
check "SSH Match final overrides ~/.ssh/config hostile BatchMode=no" "$([[ "$ssh_override" == "batchmode yes" ]] && echo pass || echo fail)" "$ssh_override"
rm -f ~/.ssh/config

# SSH_N7. CLAUDE.md push-less text guards (two assertions — both must pass)
check "CLAUDE.md has no push mandate (git push succeeds)" "$(grep -qF 'git push' /workspace/CLAUDE.md 2>/dev/null && grep -qF 'succeeds' /workspace/CLAUDE.md && echo fail || echo pass)"
check "CLAUDE.md has no bd dolt push mandate" "$(grep -qF 'bd dolt push' /workspace/CLAUDE.md 2>/dev/null && echo fail || echo pass)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
[[ "$FAIL" -eq 0 ]] || exit 1
