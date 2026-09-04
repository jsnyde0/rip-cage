#!/usr/bin/env bash
# tests/test-real-home-pi-write-guard.sh -- recurrence guard for rip-cage-bh0r.
#
# ROOT CAUSE this guards against (rip-cage-bh0r, 2026-09-04): a test derived
# PI_AGENT_DIR="${HOME}/.pi/agent" -- the LIVE host path, unsandboxed -- and
# then wrote into it (printf redirect, mv-aside). On a host where
# ~/.pi/agent/AGENTS.md is a symlink into a sibling checkout (dotpi), the
# write followed the symlink and clobbered that repo's tracked file (85
# lines lost). The cp -a/mv "backup" the test ran first was never a
# sandbox: cp -a copies the SYMLINK, not its target, so restoring it puts
# the symlink back while the already-clobbered target stays clobbered. The
# fix (test-pi-cage-context.sh, test-pi-auth-mount.sh already had it via
# rip-cage-7atw.3) is to point $HOME at a throwaway mktemp dir BEFORE
# deriving any ${HOME}/.pi path -- this guard is the recurrence check that
# makes that fix stick.
#
# HOST-ONLY: pure static text analysis of tests/*.sh. No docker, no msb, no
# live cage, no network -- passes on a machine with nothing installed.
#
# THE RULE (keyed on the CAUSE -- a write reaching a path under the REAL,
# unsandboxed $HOME -- never on a surface shape like "the string .pi
# appears"): a WRITE-shaped operation (output redirection, mv, rm -f/-r,
# tee, ln -s) that targets a path derived from literal ${HOME}/.pi or
# $HOME/.pi (directly, or via a same-file variable chased up to 3 levels of
# indirection) is a LEAK unless the file assigns HOME itself (a sandbox
# override, `HOME=...` or `export HOME=...`) at a line number STRICTLY
# BEFORE the risky derivation. A read-only use (existence check, cat,
# python open() for read, realpath, grep) is never flagged -- this guard
# only recognizes a fixed WRITE-operator vocabulary, so
# test-agent-mail-concurrent.sh / test-pi-e2e.sh / test-multiplexer-agent-e2e.sh
# (all `[[ -f "${HOME}/.pi/agent/auth.json" ]]` existence checks) stay
# clean, and a TEST_HOME-named variable (a DIFFERENT var, not $HOME) is
# never matched by the ${HOME}/.pi pattern at all.
#
# SCOPE: files that already sandbox their own $HOME (test-credential-mounts.sh,
# test-pi-substrate-mounts.sh, test-symlink-follow.sh -- all via a
# TEST_HOME/NOEXT_HOME variable, never literal $HOME) are unaffected: this
# guard only ever matches the literal $HOME/${HOME} token, never a
# differently-named variable that merely contains "HOME" as a substring.
#
# Exit: $FAILURES (silent-red guard per rip-cage-test-fail-prose-without-exit-silent-red).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0
PASS_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "  $2"; FAILURES=$((FAILURES + 1)); }

echo "=== test-real-home-pi-write-guard.sh ==="

# scan_dir_for_leaks <dir> -- populates the WRITE_LEAKS array (global) with
# one "relpath:line: trimmed-text" entry per offending write found in
# <dir>/*.sh that targets a real, unsandboxed $HOME/.pi path.
scan_dir_for_leaks() {
  local dir="$1"
  WRITE_LEAKS=()
  local f
  for f in "$dir"/*.sh; do
    [[ -f "$f" ]] || continue
    _scan_one_file "$f"
  done
}

# Pattern constants (kept in variables per bash-regex best practice -- an
# unquoted literal ERE inline in `[[ =~ ]]` is subject to word-splitting).
# All per-line matching below uses bash's own regex engine, never a
# subprocess: tests/*.sh is ~63k lines combined, and spawning grep/sed per
# line (the first draft of this guard did) made the real scan in Case 2
# take unacceptably long. One `grep -n` per file to gather candidates is
# still fine -- that is a handful of processes per file, not per line.
_RE_COMMENT='^[[:space:]]*#'
_RE_ASSIGN='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)='
_RE_HOME_PI='\$\{?HOME\}?/\.pi'
_RE_MV_TEE='(^|[;&|({`])[[:space:]]*(mv|tee)[[:space:]]'
_RE_RM_F='(^|[;&|({`])[[:space:]]*rm[[:space:]]+-[a-zA-Z]*[fF]'
_RE_LN_S='(^|[;&|({`])[[:space:]]*ln[[:space:]]+-[a-zA-Z]*s'

_scan_one_file() {
  local f="$1"
  local base
  base=$(basename "$f")

  # --- Earliest HOME (re)assignment line in this file. A sentinel of
  # 999999999 means "never overridden" -- nothing in the file can be
  # sandboxed, so every literal ${HOME}/.pi derivation/use is risky. ---
  local home_override_line
  home_override_line=$(grep -nE '(^|[;&|({`])[[:space:]]*(export[[:space:]]+)?HOME=' "$f" 2>/dev/null | head -1 | cut -d: -f1)
  [[ -z "$home_override_line" ]] && home_override_line=999999999

  # --- Root risky-var derivations: VAR=...${HOME}/.pi... or $HOME/.pi,
  # tagged with the line number of that literal derivation (the line whose
  # execution-time value of $HOME actually gets baked into VAR). Narrowed
  # by an upfront grep to just the candidate lines. ---
  local -A risky_line=()
  local lineno line var
  while IFS=: read -r lineno line; do
    [[ "$line" =~ $_RE_COMMENT ]] && continue
    [[ "$line" =~ $_RE_ASSIGN ]] || continue
    var="${BASH_REMATCH[1]}"
    [[ -z "${risky_line[$var]:-}" ]] && risky_line["$var"]="$lineno"
  done < <(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*\$\{?HOME\}?/\.pi' "$f" 2>/dev/null)

  # --- Propagate through same-file variable chains (up to 3 hops -- covers
  # every real shape seen so far: PI_AGENT_DIR -> AGENTS_MD_PATH, and a
  # theoretical one more level of indirection). A derived var inherits the
  # LINE of the root literal derivation it ultimately traces back to (that
  # is what determines whether $HOME had already been sandboxed). Skipped
  # entirely for the (overwhelmingly common) case of zero root vars. ---
  local _hop
  for _hop in 1 2 3; do
    [[ "${#risky_line[@]}" -eq 0 ]] && break
    while IFS=: read -r lineno line; do
      [[ "$line" =~ $_RE_COMMENT ]] && continue
      [[ "$line" =~ $_RE_ASSIGN ]] || continue
      var="${BASH_REMATCH[1]}"
      [[ -n "${risky_line[$var]:-}" ]] && continue
      local ref re_ref
      for ref in "${!risky_line[@]}"; do
        re_ref="\\\$\\{${ref}\\}|\\\$${ref}([^A-Za-z0-9_]|\$)"
        if [[ "$line" =~ $re_ref ]]; then
          risky_line["$var"]="${risky_line[$ref]}"
          break
        fi
      done
    done < <(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$f" 2>/dev/null)
  done

  # --- Walk every candidate line (pre-filtered to those containing a `>`
  # or one of the write-command keywords -- cuts the per-line bash-regex
  # work down from "every line in the file" to "every line that could
  # possibly be a write") looking for a WRITE-shaped operation that
  # targets either a literal ${HOME}/.pi (checked at THAT line's own
  # position vs. the override, since $HOME expands at execution time) or a
  # risky variable (checked at ITS OWN derivation line vs. the override,
  # since the variable's value was already frozen then). ---
  while IFS=: read -r lineno line; do
    [[ "$line" =~ $_RE_COMMENT ]] && continue

    local flagged=0

    # Redirection (> / >>): the risky reference must appear IMMEDIATELY
    # after a > (only whitespace/an optional opening quote in between) --
    # i.e. actually be the redirection target, not merely appear somewhere
    # later on the line. This is what excludes read-only lines that
    # legitimately carry an unrelated `2>/dev/null` earlier or later on the
    # same line alongside a risky reference used as a READ argument (e.g.
    # the common `stat -f ... "$PATH" 2>/dev/null || stat -c ... "$PATH"
    # 2>/dev/null` fallback idiom -- a naive "everything after the first >"
    # substring check flagged this as a false positive while this guard
    # was being built: the first `>` is the unrelated `2>/dev/null`, and
    # the text after it still contains a second, purely-read, occurrence
    # of the path).
    if [[ "$line" == *'>'* ]]; then
      local re_redir_literal='[>]{1,2}[[:space:]]*"?'"$_RE_HOME_PI"
      if [[ "$line" =~ $re_redir_literal ]] && [[ "$lineno" -le "$home_override_line" ]]; then
        flagged=1
      fi
      local var re_var
      for var in "${!risky_line[@]}"; do
        re_var='[>]{1,2}[[:space:]]*"?(\$\{'"${var}"'\}|\$'"${var}"'([^A-Za-z0-9_]|$))'
        if [[ "$line" =~ $re_var ]] && [[ "${risky_line[$var]}" -le "$home_override_line" ]]; then
          flagged=1
        fi
      done
    fi

    # mv / rm -f|-r / tee / ln -s -- these take the risky path as a direct
    # positional argument (no redirection ambiguity), so any occurrence
    # anywhere on the line counts.
    if [[ "$line" =~ $_RE_MV_TEE ]] || [[ "$line" =~ $_RE_RM_F ]] || [[ "$line" =~ $_RE_LN_S ]]; then
      if [[ "$line" =~ $_RE_HOME_PI ]] && [[ "$lineno" -le "$home_override_line" ]]; then
        flagged=1
      fi
      local var re_var
      for var in "${!risky_line[@]}"; do
        re_var="\\\$\\{${var}\\}|\\\$${var}([^A-Za-z0-9_]|\$)"
        if [[ "$line" =~ $re_var ]] && [[ "${risky_line[$var]}" -le "$home_override_line" ]]; then
          flagged=1
        fi
      done
    fi

    if [[ "$flagged" -eq 1 ]]; then
      local trimmed="${line#"${line%%[![:space:]]*}"}"
      WRITE_LEAKS+=("${base}:${lineno}: ${trimmed}")
    fi
  done < <(grep -nE '>|(^|[;&|({`])[[:space:]]*(mv|rm|tee|ln)[[:space:]]' "$f" 2>/dev/null)
}

# ============================================================================
# Case 1: NEGATIVE CONTROL + POSITIVE (clean) fixtures.
#
# A guard with no proof it can fail is worthless. This writes a throwaway
# set of fixtures into a temp dir, scans ONLY that temp dir, and asserts
# the detector reds on every leaking shape and stays green on every clean
# one.
# ============================================================================
echo ""
echo "--- Case 1: detector self-test (negative control + clean fixtures) ---"

FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rc-home-pi-guard-selftest-XXXXXX")
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# 1a. LEAKING: direct literal derivation + write, no sandbox at all --
# mirrors the pre-fix test-pi-cage-context.sh:62/76 shape exactly.
cat > "${FIXTURE_DIR}/test-fixture-leaking-direct.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
PI_AGENT_DIR="${HOME}/.pi/agent"
mkdir -p "$PI_AGENT_DIR"
printf 'sentinel\n' > "${PI_AGENT_DIR}/AGENTS.md"
FIXEOF

# 1b. LEAKING: two-level variable chase (VAR1 -> VAR2 -> write) -- the
# EXACT shape of the real incident (PI_AGENT_DIR -> AGENTS_MD_PATH).
cat > "${FIXTURE_DIR}/test-fixture-leaking-chained.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
PI_AGENT_DIR="${HOME}/.pi/agent"
AGENTS_MD_PATH="${PI_AGENT_DIR}/AGENTS.md"
printf 'sentinel\n' > "$AGENTS_MD_PATH"
FIXEOF

# 1c. LEAKING: mv of the risky var aside (Test-7/Test-6 mount-absent shape).
cat > "${FIXTURE_DIR}/test-fixture-leaking-mv.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
PI_AGENT_DIR="${HOME}/.pi/agent"
mv "$PI_AGENT_DIR" "${PI_AGENT_DIR}.bak-test"
FIXEOF

# 1d. LEAKING: direct inline literal on a write line, no variable at all.
cat > "${FIXTURE_DIR}/test-fixture-leaking-inline.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
mv "${HOME}/.pi/agent" "${HOME}/.pi/agent.bak-test"
FIXEOF

# 1e. CLEAN: HOME sandboxed via mktemp BEFORE the derivation -- the actual
# fix shape (test-pi-auth-mount.sh / post-fix test-pi-cage-context.sh).
cat > "${FIXTURE_DIR}/test-fixture-clean-sandboxed.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
export HOME="$(mktemp -d)"
PI_AGENT_DIR="${HOME}/.pi/agent"
AGENTS_MD_PATH="${PI_AGENT_DIR}/AGENTS.md"
mkdir -p "$PI_AGENT_DIR"
printf 'sentinel\n' > "$AGENTS_MD_PATH"
FIXEOF

# 1f. CLEAN: read-only existence check, no sandbox needed -- mirrors
# test-agent-mail-concurrent.sh:110 / test-pi-e2e.sh:40 /
# test-multiplexer-agent-e2e.sh:285 (all confirmed read-only, rip-cage-bh0r).
cat > "${FIXTURE_DIR}/test-fixture-clean-readonly.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
PI_AUTH_FILE="${HOME}/.pi/agent/auth.json"
if [[ ! -f "$PI_AUTH_FILE" ]]; then
  echo "skip"
fi
cat "$PI_AUTH_FILE" 2>/dev/null
FIXEOF

# 1g. CLEAN: a DIFFERENTLY-NAMED variable (TEST_HOME, not HOME) must never
# false-positive -- mirrors test-credential-mounts.sh / test-symlink-follow.sh.
cat > "${FIXTURE_DIR}/test-fixture-clean-testhome.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
TEST_HOME=$(mktemp -d)
PI_AGENT_DIR="${TEST_HOME}/.pi/agent"
mkdir -p "$PI_AGENT_DIR"
printf 'sentinel\n' > "${PI_AGENT_DIR}/AGENTS.md"
FIXEOF

# 1h. CLEAN: prose/comment mention only, never a real write line.
cat > "${FIXTURE_DIR}/test-fixture-prose-only.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
# doc note: printf > "${HOME}/.pi/agent/AGENTS.md" would clobber dotpi
reason="a write to \${HOME}/.pi/agent must never happen unsandboxed"
echo "$reason"
FIXEOF

# 1i. CLEAN: the real false positive caught while building this guard --
# an unrelated `2>/dev/null` fallback idiom (`stat -f ... || stat -c ...`)
# on the same line as a purely-READ risky-var reference. A naive "text
# after the first >" substring check flagged this; the fix requires the
# risky reference to appear IMMEDIATELY after a >, not merely later on the
# line. Mirrors the actual line found live in test-pi-cage-context.sh
# (AGENTS_MTIME_BEFORE/_AFTER).
cat > "${FIXTURE_DIR}/test-fixture-clean-stat-fallback-readonly.sh" <<'FIXEOF'
#!/usr/bin/env bash
set -uo pipefail
PI_AGENT_DIR="${HOME}/.pi/agent"
AGENTS_MD_PATH="${PI_AGENT_DIR}/AGENTS.md"
AGENTS_MTIME=$(stat -f '%m' "$AGENTS_MD_PATH" 2>/dev/null || stat -c '%Y' "$AGENTS_MD_PATH" 2>/dev/null || true)
FIXEOF

scan_dir_for_leaks "$FIXTURE_DIR"

_direct_flagged=0 _chained_flagged=0 _mv_flagged=0 _inline_flagged=0
_clean_flagged=""
for _entry in "${WRITE_LEAKS[@]+"${WRITE_LEAKS[@]}"}"; do
  case "$_entry" in
    test-fixture-leaking-direct.sh:*) _direct_flagged=1 ;;
    test-fixture-leaking-chained.sh:*) _chained_flagged=1 ;;
    test-fixture-leaking-mv.sh:*) _mv_flagged=1 ;;
    test-fixture-leaking-inline.sh:*) _inline_flagged=1 ;;
    test-fixture-clean-*|test-fixture-prose-only.sh:*) _clean_flagged="${_clean_flagged}${_entry}; " ;;
  esac
done

if [[ "$_direct_flagged" -eq 1 ]]; then
  pass "negative control: unsandboxed direct derivation + write is flagged (proves the detector can fail)"
else
  fail "negative control: unsandboxed direct derivation + write was NOT flagged -- detector is not red-capable"
fi

if [[ "$_chained_flagged" -eq 1 ]]; then
  pass "negative control: the real incident's two-level variable chain (VAR1 -> VAR2 -> write) is flagged"
else
  fail "negative control: a chained (VAR1 -> VAR2) derivation escaped detection -- misses the actual rip-cage-bh0r shape"
fi

if [[ "$_mv_flagged" -eq 1 ]]; then
  pass "negative control: an unsandboxed mv of the risky var is flagged"
else
  fail "negative control: mv of an unsandboxed risky var was NOT flagged"
fi

if [[ "$_inline_flagged" -eq 1 ]]; then
  pass "negative control: a direct inline \${HOME}/.pi write (no intermediate variable) is flagged"
else
  fail "negative control: inline literal write escaped detection"
fi

if [[ -z "$_clean_flagged" ]]; then
  pass "positive controls: sandboxed / read-only / differently-named-var / prose-only fixtures are all correctly left clean"
else
  fail "positive controls: detector false-positived on a correctly-safe fixture" "$_clean_flagged"
fi

rm -rf "$FIXTURE_DIR"
trap - EXIT

# ============================================================================
# Case 2: REAL SCAN of tests/*.sh -- the actual recurrence guard.
# ============================================================================
echo ""
echo "--- Case 2: live scan of tests/*.sh for unsandboxed \$HOME/.pi writes ---"

scan_dir_for_leaks "$SCRIPT_DIR"

if [[ "${#WRITE_LEAKS[@]}" -eq 0 ]]; then
  pass "live scan: zero unsandboxed \$HOME/.pi write(s) found under tests/*.sh"
else
  fail "live scan: ${#WRITE_LEAKS[@]} unsandboxed \$HOME/.pi write(s) found -- each risks clobbering the operator's real ~/.pi/agent (rip-cage-bh0r)" \
       "fix: sandbox \$HOME via a throwaway mktemp dir (export HOME=\$(mktemp -d)) BEFORE deriving any \${HOME}/.pi path -- see test-pi-auth-mount.sh / test-pi-cage-context.sh for the working pattern"
  for _entry in "${WRITE_LEAKS[@]}"; do
    echo "  LEAK: ${_entry}"
  done
fi

echo ""
echo "=== test-real-home-pi-write-guard.sh: PASS=$PASS_COUNT FAIL=$FAILURES ==="

exit "$FAILURES"
