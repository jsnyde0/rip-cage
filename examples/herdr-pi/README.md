# herdr-pi — pi launch-extension recipe (inspiration)

This recipe shows how to compose herdr's semantic-status pi extension into a cage's
pi launch shim using the manifest-declared `launch_args` mechanism (ADR-027 D4 /
rip-cage-l72i.1). It is **inspiration** — a concrete fragment an agent reads to learn
how to declare a tool's launch composition — not validated machinery that rc special-cases.

## What problem this solves

herdr tracks the semantic status (working/blocked/idle) of coding agents. For pi agents,
herdr can use either:
- **Integration path** (this recipe): pi loads the herdr extension via `-e`; the extension
  connects to herdr over a unix socket and reports state transitions in real-time.
- **Screen-detection fallback**: herdr infers state by watching terminal output patterns.

The integration path is more reliable. This recipe bakes the generated extension into
the image and declares its load via `launch_args` so every pi invocation carries it.

## What this recipe provisions

- **herdr-pi** (TOOL): runs `herdr integration install pi` (the public CLI — ADR-006 D8)
  inside the Docker build, relocates the generated extension to a root-owned cage path
  `/etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts`, and contributes:
  - `launch_args: ["-e", "/etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts"]` to the
    assembled pi launch shim (assembled by `rc build` from all composed fragments)
  - `mounts: []` — **no host-config mount.** In scenario (a) (herdr as the in-cage
    multiplexer) the cage runs its own herdr server and needs a *writable*
    `~/.config/herdr`; mounting the host dir there (even `ro`) makes it read-only and
    kills the server. Scenario (b) (host-watch) adds its own mount to a non-colliding
    path — see [Socket mount scenarios](#socket-mount-scenarios) below.

## D8 open-verification finding

**For ADR-027 D4 reconciliation (rip-cage-l72i.6).**

`herdr integration install pi` was inspected directly on the host (herdr v0.7.0):

```
$ herdr integration install pi --help
usage: herdr integration install <pi|omp|claude|...>
$ herdr integration install pi
installed pi integration to /Users/<user>/.pi/agent/extensions/herdr-agent-state.ts
```

**Finding: NAMED BOUNDED D8 DEVIATION.**

The CLI accepts no `--output-dir` flag. It always writes to
`<PI_CODING_AGENT_DIR>/extensions/herdr-agent-state.ts` (defaulting to
`~/.pi/agent/extensions/` when `PI_CODING_AGENT_DIR` is unset).

Inside the Docker build (running as root, `PI_CODING_AGENT_DIR` not set), it writes to
`/root/.pi/agent/extensions/herdr-agent-state.ts`.

The recipe therefore:
1. Runs `herdr integration install pi` (D8: public CLI, herdr-authored file).
2. Copies the result to `/etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts`.
3. Sets `root:root` ownership and `0644` permissions.
4. Removes the intermediate path `/root/.pi/`.

The file **content** is 100% herdr-generated. Only the **location** is cage-dictated.
This is the minimal deviation consistent with ADR-006 D8: no hand-authored herdr internals,
no impersonation of herdr's file format. The relocation is post-generate and trivial.

The herdr maintainer could resolve this fully (make it D8-clean) by adding an
`--output-dir` flag to `herdr integration install pi`. Until then, this bounded
deviation is the correct approach.

## How to compose

### Required: herdr binary in the image

This fragment's `install_cmd` runs `herdr integration install pi` inside the Docker
build. The herdr binary must be in the image before this step runs. Compose the
`herdr-bin` TOOL entry from `examples/herdr/manifest-fragment.yaml` first.

### tools.yaml (excerpt)

```yaml
version: 1
tools:
  # 1. Install the herdr binary (from examples/herdr/manifest-fragment.yaml)
  - name: herdr-bin
    archetype: TOOL
    version_pin: "v0.7.0"
    install_cmd: "ARCH=$(uname -m) && ..."  # see examples/herdr/manifest-fragment.yaml
    egress: [github.com]
    mounts: []

  # 2. (Optional) DCG guard — compose BEFORE herdr-pi so --no-extensions appears
  #    first in the assembled launch_args (guard-first by fragment order, ADR-027 D4).
  #    From examples/dcg/manifest-fragment.yaml.
  - name: dcg
    ...
  - name: dcg-wiring
    ...

  # 3. herdr-pi: bakes the herdr extension and contributes -e <ext> to pi launch
  - name: herdr-pi
    archetype: TOOL
    version_pin: "herdr-v0.7.0-integration"
    install_cmd: "mkdir -p /root/.pi/agent/extensions /etc/rip-cage/pi/herdr-ext && herdr integration install pi && cp /root/.pi/agent/extensions/herdr-agent-state.ts /etc/rip-cage/pi/herdr-ext/ && chown -R root:root /etc/rip-cage/pi/herdr-ext && chmod 0644 /etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts && rm -rf /root/.pi"
    egress: []
    mounts: []   # no host-config mount — see "Socket mount scenarios" below
    launch_args: ["-e", "/etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts"]
```

Or copy the `tools[]` entry directly from `manifest-fragment.yaml`.

### Build

```bash
rc build
```

`rc build` assembles `launch_args` across all composed fragments in fragment order and
bakes a generic pi shim. With DCG + herdr-pi composed, the assembled args are:
```
--no-extensions -e /etc/rip-cage/pi/dcg-gate.ts -e /etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts
```

Without DCG, the assembled args are:
```
-e /etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts
```

(pi auto-discovers normally; the herdr extension is loaded explicitly AND available
via auto-discovery from `herdr integration install pi` at cage start — see below.)

## Socket mount scenarios

The herdr pi extension connects to herdr via the unix socket path in `HERDR_SOCKET_PATH`.
Two scenarios — **this recipe declares `mounts: []` and targets scenario A**:

**Scenario A — herdr as multiplexer (examples/herdr/, `session.multiplexer: herdr`)**:
the herdr server runs INSIDE the cage. The socket is at `~/.config/herdr/herdr.sock` inside
the container, and `HERDR_SOCKET_PATH` is set by herdr in managed panes. The cage's herdr
server **must own a writable `~/.config/herdr`** to create that socket — so this recipe
mounts **nothing** there. ⚠️ Do NOT mount the host's `~/.config/herdr` into the cage in this
scenario: even a `ro` mount makes the dir read-only and the in-cage server dies at start
with `herdr: server did not become ready within 5s` (`Os code 30 ReadOnlyFilesystem`).

**Scenario B — herdr running on the HOST (host-watch)**:
herdr watches the cage from outside (e.g., a host-side supervisor) and the cage does NOT
run its own herdr server. The host socket is at `~/.config/herdr/herdr.sock`. A host-watch
user adds their OWN mount — but to a **non-colliding cage path**, e.g.
`{host: "~/.config/herdr", dest: "/home/agent/.config/herdr-host", mode: "ro"}` — and sets
`HERDR_SOCKET_PATH` to `/home/agent/.config/herdr-host/herdr.sock`. Never mount it over the
cage-local `~/.config/herdr`. This scenario-B mount is intentionally NOT baked into this
recipe because it would break scenario A (the common case).

## Without DCG (no-guard path)

Composing herdr-pi WITHOUT the DCG fragment:
- `--no-extensions` is absent from the assembled launch_args.
- pi auto-discovers extensions from workspace and `~/.pi/agent/extensions/`.
- The herdr extension from the image is loaded via `-e` AND also auto-loads from
  `~/.pi/agent/extensions/herdr-agent-state.ts`, written by herdr's
  `integration install pi` at cage boot (the herdr multiplexer start hook —
  see examples/herdr/). This is a genuine double-load of the same
  herdr-generated file content from two paths, not a hypothetical.
- **Newly enabled by rip-cage-fwp3 (2026-07-02)**: before that fix, the
  boot-time `integration install pi` always failed (its target dir,
  `~/.pi/agent/extensions/`, didn't exist yet — nothing provisioned it), so
  in practice the no-DCG path only ever single-loaded via the `-e` bake. The
  fix makes the boot-time install succeed, which is what makes this
  double-load real rather than aspirational.
- **Live-verified non-issue (rip-cage-fwp3, 2026-07-02)**: loading the identical
  herdr-agent-state.ts extension twice does not error or crash pi — extension
  loading completes and pi proceeds normally to the provider/auth check. No
  guard was added; do not add one unless a real failure mode surfaces.
- **Accepted residual**: no destructive-command guard. Containment bounds blast radius.

## Relationship to examples/herdr/

`examples/herdr/` provides the herdr multiplexer (start/attach hooks, binary install).
Its `start` hook runs `herdr integration install pi` at cage boot into the agent's
writable `~/.pi/agent/extensions/` dir. That auto-install works for the no-DCG path.

`examples/herdr-pi/` (this recipe) bakes the extension at a root-owned cage path and
contributes it via `launch_args`, which is required when DCG is composed (because DCG
declares `--no-extensions`, which suppresses the auto-discovery path the start hook writes to).
The two recipes are complementary: compose both when using herdr as multiplexer WITH DCG.

## Upgrading

When upgrading herdr:
1. Update `herdr-bin`'s `version_pin` and `install_cmd` (in examples/herdr/ fragment).
2. Update `herdr-pi`'s `version_pin` to match (e.g., `herdr-v0.8.0-integration`).
3. Run `rc build` — the new `install_cmd` regenerates the extension via the updated binary.
4. The extension file content is always herdr-generated; no hand-editing required.
