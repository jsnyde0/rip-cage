#!/usr/bin/env bash
set -uo pipefail

# tests/test-device-ceiling.sh -- host-tier proof for rip-cage-rsh9.17.3.2
# (ADR-002 D11, "Device ceiling"): rc up counts a cage's devices on create and
# converge and refuses past the measured ceiling of Linux x86_64 (msb 0.7.8,
# step 0 of that bead). Count = the --conf file's bind mounts and named volumes
# + every -v / --mount-file share and every --vsock endpoint on the final
# `msb create` argv. Runs the REAL rc behind the fake runtime
# (tests/_fake-runtime-lib.sh); no cage, no docker daemon, no msb.
#
#   D1  a config with 104 devices and a host-tool declaration (rc adds
#       --vsock) is refused at 105; the same config without it is allowed
#   D2  an over-ceiling create is refused naming devices, ceiling, platform,
#       under a real rc up, --dry-run and --dry-run --output json; the real run
#       reaches no msb create
#   D3  config-file mounts alone over the ceiling, few argv shares: refused
#   D4  exactly 104 allowed, one more share refused
#   D5  an over-ceiling config against a running cage (attach) and a stopped
#       unchanged cage (resume): no refusal, no count, nothing written
#   D6  platform stubbed to not-Linux-x86_64: the over-ceiling fixture proceeds,
#       printing the count and "ceiling unmeasured on <platform>"
#   D7  the constant has one definition site in cli/
#   D8  cross-leaf (rip-cage-rsh9.17.3.1): a config at 104 devices without
#       nested-repo hides and over 104 with them is refused -- the count
#       includes the hide lines
#   D9  a JSON dry-run performs no host write the human dry-run does not

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
REAL_PY="$(command -v python3 || true)"
[[ -n "$REAL_PY" ]] || { echo "SKIP: python3 not on PATH (rc up starts the gatekeeper with it)"; exit 0; }
REAL_PY="$(readlink -f "$REAL_PY")"
REAL_UNAME="$(command -v uname)"

# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

T=$(mktemp -d /tmp/rc-devceil-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
LOG="${T}/calls.log"
: > "$LOG"
FAKE_BIN=$(fake_runtime_bin "$LOG")
# A uname that answers FAKE_UNAME_S / FAKE_UNAME_M when set (the platform stub)
# and the real one otherwise.
# shellcheck disable=SC2016  # the shim expands these at call time
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -s) [[ -n "${FAKE_UNAME_S:-}" ]] && { echo "$FAKE_UNAME_S"; exit 0; } ;;\n  -m) [[ -n "${FAKE_UNAME_M:-}" ]] && { echo "$FAKE_UNAME_M"; exit 0; } ;;\nesac\nexec %q "$@"\n' "$REAL_UNAME" > "${FAKE_BIN}/uname"
chmod +x "${FAKE_BIN}/uname"
cleanup() {
  local _p _c
  for _p in /proc/[0-9]*; do
    _c=$({ tr '\0' ' ' < "${_p}/cmdline"; } 2>/dev/null) || continue
    [[ "$_c" == *host-tool-gatekeeper.py* && "$_c" == *"$T"* ]] && kill -KILL "${_p#/proc/}" 2>/dev/null
  done
  rm -rf "$T" "$FAKE_BIN"
}
trap cleanup EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
export PATH="${FAKE_BIN}:${PATH}"
unset RC_STATE_DIR RC_PYTHON3 RC_CAGE_CONF FAKE_MSB_INSPECT_FILE FAKE_UNAME_S FAKE_UNAME_M

mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" \
  "$T/ws/.git/hooks" "$T/ws/.git/info" "$T/bin" "$T/conf" "$T/cwd" "$T/m"
: > "$T/ws/.git/config"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tool";  chmod 0755 "$T/bin/tool"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PY" > "$T/bin/okpy";  chmod 0755 "$T/bin/okpy"
# 130 scratch directories to mount; extra shares come from here.
for _i in $(seq 1 130); do mkdir -p "$T/m/d${_i}"; done

# mk_conf FILE EXTRA [mixed] -- the minimal native config (3 mounts) plus EXTRA
# read-write bind mounts of $T/m/d1..dEXTRA; "mixed" adds one named volume and
# one tmpfs line (the volume is a share, the tmpfs is not). The project is $PROJ.
PROJ="$T/ws"
mk_conf() {
  local _i
  {
    printf 'image: rip-cage:latest\nworkdir: /workspace\nmounts:\n  - "%s:/workspace"\n' "$PROJ"
    printf "  - \"%s/.claude/projects:/home/agent/.claude/projects\"\n  - \"%s/.claude/sessions:/home/agent/.claude/sessions\"\n" "$HOME" "$HOME"
    for ((_i = 1; _i <= $2; _i++)); do printf '  - "%s/m/d%s:/m/d%s"\n' "$T" "$_i" "$_i"; done
    if [[ "${3:-}" == mixed ]]; then printf '  - named: "rc-devceil-vol"\n    target: /vol\n    create: ensure-exists\n  - tmpfs: /scratch\n'; fi
    printf 'network:\n  policy: none\n  strict: false\n  allow:\n    - "api.anthropic.com:tcp:443"\n'
  } > "$1"
}
mk_decl() {
  printf 'tools:\n  demo:\n    verbs:\n      go:\n        argv: ["%s/bin/tool"]\n        timeout: 30s\n' "$T" > "$1"
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
has_call() { grep -q "^msb $1" "$LOG"; }
STUB=(FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64)
# indep_count CONF -- the device count the TEST derives, never asking rc for a
# number: the config's bind-mount and named-volume lines (tmpfs lines cost
# none) plus the -v / --mount-file / --vsock tokens on the printed "Would run:"
# line of a platform-stubbed dry-run. Sets INDEP (the test's count) and RCPRINT
# (the number rc printed on that run).
indep_count() {
  local _conf_n _argv_n
  run_up "${STUB[@]}" -- up --dry-run --conf "$1" "$PROJ"
  _conf_n=$(grep -cE '^  - ("|named:)' "$1" || true)
  _argv_n=$(grep '^Would run: ' <<<"$OUT" | tr ' ' '\n' | grep -cxE -e '-v|--mount-file|--vsock' || true)
  INDEP=$((_conf_n + _argv_n))
  RCPRINT=$(printf '%s\n' "$OUT" | sed -n 's/.* has \([0-9][0-9]*\) devices.*/\1/p' | head -1)
}
# refused LABEL COUNT -- the last run exited non-zero and named count/ceiling/platform
refused() {
  local _label="$1" _count="$2" _ok=1
  [[ "$EX" -ne 0 ]] || { _ok=0; echo "  exit was 0"; }
  [[ "$OUT" == *"${_count} devices"* ]] || { _ok=0; echo "  missing '${_count} devices'"; }
  [[ "$OUT" == *"104"* && "$OUT" == *"Linux x86_64"* ]] || { _ok=0; echo "  missing ceiling or platform"; }
  if grep -Eq '^msb (create|stop|remove)' "$LOG"; then _ok=0; echo "  destructive msb call recorded: $(grep -E '^msb (create|stop|remove)' "$LOG" | head -1)"; fi
  if [[ "$_ok" == 1 ]]; then pass "$_label"; else fail "$_label"; echo "  output: ${OUT}"; fi
}
allowed() { # LABEL
  if [[ "$EX" -eq 0 && "$OUT" != *"devices, past"* && "$OUT" != *"ceiling of 104"* ]]; then pass "$1"; else fail "$1 (ex=${EX}): ${OUT}"; fi
}

C="$T/conf/a.yaml"
mk_conf "$C" 0
indep_count "$C"; BASE=$INDEP
if [[ "$BASE" =~ ^[0-9]+$ && "$BASE" -gt 3 && "$BASE" -lt 104 ]]; then pass "D0a baseline derived by the test from the config lines and argv tokens: ${BASE} devices"; else fail "D0a baseline count not derived (got '${BASE}'): ${OUT}"; BASE=10; fi
AT104=$((104 - BASE))   # extra shares that make exactly 104 devices, by the test's own count

# D0b: rc's printed number equals the test's own count, for a bind-only config,
# a mixed one (named volume + tmpfs) and one with a host-tool declaration (--vsock).
_d0=""
for _variant in plain mixed mixed+decl; do
  case "$_variant" in plain) mk_conf "$C" 7 ;; *) mk_conf "$C" 7 mixed ;; esac
  [[ "$_variant" == mixed+decl ]] && mk_decl "$T/conf/a.tools.yaml"
  indep_count "$C"; _mine=$INDEP; _rcs=$RCPRINT
  [[ -n "$_mine" && "$_mine" == "$_rcs" ]] || _d0+=" ${_variant}:test=${_mine},rc=${_rcs}"
  rm -f "$T/conf/a.tools.yaml"
done
if [[ -z "$_d0" ]]; then pass "D0b rc's printed device count equals the test's own count (plain, mixed volume+tmpfs, host-tool vsock)"; else fail "D0b counts differ:${_d0}"; fi

# ============================================================================
echo "=== D4: exactly 104 allowed, one more refused ==="
mk_conf "$C" "$AT104"
run_up -- up --dry-run --conf "$C" "$T/ws"
allowed "D4a 104 devices: dry-run allowed"
mk_conf "$C" $((AT104 + 1))
run_up -- up --dry-run --conf "$C" "$T/ws"
refused "D4b 105 devices: dry-run refused" 105

# ============================================================================
echo "=== D2: refusal in a real launch, --dry-run and --dry-run --output json ==="
run_up -- up --dry-run --conf "$C" "$T/ws"
refused "D2a dry-run refuses" 105
run_up -- up --conf "$C" "$T/ws"
refused "D2b real rc up refuses before any msb create" 105
run_up -- up --dry-run --output json --conf "$C" "$T/ws"
refused "D2c --dry-run --output json refuses" 105
if jq -e '.code == "DEVICE_CEILING_EXCEEDED"' <<<"$(grep '^{' <<<"$OUT" | head -1)" >/dev/null 2>&1; then pass "D2d JSON refusal carries code DEVICE_CEILING_EXCEEDED"; else fail "D2d JSON code: ${OUT}"; fi

# ============================================================================
echo "=== D3: config-file mounts alone over the ceiling ==="
mk_conf "$C" 110
run_up -- up --dry-run --conf "$C" "$T/ws"
if [[ "$EX" -ne 0 && "$OUT" =~ ([0-9]+)\ devices && "${BASH_REMATCH[1]}" -ge 113 ]]; then pass "D3 113+ devices from the config's own mounts: refused (${BASH_REMATCH[1]})"; else fail "D3 (ex=${EX}): ${OUT}"; fi

# ============================================================================
echo "=== D1: host-tool vsock endpoint is a device ==="
mk_conf "$C" "$AT104"
run_up -- up --dry-run --conf "$C" "$T/ws"
allowed "D1a 104 devices, no declaration: allowed"
mk_decl "$T/conf/a.tools.yaml"
run_up -- up --dry-run --conf "$C" "$T/ws"
refused "D1b same config with a host-tool declaration (105 devices): refused" 105
rm -f "$T/conf/a.tools.yaml"

# ============================================================================
echo "=== D6: platform not Linux x86_64 ==="
mk_conf "$C" $((AT104 + 1))
run_up "${STUB[@]}" -- up --dry-run --conf "$C" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *"105 devices"* && "$OUT" == *"ceiling unmeasured on Darwin arm64"* ]]; then pass "D6a Darwin arm64: proceeds, prints the count and 'ceiling unmeasured on Darwin arm64'"; else fail "D6a (ex=${EX}): ${OUT}"; fi
run_up FAKE_UNAME_S=Linux FAKE_UNAME_M=aarch64 -- up --conf "$C" "$T/ws"
if [[ "$EX" -eq 0 && "$OUT" == *"ceiling unmeasured on Linux aarch64"* ]] && has_call "create"; then pass "D6b Linux aarch64, real launch: creates, 'ceiling unmeasured on Linux aarch64'"; else fail "D6b (ex=${EX}): ${OUT}"; fi

# ============================================================================
echo "=== D5: attach and resume neither count nor refuse nor prepare mounts ==="
sha_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf '[{"reference":"rip-cage:latest","digest":"%s"}]\n' "$DIGEST" > "$T/images.json"
mk_inspect() { # STATUS -> $T/inspect.json
  jq -n --arg st "$1" --arg dg "$DIGEST" --arg path "$PROJ" --arg sha "$(sha_of "${ICONF:-$C}")" '
    {status: $st, config: {manifest_digest: $dg, labels: {"rc.source.path": $path, "rc.cage-conf-sha": $sha, "rc.session.multiplexer": "none", "rc.host-tools": "absent"}, mounts: []}}' > "$T/inspect.json"
}
tree_state() { find "$HOME" "$T/ws" -printf '%p %y %s %T@\n' 2>/dev/null | sort; }
mk_conf "$C" $((AT104 + 5))
export FAKE_MSB_INSPECT_FILE="$T/inspect.json" FAKE_MSB_IMAGE_LIST_FILE="$T/images.json"
for _mode in "" "--dry-run"; do
  for _st in Running Stopped; do
    mk_inspect "$_st"
    _before=$(tree_state)
    # shellcheck disable=SC2086  # _mode is one flag or empty
    run_up -- up $_mode --conf "$C" "$T/ws"
    _after=$(tree_state)
    _why=""
    [[ "$EX" -eq 0 ]] || _why+=" exit-${EX}"
    [[ "$OUT" != *" devices"* && "$OUT" != *"ceiling"* ]] || _why+=" counted-or-refused"
    has_call "create" && _why+=" msb-create"
    [[ "$_before" == "$_after" ]] || _why+=" host-tree-changed"
    if [[ -z "$_why" ]]; then pass "D5 ${_st} cage, over-ceiling config, ${_mode:-real}: no count, no refusal, nothing written"; else fail "D5 ${_st} ${_mode:-real}:${_why}: ${OUT}"; fi
  done
done
# A stopped cage whose config changed is a converge (a recreate): counted.
mk_inspect Stopped
jq '.config.labels["rc.cage-conf-sha"] = "stale"' "$T/inspect.json" > "$T/inspect.stale.json" && mv "$T/inspect.stale.json" "$T/inspect.json"
run_up -- up --dry-run --conf "$C" "$T/ws"
refused "D5c converge (stopped cage, changed config), --dry-run: refused" 109
run_up -- up --dry-run --output json --conf "$C" "$T/ws"
refused "D5d converge, --dry-run --output json: refused" 109
run_up -- up --conf "$C" "$T/ws"
refused "D5e converge, real: refused, no msb create" 109
# rc up --replace over a running or stopped cage: refused before any msb stop,
# remove or create (refused() fails on any of them in the call log).
for _st in Running Stopped; do
  mk_inspect "$_st"
  run_up -- up --replace --conf "$C" "$T/ws"
  refused "D5f --replace over a ${_st} cage, real: refused, cage untouched" 109
  run_up -- up --replace --output json --conf "$C" "$T/ws"
  refused "D5g --replace over a ${_st} cage, --output json: refused, cage untouched" 109
done
mk_inspect Stopped
jq '.config.labels["rc.cage-conf-sha"] = "stale"' "$T/inspect.json" > "$T/inspect.stale.json" && mv "$T/inspect.stale.json" "$T/inspect.json"
run_up -- up --output json --conf "$C" "$T/ws"
refused "D5h converge, real, --output json: refused, cage untouched" 109
unset FAKE_MSB_INSPECT_FILE FAKE_MSB_IMAGE_LIST_FILE
rm -f "$T/inspect.json" "$T/inspect.json.removed"

# ============================================================================
echo "=== D5w: a worktree cage's gitfile is left alone by attach and resume ==="
# The mount preparation rewrites ~/.cache/rc/<name>.gitfile for a linked
# worktree; on attach/resume that would rewrite a live cage's pointer.
WTMAIN="$T/wtmain"; WT="$T/wt"
mkdir -p "$WTMAIN" && git -C "$WTMAIN" init -q
git -C "$WTMAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WTMAIN" worktree add -q "$WT" -b wtb
WTNAME="$(basename "$T")-wt"
GITFILE="$HOME/.cache/rc/${WTNAME}.gitfile"
mkdir -p "$HOME/.cache/rc"
reset_gitfile() { printf 'sentinel\n' > "$GITFILE"; touch -d '2001-01-01 00:00:00' "$GITFILE"; }
WTC="$T/conf/wt.yaml"
PROJ="$WT"; mk_conf "$WTC" 0; ICONF="$WTC"
export FAKE_MSB_INSPECT_FILE="$T/inspect.json" FAKE_MSB_IMAGE_LIST_FILE="$T/images.json"
for _mode in "" "--dry-run"; do
  for _st in Running Stopped; do
    mk_inspect "$_st"; reset_gitfile
    # shellcheck disable=SC2086  # _mode is one flag or empty
    run_up -- up $_mode --conf "$WTC" "$WT"
    _why=""
    [[ "$EX" -eq 0 ]] || _why+=" exit-${EX}"
    [[ "$(cat "$GITFILE")" == sentinel && "$(stat -c %Y "$GITFILE")" == "$(date -d '2001-01-01 00:00:00' +%s)" ]] || _why+=" gitfile-rewritten"
    if [[ -z "$_why" ]]; then pass "D5w ${_st} worktree cage, ${_mode:-real}: gitfile byte-identical, mtime unchanged"; else fail "D5w ${_st} ${_mode:-real}:${_why}: ${OUT}"; fi
  done
done
# Control: a create DOES write the gitfile (so the fixture can fail the cases above).
rm -f "$T/inspect.json"; reset_gitfile
run_up -- up --dry-run --conf "$WTC" "$WT"
if [[ "$(cat "$GITFILE")" == gitdir:* ]]; then pass "D5w control: a create writes the gitfile (the fixture reaches the write)"; else fail "D5w control: gitfile untouched on create: ${OUT}"; fi
unset FAKE_MSB_INSPECT_FILE FAKE_MSB_IMAGE_LIST_FILE ICONF
PROJ="$T/ws"; rm -f "$T/inspect.json" "$T/inspect.json.removed"

# ============================================================================
echo "=== D8: the count includes the nested-repo hide lines (rip-cage-rsh9.17.3.1) ==="
# FOLDER is mounted rw; with plain subdirectories it adds no hides, and with
# two nested repos rc hides each (one device per hide).
FOLDER="$T/folder"
mkdir -p "${FOLDER}/docs" "${FOLDER}/r1" "${FOLDER}/r2"
H="$T/conf/h.yaml"
mk_conf "$H" 0
{ printf '  - "%s:/folder"\n' "$FOLDER"; } > "$T/conf/h.line"
# insert the folder mount after the workspace line
sed -i "/:\/workspace\"/r $T/conf/h.line" "$H"
indep_count "$H"; HBASE=$INDEP
# top up to exactly 104 devices, no repos yet
HX=$((104 - HBASE))
mk_conf "$H" "$HX"
sed -i "/:\/workspace\"/r $T/conf/h.line" "$H"
run_up -- up --dry-run --conf "$H" "$T/ws"
allowed "D8a folder of plain directories, 104 devices: allowed"
git -C "${FOLDER}/r1" init -q
git -C "${FOLDER}/r2" init -q
run_up -- up --dry-run --conf "$H" "$T/ws"
refused "D8b the same config with two nested repos (two hide lines): refused" 106

# ============================================================================
echo "=== D9: a JSON dry-run writes nothing the human dry-run does not ==="
mk_conf "$C" 0
mk_decl "$T/conf/a.tools.yaml"
rm -rf "$T/home0"; cp -a "$HOME" "$T/home0"
snap() { (cd "$1" && find . -printf '%p %y %s\n' | sort); }
HOME_SAVE="$HOME"
for _fmt in human json; do
  rm -rf "$T/home-$_fmt"; cp -a "$T/home0" "$T/home-$_fmt"
  export HOME="$T/home-$_fmt" XDG_CONFIG_HOME="$T/home-$_fmt/.config" XDG_STATE_HOME="$T/home-$_fmt/.local/state"
  if [[ "$_fmt" == json ]]; then
    run_up -- up --dry-run --output json --conf "$C" "$T/ws"
  else
    run_up -- up --dry-run --conf "$C" "$T/ws"
  fi
  [[ "$_fmt" == json ]] && JOUT="$OUT" && JEX=$EX
  [[ "$_fmt" == human ]] && HEX=$EX
  snap "$T/home-$_fmt" > "$T/snap-$_fmt"
done
export HOME="$HOME_SAVE" XDG_CONFIG_HOME="$HOME_SAVE/.config" XDG_STATE_HOME="$HOME_SAVE/.local/state"
if [[ "$HEX" -eq 0 && "$JEX" -eq 0 ]] && diff -q "$T/snap-human" "$T/snap-json" >/dev/null; then pass "D9a JSON dry-run leaves the same host tree as the human dry-run"; else fail "D9a (human ex=${HEX}, json ex=${JEX}): $(diff "$T/snap-human" "$T/snap-json" | head -5)"; fi
if jq -e . >/dev/null 2>&1 <<<"$(grep -v '^Would\|^Warning\|^Dropped' <<<"$JOUT" | grep '^{' | head -1)"; then pass "D9b JSON dry-run still emits its JSON object"; else fail "D9b no JSON object: ${JOUT}"; fi
rm -f "$T/conf/a.tools.yaml"

# ============================================================================
echo "=== D7: one definition site for the constant ==="
_n=$(grep -rnw '104' "${REPO_ROOT}/cli" | wc -l | tr -d ' ')
if [[ "$_n" == 1 ]]; then pass "D7 the number 104 appears once under cli/"; else fail "D7 104 appears ${_n} times under cli/: $(grep -rnw '104' "${REPO_ROOT}/cli")"; fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then echo "All tests passed."; else echo "${FAILURES} test(s) failed."; exit 1; fi
