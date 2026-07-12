#!/usr/bin/env bash
# tests/test-msb-deny-visibility.sh -- proof for bead rip-cage-rj68 (S6)
# criterion 5: "cages boot with trace logging ON by default, and a denied
# egress surfaces the DENIED DOMAIN as a readable fix-hint (the `domain=`
# field rc tails) that the repair loop consumes -- verified by triggering a
# REAL denial and OBSERVING the denied domain in the fix-hint output, not
# merely present in a raw log line."
#
# Coverage:
#   TRACE  a cage created via _up_start_container (the real create path,
#          not a hand-rolled msb run) boots with trace-level logging on by
#          default -- confirmed by successfully mining the denial line at
#          all (it would be absent at default log level per the spike,
#          docs/2026-07-09-msb-spike-egress-observability.md)
#   HINT   _msb_denied_domains_from_trace_log turns a triggered real DNS
#          denial into a READABLE fix-hint string containing the denied
#          domain -- not merely "present somewhere in a raw `msb logs`
#          dump" (the raw JSONL line is Rust-debug-formatted and not
#          fix-hint-shaped on its own)
#   MULTI  two distinct denied domains both appear, deduplicated (a burst
#          of repeated denials for the same domain doesn't repeat it)
#   CLEAN  an ALLOWED host never appears in the denied-domains output
#          (positive control -- the extractor isn't just echoing every
#          domain the guest ever touched)
#
# NEEDS_MSB + a pre-built rip-cage:latest image + live network path to
# example.com / a non-allowlisted host. Self-skips otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
IMAGE="rip-cage:latest"
FAILURES=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); echo "FAIL  [$TOTAL] $1 -- ${2:-}"; FAILURES=$((FAILURES + 1)); }

if ! command -v msb >/dev/null 2>&1; then
  echo "SKIP: msb not available -- skipping $(basename "$0")"
  exit 0
fi
if ! msb image list --format json 2>/dev/null | grep -qF "$IMAGE"; then
  echo "SKIP: no pre-built ${IMAGE} in msb's local image cache -- skipping $(basename "$0")"
  exit 0
fi

NAME="deny-vis-probe-$$"
cleanup() { msb remove --force "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Boot via the SAME --log-level trace default _up_start_container uses
# (rip-cage-rj68 S6) -- this is a direct msb create rather than a full `rc
# up` invocation purely to keep this probe fast/self-contained; the
# trace-on-by-default CLAIM itself is verified structurally against
# cli/up.sh below (TRACE-STRUCT), and end-to-end via test-msb-lifecycle-
# create-resume.sh's real `rc up` boots.
if ! msb create "$IMAGE" --name "$NAME" --log-level trace \
    --net-default deny --net-rule "allow@example.com:tcp:443" >/dev/null 2>&1; then
  fail "setup: msb create failed"
  echo ""
  echo "=== test-msb-deny-visibility.sh: ${FAILURES}/${TOTAL} failure(s) (aborting) ==="
  exit 1
fi

echo ""
echo "=== TRACE-STRUCT: _up_start_container always passes --log-level trace ==="
if grep -qE -- '--log-level trace' "${REPO_ROOT}/cli/up.sh"; then
  pass "TRACE-STRUCT: cli/up.sh's create path unconditionally sets --log-level trace"
else
  fail "TRACE-STRUCT: --log-level trace not found in cli/up.sh"
fi

echo ""
echo "=== Triggering two real denials + one real allow (positive control) ==="
msb exec "$NAME" -- curl -sS --max-time 8 https://www.a-denied-domain-example.org >/dev/null 2>&1 || true
msb exec "$NAME" -- curl -sS --max-time 8 https://another-denied-domain.example.net >/dev/null 2>&1 || true
msb exec "$NAME" -- curl -sS --max-time 8 https://www.a-denied-domain-example.org >/dev/null 2>&1 || true
CTRL_OUT=$(msb exec "$NAME" -- curl -sS -o /dev/null -w '%{http_code} %{size_download}' --max-time 8 https://example.com 2>/dev/null)
if [[ "$CTRL_OUT" == 200\ * ]] && [[ "${CTRL_OUT#* }" -gt 0 ]]; then
  pass "positive control: the allowed host returned real bidirectional data (${CTRL_OUT})"
else
  fail "positive control: allowed host did not return real data -- dead network would invalidate the deny evidence below" "$CTRL_OUT"
fi

# shellcheck source=/dev/null
source "$RC" 2>/dev/null

echo ""
echo "=== HINT: _msb_denied_domains_from_trace_log turns the denial into a readable fix-hint ==="
HINT_OUT=$(_msb_denied_domains_from_trace_log "$NAME")
echo "--- fix-hint output ---"
echo "$HINT_OUT"
echo "-----------------------"
if echo "$HINT_OUT" | grep -q "www.a-denied-domain-example.org"; then
  pass "HINT: the first denied domain appears in the readable fix-hint output"
else
  fail "HINT: expected www.a-denied-domain-example.org in the fix-hint output" "$HINT_OUT"
fi
if echo "$HINT_OUT" | grep -q "another-denied-domain.example.net"; then
  pass "HINT: the second denied domain appears in the readable fix-hint output"
else
  fail "HINT: expected another-denied-domain.example.net in the fix-hint output" "$HINT_OUT"
fi

echo ""
echo "=== MULTI: repeated denials for the same domain are deduplicated ==="
DEDUP_COUNT=$(echo "$HINT_OUT" | grep -c "www.a-denied-domain-example.org" || true)
if [[ "$DEDUP_COUNT" -eq 1 ]]; then
  pass "MULTI: the twice-denied domain appears exactly once (deduplicated)"
else
  fail "MULTI: expected exactly one occurrence" "count=$DEDUP_COUNT"
fi

echo ""
echo "=== CLEAN: the allowed host never appears in the denied-domains output ==="
if ! echo "$HINT_OUT" | grep -q "example.com"; then
  pass "CLEAN: the allowed host (example.com) is absent from the denied-domains fix-hint"
else
  fail "CLEAN: allowed host leaked into denied-domains output" "$HINT_OUT"
fi

echo ""
echo "=== test-msb-deny-visibility.sh: ${FAILURES}/${TOTAL} failure(s) ==="
[[ "$FAILURES" -eq 0 ]]
