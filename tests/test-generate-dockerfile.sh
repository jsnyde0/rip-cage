#!/usr/bin/env bash
# tests/test-generate-dockerfile.sh — rip-cage-9oyh §4 gap-fill: `rc
# generate-dockerfile` (previously untested — the coverage-gap inventory in
# docs/2026-07-08-rc-decomposition-map.md notes "0 tests invoke it; no
# verb-level golden master"). Byte-diff coverage (bundled + from-source
# variants) lives in tests/golden-master/cases.sh
# (generate_dockerfile_bundled / generate_dockerfile_from_source); this file
# adds structural/behavioral assertions a byte-diff alone doesn't state.
#
# Wired into tests/run-host.sh (host-only tier).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
GM_LIB="${SCRIPT_DIR}/golden-master/lib"
# shellcheck source=golden-master/lib/sandbox.sh
source "${GM_LIB}/sandbox.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------
# G1: bundled (default/empty manifest) output is a well-formed Dockerfile:
# starts with a FROM, exits 0, non-empty.
# ---------------------------------------------------------------------------
gm_sandbox_reset
gm_capture generate-dockerfile

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "G1: bundled generate-dockerfile exits 0"
else
  fail "G1 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi
if [[ -n "$GM_OUT" ]]; then
  pass "G1b: bundled output is non-empty"
else
  fail "G1b non-empty" "stdout was empty"
fi
if echo "$GM_OUT" | head -1 | grep -qE '^(#|FROM)'; then
  pass "G1c: bundled output starts with a comment or FROM (well-formed Dockerfile)"
else
  fail "G1c well-formed" "first line was not a comment or FROM: $(echo "$GM_OUT" | head -1)"
fi
if echo "$GM_OUT" | grep -qE '^FROM debian:trixie$'; then
  pass "G1d: bundled output contains the runtime base image stage"
else
  fail "G1d runtime stage" "no 'FROM debian:trixie' runtime stage found"
fi
# The bundled case must NOT contain a manifest-generated from-source builder
# stage (positive/negative control pairing with G2 below).
if ! echo "$GM_OUT" | grep -q "manifest-generated from-source builder stages"; then
  pass "G1e: bundled output has NO from-source builder-stage section (empty tools.yaml -> no extra stages)"
else
  fail "G1e no builder stages" "bundled output unexpectedly contains a from-source builder-stage section"
fi

# ---------------------------------------------------------------------------
# G2: from-source manifest actually injects the builder stage + COPY
# --from=<stage> artifact line (proves the manifest->Dockerfile composition
# is real, not just "some text changed"). Positive control against G1e.
# ---------------------------------------------------------------------------
gm_sandbox_reset
GM_MANIFEST_GLOBAL="${REPO_ROOT}/tests/fixtures/manifest-with-from-source-tool.yaml" \
  gm_capture generate-dockerfile

if [[ "$GM_EXIT" -eq 0 ]]; then
  pass "G2: from-source generate-dockerfile exits 0"
else
  fail "G2 exit" "expected 0, got $GM_EXIT. stderr=$GM_ERR"
fi
if echo "$GM_OUT" | grep -qF "FROM alpine:3.19 AS rc-builder-hello-from-source"; then
  pass "G2b: from-source output declares the manifest's builder stage (alpine:3.19 AS rc-builder-hello-from-source)"
else
  fail "G2b builder stage" "expected builder FROM line not found. output head:
$(echo "$GM_OUT" | head -40)"
fi
if echo "$GM_OUT" | grep -qF "COPY --from=rc-builder-hello-from-source /usr/local/bin/hello-from-source /usr/local/bin/hello-from-source"; then
  pass "G2c: from-source output COPYs the built artifact from the isolated builder stage"
else
  fail "G2c artifact copy" "expected COPY --from=rc-builder-hello-from-source line not found"
fi

# ---------------------------------------------------------------------------
# G3: idempotent -- calling it twice in a row with the SAME manifest
# produces byte-identical output (no hidden per-call randomness like a temp
# filename leaking into the composed content).
# ---------------------------------------------------------------------------
gm_sandbox_reset
gm_capture generate-dockerfile
RUN1="$GM_OUT"
gm_capture generate-dockerfile
RUN2="$GM_OUT"
if [[ "$RUN1" == "$RUN2" ]]; then
  pass "G3: two back-to-back calls produce byte-identical output"
else
  fail "G3 determinism" "output differs between two calls with an unchanged manifest"
fi

echo ""
echo "--- Results: ${FAILURES} failure(s) ---"
exit "$FAILURES"
