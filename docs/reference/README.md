# Reference Docs — Index and Seam Catalog

This file is the landing page for an agent new to rip-cage who needs to understand what composable seams exist and how to use them. It covers both the **seam catalog** (what you wire together and how) and the **reference doc index** (where to find everything else).

---

## Composable seams

rip-cage is a **composable seam, not a bundler** ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)). The cage owns the composition *interfaces* — manifest format, mount mechanics, `rc build` assembly — and you (or an agent) perform the wiring. These six seams are what you compose from.

---

### 1. TOOL manifest entry

**What it is for:** installing any binary, script, or library into the cage image at build time. This is the universal building block — guards, multiplexers, mediators, and plain tools all start with a TOOL entry for the install step.

**Manifest/config shape** (`~/.config/rip-cage/tools.yaml`):

```yaml
version: 1
tools:
  - name: my-tool
    archetype: TOOL
    version_pin: "1.0.0"
    install_cmd: "apt-get install -y my-tool"   # or a curl/tar/install sequence
    egress:
      - github.com          # hostnames the install_cmd reaches at build time
    mounts:
      - host: "~/.config/my-tool"
        dest: "/home/agent/.config/my-tool"
        mode: "ro"          # ro | rw
```

`rc build` reads `tools.yaml`, generates Dockerfile `RUN` steps from `install_cmd`, and stamps an `rc.tools` image label listing every installed tool name. Adding a tool is a manifest entry — zero `rc` source edits ([ADR-005 D7](../decisions/ADR-005-ecosystem-tools.md)).

**Worked example:** [docs/reference/adding-a-tool.md](adding-a-tool.md) — a generic plain-TOOL walkthrough (ripgrep used as illustration; never baked/blessed by rip-cage). Real tool fragments to cross-reference: [examples/dcg/manifest-fragment.yaml](../../examples/dcg/manifest-fragment.yaml) (from-source build), [examples/herdr/manifest-fragment.yaml](../../examples/herdr/manifest-fragment.yaml) (binary download + MULTIPLEXER companion), [examples/tmux/manifest-fragment.yaml](../../examples/tmux/manifest-fragment.yaml) (apt install).

---

### 2. Per-asset ro/rw mounts

**What it is for:** controlling whether host files and directories are read-only or writable from inside the cage. Applies to two surfaces: (a) the project config file `.rip-cage.yaml` (defaulting to read-only), and (b) per-tool `mounts:` entries in the TOOL manifest (each can be `ro` or `rw`).

**Manifest/config shape:**

```yaml
# <project>/.rip-cage.yaml — project config file access inside the cage
version: 1
mounts:
  config_mode: ro   # ro (default) | rw — whether .rip-cage.yaml is writable in-cage
  denylist:
    - .env          # additive: project extends the global 16-pattern secret-path floor
```

```yaml
# ~/.config/rip-cage/tools.yaml — per-tool mount in a TOOL entry
tools:
  - name: my-tool
    archetype: TOOL
    ...
    mounts:
      - host: "~/.config/my-tool"   # host path (~ resolved to real $HOME)
        dest: "/home/agent/.config/my-tool"  # cage path
        mode: "ro"                  # ro = read-only; rw = live write-through
```

`config_mode: ro` (default, [ADR-021 D7](../decisions/ADR-021-layered-rip-cage-config.md)): `rc up` adds a nested `:ro` bind-mount over `/workspace/.rip-cage.yaml` so a prompt-injected agent cannot embed containment-weakening lines that a human rubber-stamps on `rc reload`. `config_mode: rw` is an opt-in for projects where the agent authors its own config — it requires a host-side edit to flip (cannot be self-granted from inside).

**Doc:** [config.md — `mounts.config_mode`](config.md#mountsconfig_mode----project-config-file-access-inside-the-cage) and [config.md — `mounts.denylist`](config.md#mountsdenylist-and-mountsallow_risky----secret-path-denylist) for the full worked examples including the additive-list merge rule, the 16-pattern default floor, and the `allow_risky` escape hatch.

---

### 3. Extension composition (launch args)

**What it is for:** adding per-tool launch flags and extension paths to an agent's startup shim — without editing the shim source or naming recipes in `rc`. Each recipe fragment declares its own `launch_args` contribution; `rc build` assembles them in fragment order into a generic launch shim.

**Manifest/config shape** (in each contributing TOOL entry in `tools.yaml`):

```yaml
tools:
  - name: dcg-wiring
    archetype: TOOL
    ...
    # OPEN by default (ADR-027 D1, FIRM 2026-07-02): no --no-extensions.
    # Shown here is the LOCKED opt-in variant — see examples/dcg/README.md.
    launch_args: ["--no-extensions", "-e", "/etc/rip-cage/pi/dcg-gate.ts"]
    mounts:
      - host: "..."
        dest: "/etc/rip-cage/pi/dcg-gate.ts"
        mode: "ro"

  - name: herdr-pi
    archetype: TOOL
    ...
    launch_args: ["-e", "/etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts"]
    mounts:
      - host: "~/.config/herdr"
        dest: "/home/agent/.config/herdr"
        mode: "ro"
```

`rc build` concatenates `launch_args` across all composed fragments in declaration order (guard fragment first = guard loads first) and bakes a generic wrapper shim. There is **no runtime contribution directory** — the loaded extension set is a build artifact assembled host-side from the manifest. A prompt-injected agent cannot reach `rc build` ([ADR-027 D4](../decisions/ADR-027-agent-substrate-projection.md), [ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)).

Extension composition (the `launch_args` field) was established in rip-cage-l72i and retires the former per-wrapper hardcoded extension slots (`SUBAGENT_EXT`). There is no "vetted-extension drop directory" scanned at runtime.

**Worked example:** [examples/herdr-pi/README.md](../../examples/herdr-pi/README.md) — a full launch-composition recipe showing DCG + herdr extensions composing into the pi launch shim with and without the DCG guard.

---

### 4. Multiplexer / mediator providers

**What it is for:** selecting which terminal multiplexer (if any) runs inside the cage, and optionally forwarding cage egress through an external L7 proxy for credential injection or content-level policy.

**Manifest/config shape — multiplexer** ([ADR-021 D6](../decisions/ADR-021-layered-rip-cage-config.md)):

```yaml
# <project>/.rip-cage.yaml
version: 1
session:
  multiplexer: herdr   # none (default) | tmux | herdr
```

A multiplexer provider is declared in `tools.yaml` as a TOOL entry (binary install) + a MULTIPLEXER entry (hooks):

```yaml
tools:
  - name: herdr-bin
    archetype: TOOL
    ...
  - name: herdr
    archetype: MULTIPLEXER
    version_pin: "bundled"
    hooks:
      start: "herdr server > /tmp/rip-cage-mux-herdr.log 2>&1 &"
      attach: "herdr"
```

**Manifest/config shape — mediator** ([ADR-026 D5](../decisions/ADR-026-containment-mediation-identity.md)):

```yaml
# <project>/.rip-cage.yaml
version: 1
network:
  egress:
    mediator: iron-proxy       # must match a MEDIATOR name in tools.yaml
  http:
    forward_to: "127.0.0.1:8888"  # router sends allowed traffic here via HTTP CONNECT
```

A mediator provider is declared as a TOOL entry (install) + a MEDIATOR entry (start/teardown hooks, `run_as_uid`, optional `ca_cert_path`):

```yaml
tools:
  - name: iron-proxy-bin
    archetype: TOOL
    run_as_uid: "rip-ironproxy"
    ...
  - name: iron-proxy
    archetype: MEDIATOR
    run_as_uid: "rip-ironproxy"
    ca_cert_path: "/etc/iron-proxy/ca.crt"
    hooks:
      start: "/usr/local/bin/iron-proxy -config /etc/iron-proxy/proxy.yaml ..."
```

**Doc:** [config.md — `session.multiplexer`](config.md#sessionmultiplexer----in-cage-multiplexer) and [composition-seam.md](composition-seam.md) (the full mediator seam doc).

**Examples:**
- Multiplexers: [examples/herdr/manifest-fragment.yaml](../../examples/herdr/manifest-fragment.yaml) and [examples/tmux/manifest-fragment.yaml](../../examples/tmux/manifest-fragment.yaml)
- Mediators: [examples/compose-rc-with-iron-proxy.md](../../examples/compose-rc-with-iron-proxy.md) (recommended) and [examples/compose-rc-with-mitmproxy.md](../../examples/compose-rc-with-mitmproxy.md) (proof provider / seam mechanics)

---

### 5. Guard recipes

**What it is for:** composable command-guard hooks that intercept every shell command the agent runs (via Claude Code's `PreToolUse` hook system) and block destructive or dangerous operations. Guards are **not** part of the containment floor — they compose on top of it. Omitting a guard recipe means no command-guard for that class of commands; containment (container boundary, egress firewall, non-root user, filesystem sandbox) still holds.

**Manifest/config shape:** guards use the same TOOL archetype. The guard binary is installed via an `install_cmd`; the wiring (the CC PreToolUse hook entry) lives in a root-owned managed-settings file baked by the recipe. There is no separate "guard archetype" — a guard is a TOOL + a root-owned hook asset on its own load path ([ADR-027 D3](../decisions/ADR-027-agent-substrate-projection.md), [ADR-025 D2](../decisions/ADR-025-host-adoptable-dcg-policy.md)).

To compose the DCG guard:

```yaml
# ~/.config/rip-cage/tools.yaml — copy from examples/dcg/manifest-fragment.yaml
tools:
  - name: dcg            # builds DCG binary from source (Rust builder stage)
    archetype: TOOL
    ...
  - name: dcg-wiring     # bakes the guard wrapper engine + hook registration + cage config
    archetype: TOOL
    ...
    launch_args: ["-e", "/etc/rip-cage/pi/dcg-gate.ts"]  # OPEN default (ADR-027 D1, FIRM)
```

Ships OPEN by default (ADR-027 D1, FIRM 2026-07-02): the guard extension always loads, but
pi's own extension auto-discovery paths stay live — a prompt-injected pi writing its own
bypass extension is an accepted residual. A `--no-extensions` LOCKED opt-in (closes that
residual at the cost of pi extension autonomy) is documented in
[examples/dcg/README.md](../../examples/dcg/README.md).

**Doc:** [safety-stack.md](safety-stack.md) — PreToolUse hooks, `bypassPermissions`, hard-denied operations. [ADR-025](../decisions/ADR-025-host-adoptable-dcg-policy.md) — DCG composable recipe design rationale.

**Examples:** [examples/dcg/](../../examples/dcg/) (DCG destructive-command guard) and [examples/ssh-bypass/](../../examples/ssh-bypass/) (ssh host-key-override blocker).

---

### 6. Launch composition

**What it is for:** assembling a multi-recipe cage where tools, a multiplexer, a mediator, and a guard all compose together cleanly — with each recipe declaring its own launch contributions in the manifest, and `rc build` assembling the final image. No recipe names another recipe's paths; no hardcoded cross-recipe paths in any launch leg.

**Manifest/config shape:** fragment order in `tools.yaml` determines `launch_args` assembly order. Compose the guard fragment first (so guard flags appear first in the assembled args), then extensions. Each recipe fragment is self-contained — it declares only what it contributes:

```yaml
# tools.yaml — composed manifest (guard + herdr integration + pi recipe)
tools:
  - name: dcg         # guard binary
    ...
  - name: dcg-wiring  # contributes: -e /etc/rip-cage/pi/dcg-gate.ts (OPEN default, ADR-027 D1)
    launch_args: ["-e", "/etc/rip-cage/pi/dcg-gate.ts"]
  - name: herdr-bin   # herdr binary
    ...
  - name: herdr-pi    # contributes: -e /etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts
    launch_args: ["-e", "/etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts"]
  - name: pi-recipe   # pi cage-topology doc (no launch_args)
    ...
  - name: herdr       # MULTIPLEXER archetype (session hooks)
    archetype: MULTIPLEXER
    ...
```

Assembled `launch_args` (in fragment order): `-e /etc/rip-cage/pi/dcg-gate.ts -e /etc/rip-cage/pi/herdr-ext/herdr-agent-state.ts`. `rc build` bakes this into a generic pi shim. Adding the Nth tool is a fragment declaration — zero wrapper edits, zero `rc` source edits. (LOCKED opt-in: add `--no-extensions` to `dcg-wiring`'s `launch_args` — see [examples/dcg/README.md](../../examples/dcg/README.md).)

**Worked example:** [examples/herdr-pi/README.md](../../examples/herdr-pi/README.md) — a full DCG + herdr + pi launch composition recipe (the canonical launch-composition example), including the without-DCG path, socket connectivity, and upgrading.

---

## Reference docs

### Setup and quickstart
| File | What it covers |
|---|---|
| [auth.md](auth.md) | OAuth token extraction (macOS Keychain / Linux), API key fallback, pi auth, the mount path for credentials inside the cage |
| [whats-in-the-box.md](whats-in-the-box.md) | Full tool inventory (Claude Code, pi, Node, Python, gh, git, Dolt/bd, tmux), container user model, sudo restrictions |
| [cli-reference.md](cli-reference.md) | All `rc` commands and flags: `build`, `up`, `ls`, `attach`, `exec`, `down`, `destroy`, `reload`, `allowlist`, `test`, `doctor`, `config`, `schema`, `completions`, `setup` |

### Configuration
| File | What it covers |
|---|---|
| [config.md](config.md) | Layered `.rip-cage.yaml` config: `session.multiplexer`, `mounts.config_mode` (ro/rw), `mounts.denylist`, `network.*` egress fields, `dcg.*` policy, `mounts.symlinks.*`; merge rules; `rc config show` / `rc config init` |
| [ssh-routing.md](ssh-routing.md) | SSH identity routing: `--github-identity`, identity rules file, known-hosts mount, banner states |
| [git-lfs.md](git-lfs.md) | Git LFS: what rip-cage does (and doesn't) fetch; LFS pointer stub advisory warning |

### Safety and security
| File | What it covers |
|---|---|
| [safety-stack.md](safety-stack.md) | PreToolUse hooks (DCG, ssh-bypass — composable recipes), `bypassPermissions` mode, hard-denied operations (`.git/hooks/*`), secret-path denylist, running `rc test` |
| [egress.md](egress.md) | Network egress firewall: observe vs. block mode, `rc allowlist` commands, DNS exfil detection, the observe→promote→block workflow |

### Composition and seams
| File | What it covers |
|---|---|
| [composition-seam.md](composition-seam.md) | The HTTP mediator seam (`network.http.forward_to`): the MEDIATOR provider model, launch order, real-secret delivery via `--mediator-env`, tiering (standalone vs. composed), reference providers (mitmproxy, iron-proxy) |
| [adding-a-tool.md](adding-a-tool.md) | Step-by-step: add a plain binary-on-PATH tool via a TOOL manifest entry; apt-install and curl/binary paths; runtime mounts |
| [agent-mail-daemon.md](agent-mail-daemon.md) | IN-CAGE-DAEMON worked example: `mcp-agent-mail` running as a manifest-declared in-cage daemon (the C5 archetype) |
| [cm.md](cm.md) | Mounting a host cm (CASSMS) store read-write into the cage via manifest opt-in |

### Operations
| File | What it covers |
|---|---|
| [release-ceremony.md](release-ceremony.md) | Release steps: GHCR publish, Homebrew formula pin, pre-tag gates, `scripts/update-formula-sha.sh`, two-repo tap sync |
| [devcontainer.md](devcontainer.md) | Dev Containers (VS Code) — removed in rip-cage-kt25; `rc up` is the only supported path |

---

## See also

- [examples/README.md](../../examples/README.md) — recipe index: every example recipe grouped by archetype with one-liners
- [docs/decisions/INDEX.md](../decisions/INDEX.md) — ADR index
- [README.md](../../README.md) — top-level quickstart
