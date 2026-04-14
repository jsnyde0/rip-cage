#!/usr/bin/env python3
"""
Tests for skill-server.py - MCP shim for skill discovery.
Run with: python3 test_skill_server.py
"""
import json
import os
import select
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SERVER_PATH = Path(__file__).parent / "skill-server.py"


def launch_server(env=None):
    """Launch skill-server.py as a subprocess with optional env overrides."""
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)
    return subprocess.Popen(
        [sys.executable, str(SERVER_PATH)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=proc_env,
    )


def rpc(proc, method, params, req_id):
    """Send one JSON-RPC request and read one response line."""
    msg = json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
    proc.stdin.write(msg + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    return json.loads(line)


def send_notification(proc, method, params=None):
    """Send a notification (no id field)."""
    msg = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}})
    proc.stdin.write(msg + "\n")
    proc.stdin.flush()


def has_response_within(proc, timeout=0.3):
    """Return True if server writes anything to stdout within `timeout` seconds."""
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    return bool(ready)


class TestInitialize(unittest.TestCase):
    def setUp(self):
        self.proc = launch_server()

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def test_initialize_returns_correct_server_info(self):
        r = rpc(self.proc, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "0"},
        }, 1)
        self.assertEqual(r["result"]["serverInfo"]["name"], "meta-skill")
        self.assertEqual(r["result"]["serverInfo"]["version"], "0.1.0")
        self.assertEqual(r["result"]["protocolVersion"], "2024-11-05")
        self.assertIn("tools", r["result"]["capabilities"])

    def test_initialize_response_has_correct_jsonrpc_id(self):
        r = rpc(self.proc, "initialize", {}, 42)
        self.assertEqual(r["id"], 42)
        self.assertEqual(r["jsonrpc"], "2.0")


class TestNotifications(unittest.TestCase):
    def setUp(self):
        self.proc = launch_server()
        # initialize first
        rpc(self.proc, "initialize", {}, 1)

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def test_notification_gets_no_response(self):
        """notifications/initialized must be silently discarded."""
        send_notification(self.proc, "notifications/initialized")
        responded = has_response_within(self.proc, timeout=0.3)
        self.assertFalse(responded, "Server must NOT respond to notifications")

    def test_notifications_cancelled_gets_no_response(self):
        send_notification(self.proc, "notifications/cancelled", {"requestId": 99})
        responded = has_response_within(self.proc, timeout=0.3)
        self.assertFalse(responded, "Server must NOT respond to notifications")


class TestToolsList(unittest.TestCase):
    def setUp(self):
        self.proc = launch_server()

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def test_tools_list_returns_four_tools(self):
        r = rpc(self.proc, "tools/list", {}, 2)
        names = [t["name"] for t in r["result"]["tools"]]
        self.assertIn("list", names)
        self.assertIn("show", names)
        self.assertIn("load", names)
        self.assertIn("search", names)

    def test_tools_list_has_input_schemas(self):
        r = rpc(self.proc, "tools/list", {}, 2)
        for tool in r["result"]["tools"]:
            self.assertIn("inputSchema", tool, f"Tool {tool['name']} missing inputSchema")


class TestToolCallList(unittest.TestCase):
    def setUp(self):
        # Create a temp skills dir with one real skill
        self.tmpdir = tempfile.mkdtemp()
        skill_dir = Path(self.tmpdir) / ".claude" / "skills" / "my-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: my-skill\ndescription: A test skill\n---\n# My Skill\nContent here."
        )
        # Point HOME at our temp dir so glob finds it
        self.proc = launch_server(env={"HOME": self.tmpdir})

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_list_returns_json_in_text(self):
        r = rpc(self.proc, "tools/call", {"name": "list", "arguments": {}}, 3)
        text = r["result"]["content"][0]["text"]
        payload = json.loads(text)
        self.assertIn("count", payload)
        self.assertIn("skills", payload)

    def test_list_includes_created_skill(self):
        r = rpc(self.proc, "tools/call", {"name": "list", "arguments": {}}, 3)
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertEqual(payload["count"], 1)
        self.assertEqual(payload["skills"][0]["id"], "my-skill")
        self.assertEqual(payload["skills"][0]["name"], "my-skill")
        self.assertEqual(payload["skills"][0]["description"], "A test skill")
        self.assertEqual(payload["skills"][0]["layer"], "project")

    def test_list_empty_when_no_skills_dir(self):
        """Skills dir absent: return count=0, not an error."""
        # Use a HOME with no .claude/skills dir
        empty_dir = tempfile.mkdtemp()
        try:
            proc = launch_server(env={"HOME": empty_dir})
            r = rpc(proc, "tools/call", {"name": "list", "arguments": {}}, 1)
            payload = json.loads(r["result"]["content"][0]["text"])
            self.assertEqual(payload["count"], 0)
            self.assertEqual(payload["skills"], [])
            proc.terminate()
            proc.wait()
        finally:
            import shutil
            shutil.rmtree(empty_dir, ignore_errors=True)

    def test_list_empty_when_skills_dir_exists_but_empty(self):
        empty_home = tempfile.mkdtemp()
        try:
            (Path(empty_home) / ".claude" / "skills").mkdir(parents=True)
            proc = launch_server(env={"HOME": empty_home})
            r = rpc(proc, "tools/call", {"name": "list", "arguments": {}}, 1)
            payload = json.loads(r["result"]["content"][0]["text"])
            self.assertEqual(payload["count"], 0)
            proc.terminate()
            proc.wait()
        finally:
            import shutil
            shutil.rmtree(empty_home, ignore_errors=True)


class TestToolCallShowLoad(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        skill_dir = Path(self.tmpdir) / ".claude" / "skills" / "my-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: my-skill\ndescription: A test skill\n---\n# My Skill\nContent here."
        )
        self.proc = launch_server(env={"HOME": self.tmpdir})

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_show_returns_json_content(self):
        r = rpc(self.proc, "tools/call", {"name": "show", "arguments": {"id": "my-skill"}}, 4)
        text = r["result"]["content"][0]["text"]
        payload = json.loads(text)
        self.assertIn("content", payload)
        self.assertIn("My Skill", payload["content"])

    def test_load_is_alias_for_show(self):
        r = rpc(self.proc, "tools/call", {"name": "load", "arguments": {"id": "my-skill"}}, 5)
        text = r["result"]["content"][0]["text"]
        payload = json.loads(text)
        self.assertIn("content", payload)
        self.assertIn("My Skill", payload["content"])

    def test_show_unknown_skill_returns_is_error(self):
        r = rpc(self.proc, "tools/call", {"name": "show", "arguments": {"id": "nonexistent"}}, 6)
        self.assertTrue(r["result"].get("isError"), "Expected isError=True for unknown skill")
        self.assertIn("not found", r["result"]["content"][0]["text"].lower())

    def test_show_strips_ansi_codes(self):
        # Write SKILL.md with ANSI escape codes
        skill_dir = Path(self.tmpdir) / ".claude" / "skills" / "ansi-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: ansi-skill\ndescription: Has colors\n---\n\x1b[32mGreen text\x1b[0m normal"
        )
        # restart with same home
        self.proc.terminate()
        self.proc.wait()
        self.proc = launch_server(env={"HOME": self.tmpdir})

        r = rpc(self.proc, "tools/call", {"name": "show", "arguments": {"id": "ansi-skill"}}, 7)
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertNotIn("\x1b[", payload["content"])
        self.assertIn("Green text", payload["content"])


class TestToolCallSearch(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        skills_dir = Path(self.tmpdir) / ".claude" / "skills"
        for name, desc in [
            ("git-tool", "Git helper for repos"),
            ("docker-tool", "Docker container management"),
        ]:
            d = skills_dir / name
            d.mkdir(parents=True)
            (d / "SKILL.md").write_text(f"---\nname: {name}\ndescription: {desc}\n---\n# {name}")
        self.proc = launch_server(env={"HOME": self.tmpdir})

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_search_returns_matching_skills(self):
        r = rpc(self.proc, "tools/call", {"name": "search", "arguments": {"query": "git"}}, 8)
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertEqual(payload["count"], 1)
        self.assertEqual(payload["skills"][0]["id"], "git-tool")

    def test_search_is_case_insensitive(self):
        r = rpc(self.proc, "tools/call", {"name": "search", "arguments": {"query": "DOCKER"}}, 9)
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertEqual(payload["count"], 1)

    def test_search_empty_query_returns_all(self):
        r = rpc(self.proc, "tools/call", {"name": "search", "arguments": {"query": ""}}, 10)
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertEqual(payload["count"], 2)

    def test_search_no_match_returns_empty_not_error(self):
        r = rpc(self.proc, "tools/call", {"name": "search", "arguments": {"query": "zzz-no-match"}}, 11)
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertEqual(payload["count"], 0)
        self.assertEqual(payload["skills"], [])
        # Must NOT have isError
        self.assertNotIn("isError", r["result"])


class TestUnknownTools(unittest.TestCase):
    def setUp(self):
        self.proc = launch_server()

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def test_unknown_tool_returns_empty_success(self):
        r = rpc(self.proc, "tools/call", {"name": "suggest", "arguments": {}}, 12)
        # Must be a success result (no error key)
        self.assertNotIn("error", r)
        self.assertIn("result", r)
        self.assertEqual(r["result"]["content"][0]["text"], "")

    def test_unknown_method_returns_error(self):
        r = rpc(self.proc, "unknown/method", {}, 13)
        self.assertIn("error", r)
        self.assertEqual(r["error"]["code"], -32601)


class TestBrokenSymlinks(unittest.TestCase):
    def test_broken_symlinks_are_skipped(self):
        """All skills are broken symlinks: index is empty, not an error."""
        tmpdir = tempfile.mkdtemp()
        try:
            skills_dir = Path(tmpdir) / ".claude" / "skills"
            skills_dir.mkdir(parents=True)
            # Create a skill dir with a symlink SKILL.md pointing to nonexistent target
            broken_dir = skills_dir / "broken-skill"
            broken_dir.mkdir()
            (broken_dir / "SKILL.md").symlink_to("/nonexistent/path/SKILL.md")

            proc = launch_server(env={"HOME": tmpdir})
            r = rpc(proc, "tools/call", {"name": "list", "arguments": {}}, 1)
            payload = json.loads(r["result"]["content"][0]["text"])
            self.assertEqual(payload["count"], 0, "Broken symlink skills must be skipped")
            proc.terminate()
            proc.wait()
        finally:
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)


class TestInputHandling(unittest.TestCase):
    def setUp(self):
        self.proc = launch_server()

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def test_blank_line_gets_no_response(self):
        """Blank lines on stdin must be silently skipped."""
        self.proc.stdin.write("\n")
        self.proc.stdin.flush()
        responded = has_response_within(self.proc, timeout=0.3)
        self.assertFalse(responded, "Server must NOT respond to blank lines")

    def test_multiple_blank_lines_then_valid_request(self):
        """Server continues normally after blank lines."""
        self.proc.stdin.write("\n\n\n")
        self.proc.stdin.flush()
        r = rpc(self.proc, "initialize", {}, 1)
        self.assertEqual(r["result"]["serverInfo"]["name"], "meta-skill")

    def test_malformed_json_gets_no_response(self):
        """Malformed JSON: log to stderr, skip, no response."""
        self.proc.stdin.write("not valid json{\n")
        self.proc.stdin.flush()
        responded = has_response_within(self.proc, timeout=0.3)
        self.assertFalse(responded, "Server must NOT respond to malformed JSON")

    def test_server_continues_after_malformed_json(self):
        """Server keeps running after malformed input."""
        self.proc.stdin.write("garbage\n")
        self.proc.stdin.flush()
        # Should still handle a valid request
        r = rpc(self.proc, "initialize", {}, 1)
        self.assertEqual(r["result"]["serverInfo"]["name"], "meta-skill")

    def test_eof_exits_cleanly(self):
        """stdin EOF must cause clean exit (no hanging process)."""
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            self.fail("Server hung after stdin EOF")
        # Exit code doesn't need to be 0, just must exit
        self.assertIsNotNone(self.proc.returncode)


class TestToolsCallBeforeInitialize(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        skill_dir = Path(self.tmpdir) / ".claude" / "skills" / "early-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: early-skill\ndescription: Loaded before init\n---\n# Early"
        )
        self.proc = launch_server(env={"HOME": self.tmpdir})

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_tools_call_before_initialize_works(self):
        """tools/call without prior initialize must work (index built at startup)."""
        r = rpc(self.proc, "tools/call", {"name": "list", "arguments": {}}, 1)
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertEqual(payload["count"], 1)


class TestSmokeTest(unittest.TestCase):
    """Reproduce the smoke test from the bead description exactly."""

    def test_smoke_test(self):
        proc = launch_server()
        try:
            # initialize
            r = rpc(proc, "initialize", {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "0"},
            }, 1)
            self.assertEqual(r["result"]["serverInfo"]["name"], "meta-skill", r)

            # notifications/initialized — no response expected
            send_notification(proc, "notifications/initialized")
            ready, _, _ = select.select([proc.stdout], [], [], 0.2)
            self.assertFalse(ready, "Server should not respond to notifications")

            # tools/list
            r = rpc(proc, "tools/list", {}, 2)
            names = [t["name"] for t in r["result"]["tools"]]
            self.assertIn("list", names)
            self.assertIn("show", names)

            # tools/call list
            r = rpc(proc, "tools/call", {"name": "list", "arguments": {}}, 3)
            payload = json.loads(r["result"]["content"][0]["text"])
            count = payload["count"]
            print(f"\nOK: {count} skills found")
        finally:
            proc.terminate()
            proc.wait()


if __name__ == "__main__":
    unittest.main(verbosity=2)
