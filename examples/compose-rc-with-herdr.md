# Compose rip-cage with herdr

This is a step-by-step walkthrough of adding the herdr multiplexer to a cage.
For the recipe itself (files, the provider contract, the durable-state mount,
and the two measured herdr gotchas), see
[`examples/herdr/README.md`](herdr/README.md) — this file only sequences the
steps; that one is the source of truth for the mechanics.

herdr is a headless agent-supervisor; see
[ADR-019](../docs/decisions/ADR-019-herdr-multiplexer.md) and
[ADR-006](../docs/decisions/ADR-006-semantic-status.md) for design rationale.

## Steps

### 1. Paste the recipe into your own Dockerfile

Write your own Dockerfile outside every directory your cage config mounts —
`rc build` refuses one inside a cage mount, fail-closed, no opt-out
(ADR-031 D5(a)). Paste [`examples/herdr/Dockerfile.snippet`](herdr/Dockerfile.snippet)
between your `FROM ghcr.io/jsnyde0/rip-cage:latest` line and `USER agent`, and
copy `boot-fragment.json` + `scripted-attach.py` next to your Dockerfile.

### 2. Build the image with herdr baked in

```bash
RC_IMAGE=my-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
```

This installs the herdr binary and merges the `multiplexers[]` start/attach
hooks into `/etc/rip-cage/boot.json` in the image.

### 3. Point your project's cage config at the image, and add the state mount

```yaml
image: my-cage:latest
mounts:
  - "<ABSOLUTE_HOST_DIR>/herdr-<cage-name>:/home/agent/.config/herdr"
```

The mount line is required for the roster to survive a restart — see
[`examples/herdr/README.md`](herdr/README.md#the-durable-state-mount-required-for-restart-survival).

### 4. Start the cage with herdr selected

```bash
RC_MULTIPLEXER=herdr rc up
```

On first boot, init runs the baked `start` hook, which creates
`~/.config/herdr/`, starts `herdr server` in the background (logs to
`/tmp/rip-cage-mux-herdr.log`), installs herdr integrations for any coding
agents found on PATH, and triggers herdr's native roster restore via a
scripted headless attach.

### 5. Attach to the cage

```bash
rc up
```

Against an already-running cage with `RC_MULTIPLEXER=herdr` selected, this
dispatches through the baked `attach` hook, opening the herdr TUI client over
the relocated unix socket.

## Herdr CLI control surface (ADR-019 D9)

Inside the cage (or via `msb exec`), use herdr's bash CLI:

```bash
herdr agent start <name> -- pi ...   # start an agent under herdr supervision
herdr agent list                      # list agents + semantic status
herdr pane <name>                     # open a pane
herdr workspace <name>                # switch workspace
```

## Semantic status integration (ADR-006 D8)

The `start` hook installs herdr integrations for pi and claude. Once
installed, `herdr agent list` reports `agent_status=working` with
`screen_detection_skipped=true` (integration path, not process-detection
fallback). For pi specifically, [`examples/herdr-pi/`](herdr-pi/) bakes the
integration extension in explicitly rather than relying on the boot-time
install alone — read it if you also want the DCG guard composed.

## Troubleshooting

- **herdr server not starting**: check `/tmp/rip-cage-mux-herdr.log` inside the cage.
- **Integration install failed**: re-run `herdr integration install pi` or
  `herdr integration install claude` by hand.
- **Socket not found**: confirm the cage actually finished booting past init
  before attaching — the relocated socket only exists once `start` has run.
