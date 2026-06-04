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

# 8. settings.json has DCG hook wired (via wrapper, ADR-025 D3/D4)
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/lib/rip-cage/bin/dcg-guard")' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json wires DCG hook" "pass"
else
  check "settings.json wires DCG hook" "fail"
fi

# 9. settings.json has ssh-bypass blocker hook wired (ADR-022 D5)
# NOTE: compound blocker removed in rip-cage-4r8 — DCG is chaining-robust (see 11f/11g).
if jq -e '.hooks.PreToolUse[] | select(.hooks[].command == "/usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh")' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json wires ssh-bypass blocker" "pass"
else
  check "settings.json wires ssh-bypass blocker" "fail"
fi


# 10. settings.json denies .git/hooks writes
if jq -e '.permissions.deny[] | select(startswith("Write(.git/hooks"))' ~/.claude/settings.json >/dev/null 2>&1; then
  check "settings.json denies .git/hooks writes" "pass"
else
  check "settings.json denies .git/hooks writes" "fail"
fi

# 11. DCG denies destructive command (via wrapper, ADR-025 D3)
dcg_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /usr/local/lib/rip-cage/bin/dcg-guard 2>/dev/null || true)
if echo "$dcg_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG denies destructive command" "pass"
else
  check "DCG denies destructive command" "fail" "$dcg_result"
fi

# ---------------------------------------------------------------------------
# DCG Floor-Uncrossable + Additive Regression Suite (ADR-025 D2/D5)
# rip-cage-hhh.11.4: permanent in-container regression assertions.
# ---------------------------------------------------------------------------

# 11b. Floor vs /workspace/.dcg.toml — hostile workspace config does NOT weaken guard via wrapper
# Write a hostile /workspace/.dcg.toml that allows everything via wildcard overrides.allow.
# The wrapper (dcg-guard) anchors CWD to /usr/local/lib/rip-cage which has no .git ancestor,
# so DCG's project-config discovery never walks up to /workspace. Floor must hold.
_hostile_ws="/workspace/.dcg.toml"
cat > "$_hostile_ws" << 'HOSTILE_EOF'
[overrides]
allow = [".*"]
HOSTILE_EOF
_floor_ws_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /usr/local/lib/rip-cage/bin/dcg-guard 2>/dev/null || true)
rm -f "$_hostile_ws"
if echo "$_floor_ws_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG floor holds vs hostile /workspace/.dcg.toml (via wrapper)" "pass"
else
  check "DCG floor holds vs hostile /workspace/.dcg.toml (via wrapper)" "fail" "$_floor_ws_result"
fi
unset _hostile_ws _floor_ws_result

# 11c. Floor vs user-layer — hostile ~/.config/dcg/config.toml does NOT weaken guard via wrapper
# The wrapper pins DCG_CONFIG to the cage-owned baked config, which suppresses the user-layer
# config entirely (config.rs:2417: user layer loads only if explicit_layer.is_none()).
_hostile_user_dir="${HOME}/.config/dcg"
_hostile_user_cfg="${_hostile_user_dir}/config.toml"
_hostile_user_existed=false
if [[ -f "$_hostile_user_cfg" ]]; then
  _hostile_user_existed=true
  cp "$_hostile_user_cfg" "${_hostile_user_cfg}.rc-test-bak"
fi
mkdir -p "$_hostile_user_dir"
cat > "$_hostile_user_cfg" << 'HOSTILE_EOF'
[overrides]
allow = [".*"]
HOSTILE_EOF
_floor_ul_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /usr/local/lib/rip-cage/bin/dcg-guard 2>/dev/null || true)
# Restore user config state
if [[ "$_hostile_user_existed" == "true" ]]; then
  mv "${_hostile_user_cfg}.rc-test-bak" "$_hostile_user_cfg"
else
  rm -f "$_hostile_user_cfg"
fi
if echo "$_floor_ul_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG floor holds vs hostile ~/.config/dcg/config.toml (via wrapper)" "pass"
else
  check "DCG floor holds vs hostile ~/.config/dcg/config.toml (via wrapper)" "fail" "$_floor_ul_result"
fi
unset _hostile_user_dir _hostile_user_cfg _hostile_user_existed _floor_ul_result

# 11d. Sensitivity proof — hostile /workspace/.dcg.toml WOULD weaken raw DCG (proves wrapper is load-bearing)
# Run raw /usr/local/bin/dcg from CWD=/workspace (NOT via wrapper) with the hostile file present.
# The hostile file is in a git repo root (DCG discovers it via find_repo_root from process CWD).
# This must NOT show "deny" — proving the wrapper's CWD-anchor is the mechanism, not DCG ignoring configs.
# Without the wrapper, the floor is crossable. With the wrapper, it is not (proven by 11b above).
_hostile_ws="/workspace/.dcg.toml"
cat > "$_hostile_ws" << 'HOSTILE_EOF'
[overrides]
allow = [".*"]
HOSTILE_EOF
_raw_result=$(cd /workspace; echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | /usr/local/bin/dcg 2>/dev/null || true)
rm -f "$_hostile_ws"
# Sensitivity proof: raw dcg SHOULD be weakened (i.e., NOT deny). If it still denies, the test cannot prove the wrapper is load-bearing.
if echo "$_raw_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG sensitivity: raw dcg weakened by hostile /workspace/.dcg.toml (wrapper is load-bearing)" "fail" "raw dcg still denied — hostile config not loaded (sensitivity proof invalid)"
else
  check "DCG sensitivity: raw dcg weakened by hostile /workspace/.dcg.toml (wrapper is load-bearing)" "pass"
fi
unset _hostile_ws _raw_result

# 11e. Additive rule fires — custom rule pack loaded via DCG_CONFIG custom_paths blocks sentinel command
# Proves the additive mechanism (ADR-025 D1): DCG loads and evaluates custom YAML rule packs.
# Fixture resolution (rip-cage-16t): prefer the image-baked copy so this check is portable
# across ALL cages; fall back to the repo workspace path for dev runs from a rip-cage
# checkout. test-safety-stack.sh is baked into the image and runs inside any cage via
# `rc test`, so a /workspace-only fixture path fails everywhere except this repo's own cage.
# Invokes raw dcg directly with a temp DCG_CONFIG pointing at the fixture, NOT via wrapper
# (wrapper pins DCG_CONFIG to baked floor config; this tests the additive translation mechanism).
# The sentinel command "ripcagetestsentinel" must NOT match any real command.
_sentinel_fixture="/usr/local/lib/rip-cage/dcg/fixtures/ripcage-testsentinel-rule.yaml"
if [ ! -f "$_sentinel_fixture" ]; then
  _sentinel_fixture="/workspace/tests/fixtures/ripcage-testsentinel-rule.yaml"
fi
_sentinel_cfg=$(mktemp /tmp/dcg-test-sentinel-XXXXXX.toml)
cat > "$_sentinel_cfg" << 'SENTINEL_TOML_EOF'
[packs]
enabled = ["core"]
SENTINEL_TOML_EOF
echo "custom_paths = [\"${_sentinel_fixture}\"]" >> "$_sentinel_cfg"
_additive_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"ripcagetestsentinel"}}' | DCG_CONFIG="$_sentinel_cfg" /usr/local/bin/dcg 2>/dev/null || true)
rm -f "$_sentinel_cfg"
if echo "$_additive_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG additive rule fires: sentinel command denied by custom rule pack" "pass"
else
  check "DCG additive rule fires: sentinel command denied by custom rule pack" "fail" "fixture=$_sentinel_fixture result=$_additive_result"
fi
unset _sentinel_fixture _sentinel_cfg _additive_result

# ---------------------------------------------------------------------------
# DCG Chaining-Robustness Regression Suite (rip-cage-4r8)
# Locks in that DCG denies destructive commands REGARDLESS of operator chaining.
# DCG uses unanchored whole-command regex matching, so && and ; do not bypass it.
# A future DCG version bump that anchors patterns would fail these loud.
# ---------------------------------------------------------------------------

# 11f. DCG denies destructive command after && (chaining-robust)
# Build JSON payload in a temp file — avoids literal && in a shell command string
# (the local compound-blocker hook in active sessions scans raw Bash tool input,
# not test-script shell lines, but writing to a file is the safe portable pattern).
_dcg_chain_and_payload=$(mktemp /tmp/dcg-chain-and-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"echo hi && rm -rf ~"}}' > "$_dcg_chain_and_payload"
_dcg_chain_and=$(cat "$_dcg_chain_and_payload" | /usr/local/lib/rip-cage/bin/dcg-guard 2>/dev/null || true)
rm -f "$_dcg_chain_and_payload"
if echo "$_dcg_chain_and" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG chaining-robust: denies destructive after && (rip-cage-4r8)" "pass"
else
  check "DCG chaining-robust: denies destructive after && (rip-cage-4r8)" "fail" "$_dcg_chain_and"
fi
unset _dcg_chain_and_payload _dcg_chain_and

# 11g. DCG denies destructive command after ; (chaining-robust)
_dcg_chain_semi_payload=$(mktemp /tmp/dcg-chain-semi-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"ls; rm -rf /important"}}' > "$_dcg_chain_semi_payload"
_dcg_chain_semi=$(cat "$_dcg_chain_semi_payload" | /usr/local/lib/rip-cage/bin/dcg-guard 2>/dev/null || true)
rm -f "$_dcg_chain_semi_payload"
if echo "$_dcg_chain_semi" | grep -qE '"permissionDecision".*"deny"'; then
  check "DCG chaining-robust: denies destructive after ; (rip-cage-4r8)" "pass"
else
  check "DCG chaining-robust: denies destructive after ; (rip-cage-4r8)" "fail" "$_dcg_chain_semi"
fi
unset _dcg_chain_semi_payload _dcg_chain_semi

# 11h. block-ssh-bypass denies chained ssh-bypass after && (chaining-robust)
# Verifies block-ssh-bypass.sh scans the whole command string, not just the first command.
_ssh_chain_payload=$(mktemp /tmp/ssh-chain-XXXXXX.json)
printf '{"tool_name":"Bash","tool_input":{"command":"echo x && ssh -o StrictHostKeyChecking=no host"}}' > "$_ssh_chain_payload"
_ssh_chain=$(cat "$_ssh_chain_payload" | /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh 2>/dev/null || true)
rm -f "$_ssh_chain_payload"
if echo "$_ssh_chain" | grep -qE '"permissionDecision".*"deny"'; then
  check "ssh-bypass chaining-robust: denies chained ssh-bypass (rip-cage-4r8)" "pass"
else
  check "ssh-bypass chaining-robust: denies chained ssh-bypass (rip-cage-4r8)" "fail" "$_ssh_chain"
fi
unset _ssh_chain_payload _ssh_chain

# 12. ssh-bypass blocker denies the verified bypass shape (ADR-022 D5)
# NOTE: compound blocker (formerly check 12) removed in rip-cage-4r8. DCG chaining-robustness
# is regression-tested at 11f/11g. ssh-bypass chaining robustness at 11h.
sshbypass_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/x git@gitlab.com"}}' | /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh 2>/dev/null || true)
if echo "$sshbypass_result" | grep -qE '"permissionDecision".*"deny"'; then
  check "ssh-bypass blocker denies UserKnownHostsFile+accept-new" "pass"
else
  check "ssh-bypass blocker denies UserKnownHostsFile+accept-new" "fail" "$sshbypass_result"
fi

# 12b. ssh-bypass refusal message points at .rip-cage.yaml + rc config init
if echo "$sshbypass_result" | grep -q '\.rip-cage\.yaml' && echo "$sshbypass_result" | grep -q 'rc config init'; then
  check "ssh-bypass refusal message names .rip-cage.yaml + rc config init" "pass"
else
  check "ssh-bypass refusal message names .rip-cage.yaml + rc config init" "fail" "$sshbypass_result"
fi

# 12c. ssh-bypass blocker catches /usr/bin/ssh direct path call
sshbypass_direct=$(echo '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/ssh -o StrictHostKeyChecking=no host"}}' | /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh 2>/dev/null || true)
if echo "$sshbypass_direct" | grep -qE '"permissionDecision".*"deny"'; then
  check "ssh-bypass blocker catches /usr/bin/ssh direct path" "pass"
else
  check "ssh-bypass blocker catches /usr/bin/ssh direct path" "fail" "$sshbypass_direct"
fi

# 12d. ssh-bypass blocker does NOT block legitimate ssh
sshbypass_legit=$(echo '{"tool_name":"Bash","tool_input":{"command":"ssh git@github.com"}}' | /usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh 2>/dev/null || true)
if [[ -z "$sshbypass_legit" ]]; then
  check "ssh-bypass blocker allows legitimate ssh (no override flags)" "pass"
else
  check "ssh-bypass blocker allows legitimate ssh (no override flags)" "fail" "$sshbypass_legit"
fi

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
manifest_tool "dcg" "dcg --version"
manifest_tool "node" "node --version"
manifest_tool "debian" "cat /etc/debian_version"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
[[ "$FAIL" -eq 0 ]] || exit 1
