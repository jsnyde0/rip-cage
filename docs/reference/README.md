# Reference Docs — Index and Seam Catalog

This file is the landing page for an agent new to rip-cage who needs to understand what composable seams exist and how to use them. It covers both the **seam catalog** (what you wire together and how) and the **reference doc index** (where to find everything else).

---

## Composable seams

rip-cage is a **composable seam, not a bundler** ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)). The cage owns the composition *interfaces* — manifest format, mount mechanics, `rc build` assembly — and you (or an agent) perform the wiring. These seams are what you compose from (entries 1–6 are the common path; 7–9 are the remaining manifest archetypes/mechanisms; 10 is the fail-closed contract bounding all of them).

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

### 4. Multiplexer providers

**What it is for:** selecting which terminal multiplexer (if any) runs inside the cage.

**Manifest/config shape** ([ADR-021 D6](../decisions/ADR-021-layered-rip-cage-config.md)):

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

**Doc:** [config.md — `session.multiplexer`](config.md#sessionmultiplexer----in-cage-multiplexer).

**Examples:** [examples/herdr/manifest-fragment.yaml](../../examples/herdr/manifest-fragment.yaml) and [examples/tmux/manifest-fragment.yaml](../../examples/tmux/manifest-fragment.yaml)

> **Retired: the MEDIATOR provider archetype** ([ADR-029](../decisions/ADR-029-msb-migration.md) D2/D5). This seam used to let a manifest declare a co-located L7 proxy (`archetype: MEDIATOR`, `network.egress.mediator` + `network.http.forward_to` in `.rip-cage.yaml`) that `rc up` launched via `docker exec -u root`. **That archetype, its config fields, and its launch machinery are deleted, not merely undocumented** — `manifest_checks.sh` has no MEDIATOR handling left. Credential non-possession for the dominant secrets is now a default platform property via msb `--secret` (`auth.credentials` in `.rip-cage.yaml`, see [egress.md](egress.md)); L7 content policy beyond that is fully operator-composed and unwired today — see [examples/README.md](../../examples/README.md#mediator-recipes--dropped).

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

**Examples:** [examples/dcg/](../../examples/dcg/) (DCG destructive-command guard). The former sibling `examples/ssh-bypass/` (ssh host-key-override blocker) is deleted — it guarded the ssh cluster, which retired wholesale at the msb cutover ([ADR-029](../decisions/ADR-029-msb-migration.md) D3).

---

### 6. Launch composition

**What it is for:** assembling a multi-recipe cage where tools, a multiplexer, and a guard all compose together cleanly — with each recipe declaring its own launch contributions in the manifest, and `rc build` assembling the final image. No recipe names another recipe's paths; no hardcoded cross-recipe paths in any launch leg.

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

### 7. SHELL-INTEGRATION manifest entry

**What it is for:** tools that integrate via a shell rc `eval` line — the hook must run in the interactive shell's own process (history managers, smarter-`cd`, prompt/env hooks), not just sit on PATH. One `shell_init` field, baked into `/home/agent/.zshrc` at build time. Interactive shells only; single-line enforced fail-closed. Any tool of this class (atuin, zoxide, …) is illustration-only per ADR-005 D12 — none is blessed or shipped.

**Manifest/config shape** (usually paired with a TOOL entry installing the binary — the same two-entry pattern as multiplexers):

```yaml
tools:
  - name: zoxide-bin        # illustration only — the binary install (plain TOOL)
    archetype: TOOL
    ...
  - name: zoxide            # the shell hook
    archetype: SHELL-INTEGRATION
    version_pin: "0.9.6-debian"
    shell_init: 'eval "$(zoxide init zsh)"'
```

**Worked example:** [shell-integration.md](shell-integration.md) — eval-into-shell mechanics, the two-entry pattern, interactive-vs-non-interactive scope, verification. Harness fixtures: `tests/fixtures/manifest-with-shell-integration.yaml`, `tests/fixtures/manifest-e2e-shell-integration.yaml`.

---

### 8. IN-CAGE DAEMON manifest entry

**What it is for:** a long-running localhost service other in-cage agents talk to (agent coordination, mailboxes, local APIs). Contract ([ADR-005 D7/D8/D10](../decisions/ADR-005-ecosystem-tools.md)): installed at build, started at init, **fail-warn** (a broken daemon never bricks the cage), strictly in-cage (no cross-cage reach — D8 FIRM). MCP-capable agents reach it via `mcp_fragment`; bash-only agents (pi) via the daemon's own CLI (ADR-019 D9).

**Manifest/config shape:**

```yaml
tools:
  - name: my-daemon
    archetype: IN-CAGE-DAEMON
    version_pin: "1.2.3"
    install_cmd: "..."
    start: "STATE_ROOT=/var/lib/rip-cage-daemon/my-daemon my-daemon serve --no-tui"
    health: "curl -sf http://127.0.0.1:8765/healthz"
    state_dir: "/var/lib/rip-cage-daemon/my-daemon"   # cage-lifetime; /workspace path for durability
    egress: []
    mcp_fragment: { type: http, url: "http://127.0.0.1:8765/mcp/" }  # optional; nested mapping, not a JSON string
```

**Worked example:** [in-cage-daemon.md](in-cage-daemon.md) — the generic archetype walkthrough including the DAEMON-vs-TOOL(-init-hook) decision aid; [agent-mail-daemon.md](agent-mail-daemon.md) — the concrete instance (agent_mail, pinned source, CLI + MCP reach paths).

---

### 9. From-source builder stage (`build_source`)

**What it is for:** compiling a TOOL's binary at `rc build` when no prebuilt release exists for the cage's architecture ([ADR-005 D11](../decisions/ADR-005-ecosystem-tools.md) mechanism 1, FLEXIBLE; prefer prebuilt per D6). One generic isolated Docker stage per entry — `rc` interprets no build logic; the per-tool intelligence lives in your build script. Arch-adaptive by construction (the stage targets the build platform).

**Manifest/config shape** (replaces `install_cmd`; the two are mutually exclusive):

```yaml
tools:
  - name: my-tool
    archetype: TOOL
    version_pin: "v1.2.3"
    egress: []
    mounts: []
    build_source:
      builder_image: "rust:1-slim-trixie"            # toolchain image
      build_script: "path/relative/to/repo-root.sh"  # COPY'd into the stage; never interpreted by rc
      output_path: "/usr/local/bin/my-tool"          # artifact copied into the runtime image
```

**Worked example:** [building-from-source.md](building-from-source.md) — the full `rc build` flow (codegen → pre-build isolation gate → build → post-build ownership gate) and honest limits. Live instance: [examples/dcg/manifest-fragment.yaml](../../examples/dcg/manifest-fragment.yaml) (the `dcg` entry).

---

### 10. Fail-closed manifest validator (the contract on all of the above)

**What it is for:** the enforcement arm of "adding a tool can never become weakening the cage" ([ADR-005 D11](../decisions/ADR-005-ecosystem-tools.md) mechanism 2, **FIRM** — not skippable, wired into every build path). Every *manifest entry* composed through seams 1–9 is bounded by it (seam 2's `.rip-cage.yaml` `config_mode` half is project-config validation, outside this validator; its `mounts:`-entry half is covered): strict-parse field validation, hook-bounds (no floor-weakening hook commands), IOC egress floor, secret-path mount denylist + dest allowlist, builder-stage isolation scan, and post-build root-owned assertions on binaries and declared mount assets. A violation fails the build with a named error.

**Manifest/config shape:** none — it is not composed, it bounds composition. Author entries to satisfy it.

**Doc:** [manifest-validator.md](manifest-validator.md) — the complete catalog of checks and error messages (by `rc` function name), so a manifest author can predict failures without reading `rc` source.

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
| [config.md](config.md) | Layered `.rip-cage.yaml` config: `session.multiplexer`, `mounts.config_mode` (ro/rw), `mounts.denylist`, `network.*` msb egress allowlist, `auth.credentials`, `dcg.*` policy, `mounts.symlinks.*`; merge rules; `rc config show` (`rc config init` is retired) |
| [ssh-routing.md](ssh-routing.md) | **Retired** — ssh identity routing (`--github-identity`, identity rules file, banner states) no longer exists in `rc`; kept as a historical record, with a pointer to the current HTTPS + `--secret` path |
| [git-lfs.md](git-lfs.md) | Git LFS: what rip-cage does (and doesn't) fetch; LFS pointer stub advisory warning |

### Safety and security
| File | What it covers |
|---|---|
| [safety-stack.md](safety-stack.md) | PreToolUse hooks (DCG — the sole surviving composable command-guard recipe; ssh-bypass retired), `bypassPermissions` mode, hard-denied operations (`.git/hooks/*`), secret-path denylist, running `rc test` |
| [egress.md](egress.md) | msb egress allowlist: default-deny + `network.allowed_hosts`, `rc allowlist` commands, the deny→fix→reload repair loop (there is no observe mode post-cutover) |

### Composition and seams
| File | What it covers |
|---|---|
| [composition-seam.md](composition-seam.md) | **Mostly retired** — the manifest MEDIATOR provider archetype and its `network.http.forward_to` launch seam are deleted ([ADR-029](../decisions/ADR-029-msb-migration.md) D2/D5); the page now points at the current `auth.credentials`/`--secret` non-possession path and notes that L7 content-policy composition is fully operator-driven and unwired today |
| [adding-a-tool.md](adding-a-tool.md) | Step-by-step: add a plain binary-on-PATH tool via a TOOL manifest entry; apt-install and curl/binary paths; runtime mounts |
| [shell-integration.md](shell-integration.md) | SHELL-INTEGRATION archetype walkthrough: eval-into-shell mechanics, the two-entry (TOOL + SHELL-INTEGRATION) pattern, interactive-shell scope |
| [in-cage-daemon.md](in-cage-daemon.md) | Generic IN-CAGE-DAEMON archetype walkthrough: install-at-build/start-at-init/fail-warn contract, manifest shape, DAEMON-vs-TOOL decision aid |
| [agent-mail-daemon.md](agent-mail-daemon.md) | IN-CAGE-DAEMON worked example: `mcp-agent-mail` running as a manifest-declared in-cage daemon (the C5 archetype) |
| [building-from-source.md](building-from-source.md) | From-source TOOL builds: the `build_source` generic builder stage, `rc build` flow, isolation gates, honest limits (ADR-005 D11 mechanism 1) |
| [manifest-validator.md](manifest-validator.md) | The fail-closed manifest validator contract: every check and error message, by `rc` function name (ADR-005 D11 mechanism 2, FIRM) |
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
