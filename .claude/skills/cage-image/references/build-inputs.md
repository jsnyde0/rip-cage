# Reference: what `rc build` accepts, and why it is so narrow

`rc build` takes **one Dockerfile path** and hands docker a fixed argv.
Everything else is rejected before any docker call. This page says what that
rules out and why, so the narrowness reads as a design rather than a gap.

---

## The whole surface

```bash
rc build                        # rip-cage's own base image
rc build --file <path>          # your extension Dockerfile
RC_IMAGE=<tag> rc build ...     # build under a different tag
```

The argv `rc` constructs is fixed: the file, a version build-arg, the tag, and
the file's own directory as the build context. You cannot add a flag to it.

**A build-context positional, an `--output`, an extra `--build-arg` — all
rejected, loudly, before docker runs.** The rejection is an allowlist, not a
denylist: an unrecognised flag is refused rather than passed through
([ADR-031](../../../../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5).

---

## Why one input

Because the Dockerfile is yours to write, and every knob `rc` grows is a place
where what shipped and what the file says can differ. If a build needs
something, express it in the Dockerfile: that file is readable, diffable, and
reviewable before anything runs. A flag passed once on a command line is none
of those.

This is the same rule the config layer follows — one file, read not written —
applied to the image.

---

## The refusal that is a containment property, not a convenience

**A Dockerfile inside any path the cage config mounts is refused. Fail-closed,
no opt-out.**

A cage that can edit the Dockerfile its next image is built from can grant
itself anything the image can hold — a tool, a wrapper, a disabled guard. The
refusal is what keeps "the human reviews the image before it exists" true.

So: keep build inputs outside every mount. `~/.config/rip-cage/images/` is the
conventional home. If you are tempted to keep the Dockerfile in the repo the
cage works on, that is exactly the case the refusal exists for.

---

## Host-side inputs, generally

The same rule covers every file that decides what a cage IS:

| Input | Lives | Why outside |
|---|---|---|
| the Dockerfile | `~/.config/rip-cage/images/` | see above |
| the cage config | `~/.config/rip-cage/projects/<cage>.yaml` | a cage that edits it decides its own mounts and allowlist |
| protected paths | `~/.config/rip-cage/protected-paths` | it is the floor; a cage that edits it has no floor |
| secret values | `~/.config/rip-cage/secrets/<NAME>` | the guest holds a placeholder, never the value |

All four are host-side, all four are read by `rc` and written by the human (or
an agent working on the host, outside the cage). An agent **inside** a cage
that needs one of them changed says so in prose and waits. It cannot
self-grant, and that is the point rather than an inconvenience to work around.

---

## Two stores hold the image, and they can drift

`docker build` produces the image; `msb` runs it from its own cache. `rc build`
loads the result into msb, but the two can still diverge — a `docker tag` or a
build outside `rc` moves one and not the other.

`rc` warns when msb's cached layers differ from docker's for the same tag:

```
Warning: msb's cached 'rip-cage:latest' image has different layer content than
docker's local 'rip-cage:latest' image — a cage booted from msb's cache would
run a STALE image.
```

Resync:

```bash
docker save rip-cage:latest | msb load --tag rip-cage:latest
```

or just re-run `rc build`.

**Diagnosing:** "I added the tool, the build succeeded, the cage does not have
it" has three candidate causes, in order of likelihood: the cage still runs the
old image (`rc up --replace`), msb's cache is stale (the warning above), or the
tool never installed (which the build-time `RUN which <tool>` assertion would
have caught).

---

## What `rc build` deliberately does not do

- It does not read a manifest, a tool list, or a registry. Those retired with
  the manifest ([ADR-031](../../../../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D4).
- It does not scan `examples/` or install a recipe for you. Recipes are
  inspiration you paste, not machinery that runs.
- It does not name any optional tool, anywhere in `rc`'s code
  ([ADR-005](../../../../docs/decisions/ADR-005-ecosystem-tools.md) D12). If a
  change would put a tool's name inside `rc`, it belongs in a recipe instead.
