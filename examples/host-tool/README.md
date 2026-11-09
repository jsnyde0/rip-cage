# host-tool — a worked declaration and an ask-then-run wrapper

A recipe for the **host-tool line** ([ADR-032](../../docs/decisions/ADR-032-host-tool-line.md)):
a caged agent runs `host-tool <tool> <verb> --<slot> <value>`, and the host runs
the one command line you declared for that verb, after checking every value
against its slot type. This recipe declares three verbs on one tool, `example`:

| Verb | Runs | Shows |
|---|---|---|
| `echo --text T [--count N]` | `bin/echo-tool` | a validated value reaching a host command as one argv element; a URL echoed (`allow_slash`); `--count` bounded 1..5 |
| `env` | `bin/env-tool` | what a host command inherits: exactly `PATH`, `HOME`, `LANG`, with `HOME` and the working directory one fresh per-call directory |
| `notify --text T` | `bin/ask-then-run` → `bin/echo-tool` | a verb that waits for a human's answer before it acts |

rip-cage names none of these. The files here are an example you copy and edit;
the field reference is the [`cage-config`](../../.claude/skills/cage-config/SKILL.md)
skill ("Declaring host tools") and the mechanism is
[`docs/reference/host-tool-line.md`](../../docs/reference/host-tool-line.md).

| File | What it is |
|---|---|
| `example.tools.yaml` | the declaration; `/ABSOLUTE/PATH/TO` and `/ABSOLUTE/STATE/TO` are placeholders you replace |
| `bin/echo-tool`, `bin/env-tool` | the two plain commands |
| `bin/ask-then-run` | the wrapper: ask, wait for an answer file, then run the real command or exit 2 |
| `bin/ask-nudge` | the default asker: a desktop notification, or the request path on stderr |

## 1. Install outside every mount

Copy-and-edit lines, run on the host from this checkout. `<cage>` is the cage
name `rc` derives from the project path: the last two path components joined
with `-` (`~/scratch/ht-demo` becomes `scratch-ht-demo`; the `cage-config` skill
shows how to ask `rc`).

<!-- step1:begin (tests/test-host-tool-recipe.sh runs this block as written, with <cage> set to a name) -->
```bash
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/host-tool-examples"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/host-tool-examples"
PROJECTS="${XDG_CONFIG_HOME:-$HOME/.config}/rip-cage/projects"
mkdir -p "$DEST/bin" "$STATE/inbox" "$PROJECTS" && cp examples/host-tool/bin/* "$DEST/bin/"
sed -e "s|/ABSOLUTE/PATH/TO|$DEST|g" -e "s|/ABSOLUTE/STATE/TO|$STATE|g" \
  examples/host-tool/example.tools.yaml > "$PROJECTS/<cage>.tools.yaml"
```
<!-- step1:end -->

**Where the file goes.** `rc` looks for the declaration beside the cage config
file's **real** path, named `<real-file-stem>.tools.yaml`. The block writes
`$PROJECTS/<cage>.tools.yaml`, which is right when `$PROJECTS/<cage>.yaml` is a
plain file (step 2 makes it one). If your config is a symlink, write the
declaration beside the symlink's target instead, named by the target's stem.

*Done when:* `grep ABSOLUTE "$PROJECTS/<cage>.tools.yaml"` prints nothing and
`ls "$DEST/bin"` lists the four scripts. Re-running the block is safe.

**Why a copy, and why there.** `rc up` refuses a declaration whose command, or
any path inside an `argv` literal, lies inside a directory the cage mounts
(ADR-032 D2): a cage that can write the script can run code on the host. The
workspace is a mount, and so is any directory your config mounts read-write, so
the commands must sit elsewhere, and `~/.local` is a good place only while no
cage config mounts `~/.local` or a parent of it. The copy above puts the
scripts in `~/.local/share` for that reason. It is also why the cage you launch
is **any scratch project directory, never `examples/host-tool/` itself**: this
checkout would be the workspace mount.

The inbox is authority too: whoever can write `$STATE/inbox/<id>.answer` can
answer for the human. Keep `$STATE` out of every mount for the same reason. (It
is not the per-call working directory: that directory is deleted when the call
ends, so a wrapper that waits for an answer needs a fixed path of its own.)

## 2. Launch and call

The scratch project needs its own cage config before `rc up` will start it.
The **cage-config** skill writes it, starting from the shipped template; to do
it by hand:

```bash
mkdir -p ~/scratch/ht-demo
cp share/rip-cage/cage.yaml.template "$PROJECTS/scratch-ht-demo.yaml"   # $PROJECTS from step 1
# edit that file: replace EVERY angle-bracket placeholder: <ABSOLUTE_PATH_TO_YOUR_PROJECT>
# (here ~/scratch/ht-demo, written out in full), <ABSOLUTE_PATH_TO_YOUR_HOME>, <CAGE-NAME>
# (here scratch-ht-demo). Done when this prints nothing:
grep -v '^ *#' "$PROJECTS/scratch-ht-demo.yaml" | grep '<[A-Z]'
rc auth                    # must pass: the template's CCTOK secret needs your saved Claude token
rc up ~/scratch/ht-demo
```

`rc auth` checks the `CCTOK` secret file the template's `secrets:` entry reads;
if it fails, its message says how to save the token (the **cage-config** skill
covers it too). Do not run `rc up` until `rc auth` passes.

The config and the declaration from step 1 share the cage name (the last two
path components of the project, here `scratch-ht-demo`); use that name for
`<cage>` in step 1. Because this config is a plain file, the declaration's
place is beside it: `$PROJECTS/scratch-ht-demo.tools.yaml`, named after the
config's real file stem.

`rc up` finds the declaration, checks it, starts the gatekeeper and adds the
`--vsock` route. Then, inside the cage:

```bash
host-tool --list                       # tools, verbs, slot types, timeouts; no host path
host-tool example echo --text hi --count 3
host-tool example echo --text https://example.com/a
host-tool example env                  # HOME and cwd: one fresh dir; keys: HOME LANG PATH
host-tool example notify --text hi     # waits for an answer, see below
```

Expected: `hi` three times; the URL once; the `env` listing; and `notify` blocking
until you answer or the budget runs out.

**Answering `notify`.** The wrapper writes `<inbox>/<id>.json` (the request:
`{"id": …, "argv": […]}`), runs `ask-nudge <that path>`, and polls for
`<inbox>/<id>.answer`. `ask-nudge` only tells you something is waiting; **it
never answers**. On the host: read the request, then answer it by id. With
several requests pending the id is what says which one you are answering. Write
the answer with a rename so the wrapper never reads half a file:

```bash
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/host-tool-examples"
ls "$STATE/inbox"                          # one <id>.json per pending request
id=<the uuid from the file name>
cat "$STATE/inbox/$id.json"                # what would run
printf 'allow\n' > "$STATE/inbox/.answer-tmp" && mv "$STATE/inbox/.answer-tmp" "$STATE/inbox/$id.answer"
```

Only the exact content `allow` (one trailing newline allowed) runs the command.
Anything else, or no answer within the budget, exits 2 and the agent sees
`tool-failed` and carries on. A desk's card is one possible asker: replace the
`--asker` path with a program that shows a card and writes that file when you
tap the button.

Changing the declaration later: a stopped cage picks it up on the next
`rc up`; a running cage needs `rc up --replace <project>`. Adding or removing the
declaration file on an existing cage is the same two commands.

## How `ask-then-run` is built, and what to keep when you copy it

- **No terminal.** The gatekeeper runs it with stdin `/dev/null`, detached from any
  session (ADR-032 D4). A prompt on stdin would hang until the timeout, so it
  asks through a file.
- **Its authority is its argv.** `--asker`, `--inbox` and `--budget` are fixed
  elements of the declaration, so `rc up` checks each path against the mounts
  and the agent cannot change them. The wrapper has no config file of its own,
  and reads no `HOME`, `XDG_*` or working-directory file: a config under `~/.config`
  would be one read-write mount away from the agent.
- **Fail closed.** No answer, a malformed answer, a missing or failing asker, an
  expired budget: exit 2, command not run. It removes its own files
  (`<id>.json`, `<id>.answer`, and two bookkeeping files for the asker) on every
  exit, and before it execs the real command.
- **Distinct ids.** Each call makes a fresh uuid v4 (`uuidgen`, else `python3`),
  so an answer written for one request cannot satisfy another.
- **The budget and the timeout.** A verb's `timeout` is the gatekeeper's limit
  for the whole call, the answer wait included. `--budget` bounds the asker and
  the wait for the answer **together**: the clock starts before the asker runs,
  the asker may block (a desk card that waits for a tap is fine), and at the
  deadline the wrapper sends the asker TERM, gives it 1 s, then KILL, and
  refuses (so a call ends within the budget plus about a second). The asker
  stays in the wrapper's process group, so the gatekeeper's own group kill
  reaches it too; children the asker starts and that ignore TERM are not
  chased by the wrapper. Set
  `--budget` to the verb's timeout, minus the real command's expected duration,
  minus 10 s. The example declares `timeout: 120s` and `--budget 90` for an
  instant command. A real command that is slow can still meet the timeout; the
  budget is what keeps the *wait* from using it up. The value is whole seconds,
  1 to 999999, no leading zero; anything else exits 2 before the asker runs.
- **Leftovers.** An answer written after the budget ran out stays in the inbox
  (the wrapper has already gone). The wrapper KILLs its asker after the 1 s
  grace, and the gatekeeper then KILLs the whole call's process group, so a
  process the asker started dies too unless it put itself in a new session
  (`setsid`) — only such a process can write an answer file later. Clear the
  inbox yourself now and then.
- **Validated argv only.** After `--` the real command and its slots are exactly
  what the gatekeeper built from validated values. The wrapper writes them into
  the request file as JSON so the asker can show the human what would run.

## Other shapes

A long-lived tool (a logged-in messaging session, a key agent) is not started
by rip-cage: declare that tool's own small client as the command, and keep the
daemon alive yourself. A wrapper that needs `SSH_AUTH_SOCK` sets it from a fixed
path it owns, never from the call's environment, which has no such variable
(ADR-032 D6). A path like that, a gitconfig handed in with
`-c include.path=/abs/path`, or a wrapper's own `HOME` is authority to keep
unmounted, the same as the inbox.

## The proof

[`tests/test-host-tool-recipe.sh`](../../tests/test-host-tool-recipe.sh) replays
step 1 into a temp directory, loads the declaration through the real loader
(against a mount list holding a workspace: accepted; holding the install dir:
refused), starts the real gatekeeper and drives every verb and every answer
outcome with the shipped `host-tool` client over a unix socket. The live in-cage
run of step 2 is the epic's hand-verified check.
