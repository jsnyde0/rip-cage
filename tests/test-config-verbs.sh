#!/usr/bin/env bash
# tests/test-config-verbs.sh — host-side write verbs `rc config set/add/remove`
# (ADR-021 D8, rip-cage-tsf2.10.4).
#
# The verbs are SURGICAL textual line editors: `yq` locates the key/anchor line,
# the edit splices minimal text, then the full loader re-validates the result;
# on validation failure the original file is restored byte-identical and the
# verb refuses ("edit the file"). yq re-emit (yq expr > tmp; cp) is FORBIDDEN as
# a write path because it destroys the config files' load-bearing comment prose.
#
# The proof shape is a BYTE-DIFF: a fixture carrying free-standing comment
# blocks AND same-line trailing comments AND an inline [] list AND a block list
# AND a !replace-tagged list is edited by each verb, and the result is diffed
# against an exact expected literal — every comment byte must survive, only the
# intended value token / the one defined []-to-block transform may change.
#
# Cases:
#   C1  set scalar/enum with trailing comment -> only value token changes
#   C2  set enum to invalid value -> refused, file byte-identical, non-zero
#   C3  add to existing block list -> exactly one new '- item' line
#   C4  add to inline [] list -> the one defined []-to-block transform
#   C5  remove existing item -> exactly that line removed
#   C6  add/remove on !replace-tagged list -> tag preserved, items edited
#   C7  verb asked to place a tag -> refuses, non-zero, file unchanged
#   C8  structural ask (set on a list / nested map) -> refuses "edit the file"
#   C9  post-edit validation failure (set version 1) -> byte-identical restore
#   C10 verb on absent project file -> file created with version: 2
#   C11 remove on mounts.denylist -> refuses citing ADR-023 D2
#   C12 in-cage invocation -> refused (RC_TEST_FAKE_DOCKERENV=1)
#   C13 rc allowlist add delegation parity (idempotency + created version: 2)
#
# Runs entirely host-side (no docker). D10 in-cage guard simulated by
# RC_TEST_FAKE_DOCKERENV=1 (same pattern as test-rc-allowlist.sh).
#
# ADRs: ADR-021 D8 (write verbs), D2 (merge/tag model), ADR-023 D2 (denylist
# additive-only), ADR-024/D7 (host-side-only threat model).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0
TOTAL=0
TEST_HOME=""

pass() { echo "PASS C$1: $2"; }
fail() { echo "FAIL C$1: $2 — $3"; FAILURES=$((FAILURES + 1)); }

cleanup() { [[ -n "${TEST_HOME:-}" && -d "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"; }
trap cleanup EXIT

setup_sandbox() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rc-config-verbs-XXXXXX")
  WS="${TEST_HOME}/workspace"
  mkdir -p "$WS"
}
teardown_sandbox() {
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
  TEST_HOME="" WS=""
}

# rc invocation, host-side (no in-cage simulation).
run_rc() { HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" "$RC" "$@"; }
# rc invocation with in-cage simulation.
run_rc_in_cage() { HOME="$TEST_HOME" XDG_CONFIG_HOME="${TEST_HOME}/.config" RC_TEST_FAKE_DOCKERENV=1 "$RC" "$@"; }

# Write the canonical comment-bearing fixture to $1.
write_fixture() {
  cat > "$1" <<'YAML'
version: 2
# Free-standing comment block about mounts
# second line of the block
mounts:
  config_mode: ro          # trailing comment on enum
  denylist:
    - .ssh
    - .aws
network:
  # comment above allowed_hosts
  allowed_hosts: []        # inline empty list with trailing comment
dcg:
  packs:                   # a block list
    - base
    - extra
  custom_rule_paths: !replace   # a replace-tagged list
    - /custom/rules.yaml
YAML
}

# ---------------------------------------------------------------------------
# C1: set scalar/enum with trailing comment -> only value token changes,
#     comment + all other bytes preserved (byte-diff against exact literal).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cat > "${WS}/expected" <<'YAML'
version: 2
# Free-standing comment block about mounts
# second line of the block
mounts:
  config_mode: rw          # trailing comment on enum
  denylist:
    - .ssh
    - .aws
network:
  # comment above allowed_hosts
  allowed_hosts: []        # inline empty list with trailing comment
dcg:
  packs:                   # a block list
    - base
    - extra
  custom_rule_paths: !replace   # a replace-tagged list
    - /custom/rules.yaml
YAML
c1_err=$(run_rc config set mounts.config_mode rw --scope project "$WS" 2>&1); c1_exit=$?
c1_ok=true; c1_reason=""
[[ "$c1_exit" -ne 0 ]] && c1_ok=false && c1_reason="exit $c1_exit; $c1_err"
if [[ "$c1_ok" == "true" ]] && ! diff -u "${WS}/expected" "${WS}/.rip-cage.yaml" >/tmp/c1.diff 2>&1; then
  c1_ok=false; c1_reason="byte-diff mismatch: $(cat /tmp/c1.diff)"
fi
if [[ "$c1_ok" == "true" ]]; then pass 1 "set enum edits only value token, comment preserved"; else fail 1 "set scalar/enum" "$c1_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C2: set enum to invalid value -> refused, file byte-identical, non-zero.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c2_err=$(run_rc config set mounts.config_mode bogus --scope project "$WS" 2>&1); c2_exit=$?
c2_ok=true; c2_reason=""
[[ "$c2_exit" -eq 0 ]] && c2_ok=false && c2_reason="exit 0 (want non-zero — invalid enum must refuse)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c2_ok=false; c2_reason="${c2_reason:+$c2_reason; }file mutated (want byte-identical)"; }
if [[ "$c2_ok" == "true" ]]; then pass 2 "set invalid enum refused + file byte-identical"; else fail 2 "set invalid enum" "$c2_reason -- $c2_err"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C3: add to existing block list -> exactly one new '- item' line.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cat > "${WS}/expected" <<'YAML'
version: 2
# Free-standing comment block about mounts
# second line of the block
mounts:
  config_mode: ro          # trailing comment on enum
  denylist:
    - .ssh
    - .aws
network:
  # comment above allowed_hosts
  allowed_hosts: []        # inline empty list with trailing comment
dcg:
  packs:                   # a block list
    - base
    - extra
    - newpack
  custom_rule_paths: !replace   # a replace-tagged list
    - /custom/rules.yaml
YAML
c3_err=$(run_rc config add dcg.packs newpack --scope project "$WS" 2>&1); c3_exit=$?
c3_ok=true; c3_reason=""
[[ "$c3_exit" -ne 0 ]] && c3_ok=false && c3_reason="exit $c3_exit; $c3_err"
if [[ "$c3_ok" == "true" ]] && ! diff -u "${WS}/expected" "${WS}/.rip-cage.yaml" >/tmp/c3.diff 2>&1; then
  c3_ok=false; c3_reason="byte-diff mismatch: $(cat /tmp/c3.diff)"
fi
if [[ "$c3_ok" == "true" ]]; then pass 3 "add to block list inserts exactly one '- item'"; else fail 3 "add to block list" "$c3_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C4: add to inline [] list -> the one defined []-to-block transform, all
#     comment bytes preserved (the '# inline...' trailing comment stays).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cat > "${WS}/expected" <<'YAML'
version: 2
# Free-standing comment block about mounts
# second line of the block
mounts:
  config_mode: ro          # trailing comment on enum
  denylist:
    - .ssh
    - .aws
network:
  # comment above allowed_hosts
  allowed_hosts:        # inline empty list with trailing comment
    - example.com
dcg:
  packs:                   # a block list
    - base
    - extra
  custom_rule_paths: !replace   # a replace-tagged list
    - /custom/rules.yaml
YAML
c4_err=$(run_rc config add network.allowed_hosts example.com --scope project "$WS" 2>&1); c4_exit=$?
c4_ok=true; c4_reason=""
[[ "$c4_exit" -ne 0 ]] && c4_ok=false && c4_reason="exit $c4_exit; $c4_err"
if [[ "$c4_ok" == "true" ]] && ! diff -u "${WS}/expected" "${WS}/.rip-cage.yaml" >/tmp/c4.diff 2>&1; then
  c4_ok=false; c4_reason="byte-diff mismatch: $(cat /tmp/c4.diff)"
fi
if [[ "$c4_ok" == "true" ]]; then pass 4 "add to inline [] performs []-to-block transform, comment preserved"; else fail 4 "add to inline []" "$c4_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C5: remove existing item -> exactly that '- item' line removed.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cat > "${WS}/expected" <<'YAML'
version: 2
# Free-standing comment block about mounts
# second line of the block
mounts:
  config_mode: ro          # trailing comment on enum
  denylist:
    - .ssh
    - .aws
network:
  # comment above allowed_hosts
  allowed_hosts: []        # inline empty list with trailing comment
dcg:
  packs:                   # a block list
    - base
  custom_rule_paths: !replace   # a replace-tagged list
    - /custom/rules.yaml
YAML
c5_err=$(run_rc config remove dcg.packs extra --scope project "$WS" 2>&1); c5_exit=$?
c5_ok=true; c5_reason=""
[[ "$c5_exit" -ne 0 ]] && c5_ok=false && c5_reason="exit $c5_exit; $c5_err"
if [[ "$c5_ok" == "true" ]] && ! diff -u "${WS}/expected" "${WS}/.rip-cage.yaml" >/tmp/c5.diff 2>&1; then
  c5_ok=false; c5_reason="byte-diff mismatch: $(cat /tmp/c5.diff)"
fi
if [[ "$c5_ok" == "true" ]]; then pass 5 "remove deletes exactly the matching '- item' line"; else fail 5 "remove item" "$c5_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C6: add on a !replace-tagged list -> tag preserved on the key line, item
#     appended to that layer's block.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cat > "${WS}/expected" <<'YAML'
version: 2
# Free-standing comment block about mounts
# second line of the block
mounts:
  config_mode: ro          # trailing comment on enum
  denylist:
    - .ssh
    - .aws
network:
  # comment above allowed_hosts
  allowed_hosts: []        # inline empty list with trailing comment
dcg:
  packs:                   # a block list
    - base
    - extra
  custom_rule_paths: !replace   # a replace-tagged list
    - /custom/rules.yaml
    - /more/rules.yaml
YAML
c6_err=$(run_rc config add dcg.custom_rule_paths /more/rules.yaml --scope project "$WS" 2>&1); c6_exit=$?
c6_ok=true; c6_reason=""
[[ "$c6_exit" -ne 0 ]] && c6_ok=false && c6_reason="add exit $c6_exit; $c6_err"
if [[ "$c6_ok" == "true" ]] && ! diff -u "${WS}/expected" "${WS}/.rip-cage.yaml" >/tmp/c6.diff 2>&1; then
  c6_ok=false; c6_reason="add byte-diff mismatch: $(cat /tmp/c6.diff)"
fi
# also: remove from the tagged list restores the fixture exactly
if [[ "$c6_ok" == "true" ]]; then
  write_fixture "${WS}/orig"
  c6b_err=$(run_rc config remove dcg.custom_rule_paths /more/rules.yaml --scope project "$WS" 2>&1); c6b_exit=$?
  [[ "$c6b_exit" -ne 0 ]] && c6_ok=false && c6_reason="remove exit $c6b_exit; $c6b_err"
  if [[ "$c6_ok" == "true" ]] && ! diff -u "${WS}/orig" "${WS}/.rip-cage.yaml" >/tmp/c6b.diff 2>&1; then
    c6_ok=false; c6_reason="remove byte-diff mismatch (tag not preserved?): $(cat /tmp/c6b.diff)"
  fi
fi
if [[ "$c6_ok" == "true" ]]; then pass 6 "add/remove on !replace-tagged list preserves tag, edits items"; else fail 6 "!replace-tagged list edit" "$c6_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C7: verb asked to place a tag -> refuses, non-zero, file unchanged.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c7_err=$(run_rc config add network.allowed_hosts '!replace' --scope project "$WS" 2>&1); c7_exit=$?
c7_ok=true; c7_reason=""
[[ "$c7_exit" -eq 0 ]] && c7_ok=false && c7_reason="exit 0 (want non-zero — tag placement must refuse)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c7_ok=false; c7_reason="${c7_reason:+$c7_reason; }file mutated"; }
echo "$c7_err" | grep -qi "edit the file\|tag" || { c7_ok=false; c7_reason="${c7_reason:+$c7_reason; }no tag/edit-the-file guidance in: $c7_err"; }
if [[ "$c7_ok" == "true" ]]; then pass 7 "verb refuses to place a !replace tag"; else fail 7 "tag placement refusal" "$c7_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C8: structural ask (set on a list-of-maps / structural key) -> refuses
#     "edit the file", non-zero, file unchanged.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c8_err=$(run_rc config set auth.credentials something --scope project "$WS" 2>&1); c8_exit=$?
c8_ok=true; c8_reason=""
[[ "$c8_exit" -eq 0 ]] && c8_ok=false && c8_reason="exit 0 (want non-zero — structural set must refuse)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c8_ok=false; c8_reason="${c8_reason:+$c8_reason; }file mutated"; }
echo "$c8_err" | grep -qi "edit the file" || { c8_ok=false; c8_reason="${c8_reason:+$c8_reason; }no 'edit the file' guidance in: $c8_err"; }
if [[ "$c8_ok" == "true" ]]; then pass 8 "structural ask refuses with 'edit the file'"; else fail 8 "structural refusal" "$c8_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C9: post-edit validation failure -> original restored byte-identical +
#     non-zero. `set version 1` writes version: 1, then the loader loud-aborts
#     (declared v1 unsupported) so the engine restores the original.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c9_err=$(run_rc config set version 1 --scope project "$WS" 2>&1); c9_exit=$?
c9_ok=true; c9_reason=""
[[ "$c9_exit" -eq 0 ]] && c9_ok=false && c9_reason="exit 0 (want non-zero — post-edit validation must fail)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c9_ok=false; c9_reason="${c9_reason:+$c9_reason; }original not restored byte-identical"; }
echo "$c9_err" | grep -qi "edit the file" || { c9_ok=false; c9_reason="${c9_reason:+$c9_reason; }no 'edit the file' guidance in: $c9_err"; }
if [[ "$c9_ok" == "true" ]]; then pass 9 "post-edit validation failure restores original byte-identical"; else fail 9 "validation restore" "$c9_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C10: verb on absent project file -> file created with version: 2 and the item.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
cat > "${WS}/expected" <<'YAML'
version: 2
network:
  allowed_hosts:
    - example.com
YAML
c10_err=$(run_rc config add network.allowed_hosts example.com --scope project "$WS" 2>&1); c10_exit=$?
c10_ok=true; c10_reason=""
[[ "$c10_exit" -ne 0 ]] && c10_ok=false && c10_reason="exit $c10_exit; $c10_err"
[[ ! -f "${WS}/.rip-cage.yaml" ]] && c10_ok=false && c10_reason="${c10_reason:+$c10_reason; }file not created"
if [[ "$c10_ok" == "true" ]]; then
  grep -q '^version: 2$' "${WS}/.rip-cage.yaml" || { c10_ok=false; c10_reason="no 'version: 2' in created file"; }
  grep -q 'example.com' "${WS}/.rip-cage.yaml" || { c10_ok=false; c10_reason="${c10_reason:+$c10_reason; }host missing"; }
  diff -u "${WS}/expected" "${WS}/.rip-cage.yaml" >/tmp/c10.diff 2>&1 || { c10_ok=false; c10_reason="${c10_reason:+$c10_reason; }layout: $(cat /tmp/c10.diff)"; }
fi
if [[ "$c10_ok" == "true" ]]; then pass 10 "verb creates absent project file with version: 2"; else fail 10 "absent-file create" "$c10_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C11: remove on mounts.denylist -> refuses citing ADR-023 D2, file unchanged.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c11_err=$(run_rc config remove mounts.denylist .ssh --scope project "$WS" 2>&1); c11_exit=$?
c11_ok=true; c11_reason=""
[[ "$c11_exit" -eq 0 ]] && c11_ok=false && c11_reason="exit 0 (want non-zero — denylist remove must refuse)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c11_ok=false; c11_reason="${c11_reason:+$c11_reason; }file mutated"; }
echo "$c11_err" | grep -q "ADR-023" || { c11_ok=false; c11_reason="${c11_reason:+$c11_reason; }no ADR-023 citation in: $c11_err"; }
if [[ "$c11_ok" == "true" ]]; then pass 11 "remove on mounts.denylist refuses citing ADR-023 D2"; else fail 11 "denylist remove refusal" "$c11_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C12: in-cage invocation -> refused, non-zero (RC_TEST_FAKE_DOCKERENV=1).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c12_err=$(run_rc_in_cage config set mounts.config_mode rw --scope project "$WS" 2>&1); c12_exit=$?
c12_ok=true; c12_reason=""
[[ "$c12_exit" -eq 0 ]] && c12_ok=false && c12_reason="exit 0 (want non-zero — must refuse in-cage)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c12_ok=false; c12_reason="${c12_reason:+$c12_reason; }file mutated in-cage"; }
echo "$c12_err" | grep -qi "host.only\|host-only\|inside.*container\|in-cage\|dockerenv" || {
  c12_ok=false; c12_reason="${c12_reason:+$c12_reason; }no host-only message in: $c12_err"; }
if [[ "$c12_ok" == "true" ]]; then pass 12 "config verb refuses when in-cage (D10 guard)"; else fail 12 "in-cage refusal" "$c12_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C13: rc allowlist add delegation parity — creates version: 2 file + idempotent.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
run_rc allowlist add cdn.example.com --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
c13_exit1=$?
run_rc allowlist add cdn.example.com --config-file "${WS}/.rip-cage.yaml" >/dev/null 2>&1
c13_ok=true; c13_reason=""
[[ "$c13_exit1" -ne 0 ]] && c13_ok=false && c13_reason="first add exit $c13_exit1"
grep -q '^version: 2$' "${WS}/.rip-cage.yaml" || { c13_ok=false; c13_reason="${c13_reason:+$c13_reason; }created file lacks 'version: 2'"; }
c13_count=$(grep -c 'cdn.example.com' "${WS}/.rip-cage.yaml" 2>/dev/null || echo 0)
[[ "$c13_count" -ne 1 ]] && c13_ok=false && c13_reason="${c13_reason:+$c13_reason; }host appears $c13_count times (want 1 — idempotency broken)"
if [[ "$c13_ok" == "true" ]]; then pass 13 "allowlist add delegates to shared write path (version: 2 + idempotent)"; else fail 13 "allowlist add parity" "$c13_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C14: newline/CR injection in the value/item is refused BEFORE any dispatch
# -- a value carrying an embedded '\n' + fake YAML structure must never be
# spliced in verbatim (that would let a single scalar value inject an
# arbitrary top-level key). Direct `rc config add` path.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c14_payload=$'z.com\nmounts:\n  config_mode: rw'
c14_err=$(run_rc config add network.allowed_hosts "$c14_payload" --scope project "$WS" 2>&1); c14_exit=$?
c14_ok=true; c14_reason=""
[[ "$c14_exit" -eq 0 ]] && c14_ok=false && c14_reason="exit 0 (want non-zero -- newline injection must refuse)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c14_ok=false; c14_reason="${c14_reason:+$c14_reason; }file mutated by newline-injection payload"; }
echo "$c14_err" | grep -qi "newline\|carriage return" || { c14_ok=false; c14_reason="${c14_reason:+$c14_reason; }no newline-specific message in: $c14_err"; }
if [[ "$c14_ok" == "true" ]]; then pass 14 "config add refuses a value containing a newline (injection guard)"; else fail 14 "newline injection direct" "$c14_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C15: same newline-injection guard reached via the `rc allowlist add`
# delegated path (both callers route through the single _config_edit_apply
# write path) -- absent file must NOT be created at all.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
c15_payload=$'z.com\nmounts:\n  config_mode: rw'
c15_err=$(run_rc allowlist add "$c15_payload" --config-file "${WS}/.rip-cage.yaml" 2>&1); c15_exit=$?
c15_ok=true; c15_reason=""
[[ "$c15_exit" -eq 0 ]] && c15_ok=false && c15_reason="exit 0 (want non-zero -- newline injection must refuse)"
[[ -e "${WS}/.rip-cage.yaml" ]] && { c15_ok=false; c15_reason="${c15_reason:+$c15_reason; }file was created by a newline-injection payload"; }
echo "$c15_err" | grep -qi "newline\|carriage return" || { c15_ok=false; c15_reason="${c15_reason:+$c15_reason; }no newline-specific message in: $c15_err"; }
if [[ "$c15_ok" == "true" ]]; then pass 15 "allowlist add (delegated) refuses a newline-carrying host, no file created"; else fail 15 "newline injection delegated" "$c15_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C16: add on a NON-EMPTY flow-style list (`key: !tag [a, b]` all on one
# line) refuses -- the only defined flow transform is the EMPTY-list ([])
# case; a non-empty flow list must never be block-inserted-under (that would
# corrupt the YAML). File must remain byte-identical.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
cat > "${WS}/.rip-cage.yaml" <<'YAML'
version: 2
dcg:
  custom_rule_paths: !replace [/a.yaml, /b.yaml]
YAML
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c16_err=$(run_rc config add dcg.custom_rule_paths /c.yaml --scope project "$WS" 2>&1); c16_exit=$?
c16_ok=true; c16_reason=""
[[ "$c16_exit" -eq 0 ]] && c16_ok=false && c16_reason="exit 0 (want non-zero -- non-empty flow list add must refuse)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c16_ok=false; c16_reason="${c16_reason:+$c16_reason; }file mutated (possibly corrupted YAML)"; }
if [[ "$c16_ok" == "true" ]]; then
  # The file must still be valid, parseable YAML (didn't get corrupted then
  # silently accepted) -- belt-and-suspenders on top of the byte-identical check.
  yq '.' "${WS}/.rip-cage.yaml" >/dev/null 2>&1 || { c16_ok=false; c16_reason="file no longer parses as valid YAML"; }
fi
if [[ "$c16_ok" == "true" ]]; then pass 16 "add on a non-empty flow-style list refuses, file byte-identical"; else fail 16 "non-empty flow list add" "$c16_reason -- $c16_err"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C17: set on a scalar whose CURRENT value contains a space refuses cleanly
# (the surgical single-token regex can't safely locate the value's end) --
# rather than silently truncating the old value and corrupting the line, as
# `/has a space/path` -> `/new/clean a space/path` did before the fix.
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
cat > "${WS}/.rip-cage.yaml" <<'YAML'
version: 2
auth:
  placeholder_env_file: /has a space/path
YAML
cp "${WS}/.rip-cage.yaml" "${WS}/before"
c17_err=$(run_rc config set auth.placeholder_env_file /new/clean/path --scope project "$WS" 2>&1); c17_exit=$?
c17_ok=true; c17_reason=""
[[ "$c17_exit" -eq 0 ]] && c17_ok=false && c17_reason="exit 0 (want non-zero -- ambiguous current-value shape must refuse)"
cmp -s "${WS}/before" "${WS}/.rip-cage.yaml" || { c17_ok=false; c17_reason="${c17_reason:+$c17_reason; }file mutated/corrupted (space-in-value truncation bug)"; }
if [[ "$c17_ok" == "true" ]]; then pass 17 "set refuses when the current scalar value contains a space (no truncation corruption)"; else fail 17 "scalar-with-space set" "$c17_reason -- $c17_err"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
# C18: rc config add is idempotent like rc allowlist add -- adding the same
# item twice leaves the file byte-identical after the second call and exits
# 0 (no duplicate line accumulation).
# ---------------------------------------------------------------------------
TOTAL=$((TOTAL + 1)); setup_sandbox
write_fixture "${WS}/.rip-cage.yaml"
run_rc config add dcg.packs pnpm --scope project "$WS" >/dev/null 2>&1
cp "${WS}/.rip-cage.yaml" "${WS}/after_first"
c18_err=$(run_rc config add dcg.packs pnpm --scope project "$WS" 2>&1); c18_exit=$?
c18_ok=true; c18_reason=""
[[ "$c18_exit" -ne 0 ]] && c18_ok=false && c18_reason="second add exit $c18_exit; $c18_err"
cmp -s "${WS}/after_first" "${WS}/.rip-cage.yaml" || { c18_ok=false; c18_reason="${c18_reason:+$c18_reason; }file changed on idempotent re-add (duplicate line?)"; }
c18_count=$(grep -c '^\s*- pnpm$' "${WS}/.rip-cage.yaml" 2>/dev/null || echo 0)
[[ "$c18_count" -ne 1 ]] && c18_ok=false && c18_reason="${c18_reason:+$c18_reason; }pnpm appears $c18_count times (want 1)"
if [[ "$c18_ok" == "true" ]]; then pass 18 "config add is idempotent (re-add is a no-op success, no duplicate line)"; else fail 18 "config add idempotency" "$c18_reason"; fi
teardown_sandbox

# ---------------------------------------------------------------------------
echo ""
if [[ "$FAILURES" -gt 0 ]]; then
  echo "FAILED: $FAILURES of $TOTAL tests"
  exit 1
fi
echo "All $TOTAL tests passed."
