# ADR-015: Project Toolchain Provisioning via Mise

**Status:** Accepted
**Date:** 2026-04-22
**Design:** [Project Toolchain Provisioning](../2026-04-22-toolchain-provisioning-design.md)
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud), [ADR-002](ADR-002-rip-cage-containers.md) (blast radius), [ADR-005](ADR-005-ecosystem-tools.md) (ecosystem tools pattern), [ADR-012](ADR-012-egress-firewall.md) (egress allowlist), [ADR-013](ADR-013-test-coverage.md) (tiered tests)

## Context

On 2026-04-21, an agent inside a rip-cage container failed to run `yarn` while typechecking a Node project — yarn is not installed in the image. The agent eventually worked around it via `npx --yes yarn`, but that pattern is Node-only; a Rust, Go, Elixir, Ruby, or Java project would have had no equivalent path. Post-mortem investigation confirmed the base image ships Node + npm + bun + uv + Python and nothing else ecosystem-wide.

The underlying question: **when a project declares a toolchain, how does the cage honor it?** Three answers exist:

1. **Bake every conceivable language into the image.** Bloat; version wrong for half of projects; doesn't scale past a handful of ecosystems.
2. **Let each project ship a `.rip-cage/bootstrap.sh` that runs at container start.** Maximally flexible; covers apt packages and custom binaries too; but introduces a new auto-execute-on-boot surface (any PR branch you `rc up` runs arbitrary shell before the agent does anything) and produces no shared caching or uniformity across projects.
3. **Adopt a project-toolchain manager as plumbing that reads the standard files projects already have (`.nvmrc`, `rust-toolchain.toml`, `go.mod`, `.tool-versions`, `package.json`'s `packageManager`, etc.).** No per-project rip-cage config for the common case; uniform caching; well-defined trust boundary (versioned tools fetched from pinned registries, not arbitrary bash).

Answer 1 is what we have de facto for a handful of tools and is the status quo being rejected. Answer 2 is a real future option but has a blast-radius cost (per ADR-002) that exceeds the immediate problem. Answer 3 matches the cage's existing trust model and happens to solve the "yarn not found" case for free — projects that already declare `packageManager: yarn@1.22.22` get yarn without any rip-cage-specific file.

## Decisions

### D1: Mise is blessed plumbing; the user never interacts with it

**Firmness: FIRM**

Mise (formerly `rtx`) is installed into the base image as a single binary at `/usr/local/bin/mise`. It is activated by the agent's `~/.zshrc` via `eval "$(mise activate zsh)"`. From the user's perspective, the mechanism is invisible: they run `rc up`, and the toolchain declared by the project (via `.nvmrc`, `package.json` `packageManager`, `rust-toolchain.toml`, `.python-version`, `.tool-versions`, `.mise.toml`, `go.mod`, etc.) is on PATH before the agent's first prompt. The user does not install mise on their host, does not learn mise commands, and does not write rip-cage-specific files to get toolchain support.

**Rationale:** The failure we're solving is "the toolchain I need isn't available." The cleanest solve is a mechanism that reads files projects already have and fetches the declared versions. Mise is a mature, single-binary, multi-language incarnation of that pattern, with a shared data dir that composes well with Docker volumes. Making it plumbing (rather than a user-facing tool) keeps rip-cage's surface area small: one more thing in the image, zero more things for the user to learn.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Mise as plumbing (this decision)** | Reads standard project files; zero per-project rip-cage config for common cases; shared cache; multi-language | One more pinned dependency in the image; not a solution for non-runtime needs (apt packages) |
| Bake all toolchains into the image | Zero runtime cost; offline-friendly | Bloat (100s of MB per language × versions); one version per language is wrong for most projects; doesn't scale |
| `.rip-cage/bootstrap.sh` per project | Maximally flexible; covers apt + arbitrary binaries | Auto-executes on every `rc up` before agent runs; no shared caching without per-project work; duplicative; new trust-boundary risk |
| asdf | Same ecosystem; long-standing | Shell-plugin architecture (slower activation, bash/zsh-only); mise supersedes it for our use |
| Nix / flakes | Maximal reproducibility | Steep learning curve; large store; doesn't compose with `apt`-based image; overkill for the failure mode |
| Devcontainer Features | Declarative; ecosystem standard | Build-time only; doesn't match the `rc up` flow where workspace files drive provisioning at container-start |
| Lazy `command_not_found_handler` auto-install | Zero up-front cost | Surprising latency; no version signal without declarative input anyway |

**What would invalidate this:** Mise going unmaintained (unlikely near-term; ~20k stars, active jdx stewardship); or a sustained pattern of projects needing non-runtime provisioning (apt packages, custom binaries) that dwarfs the runtime case — at which point Option 2 (`bootstrap.sh`) becomes the primary mechanism and mise becomes secondary. Revisit.

### D2: Shared Docker named volume for the mise data dir

**Firmness: FIRM**

A single `rc-mise-cache` named volume is mounted at `/home/agent/.local/share/mise` in every rip-cage container, across every project on the host. Toolchain downloads are paid once per (tool, version) and reused forever.

- Volume name: `rc-mise-cache` (literal, not `${container}`-suffixed — unlike `rc-state-${name}` and `rc-history-${name}`).
- Populated by mise on first use; keyed by content (tool + version).
- **Not** deleted by `rc destroy`. `rc destroy` is per-container; the cache is host-scoped. Manual reset via `docker volume rm rc-mise-cache` when needed.

**Rationale:** Without a shared cache, every container pays the download cost independently and the overall pattern is slower than the status quo `npx --yes`. The content-addressable nature of the mise install dir makes sharing safe — two containers installing node@22.11.0 produce byte-identical trees. Named volume (rather than bind-mount) keeps it on the Docker side, avoids host FS pollution, and doesn't require user-visible paths.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Shared named volume, host-scoped (this decision)** | One download per (tool, version); survives container destroy; no host FS pollution | Requires manual reset for corruption; growth unbounded without GC |
| Per-container named volume (pattern of `rc-state-${name}`) | Trivial cleanup | Repeats every download per container; defeats the point |
| Bind-mount to `~/.cache/rip-cage-mise` on host | Visible in host FS; trivial inspection | Platform-coupled perms (Docker Desktop on macOS = slow); noise in host HOME |
| No cache, fresh install per container | Simplest | Every `rc up` takes 30s-2min; the failure mode we're supposedly fixing |

**What would invalidate this:** Disk pressure on the host such that the unbounded cache becomes a problem. Mitigation then is `rc mise-cache-gc` / manual `docker volume rm` with a rebuild policy. Not worth pre-building.

### D3: `init-rip-cage.sh` runs `mise install` when workspace declares a toolchain

**Firmness: FIRM**

A new step in `init-rip-cage.sh` (between git-identity and Claude-Code-verify) detects whether `/workspace` contains any of a small set of recognized tool-declaration files (`.mise.toml`, `mise.toml`, `.tool-versions`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `rust-toolchain.toml`, `go.mod`). If yes, it runs `mise install` in the workspace, logging output. If no, it skips silently.

Install failures log a WARNING to stderr but do **not** abort container startup.

**Rationale:** Provisioning has to happen before the agent's first prompt, otherwise the agent keeps hitting "command not found." `init-rip-cage.sh` is the only point in the lifecycle where the workspace is known-available and the agent has not yet run. Fail-loud (WARNING visible in init output + log file path named) preserves ADR-001's spirit; non-fatal (no `exit 1`) avoids the failure mode where a malformed `.tool-versions` bricks the container. A broken declaration is a thing the agent can observe and repair from inside; an un-startable container is not.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Install at init, warn on failure (this decision)** | Toolchain ready when agent starts; observable failures | ~30s init-time cost on first `rc up` per (tool, version) |
| Install lazily on first shell activation | Zero init cost if user never shells in | First interactive command still blocks on download; surprising |
| Install only when `mise install` invoked manually | Zero side effects | Defeats the point — agents don't know to run it |
| Fail-loud with `exit 1` on install errors | Strict ADR-001 compliance | A malformed project file bricks the cage; worse than status quo |

**What would invalidate this:** If `mise install` latency on first `rc up` becomes painful in practice (e.g., multi-minute Rust toolchain downloads every time a new version is cut), move install to a background step that the agent can `wait` on. Not needed today.

### D4: Trust `/workspace` tool files automatically inside the cage

**Firmness: FIRM**

The Dockerfile sets `ENV MISE_TRUSTED_CONFIG_PATHS=/workspace`, which causes mise to treat `/workspace/**/.mise.toml` and `/workspace/**/.tool-versions` as pre-trusted. No `mise trust` prompt is issued; no hidden trust database entries are written.

**Rationale:** Mise's trust model targets users running mise on their host machine, where `.mise.toml` can contain arbitrary `[hooks]` shell code. Inside the cage, the trust boundary already happened at `rc up` — you trusted the workspace enough to mount it into a `bypassPermissions` container. A second trust layer at the mise level adds only agent-unfriendliness (the agent can't answer an interactive trust prompt), not security. Scoping the trust to `/workspace` (as opposed to `MISE_YES=1` globally) is the narrower form and sufficient.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Trust `/workspace` specifically (this decision)** | Narrow scope; agent-friendly; matches cage trust boundary | Trusts any `[hooks]` declared by the mounted project |
| `MISE_YES=1` global auto-confirm | Simpler | Broader than needed; silences all future mise prompts, not just trust |
| Pre-seed the mise trust DB at agent-user creation time | Appears explicit | Requires knowing the workspace path at image build; we don't; also fragile across paths |
| Default mise behavior (prompt for trust) | Matches upstream | Prompts that the agent cannot answer; blocks init |

**What would invalidate this:** A future ADR on hostile-repo isolation (e.g., a "review this PR without trusting it" mode) where the workspace mount is explicitly quarantined. That mode would disable this env var; tracked as a future concern, not blocking.

### D5: `bootstrap.sh` escape hatch is deferred, not rejected

**Firmness: PROVISIONAL**

A `.rip-cage/bootstrap.sh` mechanism that runs arbitrary project-supplied shell at container start is **not** shipped in this ADR. It is also not permanently rejected. The leading use case (apt-level system libraries like `libpq-dev` / `ffmpeg`, or project-local binaries not in mise) is real but has not yet produced concrete demand.

If it's added later, the shape should be:

- Opt-in per container (e.g., `RC_ALLOW_BOOTSTRAP=1` env var passed by `rc up --with-bootstrap`), not opt-out. Auto-executing project-supplied shell on `rc up` is a meaningful change to the cage's trust model — it should be a deliberate user action.
- Subject to the egress firewall (ADR-012) like everything else.
- Documented loudly in the init output when invoked.

**Rationale:** YAGNI. The cost of shipping a speculative escape hatch is a persistent auto-execute surface that's easy to forget about; the cost of adding it later when a real need appears is one ADR.

**What would invalidate this (i.e., trigger adding bootstrap.sh):** Three or more distinct projects hitting provisioning needs mise can't cover (apt packages, custom binaries). Track via beads.

## Deferred

- **`rc mise-cache-gc` command.** A convenience to prune stale versions from `rc-mise-cache`. Not needed until disk pressure becomes a real complaint.
- **Offline / air-gapped mode.** The cache enables offline reuse of already-downloaded versions, but there's no pre-seed mechanism for workstations that never had internet. Edge case; tracked separately if it ever matters.
- **Per-project override of the shared cache.** Some teams may want per-project mise caches for isolation. Possible via an `rc up --mise-cache=<name>` flag later; not worth pre-building.
- **Non-runtime provisioning (apt, custom binaries).** See D5 — deferred to a future `bootstrap.sh` ADR if demand materializes.
