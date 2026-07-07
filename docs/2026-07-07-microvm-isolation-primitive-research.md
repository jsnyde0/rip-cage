# MicroVM as rip-cage's isolation primitive — research dossier (2026-07-07)

Home bead: **rip-cage-gljd** (the spike). Sibling short-term bead: **rip-cage-z40e**
(in-cage native Postgres+pgvector recipe). Origin: a switch-berlin session where a caged
agent could not run its DB-backed test suite (no docker in-cage), which forced the broader
question this dossier answers groundwork for: *is the shared-kernel container still the
right isolation primitive for rip-cage?*

Three parallel web-research agents (nested-container mechanics / industry survey /
native-Postgres engineering) produced the findings below. Compressed but
evidence-preserving; URLs inline where load-bearing.

---

## 1. The triggering problem and the strategy space

Caged agents can now self-verify anything pip/npm-installable (the mediator allowlist fix,
same date — see configure-cage SKILL.md Footguns, commit 4700c80). What they still cannot
do is run test suites needing service dependencies (Postgres+pgvector via docker-compose):
no docker socket, no privileges, by design.

Strategies evaluated, with verdicts:

| # | Strategy | Verdict |
|---|---|---|
| A | Bake Postgres+pgvector into the cage image as a plain unprivileged process | **Short-term winner** → rip-cage-z40e |
| B | Rootless Podman inside the cage | Fallback only — needs `/dev/fuse` + subuid/subgid + often `CAP_SETUID`/`CAP_SETGID` + no-new-privileges off; podman-compose still Alpha; posture-eroding |
| C | MicroVM-per-cage as the isolation primitive | **The architectural question** → rip-cage-gljd, this dossier |
| D | Cage reaches an external DB (host stack or cloud) | Weak — host-coupling, shared-DB blast radius, credentials-in-cage violates non-possession |
| E | Formalized test-offload (agent raises "run suite", host executes) | Honest interim; works manually today; automating it = designing a command-execution channel carefully |

Hard nested-container facts (kill the "just nest docker" idea):
- Classic **and** "rootless" DinD both still require `--privileged` per Docker's own docs
  ([docker-library/docker#291](https://github.com/docker-library/docker/issues/291)).
- Sysbox: Linux-only runc replacement, low maintenance velocity post-Docker-acquisition,
  no confirmed macOS/OrbStack path.
- Kata/Firecracker: KVM-only; OrbStack's VM runs on Apple Virtualization.framework — no
  nested-KVM path found.
- Rootless Podman-in-Docker is the only semi-viable nesting: narrow but real capability
  adds, flaky beyond one nesting level, podman-compose compat gaps
  ([podman#15419](https://github.com/containers/podman/issues/15419),
  [discussion #28123](https://github.com/containers/podman/discussions/28123)).

## 2. The industry converged on microVM-per-sandbox (2025-2026)

- **Docker Sandboxes (`sbx`)** — standalone CLI since ~Jan 2026 (`brew install
  docker/tap/sbx`, no Docker Desktop needed). On Apple Silicon boots an Arm Linux microVM
  via Virtualization.framework; each sandbox gets a **private Docker daemon** (invisible to
  host `docker ps`), so `docker compose up` works natively inside. Host-side egress proxy
  with allow/deny lists. Parts still labeled Experimental. Explicitly marketed for running
  Claude Code/Codex/Copilot agents unsupervised.
  [docs.docker.com/ai/sandboxes](https://docs.docker.com/ai/sandboxes/get-started/),
  [Docker blog](https://www.docker.com/blog/docker-sandboxes-run-ai-coding-agents-safely-without-breaking-your-machine/).
- **microsandbox** — Apache-2.0, self-hosted, libkrun-based (same substrate as Podman's VM
  mode). Boots microVMs in ~100-320ms; macOS-native via Hypervisor.framework; runs standard
  **OCI images from any registry**; Python/JS/Rust/Go SDKs + an MCP server; beta (v0.6.1
  mid-2026, 6.5k stars, active). [microsandbox.dev](https://microsandbox.dev/),
  [GitHub](https://github.com/zerocore-ai/microsandbox).
- **Apple Containerization framework v1.0** (June 2026) — VM-per-container on Apple's own
  hypervisor; Mac-native but its own stack, not Docker/OCI-toolchain-compatible drop-in.
- **Depot / Blacksmith / E2B / Modal / Daytona-with-Kata** — every dedicated sandbox
  vendor is VM-based or moving there; Depot advertises "nothing stopping you from running
  Docker… or nested VMs" because each sandbox has a real kernel.
- **Cursor background agents** are the cautionary tale of NOT doing this: their container
  sandbox forbids `--privileged`, so DinD is "dead on arrival" and the community hand-patches
  daemon configs; "how do I get Postgres working" threads stay open. That is rip-cage's
  current architecture class.
- Adjacent patterns worth knowing: **Imbue Offload** (decouple test execution from the
  interactive sandbox — burst suites to Modal), **Namespace.so** (sandbox joins a Tailscale
  tailnet to reach real services with short-lived OIDC identity), **Morph Infinibranch**
  (fork a running VM in ~250ms preserving DB state — sidesteps re-provisioning entirely).
- Research gap flagged honestly: **nobody has published** a solved pattern for
  "pgvector inside a fully locked-down no-docker sandbox" — option A is us composing a
  known CI pattern (GitHub's own runner images pre-install Postgres natively), not
  following a published recipe.

## 3. The honest architectural assessment

**The key reframing fact:** on macOS today, every rip-cage cage shares ONE Linux kernel —
OrbStack's single VM. A kernel escape from any cage exposes every other cage and every
mount of every cage (`/workspace` repos, `~/.claude`, …). MicroVM-per-cage gives each cage
its own kernel — strictly stronger — and dissolves the in-cage-services problem as a side
effect (private docker daemon per VM).

**The anti-sunk-cost observation:** rip-cage's durable value is NOT the container
primitive. It is: the composition manifest (tools/guards/multiplexers/mediators, ADR-005),
credential non-possession via mediator MITM (ADR-026), DCG, herdr, per-project config
layering (ADR-021), and the `rc` UX. All of that is image content + posture, largely
substrate-agnostic — and microsandbox boots standard OCI images, so the `rc build`
artifact may carry over nearly intact. "Switching" is plausibly a bottom-layer swap, not a
rewrite. The decision should be made on merits, not investment protection.

**What keeps this from being an immediate switch** (the five spike questions,
rip-cage-gljd):
1. Can the rc-built image boot under sbx / microsandbox with init-firewall + iron-proxy +
   herdr actually functioning?
2. File-sharing semantics + performance for the bind-mount-heavy workflow (`/workspace`,
   `~/.claude`) — virtiofs vs bind mounts; mount-severing behaviors may differ.
3. Does sbx's own egress proxy compose with or fight iron-proxy's credential-swap MITM?
4. Per-cage resource overhead (RAM/disk/boot) vs containers, at "several cages up at once"
   scale.
5. Which `rc` verbs break (exec/attach/doctor/reload) and what replaces them.

## 4. Competitive framing (operator's addition, 2026-07-07)

The operator's read: **Docker `sbx` looks like a competitor to rip-cage, not a substrate
to build on.** Assessment to carry into the next session: it is plausibly BOTH, and the
distinction structures the whole investigation —

- **sbx = product** (opinionated cage-manager: VM boot + egress proxy + agent launchers).
  Overlaps rip-cage's job description directly. Building rip-cage ON sbx means building on
  a competitor's experimental product with its own opinions (their proxy, their config
  surface) — friction likely at exactly the layers rip-cage differentiates on.
- **microsandbox / libkrun / Apple Containerization = substrate** (runtimes/libraries that
  boot OCI images in microVMs, no opinions about agents or egress). These are the natural
  "swap the bottom layer" candidates.
- **Where rip-cage differentiates today** (the "how do we stack up" seed — to be verified
  against sbx's actual current feature set, not assumed):
  - credential **non-possession** (placeholder token + MITM secret-swap on egress) — no
    surveyed competitor documented this; sbx proxies egress but secret-swapping is unknown
    (spike question 3 doubles as competitive intel);
  - the **composition manifest** — guards (DCG), multiplexers (herdr), mediators as
    reviewable YAML the human reads before build;
  - **per-project config layering** with additive-merge semantics (ADR-021);
  - substrate integration (beads, memories, session hooks) — the agent-workflow layer
    above the sandbox;
  - local-first, no SaaS dependency.
- **Where sbx/the VM products beat rip-cage today:** own-kernel isolation; nested docker
  (and thus DB-backed test suites) for free; vendor momentum.
- Strategic shape this suggests (unvalidated, for the brainstorm): rip-cage's moat is the
  *posture and composition layer*, which is exactly the part that ports. If the substrate
  layer commoditizes (sbx, microsandbox), rip-cage-on-microVM is a stronger product than
  either rip-cage-on-container or bare sbx. The competitor is only a competitor at the
  layer rip-cage should be happy to vacate.

## 5. What the next session should probably do (operator intent, verbatim-adjacent)

Continue with more grounding toward microVM: more/better subagent research, and a few
QUICK VALIDATION SPIKES rather than theorizing — e.g. actually `brew install
docker/tap/sbx` and boot something; actually run microsandbox and try booting the
rc-built image (it's an OCI image — `docker.io/library/rip-cage:latest` exists locally);
map what tools/solutions compose. Investigate sbx specifically through the
competitor-vs-substrate lens, and produce an honest "how does rip-cage stack up against
this competition" read.
