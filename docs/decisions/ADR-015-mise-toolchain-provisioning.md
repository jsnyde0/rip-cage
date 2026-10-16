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
| **Mise as plumbing (this decision)** | Reads standard project files; zero per-project rip-cage config for common cases; cached installs (per cage, D2); multi-language | One more pinned dependency in the image; not a solution for non-runtime needs (apt packages) |
| Bake all toolchains into the image | Zero runtime cost; offline-friendly | Bloat (100s of MB per language × versions); one version per language is wrong for most projects; doesn't scale |
| `.rip-cage/bootstrap.sh` per project | Maximally flexible; covers apt + arbitrary binaries | Auto-executes on every `rc up` before agent runs; no shared caching without per-project work; duplicative; new trust-boundary risk |
| asdf | Same ecosystem; long-standing | Shell-plugin architecture (slower activation, bash/zsh-only); mise supersedes it for our use |
| Nix / flakes | Maximal reproducibility | Steep learning curve; large store; doesn't compose with `apt`-based image; overkill for the failure mode |
| Devcontainer Features | Declarative; ecosystem standard | Build-time only; doesn't match the `rc up` flow where workspace files drive provisioning at container-start |
| Lazy `command_not_found_handler` auto-install | Zero up-front cost | Surprising latency; no version signal without declarative input anyway |

**What would invalidate this:** Mise going unmaintained (unlikely near-term; ~20k stars, active jdx stewardship); or a sustained pattern of projects needing non-runtime provisioning (apt packages, custom binaries) that dwarfs the runtime case — at which point Option 2 (`bootstrap.sh`) becomes the primary mechanism and mise becomes secondary. Revisit.

### D2: One mise cache volume per cage

**Firmness: FIRM**

> **Evolved 2026-10-16 (rip-cage-p4ss.2, human ruling via brain:rip-cage).** This decision used to be ONE `rc-mise-cache` volume shared read-write by every cage on the host and kept past `rc destroy`. The isolation review (`docs/2026-10-03-isolation-boundary-review.md`) showed that shared volume is a persistent cross-cage channel: any cage — including one steered by injected instructions (ADR-024) — can replace `installs/<tool>/<v>/bin/<tool>` or a shim, and every later cage of every project puts it on its PATH. It survived destroy, recreate and image rebuild, outside every per-project mount and the protected-paths check. Confirmed live: under the shared name, a second cage saw a file the first planted (`tests/test-mise-cache-isolation-live.sh`, run red against the old template). "Content-addressable, so sharing is safe" held only for honest writers. Accepted cost: each cage pays its own first download, and disk grows per cage.

Each cage gets its own mise data volume, `rc-mise-cache-<cage>`, mounted at `/home/agent/.local/share/mise`. No writable tool cache is shared between cages.

- Declared in the cage config (`share/rip-cage/cage.yaml.template`), keyed on the cage name exactly like `rc-state-<cage>` and `rc-history-<cage>`: the operator substitutes `<CAGE-NAME>` once for all three.
- Populated by mise on first use in that cage. It survives stop, resume and `rc up --replace`, so a download is paid once per (cage, tool, version).
- **Deleted by `rc destroy`** with the cage's other two volumes. A config still naming the old shared `rc-mise-cache` keeps booting; `rc destroy` never touches that shared volume. After renaming the line, remove it with `msb volume remove rc-mise-cache`.

**Rationale:** The cache exists so that an `rc up` does not pay 30s–2min of downloads. Per-cage keeps that for the common loop — one project, many resumes and recreates — and gives up only cross-project reuse, which is exactly the sharing that let one cage's write become another cage's code.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Per-cage named volume (this decision)** | No cross-cage write path; reaped with the cage; same keying as the other two volumes | Every cage pays its own first download; disk per cage |
| Shared read-write named volume, host-scoped (the pre-2026-10-16 decision) | One download per (tool, version), host-wide | Persistent cross-cage compromise channel; survives destroy |
| Shared volume, read-only at runtime, populated at build time | Cross-project reuse with no write path | Needs a build-time populate step per tool set; a runtime `mise install` of an undeclared version fails |
| `mise --locked` checksum verification on use | Keeps the share | Covers only tools with lockfile checksums; shims and plugins stay writable |
| No cache, fresh install per boot | Simplest | Every `rc up` takes 30s–2min |

**What would invalidate this:** Per-cage download time or disk use becoming a sustained complaint. The next step then is the read-only, build-time-populated shared cache — never a writable share.

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

**Firmness: EXPLORATORY** *(provisional; assigned to the nearest enum level by the 2026-09-23 firmness normalisation)*

A `.rip-cage/bootstrap.sh` mechanism that runs arbitrary project-supplied shell at container start is **not** shipped in this ADR. It is also not permanently rejected. The leading use case (apt-level system libraries like `libpq-dev` / `ffmpeg`, or project-local binaries not in mise) is real but has not yet produced concrete demand.

If it's added later, the shape should be:

- Opt-in per container (e.g., `RC_ALLOW_BOOTSTRAP=1` env var passed by `rc up --with-bootstrap`), not opt-out. Auto-executing project-supplied shell on `rc up` is a meaningful change to the cage's trust model — it should be a deliberate user action.
- Subject to the egress firewall (ADR-012) like everything else.
- Documented loudly in the init output when invoked.

**Rationale:** YAGNI. The cost of shipping a speculative escape hatch is a persistent auto-execute surface that's easy to forget about; the cost of adding it later when a real need appears is one ADR.

**What would invalidate this (i.e., trigger adding bootstrap.sh):** Three or more distinct projects hitting provisioning needs mise can't cover (apt packages, custom binaries). Track via beads.

## Deferred

- **Offline / air-gapped mode.** The cache enables offline reuse of already-downloaded versions, but there's no pre-seed mechanism for workstations that never had internet. Edge case; tracked separately if it ever matters.
- **Non-runtime provisioning (apt, custom binaries).** See D5 — deferred to a future `bootstrap.sh` ADR if demand materializes.
