#!/usr/bin/env bash
set -uo pipefail

# tests/test-hidden-repo-converge.sh -- host-tier proof for rip-cage-rsh9.17.3.3
# (ADR-002 D11, "A changed hidden set is a changed config"): rc up recreates a
# stopped cage when the set of hidden repos changed, prints what it hid, reports
# the created-with guest paths on attach/resume, and carries hidden_repos in
# every dry-run JSON object. Runs the REAL rc behind the fake runtime
# (tests/_fake-runtime-lib.sh): no cage, no docker daemon, no msb.
#
# Fixture: a folder mounted read-write at /tree holding the nested repo pkg.
#
#   W1  --dry-run on a create: exactly one "Would hide" line naming pkg and /tree/pkg
#   W2  the folder mounted at two targets: two lines
#   W3  a repo in the skip set (under a protected-name tmpfs): no line, no entry
#   J1  --dry-run --output json: hidden_repos {host, guest} on would_create
#   J2  ... on the image-absent objects, with and without RIP_CAGE_IMAGE_REGISTRY
#   J3  ... on would_attach, would_resume and would_converge: the CURRENT scan
#   J4  nothing hidden: an empty array, on every one of those
#   S1  a create stamps the hidden-set label (argv of the dry-run and of msb create)
#   P1  a real create prints one line per (hidden repo, guest path)
#   C1-C7 converge matrix on a stopped cage: label differs, missing + non-empty,
#       missing + empty, equal; --no-reload refused on a change and on missing +
#       non-empty, allowed when equal
#   R1  resume (stopped, label equal) reports the created-with guest paths, no host path
#   R2  attach (running, scan changed) reports the TWO created-with paths and says
#       rc up --replace applies the change; no note when the scan is unchanged
#   R3  attach and resume run no mount preparation and no device count

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
REAL_PY="$(command -v python3 || true)"
[[ -n "$REAL_PY" ]] || { echo "SKIP: python3 not on PATH"; exit 0; }
REAL_PY="$(readlink -f "$REAL_PY")"

# shellcheck source=tests/_fake-runtime-lib.sh
source "${SCRIPT_DIR}/_fake-runtime-lib.sh"

T=$(mktemp -d /tmp/rc-hidconv-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
LOG="${T}/calls.log"
: > "$LOG"
FAKE_BIN=$(fake_runtime_bin "$LOG")
trap 'rm -rf "$T" "$FAKE_BIN"' EXIT

export HOME="${T}/home"
export XDG_CONFIG_HOME="${T}/home/.config"
export XDG_STATE_HOME="${T}/home/.local/state"
export PATH="${FAKE_BIN}:${PATH}"
unset RC_STATE_DIR RC_PYTHON3 RC_CAGE_CONF FAKE_MSB_INSPECT_FILE FAKE_MSB_IMAGE_LIST_FILE RIP_CAGE_IMAGE_REGISTRY RC_PROTECTED_SCAN_DEPTH

PROJ="${T}/ws"
TREE="${T}/tree"; PLAIN="${T}/plain"; SKIPT="${T}/skiptree"
mkdir -p "$HOME/.claude/projects" "$HOME/.claude/sessions" "${PROJ}/.git/hooks" "${PROJ}/.git/info" \
  "${T}/conf" "${T}/cwd" "${T}/bin" "${TREE}/pkg" "${PLAIN}/docs" "${SKIPT}/.aws/rep"
: > "${PROJ}/.git/config"
git -C "${TREE}/pkg" init -q
git -C "${SKIPT}/.aws/rep" init -q
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PY" > "${T}/bin/okpy"; chmod 0755 "${T}/bin/okpy"
HIDE_DIR="${HOME}/.cache/rc/hidden-repo"

# mk_conf FILE MOUNT... -- the minimal native config plus the given "host:guest" rw mounts
mk_conf() {
  local _f="$1" _m; shift
  {
    printf 'image: rip-cage:latest\nworkdir: /workspace\nmounts:\n  - "%s:/workspace"\n' "$PROJ"
    printf '  - "%s/.claude/projects:/home/agent/.claude/projects"\n  - "%s/.claude/sessions:/home/agent/.claude/sessions"\n' "$HOME" "$HOME"
    for _m in "$@"; do printf '  - "%s"\n' "$_m"; done
    printf 'network:\n  policy: none\n  strict: false\n  allow:\n    - "api.anthropic.com:tcp:443"\n'
  } > "$_f"
}

OUT=''; EX=0
run_up() { # [VAR=val ...] -- ARGS...  -> OUT (stdout+stderr), EX; the call log holds this run only
  local -a _envs=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done
  shift
  : > "$LOG"
  rm -f "${T}/inspect.json.removed"
  OUT=$(cd "${T}/cwd" && env RC_PYTHON3="${T}/bin/okpy" ${_envs[@]+"${_envs[@]}"} "$RC" "$@" 2>&1 < /dev/null)
  EX=$?
}
run_json() { # as run_up, but stdout only (the JSON object) -> JOUT
  local -a _envs=()
  while [[ "$1" != -- ]]; do _envs+=("$1"); shift; done
  shift
  : > "$LOG"
  rm -f "${T}/inspect.json.removed"
  JOUT=$(cd "${T}/cwd" && env RC_PYTHON3="${T}/bin/okpy" ${_envs[@]+"${_envs[@]}"} "$RC" "$@" 2>/dev/null < /dev/null)
  EX=$?
}
has_call() { grep -q "^msb $1" "$LOG"; }
would_hide_count() { grep -c '^Would hide ' <<<"$OUT" || true; }

C="${T}/conf/a.yaml"        # /tree holds pkg: one hidden repo
CNONE="${T}/conf/none.yaml" # nothing to hide
C2="${T}/conf/two.yaml"     # the same folder at two targets
CSKIP="${T}/conf/skip.yaml" # the only repo is in the skip set
mk_conf "$C" "${TREE}:/tree"
mk_conf "$CNONE" "${PLAIN}:/plain"
mk_conf "$C2" "${TREE}:/tree" "${TREE}:/tree-b"
mk_conf "$CSKIP" "${SKIPT}:/skiptree"

# ============================================================================
echo "=== W: the Would hide lines of a dry-run create ==="
run_up -- up --dry-run --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 && "$(would_hide_count)" -eq 1 ]] \
    && grep '^Would hide ' <<<"$OUT" | grep -qF "${TREE}/pkg" \
    && grep '^Would hide ' <<<"$OUT" | grep -qF "/tree/pkg" \
    && grep '^Would hide ' <<<"$OUT" | grep -qF "cage-config skill"; then
  pass "W1 one 'Would hide' line, naming ${TREE}/pkg and /tree/pkg"
else
  fail "W1 (ex=${EX}, lines=$(would_hide_count)): $(grep '^Would hide' <<<"$OUT")"
fi
run_up -- up --dry-run --conf "$C2" "$PROJ"
if [[ "$EX" -eq 0 && "$(would_hide_count)" -eq 2 ]] \
    && grep -q '^Would hide .*/tree/pkg' <<<"$OUT" && grep -q '^Would hide .*/tree-b/pkg' <<<"$OUT"; then
  pass "W2 the folder mounted at two targets: two 'Would hide' lines"
else
  fail "W2 (ex=${EX}, lines=$(would_hide_count)): $(grep '^Would hide' <<<"$OUT")"
fi
run_up -- up --dry-run --conf "$CSKIP" "$PROJ"
run_json -- up --dry-run --output json --conf "$CSKIP" "$PROJ"
if [[ "$EX" -eq 0 && "$(would_hide_count)" -eq 0 ]] && [[ "$(jq -c '.hidden_repos' <<<"$JOUT" 2>/dev/null)" == "[]" ]]; then
  pass "W3 a repo in the skip set: no 'Would hide' line, no hidden_repos entry"
else
  fail "W3 (ex=${EX}): $(grep '^Would hide' <<<"$OUT") / json: ${JOUT}"
fi

# ============================================================================
echo "=== J: hidden_repos in every dry-run JSON object ==="
VERSION_FILE="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)"
# image_present: a docker that reports the image current, an msb that lists it
# shellcheck disable=SC2016  # the shim expands these at call time
make_image_present() {
  printf '#!/usr/bin/env bash\necho "docker $*" >> %q\n[[ "${1:-}" == image && "${2:-}" == inspect && "$*" == *--format* ]] && echo %q\nexit 0\n' "$LOG" "$VERSION_FILE" > "${FAKE_BIN}/docker.present"
  chmod +x "${FAKE_BIN}/docker.present"
  mv "${FAKE_BIN}/docker" "${FAKE_BIN}/docker.absent"; cp "${FAKE_BIN}/docker.present" "${FAKE_BIN}/docker"
}
sha_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf '[{"reference":"rip-cage:latest","digest":"%s"}]\n' "$DIGEST" > "${T}/images.json"

# entries_ok JSON HOST GUEST -- hidden_repos is exactly [{host,guest}] for one repo
entries_ok() { jq -e --arg h "$2" --arg g "$3" '.hidden_repos == [{host: $h, guest: $g}]' <<<"$1" >/dev/null 2>&1; }

# J2 first: the image-absent objects (the fake docker reports no image)
run_json RIP_CAGE_IMAGE_REGISTRY= -- up --dry-run --output json --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && jq -e '.action == "would_build_and_create"' <<<"$JOUT" >/dev/null 2>&1 && entries_ok "$JOUT" "${TREE}/pkg" "/tree/pkg"; then
  pass "J2a image absent, no registry: would_build_and_create carries hidden_repos [{host, guest}]"
else
  fail "J2a (ex=${EX}): ${JOUT}"
fi
run_json RIP_CAGE_IMAGE_REGISTRY=example.invalid/rip-cage -- up --dry-run --output json --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && jq -e '.action == "would_pull_and_create"' <<<"$JOUT" >/dev/null 2>&1 && entries_ok "$JOUT" "${TREE}/pkg" "/tree/pkg"; then
  pass "J2b image absent, registry set: would_pull_and_create carries hidden_repos [{host, guest}]"
else
  fail "J2b (ex=${EX}): ${JOUT}"
fi
run_json RIP_CAGE_IMAGE_REGISTRY= -- up --dry-run --output json --conf "$CNONE" "$PROJ"
_a="$(jq -c '.hidden_repos' <<<"$JOUT" 2>/dev/null)"
run_json RIP_CAGE_IMAGE_REGISTRY=example.invalid/rip-cage -- up --dry-run --output json --conf "$CNONE" "$PROJ"
_b="$(jq -c '.hidden_repos' <<<"$JOUT" 2>/dev/null)"
if [[ "$_a" == "[]" && "$_b" == "[]" ]]; then
  pass "J4a nothing hidden: an empty array on both image-absent objects"
else
  fail "J4a build: '${_a}', pull: '${_b}'"
fi

# J1: image present -> would_create through _up_json_output
make_image_present
export FAKE_MSB_IMAGE_LIST_FILE="${T}/images.json"
run_json -- up --dry-run --output json --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && jq -e '.action == "would_create"' <<<"$JOUT" >/dev/null 2>&1 && entries_ok "$JOUT" "${TREE}/pkg" "/tree/pkg"; then
  pass "J1 would_create carries hidden_repos [{host, guest}]"
else
  fail "J1 (ex=${EX}): ${JOUT}"
fi
run_json -- up --dry-run --output json --conf "$CNONE" "$PROJ"
if jq -e '.action == "would_create" and .hidden_repos == []' <<<"$JOUT" >/dev/null 2>&1; then pass "J4b would_create with nothing hidden: hidden_repos is []"; else fail "J4b: ${JOUT}"; fi

# S1: a create stamps the label -- read off the dry-run argv, then off msb create
run_up -- up --dry-run --conf "$C" "$PROJ"
LABEL_ARGV=$(grep '^Would run: ' <<<"$OUT" | tr ' ' '\n' | grep '^rc\.hidden-repos-sha=' | head -1)
SHA="${LABEL_ARGV#rc.hidden-repos-sha=}"
if [[ "$SHA" =~ ^[0-9a-f]{64}$ ]]; then pass "S1a the dry-run create argv carries rc.hidden-repos-sha=<sha256>"; else fail "S1a no hidden-set label on the Would run argv: $(grep '^Would run' <<<"$OUT" | cut -c1-200)"; fi
run_up -- up --conf "$C" "$PROJ"
if grep '^msb create' "$LOG" | tr ' ' '\n' | grep -qxF "rc.hidden-repos-sha=${SHA}"; then
  pass "S1b the real msb create carries the same label"
else
  fail "S1b label missing on msb create: $(grep '^msb create' "$LOG" | cut -c1-200)"
fi
run_up -- up --dry-run --conf "$C2" "$PROJ"
SHA2=$(grep '^Would run: ' <<<"$OUT" | tr ' ' '\n' | grep '^rc\.hidden-repos-sha=' | head -1)
run_up -- up --dry-run --conf "$CNONE" "$PROJ"
SHA0=$(grep '^Would run: ' <<<"$OUT" | tr ' ' '\n' | grep '^rc\.hidden-repos-sha=' | head -1)
if [[ -n "$SHA2" && -n "$SHA0" && "$SHA2" != "rc.hidden-repos-sha=${SHA}" && "$SHA0" != "rc.hidden-repos-sha=${SHA}" && "$SHA0" != "$SHA2" ]]; then
  pass "S1c the hash differs between one hidden repo, two guest paths, and none"
else
  fail "S1c hashes: one=${SHA} two=${SHA2} none=${SHA0}"
fi
SHA0=${SHA0#rc.hidden-repos-sha=}

# P1: a real create prints one line per (hidden repo, guest path)
run_up -- up --conf "$C2" "$PROJ"
_n=$(grep -cE "^Hid(ing|e) " <<<"$OUT" || true)
if [[ "$EX" -eq 0 && "$_n" -eq 2 ]] \
    && grep -E '^Hiding ' <<<"$OUT" | grep -qF "${TREE}/pkg at /tree/pkg" \
    && grep -E '^Hiding ' <<<"$OUT" | grep -qF "${TREE}/pkg at /tree-b/pkg" \
    && grep -E '^Hiding ' <<<"$OUT" | grep -qF "clone it onto your volume (cage-config skill)"; then
  pass "P1 a real create prints one 'Hiding' line per (repo, guest path): $(grep -E '^Hiding ' <<<"$OUT" | head -1)"
else
  fail "P1 (ex=${EX}, lines=${_n}): $(grep -E 'Hid' <<<"$OUT")"
fi
run_up -- up --conf "$CNONE" "$PROJ"
if [[ "$EX" -eq 0 ]] && ! grep -qE '^Hiding |Would hide' <<<"$OUT"; then pass "P1b nothing hidden: nothing printed"; else fail "P1b: $(grep -E 'Hid' <<<"$OUT")"; fi

# ============================================================================
echo "=== cage fixtures: a stopped / running cage created with a hidden-set label ==="
# mk_inspect STATUS CONF LABEL GUEST... -- label "" omits it; each GUEST is a
# hide mount (host = the README dir) in config.mounts[]
mk_inspect() {
  local _st="$1" _conf="$2" _lbl="$3"; shift 3
  local _mounts
  _mounts=$(jq -n '[$ARGS.positional[] | {host: $h, guest: ., readonly: true}]' --arg h "$HIDE_DIR" --args "$@")
  jq -n --arg st "$_st" --arg dg "$DIGEST" --arg path "$PROJ" --arg sha "$(sha_of "$_conf")" --arg lbl "$_lbl" --argjson mounts "$_mounts" '
    {status: $st, config: {manifest_digest: $dg,
      labels: ({"rc.source.path": $path, "rc.cage-conf-sha": $sha, "rc.session.multiplexer": "none", "rc.host-tools": "absent"}
               + (if $lbl == "" then {} else {"rc.hidden-repos-sha": $lbl} end)),
      mounts: ($mounts + [{host: "/somewhere/else", guest: "/elsewhere"}])}}' > "${T}/inspect.json"
}
export FAKE_MSB_INSPECT_FILE="${T}/inspect.json"
converged() { has_call "create" && has_call "remove"; }

echo "=== C: the converge matrix on a stopped cage ==="
mk_inspect Stopped "$C" "stale-hash" /tree/pkg
run_up -- up --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && converged && grep -qiE 'hidden repos? (changed|differ)' <<<"$OUT"; then
  pass "C1 label differs: recreated, reason printed ($(grep -iE 'hidden repo' <<<"$OUT" | head -1 | cut -c1-160))"
else
  fail "C1 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"
fi
mk_inspect Stopped "$C" "" /tree/pkg
run_up -- up --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && converged && grep -qiE 'hidden repos?.*(no record|missing|not recorded|predates)' <<<"$OUT"; then
  pass "C2 label missing, set non-empty: recreated, reason printed ($(grep -iE 'hidden repo' <<<"$OUT" | head -1 | cut -c1-160))"
else
  fail "C2 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"
fi
mk_inspect Stopped "$CNONE" ""
run_up -- up --conf "$CNONE" "$PROJ"
if [[ "$EX" -eq 0 ]] && ! has_call "create" && ! has_call "remove" && has_call "start"; then
  pass "C3 label missing, set empty: resumed, no recreate"
else
  fail "C3 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400); calls: $(tr '\n' '|' < "$LOG" | cut -c1-300)"
fi
mk_inspect Stopped "$C" "$SHA" /tree/pkg
run_up -- up --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && ! has_call "create" && ! has_call "remove" && has_call "start"; then
  pass "C4 label equal: resumed, no recreate"
else
  fail "C4 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"
fi
mk_inspect Stopped "$CNONE" "$SHA0"
run_up -- up --conf "$CNONE" "$PROJ"
if [[ "$EX" -eq 0 ]] && ! has_call "create" && ! has_call "remove"; then
  pass "C4b label equal on an empty set: resumed, no recreate"
else
  fail "C4b (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"
fi
mk_inspect Stopped "$C" "stale-hash" /tree/pkg
run_up -- up --no-reload --conf "$C" "$PROJ"
if [[ "$EX" -ne 0 ]] && grep -q -- '--no-reload' <<<"$OUT" && grep -qi 'hidden' <<<"$OUT" && ! has_call "create" && ! has_call "remove" && ! has_call "start"; then
  pass "C5 --no-reload with a changed set: refused, cage untouched"
else
  fail "C5 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"
fi
mk_inspect Stopped "$C" "" /tree/pkg
run_up -- up --no-reload --conf "$C" "$PROJ"
if [[ "$EX" -ne 0 ]] && grep -q -- '--no-reload' <<<"$OUT" && grep -qi 'hidden' <<<"$OUT" && ! has_call "create" && ! has_call "remove" && ! has_call "start"; then
  pass "C6 --no-reload with no label and a non-empty set: refused, cage untouched"
else
  fail "C6 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"
fi
mk_inspect Stopped "$C" "$SHA" /tree/pkg
run_up -- up --no-reload --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && has_call "start"; then pass "C7 --no-reload with an equal label: resumes"; else fail "C7 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"; fi
mk_inspect Stopped "$CNONE" ""
run_up -- up --no-reload --conf "$CNONE" "$PROJ"
if [[ "$EX" -eq 0 ]] && has_call "start"; then pass "C7b --no-reload with no label and an empty set: resumes"; else fail "C7b (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-400)"; fi
mk_inspect Stopped "$C" "stale-hash" /tree/pkg
run_json -- up --dry-run --output json --no-reload --conf "$C" "$PROJ"
if [[ "$EX" -ne 0 ]] && jq -e '.code == "HIDDEN_REPOS_NO_RELOAD"' <<<"$(grep '^{' <<<"$JOUT" | head -1)" >/dev/null 2>&1; then
  pass "C5b --no-reload refusal in --dry-run --output json carries code HIDDEN_REPOS_NO_RELOAD"
else
  fail "C5b (ex=${EX}): ${JOUT}"
fi

# ============================================================================
echo "=== J3: hidden_repos on would_attach / would_resume / would_converge holds the current scan ==="
mk_inspect Running "$C" "$SHA" /tree/pkg
run_json -- up --dry-run --output json --conf "$C" "$PROJ"
if jq -e '.action == "would_attach"' <<<"$JOUT" >/dev/null 2>&1 && entries_ok "$JOUT" "${TREE}/pkg" "/tree/pkg"; then pass "J3a would_attach carries the current scan"; else fail "J3a: ${JOUT}"; fi
mk_inspect Stopped "$C" "$SHA" /tree/pkg
run_json -- up --dry-run --output json --conf "$C" "$PROJ"
if jq -e '.action == "would_resume"' <<<"$JOUT" >/dev/null 2>&1 && entries_ok "$JOUT" "${TREE}/pkg" "/tree/pkg"; then pass "J3b would_resume carries the current scan"; else fail "J3b: ${JOUT}"; fi
mk_inspect Stopped "$C" "stale-hash" /tree/pkg
run_json -- up --dry-run --output json --conf "$C" "$PROJ"
if jq -e '.action == "would_converge"' <<<"$JOUT" >/dev/null 2>&1 && entries_ok "$JOUT" "${TREE}/pkg" "/tree/pkg"; then pass "J3c would_converge carries the current scan"; else fail "J3c: ${JOUT}"; fi
# the cage was created with TWO hidden paths, the scan now holds one: the key is the scan
mk_inspect Running "$C" "$SHA" /tree/pkg /tree/gone
run_json -- up --dry-run --output json --conf "$C" "$PROJ"
if jq -e '.action == "would_attach" and (.hidden_repos | length) == 1' <<<"$JOUT" >/dev/null 2>&1; then pass "J3d would_attach holds the current scan, not the created-with paths"; else fail "J3d: ${JOUT}"; fi
mk_inspect Running "$CNONE" ""
run_json -- up --dry-run --output json --conf "$CNONE" "$PROJ"
_a="$(jq -c '[.action, .hidden_repos]' <<<"$JOUT" 2>/dev/null)"
mk_inspect Stopped "$CNONE" ""
run_json -- up --dry-run --output json --conf "$CNONE" "$PROJ"
_b="$(jq -c '[.action, .hidden_repos]' <<<"$JOUT" 2>/dev/null)"
if [[ "$_a" == '["would_attach",[]]' && "$_b" == '["would_resume",[]]' ]]; then pass "J4c nothing hidden: [] on would_attach and would_resume"; else fail "J4c attach ${_a}, resume ${_b}"; fi

# ============================================================================
echo "=== R: the resume / attach report ==="
# R1: stopped, label equal -> plain resume, report names the created-with guest paths only
SHA2V="${SHA2#rc.hidden-repos-sha=}"
mk_inspect Stopped "$C2" "$SHA2V" /tree/pkg /tree-b/pkg
run_up -- up --conf "$C2" "$PROJ"
_line=$(grep -F 'created with' <<<"$OUT" | head -1)
if [[ "$EX" -eq 0 ]] && has_call "start" && ! has_call "create" \
    && [[ "$_line" == *"/tree/pkg"* && "$_line" == *"/tree-b/pkg"* && "$_line" != *"${TREE}"* && "$_line" != *"${HIDE_DIR}"* ]] \
    && ! grep -q 'rc up --replace applies' <<<"$OUT"; then
  pass "R1 resume reports the created-with guest paths, no host path, no change note: ${_line}"
else
  fail "R1 (ex=${EX}): line='${_line}' $(tr '\n' '|' <<<"$OUT" | cut -c1-300)"
fi
# R2: the cage was created with exactly /tree/pkg and /tree-b/pkg; a third repo
# has since appeared, so the current scan holds more paths than the cage was created with
mkdir -p "${TREE}/pkg3"; git -C "${TREE}/pkg3" init -q
mk_inspect Running "$C2" "$SHA2V" /tree/pkg /tree-b/pkg
run_up -- up --conf "$C2" "$PROJ"
_line=$(grep -F 'created with' <<<"$OUT" | head -1)
_note=$(grep -F 'rc up --replace' <<<"$OUT" | head -1)
if [[ "$EX" -eq 0 ]] && ! has_call "create" && ! has_call "remove" \
    && [[ "$_line" == *"/tree/pkg"* && "$_line" == *"/tree-b/pkg"* && "$_line" != *"pkg3"* && "$_line" != *"${TREE}"* ]] \
    && [[ -n "$_note" && "$_note" == *"applies"* ]]; then
  pass "R2 attach to a running cage after a third repo appeared: reports the two created-with paths (no pkg3, no host path) and says rc up --replace applies the change"
else
  fail "R2 (ex=${EX}): line='${_line}' note='${_note}' $(tr '\n' '|' <<<"$OUT" | cut -c1-300)"
fi
rm -rf "${TREE}/pkg3"
# running, label equal: report, no note
mk_inspect Running "$C2" "$SHA2V" /tree/pkg /tree-b/pkg
run_up -- up --conf "$C2" "$PROJ"
if [[ "$EX" -eq 0 ]] && grep -qF 'created with' <<<"$OUT" && ! grep -qF 'rc up --replace applies' <<<"$OUT"; then
  pass "R2b attach with an unchanged scan: the report, no change note"
else
  fail "R2b (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-300)"
fi
# running, label missing, set non-empty: a change
mk_inspect Running "$C2" "" /tree/pkg /tree-b/pkg
run_up -- up --conf "$C2" "$PROJ"
if [[ "$EX" -eq 0 ]] && grep -qF 'rc up --replace applies' <<<"$OUT"; then pass "R2c attach, label missing and set non-empty: says rc up --replace applies"; else fail "R2c (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-300)"; fi
# no hide in the cage, none in the scan: nothing said
mk_inspect Running "$CNONE" ""
run_up -- up --conf "$CNONE" "$PROJ"
if [[ "$EX" -eq 0 ]] && ! grep -qiE 'created with|hidden' <<<"$OUT"; then pass "R2d nothing hidden anywhere: no report"; else fail "R2d: $(tr '\n' '|' <<<"$OUT" | cut -c1-300)"; fi
# JSON mode keeps stdout bare: the report is a human line
mk_inspect Running "$C2" "$SHA2V" /tree/pkg /tree-b/pkg
run_json -- up --output json --conf "$C2" "$PROJ"
if [[ "$EX" -eq 0 ]] && jq -e . >/dev/null 2>&1 <<<"$JOUT" && ! jq -e 'has("hidden_repos")' >/dev/null 2>&1 <<<"$JOUT"; then
  pass "R2e a real --output json attach: one JSON object on stdout, created-with paths not in it"
else
  fail "R2e (ex=${EX}): ${JOUT}"
fi

# R2f: a --output json attach says so too: the report and the --replace note go
# to stderr, stdout stays one JSON object.
mk_inspect Running "$C2" "stale-hash" /tree/pkg /tree-b/pkg
JERR="${T}/json.err"
: > "$LOG"
JOUT=$(cd "${T}/cwd" && env RC_PYTHON3="${T}/bin/okpy" "$RC" up --output json --conf "$C2" "$PROJ" 2>"$JERR" < /dev/null); EX=$?
if [[ "$EX" -eq 0 ]] && [[ "$(jq -c . <<<"$JOUT" 2>/dev/null | wc -l)" -eq 1 ]] && jq -e '.action == "attached"' <<<"$JOUT" >/dev/null 2>&1 \
    && grep -q 'as created with.*/tree/pkg.*/tree-b/pkg' "$JERR" && grep -qF 'rc up --replace applies the change' "$JERR" \
    && ! grep -qF 'rc up --replace' <<<"$JOUT"; then
  pass "R2f --output json attach, scan changed: stderr has the created-with line and the --replace note, stdout is one JSON object"
else
  fail "R2f (ex=${EX}): stdout=${JOUT} stderr=$(tr '\n' '|' < "$JERR" | cut -c1-300)"
fi

# C8: two keys differ at once (host-tool presence and the hidden set): the
# hidden-set reason is still printed. And with the config hash also differing.
mk_inspect Stopped "$C" "stale-hash" /tree/pkg
jq '.config.labels["rc.host-tools"] = "present"' "${T}/inspect.json" > "${T}/inspect.tmp" && mv "${T}/inspect.tmp" "${T}/inspect.json"
run_up -- up --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && converged && grep -qE '^Hidden repos changed since cage' <<<"$OUT"; then
  pass "C8 presence and hidden set both differ: recreated, hidden-set reason printed"
else
  fail "C8 (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-300)"
fi
mk_inspect Stopped "$C" "stale-hash" /tree/pkg
jq '.config.labels["rc.cage-conf-sha"] = "stale"' "${T}/inspect.json" > "${T}/inspect.tmp" && mv "${T}/inspect.tmp" "${T}/inspect.json"
run_up -- up --conf "$C" "$PROJ"
if [[ "$EX" -eq 0 ]] && converged && grep -qE '^Hidden repos changed since cage' <<<"$OUT"; then
  pass "C8b config hash and hidden set both differ: recreated, hidden-set reason printed"
else
  fail "C8b (ex=${EX}): $(tr '\n' '|' <<<"$OUT" | cut -c1-300)"
fi

# R3: attach and resume leave a worktree cage's gitfile alone (the mount
# preparation rewrites ~/.cache/rc/<name>.gitfile; on a live cage that would
# rewrite its pointer), human and --output json. Shape from tests/test-device-ceiling.sh D5w.
WTMAIN="${T}/wtmain"; WT="${T}/wt"
mkdir -p "$WTMAIN" && git -C "$WTMAIN" init -q
git -C "$WTMAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WTMAIN" worktree add -q "$WT" -b wtb
WTNAME="$(basename "$T")-wt"
GITFILE="${HOME}/.cache/rc/${WTNAME}.gitfile"
mkdir -p "${HOME}/.cache/rc"
reset_gitfile() { printf 'sentinel\n' > "$GITFILE"; touch -d '2001-01-01 00:00:00' "$GITFILE"; }
WTC="${T}/conf/wt.yaml"
PROJ="$WT"; mk_conf "$WTC" "${TREE}:/tree" "${TREE}:/tree-b"
for _fmt in human json; do
  for _st in Running Stopped; do
    mk_inspect "$_st" "$WTC" "$SHA2V" /tree/pkg /tree-b/pkg; reset_gitfile
    if [[ "$_fmt" == json ]]; then run_json -- up --output json --conf "$WTC" "$WT"; else run_up -- up --conf "$WTC" "$WT"; fi
    _why=""
    [[ "$EX" -eq 0 ]] || _why+=" exit-${EX}"
    [[ "$(cat "$GITFILE")" == sentinel && "$(stat -c %Y "$GITFILE")" == "$(date -d '2001-01-01 00:00:00' +%s)" ]] || _why+=" gitfile-rewritten"
    grep -qE '^msb (create|remove|stop)' "$LOG" && _why+=" create-remove-stop"
    if [[ -z "$_why" ]]; then pass "R3 ${_st} worktree cage, ${_fmt}: gitfile content and mtime untouched, no create/remove/stop"; else fail "R3 ${_st} ${_fmt}:${_why}: ${OUT}${JOUT}"; fi
  done
done
# control: a create writes the gitfile, so the fixture can go red
rm -f "${T}/inspect.json"; reset_gitfile
run_up -- up --dry-run --conf "$WTC" "$WT"
if [[ "$(cat "$GITFILE")" == gitdir:* ]]; then pass "R3 control: a create writes the gitfile (the fixture reaches the write)"; else fail "R3 control: gitfile untouched on create: ${OUT}"; fi
PROJ="${T}/ws"

echo ""
if [[ "$FAILURES" -eq 0 ]]; then echo "All tests passed."; else echo "${FAILURES} test(s) failed."; exit 1; fi
