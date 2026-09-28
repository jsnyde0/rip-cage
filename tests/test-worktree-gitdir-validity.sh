#!/usr/bin/env bash
set -uo pipefail

# tests/test-worktree-gitdir-validity.sh -- host-tier proof for rip-cage-qyer.
#
# A workspace `.git` FILE is workspace content (ADR-024 prompt-injection
# scope). Its `gitdir:` line decides which host dir rc mounts READ-WRITE at
# /workspace/.git-main. rc now mounts that dir only when it is a real git dir
# (HEAD, objects/, refs/), is not a protected path, does not contain the CCTOK
# secrets dir, and has a worktrees/<name>/gitdir entry pointing back at THIS
# workspace. Any miss: a Warning naming the path and the reason, no mount, and
# the run still proceeds (warn-and-skip, never refuse).
#
#   G   a genuine `git worktree add` workspace still mounts .git-main
#   N   gitdir -> a plain (non-git) host dir               -> skipped, reason
#   P   gitdir -> ~/.ssh/worktrees/x, dressed as a git dir -> skipped, reason
#   W   gitdir -> a real repo's worktree entry that belongs to a DIFFERENT
#       workspace                                           -> skipped, reason
#   I   the workspace dresses ITSELF up as the main .git (HEAD, objects/,
#       refs/, a backlink)                                  -> skipped, reason
#   U   a genuine worktree whose backlink file is unreadable -> skipped, not
#       an rc abort (set -e)
#   S   a genuine worktree whose main .git holds the CCTOK secrets dir
#                                                           -> skipped, reason
#
# Every `rc up` is --dry-run behind fake docker + msb PATH shims under a temp
# HOME and XDG_CONFIG_HOME; the call log is asserted free of mutating calls.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }

T=$(mktemp -d /private/tmp/rc-wt-validity-XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

CALL_LOG="${T}/calls.log"
BIN="${T}/bin"
mkdir -p "$BIN"
for _tool in docker msb; do
  cat > "${BIN}/${_tool}" <<FAKEEOF
#!/usr/bin/env bash
echo "${_tool} \$*" >> "${CALL_LOG}"
exit 0
FAKEEOF
  chmod +x "${BIN}/${_tool}"
done

H="${T}/home"
mkdir -p "$H/.config/rip-cage"
[[ -e "${HOME}/.docker" ]] && ln -sfn "${HOME}/.docker" "${H}/.docker"

_git() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# _dry_run WS -> OUT, RCODE, ARGV (the "Would run: msb create" line).
_dry_run() {
  local _ws="$1" _conf
  _conf="${T}/conf-$(basename "$1").yaml"
  cat > "$_conf" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${_ws}:/workspace"
  - "${H}/.claude/projects:/home/agent/.claude/projects"
  - "${H}/.claude/sessions:/home/agent/.claude/sessions"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CONF
  : > "$CALL_LOG"
  OUT=$(HOME="$H" XDG_CONFIG_HOME="${H}/.config" RC_CAGE_CONF="$_conf" PATH="${BIN}:${PATH}" \
        bash "$RC" up --dry-run "$_ws" 2>&1 </dev/null)
  RCODE=$?
  ARGV=$(grep '^Would run: msb create' <<<"$OUT")
}

_no_mutation() {
  if grep -Eq '^(docker (save|tag|pull|build|load)|msb (load|create|pull|start))' "$CALL_LOG"; then
    fail "$1: dry-run made a mutating runtime call"
  fi
}

# _expect_skip LABEL REASON-FRAGMENT
_expect_skip() {
  local _l="$1" _why="$2"
  if [[ $RCODE -eq 0 ]]; then pass "${_l} rc up --dry-run exits 0 (warn-and-skip, not refuse)"; else fail "${_l} exit ${RCODE}: $(tail -3 <<<"$OUT")"; fi
  if [[ -n "$ARGV" ]] && ! grep -q '/workspace/.git-main' <<<"$ARGV"; then
    pass "${_l} argv carries no /workspace/.git-main mount"
  else
    fail "${_l} argv missing or still mounts .git-main: ${ARGV:-<no argv line>}"
  fi
  if grep -q "Warning: skipping worktree mount .*${_why}" <<<"$OUT"; then
    pass "${_l} stderr names why: ${_why}"
  else
    fail "${_l} no warning naming '${_why}': $(grep -i 'warning' <<<"$OUT" | head -3)"
  fi
  _no_mutation "$_l"
}

# --- G: a genuine worktree ----------------------------------------------------
echo "=== G: genuine git worktree ==="
MAIN="${T}/main-repo"
mkdir -p "$MAIN"
_git -C "$MAIN" init
echo x > "$MAIN/f"
_git -C "$MAIN" add f
_git -C "$MAIN" commit -m init
WS_G="${T}/wt-good"
_git -C "$MAIN" worktree add "$WS_G" -b wt-good
if [[ -f "$WS_G/.git" ]]; then
  _dry_run "$WS_G"
  if [[ $RCODE -eq 0 ]]; then pass "G rc up --dry-run exits 0"; else fail "G exit ${RCODE}: $(tail -3 <<<"$OUT")"; fi
  # Read-write = no :ro suffix (the msb translation drops docker's :delegated).
  if grep -Eq -- "-v ${MAIN}/\.git:/workspace/\.git-main( |$)" <<<"$ARGV"; then
    pass "G argv mounts the real main .git read-write at /workspace/.git-main"
  else
    fail "G genuine worktree lost its .git-main mount: ${ARGV:-<no argv line>}"
  fi
  if grep -q "skipping worktree mount" <<<"$OUT"; then fail "G a genuine worktree was warned about"; else pass "G no skip warning"; fi
  _no_mutation "G"
else
  fail "G fixture: git worktree add did not produce a .git file"
fi

# --- N: gitdir -> a plain host dir --------------------------------------------
echo ""
echo "=== N: gitdir points at a non-git host dir ==="
PLAIN="${T}/plain-dir"
mkdir -p "$PLAIN/worktrees/x"
WS_N="${T}/ws-nongit"
mkdir -p "$WS_N"
echo "gitdir: ${PLAIN}/worktrees/x" > "$WS_N/.git"
_dry_run "$WS_N"
_expect_skip "N" "not a git dir"

# --- P: gitdir -> ~/.ssh, dressed up as a git dir -----------------------------
echo ""
echo "=== P: gitdir points at a protected path ==="
SSH="${H}/.ssh"
mkdir -p "$SSH/objects" "$SSH/refs" "$SSH/worktrees/x"
echo "ref: refs/heads/main" > "$SSH/HEAD"
WS_P="${T}/ws-protected"
mkdir -p "$WS_P"
echo "${WS_P}/.git" > "$SSH/worktrees/x/gitdir"
echo "gitdir: ${SSH}/worktrees/x" > "$WS_P/.git"
_dry_run "$WS_P"
_expect_skip "P" "protected path '.ssh'"

# --- W: a real repo's worktree entry that belongs to another workspace --------
echo ""
echo "=== W: gitdir borrows another workspace's worktree entry ==="
WS_W="${T}/ws-borrower"
mkdir -p "$WS_W"
cp "$WS_G/.git" "$WS_W/.git"
_dry_run "$WS_W"
_expect_skip "W" "not this workspace's .git"

# --- I: the workspace plants a git dir in itself -----------------------------
echo ""
echo "=== I: workspace dressed up as its own main .git ==="
WS_I="${T}/ws-self"
mkdir -p "$WS_I/objects" "$WS_I/refs" "$WS_I/worktrees/x"
echo "ref: refs/heads/main" > "$WS_I/HEAD"
echo "${WS_I}/.git" > "$WS_I/worktrees/x/gitdir"
echo "gitdir: ${WS_I}/worktrees/x" > "$WS_I/.git"
_dry_run "$WS_I"
_expect_skip "I" "inside the workspace itself"

# --- U: unreadable backlink -> warn-and-skip, never an abort ------------------
echo ""
echo "=== U: genuine worktree, unreadable backlink file ==="
WS_U="${T}/wt-unreadable"
_git -C "$MAIN" worktree add "$WS_U" -b wt-unreadable
chmod 000 "$MAIN/.git/worktrees/wt-unreadable/gitdir"
_dry_run "$WS_U"
chmod 644 "$MAIN/.git/worktrees/wt-unreadable/gitdir"
_expect_skip "U" "gitdir is empty or unreadable"

# --- S: main .git holds the CCTOK secrets dir ---------------------------------
echo ""
echo "=== S: main .git contains the CCTOK secrets dir ==="
MAIN_S="${T}/main-secrets"
mkdir -p "$MAIN_S"
_git -C "$MAIN_S" init
echo x > "$MAIN_S/f"
_git -C "$MAIN_S" add f
_git -C "$MAIN_S" commit -m init
WS_S="${T}/wt-secrets"
_git -C "$MAIN_S" worktree add "$WS_S" -b wt-secrets
mkdir -p "$MAIN_S/.git/xdg/rip-cage/secrets"
H_XDG="$MAIN_S/.git/xdg"
_dry_run_xdg() {
  local _ws="$1" _conf
  _conf="${T}/conf-$(basename "$1").yaml"
  cat > "$_conf" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${_ws}:/workspace"
  - "${H}/.claude/projects:/home/agent/.claude/projects"
  - "${H}/.claude/sessions:/home/agent/.claude/sessions"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CONF
  : > "$CALL_LOG"
  OUT=$(HOME="$H" XDG_CONFIG_HOME="$H_XDG" RC_CAGE_CONF="$_conf" PATH="${BIN}:${PATH}" \
        bash "$RC" up --dry-run "$_ws" 2>&1 </dev/null)
  RCODE=$?
  ARGV=$(grep '^Would run: msb create' <<<"$OUT")
}
_dry_run_xdg "$WS_S"
_expect_skip "S" "CCTOK secrets dir"

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
[[ $FAILURES -eq 0 ]]
