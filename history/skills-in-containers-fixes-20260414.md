# Fixes: skills-in-containers
Date: 2026-04-14
Review passes: 2 (architecture + implementation reviewers × 2 passes)

## Important

- **skill-server.py:~54** — `build_index()` catches `FileNotFoundError` and `PermissionError` but not `NotADirectoryError` (raised when `skills_dir` exists as a file, e.g., bad bind mount). All are subclasses of `OSError`. Fix: broaden catch to `except OSError as e:`.

- **skill-server.py:~25** — `strip_ansi()` regex `r'\x1b\[[0-9;]*[mGKHF]'` covers only 5 of ~26 CSI final bytes. Misses `J` (erase display), `A-D` (cursor movement), `L`, `P`, `S`, `T`, `?`-prefixed sequences. Fix: use `r'\x1b\[[0-9;?]*[A-Za-z]'` to cover all standard CSI sequences; add `|\x1b\([A-Z]` for non-CSI escapes.

- **skill-server.py:~32-41** — `parse_description()` returns `>` or `|` for YAML block scalar descriptions (e.g., `description: >`). Affects `n8n-workflow`, `yt-transcript`, `scrape-url` and any skill formatted by Prettier. Fix: detect block indicators after `description:` value, collect indented continuation lines, join as description text. ~10 lines.

- **skill-server.py:~176** — `handle_tools_call` for `show`/`load` calls `skill['path'].read_text()` on every request, violating the design's scan-once constraint ("enumerate at startup, serve from memory"). Also: ANSI strip runs redundantly per call. Fix: cache `strip_ansi(content)` in `build_index()` as `skill['content']`; serve from cache in `show`/`load`. Remove `skill['path']` from index (resolves latent JSON-serialization issue with `Path` objects, per arch reviewer A1-4).

- **skill-server.py:dispatch()** — `params = msg.get('params', {})` returns `None` when message contains `"params": null`. Any `.get()` on `None` raises `AttributeError`. Fix: `params = msg.get('params') or {}`.

- **skill-server.py:handle_tools_call** — `arguments = params.get('arguments', {})` has same null-default trap as above. `"arguments": null` raises `AttributeError` silently (no response to client, violating JSON-RPC). Fix: `arguments = params.get('arguments') or {}`.

- **test_skill_server.py** — No test for `arguments: null` path. The silent hang (no response for id'd request) is untested. Add test to `TestInputHandling` or new `TestMalformedArguments`: send `{"name": "show", "arguments": null}` and `{"name": "search", "arguments": null}`, verify server returns error response rather than dropping the request.

- **init-rip-cage.sh:~29** — `cp /etc/rip-cage/settings.json ~/.claude/settings.json` overwrites any project-level `mcpServers` entries. Pre-existing limitation (ADR-002 D18), but elevated by adding `mcpServers.meta-skill` — projects with their own MCP servers now silently lose them on every start. Fix: replace `cp` with a `jq` deep-merge:
  ```bash
  if [ -f ~/.claude/settings.json ]; then
    jq -s '
      .[0] as $project |
      .[1] as $rip_cage |
      $rip_cage
      | .mcpServers = (($project.mcpServers // {}) + ($rip_cage.mcpServers // {}))
      | .hooks = (($project.hooks // {}) | to_entries
          + ($rip_cage.hooks // {}) | to_entries | group_by(.key)
          | map({key: .[0].key, value: (map(.value) | flatten)}) | from_entries)
    ' ~/.claude/settings.json /etc/rip-cage/settings.json > /tmp/merged-settings.json
    mv /tmp/merged-settings.json ~/.claude/settings.json
  else
    cp /etc/rip-cage/settings.json ~/.claude/settings.json
  fi
  ```
  Note: The `jq` expression merges `mcpServers` (union) and `hooks` arrays (concatenation). `allowedTools`, `permissions`, and other scalar fields use rip-cage values (container config takes precedence). Test with a project that has its own settings.json.

## Minor

- **skill-server.py:163-168** — Fallback name-search loop in `show`/`load` is dead code. `build_index` sets `index[dir_name]` and `s['name'] = dir_name`, so `index.get(skill_id)` and the loop searching for `s['name'] == skill_id` are identical conditions. The loop can never find a skill the dict lookup missed. Remove it.

- **skill-server.py:tools/list input schemas** — `show` and `load` schemas declare `id` as a property but omit `"required": ["id"]`. `search` omits `"required": ["query"]`. Add required arrays so MCP tooling validates inputs before calling.

- **skill-server.py:parse_description** — Quoted YAML descriptions (`description: "My skill"`) return with literal quote characters. Fix: `.strip('"\'')` after `.strip()`.

- **skill-server.py:signal handling** — No SIGTERM handler. On `docker stop`, SIGTERM propagates; Python raises `SystemExit` mid-readline, potentially logging a spurious exception. Fix: `import signal; signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))` before the main loop.

- **test_skill_server.py:smoke_test** — `TestSmokeTest.test_smoke_test` calls `tools/call list` and prints skill count but does not assert it. Test passes with 0 skills. Fix: assert `payload['count'] >= 0` and that the response shape is correct, or document explicitly that this is an integration test requiring real skills.

- **test_skill_server.py:tearDown** — `proc.stderr` pipe is never closed before `terminate()`, producing `ResourceWarning: unclosed file` in test output. Fix: add `proc.stderr.close()` in tearDown after `proc.wait()`.

- **test-skills.sh:header** — Header comments describe "Branch A: Direct bind-mount (no MCP server)" and "Branch B: Python MCP server" as two options. Branch A was eliminated by Spike 1 (MCP is required). Fix: update header to state Branch B (MCP) is the only supported path; the else block is a fallback error reporter, not an active alternative.

- **test-skills.sh:find count** — `find ~/.claude/skills -name SKILL.md -maxdepth 2` can return >0 when all matching skills are broken symlinks that `skill-server.py` skips. The "at least one skill present" check can pass while MCP serves 0 skills. Fix: note this in a comment or replace with a check against the MCP `list` response count.

- **Dockerfile:COPY ordering** — `skill-server.py` (frequently edited) is COPY'd in the same block as stable files (`settings.json`, `init-rip-cage.sh`). Any edit to `skill-server.py` busts the cache for all following layers. Fix: move frequently-changing files (`skill-server.py`, `test-skills.sh`) to the end of the COPY block so stable files stay cached.

## ADR Updates
- ADR-002 D18: No changes needed — the settings.json merge gap was already documented. The fix in init-rip-cage.sh implements the recommendation already noted in D18 ("init-rip-cage.sh should merge mcpServers from the project's settings into the container's settings rather than overwriting").

## Discarded
- **Unknown tools return empty success** (arch A2-5): Intentional per ADR-002 D18 ("Stubs return empty/success, never errors"). The design doc explicitly documents this as the stub behavior for unimplemented tools. Not a defect.
- **Test number collision between test scripts** (arch A2-2): Pre-existing issue in `rc test` JSON mode; not introduced by this change. Out of scope.
- **Upgrade path contract untested** (arch A2-3 partial): The design doc §"ms Wire Format (Probed 2026-04-14)" documents the exact wire format observed from real `ms`. The upgrade path is documented in the ADR. Theoretical divergence is not actionable.
