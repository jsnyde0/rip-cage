#!/usr/bin/env bash
set -uo pipefail

# tests/test-beads-redirect-validity.sh -- host-tier proof for rip-cage-p4ss.1.
#
# .beads/redirect is workspace content (ADR-024 prompt-injection scope) and
# its target is mounted READ-WRITE at /workspace/.beads. A steered agent that
# writes ../../.claude into it used to get host ~/.claude (settings.json hooks)
# writable at the next cage create -- host code execution. rc now mounts the
# target only when it is a .beads dir holding metadata.json, sits outside
# every $HOME dotdir, is no ancestor of ~/.claude or ~/.pi, and its realpath
# carries no control characters. Any miss refuses the run, no mount.
#
#   L   redirect -> a sibling repo's real .beads           -> mounted rw
#   C   redirect -> fake $HOME/.claude (metadata planted)  -> refused
#   A   redirect -> fake $HOME/.pi/agent                   -> refused
#   D   redirect -> a .beads inside a $HOME dotdir         -> refused
#   P   redirect -> a sibling project ROOT (not a .beads)  -> refused
#   M   redirect -> a .beads dir without metadata.json     -> refused
#   N   redirect -> a symlink whose realpath has a newline -> refused
#
# Each refused case fails exactly ONE rule and passes the others, so a refusal
# proves that rule: D is a real .beads with metadata.json (only the dotdir rule
# refuses it), N likewise outside every dotdir (only the control-char rule), M
# is named .beads without metadata.json. The refusal text is not asserted:
# --dry-run drops mount-preparation stderr (cli/up.sh dry-run branch), so the
# exit code and the absent mount are the observable signal.
#
# Every `rc up` is --dry-run behind fake docker + msb PATH shims under a temp
# HOME and XDG_CONFIG_HOME; the call log is asserted free of mutating calls.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }

T=$(mktemp -d /private/tmp/rc-beads-redir-XXXXXX)
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
mkdir -p "$H/.config/rip-cage" "$H/.claude" "$H/.pi/agent" "$H/.local/share/x/.beads"
printf '{}\n' > "$H/.claude/metadata.json"
printf '{}\n' > "$H/.pi/agent/metadata.json"
printf '{}\n' > "$H/.local/share/x/.beads/metadata.json"
[[ -e "${HOME}/.docker" ]] && ln -sfn "${HOME}/.docker" "${H}/.docker"

# Projects live under $H/code so ../ walks reach the fake dotdirs.
mkdir -p "$H/code/main/.beads" "$H/code/sibling" "$H/code/nometa/.beads"
printf '{"dolt_mode":"embedded"}\n' > "$H/code/main/.beads/metadata.json"
printf 'SECRET=1\n' > "$H/code/sibling/.env"
mkdir -p "$H/code/evil"$'\n'"dir/.beads"
printf '{}\n' > "$H/code/evil"$'\n'"dir/.beads/metadata.json"
ln -s "$H/code/evil"$'\n'"dir" "$H/code/nl-link"

# _dry_run LABEL REDIRECT-CONTENT -> OUT, RCODE, ARGV
_dry_run() {
  local _ws="${T}/ws-$1" _conf="${T}/conf-$1.yaml"
  mkdir -p "$_ws/.beads"
  printf '%s\n' "$2" > "$_ws/.beads/redirect"
  # The workspace sits at $H/code/ws-<label> so redirects are ../<x> relative.
  rm -rf "$H/code/ws-$1"; mv "$_ws" "$H/code/ws-$1"; _ws="$H/code/ws-$1"
  cat > "$_conf" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${_ws}:/workspace"
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

# _expect_refuse LABEL
_expect_refuse() {
  local _l="$1"
  if [[ $RCODE -ne 0 ]]; then pass "${_l} rc up --dry-run refuses (exit ${RCODE})"; else fail "${_l} exit 0 — redirect was not refused"; fi
  if ! grep -q ':/workspace/.beads' <<<"$OUT"; then
    pass "${_l} no /workspace/.beads mount emitted"
  else
    fail "${_l} still mounts /workspace/.beads: $(grep ':/workspace/.beads' <<<"$OUT" | head -2)"
  fi
  _no_mutation "$_l"
}

echo "=== L: legitimate redirect to a sibling repo's .beads ==="
_dry_run L "../main/.beads"
if [[ $RCODE -eq 0 ]]; then pass "L rc up --dry-run exits 0"; else fail "L exit ${RCODE}: $(tail -3 <<<"$OUT")"; fi
if grep -Eq -- "-v ${H}/code/main/\.beads:/workspace/\.beads( |$)" <<<"$ARGV"; then
  pass "L argv mounts the real .beads rw at /workspace/.beads"
else
  fail "L legitimate redirect lost its mount: ${ARGV:-<no argv line>}"
fi
_no_mutation L

echo "=== C: redirect into fake ~/.claude ==="
_dry_run C "../../.claude"
_expect_refuse C

echo "=== A: redirect into fake ~/.pi/agent ==="
_dry_run A "../../.pi/agent"
_expect_refuse A

echo "=== D: a real .beads inside a home dotdir ==="
_dry_run D "../../.local/share/x/.beads"
_expect_refuse D

echo "=== P: redirect to a sibling project root ==="
_dry_run P "../sibling"
_expect_refuse P

echo "=== M: a .beads dir without metadata.json ==="
_dry_run M "../nometa/.beads"
_expect_refuse M

echo "=== N: realpath carries a newline ==="
_dry_run N "../nl-link/.beads"
_expect_refuse N

echo
if [[ $FAILURES -gt 0 ]]; then
  echo "FAILED: $FAILURES check(s)"
  exit 1
fi
echo "All checks passed."
