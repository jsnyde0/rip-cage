#!/usr/bin/env bash
set -uo pipefail

# tests/test-host-tools-decl.sh -- host-tier proof for rip-cage-jdl2.1
# (ADR-032 D2/D3): the declaration loader in cli/lib/host_tools.sh.
#
#   V   the valid declaration loads and normalizes (typed defaults, 4096 max,
#       integer-second timeout, absolute argv[0] as declared)
#   R   one fixture per defect class is refused: exit 1, stdout empty, exactly
#       one "Error: " line on stderr naming the expected location/element
#   F   _host_tools_file / _host_tools_present resolve the sibling of a --conf
#   I   _host_tools_mounts_from_inspect lists a recorded cage's mount sources
#   H   hermeticity: nothing was written under the real HOME
#
# Fixtures: tests/fixtures/host-tools/<case>.{tools.yaml,mounts,expect}. The
# token @T@ is replaced with the scratch root's resolved path. .expect line 1
# is the exit code, line 2 a substring the Error line must contain ("-": none).
# Sources the libs directly; no docker, no msb.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
FIX="${SCRIPT_DIR}/fixtures/host-tools"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

REAL_HOME="${HOME:-}"
_real_before="$(find "${REAL_HOME}/.config/rip-cage" "${REAL_HOME}/.local/state/rip-cage" -ls 2>&1 | sort | cksum)"

T=$(mktemp -d /tmp/rc-hostdecl-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
unset RC_STATE_DIR
mkdir -p "$HOME"
# shellcheck source=cli/lib/protected_paths.sh
source "${REPO_ROOT}/cli/lib/protected_paths.sh"
# shellcheck source=cli/lib/host_tools.sh
source "${REPO_ROOT}/cli/lib/host_tools.sh"

# --- plant the scratch world ------------------------------------------------
mkdir -p "$T/ws/bin" "$T/bin" "$T/decl-in-ws" "$T/work"
printf 'print(1)\n' > "$T/ws/tool.py"
printf '#!/bin/sh\nexit 0\n' > "$T/ws/bin/x"
chmod 0755 "$T/ws/bin/x"
printf 'SECRET=1\n' > "$T/ws/.env"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tool"
chmod 0755 "$T/bin/tool"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/notexec"
chmod 0644 "$T/bin/notexec"
ln -s "$T/ws/tool.py" "$T/link-into-ws"
ln -s "$T/ws/missing" "$T/dangling"
ln -s "$T/nowhere/x" "$T/dangling-out"   # dangling, target outside every mount
ln -s "$T/bin/tool" "$T/link-out"        # live symlink outside every mount
ln -s "$T/loop2" "$T/loop1"
ln -s "$T/loop1" "$T/loop2"
# $T/missing-parent is deliberately NOT created.

_sub() { sed "s|@T@|${T}|g" "$1"; }

run_case() { # CASE
  local c="$1" decl mounts code want_code want_sub out err rc n
  decl="$T/work/${c}.tools.yaml"
  [[ "$c" == "decl-file-in-mount" ]] && decl="$T/ws/decl.tools.yaml"
  _sub "$FIX/${c}.tools.yaml" > "$decl"
  mounts="$T/work/${c}.mounts"
  _sub "$FIX/${c}.mounts" > "$mounts"
  want_code="$(sed -n 1p "$FIX/${c}.expect")"
  want_sub="$(sed -n 2p "$FIX/${c}.expect")"
  want_sub="${want_sub//@T@/$T}"
  out="$T/work/${c}.out"; err="$T/work/${c}.err"
  _host_tools_load "$decl" "$mounts" > "$out" 2> "$err"
  code=$?
  if [[ "$code" != "$want_code" ]]; then
    fail "${c}: exit ${code}, want ${want_code} (stderr: $(cat "$err"))"; return
  fi
  if [[ "$want_code" == "0" ]]; then
    if [[ -s "$err" ]]; then fail "${c}: stderr not empty: $(cat "$err")"; return; fi
    if [[ ! -s "$out" ]]; then fail "${c}: no normalized JSON on stdout"; return; fi
    pass "${c}: loads"
    return
  fi
  if [[ -s "$out" ]]; then fail "${c}: stdout not empty on refusal"; return; fi
  n="$(wc -l < "$err" | tr -d ' ')"
  if [[ "$n" != "1" ]]; then fail "${c}: stderr is ${n} lines, want exactly 1: $(cat "$err")"; return; fi
  rc="$(cat "$err")"
  case "$rc" in
    "Error: "*) ;;
    *) fail "${c}: stderr does not start with 'Error: ': ${rc}"; return ;;
  esac
  if [[ "$want_sub" != "-" && "$rc" != *"$want_sub"* ]]; then
    fail "${c}: Error line lacks '${want_sub}': ${rc}"; return
  fi
  pass "${c}: refused (${rc#Error: host-tool declaration })"
}

echo "--- fixture matrix ---"
for f in "$FIX"/*.expect; do
  c="$(basename "$f" .expect)"
  run_case "$c"
done

echo "--- V: normalized shape of the valid case ---"
J="$(cat "$T/work/valid.out")"
jq_ok() { # LABEL FILTER -- passes when the filter yields true
  if [[ "$(jq -r "$2" <<<"$J" 2>&1)" == "true" ]]; then pass "$1"; else fail "$1 ($2)"; fi
}
jq_ok "v is 1" '.v == 1'
jq_ok "argv[0] absolute, as declared" ".tools.demo.verbs.send.argv[0] == \"${T}/bin/tool\""
jq_ok "timeout 30s is the integer 30" '.tools.demo.verbs.send.timeout | (type == "number" and . == 30)'
jq_ok "timeout 2m is the integer 120" '.tools.demo.verbs.all.timeout == 120'
jq_ok "returns_secret carried (false, true)" '(.tools.demo.verbs.send.returns_secret == false) and (.tools.demo.verbs.all.returns_secret == true)'
jq_ok "string slot without max gets 4096" '.tools.demo.verbs.send.slots.chat.max == 4096'
jq_ok "string slot allow_dash declared true" '.tools.demo.verbs.send.slots.chat.allow_dash == true'
jq_ok "string slot allow_slash defaults false" '.tools.demo.verbs.send.slots.chat.allow_slash == false'
jq_ok "regex carried verbatim" '.tools.demo.verbs.send.slots.chat.regex == "^-?[1-9][0-9]*$"'
jq_ok "int slot default is a number 20" '.tools.demo.verbs.send.slots.limit | (.type == "int" and (.default|type) == "number" and .default == 20 and .min == 1 and .max == 100)'
jq_ok "int slot without regex/default keys absent where undeclared" '(.tools.demo.verbs.all.slots.n | has("min") or has("max")) | not'
jq_ok "enum slot values and default" '.tools.demo.verbs.all.slots.mode | (.type == "enum" and .values == ["a","b"] and .default == "b")'
jq_ok "string default is a string, max 10 declared" '.tools.demo.verbs.all.slots.name | (.max == 10 and (.default|type) == "string" and .default == "hi")'
jq_ok "string slot without regex has no regex key" '.tools.demo.verbs.all.slots.name | has("regex") | not'
jq_ok "int default 5 carried with its type" '.tools.demo.verbs.all.slots.n | ((.default|type) == "number" and .default == 5)'
jq_ok "placeholders stay in argv" '.tools.demo.verbs.send.argv == ["'"${T}"'/bin/tool","sub","--chat","{chat}","--limit","{limit}"]'
if [[ "$(wc -l < "$T/work/valid.out" | tr -d ' ')" == "1" ]]; then pass "normalized JSON is compact (one line)"; else fail "normalized JSON is not one line"; fi

echo "--- no file: exit 0, no output ---"
out="$(_host_tools_load "$T/work/does-not-exist.tools.yaml" "$T/work/valid.mounts" 2>"$T/work/nofile.err")"; code=$?
if [[ "$code" == "0" && -z "$out" && ! -s "$T/work/nofile.err" ]]; then pass "no-file: exit 0, empty stdout, empty stderr"; else fail "no-file: code=$code out='$out' err='$(cat "$T/work/nofile.err")'"; fi

echo "--- no side effects ---"
if [[ ! -e "$T/home/.local" && ! -e "$T/home/.config" ]]; then pass "loader created nothing under HOME/XDG"; else fail "loader created state"; fi

echo "--- F: _host_tools_file / _host_tools_present ---"
mkdir -p "$T/elsewhere" "$T/real-conf-dir"
ln -s "$T/real-conf-dir" "$T/linked-conf-dir"
printf 'x: 1\n' > "$T/elsewhere/proj.yaml"
got="$(_host_tools_file demo "$T/elsewhere/proj.yaml")"
if [[ "$got" == "$T/elsewhere/proj.tools.yaml" ]]; then pass "--conf sibling: $got"; else fail "--conf sibling: $got"; fi
got="$(_host_tools_present demo "$T/elsewhere/proj.yaml")"
if [[ "$got" == "absent" ]]; then pass "present/absent: absent when no sibling"; else fail "expected absent, got $got"; fi
printf 'tools: {}\n' > "$T/elsewhere/proj.tools.yaml"
got="$(_host_tools_present demo "$T/elsewhere/proj.yaml")"
if [[ "$got" == "present" ]]; then pass "present/absent: present with sibling"; else fail "expected present, got $got"; fi
got="$(_host_tools_file demo "$T/elsewhere/proj.yml")"
if [[ "$got" == "$T/elsewhere/proj.tools.yaml" ]]; then pass ".yml extension stripped"; else fail ".yml stem: $got"; fi
printf 'x: 1\n' > "$T/real-conf-dir/c.yaml"
got="$(_host_tools_file demo "$T/linked-conf-dir/c.yaml")"
if [[ "$got" == "$T/real-conf-dir/c.tools.yaml" ]]; then pass "symlinked conf dir resolves to its real dir"; else fail "symlinked conf dir: $got"; fi
# the conf FILE itself a symlink: sibling lands beside its real path (ADR-032 D2)
mkdir -p "$T/c/real"
printf 'x: 1\n' > "$T/c/real/c.yaml"
ln -s "$T/c/real/c.yaml" "$T/c/link.yaml"
got="$(_host_tools_file demo "$T/c/link.yaml")"
if [[ "$got" == "$T/c/real/c.tools.yaml" ]]; then pass "symlinked conf file resolves to its real path's sibling"; else fail "symlinked conf file: $got"; fi
got="$(_host_tools_file demo "$T/no-such-dir/p.yaml")"
if [[ "$got" == "$T/no-such-dir/p.tools.yaml" ]]; then pass "nonexistent conf dir still yields an absolute path"; else fail "nonexistent conf dir: $got"; fi
got="$(cd "$T" && _host_tools_file demo "no-such-rel/p.yaml")"
case "$got" in /*) pass "relative conf in a nonexistent dir is absolute: $got" ;; *) fail "relative result: $got" ;; esac

echo "--- walker: dangling prints its best lexical resolution; loops and fan-out are bounded ---"
got="$(_protected_paths_walk_path "$T/dangling-out/sub")"; code=$?
if [[ "$code" == "2" && "$got" == "$T/nowhere/x/sub" ]]; then pass "dangling: exit 2, prints target plus suffix ($got)"; else fail "dangling walk: code=$code got=$got"; fi
got="$(_protected_paths_walk_path "$T/loop1")"; code=$?
if [[ "$code" == "2" ]]; then pass "loop1 -> loop2 -> loop1: exit 2"; else fail "loop walk: code=$code got=$got"; fi
_mkfan() { # DIR N -- l_k -> l_{k+1}/../l_{k+1}; l_N -> DIR/real (so the .. lands back in DIR)
  local _d="$1" _n="$2" _k=1
  mkdir -p "$_d/real"
  while [[ "$_k" -lt "$_n" ]]; do
    ln -s "l$((_k + 1))/../l$((_k + 1))" "$_d/l$_k"
    _k=$((_k + 1))
  done
  ln -s "$_d/real" "$_d/l$_n"
}
_mkfan "$T/fan3" 3
got="$(_protected_paths_walk_path "$T/fan3/l1")"; code=$?
if [[ "$code" == "0" && "$got" == "$T/fan3/real" ]]; then pass "fan-out control N=3 resolves (exit 0, $got)"; else fail "fan-out control: code=$code got=$got"; fi
_mkfan "$T/fan" 12
_t0=$SECONDS
got="$(_protected_paths_walk_path "$T/fan/l1")"; code=$?
_dt=$((SECONDS - _t0))
if [[ "$code" == "2" && "$_dt" -le 1 ]]; then pass "fan-out l_k -> l_{k+1}/../l_{k+1} (N=12): exit 2 within ~1s (SECONDS granularity)"; else fail "fan-out: code=$code dt=${_dt}s"; fi

echo "--- I: _host_tools_mounts_from_inspect ---"
_msb_inspect_json() {
  if [[ "$1" == "gone" ]]; then return 1; fi
  printf '%s\n' '{"name":"x","config":{"mounts":[{"host":"/a/b","guest":"/workspace"},{"host":"/c d/e","guest":"/g"},{"guest":"/tmpfs-only"}]}}'
}
got="$(_host_tools_mounts_from_inspect demo)"
if [[ "$got" == "/a/b
/c d/e" ]]; then pass "recorded mount sources, one per line"; else fail "mounts: $got"; fi
got="$(_host_tools_mounts_from_inspect gone)"; code=$?
if [[ "$code" != "0" && -z "$got" ]]; then pass "absent cage: non-zero, no output"; else fail "absent cage: code=$code out=$got"; fi

echo "--- H: hermeticity ---"
_real_after="$(find "${REAL_HOME}/.config/rip-cage" "${REAL_HOME}/.local/state/rip-cage" -ls 2>&1 | sort | cksum)"
if [[ "$_real_before" == "$_real_after" ]]; then pass "real HOME rip-cage dirs unchanged (names, sizes, mtimes)"; else fail "real HOME rip-cage dirs changed"; fi

echo ""
echo "failures: $FAILURES"
exit $((FAILURES > 0))
