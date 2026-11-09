# The host-tool line

The mechanism reference for [ADR-032](../decisions/ADR-032-host-tool-line.md):
a caged agent runs one declared host command, with arguments checked against
typed slots, over a vsock route. This page is the one place the wire, the error
table, the lifecycle and the state-directory layout live. The how-to is the
[`cage-config`](../../.claude/skills/cage-config/SKILL.md) skill ("Declaring
host tools") and the repair table is [`cage-ops`](../../.claude/skills/cage-ops/SKILL.md).
A worked declaration is [`examples/host-tool/`](../../examples/host-tool/README.md).
rip-cage names no tool: the tools are yours.

**It is a path around the egress allowlist.** A host tool reaches whatever its
command reaches on the host, and `network.allow` does not see it. `rc doctor`
lists the host tools and states they bypass `network.allow`.

## Parts

| Part | Where | Role |
|---|---|---|
| Declaration | beside the config file's **real** path, named `<real-file-stem>.tools.yaml` (the real basename's last extension swapped). For a default config that is a plain file, `${XDG_CONFIG_HOME:-$HOME/.config}/rip-cage/projects/<cage>.tools.yaml`; a symlinked config resolves to its target's directory and stem; a `--conf` / `RC_CAGE_CONF` config follows the same rule | per tool, per verb: one fixed `argv`, typed slots, a timeout, `returns_secret` |
| Loader | `cli/lib/host_tools.sh` | schema, slot types, `argv[0]` and path-literal checks against the mount list; emits the normalized JSON |
| Gatekeeper | `cli/lib/host-tool-gatekeeper.py`, one process per cage | listens on a unix socket, validates, executes the argv array, replies |
| Client | `/usr/local/bin/host-tool` in the image, root-owned | one JSON line out, one in, a typed exit code |
| Route | `msb create --vsock <state>/host-tool.sock:7700` | guest AF_VSOCK to the host unix socket |

The port is the constant **7700**. It lives in two places: `RC_HOST_TOOL_PORT` in
`cli/lib/host_tools.sh` and `PORT` in `cage/substrate/host-tool`. Change both.

## Wire

One request line, one reply line, UTF-8 JSON, each capped at **32 KiB measured
on the encoded line** (a 64 KiB payload stalls on the measured vsock path, and
JSON escaping can multiply a raw reply). The tool pages; the line does not stream.

```
call   {"v":1,"tool":"<tool>","verb":"<verb>","args":{"<slot>":<value>,...}}
list   {"v":1,"list":true}
ok     {"ok":true,"result":"<stdout of the command>"}
error  {"ok":false,"error":{"kind":"<kind>","message":"<fixed text>"}}
```

`list` is a separate field, so no tool or verb name is reserved. Its result is
`{"tools": {<tool>: {<verb>: {"timeout": <seconds>, "slots": {<slot>: "<type>"}}}}}`:
names, timeouts and slot types, never an `argv` template or a host path. Unknown
request fields are refused. An `int` slot takes only a JSON integer (never a
boolean, never a numeric string); the client encodes the text of an `int` slot as
an integer when it is one, from the types in `list`.

## Errors and exit codes

The closed vocabulary. Messages come from a fixed table: the only variable parts
are the slot name (`bad-argument`) and the exit status (`tool-failed`). No reply
carries a host path, a traceback or an argument value.

| Kind | Client exit | Message | Meaning |
|---|---|---|---|
| `no-such-tool` | 2 | `no such tool` | refused, nothing ran |
| `no-such-verb` | 2 | `no such verb` | refused, nothing ran |
| `bad-argument` | 2 | `bad-argument: slot <name>` (or `bad-argument: request`) | a value failed its slot, a required slot is missing, an argument is unknown, or the request is malformed; nothing ran. For an argument name the verb does not declare, the message today is literally `bad-argument: slot unknown` (the gatekeeper never echoes agent text); it reads like a slot named `unknown`, but means "an undeclared argument" |
| `request-too-large` | 2 | `request too large` | over the cap; nothing ran |
| `tool-failed` | 3 | `tool-failed: exit <n>` | the command ran and exited non-zero; no stderr is forwarded |
| `reply-too-large` | 3 | `reply too large` | the command **ran**; the reply was over the cap and withheld |
| `timeout` | 4 | `timed out` | the verb's timeout passed; the command's whole process group was killed |
| `busy` | 4 | `busy` | every concurrency slot is held (default 4 per cage); retry |
| `unavailable` | 4 | `unavailable` | the command vanished or could not be executed |

Client exit codes: **0** ok; **2** refused, nothing ran (also usage errors);
**3** the command ran and failed or its reply was withheld; **4** the gatekeeper
answered but could not run it; **5** the line did not answer. Exit 5 has two
messages, because they mean different things to a retry:

- *Connect stage* (connection refused or reset, connect timeout, or a `list`
  reply that is not valid JSON): nothing that could run was sent. The message
  names three causes: no declaration for this cage; a declaration added but the
  cage not yet recreated; the gatekeeper is down. Next step: `rc doctor <cage>`.
- *After the call request was delivered* (a reset, a missed deadline or an
  unusable reply): "host-tool line stopped answering after the request was sent;
  the command may have run". Do not retry a side-effecting verb on this exit.

`rc doctor <cage>` names which cause applies (rip-cage-jdl2.6). A `busy` reply to
`list` is an answer: exit 4.

## Slots and validation

A string slot takes `max` (default 4096 bytes), an anchored full-match `regex`,
`allow_dash` and `allow_slash`; an `int` slot takes `min`, `max`; an `enum`
slot takes `values`; each may carry a `default` of its own type. Every string
rejects control characters, newlines and NUL. A value that begins with `-` is
rejected unless `allow_dash`. A value that contains `/` or is `..` is rejected
unless `allow_slash`. There is no path-typed slot. Each validated value becomes
exactly one argv element; no shell is involved and nothing joins agent text into
a command string. Names (tool, verb, slot) match `^[a-z][a-z0-9_-]{0,31}$`.
Placeholders are whole argv elements and match slots one to one; a slot never
fills `argv[0]`.

## The command's environment and directory

The gatekeeper rebuilds its own process environment at start to exactly three
variables and runs every command with the same three:

| Variable | Value |
|---|---|
| `PATH` | `/usr/bin:/bin` (a platform constant) |
| `HOME` | that call's directory |
| `LANG` | copied from the launch environment, `C.UTF-8` when absent |

The working directory is the same per-call directory, created under
`<state>/calls/`, empty, and removed when the call ends (and at gatekeeper stop).
It is never `rc up`'s environment, which carries the real values of every
`secrets:` entry. A command therefore finds no dotfiles and keeps nothing between
calls; anything it needs outside that is a fixed path the declaration or its
wrapper supplies, and such a path is authority to keep unmounted. The command's
stdin is `/dev/null` and it runs detached in its own session; its stderr is the
gatekeeper log. A command that exceeds its timeout has its whole process group
killed (a grandchild that calls `setsid` leaves it; that is a known residual).

## State directory

`${RC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rip-cage}/<cage>/`, created
when a cage first declares a tool, removed by `rc destroy <cage>`. For a cage
that still exists, destroy uses the directory its `rc.state-dir` label records;
for a cage already gone it can only find the directory under the **current**
`RC_STATE_DIR` (or its default), so destroy a gone cage with the same
`RC_STATE_DIR` it was created under. The socket path must fit the platform limit (103 bytes on
macOS, 107 elsewhere, one definition in `cli/lib/host_tools.sh`); `rc up` refuses
before any msb call and names `RC_STATE_DIR` as the override.

| Entry | Holds |
|---|---|
| `host-tool.sock` | the unix socket, mode 0600 |
| `gatekeeper.pid` | the gatekeeper's pid, written after it detaches |
| `tools.json` | the normalized declaration the running gatekeeper loaded |
| `gatekeeper.log` | one line per call (tool, verb, outcome, ms, bytes), each command's stderr |
| `lock` (`lock.d/` on macOS) | held by `rc up` around the start and stop of the gatekeeper: an `flock` on Linux, a `mkdir` directory carrying a pid file on macOS |
| `calls/` | the per-call directories; empty between calls |

It holds the normalized declaration and the pid rc signals, so it must never be
inside a mount: a caged agent that could write it could rewrite its own verbs.

## Lifecycle

- **Presence** is a create-time fact. `rc up` stamps `rc.host-tools=present|absent`
  and, when present, `rc.state-dir=<path>`; a cage with no such label reads as
  `absent`. Adding or removing a declaration therefore takes effect through
  `rc up` on a **stopped** cage (the converge recreates it) or `rc up --replace`
  on a running one. On a stopped cage, `--no-reload` with a presence change is
  refused (the refusal is a stopped-cage check; a running cage only attaches
  and prints that the declaration was added or removed).
- **Contents** never force a recreate. On a **stopped** cage, `rc up` stops any
  gatekeeper still alive for it and starts a fresh one from the current file
  before the cage starts. On a **running** cage, `rc up` only attaches and
  never kills a live gatekeeper; when the live gatekeeper's file differs from
  the current one it prints one line ("host-tool declaration changed; takes
  effect on `rc up --replace`"). A **dead** gatekeeper on a running cage is
  restarted from the **current** declaration file, and no changed line is
  printed: an edit made since create takes effect on that restart, with
  nothing said. Revocation on a running cage needs `rc up --replace` (or that
  silent restart, if the gatekeeper happens to be dead).
- **Start.** After `msb create` succeeds, before init: the gatekeeper calls
  `setsid()`, writes its pid, and `rc up` waits up to 5 s for the pid file and a
  listening socket. If it fails, `rc up` exits non-zero naming the log; the cage
  is stopped and kept, with no line (the same posture as a failed init), and the next plain `rc up` retries the gatekeeper and runs init.
- **Stop.** `rc destroy`, `rc up --replace`, the stopped-cage restart, and a
  failed create or init stop it; attach exit never does. SIGTERM: no new
  connection is accepted, in-flight commands get 5 s, then every remaining
  command group is killed and its call directory removed; `rc` sends SIGKILL after
  5 more seconds and removes socket and pid. A command and anything it started
  in the same process group do not outlive the stop; a process that calls
  `setsid` itself leaves the group and is not reached.
- **No supervisor, no restart loop.** A dead gatekeeper is `host-tool` exit 5 and
  a line in `rc doctor`; plain `rc up` restarts it.
- **`rc doctor <cage>`** lists every declared tool and verb and states they
  bypass `network.allow`, with one fixed sentence (a host tool reaches whatever its
  command reaches; the allowlist does not see it; rc checked the files `argv`
  names, not the code they load), marks `returns_secret` verbs as possession-mode,
  and reports a dead or orphaned gatekeeper, a presence change since create
  (recreate pending) and contents that differ from the running gatekeeper's
  (`rc up --replace` pending). `rc test <cage>` proves the route generically,
  never naming a tool or calling a declared verb.

## The three check sites

A declaration is refused, naming the defect in one `Error:` line, at each of
three points (ADR-032 D2):

1. **`rc up`'s pre-msb floor block**: schema and shape; `argv[0]` is absolute,
   exists and is executable; every `/`-anchored substring of every `argv`
   literal resolves outside every mount of the config; the declaration file
   itself is outside every mount; the pinned `python3` lies outside every mount.
   A mount whose real path equals or contains the projects directory or the
   state root, or lies inside either, is refused; for the `--conf` config's
   directory only equals-or-contains is refused (a mount strictly inside it
   cannot expose the config or its sibling declaration).
2. **The final `msb create` argv**, as assembled, immediately before it runs: every
   host source in it, rc's computed mounts included, is checked against the same
   rule. For a mount rc computes, the overlap is warn-and-skip; for a config row
   it is a refusal. `--dry-run` shows the refusal. One cost to know: on a
   **stopped** cage whose converge has already removed the old cage, a refusal
   here leaves the cage removed (host mounts and named volumes are intact);
   the next `rc up` recreates it against the corrected declaration — the same
   cost as a `--replace`. So site 1 does **not** catch every declaration
   defect: a declared `argv` path that lies inside a mount rc computes (skill
   directories, skill-symlink parents, a worktree's `.git`) is refused only
   here, at site 2. The warn-and-skip above applies to a computed mount that
   overlaps an rc authority directory, never to a declared path inside one.
3. **An existing cage** (stopped converge, running attach): the mount set is the
   one msb recorded at create (`msb inspect --format json`,
   `config.mounts[].host`), and every gatekeeper start checks against it.

## What rc does not check

rc checks the files `argv` names, not the code they load: a shebang's
interpreter, a venv behind an entry point, a sourced library, a `.pth` in
site-packages. Declare tools whose whole install lives outside every mount.
A verb that runs a host tool over the **mounted workspace itself** (`git push`
on the project with the host's keys) is not declarable: the workspace is a
mount, and a tool that reads guest-writable config or hooks from it is host
code execution from the cage.

Known residuals, accepted (ADR-032 D6): host code a cage can influence if it
mounts the place that code lives read-write: the rc checkout, `~/.local/bin`,
a declared tool's own files (the check covers this cage's mounts only, so a
second cage of the same operator can mount them). One operator, one trust
domain. A cage created before the line existed with `~/.local/state` or a parent
mounted read-write keeps that mount until its next `rc up`, which refuses it.
On the guest side `~/.local/bin` precedes `/usr/local/bin` on the agent's `PATH`,
so an agent can shadow the baked client for itself; a tampered client misleads
only the agent, never the host.

## Variables

| Variable | Read by | Meaning |
|---|---|---|
| `RC_STATE_DIR` | `rc` | the state root; a relative value resolves against `$PWD` once; refused if it overlaps a mount |
| `RC_PYTHON3` | `rc` | the interpreter rc execs for the gatekeeper (`python3` on `PATH` by default); resolved to a real absolute path, outside every mount, must import `socket`, `json`, `subprocess` under `-I` |
| `HOST_TOOL_SOCKET` | the client | a unix socket path to dial instead of vsock; honoured only so tests can inject a gatekeeper |
