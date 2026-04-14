#!/usr/bin/env bash
# test-skills.sh — validates skill discovery inside rip-cage containers
#
# Tests both possible implementations from the 2026-04-14 design:
#   Branch A: Direct bind-mount to ~/.claude/skills/ (no MCP server needed)
#   Branch B: Python MCP server at /usr/local/lib/rip-cage/skill-server.py
#
# The script detects which mode the container is in by checking settings.json
# for a mcpServers["meta-skill"] entry and runs the appropriate tests.
#
# Currently FAILS on an unmodified container:
#   - Branch A: ~/.claude/skills/ is a symlink, not a real directory
#   - Branch B: skill-server.py doesn't exist, no mcpServers config
#
# Passes after implementation of either branch.
#
# Run directly: docker exec <container> /usr/local/lib/rip-cage/test-skills.sh
# Or via:       rc test <container>  (if called by test-safety-stack.sh)

set -euo pipefail
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

echo "=== Skills Discovery Check ==="
echo ""
echo "-- Skill Files --"

skills_dir="${HOME}/.claude/skills"

# 1. ~/.claude/skills/ directory exists (directory or symlink to directory)
check "~/.claude/skills/ exists" "$([[ -d "${skills_dir}" ]] && echo pass || echo fail)"

# 2. At least one SKILL.md present
if [[ -d "${skills_dir}" ]]; then
  skill_count=$(find "${skills_dir}" -name 'SKILL.md' -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
  check "At least one skill present" "$([[ "${skill_count}" -gt 0 ]] && echo pass || echo fail)" "${skill_count} skill(s)"
else
  check "At least one skill present" "fail" "skills dir missing"
  skill_count=0
fi

# 3. Skill files readable (not root-owned or permission-denied)
if [[ "${skill_count}" -gt 0 ]]; then
  first_skill=$(find "${skills_dir}" -name 'SKILL.md' -maxdepth 2 2>/dev/null | head -1)
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

  # 4. skill-server.py exists
  check "skill-server.py exists" "$([[ -f "${server_py}" ]] && echo pass || echo fail)" "${server_py}"

  # 5-7. Full MCP protocol exchange: initialize → tools/list → tools/call list
  if [[ -f "${server_py}" ]]; then
    # Write a temp Python test script — avoids heredoc-inside-heredoc quoting issues
    tmp_py=$(mktemp /tmp/mcp-test-XXXXXX.py)
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

  # 8. settings.json registers server as "meta-skill" (ADR-002 D18: name matches host)
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
echo "=== Results: ${PASS} passed, ${FAIL} failed (of ${TOTAL}) ==="
[[ "${FAIL}" -eq 0 ]] || exit 1
