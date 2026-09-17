# The cage config

A project launches from **one file**. It is a native microsandbox `--conf` file — msb's own schema, not a rip-cage one — and it carries its lists in full. `rc` merges nothing into it ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2).

This page is the field reference. To **write** one, use the [`cage-config`](../../.claude/skills/cage-config/SKILL.md) skill; `share/rip-cage/cage.yaml.template` is the annotated template it copies from.

## Where the file lives

`rc up` takes the first of:

1. `rc up --conf <path>`
2. `$RC_CAGE_CONF`
3. `~/.config/rip-cage/projects/<cage-name>.yaml`

Always a host-side path **outside every mount the config declares** — a config that resolves inside a tree it mounts is refused before any msb call. A caged agent that could edit its own config could widen its own egress or mount your keys, which would make every mount-side rule advisory ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5a).

The cage name is derived, not chosen: the last two path components of the project directory, with a 4-character hash suffix on collision.

### Why one file and not two

msb overlays two `--conf` files **per field**, but **replaces lists**. So a defaults file plus a project overlay would silently drop the session mounts and the whole allowlist the moment the project file declared any of its own. Native layering is lossy on exactly the fields that matter here, and anything rip-cage built on top would be its own merge engine wearing msb's schema.

## Two rules that fail at boot, not at validation

- **Every host path must be absolute**, and must not traverse a symlink. msb does not follow a host-side symlink in a mount source; the mount fails when the VM boots. On macOS that means `/private/tmp/...`, never `/tmp/...`.
- **A mount source that does not exist fails the boot.** Drop the line rather than pointing it at a path you hope appears.

---

## Image and resources

```yaml
image: rip-cage:latest
cpus: 2
memory: 4G
workdir: /workspace

labels:
  rc.managed: "true"
```

`image:` selects the image — `rc` passes no image argument. Point it at your own `FROM rip-cage:latest` extension when you have one; `RC_IMAGE` is a test-only override.

`rc up`'s `--cpus`, `--memory` and `--pids-limit` flags override the config's values for one launch.

---

## Mounts

Two forms, in one list.

### Host paths

```yaml
mounts:
  - "HOST_PATH:GUEST_PATH"        # read-write
  - "HOST_PATH:GUEST_PATH:ro"     # read-only
```

The set that earns its place in almost every cage:

```yaml
mounts:
  # The project. Changes sync both ways, live.
  - "/Users/you/code/my-app:/workspace"

  # THE TWO LINES THAT MAKE A CLAUDE SESSION SURVIVE A RECREATE.
  - "/Users/you/.claude/projects:/home/agent/.claude/projects"
  - "/Users/you/.claude/sessions:/home/agent/.claude/sessions"

  # Host skills, read-only.
  - "/Users/you/.claude/skills:/home/agent/.claude/skills:ro"

  # Host Claude config, READ-ONLY. See below.
  - "/Users/you/.claude.json:/home/agent/.claude.json:ro"
```

**The session mounts are not optional if you care about continuity.** Adding a host to the allowlist recreates the cage; without `~/.claude/projects` and `~/.claude/sessions` on the host, the running conversation goes with it.

**`~/.claude.json` is `:ro` on purpose.** Init snapshots it to a seed file at boot and the in-cage agent works from the copy. Read-write would hand a prompt-injected agent a write into the `mcpServers` and `hooks` that your **host** Claude later executes ([ADR-024](../decisions/ADR-024-prompt-injection-threat-model.md)). Drop the line entirely if you do not run Claude Code in this cage.

### Named volumes

State msb owns, rather than the host filesystem. Map form, in the same list:

```yaml
mounts:
  - named: "rc-state-<cage-name>"
    target: /home/agent/.claude-state
    create: ensure-exists
  - named: "rc-history-<cage-name>"
    target: /commandhistory
    create: ensure-exists
  - named: "rc-mise-cache"
    target: /home/agent/.local/share/mise
    create: ensure-exists
```

`create: ensure-exists` makes the volume during `msb create`, so a fresh machine needs no setup step. The per-cage volumes carry the cage name; the mise cache is deliberately shared across cages. These survive a recreate, and `rc destroy` removes them — `msb remove` alone would orphan them.

### Secret covers

An empty read-only file mounted over a secret the cage has no business reading. The cage sees the name and zero bytes.

```yaml
mounts:
  - "/Users/you/.config/rip-cage/empty:/workspace/config/local-secrets.toml:ro"
```

These are **belt and braces**: the protected-paths rule already covers the well-known names automatically (see below). Write a line here for a secret whose name is *not* on that list and is specific to this project. This is Tier 1 of the [secret posture gradient](secret-posture.md).

---

## Secrets — credentials the cage never holds

```yaml
secrets:
  CCTOK:
    allow:
      - "api.anthropic.com"

env:
  CLAUDE_CODE_OAUTH_TOKEN: "$MSB_CCTOK"
```

A `secrets:` entry binds a credential **name** to the hosts it may be injected toward. msb substitutes the real value on the wire toward those hosts only; the guest holds the literal string `$MSB_<NAME>` — on disk, in its environment, in `/proc`, and in the config at rest.

**Leave `value:` out.** msb's schema has the field, and filling it would put the secret in a file you edit — the one thing this shape exists to avoid. Omitted, msb resolves the value from the **host environment variable of the same name** at boot.

**The `env:` line is what makes the binding reach the tool.** Claude Code reads a fixed variable name, so it gets the placeholder under that name.

> **This block does not by itself put the Claude login in non-possession.** `rc up` still finds your keychain login and mounts `~/.claude/.credentials.json`, and that mount is what Claude Code actually reads. The block above takes effect only for a token **you** place at `~/.config/rip-cage/secrets/CCTOK`. Bridging the two is `rip-cage-ely4.7.17`, charted and not shipped — [auth.md](auth.md) has both postures side by side.

**Where the host variable comes from.** `rc up` reads the value from `$XDG_CONFIG_HOME/rip-cage/secrets/<NAME>` when that file exists and exports it for the launch — so an unattended run needs no pre-export. Otherwise export it yourself, or msb fails loud naming it. That directory is host-side, outside every cage mount, the same location class as the protected-paths list.

A credential sent toward a host it is not bound to is blocked and logged, not substituted. Full model, including the shapes this does **not** protect: [secret-posture.md](secret-posture.md).

---

## Network — the egress allowlist

```yaml
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
    - "github.com:tcp:443"
```

`policy: none` is msb's default-**deny**: nothing leaves the cage except the hosts listed. Each entry uses the `<host>:tcp:443` form — name the port; a bare host records every port.

The full repair loop when something is denied, and what the denial does and does not log, is [egress.md](egress.md).

---

## What `rc up` adds that no config file can hold

The config is the whole project config, but a few things are computed from the host at launch and belong to `rc`:

| What | Why it cannot be in the file |
|---|---|
| `--name` | Derived from the project path |
| `--log-level trace` | What the denied-host fix-hint mines |
| `--replace` | A per-launch decision, not a property of the cage |
| The keychain credential extraction | Reaches the macOS keychain |
| Read-only parent mounts for skill symlinks | Computed by walking the host filesystem |
| The protected-paths covers | Computed against a host-side list, per mount tree |

`rc up --dry-run` prints the exact `msb create` argv it would run. What the dry-run shows is what runs.

## The floor you do not write: protected paths

`share/rip-cage/protected-paths` is a shipped list of known credential locations — ssh, cloud, gpg, kube, env files. Before any msb call, `rc up`:

- **refuses to launch** a config that mounts a listed path directly;
- **covers** any listed path found inside a mounted tree (an empty read-only file over a file, an empty tmpfs over a directory);
- **aborts** if the list is unreadable.

You do not declare this, and a cage config cannot point at the list. It is operator-editable *configuration* — `$RC_PROTECTED_PATHS`, then `$XDG_CONFIG_HOME/rip-cage/protected-paths`, then the copy shipped beside `rc` — but it is not part of a cage's composition ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2/D5d, [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md)).

## Choosing a multiplexer

`RC_MULTIPLEXER` selects one, and the image's boot descriptor must declare it — otherwise `rc up` refuses before any msb call and names what the image does declare. The default is `none`. Which multiplexer, and whether one at all, is composition, not config ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)); see [`cage-image`](../../.claude/skills/cage-image/SKILL.md).

---

## Two things never to do

- **Never edit this file from inside a cage.** It is host-side by design and not reachable from the guest. An in-cage agent that needs a host added [surfaces the request in prose](../../.claude/skills/cage-ops/SKILL.md) and waits.
- **Never write a real secret into it.** Not in `secrets.<NAME>.value`, not in `env:`, not in a mount source's name. The file is meant to be readable, reviewable and diffable.

## See also

- [`cage-config`](../../.claude/skills/cage-config/SKILL.md) — the skill that writes this file
- [egress.md](egress.md) — the denied-host repair loop
- [secret-posture.md](secret-posture.md) — which credentials are worth the non-possession rework
- [cli-reference.md](cli-reference.md) — `rc up`'s flags, and what a recreate keeps
- [ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2 — why one native file replaced the layered rip-cage schema
