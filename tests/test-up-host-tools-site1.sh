#!/usr/bin/env bash
set -uo pipefail

# tests/test-up-host-tools-site1.sh -- host-tier proof for rip-cage-jdl2.3.1
# (ADR-032 D2/D6): `rc up` check site 1 (the pre-msb floor block), the state /
# python3 / socket-path helpers, the real-path config, and the authority-
# directory predicate at every mount site. Runs the REAL rc behind the fake
# runtime (tests/_fake-runtime-lib.sh); no cage, no docker daemon, no msb.
#
# Every refusal case runs twice, real and --dry-run, and asserts: non-zero
# exit, exactly one "Error:" line, the expected substrings (the directory and
# the row, or the cause), and NO msb call besides the preflight --version.

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

T=$(mktemp -d /tmp/rc-site1-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
LOG="${T}/calls.log"
: > "$LOG"
FAKE_BIN=$(fake_runtime_bin "$LOG")
trap 'rm -rf "$T" "$FAKE_BIN"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
export PATH="${FAKE_BIN}:${PATH}"
unset RC_STATE_DIR RC_PYTHON3 RC_CAGE_CONF
PROJECTS="${XDG_CONFIG_HOME}/rip-cage/projects"
STATE_ROOT="${XDG_STATE_HOME}/rip-cage"

mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "$T/ws/bin" "$T/ws2/.beads" "$T/bin" "$T/conf" "$T/cwd" "$T/real/sub" "$T/link" "$T/ws3"
printf 'print(1)\n' > "$T/ws/tool.py"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tool";   chmod 0755 "$T/bin/tool"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/okpy";   chmod 0755 "$T/bin/okpy"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/stubpy"; chmod 0755 "$T/bin/stubpy"
printf '#!/bin/sh\nexit 0\n' > "$T/ws/bin/py";  chmod 0755 "$T/ws/bin/py"
ln -s "$T/ws/bin/py" "$T/bin/py-link"

# mk_conf FILE PROJECT [EXTRA_ROW...] -- a minimal native config.
mk_conf() {
  local _f="$1" _proj="$2"; shift 2
  {
    printf 'image: rip-cage:latest\nworkdir: /workspace\nmounts:\n  - "%s:/workspace"\n' "$_proj"
    printf "  - \"%s/.claude/projects:/home/agent/.claude/projects\"\n  - \"%s/.claude/sessions:/home/agent/.claude/sessions\"\n" "$HOME" "$HOME"
    local _r
    for _r in "$@"; do printf '  - "%s"\n' "$_r"; done
    printf 'network:\n  policy: none\n  strict: false\n  allow:\n    - "api.anthropic.com:tcp:443"\n'
  } > "$_f"
}

# mk_decl FILE [EXTRA_ARGV_ELEMENT] -- a valid declaration (argv[0] outside every mount).
mk_decl() {
  {
    printf 'tools:\n  demo:\n    verbs:\n      go:\n        argv: ["%s/bin/tool"' "$T"
    [[ -n "${2:-}" ]] && printf ', "%s"' "$2"
    printf ']\n        timeout: 30s\n'
  } > "$1"
}

# run_up [VAR=val ...] -- ARGS...  -> OUT, EX; the call log holds this run only.
OUT=''; EX=0
run_up() {
  local -a _envs=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done
  shift
  : > "$LOG"
  OUT=$(cd "$T/cwd" && env ${_envs[@]+"${_envs[@]}"} "$RC" "$@" 2>&1)
  EX=$?
}

# msb_calls -- every msb call except the preflight --version.
msb_calls() { grep '^msb ' "$LOG" | grep -v '^msb --version$' || true; }

# assert_refused LABEL NEEDLE... -- exit non-zero, one Error: line, needles
# present, no msb call.
assert_refused() {
  local _label="$1"; shift
  local _n _needle _ok=1 _calls
  _n=$(printf '%s\n' "$OUT" | grep -c '^Error:' || true)
  _calls=$(msb_calls)
  [[ "$EX" -ne 0 ]] || { _ok=0; echo "  exit was 0"; }
  [[ "$_n" == 1 ]] || { _ok=0; echo "  Error: lines = ${_n}, want 1"; }
  for _needle in "$@"; do
    [[ "$OUT" == *"${_needle}"* ]] || { _ok=0; echo "  missing substring: ${_needle}"; }
  done
  [[ -z "$_calls" ]] || { _ok=0; echo "  msb called: ${_calls}"; }
  if [[ "$_ok" == 1 ]]; then pass "$_label"; else fail "$_label"; echo "  output: ${OUT}"; fi
}

# refuse_both LABEL [VAR=val ...] -- UP_ARGS... :: NEEDLE...
refuse_both() {
  local _label="$1"; shift
  local -a _envs=() _args=() _needles=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done; shift
  while [[ "$1" != :: ]]; do _args+=("$1"); shift; done; shift
  _needles=("$@")
  run_up ${_envs[@]+"${_envs[@]}"} -- up "${_args[@]}"
  assert_refused "${_label} (real)" "${_needles[@]}"
  run_up ${_envs[@]+"${_envs[@]}"} -- up --dry-run "${_args[@]}"
  assert_refused "${_label} (--dry-run)" "${_needles[@]}"
}

# --- A. config row overlaps an authority directory ---------------------------
echo "=== A: config row vs authority directories ==="
mkdir -p "$PROJECTS"
auth_case() { # LABEL ROW_HOST DIR_NEEDLE
  local _l="$1" _row="$2" _dir="$3"
  mk_conf "$T/conf/a.yaml" "$T/ws" "${_row}:/x"
  # "authority directory <dir>" is not a substring of the row, so the needle
  # proves the message names the directory, not just echoes the row.
  refuse_both "A: ${_l}" -- --conf "$T/conf/a.yaml" "$T/ws" :: "Error:" "authority directory ${_dir}" "${_row}"
}
auth_case "row = default projects dir"        "$PROJECTS"          "$PROJECTS"
auth_case "row = its parent (~/.config)"       "$XDG_CONFIG_HOME"   "$PROJECTS"
auth_case "row = a child of the projects dir"  "$PROJECTS/sub"      "$PROJECTS"
auth_case "row = state root (nonexistent)"     "$STATE_ROOT"        "$STATE_ROOT"
auth_case "row = parent of the state root"     "$XDG_STATE_HOME"    "$STATE_ROOT"
auth_case "row = child of the state root"      "$STATE_ROOT/x"      "$STATE_ROOT"
# Ruling 2026-11-09: a mount strictly inside the --conf dir is allowed (the
# config-beside-project layout); only equals-or-contains is refused. PASS control:
mk_conf "$T/conf/a.yaml" "$T/ws" "$T/conf/sub:/x"
run_up -- up --conf "$T/conf/a.yaml" "$T/ws"
if grep -q '^msb create' "$LOG" && [[ "$OUT" != *"Error:"* ]]; then pass "A: row strictly inside the --conf dir is allowed (fake create recorded)"; else fail "A: child of --conf dir: ${OUT}"; fi
# a row that contains the --conf dir (its parent) stays a refusal
mk_conf "$T/conf/a.yaml" "$T/ws" "$T:/x"
refuse_both "A: row = parent of the --conf dir" -- --conf "$T/conf/a.yaml" "$T/ws" :: "Error:" "$T"
# the --conf directory itself: this refusal comes from
# _protected_paths_conf_outside_mounts (the config sits inside the mount), not
# from the authority predicate -- a row equal to or containing the conf dir
# contains the config itself, so the predicate's conf-dir equals/contains legs
# are unreachable at site 1. Assert the refusal and the directory only.
mk_conf "$T/conf/a.yaml" "$T/ws" "$T/conf:/x"
refuse_both "A: row = the --conf directory" -- --conf "$T/conf/a.yaml" "$T/ws" :: "Error:" "$T/conf"
# a workspace that contains RC_STATE_DIR
mk_conf "$T/conf/a.yaml" "$T/ws3"
refuse_both "A: workspace contains RC_STATE_DIR" "RC_STATE_DIR=$T/ws3/state" -- --conf "$T/conf/a.yaml" "$T/ws3" :: "Error:" "$T/ws3/state" "$T/ws3"

# relative RC_STATE_DIR: the refusal names the canonical path, not ../
mk_conf "$T/conf/a.yaml" "$T/ws3"
run_up "RC_STATE_DIR=../ws3/st" -- up --conf "$T/conf/a.yaml" "$T/ws3"
assert_refused "A: relative RC_STATE_DIR names the canonical path" "Error:" "authority directory $T/ws3/st"
[[ "$OUT" != *"/cwd/../"* ]] || fail "A: refusal still carries an unnormalized path"

# --- B. the declaration: schema, argv path, declaration file ----------------
echo "=== B: declaration defects (site 1) ==="
mk_conf "$T/conf/b.yaml" "$T/ws"
printf 'tools:\n  demo:\n    bogus: 1\n' > "$T/conf/b.tools.yaml"
refuse_both "B: schema defect" "RC_PYTHON3=$T/bin/okpy" -- --conf "$T/conf/b.yaml" "$T/ws" :: "Error:" "host-tool declaration" "$T/conf/b.tools.yaml"
mk_decl "$T/conf/b.tools.yaml" "$T/ws/tool.py"
refuse_both "B: argv path inside a config-row mount" "RC_PYTHON3=$T/bin/okpy" -- --conf "$T/conf/b.yaml" "$T/ws" :: "Error:" "host-tool declaration" "$T/ws"
mk_decl "$T/ws/decl.yaml"
rm -f "$T/conf/b.tools.yaml"; ln -s "$T/ws/decl.yaml" "$T/conf/b.tools.yaml"
refuse_both "B: declaration file inside a mount" "RC_PYTHON3=$T/bin/okpy" -- --conf "$T/conf/b.yaml" "$T/ws" :: "Error:" "declaration file" "$T/ws"
rm -f "$T/conf/b.tools.yaml"

# --- C. python3 prerequisite --------------------------------------------------
echo "=== C: python3 prerequisite ==="
mk_conf "$T/conf/c.yaml" "$T/ws"
mk_decl "$T/conf/c.tools.yaml"
refuse_both "C: RC_PYTHON3 inside a mounted workspace" "RC_PYTHON3=$T/ws/bin/py" -- --conf "$T/conf/c.yaml" "$T/ws" :: "Error:" "python3" "inside mount source" "$T/ws"
refuse_both "C: python3 symlink resolving into a mount"  "RC_PYTHON3=$T/bin/py-link" -- --conf "$T/conf/c.yaml" "$T/ws" :: "Error:" "python3" "$T/ws/bin/py"
refuse_both "C: stub python3 (import fails)"             "RC_PYTHON3=$T/bin/stubpy" -- --conf "$T/conf/c.yaml" "$T/ws" :: "Error:" "python3" "import socket, json, subprocess"
refuse_both "C: python3 missing"                         "RC_PYTHON3=$T/bin/nonesuch" -- --conf "$T/conf/c.yaml" "$T/ws" :: "Error:" "python3" "$T/bin/nonesuch"
run_up "RC_PYTHON3=$T/bin/okpy" -- up --dry-run --conf "$T/conf/c.yaml" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" != *"Error:"* ]]; then pass "C: a usable python3 passes site 1 (--dry-run exit 0)"; else fail "C: a usable python3 refused (exit ${EX}): ${OUT}"; fi

# --- D. real-path config -----------------------------------------------------
echo "=== D: relative and symlinked --conf resolve to the real path ==="
mk_conf "$T/real/x.yaml" "$T/ws"
ln -s "$T/real/x.yaml" "$T/link/x.yaml"
printf 'tools:\n  demo:\n    bogus: 1\n' > "$T/real/x.tools.yaml"
OUT=$(cd "$T/real" && "$RC" up --dry-run --conf ./x.yaml "$T/ws" 2>&1); EX=$?
if [[ "$EX" -ne 0 && "$OUT" == *"$T/real/x.tools.yaml"* ]]; then pass "D: relative ./x.yaml finds the sibling beside the real file"; else fail "D: relative: ${OUT}"; fi
OUT=$(cd "$T/cwd" && "$RC" up --dry-run --conf "$T/link/x.yaml" "$T/ws" 2>&1); EX=$?
if [[ "$EX" -ne 0 && "$OUT" == *"$T/real/x.tools.yaml"* ]]; then pass "D: symlinked --conf finds the sibling beside the real file"; else fail "D: symlink: ${OUT}"; fi
rm -f "$T/real/x.tools.yaml"
OUT=$(cd "$T/real" && "$RC" up --dry-run --conf ./x.yaml "$T/ws" 2>&1)
if printf '%s\n' "$OUT" | grep -q -- "--conf $T/real/x.yaml"; then pass "D: relative --conf reaches the argv as the real path"; else fail "D: relative argv: ${OUT}"; fi
OUT=$(cd "$T/cwd" && "$RC" up --dry-run --conf "$T/link/x.yaml" "$T/ws" 2>&1)
if printf '%s\n' "$OUT" | grep -q -- "--conf $T/real/x.yaml"; then pass "D: symlinked --conf reaches the argv as the real path"; else fail "D: symlink argv: ${OUT}"; fi
# the conf-dir the predicate sees is the REAL directory
mk_conf "$T/real/y.yaml" "$T/ws" "$T/real:/s"
ln -sf "$T/real/y.yaml" "$T/link/y.yaml"
run_up -- up --dry-run --conf "$T/link/y.yaml" "$T/ws"
assert_refused "D: symlinked --conf, the refusal names the real conf dir" "Error:" "$T/real"

# --- E. socket path over the platform limit -----------------------------------
echo "=== E: socket path limit ==="
LONG="${T}/$(printf 'a%.0s' $(seq 1 130))"
refuse_both "E: over-limit socket path" "RC_PYTHON3=$T/bin/okpy" "RC_STATE_DIR=$LONG" -- --conf "$T/conf/c.yaml" "$T/ws" :: "Error:" "RC_STATE_DIR"

# --- F. dropped computed mounts ----------------------------------------------
echo "=== F: a computed mount over an authority directory is dropped ==="
mkdir -p "$HOME/.claude/skills" "$XDG_CONFIG_HOME/some-skill"
ln -s "$XDG_CONFIG_HOME/some-skill" "$HOME/.claude/skills/some-skill"
mk_conf "$T/conf/f.yaml" "$T/ws"
run_up -- up --dry-run --conf "$T/conf/f.yaml" "$T/ws"
ARGV=$(printf '%s\n' "$OUT" | grep '^Would run: msb create' || true)
if [[ "$OUT" == *"Warning:"*"$PROJECTS"* && -n "$ARGV" && "$ARGV" != *"-v ${XDG_CONFIG_HOME}:"* && "$OUT" != *"Would mount ${XDG_CONFIG_HOME} ->"* ]]; then
  pass "F: --dry-run warns naming the authority dir and drops the mount from the printed argv"
else
  fail "F: dry-run drop: ${OUT}"
fi
run_up -- up --conf "$T/conf/f.yaml" "$T/ws"
CREATE=$(grep '^msb create' "$LOG" || true)
if [[ "$OUT" == *"Warning:"*"$PROJECTS"* && -n "$CREATE" && "$CREATE" != *"-v ${XDG_CONFIG_HOME}:"* ]]; then
  pass "F: real run warns naming the authority dir and the create argv has no such mount"
else
  fail "F: real drop: ${OUT} / ${CREATE}"
fi
rm -f "$HOME/.claude/skills/some-skill"

# --- G. explicit .beads/redirect inside the state root ------------------------
echo "=== G: beads redirect target inside the state root ==="
mkdir -p "$T/st/main/.beads"
printf '{"dolt_mode":"embedded"}\n' > "$T/st/main/.beads/metadata.json"
printf '../st/main/.beads\n' > "$T/ws2/.beads/redirect"
mk_conf "$T/conf/g.yaml" "$T/ws2"
run_up "RC_STATE_DIR=$T/st" -- up --conf "$T/conf/g.yaml" "$T/ws2"
if [[ "$EX" -ne 0 && "$OUT" == *"Error:"* && "$OUT" == *"$T/st"* && -z "$(grep '^msb create' "$LOG" || true)" ]]; then
  pass "G: explicit redirect into the state root is a hard refusal (real, no create)"
else
  fail "G: ${OUT}"
fi
run_up "RC_STATE_DIR=$T/st" -- up --dry-run --conf "$T/conf/g.yaml" "$T/ws2"
if [[ "$EX" -ne 0 && "$OUT" == *"Error:"* && "$OUT" == *"$T/st"* ]]; then
  pass "G: explicit redirect into the state root is refused under --dry-run"
else
  fail "G dry-run: ${OUT}"
fi

# --- G2. worktree whose main .git lies in an authority directory ----------------
echo "=== G2: worktree main .git mount in an authority directory is dropped ==="
if command -v git >/dev/null 2>&1; then
  mkdir -p "$PROJECTS/mainrepo"
  ( cd "$PROJECTS/mainrepo" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && git worktree add -q "$T/wt" -b wtbranch ) >/dev/null 2>&1
  mkdir -p "$PROJECTS/mainrepo/.beads"
  mk_conf "$T/conf/w.yaml" "$T/wt"
  run_up -- up --conf "$T/conf/w.yaml" "$T/wt"
  CREATE=$(grep '^msb create' "$LOG" || true)
  if [[ "$OUT" == *"Warning: skipping worktree main .git mount"*"$PROJECTS"* && -n "$CREATE" && "$CREATE" != *"/workspace/.git-main"* ]]; then
    pass "G2: worktree main .git warned about naming the authority dir, no .git-main mount in the create argv"
  else
    fail "G2: ${OUT} / ${CREATE}"
  fi
  run_up -- up --dry-run --conf "$T/conf/w.yaml" "$T/wt"
  ARGV=$(printf '%s\n' "$OUT" | grep '^Would run: msb create' || true)
  if [[ "$OUT" == *"Warning: skipping worktree main .git mount"*"authority directory $PROJECTS"*"broken repository"* \
     && "$OUT" != *"Would mount worktree main"* && "$OUT" != *"Would mount corrected .git pointer"* \
     && "$OUT" != *"Would mount hooks, config, info"* && -n "$ARGV" && "$ARGV" != *"/workspace/.git-main"* ]]; then
    if [[ "$OUT" == *"Warning: worktree auto-redirect"*"$PROJECTS"* ]]; then pass "G2: --dry-run replays the worktree auto-redirect drop warning (held-stderr replay)"; else fail "G2 auto-redirect replay: ${OUT}"; fi
    pass "G2: --dry-run prints the drop warning (broken-repository note), none of the three Would mount worktree lines, no .git-main in argv"
  else
    fail "G2 dry-run: ${OUT}"
  fi
else
  echo "SKIP: git not on PATH"
fi

# --- H. no state directory is created -----------------------------------------
echo "=== H: --dry-run creates no state directory ==="
STX="$T/stx"
run_up "RC_PYTHON3=$T/bin/okpy" "RC_STATE_DIR=$STX" -- up --dry-run --conf "$T/conf/c.yaml" "$T/ws"
if [[ ! -e "$STX" && "$EX" -eq 0 ]]; then pass "H: valid declaration, --dry-run: state root not created"; else fail "H: exit ${EX}, ${STX} exists? ${OUT}"; fi
printf 'tools:\n  demo:\n    bogus: 1\n' > "$T/conf/c.tools.yaml"
run_up "RC_PYTHON3=$T/bin/okpy" "RC_STATE_DIR=$STX" -- up --dry-run --conf "$T/conf/c.yaml" "$T/ws"
if [[ ! -e "$STX" && "$EX" -ne 0 ]]; then pass "H: defective declaration, --dry-run: refused, nothing created"; else fail "H defective: ${OUT}"; fi
run_up "RC_PYTHON3=$T/bin/okpy" "RC_STATE_DIR=$STX" -- up --conf "$T/conf/c.yaml" "$T/ws"
if [[ ! -e "$STX" ]]; then pass "H: defective declaration, real: nothing created"; else fail "H real: ${STX} exists"; fi
rm -f "$T/conf/c.tools.yaml"

# --- I. no declaration: none of the declaration checks run ---------------------
echo "=== I: no declaration -> an unrelated config still launches ==="
mk_conf "$T/conf/i.yaml" "$T/ws"
run_up "RC_PYTHON3=$T/bin/nonesuch" "RC_STATE_DIR=$LONG" -- up --conf "$T/conf/i.yaml" "$T/ws"
if grep -q '^msb create' "$LOG" && [[ "$OUT" != *"Error:"* ]]; then
  pass "I: no declaration, missing python3 and over-limit socket path: fake create recorded"
else
  fail "I: ${OUT}"; sed 's/^/    log: /' "$LOG"
fi

# --- J. JSON codes -------------------------------------------------------------
echo "=== J: JSON refusal codes ==="
json_code() { # LABEL CODE [VAR=val ...] -- CONF
  local _l="$1" _c="$2"; shift 2
  local -a _e=()
  while [[ "$1" != -- ]]; do _e+=("$1"); shift; done; shift
  : > "$LOG"
  OUT=$(cd "$T/cwd" && env ${_e[@]+"${_e[@]}"} "$RC" --output json up --conf "$1" "$T/ws" 2>/dev/null); EX=$?
  if [[ "$EX" -ne 0 && "$(printf '%s\n' "$OUT" | jq -r '.code' 2>/dev/null)" == "$_c" && -z "$(msb_calls)" ]]; then pass "J: ${_l} -> ${_c}"; else fail "J: ${_l}: ${OUT}"; fi
}
mk_conf "$T/conf/ja.yaml" "$T/ws" "$STATE_ROOT:/x"
json_code "authority row" AUTHORITY_DIR_INSIDE_MOUNT -- "$T/conf/ja.yaml"
mk_conf "$T/conf/jb.yaml" "$T/ws"
printf 'tools:\n  demo:\n    bogus: 1\n' > "$T/conf/jb.tools.yaml"
json_code "declaration defect" HOST_TOOLS_DECL_REFUSED "RC_PYTHON3=$T/bin/okpy" -- "$T/conf/jb.yaml"
mk_conf "$T/conf/jc.yaml" "$T/ws"; mk_decl "$T/conf/jc.tools.yaml"
json_code "python3" PYTHON3_UNUSABLE "RC_PYTHON3=$T/bin/stubpy" -- "$T/conf/jc.yaml"
json_code "socket path" STATE_DIR_SOCKET_PATH "RC_PYTHON3=$T/bin/okpy" "RC_STATE_DIR=$LONG" -- "$T/conf/jc.yaml"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then echo "All site-1 checks passed"; exit 0; fi
echo "${FAILURES} site-1 check(s) FAILED"
exit 1
