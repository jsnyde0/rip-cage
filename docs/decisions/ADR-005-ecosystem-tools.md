# ADR-005: Ecosystem Tools Integration

**Status:** Proposed (revised 2026-06-15 — added **D12** [rip-cage is a composable seam, not a bundler — rc never names/bundles/blesses an optional tool; defaults ship minimal; examples live outside the binary]; **D9** clarified [session-multiplexer provider hooks are availability-payload, not interceptors]; **D11** mechanism-2 extended [the fail-closed validator bounds multiplexer provider hooks like `install_cmd`]. Discovered fixing rip-cage-kqvw [herdr leaked into the default manifest — an optional multiplexer pre-installed for every cage, dispatched via a hardcoded `case` in `rc`]. Prior: revised 2026-06-14 — D1/D3/D4 statements corrected to reality [rip-cage-hqvk]: the build-arg customization layer they described — per-tool `INCLUDE_<TOOL>` toggles, a repo-root `versions.env`, and `rc build --with/--full/--minimal` flags — was never built. The host-only manifest [D7–D11] is the realized tool-inclusion + version-pin surface; bundled-tool versions ship as hardcoded Dockerfile `ARG` defaults; per-cage selection [the `--with` role] is deferred onto the manifest [Open-decision 8]. D11 mechanism-2 binary-root-owned coverage clarified: it runs against a declarable binary path [from-source `output_path` + prebuilt `binary_path`, rip-cage-ryn6], not literally every tool. The FIRM cores of D1/D3/D4 [install-at-build-not-runtime, pin-not-`latest`, `rc`-is-the-interface] are unchanged. Prior: revised 2026-06-12 — D11 mechanism 2 adds the entrypoint-completeness clause [the fail-closed validator must be wired into every build path, not only `rc build`], discovered-and-closed via the `rc up` auto-build bypass rip-cage-buuo.6. Prior: revised 2026-06-10 — D11 adds the agent-first composability surface [generic builder stage + fail-closed validator + authoring skill]; D2 demotes cm from bundled-default to manifest worked example; D6 generalizes the from-source fallback into D11's generic stage. Prior: revised 2026-06-05 — D7–D10 add the composable host-only tool manifest)
**Date:** 2026-03-27
**Design:** [Ecosystem Tools Design](../2026-03-27-ecosystem-tools-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [Flywheel Investigation](../2026-03-27-flywheel-investigation.md)

## Context

Rip-cage's Phase 1 delivered a safety stack (DCG + compound command blocker) inside a containerized environment. The next step is integrating external tools that make agents more effective: bug scanning (UBS), network monitoring (RANO), session search (CASS), task visualization (bv), and procedural memory (CM). These tools are independently developed projects with their own release cycles. The question is how to integrate them without bloating the base image or creating maintenance burden.

**2026-06-05 extension (D7–D10):** D1–D6 cover *maintainer-curated* ecosystem tools toggled by build args. D7–D10 generalize that into a **composable, declarative, host-only tool manifest** so that any user (not just a rip-cage maintainer editing the Dockerfile) can add a tool — including shell-integration tools and in-cage coordination daemons such as agent_mail — and so the safety contract of "adding a tool" is canonical. The manifest is the build-time composition surface D3's `versions.env` and D5's 4-point pattern were the first instance of; D7 names the general mechanism, D8–D9 bound what it may touch, D10 sets the failure asymmetry. The manifest's exact format and storage location remain EXPLORATORY and live on bead `rip-cage-4c5`, not here — this ADR canonicalizes the *contract*, not the schema.

## Decisions

### D1: Ecosystem tools are integrated at build time, not via runtime plugins

**Firmness: FIRM** (statement revised 2026-06-14 — the per-tool `ARG INCLUDE_<TOOL>=true|false` toggle was never realized; the host-only manifest [D7] is the tool-inclusion mechanism. The FIRM core — install at build time, never a runtime plugin/download — is unchanged.)

Ecosystem tools are installed at **build time** — never via a runtime plugin system, dynamic download, or post-start installation. This build-time-not-runtime rule is the FIRM, load-bearing invariant; it is what D7's manifest and D11's builder stage inherit.

**Realized mechanism (revised 2026-06-14):** the per-tool `ARG INCLUDE_<TOOL>=true|false` toggle this decision originally specified was *not* built. Tool *inclusion* is instead governed by the host-only manifest (D7–D11): the sole bundled tool (UBS, D2) is baked unconditionally into the image, and every other tool is added as a manifest entry. The build-time invariant holds exactly as stated; only the per-tool-build-arg toggle as the inclusion mechanism was superseded by the manifest (see Context, 2026-06-05 extension).

**Rationale:** Build-time composition produces deterministic, reproducible images. Runtime plugin systems add complexity (download failures, version mismatches, startup latency) without meaningful benefit — users rebuild images infrequently and want consistent environments. The Dockerfile already has a multi-stage pattern (Go builder, Rust builder, runtime) that naturally accommodates conditional tool installation.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Build-arg toggles** | Deterministic, reproducible, fits existing Dockerfile pattern | Must rebuild image to change tools |
| Runtime plugin download | Change tools without rebuild | Non-deterministic, download failures, startup latency |
| Separate image per tool combo | Maximum isolation | Combinatorial explosion of images |
| Docker multi-stage with `--target` | Clean separation | Doesn't support conditional inclusion within a stage |

**What would invalidate this:** Tool set changes so frequently that rebuilding the image becomes a bottleneck. In that case, consider a volume-mounted tool directory with version-locked binaries.

### D2: UBS is the sole bundled-default external tool; the bundled bar is "integral to operating the cage"

**Firmness: FLEXIBLE** (revised 2026-06-10 — cm DEMOTED from bundled default back to the manifest worked example, rip-cage-l0u2 reframe; reverts the 2026-06-09 cm-as-default revision)

UBS (Ultimate Bug Scanner) ships in the default image — baked unconditionally (the `INCLUDE_UBS` build-arg toggle of D1's original design was not built; see D1 realized-mechanism note). **cm (CASSMS / CASS memory system) is NOT bundled** — it is the *worked example* of the host-only tool manifest (D7, D11), provisioned opt-in like any user tool, never baked unconditionally. All other evaluated tools (bv, RANO, CASS) likewise remain not bundled.

The bundled-default bar is **"integral to operating the cage."** The safety stack (DCG, ssh-blocker, egress proxy), auth, and the task tracker (bd) are baked into the image because the cage's *own operation* depends on them — they are cage infrastructure, not ecosystem tools toggled by D1–D6. UBS earns the one ecosystem-tool default slot because its value-to-cost is exceptional (a 3MB bash script, no compilation, catches bugs across 9 languages in <5s, directly improves auto-mode safety by gating commits). Everything an agent merely *uses* rather than something the cage *operates with* — cm included — goes through the manifest.

**Rationale:** UBS has the highest value-to-cost ratio of any tool evaluated, and gating commits is close enough to a safety function to justify baking. cm's brief default slot (added 2026-06-09 under rip-cage-l0u2) was reverted on reframe: bundling a niche memory tool by default contradicts rip-cage's composability posture. rip-cage ships the *mechanism* to add any tool (D7) with cm as the worked example a user opts into — not first-class support for one specific tool. Most users won't use cm (it's niche), so baking it into every image is exactly the bespoke-per-tool integration the manifest exists to avoid. The manifest + the authoring skill (D11) make opt-in cheap, so demotion costs the cm user little while keeping the default lean and tool-agnostic.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **UBS only (cm via manifest)** | Lean, tool-agnostic default; cm is the manifest's worked example | cm users opt in rather than getting it for free |
| Keep cm bundled by default (the 2026-06-09 position) | cm user gets memory-continuity with zero setup | `reasoned:` baking one niche tool is the bespoke per-tool integration the manifest (D7/D11) exists to replace; contradicts "ship the mechanism, not specific tools"; most users won't use cm. |
| UBS + RANO | Safety + observability | `reasoned:` RANO adds 8MB and complexity for a tool most users won't need immediately; it belongs in the manifest, not the default. |
| All tools default | Feature-rich out of the box | `reasoned:` ~200MB larger, longer build, and ships tools users don't need — the opposite of the lean, tool-agnostic default. |
| No external tools default | Smallest image | `reasoned:` misses the highest-value addition (UBS), whose value-to-cost clears the bundled bar. |

**What would invalidate this:** An ecosystem tool proving higher value-to-cost than UBS for the default use case (e.g. a lighter bug scanner). cm specifically would re-cross the bundled bar only if it became integral to the cage's *operation* rather than the agent's workflow — e.g. rip-cage itself coming to depend on cm for substrate — at which point it is cage infrastructure, not an ecosystem tool.

### D3: Tool versions are pinned, never floating

**Firmness: FIRM** (statement revised 2026-06-14 — no `versions.env` file was built; bundled-tool versions are hardcoded Dockerfile `ARG` defaults and user-tool versions live in the manifest `version_pin` field [D7]. The FIRM core — versions are pinned, never floating `latest` — is unchanged.)

Tool versions are **pinned, never floating `latest`** — the FIRM, load-bearing invariant (reproducible builds, no silent upstream breakage).

**Realized mechanism (revised 2026-06-14):** the repo-root `versions.env` file this decision originally specified was *not* built. Bundled-tool versions are **hardcoded Dockerfile `ARG` defaults** (`ARG BEADS_VERSION=v1.0.2`, `ARG DCG_VERSION=0.4.0`, `ARG BUN_VERSION=1.3.14`, `ARG MISE_VERSION=2026.4.5`, `ARG DOLT_VERSION=1.84.0`, …); `rc build` passes only `RC_VERSION` as a `--build-arg`. User-tool versions are pinned in the **manifest `version_pin` field** (D7), which generalized the centralized-version-pin idea from a single repo file into the per-entry manifest surface (see Context, 2026-06-05 extension, and D7). A separate `versions.env` would now duplicate machinery the manifest already provides.

**Rationale:** Pinned versions prevent silent breakage from upstream changes. A manifest file makes version bumps a single-file change that is easy to review, diff, and automate (e.g., Dependabot-style PRs). Build args are the standard Docker mechanism for parameterizing builds — no custom tooling needed.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Build args + versions.env** | Standard Docker pattern, single-file updates, easy to automate | Extra file to maintain |
| Hardcoded versions in Dockerfile | Simpler, fewer files | Versions scattered across Dockerfile, harder to review |
| `latest` tag always | No pinning needed | Non-reproducible builds, silent breakage |
| Lock file (versions.lock) | Cryptographic verification | Over-engineered for this use case |

**Realized (2026-06-14):** the chosen row's `versions.env` half was not built. Bundled-tool pins live as the "Hardcoded versions in Dockerfile" row's mechanism — acceptable at the current ~6-tool bundled count (the row's "harder to review" con is tolerable at this scale) — and user-tool pins live in the manifest `version_pin` field (D7), which is the realized form of "single-file centralization" for the open-ended tool set.

**What would invalidate this:** Tool count grows large enough that a proper dependency resolver (like Nix) would be more appropriate than a flat env file.

### D4: `rc` is the primary interface for tool selection (specific `--with` flags deferred)

**Firmness: FIRM** (statement revised 2026-06-14 — the `--with/--full/--minimal` flag surface is DEFERRED, not shipped: per-cage tool selection layers onto the host-only manifest [Open-decision 8 / rip-cage-4c5], `rc`:6852–6854. The FIRM core — `rc` is the primary interface; users shouldn't hand-write Docker `--build-arg` syntax — is unchanged as intent.)

**Intent (FIRM):** `rc` is the primary interface for tool selection — users should not need raw Docker `--build-arg` syntax.

**Realized status (revised 2026-06-14):** the specific `--with <tool>` / `--full` / `--minimal` flag surface was *not* shipped. Per-cage tool selection is **DEFERRED** (Open-decision 8 on the manifest epic rip-cage-4c5; `rc` records the deferral at lines 6852–6854) and will layer on top of the host-only manifest (D7) — the realized tool-composition surface — not on standalone build-arg flags. The example block below is the originally-envisioned UX, retained as the deferred target shape, not current behavior.

```bash
rc build                          # Default: core + UBS
rc build --with rano              # Add RANO
rc build --with rano --with cass  # Add RANO + CASS
rc build --full                   # Everything
rc build --minimal                # Core only
```

**Rationale:** Users should not need to know Docker build-arg syntax. `--with rano` is self-documenting and discoverable via `rc build --help`. The flag names match the tool names used throughout documentation. This is consistent with ADR-003's principle that `rc` is the primary interface for all container operations.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **`--with <tool>` flags** | Self-documenting, discoverable, matches tool names | Must maintain flag-to-arg mapping |
| Raw `--build-arg` passthrough | No new code | Poor UX, leaks Docker abstraction |
| Config file (rc.yaml) | Persistent preferences | Another config file, overkill for build-time choice |
| Profiles (rc build --profile heavy) | Curated combos | Opaque, hard to customize |

**What would invalidate this:** Tool count grows beyond ~10, making individual `--with` flags unwieldy. In that case, consider a config file or profile system.

### D5: Standard integration pattern for each tool

**Firmness: FIRM**

Every tool follows the same four-point integration pattern:

1. **Dockerfile:** Conditional install via build arg
2. **init-rip-cage.sh:** Conditional config via `command -v` runtime detection
3. **CLAUDE.md:** Always document available tools (agents should know their environment)
4. **settings.json:** Optional hook registration (e.g., UBS as pre-commit gate)

The init script uses runtime detection (`command -v tool`), not build args, so it works correctly regardless of which tools are in the image.

**Rationale:** A standard pattern makes tool additions mechanical. A contributor adding a new tool follows a checklist, not a design process. Runtime detection in init decouples the init script from the Dockerfile — you can swap tool installation methods (source build vs. pre-built binary) without changing init.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Standard 4-point pattern** | Mechanical additions, decoupled init | Slightly more boilerplate per tool |
| Ad-hoc per tool | Flexibility | Inconsistent, harder to maintain |
| Plugin manifest (tools.json) | Machine-readable tool registry | Over-engineered, another file to parse |
| Init reads build args from labels | Build-time and runtime in sync | Tighter coupling, Docker label complexity |

**What would invalidate this:** Tools require fundamentally different integration patterns (e.g., a tool that needs kernel modules or Docker socket access). In that case, extend the pattern rather than abandoning it.

### D6: Prefer pre-built binaries from GitHub releases over source compilation

**Firmness: FLEXIBLE** (revised 2026-06-09 — cm is the first realized from-source-fallback instance, rip-cage-l0u2)

When a tool publishes pre-built binaries for linux/arm64 and linux/amd64, download those in the Dockerfile rather than compiling from source. Fall back to source compilation only when pre-built binaries are unavailable for the target architecture.

**Rationale:** Pre-built binaries make builds faster (no Rust/Go toolchain needed for that tool), produce smaller builder stages (no source tree or build cache), and reduce the chance of build failures from upstream dependency changes. The Dockerfile already compiles DCG and bd from source — adding more source builds increases build time and fragility. For tools like RANO and CASS that publish releases, downloading a binary is a single `curl` command.

**Realized instance (cm, rip-cage-l0u2) — being generalized into a manifest-driven generic builder stage (D11):** cm was the first tool to exercise the from-source fallback. cm is a Bun-compiled single binary whose upstream ships macos-x64/arm64, linux-x64, windows-x64 — but **no linux-arm64 release**, the architecture cages run on Apple Silicon. The first cut was a dedicated `cm-builder` Dockerfile stage that cross-compiles via `bun build src/cm.ts --compile --target=bun-linux-arm64 --outfile cm` (Bun's `--compile` cross-compiles from any host arch; no x64 emulation / Rosetta, contrast rip-cage-oc8); the runtime stage COPYs only the binary, keeping the Bun/node build toolchain out of the runtime layer (the beads/DCG builder-stage pattern). That hand-written stage is a *worked example*, not the final shape: D11 generalizes "fall back to source" from a maintainer hand-coding one stage per tool into a single **manifest-driven generic builder stage** (declared builder image + host-side build script + output path, run isolated). Because the generic stage targets the build platform, it is **arch-adaptive by construction** — which is *slated to* subsume the cm-specific arch-hardcode limitation tracked as rip-cage-ywek. Note the subsumption is not yet realized: the `cm-builder` stage in the Dockerfile still carries the hand-pinned `--target=bun-linux-arm64`; it is removed only when cm is moved onto the generic stage (the cm-demotion work, rip-cage-buuo.5).

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Pre-built binaries preferred** | Fast builds, small stages, simple | Trust upstream build, no local patching |
| Always compile from source | Full control, can patch | `reasoned:` slow builds, large builder stages, toolchain deps for every tool — the prebuilt path avoids this for the common case. |
| Vendor binaries in repo | No network dependency at build time | `reasoned:` bloats the repo and makes updates manual; the from-source builder stage gives reproducibility without vendoring. |
| Nix or Guix for all tools | Reproducible, declarative | `reasoned:` heavy dependency and unfamiliar tooling — over-engineered relative to "prefer prebuilt, else one generic builder stage." |

**What would invalidate this:** Need to patch tools locally (e.g., rip-cage-specific modifications) — fork the tool and compile from source. Separately, the **generic builder stage** mechanism this decision now folds in (D11) should be reconsidered if a from-source tool's build cannot be expressed as "builder image + script + output" (e.g. it needs the host filesystem or cross-stage interdependence), at which point the builder mechanism is *extended*, not abandoned.

### D7: Tool composability is a declarative, host-only manifest with four archetypes

**Firmness: storage-location FIRM (host-only `~/.config/rip-cage/`); schema/format EXPLORATORY** (added 2026-06-05; storage-location resolved 2026-06-05; MULTIPLEXER added as the fourth archetype 2026-06-15, rip-cage-61al)

A declarative manifest — stored **host-side under `~/.config/rip-cage/`, agent-inaccessible**, consumed by `rc build` at build time, with the current bundled stack as its defaults — lets users add tools without forking the Dockerfile. It generalizes D3 (`versions.env` pinning) and D5 (the 4-point integration pattern) from a maintainer checklist into a user-facing composition surface. Each entry is one of four **archetypes**, defined by integration surface, that other beads and contributors reference as a constraint:

- **TOOL** — agent-invoked; integration is just reachability (binary on PATH) + declared egress + declared mounts. ~75% of a real ecosystem (ACFS phases 7–10).
- **SHELL-INTEGRATION** — integrates via a shell rc `eval` line (atuin, zoxide); one `shell_init` field.
- **IN-CAGE DAEMON** — a long-running localhost service other in-cage agents talk to (e.g. agent_mail); needs `start` + `health` + a state-dir placement + an optional MCP-registration fragment. The `mcp_fragment` is the reach mechanism for **MCP-capable agents only** (Claude Code) — it is *not* how every in-cage agent reaches the daemon. **Bash-only agents (pi, no MCP bridge) reach the same daemon via the daemon's own CLI over their bash tool**, not via MCP (ADR-019 D9; agent_mail's `am mail` CLI is the worked example). A daemon that wants to serve bash-only agents must ship a CLI; `mcp_fragment` alone reaches only MCP clients.
- **MULTIPLEXER** — a session multiplexer the agent's interactive session runs *inside* (tmux, herdr, zellij). Declares provider hooks: `start` (launch its server/session at cage init) and `attach` (connect a client) **required**; `exec` / `new-session` / `teardown` **optional** and tiered — a provider supplies only the hooks it supports. `rc` dispatches the per-cage `session.multiplexer` selection (ADR-021 D6) to the declared `start`/`attach` hooks, replacing the former hardcoded `none|tmux|herdr` `case`; the allowed-set is derived from the baked provider registry, **not** an `rc` enum. Provider hooks are **availability-payload** (D9 multiplexer clarification), **build-time-bounded by D11's validator** (a hook may not weaken the welded floor), and ship as `examples/` providers, never a blessed set (D12). The realized mechanism (baked registry, image label, reference reader, dynamic config derivation) is documented in D9 below.

Tools are **installed at build time** (consistent with D1 — no runtime download/plugin); a daemon archetype's process is merely **started at init**, the same lifecycle rip-cage already uses for the egress proxy, ssh-agent-filter, and tmux. "Install = build-time, start = init-time" — D1 forbids runtime *installation*, not daemons that run.

**Rationale:** Editing the Dockerfile per tool forks the image per project and offers no shared default set or selection. A manifest decouples *what tools exist* from *how they install* (the ACFS pattern: manifest → generated install steps → selection), and the archetype enum keeps the integration surface finite and reviewable.

**Storage location is host-only by construction (FIRM).** The security property D7 requires — *no agent-authored tool reaches a built cage unreviewed* — comes from the agent being unable to reach the manifest file at all, **not** from the `rc build` step acting as a review gate. The egress/ssh-allowlist precedent (`.rip-cage.yaml`, workspace-resident, agent-writable) is safe because **application** is host-gated: an in-cage edit does nothing until a human runs `rc reload`/`rc up` (`rc` lines 3016–3017, 3082–3084). That gate is weaker for a tool manifest: `rc build` is routine and less-scrutinized than the deliberate `rc reload`, and a tool entry installs an **arbitrary binary on PATH** — a larger blast radius than one egress host (which still sits behind the IOC floor and the proxy regardless, ADR-012 D1). Putting the manifest host-side under `~/.config/rip-cage/` (alongside the existing global config home, ADR-021 D1) gives "only the human controls which tools a cage may contain" structurally, and needs zero net-new build-time diff-review tooling. **Accepted cost:** tool *definitions* are per-host-global, not per-project git-tracked — which binaries a machine's cages may contain is an operator/host concern, not a per-repo one. Per-cage *selection* (which subset of defined tools a given project gets) is deferred (an open decision on the epic, bead `rip-cage-4c5`) and is the place a workspace-visible, git-tracked, bounded knob can live later — selection cannot introduce a new binary, so it carries no pre-stage risk even when agent-writable.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Keep per-tool Dockerfile edits (D1–D6 only) | `direct:` adding a tool needs a new builder stage + rebuild (Dockerfile multi-stage, ADR-005 D1); forks the image per project, no shared default set, no selection — the gap this decision closes. |
| Runtime install-on-`up` / plugin loader | `reasoned:` an agent or injected workspace content that can trigger runtime install can expand its own capability surface; violates D1 FIRM. |
| Single "binary on PATH" archetype | `direct:` ~25% of a real ecosystem (ACFS phases 7–10) needs more than PATH — shell-init and daemon lifecycle have no expression in a PATH-only model. |
| Full ACFS-style rich schema (systemd units, cloud-cred injection, cross-host sync) | `reasoned:` violates rip-cage's 80/20; most fields serve cross-cage or cloud cases ruled out by D8 — ship the three the in-cage grain needs. |
| Manifest in workspace `.rip-cage.yaml`, agent-writable, gated only by host-run `rc build` (egress-config precedent) | `reasoned:` a prompt-injected agent can pre-stage a malicious tool entry and wait for a routine `rc build` to bake it; `rc build` is less-scrutinized than the deliberate `rc reload`, and a tool installs an arbitrary binary (bigger blast radius than one egress host). Per-project git-tracking does not outweigh the pre-stage hole. |
| Manifest in workspace, plus net-new `rc build` diff-review tooling to close the pre-stage hole | `reasoned:` recovers safety but only by building a whole human-in-the-loop diff-review surface; host-side storage gets the same "only the human controls it" property for free. Diff-review tooling is mooted by host-only storage. |

**What would invalidate this:** a common, legitimate tool fitting none of the three archetypes (and not a deferred cloud-CLI case); a validated need to add tools to an already-running cage without rebuild (which would reopen D1); or a validated need for tool *definitions* to be per-project and travel with the repo (which would reopen the storage-location choice and require the diff-review tooling the host-only decision moots).

**Clarification — agent_mail ships as DOCS + TEST FIXTURE only, NOT in the seeded default manifest (FLEXIBLE; user-decided 2026-06-06).** The in-cage-daemon worked example (agent_mail) is *not* seeded into the default manifest. Seeding a third-party daemon by default would (a) break the D8 byte-for-byte default-image invariant (it would add a daemon to every default build), and (b) put a third-party github reference + pinned commit into the shipped default config — threat-model-cleaner to keep out (ADR-024). So the worked example ships as reference documentation (`docs/reference/agent-mail-daemon.md`) and test fixtures (`tests/fixtures/manifest-agent-mail.yaml`), exercised by the harness, never as a seeded default. The default manifest's defaults remain the existing bundled stack (D2: UBS + core).

### D8: The manifest composes within ONE cage and never reaches across cages

**Firmness: FIRM** (added 2026-06-05)

Everything a manifest tool does happens inside one cage's isolation boundary: no shared-volume-across-containers, no cross-cage networking, no cross-cage coordination. An in-cage daemon binds its port once per cage (Docker gives each cage its own network namespace, so the same port in two cages is independent); init is idempotent (re-running init, or — once ADR-006 Tier 1a ships — a second in-cage agent, spawns no second binder). agent_mail therefore coordinates agents *within* a cage (co-tenants already sharing `/workspace`), adding no trust surface beyond the existing bind mount.

**Rationale:** Keeping the manifest single-cage means the welded floor stays untouched and there is no new cross-cage trust surface to reason about. It is also the structural answer to "should agents collaborate across cages": no — the manifest is simply never given the reach, rather than the reach existing and being policy-forbidden.

**Counter-argument (FIRM discipline):** A user might legitimately want two cages on one host (e.g. frontend + backend of one project) to share a mailbox, which FIRM forecloses without an ADR change. This does not overturn FIRM: cross-cage sharing requires a shared writable volume + cross-container network — exactly the prompt-injection poisoning surface ADR-024 names. Making it FIRM forces that to be a deliberate, reviewed ADR evolution, not a quiet manifest field; the safety-relevant default should be the hard one to cross. Cross-cage coordination belongs to the dotpi multi-cage / AFK-orchestration epic, not the per-cage manifest.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Allow cross-cage coordination (shared volume / bridge network) | `reasoned:` reintroduces a cross-cage trust surface + shared-volume poisoning under ADR-024; a different and larger design (dotpi multi-cage), not a manifest field. |
| One daemon instance per agent (not per cage) | `reasoned:` multiple binders contend for one port in a shared network namespace; per-cage-singleton is the only coherent model for a localhost service. |

**What would invalidate this:** a validated need for cross-cage agent coordination — at which point it is designed deliberately as its own ADR, not absorbed into the manifest.

**Clarification — what "byte-for-byte" scopes (FLEXIBLE).** The D8 byte-for-byte default-image invariant means "manifest-unchanged → no Dockerfile delta → no image change *from the manifest*." It is a statement about the *manifest's contribution* to the image, not absolute image immutability across intentional base changes. A deliberate base-image bump (ADR-002 D2a, debian:trixie) changes the image independently of the manifest; that does not violate D8, because the manifest contributed nothing to the change. The invariant the manifest owes is: an unchanged manifest must not, by itself, alter the built image.

### D9: The manifest affects tool *availability* only — never the welded safety floor

**Firmness: FIRM** (added 2026-06-05)

The manifest can install tools, declare their egress (which unions into the allowlist but stays under ADR-012's non-overridable IOC floor) and mounts (subject to the ADR-023 denylist), and start daemons. It can **never** register or alter lifecycle interceptors: PreToolUse hooks, DCG wiring (ADR-025 D2 baked floor), the ssh-bypass blocker, sudoers scope, or the non-root posture. The floor is welded; the manifest is payload.

**Rationale:** A safety interceptor enforces policy *on* the agent (push); a tool the agent merely *calls* (pull) cannot enforce anything — so safety layers are irreducibly interceptors, and a composition surface that could register them could disable them. Confining the manifest to availability keeps "adding a tool" from ever being "weakening the cage."

**Counter-argument (FIRM discipline):** A user might want to add their own pre-commit guard via the manifest, which D9 forecloses. This does not overturn FIRM: letting the manifest register hooks reopens the exact hole — a manifest edit, or a prompt-injected pre-staged entry awaiting the next `rc build`, could register a hook that weakens DCG. User-supplied interceptors are the cross-harness per-agent-registration problem (differs across Claude/Pi/Codex; dotpi W1/W2), genuinely separate work. "Manifest = availability only" is the load-bearing invariant that makes the whole composability surface safe.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Let the manifest add/replace lifecycle hooks (interceptor composability) | `reasoned:` per-agent registration differs across agents (cross-harness substrate, dotpi W1/W2) and any hook-registration path lets a manifest edit weaken DCG — the hole D9 exists to close. |
| Make DCG a swappable "enforcement slot" with a startup conformance probe | `reasoned:` premature generalization — one immature guard, one implementation; welding-by-identity (current init fail-loud) suffices until a second implementation exists. |

**What would invalidate this:** a second mature command-guard implementation appearing (would justify a conformance-slot model for the enforcement layer only — still not arbitrary manifest hook registration).

**Clarification — agent-invoked runtime hooks are OUT of D9's scope (FLEXIBLE).** D9 constrains the **manifest infrastructure**: the manifest cannot register or alter lifecycle interceptors. It does **not** forbid a tool — once made available — from installing its *own* hooks at runtime via its own mechanism. The two are different actors: D9 governs what the *composition surface* may register; it says nothing about what an available tool, *invoked by the agent*, then does. Worked example: agent_mail's `am guard install` MCP tool installs a git pre-commit hook into the workspace `.git/hooks/`. That is an agent-invoked workspace hook, bounded by the cage's other layers — not a D9 contradiction. It was verified non-breaking against DCG (pinned source @ 8897497 + the T2e runtime probe in `tests/test-manifest-agent-mail.sh`): the guard hook writes only to the target repo's `.git/hooks/`, reads only env + JSON, and performs no DCG-config write, no PATH-shadow, and no workspace `.dcg.toml` write — DCG fires before AND after the guard install. See `docs/reference/agent-mail-daemon.md`. A reader should not misread agent_mail's guard hook as weakening the D9 invariant.

**Clarification — session-multiplexer provider hooks are availability-payload, not interceptors (FIRM, added 2026-06-15).** A multiplexer added via the manifest declares provider hooks — `start` (launch its server/session at cage init), `attach` (connect a client), and optional `exec` / `new-session` / `teardown`. These are **availability-payload**, explicitly permitted by D9's own "and start daemons" clause: a multiplexer is a pull-side session daemon the agent runs *in*, not a push-side interceptor that enforces policy *on* the agent. It registers no PreToolUse hook and alters no DCG wiring, ssh-bypass blocker, sudoers scope, or non-root posture — the forbidden list is unchanged. `rc` dispatching to a declared `start`/`attach` hook (in place of the former hardcoded `none|tmux|herdr` `case`) is the seam reading payload, not the composition surface registering an interceptor. The hook commands are bounded at build time by D11's validator (see D11). This clarification is what makes D12's "the multiplexer is a manifest-declared provider, not a hardcoded set" safe under D9.

**Realized mechanism (2026-06-15, rip-cage-61al).** The multiplexer composable-provider seam is shipped and proven: a fixture multiplexer (`fakemux`) named nowhere in `rc` or `init-rip-cage.sh` drives build → config-validate → start → attach with zero source edits (`RC_E2E`), and `grep 'tmux\|herdr' rc init-rip-cage.sh` returns nothing. The realized pieces:

- **Baked provider registry.** Each declared multiplexer's hooks are baked into the image at build under `/etc/rip-cage/multiplexers/<name>/<hook>` — the build-time materialization of the availability-payload above.
- **`rc.multiplexers` image label** records the baked provider names and is the **host-readable allowed-set** (read via `docker inspect`, build-frozen). The host never reads the host-only manifest at container runtime; the label is the authoritative source when the image is present, with manifest enumeration as the fallback only when no image exists.
- **`_rc_mux_resolve_hook_path`** is the single reference reader — cage-aware (`docker exec` into a running cage, else local-fs resolution against the baked registry), shared by both host-side dispatch and in-cage init, fail-loud on a missing registry directory.
- **Dynamic config derivation.** `session.multiplexer`'s allowed-set (ADR-021 D6) is derived at validate time from the `rc.multiplexers` label / baked registry — never a hardcoded `rc` enum (the `none,tmux,herdr` schema literal was removed).

tmux and herdr moved to `examples/` providers and were stripped from the default image (D12); each is a two-entry example (a TOOL entry installing the binary + a MULTIPLEXER entry declaring its hooks). D11's validator bounds every baked hook on the same footing as `install_cmd`.

### D10: Safety interceptors fail-closed; user daemons fail-warn

**Firmness: FLEXIBLE** (added 2026-06-05)

A missing or broken safety interceptor (DCG, ssh-blocker, egress proxy) must refuse cage start (ADR-001 fail-loud; ADR-025 D5 validate-by-parsing). A broken user daemon added via the manifest (e.g. agent_mail) must **not** brick the cage — it warns and the cage runs without it.

**Rationale:** The floor is load-bearing; a user tool is not. Bricking a cage because an optional coordination daemon failed defeats agent autonomy (the cage's purpose is uninterrupted runs) — but silently continuing when a *safety* layer is absent is the fail-open hole the safety stack exists to prevent. The asymmetry routes each failure to the response that matches its stakes.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Fail-closed for all (a broken user daemon bricks the cage) | `reasoned:` defeats agent autonomy — a non-load-bearing user tool failing should not stop the agent's work (rip-cage philosophy: don't gate legitimate work). |
| Fail-warn for all (including safety interceptors) | `direct:` a missing safety interceptor would silently disarm the cage — the fail-open hole ADR-001 / ADR-025 D5 forbid. |
| Per-tool fail-policy configurable from the start | `reasoned:` adds config surface before a need exists; ship the default asymmetry first. |

**What would invalidate this:** a user with a workflow that genuinely cannot proceed without a specific daemon, wanting to opt that daemon into fail-closed — which would make the policy per-tool-configurable rather than a fixed asymmetry.

### D11: Tool fitting is agent-authorable host-side, build-validated, via one generic from-source builder stage

**Firmness: asymmetric across the three mechanisms** (added 2026-06-10) — mechanism 2 (the validator) is **FIRM**: it is the enforcement arm of D9 (FIRM), and is not skippable. Mechanism 1 (the generic builder stage) is **FLEXIBLE**: the "builder image + script + output" shape may iterate. Mechanism 3 (the host-side authoring skill) is **EXPLORATORY**: an unproven UX that will move. The FIRM/FLEXIBLE/EXPLORATORY split matters because lumping all three as EXPLORATORY would wrongly imply the safety validator is optional.

Three mechanisms turn D7's host-only manifest into an **agent-first composability surface** — so that adding any tool is a manifest entry a user (or their agent) writes, never bespoke rip-cage support for a named tool. cm is the worked example throughout.

1. **One generic builder stage, not per-tool Dockerfile edits.** A from-source manifest entry declares a builder base image, a host-side build script, and an output binary path. `rc build` runs that script in a *single isolated builder stage* (no host access; the beads/DCG builder-stage isolation pattern) and copies only the artifact into the runtime image. rip-cage interprets **no** build logic — the per-tool build intelligence lives in the script, not a build DSL. This generalizes D6's "fall back to source" from a maintainer hand-coding a stage per tool into a declarative, arch-adaptive mechanism (the stage targets the build platform; once cm is moved onto it — the demotion work, rip-cage-buuo.5 — the hand-pinned `--target` hardcode tracked as rip-cage-ywek goes away). **Implementation note:** the manifest subsystem already exists in `rc` (parse/validate/load, Dockerfile-step generation, the three archetypes), but its only build affordance today is a single-line prebuilt `install_cmd` emitted as one runtime-stage `RUN`; the from-source *builder stage* is the net-new mechanism this decision adds.

2. **A fail-closed validator enforces the safety contract on every tool, regardless of who authored it.** At build, rip-cage asserts: the provisioned binary is root-owned and not agent-writable; declared egress unions under the non-overridable IOC floor (ADR-012); declared mounts pass the realpath + ADR-023 denylist; the build script ran isolated. A violation **fails the build** (ADR-001 fail-loud; D10 safety-side asymmetry). This is the enforcement arm of D9's availability-only invariant — "adding a tool" can never become "weakening the cage," even when an agent drafted the entry. Guidance is advisory; the validator is not. **Entrypoint-completeness (FIRM, added 2026-06-12):** because the validator is the non-skippable enforcement arm, it must be wired into *every* build path that can produce a from-source manifest tool — not only the obvious `rc build` entrypoint. A second build path that omits it is a silent FIRM bypass, and "the validator is not skippable" does not by itself prevent one: `rip-cage-buuo.6` found exactly this — the `rc up` auto-build path (`_pull_or_build`) duplicated the `docker build` call *without* the validators that `cmd_build` carried, so a tool built via `rc up` (no prior `rc build`) was enforced by neither check; per-child review saw the correct `cmd_build` wiring and missed the second path, and only the epic parent re-verify caught it (both paths now route through a shared `_pull_or_build_local` helper that runs the assertions). The invariant is *every build entrypoint inherits the check* — a new `docker build` call site reachable by a from-source stage must wire the validator or it reintroduces the hole; the invariant is stated over build paths in general, not over an enumeration that goes stale on refactor. **Implementation note:** the egress-under-IOC and mount-denylist checks (`_manifest_check_ioc_egress`, `_manifest_check_mounts_denylist`) and strict-parse validation (`_manifest_validate`) pre-existed; the **binary root-owned / not-agent-writable** check and the **build-script isolation** check this decision added are implemented in `rip-cage-buuo.3` and, per the entrypoint-completeness clause, wired into both build entrypoints (`cmd_build` and `_pull_or_build_local`) in `rip-cage-buuo.6`. **Binary-root-owned coverage scope (revised 2026-06-14, rip-cage-hqvk / rip-cage-ryn6):** "on every tool" holds for the egress-under-IOC, mount-denylist, and build-isolation assertions. The *binary-root-owned* assertion specifically can only run against a **declarable binary path**: from-source entries (via `build_source.output_path`) and prebuilt `install_cmd` entries that declare an optional `binary_path` (rip-cage-ryn6) are stat-checked root-owned + not-agent-writable in the built image. A prebuilt entry that declares *no* path cannot be effect-checked (its runtime binary location is not declaratively known) and falls to human review (ADR-024 D11) — so the binary-ownership check is coverage-on-declared-path, not literally universal. Requiring a declared path on every prebuilt entry is deliberately *not* done: package-manager `install_cmd`s (e.g. `apt-get install jq`) land root-owned via the package manager regardless, and forcing a path declaration there would gate legitimate work (rip-cage philosophy: block the accident, don't gate the legit case). **Multiplexer provider hooks are validator-bounded (FIRM, added 2026-06-15):** a manifest entry that declares multiplexer provider hooks (D9 clarification; D12) — `start` / `attach` and optional `exec` / `new-session` / `teardown` — has those hook commands bounded by this validator on the same footing as `install_cmd`. A manifest-authored or prompt-injected mux entry must not be able to declare a `start` hook that weakens the welded floor (no DCG-config or workspace `.dcg.toml` write, no PATH-shadow of a safety binary, no lifecycle-interceptor registration). The hooks are validated at build, before they can execute at cage init; a hook that fails the assertion fails the build (D10 safety-side asymmetry). This is the enforcement arm of D9's multiplexer-hooks clarification, exactly as the rest of mechanism 2 is the enforcement arm of D9's availability-only invariant.

3. **A repo-shipped skill lets a user's *host-side* agent author entries for human review.** rip-cage is agent-first (installed and configured via agents), so the composability UX is a skill the user points their own host-side agent at: it reads the target tool's source, drafts a manifest entry + build script as **human-reviewable host files** under `~/.config/rip-cage/`, and the human approves before `rc build`. This does **not** weaken D7's FIRM host-only property: the *in-cage* agent still cannot reach the manifest; a host-side agent under the user's supervision drafts it exactly as the user would, and human review + the validator are the gates. cm is the skill's worked example — no prebuilt linux-arm64, so it exercises the from-source path.

**Rationale:** encoding every tool's source build as a declarative schema either stays too rigid or balloons into a build DSL — "figure out how to build *this* tool for Linux" is open-ended, per-tool judgment an agent does well and a schema does badly. Moving that to a skill-guided host-side agent keeps rip-cage thin (one generic stage + a validator) while making any tool fittable. The validator is what keeps agent-authoring safe.

**Counter-argument / residual risk (named, accepted):** an agent-authored build script fetches and compiles arbitrary upstream source at build time — more trust than a pinned prebuilt download. It is mitigated (a builder stage with no host *filesystem* access, validated root-owned output, a human-reviewed script), but two honest limits remain: (1) **stage isolation is filesystem isolation, not network isolation** — a Docker `RUN` in the builder stage reaches the internet by default, so a malicious build script could exfiltrate *during* the build even while producing a valid root-owned binary, and the validator inspects the build *output*, not the script's runtime behavior; restricting build-time egress is a possible hardening, but until it ships, (2) **human review of the build script is the actual load-bearing mitigation**, not the stage isolation. This is precisely why the skill produces reviewable host files and never a runtime injection. "Compile arbitrary source" stays a real supply-chain surface that human review carries.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Declarative build fields `rc` interprets (a build DSL) | `reasoned:` every tool's build differs (build tool, deps, flags, arch); a generic schema is either too rigid or balloons — the open-ended part belongs to an agent, not a schema. |
| Agent hand-edits the monolithic Dockerfile to add a stage | `reasoned:` no clean seam, fragile, edits conflict; the single generic builder stage gives one bounded, uniform seam parameterized by the manifest. |
| Let the *in-cage* agent author the manifest directly | `reasoned:` reopens D7's pre-stage hole — the manifest must stay in-cage-agent-inaccessible; only a host-side agent under user supervision may draft it. |
| Trust the skill's guidance without a build-time validator | `direct:` guidance is advisory; ADR-024's threat model requires enforcement — the validator is the non-advisory gate (D9/D10). |
| Bundle popular tools instead of generalizing (per-tool support) | `reasoned:` contradicts the composability posture (D2) — rip-cage ships the mechanism, not curated tool support; bundling scales with tool count, the manifest does not. |

**What would invalidate this:** a from-source tool whose build genuinely cannot be expressed as "builder image + script + output" (e.g. needs the host filesystem, or multi-stage interdependence) — which would *extend* the builder mechanism, not abandon it; or the validator's contract proving insufficient against a real injected-tool vector — which would harden the contract, not drop the gate.

### D12: rip-cage is a composable seam, not a bundler

**Firmness: FIRM** (added 2026-06-15)

rip-cage owns the **composition interfaces** (the tool manifest and its archetypes, the multiplexer provider contract, egress/mount declarations) and the **welded safety floor** — and nothing else. It never owns, bundles, or *blesses* a specific optional tool. Three binding consequences:

1. **`rc`'s code never names a specific optional tool.** No hardcoded multiplexer set, no built-in optional-tool list, no `if tool == "herdr"` branch. A new tool — including a new multiplexer (e.g. zellij) — is added by writing a manifest entry, with **zero edits to `rc` source**. (This is D2's "ship the mechanism, not curated tool support" and D11's "never bespoke rip-cage support for a named tool," stated once as a citable invariant.)
2. **Defaults ship minimal.** The default manifest seeds nothing optional; nothing optional is pre-installed in the default image. A default cage carries the floor (D2: UBS + core toolchain) and nothing else. `session.multiplexer` defaults to `none` (ADR-021 D6; ADR-009 D1).
3. **Examples live outside the binary.** Provider definitions and composition recipes (how to wire rc with tmux / herdr / zellij / agent_mail / …) ship as copyable examples (an `examples/` folder + reference docs), never special-cased in `rc`. tmux and herdr are example entries exactly like agent_mail — not a blessed set.

**Convenience never earns a hardcoded exception in the seam.** When a tool would be "nice to have on by default," the move is *not* to bundle it into the optional surface — it is either (a) an opt-in example the user composes, or (b), if the tool is genuinely universal, reclassify it as **floor** (baked unconditionally, git/curl tier). There is no third "blessed-but-optional" category; that category is precisely what re-introduces the hardcoded exceptions this decision forecloses.

**Rationale:** Every "just bundle this one optional tool by default" trades a permanent, compounding cost (every default cage carries it; the blessed set is a threat + maintenance surface that grows with tool count) to erase a one-time cost (copying a documented example). It also creates second-class citizens — a "blessed" tool gets `rc`-source support a user's own tool cannot — which is the exact asymmetry that re-grows hardcoded dispatch. The herdr-in-default-manifest regression (rip-cage-kqvw: an optional multiplexer pre-installed for every cage, dispatched via a hardcoded `case` in `rc`) is the canonical failure this decision names so it stops recurring. The seam stays thin and uniform; tool count scales in the manifest, never in `rc`.

**Counter-argument (FIRM discipline):** Forcing every user to copy a provider entry to use a common multiplexer is friction a one-word default toggle would erase — a real ergonomic cost. This does not overturn FIRM: the friction is a one-time copy of a documented example, while bundling's cost is permanent and compounding (per-tool, per-cage, per-threat-surface), and the "blessed-but-optional" category it requires is itself the hardcoded-exception vector. The escape valve for a genuinely universal tool is floor reclassification (consequence path b), which keeps the exception honest and bounded rather than letting "blessed optional" creep back in.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Bundle common optional tools (a blessed default set) | `direct:` rip-cage-kqvw — herdr seeded into the default manifest pre-installed an optional multiplexer for every cage and required a hardcoded `case` in `rc`; the blessed set is the regression vector. Also `reasoned:` bundling scales with tool count, the manifest does not (D2/D11). |
| Auto-add a selected tool to the user's manifest (selection mutates config) | `reasoned:` a hidden side-effect — selecting a multiplexer silently editing `tools.yaml` — is the "messy exception" composability exists to avoid; selection (runtime, per-cage) and availability (build-time) stay separate, uniform knobs. |
| A built-in `include:` / reference mechanism so examples need no copy | `reasoned:` adds a config-resolution surface to shave a one-time paste; scope creep against a thin seam. Examples are copy-once. |

**What would invalidate this:** a tool so universally needed that *not* shipping it creates more friction than the composability buys — at which point it becomes **floor** (baked unconditionally, like git / curl / the core agent toolchain), *not* a bundled-optional tool. The invalidation moves a tool across the floor/optional line; it never creates a blessed-optional middle category.

## canonical_refs

- [ADR-001 Fail-Loud Error Handling](ADR-001-fail-loud-pattern.md) — D10 safety-interceptor fail-closed; D11 fail-closed tool validator.
- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) — base image + bypassPermissions/hooks model the manifest composes on top of (D7, D9).
- [ADR-006 Multi-Agent Architecture](ADR-006-multi-agent-architecture.md) — Tier 1a many-agents-in-one-cage, the planned-not-shipped prerequisite for the in-cage daemon archetype (D7, D8).
- [ADR-012 Network Egress Firewall](ADR-012-egress-firewall.md) — declared egress unions into the allowlist but stays under the non-overridable IOC floor (D7, D9).
- [ADR-019 pi-coding-agent Support](ADR-019-pi-coding-agent-support.md) — D1 container-local cage-owned paths + narrow durable sub-mount, the pattern for daemon state-dir placement (D7); D9 bash-only agents reach the daemon via its CLI over bash, not the `mcp_fragment` (the agent-side counterpart to D7's archetype, reconciled into D7 wording).
- [ADR-021 Layered rip-cage Config](ADR-021-layered-rip-cage-config.md) — D1 `~/.config/rip-cage/` host-side config home (where the host-only manifest lives); additive-list/selection-list merge semantics and no-config regression contract the manifest mirrors (D7); **D6 `session.multiplexer` enum (default `none`) is the per-cage runtime selection D12 dispatches to the manifest-declared provider (the D9 clarification's `start`/`attach` hooks).**
- [ADR-006 Multi-Agent Architecture](ADR-006-multi-agent-architecture.md) — D7/D8 (FLEXIBLE) the composable session layer wired through the multiplexer tool's *public CLI*; D12 makes that multiplexer a manifest-declared provider rather than a hardcoded `rc` set, and D11's validator bounds the provider hooks.
- [ADR-009 UX Overhaul](ADR-009-ux-overhaul.md) — D1 default `none` (normal terminal semantics; supervisor view is opt-in), the per-cage default D12 consequence 2 reaffirms.
- [ADR-023 Secret-Path Mount Denylist](ADR-023-secret-path-mount-denylist.md) — manifest-declared mounts subject to the denylist floor (D9).
- [ADR-024 Prompt-Injection Threat Model](ADR-024-prompt-injection-threat-model.md) — warrants host-only authoring (the pre-staged-manifest vector) and the in-cage-only invariant (D7, D8, D9); the agent-authoring path (D11) stays safe because only a host-side agent under user review may draft entries and the validator enforces the contract.
- [ADR-025 Host-Adoptable DCG Policy Layer](ADR-025-host-adoptable-dcg-policy.md) — D2 baked DCG floor is uncrossable (the manifest can't weaken it); D5 validate-by-parsing (D9, D10).
- bead `rip-cage-4c5` — the composable-tool-manifest *design* epic (closed); the manifest subsystem it specced is now implemented in `rc` (`_manifest_*` functions).
- bead `rip-cage-buuo` — the D11 *implementation* epic: generic from-source builder stage, the binary-ownership + build-isolation validator additions, the mounts consumer, the host-side authoring skill, and the cm demotion (subsumes rip-cage-ywek).

## Related

- [Ecosystem Tools Design](../2026-03-27-ecosystem-tools-design.md) — full design document with per-tool details
- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) — base image architecture this extends
- [ADR-003 Agent-Friendly CLI](ADR-003-agent-friendly-cli.md) — `rc build` JSON output pattern
- [Flywheel Investigation](../2026-03-27-flywheel-investigation.md) — tool evaluation and selection rationale
- [UBS](https://github.com/Dicklesworthstone/ultimate_bug_scanner) — Ultimate Bug Scanner
