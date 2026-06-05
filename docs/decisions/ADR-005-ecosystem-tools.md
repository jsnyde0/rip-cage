# ADR-005: Ecosystem Tools Integration

**Status:** Proposed (revised 2026-06-05 — D7–D10 add the composable host-only tool manifest)
**Date:** 2026-03-27
**Design:** [Ecosystem Tools Design](../2026-03-27-ecosystem-tools-design.md)
**Related:** [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md), [Flywheel Investigation](../2026-03-27-flywheel-investigation.md)

## Context

Rip-cage's Phase 1 delivered a safety stack (DCG + compound command blocker) inside a containerized environment. The next step is integrating external tools that make agents more effective: bug scanning (UBS), network monitoring (RANO), session search (CASS), task visualization (bv), and procedural memory (CM). These tools are independently developed projects with their own release cycles. The question is how to integrate them without bloating the base image or creating maintenance burden.

**2026-06-05 extension (D7–D10):** D1–D6 cover *maintainer-curated* ecosystem tools toggled by build args. D7–D10 generalize that into a **composable, declarative, host-only tool manifest** so that any user (not just a rip-cage maintainer editing the Dockerfile) can add a tool — including shell-integration tools and in-cage coordination daemons such as agent_mail — and so the safety contract of "adding a tool" is canonical. The manifest is the build-time composition surface D3's `versions.env` and D5's 4-point pattern were the first instance of; D7 names the general mechanism, D8–D9 bound what it may touch, D10 sets the failure asymmetry. The manifest's exact format and storage location remain EXPLORATORY and live on bead `rip-cage-4c5`, not here — this ADR canonicalizes the *contract*, not the schema.

## Decisions

### D1: Ecosystem tools are integrated via Dockerfile build-arg toggles, not runtime plugins

**Firmness: FIRM**

Each optional tool gets a `ARG INCLUDE_<TOOL>=true|false` in the Dockerfile. Tools are installed at build time, conditional on the arg. There is no runtime plugin system, no dynamic downloading, no post-start installation.

**Rationale:** Build-time composition produces deterministic, reproducible images. Runtime plugin systems add complexity (download failures, version mismatches, startup latency) without meaningful benefit — users rebuild images infrequently and want consistent environments. The Dockerfile already has a multi-stage pattern (Go builder, Rust builder, runtime) that naturally accommodates conditional tool installation.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Build-arg toggles** | Deterministic, reproducible, fits existing Dockerfile pattern | Must rebuild image to change tools |
| Runtime plugin download | Change tools without rebuild | Non-deterministic, download failures, startup latency |
| Separate image per tool combo | Maximum isolation | Combinatorial explosion of images |
| Docker multi-stage with `--target` | Clean separation | Doesn't support conditional inclusion within a stage |

**What would invalidate this:** Tool set changes so frequently that rebuilding the image becomes a bottleneck. In that case, consider a volume-mounted tool directory with version-locked binaries.

### D2: UBS is the only external tool included by default

**Firmness: FLEXIBLE**

UBS (Ultimate Bug Scanner) ships in the default image (`INCLUDE_UBS=true`). All other tools default to false.

**Rationale:** UBS has the highest value-to-cost ratio of any tool evaluated. It is a 3MB bash script (no compilation), catches bugs across 9 languages in <5s, and directly improves auto-mode safety by gating commits. Every other tool is either larger (bv: 50-100MB), requires setup (CM: host-side playbook), or serves a narrower use case (RANO: network debugging, CASS: session search). The default image should be opinionated toward safety — UBS is the one tool that makes every agent session safer.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **UBS only** | Lean default, clear value proposition | Users must opt-in to other tools |
| UBS + RANO | Safety + observability | RANO adds 8MB and complexity for a tool most users won't need immediately |
| All tools default | Feature-rich out of the box | ~200MB larger, longer build, tools users don't need |
| No external tools default | Smallest image | Misses the highest-value addition |

**What would invalidate this:** Another tool proves higher value-to-cost than UBS for the default use case (e.g., a lighter bug scanner, or a tool that prevents a class of errors UBS misses).

### D3: Tool versions are pinned via build args with a manifest file

**Firmness: FIRM**

Each tool version is a Dockerfile build arg (`ARG UBS_VERSION=5.0.7`). A `versions.env` file at the repo root centralizes all version pins. `rc build` sources this file and passes values as `--build-arg` flags.

**Rationale:** Pinned versions prevent silent breakage from upstream changes. A manifest file makes version bumps a single-file change that is easy to review, diff, and automate (e.g., Dependabot-style PRs). Build args are the standard Docker mechanism for parameterizing builds — no custom tooling needed.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Build args + versions.env** | Standard Docker pattern, single-file updates, easy to automate | Extra file to maintain |
| Hardcoded versions in Dockerfile | Simpler, fewer files | Versions scattered across Dockerfile, harder to review |
| `latest` tag always | No pinning needed | Non-reproducible builds, silent breakage |
| Lock file (versions.lock) | Cryptographic verification | Over-engineered for this use case |

**What would invalidate this:** Tool count grows large enough that a proper dependency resolver (like Nix) would be more appropriate than a flat env file.

### D4: `rc build` gains `--with <tool>` flags for user customization

**Firmness: FIRM**

The `rc build` command accepts `--with <tool>` to enable optional tools, `--full` to enable all, and `--minimal` to disable all (including UBS). These translate directly to Docker build args.

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

**Firmness: FLEXIBLE**

When a tool publishes pre-built binaries for linux/arm64 and linux/amd64, download those in the Dockerfile rather than compiling from source. Fall back to source compilation only when pre-built binaries are unavailable for the target architecture.

**Rationale:** Pre-built binaries make builds faster (no Rust/Go toolchain needed for that tool), produce smaller builder stages (no source tree or build cache), and reduce the chance of build failures from upstream dependency changes. The Dockerfile already compiles DCG and bd from source — adding more source builds increases build time and fragility. For tools like RANO and CASS that publish releases, downloading a binary is a single `curl` command.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Pre-built binaries preferred** | Fast builds, small stages, simple | Trust upstream build, no local patching |
| Always compile from source | Full control, can patch | Slow builds, large builder stages, toolchain deps |
| Vendor binaries in repo | No network dependency at build time | Bloats repo, manual updates |
| Nix or Guix for all tools | Reproducible, declarative | Heavy dependency, unfamiliar tooling |

**What would invalidate this:** Need to patch tools locally (e.g., rip-cage-specific modifications). In that case, fork the tool and compile from source in the builder stage.

### D7: Tool composability is a declarative, host-only manifest with three archetypes

**Firmness: storage-location FIRM (host-only `~/.config/rip-cage/`); schema/format EXPLORATORY** (added 2026-06-05; storage-location resolved 2026-06-05)

A declarative manifest — stored **host-side under `~/.config/rip-cage/`, agent-inaccessible**, consumed by `rc build` at build time, with the current bundled stack as its defaults — lets users add tools without forking the Dockerfile. It generalizes D3 (`versions.env` pinning) and D5 (the 4-point integration pattern) from a maintainer checklist into a user-facing composition surface. Each entry is one of three **archetypes**, defined by integration surface, that other beads and contributors reference as a constraint:

- **TOOL** — agent-invoked; integration is just reachability (binary on PATH) + declared egress + declared mounts. ~75% of a real ecosystem (ACFS phases 7–10).
- **SHELL-INTEGRATION** — integrates via a shell rc `eval` line (atuin, zoxide); one `shell_init` field.
- **IN-CAGE DAEMON** — a long-running localhost service other in-cage agents talk to (e.g. agent_mail); needs `start` + `health` + a state-dir placement + an optional MCP-registration fragment.

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

## canonical_refs

- [ADR-001 Fail-Loud Error Handling](ADR-001-fail-loud-pattern.md) — D10 safety-interceptor fail-closed.
- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) — base image + bypassPermissions/hooks model the manifest composes on top of (D7, D9).
- [ADR-006 Multi-Agent Architecture](ADR-006-multi-agent-architecture.md) — Tier 1a many-agents-in-one-cage, the planned-not-shipped prerequisite for the in-cage daemon archetype (D7, D8).
- [ADR-012 Network Egress Firewall](ADR-012-egress-firewall.md) — declared egress unions into the allowlist but stays under the non-overridable IOC floor (D7, D9).
- [ADR-019 pi-coding-agent Support](ADR-019-pi-coding-agent-support.md) — D1 container-local cage-owned paths + narrow durable sub-mount, the pattern for daemon state-dir placement (D7).
- [ADR-021 Layered rip-cage Config](ADR-021-layered-rip-cage-config.md) — D1 `~/.config/rip-cage/` host-side config home (where the host-only manifest lives); additive-list/selection-list merge semantics and no-config regression contract the manifest mirrors (D7).
- [ADR-023 Secret-Path Mount Denylist](ADR-023-secret-path-mount-denylist.md) — manifest-declared mounts subject to the denylist floor (D9).
- [ADR-024 Prompt-Injection Threat Model](ADR-024-prompt-injection-threat-model.md) — warrants host-only authoring (the pre-staged-manifest vector) and the in-cage-only invariant (D7, D8, D9).
- [ADR-025 Host-Adoptable DCG Policy Layer](ADR-025-host-adoptable-dcg-policy.md) — D2 baked DCG floor is uncrossable (the manifest can't weaken it); D5 validate-by-parsing (D9, D10).
- bead `rip-cage-4c5` — the composable-tool-manifest epic carrying the full design, the EXPLORATORY manifest schema/location open decisions, and the per-archetype harness target.

## Related

- [Ecosystem Tools Design](../2026-03-27-ecosystem-tools-design.md) — full design document with per-tool details
- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) — base image architecture this extends
- [ADR-003 Agent-Friendly CLI](ADR-003-agent-friendly-cli.md) — `rc build` JSON output pattern
- [Flywheel Investigation](../2026-03-27-flywheel-investigation.md) — tool evaluation and selection rationale
- [UBS](https://github.com/Dicklesworthstone/ultimate_bug_scanner) — Ultimate Bug Scanner
