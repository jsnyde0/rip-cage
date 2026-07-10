# rip-cage on microsandbox — product direction (living doc)

**Status: DRAFT / EXPLORATORY — pending review by the stronger model (Fable) before any of
it hardens into ADRs or drives migration.** Started 2026-07-08. This is a *living* doc: add to
it each time dogfooding friction teaches something. It is deliberately NOT in CLAUDE.md/AGENTS.md
(no always-loaded bloat) and NOT yet an ADR (ADRs are for stamped decisions; this is still
evolving). The always-surfaced pointer to it is the `bd` memory `rip-cage-on-msb-direction`.

Companion evidence: `docs/2026-07-07-microvm-spike-findings.md` (the live spike — boot, credential
non-possession, virtiofs perf, landscape sweep, moat analysis §7, migration sketch §8b) and spike
bead **rip-cage-gljd**.

---

## 1. Where this came from

The microVM spike concluded that **microsandbox (msb) should be rip-cage's isolation primitive** —
and not merely as an upgrade. It *fixes a real weakness*: rip-cage's credential non-possession today
is a co-located-uid boundary inside one shared kernel (a container escape defeats it); msb keeps the
real secret in the host process outside the VM (defeating it needs a host compromise). msb also
ships, host-side and un-bypassable, the entire egress+credential stack rip-cage built in-cage
(`--net-*`, `--tls-intercept`, `--secret ENV@HOST`). That forced the harder question this doc
captures: **if the security engine is commoditized, what is rip-cage for?**

## 2. The core reframe

Two questions that were tangled have now cleanly separated:

- **Isolation primitive** — SETTLED: adopt msb.
- **Product / what rip-cage IS** — this doc.

Consequence: rip-cage's most-invested-in code — `rip_cage_router.py`, `rip_cage_egress.py`,
`rip_cage_dns.py`, `init-firewall.sh`, `init-mediator.sh`, the MEDIATOR machinery — is superseded by
msb host-side primitives and should be **retired, not ported**. That is not lost work; it did its
job (it's why we understood the frontier) and is now replaced by something stronger. What survives is
the layer *above* the runtime.

## 3. What rip-cage is (positioning)

**rip-cage = the opinionated, agent-native workbench and operating layer on top of a commodity
microVM runtime (msb).** The analogy is Docker Compose / a Linux distro to the runtime beneath it —
except the composition unit is *agent-native* (tools, substrate, trust boundaries), NOT the
heterogeneous services that justify Compose. "Opinionated configuration of msb" is not a demotion:
Compose is opinionated configuration of a container runtime and is one of the most-adopted tools in
existence. Docker was never rip-cage's moat either; nothing about rip-cage's value changes because
the bottom layer swaps to a better one.

**Goal (explicit):** a popular OSS tool that helps the author and fellow agentic engineers, and that
establishes the author as an authority in agentic engineering. NOT commercial success / not a
defensible commercial moat. The msb finding *frees* rip-cage to occupy the higher-value workbench
layer instead of losing an isolation race to Docker and funded teams.

## 4. Three operating rules

1. **Needs-pull, not feature-push.** The author is the first user; dogfooding friction is the
   roadmap. Do not build a composition primitive until the workflow actually demands it.
2. **Keep the option map in your pocket** (§6). Not to build speculatively — so that when friction
   hits, you recognize its known-good shape instead of reinventing a worse one.
3. **The earn-its-keep guardrail** (§5).

## 5. The earn-its-keep guardrail (the anti-obsolescence rule)

Every rc concept must live at a **higher altitude than msb thinks in** — *projects, tasks, teams,
trust, substrate*. The sharp test is NOT "does this compile to an msb flag" (everything does) — it is:

> **Is rc saying something msb has no word for?**

If a manifest field just re-spells `-v` or `--net-rule`, delete it — msb already does that, and a 1:1
flag-mapper makes rip-cage obsolete. If it expresses *project / task / trust boundary / substrate
projection / fleet topology* — things msb is deliberately ignorant of — it is rip-cage's to own.

## 6. Option map (reference — NOT a build list)

**Cage-to-cage primitives (plain):** (a) shared folders / mounts — two cages can be handed the same
host dir; (b) network — each cage gets a private IP, deny-by-default, allowlist specific paths;
(c) shared host service — every cage talks out to one service on the host (e.g. a beads server).

> **Host-service seam — design CAPTURED, not committed (2026-07-10).** Under msb the only delivering
> guest→host path is the host's LAN IP (spike-proven), so (c) implies a real seam: manifest-declared
> host services, rc owning LAN-IP discovery / liveness / per-cage net-rule scoping, services
> operator-composed and never blessed. Full design, consumer list (beads single-writer, OAuth
> refresher, package caches, host MCP tools, telemetry collector, cross-cage bus), tradeoffs, and
> decide-or-dismiss triggers live in bead `rip-cage-o7tx`; the three unmeasured exposure inputs
> (guest-traffic source address, other-LAN-device reachability, offline shape) are probed by bead
> `rip-cage-606c`. Do not build without an explicit go decision.

**The honest core:** multi-cage composition buys exactly ONE thing over one-big-cage-with-mounts —
**isolation**. Every "share files / talk / use a service" trick is easier *inside* one cage. So
composition = **cooperation-with-a-wall** (contain a disaster to one cage), NOT "microservices for
agents" (agents aren't heterogeneous the way an app and a DB are).

**Genuinely real affordances of multi-cage:**
- Trust-tiered teams (trusted orchestrator + untrusted workers that must talk but stay walled).
- Credential-domain separation (prod-DB agent vs open-internet agent never share a cage).
- Blast-radius-limited fan-out (N worker cages; one compromise can't poison siblings).
- Ephemeral scratch cages (spin up for one risky op, destroy).

**Wishful / avoid:** "microservices for agents"; "agents talk across cages" as a *headline*
(communication is trivial in-cage; only interesting *because* of the wall); "check beads in another
repo" (that's a mount, not composition).

**Candidate framing to keep poking:** composition = **"org chart for caged agents"** — declare a
team + who-can-touch-what + who-talks-to-whom, compiled to a set of msb cages wired with the right
walls. Above msb's "one computer per agent" thesis. Not crowned; a lens to test.

**Topology:**
- Current (`mosh mac-mini → rc-per-project → herdr-inside`) is a VALID architecture — per-project
  isolation from the host, simple.
- Host-side herdr is an *option* (one cross-project cockpit, survives cage restarts, keeps the
  operator control plane outside the isolation boundary). herdr is a cockpit/multiplexer, not an
  agent, so host-herdr runs no agent code — SAFE. The unsafe thing would be an *agent* on the host.
- The real dial: orchestrator **spawns workers as processes inside its own cage** (simple, one blast
  radius, workers not isolated from each other) vs **spawns brand-new cages** (per-worker isolation,
  but the orchestrator now needs host-fleet control → it becomes a privileged "control-plane" cage
  whose compromise = fleet compromise). Self-driving autonomy inherently requires delegating *some*
  fleet control to an agent-driven component; size that boundary deliberately.
- **Cross-project work = task-scoped cages, NOT cage composition.** Treat a cage as "a workspace
  scoped to a task," not "a project." A cross-project task → one cage mounting exactly those repos;
  agent works across both, fully caged, blast radius = the union it needs anyway. Combine at the
  **cockpit**, isolate at the **cage** — never build one giant cage mounting all projects.

## 7. Known frictions (the actual roadmap seeds)

- **Cross-project work forces a host-side agent today** → fix = task-scoped cages (one cage, the
  relevant repos mounted). *This is the next itch to scratch.* Earns its keep per §5 (msb has no
  notion of project/task/per-project-trust).
- **Nested containers inside a cage** → dissolved by the msb switch (own kernel per cage, dind
  supported). Needs no rc concept.

## 8. Sequence

1. **Capture (now, this doc + memory anchor)** — draft, with me (current model).
2. **Fable review/revise** (several days out, when access returns) — harden the *settled* parts
   (adopt-msb; retire the security engine) into ADRs; leave the exploratory product framing as living
   doc until dogfooding earns the decisions.
3. **Migrate rip-cage to msb** — retire the egress/credential engine; make `rc up` a generator of
   msb flags (see findings §8b for the verb→flag mapping); host-herdr topology is optional.
4. **Scratch the task-scoped-cage itch** — first new capability on the msb base.

Capture-before-migrate is deliberate: capture is cheap and it's what makes the migration coherent
(migrate *toward* a written vision, not blind).

## 9. Honest caveats to keep in view

- **The moat is thin and it's the OSS-standard kind** (first + best + community + taste +
  integration → become the default), not a commercial moat. Fine for the stated goal; not to be
  oversold to ourselves.
- **Needs-pull risk:** building purely to the author's friction can tune rc to personal quirks that
  don't generalize — a drag on the adoption goal. Mitigation: the frictions so far (cross-project,
  isolation, substrate, nested services) look like *shared* agentic-eng pains, not oddities. Keep
  one ear open for "me-problem vs everyone-problem"; me-problems become recipes, everyone-problems
  become core.
- **msb's roadmap climbs into this layer** (#970 Sandboxfile manifest, #769 richer secret
  substitution, their SDKs + cloud). The guardrail (§5) is the defense: stay above msb's abstraction;
  never become a re-wrapper of its own knobs.
