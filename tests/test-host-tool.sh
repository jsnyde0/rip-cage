#!/usr/bin/env bash
# test-host-tool.sh -- the in-guest half of rc test's host-tool line checks
# (rip-cage-jdl2.6; ADR-032 D7). Baked root-owned beside the other in-guest
# suites and run by `rc test` with no arguments. Generic and name-free like
# run-recipe-smokes.sh: it calls no declared verb, names no tool, and only
# samples the route.
#
# rc test sets two variables on this exec:
#   RC_HOST_TOOL_PORT       the line's vsock port (rc's own constant; no copy here)
#   RC_HOST_TOOLS_DECLARED  present|absent -- the cage's rc.host-tools label
#
# present: an unlisted verb on the first listed tool and an unlisted tool both
#   exit 2; the declared socket answers (CID 2, the port), the neighbouring port
#   is refused, and ordinary egress is still denied.
# absent: `host-tool --list` exits 5 with the one three-cause message.
# Both: the floor probe's guard-file line for the client is present.
#
# Accumulates failures (no set -e); exits non-zero if any check failed.

set -uo pipefail

FAILURES=0
N=0
pass() { N=$((N + 1)); echo "PASS  [${N}] $1"; }
fail() { N=$((N + 1)); echo "FAIL  [${N}] $1"; FAILURES=$((FAILURES + 1)); }

CLIENT=/usr/local/bin/host-tool
PROBE=/usr/local/lib/rip-cage/floor-probe.sh

if [[ -z "${RC_HOST_TOOL_PORT:-}" ]]; then
  echo "FAIL  [0] host-tool: RC_HOST_TOOL_PORT is unset -- rc test passes the line's port in; this script holds no copy of it" >&2
  exit 1
fi
if [[ ! "${RC_HOST_TOOL_PORT}" =~ ^[0-9]+$ ]]; then
  echo "FAIL  [0] host-tool: RC_HOST_TOOL_PORT='${RC_HOST_TOOL_PORT}' is not a port number" >&2
  exit 1
fi
case "${RC_HOST_TOOLS_DECLARED:-}" in
  present|absent) ;;
  *)
    echo "FAIL  [0] host-tool: RC_HOST_TOOLS_DECLARED='${RC_HOST_TOOLS_DECLARED:-}' is not present|absent -- rc test sets it from the cage's rc.host-tools label" >&2
    exit 1 ;;
esac

# --- (d) the floor probe's guard-file line for the client --------------------
if [[ ! -x "$PROBE" ]]; then
  fail "host-tool: floor probe guards the client — ${PROBE} is missing"
else
  # A second probe run on purpose: this suite also runs standalone, and the guard line it checks must come from its own run.
  probe_rc=0
  probe_out=$("$PROBE" 2>&1) || probe_rc=$?
  if printf '%s\n' "$probe_out" | grep -Eq "^PASS .*floor: guard-file ${CLIENT}( |$)"; then
    pass "host-tool: floor probe guards the client — guard-file ${CLIENT} present and passing"
  else
    fail "host-tool: floor probe guards the client — no passing 'guard-file ${CLIENT}' line in the probe output (probe exit ${probe_rc})"
  fi
fi

if [[ "${RC_HOST_TOOLS_DECLARED}" == "absent" ]]; then
  # --- (e) no route: exit 5 with the three-cause message ----------------------
  list_rc=0
  list_err=$("$CLIENT" --list 2>&1 >/dev/null) || list_rc=$?
  if [[ "$list_rc" -eq 5 \
        && "$list_err" == *"host-tool line did not answer."* \
        && "$list_err" == *"no <cage>.tools.yaml declared for this cage"* \
        && "$list_err" == *"declaration added but the cage not recreated yet"* \
        && "$list_err" == *"the gatekeeper is down"* ]]; then
    pass "host-tool: no route, exit 5 with the three-cause message — host-tool --list exits 5 on a cage with no declared line"
  else
    fail "host-tool: no route, exit 5 with the three-cause message — exit ${list_rc}: ${list_err}"
  fi
else
  # --- (b) undeclared verb / tool exit 2, nothing ran --------------------------
  list_rc=0
  list_json=$("$CLIENT" --list --json 2>/dev/null) || list_rc=$?
  first_tool=""
  if [[ "$list_rc" -eq 0 ]]; then
    first_tool=$(printf '%s' "$list_json" | python3 -I -c '
import json, sys
tools = json.load(sys.stdin)["result"]["tools"]
print(sorted(tools)[0] if tools else "")' 2>/dev/null) || first_tool=""
  fi
  if [[ -z "$first_tool" ]]; then
    fail "host-tool: undeclared verb and tool exit 2 — cannot take a tool name from host-tool --list --json (exit ${list_rc})"
  else
    verb_rc=0
    verb_err=$("$CLIENT" "$first_tool" "no-such-verb-$$" 2>&1 >/dev/null) || verb_rc=$?
    if [[ "$verb_rc" -eq 2 && "$verb_err" == *"no-such-verb"* ]]; then
      pass "host-tool: an unlisted verb on a listed tool exits 2 with no-such-verb — nothing ran"
    else
      fail "host-tool: an unlisted verb on a listed tool exits 2 with no-such-verb — exit ${verb_rc}: ${verb_err}"
    fi
    tool_rc=0
    tool_err=$("$CLIENT" "no-such-tool-$$" x 2>&1 >/dev/null) || tool_rc=$?
    if [[ "$tool_rc" -eq 2 && "$tool_err" == *"no-such-tool"* ]]; then
      pass "host-tool: an unlisted tool exits 2 with no-such-tool — nothing ran"
    else
      fail "host-tool: an unlisted tool exits 2 with no-such-tool — exit ${tool_rc}: ${tool_err}"
    fi
  fi

  # --- (c) the route sample ----------------------------------------------------
  sample_rc=0
  sample_out=$(python3 -I - "$RC_HOST_TOOL_PORT" <<'PY' 2>&1
import socket, sys
port = int(sys.argv[1])

def dial(p):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect((2, p))
        return "answers"
    except socket.timeout:
        return "timeout"
    except OSError as exc:
        return "refused (%s)" % exc.__class__.__name__
    finally:
        s.close()

declared = dial(port)
neighbour = dial(port + 1)
print("declared=%s neighbour=%s" % (declared, neighbour))
sys.exit(0 if declared == "answers" and neighbour.startswith("refused") else 1)
PY
  ) || sample_rc=$?
  egress_state="denied"
  if ! command -v curl >/dev/null 2>&1; then
    egress_state="curl missing"
  elif curl -m5 -sS -o /dev/null https://example.com >/dev/null 2>&1; then
    egress_state="REACHED example.com"
  fi
  if [[ "$sample_rc" -eq 0 && "$egress_state" == "denied" ]]; then
    pass "route sample: declared socket answers, neighbour refused, egress denied — msb's isolation beyond this is not proven here"
  else
    fail "route sample: declared socket answers, neighbour refused, egress denied — ${sample_out:-no output} (sample exit ${sample_rc}); egress: ${egress_state}"
  fi
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "host-tool checks: ${N} passed"
  exit 0
fi
echo "host-tool checks: ${FAILURES} of ${N} failed"
exit 1
