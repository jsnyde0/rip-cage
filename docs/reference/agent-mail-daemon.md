# agent_mail — IN-CAGE-DAEMON Worked Example

This document covers running `mcp-agent-mail` as an `IN-CAGE-DAEMON` manifest entry.
It is the worked example that validates the C5 archetype against a real third-party tool.

**Pinned source:** `github.com/Dicklesworthstone/mcp_agent_mail_rust`
commit `8897497257c5fac79f7a3559cacf27fddc853d4a` (workspace version 0.3.10)

---

## Two Reach Paths

Agent_mail is an in-cage daemon (ADR-005 D7 IN-CAGE-DAEMON archetype). Two classes of
in-cage agent reach it, by different mechanisms:

| Agent class | Reach mechanism | Config requirement |
|---|---|---|
| **MCP-capable** (Claude Code) | MCP client via `mcp_fragment` → `/mcp/` endpoint | `mcp_fragment` in manifest; daemon can run either `mcp-agent-mail serve` or `am serve-http` |
| **Bash-only** (pi — no MCP bridge) | `am` CLI over bash tool | Daemon **must** run in `am serve-http --no-auth` mode (see below) |

This is rip-cage's application of ADR-019 D9: *bash-only agents reach in-cage daemons via the
daemon's own CLI over bash, not MCP.* The `mcp_fragment` in the manifest is the reach mechanism
for MCP-capable agents only; pi (and any other bash-only agent) drives `am ...` commands directly.
Cross-reference: ADR-005 D7 (IN-CAGE-DAEMON archetype), ADR-019 D9 (bash-only CLI-over-bash
pattern; the rejected-MCP-first history is documented there).

---

## `am` CLI Message Surface

The `am` CLI is the reach mechanism for **bash-only agents** (pi and any agent with only a bash
tool). No MCP client is needed — the CLI proxies to the daemon's `/mcp/` endpoint internally.

**Flag surface — verified against built binary (`tests/test-agent-mail-concurrent.sh`, PRECONDITION
4 flag check, lines 209–241; also cross-referenced in the test's header comment block):**

### Send a message

```bash
am mail send \
  --project <path>        \  # workspace/project path (scopes the mailbox)
  --from    <agent-name>  \  # sender's registered agent name
  --to      <agent-name>  \  # recipient's registered agent name
  --subject <subject>     \
  --body    <body>
```

Returns JSON with an `"id"` field on success.

### Read the inbox

```bash
am mail inbox \
  --project       <path>       \  # workspace/project path
  --agent         <agent-name> \  # whose inbox to read
  --include-bodies             \  # include message bodies in the response
  --json                          # output as JSON array
```

Returns a JSON array of message objects. Each object has a **`body_md`** field for the message
body (verified: `tests/test-agent-mail-concurrent.sh` line 514 `m.get('body_md','')`).

**Important:** a "Contact request" message lands in the inbox automatically when a new agent is
registered or first contacted. Agents polling for real messages should filter it out
(`subject` contains `"Contact request"` — see test line 515).

### Register an agent in a project

```bash
am agents register \
  --project <path>   \  # workspace/project path
  --program <prog>   \  # agent program (e.g. pi)
  --model   <model>  \  # model name (e.g. claude-sonnet)
  --json                # optional: output JSON (includes "name" field)
```

Agent names are **auto-generated** (adjective+noun, wordlist-validated). Do not hardcode a name —
read it from the `"name"` field of the JSON output. Names for different registrations in the same
project will be distinct.

---

## Daemon Mode — the -32002 Gotcha

Two daemon start modes ship with agent_mail. **Which one you run determines whether bash-CLI
calls work:**

### `mcp-agent-mail serve --no-tui` (MCP-client path — original fixture)

```yaml
start: "STORAGE_ROOT=/var/lib/rip-cage-daemon/agent-mail mcp-agent-mail serve --no-tui"
```

Fixture: `tests/fixtures/manifest-agent-mail.yaml`

This is the canonical mode for **MCP-capable agents only** (Claude Code). It serves the `/mcp/`
endpoint and exposes the MCP tool surface.

**Known limitation:** mutating `am` CLI calls (`am mail send`, etc.) routed through this daemon
return **JSON-RPC `-32002 Forbidden`** — contact-enforcement gating operates at the MCP session
level, and CLI calls that do not carry a proper MCP session context hit the gate. This is not a
config error; it is by design in `mcp-agent-mail serve`.

### `am serve-http --no-auth --no-tui` (CLI-friendly mode — concurrent fixture)

```yaml
start: "STORAGE_ROOT=/var/lib/rip-cage-daemon/agent-mail am serve-http --no-auth --no-tui"
```

Fixture: `tests/fixtures/manifest-agent-mail-concurrent.yaml`

This mode serves the same `/mcp/` endpoint (same URL, same health probe) but **removes the
contact-enforcement gate** — `--no-auth` disables bearer-token enforcement so `am mail send` /
`am mail inbox` CLI calls work without a Forbidden error.

**Use `am serve-http --no-auth` when:**
- Pi (or any bash-only agent) needs to drive agent_mail via `am` CLI commands.
- A multi-agent cage mixes Claude Code (MCP path) and pi (CLI path) talking to the same daemon.

**Use `mcp-agent-mail serve` when:**
- Only MCP-capable agents (Claude Code) will use the daemon via the `mcp_fragment`.
- The bash CLI path is not needed.

The health probe (`curl -sf http://127.0.0.1:8765/healthz`) works identically in both modes —
health endpoints bypass bearer auth regardless (`lib.rs:57-60`).

---

## Manifest Entry Shape

```yaml
version: 1
tools:
  - name: agent-mail
    archetype: IN-CAGE-DAEMON
    version_pin: "0.3.10"
    start: "STORAGE_ROOT=/var/lib/rip-cage-daemon/agent-mail mcp-agent-mail serve --no-tui"
    health: "curl -sf http://127.0.0.1:8765/healthz"
    state_dir: "/var/lib/rip-cage-daemon/agent-mail"
    install_cmd: "<see tests/fixtures/manifest-agent-mail.yaml for the full pinned-release install_cmd>"
    mcp_fragment:
      type: http
      url: "http://127.0.0.1:8765/mcp/"
      headers:
        Authorization: "Bearer <HTTP_BEARER_TOKEN>"
    egress: []
```

See `tests/fixtures/manifest-agent-mail.yaml` for the full annotated fixture.

### Field notes (all grounded in pinned source @ 8897497)

**`start: "STORAGE_ROOT=/var/lib/rip-cage-daemon/agent-mail mcp-agent-mail serve --no-tui"`**

`--no-tui` suppresses the interactive TUI when stdout is not a TTY
(`main.rs:714-827`). Required for headless cage operation.

`STORAGE_ROOT` pins the storage directory to `state_dir`. Without it, agent_mail
defaults to `~/.local/share/mcp-agent-mail` (XDG, `config.rs:852-870`), which does
not exist in the cage (the parent `/home/agent/.local/share/` is not created by the
init machinery). The `start` env-assignment prefix is evaluated by `eval "$start"`
in `init-rip-cage.sh`, so the `STORAGE_ROOT=...` prefix works. The value must match
`state_dir` exactly so the pre-created, correctly-owned directory is used.

**`health: "curl -sf http://127.0.0.1:8765/healthz"`**

Health endpoints (`/healthz`, `/health/liveness`, `/health`, `/health/readiness`)
**bypass bearer auth** (`lib.rs:57-60`) — the curl health probe needs no token.
Default binding: `127.0.0.1:8765` (`config.rs:1214-1215`). Overridable via
`HTTP_HOST` / `HTTP_PORT` env vars.

**`state_dir: "/var/lib/rip-cage-daemon/agent-mail"`**

Container-local path (ADR-019 D1 extensions pattern). Default XDG path would be
`~/.local/share/mcp-agent-mail/git_mailbox_repo` (`config.rs:852-870`).
The `start` field pins agent_mail to this dir via `STORAGE_ROOT` — the `state_dir`
value and the `STORAGE_ROOT` value must match (the init machinery creates and chowns
`state_dir` before launching the daemon).
Wipe on `rc destroy` is correct semantics — mailboxes are cage-lifetime.

**`install_cmd`**

Prebuilt release download via the official `install.sh` (`install.sh:387,352-353`).
**Bare-clone `cargo build` is NOT viable:** the workspace `Cargo.toml:160-224`
redirects ~40 dependencies to unpublished sibling path-checkouts via
`[patch.crates-io]`. Use the official installer or a direct release artifact URL.

Linux targets:
- `x86_64-unknown-linux-musl` (preferred — statically linked)
- `aarch64-unknown-linux-gnu`

Release artifact pattern: `https://github.com/Dicklesworthstone/mcp_agent_mail_rust/releases/download/<tag>/mcp-agent-mail-<target>.tar.gz`

**`mcp_fragment` (HTTP transport — canonical)**

```yaml
mcp_fragment:
  type: http
  url: "http://127.0.0.1:8765/mcp/"
  headers:
    Authorization: "Bearer <HTTP_BEARER_TOKEN>"
```

Source: `crates/*/setup.rs:1802-1808, 219-224` (pinned @ 8897497).

**Must be a nested YAML object, NOT a quoted JSON string.**
When `mcp_fragment` is declared as a YAML string (e.g.
`mcp_fragment: '{"type":"http",...}'`), `yq -o=json` converts it to a JSON string
value. The `jq --argjson frag` baking step then writes a string into
`settings.json`, so `.mcpServers["agent-mail"].type` reads as empty at runtime.
Declaring it as a YAML mapping (nested dict) ensures `yq` produces a real JSON
object, and the baked `settings.json` entry has a proper `type` field.

**Bearer token is a LITERAL baked value, NOT a substituted template variable.**
The `<HTTP_BEARER_TOKEN>` placeholder in the manifest header is a documentation
convention. The fixture ships this value verbatim. If you leave it as-is, the
Authorization header will send the literal string `Bearer <HTTP_BEARER_TOKEN>`.

**Supported / default path: no bearer token.**
- `HTTP_BEARER_TOKEN` unset → the daemon's `/mcp/` endpoint requires NO auth.
- The fixture as shipped uses no token. Delete the `Authorization` header from
  the manifest's `headers` field, OR leave it as-is — the server ignores an
  unrecognized bearer value when `HTTP_BEARER_TOKEN` is not set.

**Setting a token (operator-only opt-in):**
If you want to protect `/mcp/` with a token:
1. Set `HTTP_BEARER_TOKEN=<your-secret>` in the daemon's environment.
2. Edit the manifest's `mcp_fragment` `Authorization` header to use the SAME
   literal value: `"Bearer <your-secret>"`.
3. Run `rc build` to bake the updated manifest into the image.

Token mechanism: static bearer token read from `HTTP_BEARER_TOKEN` env at server
startup (`config.rs:1776`).

**`egress: []`**

Localhost-only in default configuration. External egress is opt-in only:
- Via `LLM_ENABLED=true` + a provider `*_API_KEY` (default `llm_enabled: false`,
  `config.rs:1324`)
- Via the `am share` CLI subcommand — not invoked by `serve`

**The fixture MUST NOT set `LLM_ENABLED` and MUST inject no `*_API_KEY`.** Declaring
`egress: []` is correct for this configuration. The IOC egress floor (C3) checks
declared hosts against observed proxy traffic.

---

## git-hook-vs-DCG Characterization (ADR-005 D7 risk closure)

**Verdict: NON-BREAKING.**

The `mcp-agent-mail-guard` pre-commit hook (`crates/mcp-agent-mail-guard/src/lib.rs`)
does not suppress or weaken DCG. Details:

### Why the interaction is non-breaking

1. **Opt-in install only.** The guard hook is installed exclusively by:
   - The `install_precommit_guard` MCP tool (explicit agent dispatch)
   - `am guard install` CLI
   - `am doctor --fix`

   It is **never auto-installed on daemon startup.** A running `mcp-agent-mail serve`
   instance does not write any hooks anywhere.

2. **Target-repo-hooks-only.** When installed, the hook writes only into the **target
   repository's `.git/hooks/`** — the repo the agent is currently working on. It does
   not touch the rip-cage Dockerfile, `settings.json`, DCG policy files, or any
   rip-cage configuration.

3. **No DCG-config writes.** The guard reads only environment variables and the
   mailbox JSON reservation archive. It cannot write to or read from DCG's policy
   files, rule definitions, or runtime state. DCG and the guard hook are
   **mutually invisible** — neither knows the other exists.

4. **What the hook actually does.** The guard hook runs `run_guard_check` at commit
   time. It checks whether any staged file matches another agent's live exclusive
   file reservation in the mailbox. If a conflict is found and the mode is `Block`
   (default), it exits 1 — blocking only THAT commit from THAT agent. It does not
   affect DCG's ability to block destructive operations.

5. **DCG fires independently.** DCG operates at the PreToolUse hook level (Claude
   Code's tool dispatch path), before any git command executes. The guard hook runs
   AFTER git's pre-commit phase, which is after DCG has already evaluated and
   (optionally) blocked the operation. DCG blocking a `git commit` call happens
   before the guard hook is ever invoked.

### Escapable conflict cases

The guard hook blocks a commit only when there is an active file reservation conflict.
These cases are escapable:

- `AGENT_MAIL_GUARD_MODE=warn` — downgrades block to warning, commit proceeds (`lib.rs:36-45`)
- `AGENT_MAIL_BYPASS=1` — unconditionally bypasses the check (`lib.rs:1196-1219`)
- The conflicting reservation expires (reservations are time-bounded)

These knobs do not affect DCG. Setting `AGENT_MAIL_BYPASS=1` bypasses the file-
reservation check only — DCG's destructive-command policy is enforced separately
by rip-cage's PreToolUse hook and is not affected by agent_mail environment variables.

### What a cage operator needs to know

- Installing the guard hook in a workspace repo is an **agent-driven opt-in** — the
  agent must explicitly call `install_precommit_guard` or `am guard install`. It does
  not happen automatically.
- Normal commits in a workspace without conflicting reservations succeed without
  any interaction from the guard hook.
- DCG fires on destructive tool calls regardless of whether the guard hook is
  present, absent, or in bypass mode.
- The DCG risk named in ADR-005 D7 is **closed** — no code changes are needed.

---

## Egress Caveat

Agent_mail's default configuration is localhost-only. The only paths to external
egress are:

1. `LLM_ENABLED=true` + a provider API key (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`)
   — enables the daemon's LLM integration for summarization/classification. Do not
   set these in the cage unless you explicitly want external LLM calls.
2. `am share` subcommand — not invoked by `serve`. Only relevant if an agent
   explicitly uses the share feature.

With the fixture as written (no `LLM_ENABLED`, no API keys, `egress: []`), the
daemon makes zero external network calls. The IOC egress proxy (C3) will see only
`localhost:8765` traffic.
