#!/usr/bin/env bash
# bd CLI roundtrip e2e (rip-cage-9jz)
#
# Exercises the bd CLI end-to-end against a tmpdir copy of /workspace/.beads
# (no `bd init` — user preference; init would pollute or conflict with the
# mounted workspace DB). Catches upstream CLI flag renames, stdout format
# changes, and schema migrations that break the current .beads file.
# Note: no `pipefail` — `grep -q` exits early on match, which SIGPIPEs the
# upstream `bd` process; pipefail would then surface bd's SIGPIPE exit and
# invert the test's success/failure condition.
set -eu
PASS=0
FAIL=0
TOTAL=0

check() {
    local name="$1" result="$2" detail="${3:-}"
    TOTAL=$((TOTAL + 1))
    if [[ "$result" == "pass" ]]; then
        echo "PASS  [$TOTAL] $name${detail:+ — $detail}"
        PASS=$((PASS + 1))
    else
        echo "FAIL  [$TOTAL] $name${detail:+ — $detail}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== bd CLI Roundtrip ==="
echo ""

if [[ ! -d /workspace/.beads ]]; then
    echo "SKIP: /workspace/.beads not present (nothing to roundtrip against)"
    echo "=== Results: 0 passed, 0 failed (of 0) ==="
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp -r /workspace/.beads "$tmpdir/.beads"
cd "$tmpdir"

sentinel="rc-roundtrip-$(date +%s)-$$"

# 1. bd create returns an ID
create_out=$(bd create --title="$sentinel" --description="harness roundtrip probe" --type=task --priority=3 2>&1 || true)
# bd prints "✓ Created issue: <prefix>-<id> — <title>"; pull the ID after that marker.
issue_id=$(echo "$create_out" | sed -n 's/.*Created issue: \([A-Za-z0-9-]*\).*/\1/p' | head -1)
if [[ -n "$issue_id" ]]; then
    check "bd create returns issue id" "pass" "$issue_id"
else
    check "bd create returns issue id" "fail" "$create_out"
    echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
    exit 1
fi

# 2. bd list shows the new issue ID
if bd list 2>&1 | grep -qF "$issue_id"; then
    check "bd list shows new issue" "pass"
else
    check "bd list shows new issue" "fail" "issue id '$issue_id' not found in bd list"
fi

# 3. bd update --claim succeeds
if bd update "$issue_id" --claim >/dev/null 2>&1; then
    check "bd update --claim succeeds" "pass"
else
    check "bd update --claim succeeds" "fail"
fi

# 4. bd show reflects in_progress status (matches 'in_progress' text or ◐ symbol)
show_out=$(bd show "$issue_id" 2>&1 || true)
if echo "$show_out" | grep -qiE 'in[_ -]?progress'; then
    check "bd show reflects in_progress" "pass"
else
    check "bd show reflects in_progress" "fail" "status line: $(echo "$show_out" | head -1)"
fi

# 5. bd close succeeds
if bd close "$issue_id" >/dev/null 2>&1; then
    check "bd close succeeds" "pass"
else
    check "bd close succeeds" "fail"
fi

# 6. bd show reflects closed status (bd list --status=closed has a display
#    --limit default that can hide recently-closed issues in large DBs).
if bd show "$issue_id" 2>&1 | grep -qE 'CLOSED|closed'; then
    check "bd show reflects closed" "pass"
else
    check "bd show reflects closed" "fail" "'$issue_id' status not CLOSED"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
[[ "$FAIL" -eq 0 ]] || exit 1
