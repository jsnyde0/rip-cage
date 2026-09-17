# Recipe: a project with no cage, taken to a running one

Use this the first time a project gets a cage. Three steps: write the config,
build the image once, start the cage. A returning project skips step 2.

Everything here runs **on the host**. None of it can be done from inside a cage.

---

## Step 0 — check the prerequisites

```bash
docker --version && msb --version && rc --version
```

*Done when:* all three print. `docker` builds the image, `msb` runs the cage,
`rc` wires them together. If `msb` is missing, install microsandbox first —
`rc` refuses without it.

---

## Step 1 — write the config

Get the cage name `rc` will derive, so the filename matches:

```bash
PROJECT=$(cd <your-project> && pwd -P)
CAGE=$(bash -c "source \"\$(command -v rc)\"; container_name '$PROJECT'")
echo "$CAGE"
```

The template ships beside the `rc` script itself. `rc` is usually a symlink, so
resolve it first:

```bash
RC_REAL=$(python3 -c 'import os,shutil;print(os.path.realpath(shutil.which("rc")))')
TEMPLATE="$(dirname "$RC_REAL")/share/rip-cage/cage.yaml.template"
ls "$TEMPLATE"
```

*Done when:* that `ls` prints the path. If it does not, your installed `rc`
predates the template — take it from a rip-cage checkout at
`share/rip-cage/cage.yaml.template`, and say so to the human, because an `rc`
that old also predates the single-config launch this recipe assumes.

Copy it to the path `rc up` reads, then edit it:

```bash
mkdir -p ~/.config/rip-cage/projects
cp "$TEMPLATE" ~/.config/rip-cage/projects/"$CAGE".yaml
```

Now fill in every `<ANGLE-BRACKET>` placeholder. There are two kinds:

- **`<ABSOLUTE_PATH_TO_YOUR_PROJECT>`** → the `$PROJECT` value above. Use the
  `pwd -P` form: msb does not follow a host-side symlink in a bind source, and
  on macOS a `/tmp` or `/var` path is one.
- **`<ABSOLUTE_PATH_TO_YOUR_HOME>`** → `echo $HOME`. It appears on several
  lines; replace all of them.
- **`<CAGE-NAME>`** → the `$CAGE` value, in the two per-cage named volumes.
  `rc-mise-cache` is deliberately shared across cages — leave it alone.

Then make two decisions the template cannot make for you:

1. **Drop any mount whose host path does not exist.** A missing bind source
   fails the BOOT, not the validation. No Claude config on this machine? Delete
   that line.
2. **Read the `network.allow` list and keep what this project needs.** The
   shipped set covers a coding agent: the Anthropic API, GitHub over HTTPS, and
   the usual package registries. Adding more later is one line plus a recreate —
   you are not committing to anything here.

Check your work without starting anything:

```bash
rc up --dry-run "$PROJECT"
```

*Done when:* it exits 0 and the printed argv contains `--conf` pointing at the
file you just wrote. A `CAGE_CONFIG_MISSING` refusal means the filename does
not match `$CAGE`; a protected-path refusal means a mount names something the
containment floor will not hand over — see `share/rip-cage/protected-paths`.

---

## Step 2 — build the image, once

The config's `image:` line names an image that has to exist. Build it from one
Dockerfile:

```bash
rc build --file <path-to-your-Dockerfile>
```

Bare `rc build` builds rip-cage's own base image, which is enough to start.
Want a language runtime, a database, a multiplexer, or a command guard in the
cage? That is a Dockerfile that extends the base image — **the `cage-image`
skill owns that**, and `examples/base/` is the smallest complete starting
point.

*Done when:* `docker image inspect rip-cage:latest` succeeds.

Note the Dockerfile must live OUTSIDE every path your config mounts. `rc build`
refuses otherwise, fail-closed — a cage that can edit its own next image is not
contained.

---

## Step 3 — start the cage

```bash
rc up "$PROJECT"
```

The project appears at `/workspace`. File changes sync both ways, live — no
git push, no copy step.

*Done when:* `msb list` shows the cage, and

```bash
msb exec "$CAGE" -- ls /workspace
```

lists your project's files.

---

## What you now have, and what to run next

| Want to | Verb |
|---|---|
| shell into it | `msb exec <cage> -- zsh` |
| check it | `rc doctor <cage>` |
| stop it, keeping state | `msb stop <cage>` |
| pick it back up | `rc up <project>` |
| throw it away | `rc destroy <cage>` |

Running it day to day, and what to do when something is denied or broken, is
the **cage-ops** skill.

---

## If it did not work

| Symptom | Cause | Fix |
|---|---|---|
| `CAGE_CONFIG_MISSING` | filename ≠ derived cage name | rename to `$CAGE.yaml`, or pass `--conf` |
| `mount ...: Not a directory (os error 20)` | a symlink in a bind source | rewrite that path with `cd <p> && pwd -P` |
| boot fails naming a missing path | a declared mount source is absent | delete the line or create the path |
| `rc up` refuses naming a protected path | a mount hands over a credential store | remove that mount; see `share/rip-cage/protected-paths` |
| msb fails naming a secret variable | `secrets:` entry with no host value | put it in `~/.config/rip-cage/secrets/<NAME>` or export it |
| image not found | step 2 skipped, or `image:` names another tag | `rc build`, or fix the `image:` line |
