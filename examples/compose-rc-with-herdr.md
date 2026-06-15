# Compose rip-cage with herdr

This recipe shows how to add the herdr multiplexer provider to a rip-cage manifest.
herdr is a headless agent-supervisor; see [ADR-019](../../docs/decisions/ADR-019-herdr-multiplexer.md)
and [ADR-006](../../docs/decisions/ADR-006-semantic-status.md) for design rationale.

## Steps

### 1. Add the herdr tool entries to your manifest

Edit `~/.config/rip-cage/tools.yaml` (global) or a project-level `tools.yaml`.
**Two entries are required** — one TOOL (installs the binary) and one MULTIPLEXER (bakes the hooks):

```yaml
version: 1
tools:
  # TOOL entry: installs the herdr binary at image build time.
  - name: herdr-bin
    archetype: TOOL
    version_pin: "v0.6.10"
    install_cmd: "ARCH=$(uname -m) && ..."  # see manifest-fragment.yaml for full command
    egress:
      - github.com
    mounts: []

  # MULTIPLEXER entry: bakes start/attach hooks into /etc/rip-cage/multiplexers/herdr/.
  - name: herdr
    archetype: MULTIPLEXER
    version_pin: "bundled"
    hooks:
      start: "mkdir -p \"${HOME}/.config/herdr\" && herdr server > /tmp/rip-cage-mux-herdr.log 2>&1 & ..."
      attach: "herdr"
```

Or copy the full entries from `examples/herdr/manifest-fragment.yaml`.

### 2. Build the image with herdr baked in

```bash
rc build
```

This installs the herdr binary and bakes the hook scripts into
`/etc/rip-cage/multiplexers/herdr/` in the image.

### 3. Configure a workspace to use herdr

In the workspace `.rip-cage.yaml`:

```yaml
version: 1
session:
  multiplexer: herdr
```

### 4. Start the cage

```bash
rc up /path/to/workspace
```

On first boot, `init-rip-cage.sh` runs the baked `start` hook, which:
- Creates `~/.config/herdr/` in the container
- Starts `herdr server` in the background (logs to `/tmp/rip-cage-mux-herdr.log`)
- Installs herdr integrations for any coding agents found on PATH (pi, claude)

### 5. Attach to the cage

```bash
rc attach
```

This dispatches through the baked `attach` hook, opening the herdr TUI client
over the unix socket at `~/.config/herdr/herdr.sock`.

## Herdr CLI control surface (ADR-019 D9)

Inside the cage (or via `rc exec`), use herdr's bash CLI:

```bash
herdr agent start <name> -- pi ...   # start an agent under herdr supervision
herdr agent list                      # list agents + semantic status
herdr pane <name>                     # open a pane
herdr workspace <name>               # switch workspace
```

The `HERDR_ENV=1` variable is set in managed panes.

## Semantic status integration (ADR-006 D8)

The `start` hook installs herdr integrations for pi and claude.
Once installed, `herdr agent list` reports `agent_status=working` with
`screen_detection_skipped=true` (integration path, not process-detection fallback).

## Troubleshooting

- **herdr server not starting**: Check `/tmp/rip-cage-mux-herdr.log` inside the cage.
- **Integration install failed**: herdr may not have been present at install time;
  re-run `herdr integration install pi` or `herdr integration install claude` manually.
- **Socket not found**: Ensure herdr was started before attaching; `rc up` triggers init.
