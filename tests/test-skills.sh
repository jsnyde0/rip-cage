#!/usr/bin/env bash
# test-skills.sh — validates skill discovery inside rip-cage containers
#
# MCP server (skill-server.py) is the only supported skill discovery path.
# The script checks for mcpServers["meta-skill"] in settings.json and runs the
# MCP protocol smoke test (initialize → tools/list → tools/call list).
#
# If mcpServers["meta-skill"] is not configured, all MCP tests fail with a
# clear error — there is no fallback filesystem path.
#
# Run directly: docker exec <container> /usr/local/lib/rip-cage/test-skills.sh
# Or via:       rc test <container>  (if called by test-safety-stack.sh)
#
# Runs on the host too (tests/run-host.sh) — this file is single-sourced:
# cli/test.sh already invokes it in-cage as
# /usr/local/lib/rip-cage/test-skills.sh, so a second host-only copy would
# fork coverage that is already runnable. Instead the cage-only tier (checks
# probing /usr/local/lib/rip-cage/skill-server.py, the ~/.claude/agents
# in-cage symlink projection, and the shipped /etc/rip-cage/settings.json
# baseline) self-skips on the host with a "SKIP (cage-only): ..." line naming
# the missing prerequisite; the host-valid checks still run and must still
# pass (rip-cage-dovx).

set -euo pipefail

# Source agent-readability classification helpers.
# The helper lives next to this script; resolve relative to BASH_SOURCE so this
# works whether invoked as a path or via `docker exec ... /path/test-skills.sh`.
_TS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=./_agent-readability.sh
# shellcheck disable=SC1091
source "${_TS_DIR}/_agent-readability.sh"

# In-cage detection (rip-cage-dovx). /etc/rip-cage/release is the repo-wide
# canonical in-cage sentinel (rc:54 itself hard-exits on it, ADR-002 D14 /
# rip-cage-r5f9; test-auth-refresh.sh, test-rc-allowlist.sh gate the same
# way, and the broken-symlink check below already used this exact test
# before this variable existed).
_TS_IN_CAGE=false
[[ -f /etc/rip-cage/release ]] && _TS_IN_CAGE=true

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

# skip_check: ledgers a cage-only check as SKIP on the host instead of
# probing a path/process that only exists inside a cage. Does NOT touch
# PASS/FAIL/TOTAL — it never ran, so it isn't a pass or a fail. The line
# shape ("SKIP (cage-only): ...") matches tests/run-host.sh's body-decided
# SKIP sentinel ('^SKIP[[:space:]:(]') so a suite run classifies it
# correctly once this worktree picks up that classifier (rip-cage-pow0).
skip_check() {
  local name="$1" reason="$2"
  echo "SKIP (cage-only): ${name} — ${reason}"
}

echo "=== Skills Discovery Check ==="
echo ""
echo "-- Skill Files --"

skills_dir="${HOME}/.claude/skills"

# 1. ~/.claude/skills/ directory exists (directory or symlink to directory)
check "\$HOME/.claude/skills/ exists" "$([[ -d "${skills_dir}" ]] && echo pass || echo fail)"

# 2. At least one SKILL.md present
# NOTE: find counts broken symlinks as matches, but skill-server.py skips them.
# This check can pass (find count > 0) while the MCP server serves 0 skills.
# Use the MCP list response below for the authoritative skill count.
#
# PRESENCE-GATED on what the HOST staged (rip-cage-ely4.7.5), the same shape
# test-safety-stack.sh check 8 uses for recipe-provisioned artifacts. A cage
# for a project with no skills is a valid cage: nothing staged means there is
# no property to hold, so that reports INFO, not FAIL. The case still bites
# where it was meant to — skills WERE staged (the directory has entries) but
# none of them resolves to a readable SKILL.md, which is the broken-projection
# regression, not an empty-by-design cage.
skill_count=0
if [[ ! -d "${skills_dir}" ]]; then
  TOTAL=$((TOTAL + 1))
  echo "INFO  [$TOTAL] skills dir absent (${skills_dir}) — skills are staged by the host into .rc-context/skills before the cage boots; this project staged none"
else
  skill_count=$(find -L "${skills_dir}" -name 'SKILL.md' -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
  skills_dir_entries=$(find "${skills_dir}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${skill_count}" -gt 0 ]]; then
    check "At least one skill present" "pass" "${skill_count} skill(s)"
  elif [[ "${skills_dir_entries}" -gt 0 ]]; then
    check "At least one skill present" "fail" \
      "${skills_dir_entries} entr(ies) staged under ${skills_dir} but none resolves to a readable SKILL.md"
  else
    TOTAL=$((TOTAL + 1))
    echo "INFO  [$TOTAL] no skills present — ${skills_dir} is empty; skills are staged by the host into .rc-context/skills before the cage boots, and this project staged none"
  fi
  unset skills_dir_entries
fi

# 3. Skill files readable (not root-owned or permission-denied)
if [[ "${skill_count}" -gt 0 ]]; then
  first_skill=$(find -L "${skills_dir}" -name 'SKILL.md' -maxdepth 2 2>/dev/null | head -1)
  if [[ -r "${first_skill}" ]]; then
    skill_name=$(basename "$(dirname "${first_skill}")")
    check "Skill files readable" "pass" "${skill_name}/SKILL.md"
  else
    check "Skill files readable" "fail" "permission denied: ${first_skill}"
  fi
else
  check "Skill files readable" "pass" "no skills to check (skipped)"
fi

echo ""

# Detect discovery mode from settings.json
mcp_configured=false
if [[ -f "${HOME}/.claude/settings.json" ]] && \
   jq -e '.mcpServers["meta-skill"]' "${HOME}/.claude/settings.json" >/dev/null 2>&1; then
  mcp_configured=true
fi

if "${mcp_configured}"; then
  # -----------------------------------------------------------------------
  # Branch B: Python MCP server
  # -----------------------------------------------------------------------
  echo "-- MCP Skill Server (Branch B) --"

  server_py="/usr/local/lib/rip-cage/skill-server.py"

  if ! $_TS_IN_CAGE; then
    # 4-7. skill-server.py and the live MCP protocol handshake only exist
    # inside a cage (/usr/local/lib/rip-cage/skill-server.py is baked into
    # the image, not present on the host) — self-skip rather than false-FAIL.
    skip_check "skill-server.py exists" "cage-only path ${server_py} — run inside a rip-cage container (rc test <cage> or docker exec ... test-skills.sh)"
    skip_check "MCP initialize handshake" "requires the in-cage skill-server.py — run inside a rip-cage container"
    skip_check "MCP tools/list exposes list tool" "requires the in-cage skill-server.py — run inside a rip-cage container"
    skip_check "MCP tools/call list returns skills" "requires the in-cage skill-server.py — run inside a rip-cage container"
  else

    # 4. skill-server.py exists
    check "skill-server.py exists" "$([[ -f "${server_py}" ]] && echo pass || echo fail)" "${server_py}"

    # 5-7. Full MCP protocol exchange: initialize → tools/list → tools/call list
    if [[ -f "${server_py}" ]]; then
      # Write a temp Python test script — avoids heredoc-inside-heredoc quoting issues
      tmp_py=$(mktemp /tmp/mcp-test-XXXXXX)
      cat > "${tmp_py}" << 'PYTHON'
#!/usr/bin/env python3
"""
MCP protocol smoke test for skill-server.py.
Runs three turns: initialize, tools/list, tools/call list.
Prints structured tags that bash can grep for.
"""
import subprocess
import json
import sys
import os

server_py = sys.argv[1]

try:
    proc = subprocess.Popen(
        [sys.executable, server_py],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def rpc(proc, method, params, id):
        msg = json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        proc.stdin.write(msg + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        return json.loads(line) if line.strip() else None

    # Turn 1: initialize
    r = rpc(proc, "initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "0.0.1"},
    }, id=1)
    if not r or "result" not in r:
        print(f"INIT_FAIL: unexpected response: {r}")
        proc.terminate()
        sys.exit(1)
    server_name = r["result"].get("serverInfo", {}).get("name", "unknown")
    protocol = r["result"].get("protocolVersion", "?")
    print(f"INIT_OK server={server_name} protocol={protocol}")

    # Turn 2: tools/list — verify "list" tool is exposed
    r = rpc(proc, "tools/list", {}, id=2)
    if not r or "result" not in r:
        print(f"TOOLS_FAIL: unexpected response: {r}")
        proc.terminate()
        sys.exit(1)
    tool_names = [t["name"] for t in r["result"].get("tools", [])]
    if "list" not in tool_names:
        print(f"TOOLS_FAIL: 'list' tool missing, got: {tool_names}")
        proc.terminate()
        sys.exit(1)
    print(f"TOOLS_OK count={len(tool_names)} names={','.join(tool_names[:5])}")

    # Turn 3: tools/call list — verify skills are returned
    r = rpc(proc, "tools/call", {"name": "list", "arguments": {}}, id=3)
    proc.terminate()
    if not r or "result" not in r:
        print(f"LIST_FAIL: unexpected response: {r}")
        sys.exit(1)
    content = r["result"].get("content", [])
    if not content:
        print("LIST_FAIL: empty content — no skills returned")
        sys.exit(1)
    # Extract skill names from text content (server returns JSON or text)
    print(f"LIST_OK count={len(content)}")

except Exception as e:
    print(f"EXCEPTION: {e}")
    sys.exit(1)
PYTHON

      mcp_result=$(python3 "${tmp_py}" "${server_py}" 2>&1 || true)
      rm -f "${tmp_py}"

      # Parse tagged output
      if echo "${mcp_result}" | grep -q "^INIT_OK"; then
        detail=$(echo "${mcp_result}" | grep "^INIT_OK" | sed 's/^INIT_OK //')
        check "MCP initialize handshake" "pass" "${detail}"
      else
        detail=$(echo "${mcp_result}" | grep "^INIT_FAIL\|^EXCEPTION" | head -1 | sed 's/^[^:]*: //')
        check "MCP initialize handshake" "fail" "${detail:-no response}"
      fi

      if echo "${mcp_result}" | grep -q "^TOOLS_OK"; then
        detail=$(echo "${mcp_result}" | grep "^TOOLS_OK" | sed 's/^TOOLS_OK //')
        check "MCP tools/list exposes list tool" "pass" "${detail}"
      else
        detail=$(echo "${mcp_result}" | grep "^TOOLS_FAIL\|^EXCEPTION" | head -1 | sed 's/^[^:]*: //')
        check "MCP tools/list exposes list tool" "fail" "${detail:-no response}"
      fi

      if echo "${mcp_result}" | grep -q "^LIST_OK"; then
        detail=$(echo "${mcp_result}" | grep "^LIST_OK" | sed 's/^LIST_OK //')
        check "MCP tools/call list returns skills" "pass" "${detail}"
      else
        detail=$(echo "${mcp_result}" | grep "^LIST_FAIL\|^EXCEPTION" | head -1 | sed 's/^[^:]*: //')
        check "MCP tools/call list returns skills" "fail" "${detail:-no response}"
      fi
    else
      # skill-server.py missing — fail the remaining MCP tests explicitly
      check "MCP initialize handshake" "fail" "skill-server.py not found"
      check "MCP tools/list exposes list tool" "fail" "skill-server.py not found"
      check "MCP tools/call list returns skills" "fail" "skill-server.py not found"
    fi

  fi # _TS_IN_CAGE (checks 4-7)

  # 8. settings.json registers server as "meta-skill" (ADR-002 D18: name matches host)
  # Host-valid: reads the same real ~/.claude/settings.json on both host and cage.
  if jq -e '.mcpServers["meta-skill"]' "${HOME}/.claude/settings.json" >/dev/null 2>&1; then
    check "MCP server registered as meta-skill" "pass" "meta-skill found in mcpServers"
  else
    check "MCP server registered as meta-skill" "fail" "meta-skill not found in mcpServers"
  fi

else
  # Branch A (native filesystem discovery) is eliminated — Claude Code requires the MCP server.
  # If we reach here, mcpServers["meta-skill"] is not configured and skill discovery will not work.
  echo "-- MCP Skill Server (Branch B) -- MISSING CONFIGURATION --"
  echo ""
  check "MCP server configured (meta-skill)" "fail" \
    "mcpServers.meta-skill not configured — skill discovery will not work"
  check "MCP initialize handshake" "fail" "no MCP server configured"
  check "MCP tools/list exposes list tool" "fail" "no MCP server configured"
  check "MCP tools/call list returns skills" "fail" "no MCP server configured"
fi

echo ""
echo "=== Agent Directory Check ==="
echo ""

agents_dir="${HOME}/.claude/agents"

# 9. ~/.claude/agents/ symlink exists and points to .rc-context/agents
# Cage-only: in-cage init projects ~/.claude/agents as a symlink into
# .rc-context/agents; on the host ~/.claude/agents (if present at all) is a
# real directory belonging to the host's own Claude Code install.
if $_TS_IN_CAGE; then
  if [[ -L "${agents_dir}" ]]; then
    link_target=$(readlink "${agents_dir}")
    if [[ "${link_target}" == *".rc-context/agents"* ]]; then
      check "\$HOME/.claude/agents symlink points to .rc-context/agents" "pass" "-> ${link_target}"
    else
      check "\$HOME/.claude/agents symlink points to .rc-context/agents" "fail" "-> ${link_target}"
    fi
  elif [[ -d "${agents_dir}" ]]; then
    check "\$HOME/.claude/agents symlink points to .rc-context/agents" "fail" "is real dir, not a symlink"
  else
    check "\$HOME/.claude/agents symlink points to .rc-context/agents" "fail" "missing"
  fi
else
  skip_check "\$HOME/.claude/agents symlink points to .rc-context/agents" "cage-only projection — the host's .claude/agents is a real directory, not the in-cage .rc-context/agents symlink; run inside a rip-cage container"
fi

# 10. Agent .md files readable — classify ALL *.md entries:
#   readable  → counts toward PASS (symlink chain resolves)
#   hostonly  → broken symlink with target outside cage resident roots → SKIP (not FAIL)
#   corrupt   → broken symlink with target inside cage resident roots, or
#               unreadable non-symlink file → FAIL
#
# Cage resident roots default to /workspace (bind-mount) + realpath of the agents
# staging dir (the physical dir behind the ~/.claude/agents symlink).
# Override via RC_CAGE_ROOTS (colon-separated) for testing.
# Override via RC_AGENTS_DIR for testing.
_check_agents_dir="${RC_AGENTS_DIR:-${agents_dir}}"
if [[ -d "${_check_agents_dir}" ]]; then
  # Determine cage resident roots
  _default_staging=$(realpath "${_check_agents_dir}" 2>/dev/null || echo "${_check_agents_dir}")
  _cage_roots="${RC_CAGE_ROOTS:-/workspace:${_default_staging}}"

  # Classify and report — _CAD_READABLE, _CAD_HOSTONLY, _CAD_CORRUPT set as side-effects
  _report_agents_classification "${_check_agents_dir}" "${_cage_roots}"
else
  check "Agent .md files readable (symlinks resolve)" "fail" "agents dir missing"
fi

echo ""
echo "=== Settings Merge Idempotency Check ==="
echo ""

# 11. PreToolUse hooks not doubled (catches the resume re-merge bug)
# On fresh init today: 0 PreToolUse hooks baked into THIS file. Historically
# it carried dcg (moved to the root-owned managed-settings.json floor-lock at
# wlwc/rip-cage-r9n4, ADR-027 D3) then block-ssh-bypass alone (deleted
# wholesale with the ssh cluster, ADR-029 D3) -- so the count is now whatever
# the composed manifest's recipes add here, not a fixed number. Compound
# blocker removed rip-cage-4r8.
# Source of truth: /etc/rip-cage/settings.json shipped with the image.
# If init-rip-cage.sh was re-run with the old ~/.claude/settings.json as merge
# source, hooks would double on each resume. This test catches that by counting
# against the shipped baseline rather than a hardcoded number.
settings_file="${HOME}/.claude/settings.json"
shipped_file="/etc/rip-cage/settings.json"
# Cage-only: the shipped baseline (${shipped_file}) is a cage-image artifact
# and never exists on the host, so this check has no host-valid meaning.
if $_TS_IN_CAGE; then
  if [[ -f "${settings_file}" && -f "${shipped_file}" ]]; then
    pretooluse_count=$(jq '[.hooks.PreToolUse[]?.hooks[]?] | length' "${settings_file}" 2>/dev/null || echo "-1")
    expected_count=$(jq '[.hooks.PreToolUse[]?.hooks[]?] | length' "${shipped_file}" 2>/dev/null || echo "-1")
    if [[ "${pretooluse_count}" -eq "${expected_count}" ]]; then
      check "PreToolUse hooks not doubled after init" "pass" "${pretooluse_count} hook(s) — matches shipped baseline"
    elif [[ "${pretooluse_count}" -gt "${expected_count}" ]]; then
      check "PreToolUse hooks not doubled after init" "fail" "${pretooluse_count} hook(s) — init re-merged and doubled hooks (expected ${expected_count})"
    else
      check "PreToolUse hooks not doubled after init" "fail" "could not read hook count (${pretooluse_count}/${expected_count})"
    fi
  else
    check "PreToolUse hooks not doubled after init" "fail" "settings.json or shipped baseline missing"
  fi
else
  skip_check "PreToolUse hooks not doubled after init" "cage-only baseline ${shipped_file} does not exist on the host; run inside a rip-cage container"
fi

echo ""
echo "=== Broken Symlink Warning Check (rip-cage-a0h item (b)) ==="
echo ""

# _collect_symlink_parents (cli/up.sh:_collect_symlink_parents) used to skip broken symlinks under
# ~/.claude/skills / ~/.claude/agents SILENTLY (cli/up.sh:'realpath "$entry"' realpath-fails path,
# cli/up.sh:'[[ ! -e "$target" ]]' [[ -e ]]-false path). Both must now warn to stderr naming the broken
# link (existing skip behavior is preserved — the link still isn't emitted as
# a mount parent). Host-only: sources rc directly against a fake HOME/asset
# dir, mirroring tests/test-symlink-follow.sh's `source "$RC"` convention.
#
# Host-vs-in-cage detection: reuses _TS_IN_CAGE (top of file), which tests
# the same /etc/rip-cage/release sentinel this block always used. This script
# is also invoked in-cage as the canonical path (cli/test.sh:138, docker exec
# .../test-skills.sh), where ${_TS_DIR}/../rc resolves to /usr/local/lib/rc —
# not baked into the image — so sourcing it there is a guaranteed exit=127,
# not a real check of anything (rip-cage-7atw.8). Skip cleanly in that case
# rather than false-failing on a missing host artifact.
if $_TS_IN_CAGE; then
  echo "SKIP (in-cage): broken symlink under skills dir check — host-only, sources ${_TS_DIR}/../rc which isn't baked into the image (rip-cage-7atw.8)"
else
  _bsw_rc="${_TS_DIR}/../rc"
  _bsw_test_home=$(mktemp -d)
  mkdir -p "${_bsw_test_home}/.claude/skills"
  _bsw_broken_link="${_bsw_test_home}/.claude/skills/broken-skill"
  ln -s "${_bsw_test_home}/.claude/skills/nonexistent-target" "${_bsw_broken_link}"

  _bsw_stdout_file=$(mktemp)
  _bsw_stderr_file=$(mktemp)
  _bsw_exit=0
  HOME="${_bsw_test_home}" bash -c "source '${_bsw_rc}'; _collect_symlink_parents '${_bsw_test_home}/.claude/skills'" \
    >"${_bsw_stdout_file}" 2>"${_bsw_stderr_file}" || _bsw_exit=$?
  _bsw_out=$(cat "${_bsw_stdout_file}")
  _bsw_err=$(cat "${_bsw_stderr_file}")
  rm -f "${_bsw_stdout_file}" "${_bsw_stderr_file}"

  if [[ "${_bsw_exit}" -eq 0 ]] \
     && echo "${_bsw_err}" | grep -qF "${_bsw_broken_link}" \
     && echo "${_bsw_err}" | grep -qiE "broken|unresolvable" \
     && [[ -z "${_bsw_out}" ]]; then
    check "broken symlink under skills dir: stderr warning names the link, function still skips it (exit 0)" "pass"
  else
    check "broken symlink under skills dir: stderr warning names the link, function still skips it (exit 0)" "fail" \
      "exit=${_bsw_exit} stdout='${_bsw_out}' stderr='${_bsw_err}'"
  fi

  rm -rf "${_bsw_test_home}"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed (of ${TOTAL}) ==="
[[ "${FAIL}" -eq 0 ]] || exit 1
