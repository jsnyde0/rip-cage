#!/usr/bin/env bash
set -uo pipefail

# tests/test-up-host-tools-sites.sh -- host-tier proof for rip-cage-jdl2.3.2
# (ADR-032 D2/D6, child B of the rc up wiring): the --vsock route flag, the
# rc.host-tools / rc.state-dir labels, the presence converge, check sites 2
# and 3, and the fake-runtime inspect override they need. Runs the REAL rc
# behind the fake runtime (tests/_fake-runtime-lib.sh); no cage, no docker
# daemon, no msb. Site 1 and the helpers are tests/test-up-host-tools-site1.sh.
#
# Every refusal asserts the exit code, the Error: substring(s), and the
# recorded msb calls (no create / no start / no exec as the contract says).
# Every argv case greps the printed "Would run:" line or the recorded create.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

T=$(mktemp -d /tmp/rc-sites-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
LOG="${T}/calls.log"
: > "$LOG"
FAKE_BIN=$(fake_runtime_bin "$LOG")
trap 'rm -rf "$T" "$FAKE_BIN"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
export PATH="${FAKE_BIN}:${PATH}"
unset RC_STATE_DIR RC_PYTHON3 RC_CAGE_CONF FAKE_MSB_INSPECT_FILE
STATE_ROOT="${XDG_STATE_HOME}/rip-cage"

mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$HOME/.claude/commands" \
  "$T/ws/.git/hooks" "$T/ws/.git/info" "$T/bin" "$T/conf" "$T/cwd" "$T/rd/.beads" "$T/ws2/.beads"
: > "$T/ws/.git/config"
: > "$T/ws/.env"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tool";  chmod 0755 "$T/bin/tool"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/okpy";  chmod 0755 "$T/bin/okpy"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.claude/commands/py"; chmod 0755 "$HOME/.claude/commands/py"
printf '{"dolt_mode":"embedded"}\n' > "$T/rd/.beads/metadata.json"

# The cage name rc derives for a project path (parent-base, as container_name).
cage_name() {
  local _p="$1"
  printf '%s-%s' "$(basename "$(dirname "$_p")")" "$(basename "$_p")" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^[.-]*//' | sed 's/-$//'
}
NAME=$(cage_name "$T/ws")
SOCK="${STATE_ROOT}/${NAME}/host-tool.sock"

# mk_conf FILE PROJECT -- a minimal native config.
mk_conf() {
  {
    printf 'image: rip-cage:latest\nworkdir: /workspace\nmounts:\n  - "%s:/workspace"\n' "$2"
    printf "  - \"%s/.claude/projects:/home/agent/.claude/projects\"\n  - \"%s/.claude/sessions:/home/agent/.claude/sessions\"\n" "$HOME" "$HOME"
    printf 'network:\n  policy: none\n  strict: false\n  allow:\n    - "api.anthropic.com:tcp:443"\n'
  } > "$1"
}

# mk_decl FILE [ARGV1] -- a valid declaration; argv[0] outside every mount,
# an optional second argv literal.
mk_decl() {
  {
    printf 'tools:\n  demo:\n    verbs:\n      go:\n        argv: ["%s/bin/tool"' "$T"
    [[ -n "${2:-}" ]] && printf ', "%s"' "$2"
    printf ']\n        timeout: 30s\n'
  } > "$1"
}

OUT=''; EX=0
run_up() { # [VAR=val ...] -- ARGS...  -> OUT, EX; the call log holds this run only
  local -a _envs=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done
  shift
  : > "$LOG"
  rm -f "${T}/inspect.json.removed"
  OUT=$(cd "$T/cwd" && env RC_PYTHON3="$T/bin/okpy" ${_envs[@]+"${_envs[@]}"} "$RC" "$@" 2>&1)
  EX=$?
}

calls() { grep '^msb ' "$LOG" | grep -v '^msb --version$' || true; }
has_call() { grep -q "^msb $1" "$LOG"; }
error_count() { printf '%s\n' "$OUT" | grep -c '^Error:' || true; }

# argv_of -- the printed "Would run: msb create ..." line (dry-run) or the
# recorded create call.
dry_argv() { printf '%s\n' "$OUT" | grep '^Would run: msb create' || true; }
real_argv() { grep '^msb create' "$LOG" || true; }

# count_word LINE WORD -- exact-token occurrences in a space-separated line.
count_word() { printf '%s\n' "$1" | tr ' ' '\n' | grep -cx -- "$2" || true; }
# index_of LINE WORD -- 1-based token index of the first exact match, 0 if none.
index_of() { printf '%s\n' "$1" | tr ' ' '\n' | grep -nx -- "$2" | head -1 | cut -d: -f1 | grep . || echo 0; }

# assert_refused LABEL FORBIDDEN_CALL_REGEX NEEDLE... -- exit non-zero, one
# Error: line, needles present, and no recorded call matching the regex.
assert_refused() {
  local _label="$1" _forbid="$2"; shift 2
  local _needle _ok=1
  [[ "$EX" -ne 0 ]] || { _ok=0; echo "  exit was 0"; }
  [[ "$(error_count)" == 1 ]] || { _ok=0; echo "  Error: lines = $(error_count), want 1"; }
  for _needle in "$@"; do
    [[ "$OUT" == *"${_needle}"* ]] || { _ok=0; echo "  missing substring: ${_needle}"; }
  done
  if grep -Eq "^msb (${_forbid})" "$LOG"; then _ok=0; echo "  forbidden msb call recorded: $(grep -E "^msb (${_forbid})" "$LOG" | head -1)"; fi
  if [[ "$_ok" == 1 ]]; then pass "$_label"; else fail "$_label"; echo "  output: ${OUT}"; fi
}

# ============================================================================
echo "=== A: the route flag and the two labels ==="
mk_conf "$T/conf/a.yaml" "$T/ws"
mk_decl "$T/conf/a.tools.yaml"

run_up -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
ARGV=$(dry_argv)
VS=$(count_word "$ARGV" "--vsock")
if [[ "$EX" -eq 0 && "$VS" == 1 && "$ARGV" == *" --vsock ${SOCK}:7700 "* ]]; then pass "A1: dry-run prints --vsock <state>/host-tool.sock:7700 exactly once"; else fail "A1: vsock count=${VS} ex=${EX}: ${ARGV}"; fi
VI=$(index_of "$ARGV" "--vsock"); MI=$(index_of "$ARGV" "--mount-file")
if [[ "$MI" -gt 0 && "$VI" -gt 0 && "$VI" -lt "$MI" ]]; then pass "A2: the --vsock flag precedes the first --mount-file cover (token ${VI} < ${MI})"; else fail "A2: vsock at ${VI}, first --mount-file at ${MI}: ${ARGV}"; fi
if [[ "$ARGV" == *" --label rc.host-tools=present "* && "$ARGV" == *" --label rc.state-dir=${STATE_ROOT}/${NAME} "* ]]; then pass "A3: dry-run prints rc.host-tools=present and rc.state-dir=<state>"; else fail "A3: ${ARGV}"; fi
if [[ ! -e "$STATE_ROOT" ]]; then pass "A3b: --dry-run created no state directory"; else fail "A3b: ${STATE_ROOT} exists"; fi

run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
CREATE=$(real_argv)
VS=$(count_word "$CREATE" "--vsock"); VI=$(index_of "$CREATE" "--vsock"); MI=$(index_of "$CREATE" "--mount-file")
if [[ -n "$CREATE" && "$VS" == 1 && "$CREATE" == *" --vsock ${SOCK}:7700 "* && "$VI" -lt "$MI" && "$CREATE" == *" --label rc.host-tools=present "* && "$CREATE" == *" --label rc.state-dir=${STATE_ROOT}/${NAME} "* ]]; then
  pass "A4: the real create carries the same rows as the preview (vsock once before the covers, both labels)"
else
  fail "A4: ${CREATE}"
fi
# the preview and the real create print the same label/vsock rows
pick() { printf '%s\n' "$1" | tr ' ' '\n' | grep -E '^(rc\.host-tools=|rc\.state-dir=|[^ ]*host-tool\.sock:7700$)' | tr '\n' ' '; }
if [[ "$(pick "$ARGV")" == "$(pick "$CREATE")" && -n "$(pick "$CREATE")" ]]; then pass "A5: preview and real create rows are identical"; else fail "A5: '$(pick "$ARGV")' vs '$(pick "$CREATE")'"; fi

rm -f "$T/conf/a.tools.yaml"
run_up -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
ARGV=$(dry_argv)
if [[ "$(count_word "$ARGV" "--vsock")" == 0 && "$ARGV" == *" --label rc.host-tools=absent "* && "$ARGV" != *"rc.state-dir"* ]]; then pass "A6: no declaration: no --vsock, rc.host-tools=absent, no rc.state-dir (dry-run)"; else fail "A6: ${ARGV}"; fi
run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
CREATE=$(real_argv)
if [[ -n "$CREATE" && "$(count_word "$CREATE" "--vsock")" == 0 && "$CREATE" == *" --label rc.host-tools=absent "* && "$CREATE" != *"rc.state-dir"* ]]; then pass "A7: no declaration: the real create carries rc.host-tools=absent, no vsock, no rc.state-dir"; else fail "A7: ${CREATE}"; fi

# ============================================================================
echo "=== B: presence converge on a stopped cage ==="
sha_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
# mk_inspect STATUS HOST_TOOLS_LABEL(present|absent|none) [MOUNT...] -> $T/inspect.json
mk_inspect() {
  local _status="$1" _ht="$2"; shift 2
  local _mounts_json
  _mounts_json=$(printf '%s\n' "$@" | jq -R 'select(length > 0) | {host: .}' | jq -s '.')
  jq -n --arg st "$_status" --arg ht "$_ht" --arg dg "$DIGEST" --arg path "$T/ws" --arg sha "$(sha_of "$T/conf/a.yaml")" --argjson mounts "$_mounts_json" '
    {status: $st, config: {manifest_digest: $dg, labels: ({"rc.source.path": $path, "rc.cage-conf-sha": $sha, "rc.session.multiplexer": "none"}
        + (if $ht == "none" then {} else {"rc.host-tools": $ht} end)), mounts: $mounts}}' > "$T/inspect.json"
}
export FAKE_MSB_INSPECT_FILE="$T/inspect.json"
# The image the stopped cage was created from is the image msb has now, so the
# resume image-drift guard passes (the fake answers `msb image list` from this file).
DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf '[{"reference":"rip-cage:latest","digest":"%s"}]\n' "$DIGEST" > "$T/images.json"
export FAKE_MSB_IMAGE_LIST_FILE="$T/images.json"

conv_case() { # LABEL STORED_LABEL FILE(yes|no) WANT(converge|resume)
  local _l="$1" _stored="$2" _file="$3" _want="$4"
  mk_inspect Stopped "$_stored"
  if [[ "$_file" == yes ]]; then mk_decl "$T/conf/a.tools.yaml"; else rm -f "$T/conf/a.tools.yaml"; fi
  run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
  if [[ "$_want" == converge ]]; then
    if has_call "remove" && has_call "create" && [[ "$EX" -eq 0 ]]; then pass "B: ${_l}: converges (fake remove + create recorded)"; else fail "B: ${_l}: want converge (ex=${EX})"; calls | sed 's/^/    /'; fi
  else
    if has_call "start" && ! has_call "remove" && ! has_call "create"; then pass "B: ${_l}: no converge (fake start recorded, no remove, no create)"; else fail "B: ${_l}: want plain resume (ex=${EX}): ${OUT}"; calls | sed 's/^/    /'; fi
  fi
}
conv_case "label absent, file now present" absent yes converge
conv_case "label present, file now gone"   present no  converge
conv_case "label absent, no file (control)" absent no  resume
conv_case "label present, file present (control)" present yes resume
conv_case "label-less (pre-epic) cage, no file" none no resume
conv_case "label-less (pre-epic) cage, file present" none yes converge

# dry-run preview of the same decisions
mk_inspect Stopped absent; mk_decl "$T/conf/a.tools.yaml"
run_up -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *"Would converge container"* ]]; then pass "B: dry-run previews the presence converge"; else fail "B: dry-run converge: ${OUT}"; fi
mk_inspect Stopped none; rm -f "$T/conf/a.tools.yaml"
run_up -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *"Would resume container"* ]]; then pass "B: dry-run: label-less cage, no file previews a plain resume"; else fail "B: dry-run label-less: ${OUT}"; fi

# --no-reload with a presence difference: one Error:, no msb write.
echo "=== B2: --no-reload with a presence difference ==="
mk_inspect Stopped absent; mk_decl "$T/conf/a.tools.yaml"
run_up -- up --no-reload --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "B2: --no-reload + file added is refused (real)" "start|stop|remove|create|exec" "--no-reload" "host-tool declaration" "$NAME"
run_up -- up --dry-run --no-reload --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "B2: --no-reload + file added is refused (--dry-run)" "start|stop|remove|create|exec" "--no-reload" "host-tool declaration"
mk_inspect Stopped present; rm -f "$T/conf/a.tools.yaml"
run_up -- up --no-reload --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "B2: --no-reload + file removed is refused (real)" "start|stop|remove|create|exec" "--no-reload" "host-tool declaration"
mk_inspect Stopped absent
run_up -- up --no-reload --conf "$T/conf/a.yaml" "$T/ws"
if [[ "$EX" -eq 0 ]] && has_call "start" && ! has_call "remove"; then pass "B2: --no-reload with no presence difference resumes"; else fail "B2: control: ${OUT}"; fi

# ============================================================================
echo "=== C: site 2 (the final create argv) ==="
unset FAKE_MSB_INSPECT_FILE FAKE_MSB_IMAGE_LIST_FILE
COVER_SRC="${HOME}/.cache/rc/protected-cover.empty"
site2_both() { # LABEL [VAR=val ...] -- UP_ARGS... :: NEEDLE...
  local _label="$1"; shift
  local -a _envs=() _args=() _needles=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done; shift
  while [[ "$1" != :: ]]; do _args+=("$1"); shift; done; shift
  _needles=("$@")
  run_up ${_envs[@]+"${_envs[@]}"} -- up "${_args[@]}"
  assert_refused "${_label} (real)" "create" "${_needles[@]}"
  run_up ${_envs[@]+"${_envs[@]}"} -- up --dry-run "${_args[@]}"
  assert_refused "${_label} (--dry-run)" "create" "${_needles[@]}"
}

# a literal under the /workspace/.env cover's host source (a --mount-file row)
mk_conf "$T/conf/a.yaml" "$T/ws"
mk_decl "$T/conf/a.tools.yaml" "$COVER_SRC"
site2_both "C1: literal = a --mount-file cover source" -- --conf "$T/conf/a.yaml" "$T/ws" :: "Error:" "host-tool declaration" "inside mount source ${COVER_SRC}" "rc up: the cage was not created"

# a literal under the worktree main-repo .beads mount
if command -v git >/dev/null 2>&1; then
  mkdir -p "$T/mainrepo"
  ( cd "$T/mainrepo" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && git worktree add -q "$T/wt" -b wtbranch ) >/dev/null 2>&1
  mkdir -p "$T/mainrepo/.beads"
  mk_conf "$T/conf/w.yaml" "$T/wt"
  mk_decl "$T/conf/w.tools.yaml" "$T/mainrepo/.beads/x"
  site2_both "C2: literal under the worktree main-repo .beads mount" -- --conf "$T/conf/w.yaml" "$T/wt" :: "Error:" "host-tool declaration" "inside mount source $T/mainrepo/.beads"
  rm -f "$T/conf/w.tools.yaml"
else
  echo "SKIP: git not on PATH (worktree case)"
fi

# a literal under a beads-redirect target
printf '../rd/.beads\n' > "$T/ws2/.beads/redirect"
mk_conf "$T/conf/r.yaml" "$T/ws2"
mk_decl "$T/conf/r.tools.yaml" "$T/rd/.beads/x"
site2_both "C3: literal under a beads-redirect target" -- --conf "$T/conf/r.yaml" "$T/ws2" :: "Error:" "host-tool declaration" "inside mount source $T/rd/.beads"
rm -f "$T/conf/r.tools.yaml"

# RC_PYTHON3 under a computed mount source
mk_conf "$T/conf/a.yaml" "$T/ws"
mk_decl "$T/conf/a.tools.yaml"
site2_both "C4: RC_PYTHON3 under a computed mount source" "RC_PYTHON3=$HOME/.claude/commands/py" -- --conf "$T/conf/a.yaml" "$T/ws" :: "Error:" "python3" "inside mount source $HOME/.claude/commands"

# a computed mount (~/.claude/commands) containing the state root is dropped
rm -f "$T/conf/a.tools.yaml"
run_up "RC_STATE_DIR=$HOME/.claude/commands/st" -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
ARGV=$(dry_argv)
if [[ "$EX" -eq 0 && "$OUT" == *"Warning: skipping computed mount $HOME/.claude/commands"*"$HOME/.claude/commands/st"* && -n "$ARGV" && "$ARGV" != *"-v $HOME/.claude/commands:"* && "$OUT" != *"Would mount ~/.claude/commands"* ]]; then
  pass "C5: a computed mount over the state root is dropped with the warning (dry-run: warning present, no Would mount line, no such -v)"
else
  fail "C5 dry-run: ${OUT}"
fi
run_up "RC_STATE_DIR=$HOME/.claude/commands/st" -- up --conf "$T/conf/a.yaml" "$T/ws"
CREATE=$(real_argv)
if [[ "$EX" -eq 0 && "$OUT" == *"Warning: skipping computed mount $HOME/.claude/commands"* && -n "$CREATE" && "$CREATE" != *"-v $HOME/.claude/commands:"* ]]; then
  pass "C5: the real create drops it too (warning, no such -v in the recorded create)"
else
  fail "C5 real: ${OUT} / ${CREATE}"
fi

# a skill-symlink PARENT resolving inside the state root is dropped (child A's site)
mkdir -p "$HOME/.claude/skills" "$HOME/stx/sk"
ln -s "$HOME/stx/sk" "$HOME/.claude/skills/sk"
run_up "RC_STATE_DIR=$HOME/stx" -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
ARGV=$(dry_argv)
if [[ "$EX" -eq 0 && "$OUT" == *"Warning: skipping skill symlink mount $HOME/stx"*"authority directory $HOME/stx"* && -n "$ARGV" && "$ARGV" != *"-v $HOME/stx:"* && "$OUT" != *"Would mount $HOME/stx -> "* ]]; then
  pass "C5b: a skill-symlink parent inside the state root is dropped (dry-run: warning names the state root, no -v, no Would mount)"
else
  fail "C5b dry-run: ${OUT}"
fi
run_up "RC_STATE_DIR=$HOME/stx" -- up --conf "$T/conf/a.yaml" "$T/ws"
CREATE=$(real_argv)
if [[ "$EX" -eq 0 && "$OUT" == *"Warning: skipping skill symlink mount $HOME/stx"*"authority directory $HOME/stx"* && -n "$CREATE" && "$CREATE" != *"-v $HOME/stx:"* ]]; then
  pass "C5b: the real create drops the skill-symlink parent too"
else
  fail "C5b real: ${OUT} / ${CREATE}"
fi
rm -f "$HOME/.claude/skills/sk"

# converge + a site-2-only refusal: the old cage is gone and the text says so
mk_decl "$T/conf/a.tools.yaml"
mk_inspect Stopped absent
export FAKE_MSB_INSPECT_FILE="$T/inspect.json" FAKE_MSB_IMAGE_LIST_FILE="$T/images.json"
run_up "RC_PYTHON3=$HOME/.claude/commands/py" -- up --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "C9: converge then site-2 refusal says the previous cage was removed and not recreated" "create" "Error:" "python3" "removed and not recreated" "named volumes are intact"
if has_call "remove"; then pass "C9: the converge did remove the old cage (fake remove recorded)"; else fail "C9: no remove recorded"; fi
# ...the same for a LOADER defect found only against a computed mount: the
# loader's Error: stays the only one, plus the plain state line
mk_decl "$T/conf/a.tools.yaml" "$HOME/.claude/commands/x"
mk_inspect Stopped absent
run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "C9b: converge then a site-2 LOADER refusal prints the plain state line" "create" "Error:" "host-tool declaration" "inside mount source $HOME/.claude/commands" "rc up: the cage was not created — the previous cage was removed and not recreated" "named volumes are intact"
unset FAKE_MSB_INSPECT_FILE FAKE_MSB_IMAGE_LIST_FILE
rm -f "$T/conf/a.tools.yaml"

# a hit with nothing droppable behind it (a cover) refuses
site2_both "C6: the state root contains a cover source: refused" "RC_STATE_DIR=$HOME/.cache" -- --conf "$T/conf/a.yaml" "$T/ws" :: "Error:" "authority directory" "$COVER_SRC"

# socket path rechecked with the FINAL cage name (site 1 saw the shorter one)
printf '{"config":{"labels":{"rc.source.path":"/somewhere/else"}}}\n' > "$T/other.json"
mk_decl "$T/conf/a.tools.yaml"
PAD=$(( 107 - 16 - ${#NAME} - ${#T} - 1 ))   # root length such that <root>/<NAME>/host-tool.sock is exactly 107 bytes
LONGROOT="${T}/$(printf 'a%.0s' $(seq 1 "$PAD"))"
run_up "RC_STATE_DIR=$LONGROOT" -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
if [[ "$EX" -eq 0 && "$(dry_argv)" == *"host-tool.sock:7700"* ]]; then pass "C7: control: the pre-disambiguation socket path is exactly at the limit and passes"; else fail "C7 control: ${OUT}"; fi
site2_both "C7: the socket path is rechecked with the disambiguated cage name" "RC_STATE_DIR=$LONGROOT" "FAKE_MSB_INSPECT_FILE=$T/other.json" -- --conf "$T/conf/a.yaml" "$T/ws" :: "Error:" "RC_STATE_DIR" "${NAME}-"

# JSON mode code
mk_decl "$T/conf/a.tools.yaml" "$COVER_SRC"
: > "$LOG"
OUT=$(cd "$T/cwd" && RC_PYTHON3="$T/bin/okpy" "$RC" --output json up --conf "$T/conf/a.yaml" "$T/ws" 2>/dev/null); EX=$?
if [[ "$EX" -ne 0 && "$(printf '%s\n' "$OUT" | jq -r '.code' 2>/dev/null)" == "HOST_TOOLS_SITE2_REFUSED" ]] && ! has_call "create"; then pass "C8: JSON mode: site 2 refusal -> HOST_TOOLS_SITE2_REFUSED, no create"; else fail "C8: ${OUT}"; fi
rm -f "$T/conf/a.tools.yaml"

# ============================================================================
echo "=== D: site 3 (an existing cage) ==="
mk_conf "$T/conf/a.yaml" "$T/ws"
mk_decl "$T/conf/a.tools.yaml"
export FAKE_MSB_INSPECT_FILE="$T/inspect.json" FAKE_MSB_IMAGE_LIST_FILE="$T/images.json"

mk_inspect Stopped present "$T/ws" "$T/bin"
run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "D1: stopped cage, recorded mount contains a declared argv path: not started" "start|exec|create|remove" "Error:" "host-tool declaration" "$T/bin" "rc up: nothing was started"
run_up -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "D1: stopped cage (--dry-run) prints the site 3 refusal" "start|exec|create|remove" "Error:" "$T/bin"

mk_inspect Running present "$T/ws" "$T/bin"
run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "D2: running cage, recorded mount contains a declared argv path: not attached" "exec|start|create|remove" "Error:" "host-tool declaration" "$T/bin" "rc up: not attaching"
if [[ "$OUT" != *"is running"* ]]; then pass "D2: no attach banner printed (the rc up attach path never ran)"; else fail "D2: attached anyway: ${OUT}"; fi
run_up -- up --dry-run --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "D2: running cage (--dry-run) prints the site 3 refusal" "exec|start|create|remove" "Error:" "$T/bin"

mk_inspect Stopped present "$T/ws" "$HOME/.claude/commands"
run_up "RC_PYTHON3=$HOME/.claude/commands/py" -- up --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "D3: stopped cage, python3 inside a recorded mount: not started" "start|exec|create|remove" "Error:" "python3" "$HOME/.claude/commands" "nothing was started"
mk_inspect Running present "$T/ws" "$HOME/.claude/commands"
run_up "RC_PYTHON3=$HOME/.claude/commands/py" -- up --conf "$T/conf/a.yaml" "$T/ws"
assert_refused "D3: running cage, python3 inside a recorded mount: not attaching" "start|exec|create|remove" "Error:" "python3" "not attaching"

mk_inspect Stopped present "$T/ws"
run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
if [[ "$EX" -eq 0 ]] && has_call "start"; then pass "D4: control: stopped cage, recorded mounts clear of the declaration: started"; else fail "D4: ${OUT}"; calls | sed 's/^/    /'; fi
mk_inspect Running present "$T/ws"
run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *"is running"* ]] && ! has_call "start" && ! has_call "create"; then pass "D4: control: running cage, recorded mounts clear: rc up attaches (exit 0, no start, no create)"; else fail "D4 running: ${OUT}"; calls | sed 's/^/    /'; fi

# JSON code
mk_inspect Stopped present "$T/ws" "$T/bin"
: > "$LOG"
OUT=$(cd "$T/cwd" && RC_PYTHON3="$T/bin/okpy" "$RC" --output json up --conf "$T/conf/a.yaml" "$T/ws" 2>/dev/null); EX=$?
if [[ "$EX" -ne 0 && "$(printf '%s\n' "$OUT" | jq -r '.code' 2>/dev/null)" == "HOST_TOOLS_SITE3_REFUSED" ]] && ! has_call "start"; then pass "D5: JSON mode: site 3 refusal -> HOST_TOOLS_SITE3_REFUSED, no start"; else fail "D5: ${OUT}"; fi

# the seam: one function, the one every existing-cage path calls
# shellcheck disable=SC2016  # a literal pattern for grep, not an expansion
N_CALLS=$(grep -c '_up_host_tools_site3_ok "\$name"' "${REPO_ROOT}/cli/up.sh" || true)
if grep -q '^_up_host_tools_site3_ok()' "${REPO_ROOT}/cli/up.sh" && [[ "$N_CALLS" -eq 4 ]]; then pass "D6: _up_host_tools_site3_ok is defined and called at all four existing-cage paths (real/dry-run x stopped/running)"; else fail "D6: ${N_CALLS} call sites"; fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then echo "All site 2/3 checks passed"; exit 0; fi
echo "${FAILURES} site 2/3 check(s) FAILED"
exit 1
