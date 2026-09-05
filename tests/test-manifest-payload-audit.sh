#!/usr/bin/env bash
# tests/test-manifest-payload-audit.sh — recurrence guard for rip-cage-bqm8
# (manifest/default-tools.yaml shipped a base64 managed-settings.json blob
# wiring a PreToolUse hook to the RETIRED block-ssh-bypass.sh, ADR-029 D3).
#
# ROOT CAUSE it guards against: manifest/default-tools.yaml carries several
# TOOL entries whose install_cmd embeds base64-encoded config payloads
# (managed-settings.json, dcg config, doc assets). Those payloads drift
# silently from their canonical examples/<recipe>/ sources because a plain
# `grep` of the manifest finds nothing — the dangling reference only exists
# in DECODED form. This bug went unnoticed for weeks for exactly that reason.
#
# What this test asserts (host-only, no docker/msb, no live cage):
#
#   CHECK A (fragment freshness) — running examples/claude/build-fragment.sh
#     fresh reproduces the checked-in examples/claude/manifest-fragment.yaml
#     byte-for-byte. Catches the fragment itself drifting from its own
#     generator (never hand-edit the base64 — build-fragment.sh's own header).
#
#   CHECK B (dist-recipe sync) — manifest/default-tools.yaml's claude-recipe
#     entry byte-matches examples/claude/manifest-fragment.yaml's claude-recipe
#     entry. Mirrors the existing pi-recipe T1f check in
#     tests/test-pi-recipe-lifecycle.sh — rip-cage-bqm8 found no equivalent
#     existed for the claude-recipe entry, which is exactly how it drifted.
#
#   CHECK C (payload audit — the actual recurrence guard) — decode EVERY
#     base64 payload embedded in manifest/default-tools.yaml's install_cmd
#     lines and assert on the DECODED content: no `"command": "<path>"` JSON
#     hook reference may point at a script that nothing in the manifest
#     provisions (and that isn't on the small base-image allowlist below).
#     Assert on decoded bytes, never the encoded form.
#
#   CHECK D (negative control for CHECK C) — re-encode a synthetic payload
#     that DOES reference a nonexistent script and prove the CHECK C logic
#     goes RED on it. Without this, CHECK C could pass vacuously (e.g. a
#     regex typo that never matches anything).
#
# Wired into run-host.sh's default (non-container) tier — see the
# "RUN-HOST REGISTRATION LINE" note in the rip-cage-bqm8 ship-record; a
# sibling agent owns run-host.sh's ledger during this bead's implementation
# window, so registration lands there rather than being added here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
DIST_MANIFEST="${REPO_ROOT}/manifest/default-tools.yaml"
CLAUDE_FRAGMENT="${REPO_ROOT}/examples/claude/manifest-fragment.yaml"
BUILD_FRAGMENT_SH="${REPO_ROOT}/examples/claude/build-fragment.sh"

FAILURES=0
TOTAL=0
TMP_FILES=()

pass() { TOTAL=$((TOTAL + 1)); echo "PASS  [$TOTAL] $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL  [$TOTAL] $1${2:+ -- $2}"; }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

echo "=== test-manifest-payload-audit.sh ==="

# ---------------------------------------------------------------------------
# Shared: extract a single top-level "- name: <name>" tools[] entry's YAML
# block: from its "- name:" line through its OWN trailing "    mounts:" line
# (inclusive), never past it.
#
# Deliberately NOT the "stop at the next '  - name:' line" idiom used by
# extract_entry() in test-pi-recipe-lifecycle.sh (duplicated here since that
# file is off-limits for edits during this bead's implementation window):
# that idiom silently swallows the NEXT entry's preceding comment header
# into the current entry's extracted text whenever one exists (verified
# live -- it only "works" for pi-recipe because the entry immediately after
# it, dcg, happens to carry no header comment; claude-recipe's neighbour,
# pi-recipe, does carry one, which would false-fail this exact check).
# Bounding on the entry's own last property line (every tools[] entry here
# ends with a "mounts:" line) sidesteps that trap entirely.
# ---------------------------------------------------------------------------
extract_entry() {
  local file="$1" name="$2"
  awk -v name="$name" '
    /^  - name: / {
      if ($0 == "  - name: " name) { in_entry=1; print; next }
      else if (in_entry) { exit }
    }
    in_entry { print }
    in_entry && /^    mounts:/ { exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Shared: decode every base64 payload embedded in a manifest file's
# install_cmd lines (`echo '<b64>' | base64 -d > <path>`) and fail on any
# `"command": "<absolute-path>"` JSON hook reference that nothing in the
# SAME manifest provisions. Prints one "DANGLING REFERENCE: ..." line per
# violation to stdout; exit 0 if none found, exit 1 otherwise.
# ---------------------------------------------------------------------------
audit_manifest_payloads() {
  local manifest_file="$1"
  python3 - "$manifest_file" <<'PYEOF'
import re
import sys
import base64

manifest_file = sys.argv[1]
content = open(manifest_file, encoding="utf-8").read()

# Every (base64 blob, write-target path) pair emitted by an install_cmd's
# `echo '<b64>' | base64 -d > <path>` provisioning step, anywhere in the
# manifest -- these are the paths THIS manifest actually provisions.
pairs = re.findall(r"echo '([A-Za-z0-9+/=]+)' \| base64 -d > (\S+)", content)
provisioned_paths = {path for _, path in pairs}

# Base-image-baked executables that are legitimate command targets without
# ever being an install_cmd write target (apt/npm-installed in
# cage/Dockerfile). Keep this short; justify any addition in review -- a
# broad allowlist here defeats the whole point of this check.
BASE_IMAGE_ALLOWLIST = set()

violations = []
for blob, _ in pairs:
    decoded = base64.b64decode(blob)
    # Absolute, single-token (no whitespace) path references inside a
    # `"command": "..."` JSON hook field -- the shape every managed-settings
    # / dcg-config hook wiring uses. The single-token filter deliberately
    # excludes shell command STRINGS (e.g. "rm -rf /", "git push --force
    # origin main") that also use the JSON key "command" inside DCG's own
    # test-fixture/policy blobs baked by the dcg-wiring entry -- those are
    # policy data, not script references, and must not false-positive here.
    for m in re.finditer(rb'"command"\s*:\s*"(/\S+)"', decoded):
        ref = m.group(1).decode()
        if ref not in provisioned_paths and ref not in BASE_IMAGE_ALLOWLIST:
            violations.append(ref)

if violations:
    for ref in violations:
        print(f"DANGLING REFERENCE: decoded payload references '{ref}', "
              f"which no install_cmd in {manifest_file} provisions and "
              f"which is not on the base-image allowlist")
    sys.exit(1)
sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# CHECK A -- examples/claude/manifest-fragment.yaml is fresh against its own
# generator (build-fragment.sh, per that file's own header instructions).
# ---------------------------------------------------------------------------
if [[ ! -x "$BUILD_FRAGMENT_SH" && ! -f "$BUILD_FRAGMENT_SH" ]]; then
  fail "CHECK A generator missing" "expected ${BUILD_FRAGMENT_SH}"
else
  fresh_fragment="$(mktemp "${TMPDIR:-/tmp}/rc-payload-audit-fresh-XXXXXX")"
  TMP_FILES+=("$fresh_fragment")
  if bash "$BUILD_FRAGMENT_SH" > "$fresh_fragment" 2>/tmp/rc-payload-audit-genstderr; then
    if diff -q "$CLAUDE_FRAGMENT" "$fresh_fragment" >/dev/null 2>&1; then
      pass "CHECK A examples/claude/manifest-fragment.yaml is byte-identical to a fresh build-fragment.sh run (reproducible, not stale)"
    else
      fail "CHECK A examples/claude/manifest-fragment.yaml is STALE relative to build-fragment.sh's current output -- re-run: bash examples/claude/build-fragment.sh > examples/claude/manifest-fragment.yaml"
    fi
  else
    fail "CHECK A build-fragment.sh exited non-zero" "$(cat /tmp/rc-payload-audit-genstderr 2>/dev/null)"
  fi
  rm -f /tmp/rc-payload-audit-genstderr
fi

# ---------------------------------------------------------------------------
# CHECK B -- manifest/default-tools.yaml's claude-recipe entry byte-matches
# examples/claude/manifest-fragment.yaml's claude-recipe entry (mirrors the
# existing pi-recipe T1f check; no claude-recipe equivalent existed before
# this bead, which is exactly how the two copies drifted).
# ---------------------------------------------------------------------------
fragment_entry="$(extract_entry "$CLAUDE_FRAGMENT" "claude-recipe")"
dist_entry="$(extract_entry "$DIST_MANIFEST" "claude-recipe")"

if [[ -z "$fragment_entry" ]]; then
  fail "CHECK B SENTINEL FAILED: could not extract claude-recipe entry from ${CLAUDE_FRAGMENT}"
elif [[ -z "$dist_entry" ]]; then
  fail "CHECK B SENTINEL FAILED: could not extract claude-recipe entry from ${DIST_MANIFEST}"
elif [[ "$fragment_entry" == "$dist_entry" ]]; then
  pass "CHECK B manifest/default-tools.yaml claude-recipe entry byte-matches examples/claude/manifest-fragment.yaml (regenerated)"
else
  fail "CHECK B manifest/default-tools.yaml claude-recipe entry is STALE relative to examples/claude/manifest-fragment.yaml -- regenerate dist"
fi

# ---------------------------------------------------------------------------
# CHECK C -- the recurrence guard itself: decode every base64 payload in
# manifest/default-tools.yaml and assert no dangling script reference.
# ---------------------------------------------------------------------------
if [[ ! -f "$DIST_MANIFEST" ]]; then
  fail "CHECK C manifest missing" "expected ${DIST_MANIFEST}"
else
  if audit_output="$(audit_manifest_payloads "$DIST_MANIFEST")"; then
    pass "CHECK C manifest/default-tools.yaml: no decoded payload references a script absent from the image/repo"
  else
    fail "CHECK C manifest/default-tools.yaml has a dangling script reference" "$audit_output"
  fi
fi

# ---------------------------------------------------------------------------
# CHECK D -- negative control: prove CHECK C's checker actually goes RED on
# a dangling reference (a synthetic manifest, independent of the real one's
# current state -- must fail on every run, proving the check is not vacuous).
# ---------------------------------------------------------------------------
neg_json='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/lib/rip-cage/hooks/totally-fake-nonexistent-hook.sh"}]}]}}'
neg_blob="$(printf '%s' "$neg_json" | base64 | tr -d '\n')"
neg_file="$(mktemp "${TMPDIR:-/tmp}/rc-payload-audit-negctl-XXXXXX")"
TMP_FILES+=("$neg_file")
cat > "$neg_file" <<YAML
version: 1
tools:
  - name: fake-recipe
    archetype: TOOL
    version_pin: "bundled-recipe"
    install_cmd: ": && echo '${neg_blob}' | base64 -d > /etc/claude-code/managed-settings.json"
    egress: []
    mounts: []
YAML

if neg_output="$(audit_manifest_payloads "$neg_file")"; then
  fail "CHECK D negative control: checker did NOT flag an injected reference to a nonexistent script -- CHECK C is vacuous"
else
  if echo "$neg_output" | grep -q "totally-fake-nonexistent-hook.sh"; then
    pass "CHECK D negative control: checker correctly goes RED on an injected dangling reference (proves CHECK C is not vacuous)"
  else
    fail "CHECK D negative control failed for the wrong reason" "$neg_output"
  fi
fi

echo ""
echo "=== Results: $((TOTAL - FAILURES))/$TOTAL passed ==="
[[ $FAILURES -eq 0 ]] || echo "$FAILURES check(s) FAILED"
exit $FAILURES
