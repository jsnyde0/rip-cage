# CLI Reference

`rc` has six verbs. A verb exists only where plain shell plus a skill cannot do the job identically every run ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D3). An unknown verb prints usage and exits 1.

Twelve verbs were deleted in the same pass. Each one's successor — an msb one-liner, a file edit, or nothing — is tabled in the [`cage-ops`](../../.claude/skills/cage-ops/SKILL.md) skill, which is its sole home.

## Commands

| Command | What it does |
|---|---|
| `rc up [path] [options]` | Create or resume the cage for `path` (default `.`), run init, attach |
| `rc build [--file PATH]` | Build the image from one host-side Dockerfile, then load it into msb's cache |
| `rc auth refresh` | Re-pull the Claude login from the host keychain and re-apply it |
| `rc doctor [name]` · `rc doctor --host` | Per-cage diagnostic (labels + live probes) · host daemon/runtime liveness |
| `rc test [name]` | Run the proving suite inside a cage (`--host`, `--e2e`, `--e2e-security` for the other tiers) |
| `rc destroy <name>` | Remove the cage and the named volumes `rc` created for it |

## Global flags

| Flag | Description |
|---|---|
| `--output json` | Machine-readable JSON on stdout; human messages go to stderr. Errors carry `error` and `code`. Coverage is still landing under `rip-cage-sygz`. |
| `--dry-run` | Print what would happen instead of doing it (`up`) |
| `--version` / `-V` | Print the version |

---

## `rc up`

```
rc up [path] [--conf FILE] [--replace] [--no-reload] [--port PORT] [--env-file FILE]
      [--cpus N] [--memory SIZE] [--pids-limit N] [--new] [--session NAME]
```

`rc up` does the things no config file can hold: it pulls the Claude login from the keychain and binds it to msb `--secret`, computes read-only parent mounts for your skill symlinks, runs the protected-paths check, and then calls `msb create --conf <file> --name <cage> --log-level trace`.

| Flag | Description |
|---|---|
| `--conf FILE` | The native msb config to launch with. Default `~/.config/rip-cage/projects/<cage>.yaml`; `$RC_CAGE_CONF` sits between the two. Must resolve outside every mount the config declares. |
| `--replace` | Graceful-stop and recreate a **running** cage against the current config. A running cage is never recreated implicitly, because that kills the live session. |
| `--no-reload` | Resume a **stopped** cage as-is rather than converging it on the current config. |
| `--port`, `--env-file`, `--cpus`, `--memory`, `--pids-limit` | Runtime overrides layered onto the config's own values. |
| `--new` / `--session NAME` | Multiplexer session selection; see below. Mutually exclusive (exit 2 if both). |
| `--allow-risky-mount <resolved-path>` | One-shot: let one protected path past the mount refusal for this invocation. Takes the **resolved** (realpath) form, which the error message prints. Repeatable. |

### Which recreate am I doing?

- A **stopped** cage converges on a plain `rc up` — it is recreated against the current config.
- A **running** cage needs `rc up --replace`, explicitly.

Either way the recreate is cold: it is a fresh kernel boot, not a resumed process tree. **Host mounts and named volumes survive** — so your Claude session resumes, because `~/.claude/projects` and `~/.claude/sessions` are mounts. **The guest's ephemeral rootfs overlay does not** — an `apt-get install` you ran at runtime and never baked into the image is gone.

### The protected-paths refusal

Before any msb call, `rc up` reads `share/rip-cage/protected-paths` — a shipped list of known credential locations — and:

- **refuses to launch** a config that mounts a listed path directly;
- **covers** any listed path found inside a mounted tree (an empty read-only file over a file, an empty tmpfs over a directory);
- **aborts** if the list itself is unreadable.

If msb cannot express the cover for an entry, `rc up` refuses rather than proceeding. Fail closed, never fail open ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2/D5, [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md)). The list is operator-editable, resolved from `$RC_PROTECTED_PATHS`, then `$XDG_CONFIG_HOME/rip-cage/protected-paths`, then the copy shipped beside `rc` — never from a path any cage config can point at.

### Multiplexer sessions

`RC_MULTIPLEXER` selects a multiplexer; the image's boot descriptor must declare it, or `rc up` refuses before any msb call and names what the image does declare. The default is `none`: one shell process per `rc up`, and more agents means more cages.

With a multiplexer that supports sessions, `--new` skips the picker and creates an auto-named session; `--session NAME` attaches `NAME` or creates it. Non-TTY invocations skip the picker entirely.

---

## `rc build`

```
rc build [--file PATH]
```

Runs `docker build`, then loads the result into msb's image cache. Those are two separate stores, and **cages boot from msb's** — a bare `docker build` leaves cages running the old image. Both `rc build` and an auto-provisioning `rc up` run the load step and compare the stores afterward, warning loudly (and, on the `rc up` already-present branch, resyncing) when they disagree.

`--file PATH` names the Dockerfile. Default is rip-cage's own base Dockerfile. The path **must resolve outside every cage mount** — fail-closed, no opt-out, because a caged agent that could point `rc build` at a path it controls has written its own image.

**`rc build` takes exactly one input.** Docker receives a fixed argv — `-f <path> --build-arg RC_VERSION=<version> -t <tag> <context>` — and nothing else. Any other caller flag, including `-t`, is rejected before any docker call. Set `RC_IMAGE` to build under a different tag.

The reason is not tidiness. Three consecutive reviews found three distinct validator-defeat mechanisms in the same six lines of the old pass-through: `-f` silently swapped the audited Dockerfile (docker's duplicate `-f` is last-wins), `-o type=local` exited 0 without loading the image so the post-build checks passed against a stale one, and `--build-arg BUILDKIT_SYNTAX=<image>` replaced the frontend that interprets the Dockerfile at all. An allowlist of flag *names* cannot catch the third — admission is a value-level question. Fixed argv is the only shape that holds ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5c, [ADR-005 D14](../decisions/ADR-005-ecosystem-tools.md)).

Everything a docker flag used to express belongs in the Dockerfile, which is yours to write. See the [`cage-image`](../../.claude/skills/cage-image/SKILL.md) skill.

---

## `rc test`

| Invocation | Tier |
|---|---|
| `rc test [name]` | The in-cage safety-stack suite. The floor probe runs first, before any other check. |
| `rc test --host` | Host-side suites only; not usable inside a cage. |
| `rc test --e2e` | Full lifecycle end to end (slow; `RC_E2E_REBUILD=1` to rebuild first). |
| `rc test --e2e-security` | Injection-exfil integration probes against real cages (slow). |

The suite runs against **your** composed image, not a reference image someone else built. Checks that depend on a recipe you did not compose report `SKIP` with a reason rather than failing.

---

## `rc destroy`

```
rc destroy <name>
```

Removes the cage and the named volumes `rc` created for it — `msb remove` alone orphans them. No prompt, no flags.

`rc destroy` takes the name you type, or the cage the current directory names. Given neither, or a name that matches nothing, it **refuses with exit 2** and lists the cages it left standing. It never picks one for you.

---

## Cage names

Names are derived from the last two path components of the project directory, with a 4-character hash suffix on collision. Read the `name` field from `rc up --output json`; don't construct one. `msb list` enumerates live cages.

The read-only verbs (`doctor`, `test`) resolve a name in three steps: an explicit name, then a match on the current directory, then singleton auto-select when exactly one rc-managed cage exists. `rc destroy` deliberately stops after the second step.

---

## `rc doctor --output json` — per-cage fields

Top-level keys of `rc doctor <name> --output json`:

| Key | Type | Presence | Meaning |
|---|---|---|---|
| `name` | string | always | Resolved cage name. |
| `state` | string | always | `running` (msb `Running`), `exited` (msb `Stopped`), or `unknown` for any other status msb reports. |
| `uptime` | string | always | Time since the last start/stop transition (`Xm`, `Xh Ym`, `Xd Yh`), or `—`. msb exposes one transition timestamp, so a never-started and a stopped-after-running cage are not distinguished. |
| `source_path` | string | always | Host path recorded in the `rc.source.path` label at creation; empty string if unset. |
| `labels` | object | always | One sub-key today: `rc.egress.config-override` (`"true"`/`"false"` — the workspace base-URL-override posture, [ADR-024](../decisions/ADR-024-prompt-injection-threat-model.md) D1). |
| `probes` | object | always | Nine status strings: `posture`, `beads_server`, `auth`, `dead_mounts`, `transcript_persistence`, `skills_mount`, `cwd`, `workspace_resolution`, `bd_version_skew`. Each is the literal `"not running, no live probe"` when the cage is down, otherwise prefixed `OK —` / `WARN —` / `FAIL —` / `INFO —`. |
| `source_path_missing_hint` | string | only when the recorded host path no longer exists | The fix-hint text. The key is **omitted entirely** on a healthy cage, not set to an empty string. |

The `posture` probe is where a recently-denied host surfaces: `rc doctor` mines the cage's trace log for `DNS query denied by network policy domain=<host>` and prints the exact config line to add. See [egress.md](egress.md).

## `rc doctor --host --output json` — host fields

A separate emitter with no overlapping keys.

| Key | Type | Meaning |
|---|---|---|
| `scope` | string | Literal `"host"`. |
| `daemon` | string | Docker daemon reachability, prefixed `OK —` / `FAIL —`. |
| `docker_info_rc` | number | Exit code of the `docker info` probe (`127` not installed, `124` timeout). `0` means reachable. |
| `timeout_seconds` | number | Bound on that probe — `RC_DOCKER_PREFLIGHT_TIMEOUT` if set, else `3`. |
| `docker_path` | string | Resolved path to `docker`; empty string if not installed. |
| `msb` | string | msb reachability, prefixed `OK —` / `FAIL —`. |
| `msb_rc` | number | Exit code of the `msb --version` probe. `0` means reachable. |
| `msb_path` | string | Resolved path to `msb`; empty string if not installed. |
| `yq` | string | `yq` prerequisite status — resolved path, or an install hint (mikefarah's `yq`, not apt's incompatible one). |
| `global_config` | string | **Protected-paths list status**, despite the legacy key name: the resolved path, or an error saying every `rc up` will refuse to launch. |

---

## Running several agents

One cage per project path is the shape rip-cage is built around; each has its own microVM, its own mounts and its own state. Git worktrees make that cheap — see [the worktree workflow](../../README.md#the-worktree-workflow).

Inside one cage, a multiplexer your image declares can carry several agent slots. Which multiplexer, and whether one at all, is yours to compose ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)); `rc` names none.
