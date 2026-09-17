# Recipe: put a tool on PATH in the cage

The common case: the agent needs `ripgrep`, or `uv`, or a database client, and
nothing has to keep running. One Dockerfile, four lines of actual work.

---

## 1. Put the Dockerfile somewhere the cage cannot reach

```bash
mkdir -p ~/.config/rip-cage/images
```

`rc build` refuses a Dockerfile that sits inside any path the cage config
mounts — fail-closed, no opt-out. Anywhere outside those paths is fine;
`~/.config/rip-cage/images/` is the conventional home.

*Done when:* the directory you chose appears in no `mounts:` line of the
project's cage config.

---

## 2. Start from `examples/base/`

Copy [`examples/base/Dockerfile.snippet`](../../../../examples/base/Dockerfile.snippet)
to `~/.config/rip-cage/images/Dockerfile` and read its comments. It is a
complete, working Dockerfile that adds nothing — the right zero to start from.

---

## 3. Add the tool

Between `USER root` and `USER agent`:

```dockerfile
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends ripgrep \
    && rm -rf /var/lib/apt/lists/*
RUN which rg
USER agent
```

Four things about those lines:

- **`--no-install-recommends`** and the `rm -rf /var/lib/apt/lists/*` in the
  SAME `RUN` keep the layer small; a separate `RUN` to clean up saves nothing.
- **`RUN which rg`** is the assertion. If the package name and the binary name
  differ — as here — a build that "succeeded" without this line can still ship
  a cage with no `rg`.
- **End on `USER agent`.** An extension whose last `USER` is root boots a root
  shell with every mount stranded under `/home/agent`, silently.
- **Do not touch `PATH`** to shadow a base-image tool. The prepend reaches the
  interactive shell but not the base image's wrappers, which resolve by
  absolute path — you get half of each.

For a tool installed some other way (a release tarball, a language package
manager), the shape is identical: install as root, assert, return to agent.

---

## 4. Build

```bash
rc build --file ~/.config/rip-cage/images/Dockerfile
```

The build context is that file's directory, so anything you `COPY` must sit
beside it.

*Done when:* the build exits 0 and

```bash
docker image inspect rip-cage:latest >/dev/null && echo present
```

prints `present`.

**On a shared host, say so before you run this.** `rc build` moves the tag every
cage boots from. Use `RC_IMAGE=<other-tag> rc build --file ...` and point one
cage config's `image:` at that tag when you want to try a build without moving
everyone else's.

---

## 5. Get it into a cage

A running cage is not rebuilt in place — it holds the image it booted from.

```bash
rc up --replace <project>
```

*Done when:*

```bash
msb exec <cage> -- which rg
```

prints a path. If it does not, the cage is still on the old image: check
`rc doctor <cage>` for an image-drift warning.

---

## If it did not work

| Symptom | Cause | Fix |
|---|---|---|
| `rc build` refuses before any docker call | the Dockerfile is inside a cage mount | move it outside every `mounts:` path |
| `rc build` rejects a flag | `rc build` takes one file and a fixed argv | express it in the Dockerfile |
| build succeeds, tool missing in-cage | the cage still runs the old image | `rc up --replace <project>` |
| tool present but the agent's wrapper ignores it | a `PATH` prepend shadowing a base tool | remove the prepend |
| cage boots as root, mounts missing | the Dockerfile ends on `USER root` | add `USER agent` as the last `USER` |
| a warning that msb's cache differs from docker's | msb loaded an older copy | `docker save <tag> \| msb load --tag <tag>`, or re-run `rc build` |
