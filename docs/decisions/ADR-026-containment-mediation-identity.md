# ADR-026: Rip-Cage Identity — Containment Layer + Delegated Mediation Seam

**Status:** Accepted
**Date:** 2026-06-11
**Design:** bead `rip-cage-ta1o` (full decision narrative, verdict:pass) ; competitor investigated from source: github.com/denoland/clawpatrol

## Context

rip-cage's safety stack has been growing a network layer that aspires to per-request L7 policy (ADR-012's TLS-MITM, method/path rules). The Deno team's **clawpatrol** — a protocol-aware "firewall for agents" (WireGuard/Tailscale tunnel → TLS-MITM gateway → CEL/HCL rules → credential injection → human-in-the-loop) — does that *content* layer far more thoroughly than rip-cage ever will, and carries a property rip-cage structurally lacks: **credential non-possession** (the agent holds only placeholder tokens; the gateway injects the real secret on the wire).

Reading clawpatrol from source forced the question this ADR answers: *where does rip-cage stop, and where does a composed mediator begin?* The answer is not "build the content layer better" — it is to draw the boundary so the two **compose** instead of overlap, and to make that boundary an objective property (maintenance drift-rate) rather than a taste call. This is the network-layer instance of the same "rip-cage is a composable asset, not a monolith" direction ADR-006 D7 takes for orchestration and ADR-005 D7–D10 takes for tooling.

## Decisions

### D1: Identity — rip-cage is containment; mediation is delegated

**Firmness: FIRM**

rip-cage controls **where** traffic may go (destination control + a force-through chokepoint that captures all egress) and **routes** it to an external mediator for **what** may be said. It does not read the application's actual conversation. Analogy: **customs, not the postal service** — customs may open a bag to check for smuggling at the border, but it never reads your documents to decide whether your business is allowed.

**Rationale:** makes "rip-cage never reads application content" true *by construction* rather than by discipline; aligns with the harm-reduction positioning (ADR-009 D1) and keeps rip-cage out of the high-drift content-policy business it cannot maintain against a focused specialist (D2).

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Keep rip-cage a content-reading mini-firewall (status quo: ADR-012 L7 MITM) | `reasoned:` pulls rip-cage onto the high-drift mediation slope (D2) it cannot maintain against a focused specialist; the content layer it would own is exactly what a composed mediator does better. |
| Fold a full mediator (CP-style injection + HITL) into rip-cage | `direct:` (architectural fact of TLS-MITM credential injection) concentrates every real secret into one MITM box and inverts the "walk away, no infra, per-container blast-radius" identity (ADR-002). |

**What would invalidate this:** if injection-affected agents in practice coordinate across layers to route around refusals (ADR-024 D5's load-bearing assumption fails), the containment/mediation line blurs — a content-reading layer rip-cage delegated would need to come back in-house.

### D2: The spine — sort safety layers by maintenance drift-rate

**Firmness: FIRM**

Every safety layer sorts into one of two buckets, and the cut is the **maintenance drift-rate**, which makes it objective:

- **Containment (rip-cage's, low-drift):** force-through-chokepoint, destination/host control, CA-trust *install*, and boundary-defense guards. Container-native; stable (a host list and an iptables rule don't change when an upstream rotates an auth scheme).
- **Mediation (the mediator's, high-drift):** read *into* and rewrite traffic — L7 method/path policy, protocol parsing, credential injection, human approval. Specialist-maintained; drifts with every upstream auth/protocol change.

**Tie-break for content-peeking guards:** a guard that peeks at content stays rip-cage's **iff** it (a) defends rip-cage's own egress boundary, (b) is low-drift, AND (c) its enforcement machinery is cheap and *separable* from the TLS-termination stack. The DNS exfil guard qualifies on all three (separate port-53 sidecar — ADR-012 D9); method-asymmetry fails (c) (it requires the whole TLS-termination stack — ADR-012 D2/D4); the ssh-bypass hook qualifies as a destination-allowlist defender (ADR-022 D5). Owning a low-drift guard via thin wrapping is the same posture ADR-025 took for DCG.

**Rationale:** every line of mediation rip-cage owns drifts behind the specialist who is focused on it; containment is stable and only a container can do it (D3). The drift-rate cut means the boundary is derivable, not negotiated per layer.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Sort by "box vs wire" (network layer) | `reasoned:` mis-sorts the boundary-defense guards (DNS exfil, ssh-bypass hook) which peek at content but defend the chokepoint; drift-rate sorts them correctly via the tie-break. |
| Hard Unix cut — rip-cage drops the wire entirely, all network is the mediator's | `reasoned:` loses force-through (D3), which is the box; a standalone user would get capture with zero protection, and the composition would be unsound (agent bypasses the mediator's tunnel). |

**What would invalidate this:** a content-policy layer turning out to be genuinely low-drift AND container-native AND uncoverable by any composable mediator — would warrant pulling that specific layer back into containment.

### D3: The single container-native contribution — guarantee the chokepoint

**Firmness: FIRM**

rip-cage's irreducible contribution is to **guarantee all egress (HTTP and DNS) hits a chosen chokepoint.** A network gateway cannot force-capture an agent that routes around its tunnel (clawpatrol's own security-model doc admits this); a container owns its network namespace and can. *What happens at the chokepoint is pluggable* (a built-in destination allowlist / DNS heuristic by default, or forward to a composed mediator).

**Framing note (CLAUDE.md):** this is the container's unique *capability*, not a containment guarantee against a motivated adversary. Boundary-flavored language ("moat," "wall") is a trap the project warns against — the force-through limits accident/injection blast-radius; it is not a wall, and a motivated adversarial agent remains out of scope (ADR-024 D4).

**Rationale:** the force-through is what makes any composition sound — without it, a prompt-injected agent bypasses the mediator entirely. It is also the one egress capability a composed network-mediator structurally cannot provide for itself.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Let the mediator own capture too (CP `run`/`join` netns trick) | `direct:` (clawpatrol security-model.md) a host-process tunnel admits "if the agent bypasses the tunnel it gets the open internet"; only the netns owner (the container) can force capture. |

**What would invalidate this:** if a mediator ships a container-runtime that itself owns the netns and force-captures (collapsing this contribution), or if force-through proves bypassable from inside the cage under bypassPermissions, this stops being rip-cage's to claim.

### D4: No mediation built into rip-cage; credential non-possession is a composition property

**Firmness: FIRM**

rip-cage builds **no** credential injection and **no** content policy. ssh-agent forwarding (ADR-017) and real-creds-in-container remain the standalone posture; **credential non-possession is a property gained by composing a mediator**, not a rip-cage feature.

**Standalone gap, stated explicitly:** with real creds in the container, standalone rip-cage does **not** close the **credential-exfil axis** named in ADR-024 D2 — a prompt-injected agent can read its own env / `.credentials.json` and exfiltrate the real token to any allowed destination. The egress allowlist narrows the *destination*; it does not stop the *read*. Closing this axis requires composing a mediator for non-possession; standalone is the accident-containment tier only (D6).

**Rationale:** injection is mediation (high-drift — a specialist maintains ~6 mechanisms across ~20 credential types). The "cheap generic-header injection" option was reconsidered and rejected: cheap to *build* but in the *drift* category and the first step onto the slope a specialist already descended.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Build cheap generic-header credential injection (placeholder→real swap on the existing proxy) | `reasoned:` cheap to build but it is mediation by D2 (reads/rewrites the auth header), high-drift, and the first step onto the slope; value-framing is the wrong axis, the drift-rate cut (D2) governs. |
| Drop ssh-agent forwarding to reduce standalone credential exposure | `direct:` (ADR-017) breaks agent autonomy (pushes fail) — the cure (creds out of the cage) is the mediator's job, not a regression of the standalone tier. |

**What would invalidate this:** if a single-mechanism, genuinely low-drift injection covering the dominant secret (the Anthropic OAuth token) emerges that does NOT pull in per-service maintenance, the no-mediation line *for that one secret* could be revisited.

### D5: Composition shape — tool-agnostic seam + reference recipe; bundle nothing

**Firmness: EXPLORATORY**

rip-cage exposes the chokepoint's upstream as a **tool-agnostic seam** (expose a forward target, like exposing a proxy interface — not embed a proxy) and ships a **reference recipe**. It bundles and orchestrates **nothing**.

**Rationale:** the **agent is the installer** — a coding agent can stand up the mediator and align with its user on the OAuth/credential steps, so "the mediator is hard to set up" largely dissolves. Owning the recipe (stable) not an orchestrator (couples rip-cage to one mediator's lifecycle, recreating the monolith) keeps maintenance on the right side. EXPLORATORY because the production-path validation is open (see below).

**Open validation (why EXPLORATORY):** a spike (bead `rip-cage-ta1o`) proved a clawpatrol gateway stands up headless and injects a credential end-to-end (placeholder→real, httpbin echo) — but the *gateway-setup + injection* half is platform-agnostic, while the *container-side routing attach* (userspace-WireGuard inside the cage) ran on a macOS **host** as proof-of-mechanism, NOT inside a Linux container (the production path). The userspace-WG client is portable Go with no kernel deps, so the risk is low; validating the attach inside a real Linux cage is the gating step before this rises to FIRM.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Turnkey `rc up --with-cp` orchestration | `reasoned:` (causal) embedding one mediator's lifecycle couples rip-cage to that mediator and locks out alternatives, recreating the monolith this reshape backs out of. |
| Seam-only, no reference recipe | `reasoned:` leaves the weak user at the mediator's onboarding cliff with no help, defeating the agent-as-installer value that makes "compose, don't build" livable. |

**What would invalidate this:** if the Linux-container attach turns out to need a human at any step other than the deliberate device-approval gate, the agent-as-installer premise weakens toward needing some orchestration after all — and "seam + recipe is enough" would not hold.

### D6: Tiering — standalone is accident-containment; exfil-grade requires composition

**Firmness: FIRM**

Standalone rip-cage is honestly the **accident-containment** tier ("at least put your Claude in a cage" — ADR-009 D1). **Exfil-grade** security — closing the credential-exfil axis (D4) and the content-exfil channels (delegated mediation) — requires composing a mediator. Docs and the reference recipe actively urge composition; standalone is never marketed as an exfil boundary.

**Rationale:** false-guarantee framing is the failure CLAUDE.md / ADR-009 explicitly reject; standalone leaves the credential-exfil axis open (D4), so claiming exfil-grade standalone would be exactly that false guarantee.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Market standalone as exfil-grade | `direct:` (ADR-024 D2) standalone leaves the credential-exfil axis open; the claim would be a false guarantee of the kind ADR-009/CLAUDE.md reject. |

**What would invalidate this:** if users empirically read standalone rip-cage as providing exfil-grade guarantees (the false-confidence failure), the positioning is mis-calibrated and the docs/recipe must push composition harder or gate a warning.

## Consequences for ADR-012 (egress firewall)

ADR-012's L7 TLS-MITM direction is the layer this ADR re-homes as *mediation*. The in-place evolution of ADR-012's decisions lands with the implementation (bead `rip-cage-ta1o`), so the ADR continues to describe shipped state until then; the decisions affected and the direction are:

- **D2** (L7 method/path rules) → removed; egress becomes a pure **destination router** (read SNI/host, allow/deny the destination). Method/path policy is delegated mediation (D1).
- **D4** (uniform TLS-MITM incl. Anthropic API) → standalone egress no longer terminates TLS. Consequence: standalone loses *content-visibility* into the Anthropic API; the actual threat it guarded (`ANTHROPIC_BASE_URL` redirect, CVE-2026-21852) remains covered by **destination-control** (a redirected base URL points at a non-allowlisted host the router blocks). Content-visibility returns when a mediator is composed.
- **D5** (proxy in container, "nothing on host") → the destination router + DNS force-through stay **in-container**; the "self-contained" framing now admits an external mediator the chokepoint forwards to (composition is opt-in coupling, not a default).
- **D6** (`RIP_CAGE_EGRESS=off`) → reframed: the switch disables iptables + the router (there is no content-proxy to disable).
- **D9** (DNS exfil sidecar) → **retained** as containment (D2 tie-break) AND gains a forward-to-specialist seam (built-in low-drift heuristic is the default; power users forward to NextDNS / Umbrella / dnsdist / Zeek).

## canonical_refs

- [ADR-002](ADR-002-rip-cage-containers.md) — container-as-boundary identity (this ADR is the network-composition extension; ADR-002 D5 holds the boundary inward, this delegates mediation outward)
- [ADR-005](ADR-005-ecosystem-tools.md) D7–D10 — composable host-only tool manifest (the seam pattern D5 aligns with)
- [ADR-006](ADR-006-multi-agent-architecture.md) D7 — rip-cage as a composable asset, orchestration external (the orchestration-layer cousin of this network-layer cut)
- [ADR-009](ADR-009-ux-overhaul.md) D1 — harm-reduction positioning (D1, D6)
- [ADR-012](ADR-012-egress-firewall.md) D2/D4/D5/D6/D9 — the egress decisions this ADR re-homes (see Consequences)
- [ADR-017](ADR-017-ssh-agent-forwarding-default.md) — ssh-agent forwarding unchanged standalone (D4)
- [ADR-022](ADR-022-ssh-allowlist.md) D5 — ssh-bypass hook as a destination-allowlist defender (D2 tie-break)
- [ADR-024](ADR-024-prompt-injection-threat-model.md) D2 (credential-exfil axis — standalone gap, D4) ; D4 (motivated adversary out of scope — D3 framing) ; D5 (cross-layer-coordination assumption — D1 invalidation)
- [ADR-025](ADR-025-host-adoptable-dcg-policy.md) — DCG as a low-drift owned guard via wrapping (precedent for the D2 tie-break)
- bead `rip-cage-ta1o` — converged design + adversarial-review record (verdict:pass)
- bead `rip-cage-4c5` — wpu/herdr composable-tool-manifest epic (the pluggability direction this is the network-layer sibling of)
- External: github.com/denoland/clawpatrol — reference mediator (read from source: `cmd/clawpatrol/dnsvip/dnsvip.go` routing-only; `internal/config/plugins/credentials/bearer_token.go` injection mechanism; `site/doc/security-model.md` tunnel-bypass admission)
