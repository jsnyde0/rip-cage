#!/usr/bin/env bash
set -uo pipefail

# tests/test-up-dry-run-pure.sh -- host-tier proof for rip-cage-47gy: `rc up
# --dry-run` never writes docker's or msb's image stores. It never runs docker
# save/tag/pull/build/run or msb load/create/pull/start/stop/remove, even when
# docker's and msb's copies of the image disagree
# (the state that used to trigger the layer-drift resync before the dry-run
# exit and rewrote msb's rip-cage:latest on 2026-09-28).
#
# Fixture: fake docker + msb on PATH, logging every call. docker reports the
# image present and current (version label = rc's VERSION) with layers [aaa];
# msb lists the same reference but with layers [bbb] -- drift status 1. A
# `msb load` flips msb's answer to [aaa] so the real path converges.
#
#   N1-N3  --dry-run: exit 0, no mutating call, the "Would run 'msb load'" line.
#   P1     positive control: the same fixture WITHOUT --dry-run reaches
#          `docker save` + `msb load` (the resync still runs for real).
#   R1     red check: a scratch copy of rc with the DRY_RUN guard removed turns
#          N2 red -- proven against the copy, never the live file.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on PATH"; exit 0; }

T=$(mktemp -d /private/tmp/rc-dry-run-pure-XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

RC_VER=$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")
CALL_LOG="${T}/calls.log"
LOADED="${T}/msb-loaded"
BIN="${T}/bin"
mkdir -p "$BIN"

cat > "${BIN}/docker" <<FAKEEOF
#!/usr/bin/env bash
echo "docker \$*" >> "${CALL_LOG}"
case "\${1:-}" in
  info) exit 0 ;;
  save)
    _o="" _p=""
    for _a in "\$@"; do [[ "\$_p" == "-o" ]] && _o="\$_a"; _p="\$_a"; done
    [[ -n "\$_o" ]] && dd if=/dev/zero of="\$_o" bs=1024 count=1200 >/dev/null 2>&1
    exit 0 ;;
  image)
    if [[ "\${2:-}" == "inspect" ]]; then
      _f="" _p=""
      for _a in "\$@"; do [[ "\$_p" == "--format" ]] && _f="\$_a"; _p="\$_a"; done
      case "\$_f" in
        *RootFS.Layers*) echo '["sha256:aaa"]' ;;
        *image.version*) echo '${RC_VER}' ;;
        '{{.Id}}') echo 'sha256:d0c4e2b1a3f5' ;;
        *) echo '{}' ;;
      esac
      exit 0
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
FAKEEOF

cat > "${BIN}/msb" <<FAKEEOF
#!/usr/bin/env bash
echo "msb \$*" >> "${CALL_LOG}"
case "\${1:-}" in
  --version) echo "msb 0.7.4"; exit 0 ;;
  load) cat >/dev/null; touch "${LOADED}"; exit 0 ;;
  image)
    case "\${2:-}" in
      list) echo '[{"reference":"rip-cage:latest"}]'; exit 0 ;;
      inspect)
        if [[ -f "${LOADED}" ]]; then
          echo '{"config":{"digest":"sha256:new"},"layers":[{"diff_id":"sha256:aaa"}]}'
        else
          echo '{"config":{"digest":"sha256:old"},"layers":[{"diff_id":"sha256:bbb"}]}'
        fi
        exit 0 ;;
    esac
    exit 0 ;;
  inspect) exit 1 ;;
  *) exit 0 ;;
esac
FAKEEOF
chmod +x "${BIN}/docker" "${BIN}/msb"

H="${T}/home"
WS="${T}/ws"
mkdir -p "$H/.config/rip-cage" "$WS"
CONF="${T}/cage.yaml"
cat > "$CONF" <<CONF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${WS}:/workspace"
  - "${H}/.claude/projects:/home/agent/.claude/projects"
  - "${H}/.claude/sessions:/home/agent/.claude/sessions"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
CONF

MUTATING='^(docker (save|tag|pull|build|load|run|image (tag|pull|load|build))|msb (load|create|pull|start|stop|remove|rm|image (load|pull)))( |$)'

# _run_up RC_SCRIPT [--dry-run] -> OUT, RCODE; call log reset first.
_run_up() {
  local _rc="$1"; shift
  : > "$CALL_LOG"; rm -f "$LOADED"
  OUT=$(HOME="$H" XDG_CONFIG_HOME="${H}/.config" RC_CAGE_CONF="$CONF" PATH="${BIN}:${PATH}" \
        bash "$_rc" up "$@" "$WS" 2>&1 </dev/null)
  RCODE=$?
}

# Sanity: the fixture really is the drift state (status 1).
_st=$(cd "$T" && HOME="$H" PATH="${BIN}:${PATH}" IMAGE=rip-cage:latest bash -c \
  "source '${REPO_ROOT}/rc' 2>/dev/null; IMAGE=rip-cage:latest; _msb_image_layer_drift_status; echo \$?" 2>/dev/null | tail -1)
if [[ "$_st" == "1" ]]; then pass "fixture: docker and msb disagree (drift status 1)"; else fail "fixture: drift status is '${_st}', expected 1"; fi

echo "=== N: rc up --dry-run on the drift fixture ==="
_run_up "${REPO_ROOT}/rc" --dry-run
if [[ $RCODE -eq 0 ]]; then pass "N1 rc up --dry-run exits 0"; else fail "N1 exit ${RCODE}: $(tail -5 <<<"$OUT")"; fi
if grep -Eq "$MUTATING" "$CALL_LOG"; then
  fail "N2 dry-run made a mutating runtime call: $(grep -E "$MUTATING" "$CALL_LOG" | head -3 | tr '\n' ';')"
else
  pass "N2 call log holds no save/tag/pull/build/load/create ($(wc -l < "$CALL_LOG" | tr -d ' ') read-only calls)"
fi
if grep -q "Would run 'msb load' to resync" <<<"$OUT"; then
  pass "N3 dry-run reports the resync it would run"
else
  fail "N3 no 'Would run msb load' line: $(tail -5 <<<"$OUT")"
fi

echo ""
echo "=== P: positive control, same fixture WITHOUT --dry-run ==="
_run_up "${REPO_ROOT}/rc"
if grep -q '^docker save' "$CALL_LOG" && grep -q '^msb load' "$CALL_LOG"; then
  pass "P1 the real path still resyncs (docker save + msb load in the call log)"
else
  fail "P1 real path did not resync: $(grep -E '^(docker|msb) (save|load)' "$CALL_LOG" | head -3 | tr '\n' ';') / $(tail -3 <<<"$OUT")"
fi

echo ""
echo "=== R: red check, DRY_RUN guard removed in a scratch copy ==="
R="${T}/rc-copy"
mkdir -p "$R"
( cd "$REPO_ROOT" && tar -cf - rc cli share VERSION cage/boot 2>/dev/null ) | tar -xf - -C "$R"
sed -i.bak 's/if \[\[ "\$_image_absent" == false && "\${DRY_RUN:-}" != "true" \]\]; then/if [[ "$_image_absent" == false ]]; then/' "${R}/cli/up.sh"
if cmp -s "${R}/cli/up.sh" "${R}/cli/up.sh.bak"; then
  fail "R1 could not remove the guard in the scratch copy (anchor line changed?)"
else
  _run_up "${R}/rc" --dry-run
  if grep -Eq "$MUTATING" "$CALL_LOG"; then
    pass "R1 without the guard, --dry-run reaches a mutating call (N2 goes red)"
  else
    fail "R1 guard removed but no mutating call observed -- N2 cannot go red"
  fi
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
[[ $FAILURES -eq 0 ]]
