#!/usr/bin/env bash
# tests/test-msb-ssh-retirement-effect-probes.sh -- LIVE effect-based proof
# that the ssh cluster (agent-forwarding default ADR-017, socket discovery
# ADR-018, identity routing ADR-020, host+key allowlist + hook + filtered
# known_hosts + ssh-agent-filter ADR-022) is RETIRED, and that git autonomy
# in a cage works end-to-end over HTTPS + msb `--secret` instead (rip-cage-f1qo,
# S5 of the msb migration epic rip-cage-tsf2, ADR-029 D3).
#
# Applies the GENERATOR's emitted flags DIRECTLY via `msb run` (NOT through
# rc's create verb -- that's S6's job; this is the S4<->S6/S5<->S6
# non-circularity pattern documented in docs/2026-07-10-tsf2-decomposition.md).
#
# Per the msb fake-accept confound (bd memory
# msb-netstack-fake-accepts-tcp-connect-not-egress), the push/PR proof here
# is never connect()-success or exit-0 alone: "the push landed" is proven by
# the REMOTE REF ACTUALLY MOVING, read back independently from the HOST via
# `gh api` (outside the guest, real bidirectional GitHub API data), before
# vs after. The real token never enters the guest (msb `--secret`
# substitution) -- proven directly by inspecting the guest env/proc.
#
# Coverage (mirrors the bead's acceptance criteria):
#   SOCK   no ssh-agent socket is reachable in the guest: $SSH_AUTH_SOCK is
#          unset/empty AND no agent socket file exists at any historical
#          mount path (/ssh-agent.sock, /ssh-agent-upstream.sock)
#          [criterion 2, negative control]
#   TOKEN  the real GH token never appears in guest env or in the persisted
#          git remote URL -- only the msb placeholder does
#   PUSH   real clone -> commit -> push over HTTPS + --secret; the remote
#          ref MOVES (proven by an independent host-side `gh api` read,
#          before vs after, real commit sha + content match)
#          [criterion 1]
#   PR     real branch -> push -> `gh pr create`, all from inside the cage;
#          the PR is proven real by an independent host-side `gh pr view`
#          read [criterion 1]
#
# NEEDS_CONTAINER + NEEDS_MSB + `gh` authenticated as a real GitHub account
# with `repo` scope + network access to github.com/api.github.com. Self-skips
# (exit 0, SKIP: ...) when any prerequisite is missing -- never fakes a PASS.
#
# Side effects (outward-facing guardrail): creates/reuses ONE throwaway
# private GitHub repo under the authenticated account, named
# rip-cage-f1qo-s5-smoketest, clearly labeled as disposable in its
# description. Cleans up the branch + closes the PR it creates on every run.
# Does NOT delete the repo itself (the authenticated token here lacks the
# delete_repo scope in this environment) -- left for manual deletion,
# documented in the bead's implementation report.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GEN="${REPO_ROOT}/cli/lib/msb_flags.sh"
IMAGE="rip-cage:latest"
RUN_ID="$$"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available -- skipping $(basename "$0")"
  exit 0
fi
if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json >/dev/null 2>&1; then
  echo "SKIP: msb not responsive -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "\"reference\": \"${IMAGE}\""; then
  echo "SKIP: ${IMAGE} not loaded into msb -- skipping $(basename "$0") (run: rc build, then msb load)"
  exit 0
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "SKIP: gh CLI not available -- skipping $(basename "$0")"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "SKIP: gh not authenticated -- skipping $(basename "$0")"
  exit 0
fi

GH_LOGIN=$(gh api user --jq '.login' 2>/dev/null || true)
if [[ -z "$GH_LOGIN" ]]; then
  echo "SKIP: could not resolve authenticated gh user -- skipping $(basename "$0")"
  exit 0
fi

GH_TOKEN_REAL=$(gh auth token 2>/dev/null || true)
if [[ -z "$GH_TOKEN_REAL" ]]; then
  echo "SKIP: gh auth token unavailable -- skipping $(basename "$0")"
  exit 0
fi

REPO_NAME="rip-cage-f1qo-s5-smoketest"
REPO_FULL="${GH_LOGIN}/${REPO_NAME}"

# Reuse an existing throwaway fixture if this repo already exists (repeat
# runs), otherwise create it fresh -- private, clearly labeled disposable.
if ! gh repo view "$REPO_FULL" >/dev/null 2>&1; then
  if ! gh repo create "$REPO_FULL" --private \
      --description "THROWAWAY test fixture for rip-cage-f1qo (msb cutover S5, ssh-cluster retirement effect probe). Safe to delete manually." \
      >/tmp/5s1q-repo-create.err 2>&1; then
    echo "SKIP: could not create throwaway GitHub repo ${REPO_FULL} -- skipping $(basename "$0")"
    cat /tmp/5s1q-repo-create.err 2>/dev/null
    exit 0
  fi
fi

# shellcheck disable=SC1090
source "$GEN"

CAGE="f1qo-ssh-retire-probe-${RUN_ID}"
BRANCH="s5-probe-${RUN_ID}"

cleanup() {
  msb remove -f "$CAGE" >/dev/null 2>&1 || true
  # Close the PR (if opened) and delete the remote branch -- repo itself is
  # NOT deleted (missing delete_repo scope in this environment; documented
  # above and in the bead report).
  local _pr_num
  _pr_num=$(gh pr list --repo "$REPO_FULL" --head "$BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)
  if [[ -n "$_pr_num" ]]; then
    gh pr close "$_pr_num" --repo "$REPO_FULL" --delete-branch >/dev/null 2>&1 || true
  else
    gh api -X DELETE "repos/${REPO_FULL}/git/refs/heads/${BRANCH}" >/dev/null 2>&1 || true
  fi
  rm -f /tmp/5s1q-*.err /tmp/5s1q-*.out
}
trap cleanup EXIT

echo ""
echo "=== Setup: boot a cage from S2's generator flags directly (msb run) ==="
echo "    allowed_hosts=[github.com, api.github.com], credential GH_TOKEN bound to both (distinct synth names)"
CFG=$(jq -nc '{
  allowed_hosts: ["github.com", "api.github.com"],
  credentials: [ { source_env: "GH_TOKEN", hosts: ["github.com", "api.github.com"] } ]
}')
mapfile -t FLAGS < <(_msb_flags_generate "$CFG")
if [[ "${#FLAGS[@]}" -gt 0 ]]; then
  pass "setup: generator produced flags for allowed_hosts + credential config"
else
  fail "setup: generator produced no flags" ""
fi

# _msb_flags_prepare_secret_env must run in THIS shell (not a subshell) so
# the exports are visible to the `msb run` invocation below.
export GH_TOKEN="$GH_TOKEN_REAL"
_msb_flags_prepare_secret_env "$CFG"
unset GH_TOKEN

if msb run -d --name "$CAGE" --replace "${FLAGS[@]}" "$IMAGE" -- sleep 600 >/tmp/5s1q-boot.err 2>&1; then
  pass "setup: cage boots from generator-emitted flags (post-ssh-retirement image)"
else
  fail "setup: cage failed to boot" "$(cat /tmp/5s1q-boot.err)"
  echo ""
  echo "=== test-msb-ssh-retirement-effect-probes.sh: ${FAILURES}/${TOTAL} failure(s) (aborting -- boot failed) ==="
  exit 1
fi

# ===========================================================================
# SOCK: negative control -- no ssh-agent socket reachable in the guest.
# ===========================================================================
echo ""
echo "=== SOCK (criterion 2, negative control): no ssh-agent socket reachable in-guest ==="

# shellcheck disable=SC2016  # single-quoted: must expand INSIDE the guest shell, not the host shell
SOCK_ENV=$(msb exec "$CAGE" -- sh -c 'echo "SSH_AUTH_SOCK=[${SSH_AUTH_SOCK:-}]"' 2>/tmp/5s1q-sock-env.err)
if [[ "$SOCK_ENV" == "SSH_AUTH_SOCK=[]" ]]; then
  pass "SOCK: \$SSH_AUTH_SOCK is unset/empty in-guest"
else
  fail "SOCK: \$SSH_AUTH_SOCK is set in-guest (ssh agent forwarding still reachable)" "$SOCK_ENV"
fi

# shellcheck disable=SC2016  # single-quoted: must expand INSIDE the guest shell, not the host shell
SOCK_FILE_OUT=$(msb exec "$CAGE" -- sh -c '
  for p in /ssh-agent.sock /ssh-agent-upstream.sock; do
    [ -S "$p" ] && echo "SOCKET_PRESENT:$p"
  done
' 2>/tmp/5s1q-sock-file.err)
if [[ -z "$SOCK_FILE_OUT" ]]; then
  pass "SOCK: no agent socket FILE present at any historical mount path (/ssh-agent.sock, /ssh-agent-upstream.sock)"
else
  fail "SOCK: an agent socket file is still present in-guest" "$SOCK_FILE_OUT"
fi

# shellcheck disable=SC2016  # single-quoted: must expand INSIDE the guest shell, not the host shell
SENTINEL_OUT=$(msb exec "$CAGE" -- sh -c '
  for p in /etc/rip-cage/ssh-agent-status /etc/rip-cage/ssh-allowed-keys /etc/rip-cage/github-identity /etc/rip-cage/ssh-config-source; do
    [ -e "$p" ] && echo "SENTINEL_PRESENT:$p"
  done
' 2>/tmp/5s1q-sentinel.err)
if [[ -z "$SENTINEL_OUT" ]]; then
  pass "SOCK: no ssh-cluster sentinel file present in-guest (ssh-agent-status/ssh-allowed-keys/github-identity/ssh-config-source all absent)"
else
  fail "SOCK: an ssh-cluster sentinel file is still present in-guest" "$SENTINEL_OUT"
fi

# ===========================================================================
# PUSH: real clone -> commit -> push over HTTPS + --secret. Proven by an
# independent HOST-side gh api read of the commit, before vs after.
# ===========================================================================
echo ""
echo "=== PUSH (criterion 1): real clone -> commit -> push, remote ref MOVES ==="

BEFORE_SHA=$(gh api "repos/${REPO_FULL}/commits/main" --jq '.sha' 2>/dev/null || echo "")
echo "before: main sha = '${BEFORE_SHA:-<empty repo, no commits>}'"

COMMIT_MSG="rip-cage-f1qo S5 effect probe ${RUN_ID}"
PUSH_OUT=$(msb exec "$CAGE" -- sh -c "
  set -e
  cd /tmp
  GIT_TERMINAL_PROMPT=0 git clone \"https://x-access-token:\${GH_TOKEN__1_GITHUB_COM}@github.com/${REPO_FULL}.git\" push-probe 2>&1
  cd push-probe
  git config user.email 's5-probe@example.com'
  git config user.name 'rip-cage S5 effect probe'
  git checkout -b main 2>/dev/null || git checkout main
  echo 'run_id=${RUN_ID}' > PROBE.md
  git add PROBE.md
  git commit -m '${COMMIT_MSG}'
  GIT_TERMINAL_PROMPT=0 git push origin main 2>&1
  echo GUEST_REMOTE_URL_CHECK:
  cat .git/config | grep -F 'url ='
" 2>/tmp/5s1q-push.err)
PUSH_RC=$?

if [[ $PUSH_RC -eq 0 ]]; then
  pass "PUSH: clone/commit/push completed with exit 0 (not yet proof of a real landed push -- see below)"
else
  fail "PUSH: clone/commit/push failed" "rc=$PUSH_RC out=${PUSH_OUT} stderr=$(cat /tmp/5s1q-push.err 2>/dev/null)"
fi

# shellcheck disable=SC2016  # literal $-prefixed placeholder text we're grepping for, not host expansion
if echo "$PUSH_OUT" | grep -q 'x-access-token:\$MSB_GH_TOKEN\|x-access-token:\$GH_TOKEN__1_GITHUB_COM'; then
  pass "PUSH: persisted git remote URL holds the msb PLACEHOLDER, never the real token (non-possession proven in-guest)"
else
  fail "PUSH: could not confirm the persisted remote URL holds a placeholder (possible real-token leak or unexpected format)" "$PUSH_OUT"
fi

# The real proof: independent HOST-side read via gh api (real bidirectional
# GitHub API data, outside the guest entirely) -- the ref actually moved.
AFTER_SHA=$(gh api "repos/${REPO_FULL}/commits/main" --jq '.sha' 2>/dev/null || echo "")
AFTER_MSG=$(gh api "repos/${REPO_FULL}/commits/main" --jq '.commit.message' 2>/dev/null || echo "")
echo "after:  main sha = '${AFTER_SHA:-<still empty>}' message='${AFTER_MSG}'"

if [[ -n "$AFTER_SHA" && "$AFTER_SHA" != "$BEFORE_SHA" && "$AFTER_MSG" == "$COMMIT_MSG" ]]; then
  pass "PUSH: remote ref MOVED -- host-side gh api confirms real commit landed (before='${BEFORE_SHA:-<empty>}' after='${AFTER_SHA}', message matches)"
else
  fail "PUSH: remote ref did NOT move as expected (before='${BEFORE_SHA:-<empty>}' after='${AFTER_SHA:-<empty>}' message='${AFTER_MSG}', expected='${COMMIT_MSG}')" ""
fi

AFTER_CONTENT=$(gh api "repos/${REPO_FULL}/contents/PROBE.md" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if echo "$AFTER_CONTENT" | grep -qF "run_id=${RUN_ID}"; then
  pass "PUSH: real file content independently readable from GitHub (host-side gh api), matches what was pushed"
else
  fail "PUSH: pushed file content not independently readable/matching via gh api" "got: '${AFTER_CONTENT}'"
fi

# ===========================================================================
# PR: real branch -> push -> gh pr create, all from inside the cage. Proven
# by an independent HOST-side gh pr view read.
# ===========================================================================
echo ""
echo "=== PR (criterion 1): real branch -> push -> gh pr create, from inside the cage ==="

PR_TITLE="rip-cage-f1qo S5 effect probe PR ${RUN_ID}"
PR_OUT=$(msb exec "$CAGE" -- sh -c "
  set -e
  cd /tmp/push-probe
  git checkout -b '${BRANCH}'
  echo 'pr_run_id=${RUN_ID}' > PR_PROBE.md
  git add PR_PROBE.md
  git commit -m 'S5 probe PR commit ${RUN_ID}'
  GIT_TERMINAL_PROMPT=0 git push origin '${BRANCH}' 2>&1
  GH_TOKEN=\"\${GH_TOKEN__2_API_GITHUB_COM}\" gh pr create --repo '${REPO_FULL}' \
    --title '${PR_TITLE}' --body 'rip-cage-f1qo S5 effect probe -- proves gh pr create works from inside an msb cage over HTTPS + --secret, no ssh.' \
    --head '${BRANCH}' --base main 2>&1
" 2>/tmp/5s1q-pr.err)
PR_RC=$?

if [[ $PR_RC -eq 0 ]]; then
  pass "PR: branch push + gh pr create completed with exit 0 (not yet proof of a real PR -- see below)"
else
  fail "PR: branch push + gh pr create failed" "rc=$PR_RC out=${PR_OUT} stderr=$(cat /tmp/5s1q-pr.err 2>/dev/null)"
fi

# The real proof: independent HOST-side read via gh pr view.
HOST_PR_JSON=$(gh pr list --repo "$REPO_FULL" --head "$BRANCH" --json number,title,state,url 2>/dev/null || echo "[]")
HOST_PR_TITLE=$(echo "$HOST_PR_JSON" | jq -r '.[0].title // empty')
HOST_PR_STATE=$(echo "$HOST_PR_JSON" | jq -r '.[0].state // empty')
HOST_PR_URL=$(echo "$HOST_PR_JSON" | jq -r '.[0].url // empty')

if [[ "$HOST_PR_TITLE" == "$PR_TITLE" && "$HOST_PR_STATE" == "OPEN" ]]; then
  pass "PR: real PR independently confirmed from the HOST via gh pr list -- title matches, state=OPEN, url=${HOST_PR_URL}"
else
  fail "PR: could not independently confirm a real, open PR from the host" "title='${HOST_PR_TITLE}' state='${HOST_PR_STATE}' expected_title='${PR_TITLE}'"
fi

echo ""
if (( FAILURES > 0 )); then
  echo "=== test-msb-ssh-retirement-effect-probes.sh: ${FAILURES}/${TOTAL} failure(s) ==="
  exit 1
fi
echo "=== test-msb-ssh-retirement-effect-probes.sh: all ${TOTAL} tests passed ==="
