# base recipe — start here

The smallest thing that works: a Dockerfile that extends the published base image
and adds nothing. Copy it, add a line, build.

## The whole loop

```bash
mkdir -p ~/.config/rip-cage/images
cp Dockerfile.snippet ~/.config/rip-cage/images/Dockerfile
# edit it
RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
```

Then point your project's cage config at what you built —
`~/.config/rip-cage/projects/<cage>.yaml`:

```yaml
image: my-cage:latest
```

and `rc up`.

## Why the Dockerfile lives outside your project

`rc build` refuses a Dockerfile that resolves inside any directory a cage config
mounts — before docker runs, with no opt-out flag (ADR-031 D5(a)). An agent that
can point `rc build` at a path it controls has written its own image, and an
opt-out would be the vector rather than a convenience.

The same rule puts the cage config and the protected-paths list host-side. They
are the composition inputs: the things that decide what a cage is, authored where
the thing inside the cage cannot reach them.

## What `rc build` takes

Exactly one input:

```
rc build [--file PATH]
```

`--file` defaults to rc's own base Dockerfile. The build context is that file's
directory, so `COPY` lines read from beside it. docker receives a fixed argv and
nothing else — no `--build-arg`, no `--no-cache`, no `-t`. To build under a
different tag, set `RC_IMAGE`.

That is not austerity for its own sake. The flag allowlist this replaced was
defeated three times in three passes, and a fourth time at the value level, where
`--build-arg BUILDKIT_SYNTAX=<image>` replaces the thing that *interprets* the
Dockerfile. Anything you wanted a flag for belongs in the Dockerfile, which is
yours to write.

## Where to go next

| recipe | what it adds |
|---|---|
| [`../tmux/`](../tmux/) | a multiplexer, so sessions survive a detach |
| [`../postgres-pgvector/`](../postgres-pgvector/) | a database daemon inside the cage |
| [`../dcg/`](../dcg/) | a destructive-command guard |

Each is a `Dockerfile.snippet` you paste in, plus — if it starts something — a
`boot-fragment.json` merged into the image's boot descriptor by `rc-boot-merge`.
Composing them is your job, not rc's: there is no `compose:` directive and no
installer, deliberately (ADR-005 D12).
