#!/usr/bin/env bash
# Verification tests for git worktree support in rc (bead rip-cage-tvx)

RC_FILE="/Users/jonat/code/personal/rip-cage/rc"

pass_count=0
fail_count=0

check() {
  local desc="$1"
  local result="$2"
  local num=$(( pass_count + fail_count + 1 ))
  if [[ "$result" == "true" ]]; then
    echo "PASS [$num] $desc"
    pass_count=$(( pass_count + 1 ))
  else
    echo "FAIL [$num] $desc"
    fail_count=$(( fail_count + 1 ))
  fi
}

grep_check() {
  grep -q "$1" "$RC_FILE" 2>/dev/null && echo true || echo false
}

# Test 1: Worktree detection block exists
check "Worktree detection block present (wt_detected variable)" \
  "$(grep_check 'wt_detected=false')"

# Test 2: Reads .git file and extracts gitdir: line
check "Reads .git file for gitdir line" \
  "$(grep_check 'gitdir_line.*cat.*\.git')"

# Test 3: Control character rejection for gitdir content
check "Rejects control characters in .git file content" \
  "$(grep_check 'host_gitdir.*cntrl')"

# Test 4: Distinguishes worktrees from submodules (checks for /worktrees/ path)
check "Distinguishes worktrees from submodules via /worktrees/ path" \
  "$(grep_check '"/worktrees/"')"

# Test 5: RC_ALLOWED_ROOTS validation for main git dir
check "Validates main .git/ against RC_ALLOWED_ROOTS" \
  "$(grep_check 'git_allowed')"

# Test 6: Sets wt_name from basename of gitdir
check "Sets wt_name from basename of host_gitdir" \
  "$(grep_check 'wt_name.*basename.*host_gitdir')"

# Test 7: Dry-run JSON includes worktree metadata
check "Dry-run JSON includes worktree metadata when wt_detected" \
  "$(grep_check 'wt_name.*wt_main_git')"

# Test 8: Dry-run text output mentions worktree mount
check "Dry-run text output mentions worktree when wt_detected" \
  "$(grep_check 'Would mount worktree')"

# Test 9: Creates temp gitfile at ~/.cache/rc/<name>.gitfile
check "Creates temp gitfile at ~/.cache/rc/<name>.gitfile" \
  "$(grep_check '\.cache/rc.*\.gitfile')"

# Test 10: Uses umask 077 for gitfile creation
check "Uses umask 077 for gitfile creation" \
  "$(grep_check 'umask 077')"

# Test 11: Mounts main .git/ at /workspace/.git-main
check "Mounts main .git/ at /workspace/.git-main" \
  "$(grep_check '\.git-main:delegated')"

# Test 12: Mounts corrected .git file at /workspace/.git:ro
check "Mounts corrected .git file at /workspace/.git:ro" \
  "$(grep_check '\.git:ro')"

# Test 13: Mounts hooks read-only as sub-mount
check "Mounts hooks at /workspace/.git-main/hooks:ro" \
  "$(grep_check '\.git-main/hooks.*:ro')"

# Test 14: Worktree mount args are AFTER workspace mount (line ordering)
ws_line=$(grep -n 'workspace:delegated' "$RC_FILE" | head -1 | cut -d: -f1)
wt_line=$(grep -n 'git-main:delegated' "$RC_FILE" | head -1 | cut -d: -f1)
if [[ -n "$ws_line" && -n "$wt_line" && "$wt_line" -gt "$ws_line" ]]; then
  check "Worktree mounts added after workspace mount" "true"
else
  check "Worktree mounts added after workspace mount" "false"
fi

# Test 15: Worktree mounts are BEFORE credential extraction (in cmd_up, not devcontainer template)
# Use the security find-generic-password line inside cmd_up (not the devcontainer heredoc at line ~115)
wt_line=$(grep -n 'git-main:delegated' "$RC_FILE" | head -1 | cut -d: -f1)
cred_line=$(grep -n 'security find-generic-password' "$RC_FILE" | tail -1 | cut -d: -f1)
if [[ -n "$wt_line" && -n "$cred_line" && "$wt_line" -lt "$cred_line" ]]; then
  check "Worktree mounts added before credential extraction" "true"
else
  check "Worktree mounts added before credential extraction" "false"
fi

# Test 16: Creation JSON includes worktree metadata (2 occurrences: dry-run + creation)
count=$(grep -c 'worktree.*wt_name\|wt_name.*wt_main_git' "$RC_FILE" 2>/dev/null || echo 0)
if [[ "$count" -ge 2 ]]; then
  check "Creation JSON includes worktree metadata (2 jq calls with wt_name/wt_main_git)" "true"
else
  check "Creation JSON includes worktree metadata (2 jq calls with wt_name/wt_main_git)" "false"
fi

# Test 17: cmd_destroy cleans up gitfile
check "cmd_destroy removes ~/.cache/rc/<name>.gitfile" \
  "$(grep_check 'rm -f.*\.cache/rc.*\.gitfile')"

# Test 18: Detection block is BEFORE dry-run check (line ordering)
wt_detect_line=$(grep -n 'wt_detected=false' "$RC_FILE" | head -1 | cut -d: -f1)
dry_run_line=$(grep -n 'DRY_RUN.*==.*true' "$RC_FILE" | head -1 | cut -d: -f1)
if [[ -n "$wt_detect_line" && -n "$dry_run_line" && "$wt_detect_line" -lt "$dry_run_line" ]]; then
  check "Worktree detection block is before dry-run check" "true"
else
  check "Worktree detection block is before dry-run check" "false"
fi

# Test 19: Relative gitdir resolved with realpath
check "Relative gitdir paths resolved with realpath" \
  "$(grep_check 'realpath.*path.*host_gitdir\|realpath.*host_gitdir')"

# Test 20: Syntax check passes
bash -n "$RC_FILE" 2>/dev/null && check "rc script passes bash syntax check" "true" || check "rc script passes bash syntax check" "false"

echo ""
echo "Results: ${pass_count} passed, ${fail_count} failed"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
