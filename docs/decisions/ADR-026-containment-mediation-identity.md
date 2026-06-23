# ADR-026: Rip-Cage Identity — Containment Layer + Delegated Mediation Seam

**Status:** Accepted (D2 revised 2026-06-17 — wlwc: the **ssh-bypass command hook** reclassified OUT of containment to a composable default-on command-guard recipe (sibling to DCG, ADR-025 D2); welded ssh containment is the known_hosts/config mount floor (ADR-022 D4); DNS exfil guard stays containment. D5 revised 2026-06-17 — lifted EXPLORATORY→FIRM on the in-cage E4 proof + real-`rc up` auto-launch; second-provider behavioral residual discharged 2026-06-17 — iron-proxy E4, rip-cage-nyst)
**Date:** 2026-06-11
**Design:** bead `rip-cage-ta1o` (full decision narrative, verdict:pass) ; competitor investigated from source: github.com/denoland/clawpatrol (reclassified to *alternative appliance* — D5)

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

- **Containment (rip-cage's, low-drift):** force-through-chokepoint, destination/host control (incl. the ssh known_hosts/config mount floor, ADR-022 D4), CA-trust *install*, and the boundary-defense guards that pass the tie-break (the DNS exfil sidecar). Container-native; stable (a host list and an iptables rule don't change when an upstream rotates an auth scheme). **Note (revised 2026-06-17):** command-string PreToolUse classifiers (DCG, the ssh-bypass hook) are NOT in this bucket — they are high-drift harness-specific command-string policy, demoted to composable default-on command-guard recipes per ADR-025 D2 / wlwc D1-D2, sitting *above* the containment line.
- **Mediation (the mediator's, high-drift):** read *into* and rewrite traffic — L7 method/path policy, protocol parsing, credential injection, human approval. Specialist-maintained; drifts with every upstream auth/protocol change.

**Tie-break for content-peeking guards:** a guard that peeks at content stays rip-cage's **iff** it (a) defends rip-cage's own egress boundary, (b) is low-drift, AND (c) its enforcement machinery is cheap and *separable* from the TLS-termination stack. The DNS exfil guard qualifies on all three (separate port-53 sidecar — ADR-012 D9); method-asymmetry fails (c) (it requires the whole TLS-termination stack — ADR-012 D2/D4).

**Reclassification (revised 2026-06-17 — wlwc / [ADR-025 D2](ADR-025-host-adoptable-dcg-policy.md), [ADR-027 D1](ADR-027-agent-substrate-projection.md)):** the **ssh-bypass command hook** (`block-ssh-bypass.sh`) is **NOT containment** — it is a **command-string PreToolUse classifier**, exactly the sibling of DCG, and is demoted to a **composable default-on command-guard recipe** (ADR-025 D2: command-string guards sit *above* the containment line as accident-guardrails, not at it). This corrects the prior tie-break pass, which had classified the ssh-bypass hook as a boundary-defense guard passing the (a)(b)(c) tie-break (destination-allowlist defender): the tie-break criterion (container-native, low-drift, separable from TLS-termination) assumes a guard operating at the network/mount layer, and the hook was misclassified as a "boundary-defense guard" because its *purpose* is destination-scoping — but its *mechanism* is a command-string PreToolUse classifier, which is high-drift and harness-specific by mechanism (same tier as DCG), so it belongs in the command-guard recipe tier even though its goal aligns with destination-scoping. What stays **welded containment** for ssh is **destination scoping enforced at the network / known_hosts / config-mount layer** (ADR-022 D4 — the read-only filtered-known_hosts and config mount floor). The honest consequence: the mount-layer known_hosts floor does NOT by itself close the CLI-flag bypass (`-o UserKnownHostsFile`, `-o StrictHostKeyChecking=accept-new`); that class is closed by the ssh-bypass *hook recipe*. So **full ssh destination scoping = welded mount floor + default-on ssh-bypass recipe**, exactly parallel to DCG (egress destination-control is the network containment; the command-hook recipe completes the CLI-flag class). The **DNS exfil guard** genuinely qualifies on the tie-break (a)(b)(c) and remains rip-cage's containment. So among the formerly-grouped "boundary-defense guards", the DNS exfil sidecar stays containment; the ssh-bypass hook moves to the command-guard recipe tier. Command-string command hooks (DCG, ssh-bypass) are composable recipes above the containment line (wlwc design D1/D2), not welded containment — consistent with D1 ("rip-cage IS containment; mediation is delegated") whose welded floor is exactly the agent-agnostic containment layers, command-string policy excluded.

**Rationale:** every line of mediation rip-cage owns drifts behind the specialist who is focused on it; containment is stable and only a container can do it (D3). The drift-rate cut means the boundary is derivable, not negotiated per layer.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Sort by "box vs wire" (network layer) | `reasoned:` mis-sorts the DNS exfil sidecar (peeks at content but defends the chokepoint — drift-rate sorts it into containment via the tie-break). The ssh-bypass hook is no longer classified here at all: per the 2026-06-17 reclassification it is a command-string PreToolUse classifier demoted to a composable default-on command-guard recipe (ADR-025 D2 / wlwc), above the containment line — the welded ssh containment is the known_hosts/config mount floor (ADR-022 D4). |
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

### D5: Composition shape — a composable-provider mediator seam (isomorphic to the session-multiplexer seam); bundle nothing

**Firmness: FIRM** (revised 2026-06-17 — lifted from EXPLORATORY on the real-cage E4 proof + real-`rc up` auto-launch; see Validation below)

rip-cage exposes egress mediation as a **composable provider seam**, built isomorphic to the session-multiplexer seam (ADR-005 D12, ADR-006 D7–D8, ADR-021 D6): rip-cage owns the *interface*, blesses *no* mediator, and `none` ships by default. The shape, mapped element-for-element from the multiplexer pattern:

- **Selection config:** `network.egress.mediator` (default `none`). The allowed-set is `none` + whatever MEDIATOR providers the tool manifest declares and `rc build` bakes (read host-side from an `rc.mediators` image label, with a manifest fallback) — **not a fixed enum**. Directly mirrors `session.multiplexer` (ADR-021 D6). `none` = the built-in destination router + DNS heuristic only (the accident-containment tier, D6); no mediator in the path.
- **Provider archetype:** a new **MEDIATOR** tool-manifest archetype. Its hooks (`start` the proxy at cage init; optional `health_check` / `teardown`) bake to `/etc/rip-cage/mediators/<name>/<hook>`, on the same footing as the MULTIPLEXER archetype (ADR-005 D7) and bounded by the D11 fail-closed validator. Adding a mediator (mitmproxy, iron-proxy, a future one) is a manifest entry with **zero `rc` edits** (ADR-005 D12).
- **Handoff seam:** rip-cage's HTTP/TLS router gains `network.http.forward_to` — the HTTP analog of the DNS `forward_to` seam shipped in ta1o.2 (ADR-012 D9). On ALLOW (after destination policy), the router connects to the mediator's listen address instead of the origin, conveying the original destination via **HTTP CONNECT** (the router opens to the mediator, sends `CONNECT <orig-dst>`, then replays the buffered ClientHello and splices — CONNECT fits the router's existing SNI-peek `first_chunk` buffering and is what mitmproxy regular-mode and iron-proxy both speak; SOCKS5 was the considered alternative). The mediator MITM-terminates, applies L7 policy + injection, and re-originates to the real upstream.
- **Launch leg — host-driven root, sibling to the firewall (corrected 2026-06-17):** the "isomorphic to the multiplexer" framing holds for *selection* and *forward* but is **wrong for launch**. The mediator does NOT launch from the agent-context init (`init-rip-cage.sh`) or the multiplexer tier; it launches from `init-mediator.sh`, a host-driven `docker exec -u root` step run by `rc up` right after `init-firewall.sh` and before the agent-context init — because the mediator is network-containment substrate (path-sitting, dedicated non-root uid, coupled to the firewall's uid-exemption), so its sibling is the **firewall**, not the session multiplexer. Root comes from the host (no new standing agent sudo — least privilege); the process is backgrounded with `nohup` (survives the exec returning, dies with the container — no EXIT-trap teardown); the real secret arrives via `rc up --mediator-env` into the mediator's process env only (never container-level env / `/proc/1/environ`); the optional `ca_cert_path` is installed into the cage trust store; runs on both create and resume paths. Conflating the launch tier with the multiplexer was the source of the broken auto-launch leg the proof surfaced (rip-cage-ta1o.5.7 → reworked in .5.8).

**Responsibility split** (mirrors ADR-006 D7's box-entry-vs-spawn cut): rip-cage owns force-through + the destination floor + the `forward_to` handoff; the mediator owns L7 content policy + credential injection; egress *policy* (allowlist content, what triggers human review) stays in the consumer.

**The push-vs-pull asymmetry — and why the floor is uncrossable.** A multiplexer is *pull-side* availability-payload: the agent runs *inside* it, and ADR-005 D9 was careful it can never be a policy interceptor. An egress mediator is the **opposite — push-side**: it sits in the traffic path and rewrites (mediation *is* push-side, D1). The binding consequence: rip-cage's destination allow/deny + the non-overridable IOC floor (ADR-012 D6) run **before** forward, so the mediator only ever receives already-allowed traffic. The mediator may **add** restriction (L7, injection) but can **never subtract** from the floor — additive-only, the same uncrossable-floor discipline as the IOC denylist (ADR-012 D6) and host-adoptable DCG (ADR-025). The D11 validator enforces this on MEDIATOR hooks: a manifest-authored or prompt-injected mediator entry must not declare a hook that disables force-through (`RIP_CAGE_EGRESS=off`, `iptables` manipulation), bypasses the IOC floor, writes a DCG config, or PATH-shadows a safety binary. The mediator runs as a **co-located process under a dedicated uid** (not a separate container — keeping it within the single cage per ADR-005 D8), and loop prevention is a **uid-scoped iptables egress exemption** — the same mechanism `init-firewall.sh` already applies to the router's own `rip-proxy` uid — so the mediator's already-allowed re-origination is not re-captured by the cage's REDIRECT. (The mediator is a user-composed, validator-bounded tool; its uid exemption mirrors the router's own trust, and the floor is enforced at the router *before* forward, so the exemption does not widen the destination floor.)

**Reference providers, not blessed defaults** (ADR-005 D12): mitmproxy is the **first reference provider** (the validation target — transparent intake + a small injection addon), iron-proxy the **recommended adopt** (GA, Apache-2.0; OOTB transparent intake + placeholder→secret injection + default-deny). Both ship as `examples/` provider definitions + recipes, never special-cased in `rc`.

**clawpatrol reclassified — alternative appliance, not reference mediator** (revised 2026-06-16; read from source at commit `124cb3d`). clawpatrol cannot plug into the `forward_to` seam: its gateway has **no plain-TCP / transparent-proxy ingress** — off-host traffic enters only through its own WireGuard netstack from an enrolled, operator-approved device, and credential injection scopes to the WG-peer identity (the loopback `:8443` listener is the dashboard/join surface, not the inject path). It is a vertically-integrated L3-router **appliance** — the "let the mediator own capture too" approach D3 already rejects — so you run it *instead of* rip-cage (optionally with rip-cage as a redundant outer shell), not *downstream of* it. Its injection-MITM core is MIT-licensed and cleanly extractable (moderate effort) into a composable micro-mediator should we ever choose to own one; that is a future option, not a dependency of this seam.

**Rationale:** the **agent is the installer** (setup cost dissolves); owning the *provider interface* (stable) not an orchestrator (couples rip-cage to one mediator's lifecycle, recreating the monolith) keeps maintenance on the right side; and reusing the proven multiplexer-provider pattern means the seam inherits a dogfooded, isomorphic shape rather than inventing a second composition-interface to maintain. (Built + validated end-to-end 2026-06-17 — see Validation below; lifted to FIRM.)

**Validation (discharged 2026-06-17 — the EXPLORATORY rationale no longer holds):** the seam is now built and proven end-to-end in a real Linux Docker cage; the EXPLORATORY basis was "not yet built or validated end-to-end," and rebutting that is the lift's warrant. (The prior `composition-seam.md` HTTP attach — "Option A WireGuard / Option B socat" — was **doc-only prose** with no rip-cage forwarding code; building `network.http.forward_to` is what made the seam real, and the prior clawpatrol macOS-host spike is moot since clawpatrol is not a `forward_to` mediator.) Proof: with a sentinel real secret configured mediator-side and only a placeholder in the agent env, `httpbin.org/headers` echoed the **exact sentinel** (placeholder absent, header present), the floor still **held** with the mediator composed (non-allowlisted host denied), and a `none` cage showed **no regression** (rip-cage-ta1o.5.4, 60/60). The full **select→launch→forward** chain — not just select→forward — runs via real `rc up` auto-launch with credential **non-possession** proven (the secret is absent from `/proc/1/environ`; rip-cage-ta1o.5.8). Tool-agnosticism is shown by a second, differently-shaped provider (iron-proxy) plugging in with **zero `rc` edits** (rip-cage-ta1o.5.5). **Residual (bounds the FIRM claim honestly):** the iron-proxy-behavioral half of this residual is **discharged 2026-06-17** (rip-cage-nyst) — iron-proxy now carries its own real-`rc up` auto-launch E4: exact-sentinel injection (placeholder absent, header present), credential **non-possession** (`/proc/1/environ` clean), floor-holds-composed (non-allowlisted host denied), all with **zero `rc` edits** and independently re-verified in-shell (73/73). The seam is thus demonstrated across **two differently-shaped providers** — the strongest evidence for the tool-agnosticism claim. The one remaining residual: both providers' E4s used `httpbin.org` (`SKIP_AUTH`), proving the injection *mechanism*, not a live Anthropic-OAuth token flow (tracked at this decision's invalidation tripwire 4 and ADR-024 D2). FIRM covers the **seam architecture** (selection / CONNECT handoff / push-side uncrossable floor / co-located-uid topology / host-driven root launch), not any one provider's production credential integration.

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Turnkey `rc up --with-cp` orchestration | `reasoned:` (causal) embedding one mediator's lifecycle couples rip-cage to that mediator and locks out alternatives, recreating the monolith this reshape backs out of. |
| Seam-only, no reference recipe | `reasoned:` leaves the weak user at the mediator's onboarding cliff with no help, defeating the agent-as-installer value that makes "compose, don't build" livable. |
| Invent a bespoke mediator seam (not the multiplexer provider pattern) | `reasoned:` forks a second composition-interface shape to maintain; the multiplexer provider pattern (ADR-005 D12 / ADR-021 D6) is already dogfooded and isomorphic — reuse it. |
| Keep clawpatrol as the reference recipe target | `direct:` (clawpatrol source @`124cb3d`: gateway WG-tunnel-only ingress, no transparent-proxy port, injection scoped to WG-peer identity) — it cannot receive forwarded traffic from an external chokepoint; it is an alternative appliance, not a downstream mediator. |

**What would invalidate this (now FIRM — forward-looking tripwires):** (1) a dependency bump (the router's CONNECT handling, or mitmproxy/iron-proxy CLI/config) breaks the `forward_to` handoff so a composed mediator no longer receives forced-through traffic; (2) the D11 validator is found to miss a floor-weakening MEDIATOR hook (the push-side floor became crossable); (3) the host-driven launch cannot start a mediator unattended on a supported substrate (agent-as-installer breaks for the launch leg); or (4) a live production credential flow (e.g. Anthropic OAuth) cannot be injected through the same seam without per-service mediation creeping back into rip-cage (D4 boundary). Any of these re-opens the composition shape.

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
- **D5** (proxy in container, "nothing on host") → the destination router + DNS force-through stay **in-container**; the "self-contained" framing now admits an external mediator the chokepoint forwards to via the `network.http.forward_to` handoff seam (ADR-026 D5; composition is opt-in coupling, not a default).
- **D6** (`RIP_CAGE_EGRESS=off`) → reframed: the switch disables iptables + the router (there is no content-proxy to disable).
- **D9** (DNS exfil sidecar) → **retained** as containment (D2 tie-break) AND gains a forward-to-specialist seam (built-in low-drift heuristic is the default; power users forward to NextDNS / Umbrella / dnsdist / Zeek).

## canonical_refs

- [ADR-002](ADR-002-rip-cage-containers.md) — container-as-boundary identity (this ADR is the network-composition extension; ADR-002 D5 holds the boundary inward, this delegates mediation outward)
- [ADR-005](ADR-005-ecosystem-tools.md) D7–D10 — composable host-only tool manifest (the seam pattern D5 aligns with) ; D11 — fail-closed validator bounding MEDIATOR hooks (D5) ; D12 — composable-seam-not-bundler, the multiplexer-provider pattern D5 is isomorphic to
- [ADR-006](ADR-006-multi-agent-architecture.md) D7 — rip-cage as a composable asset, orchestration external (the orchestration-layer cousin of this network-layer cut; box-entry-vs-spawn split mirrored by D5's responsibility split) ; D8 — wire tool↔tool only through public CLIs (D5 forwards via the mediator's public listen interface)
- [ADR-009](ADR-009-ux-overhaul.md) D1 — harm-reduction positioning (D1, D6)
- [ADR-012](ADR-012-egress-firewall.md) D2/D4/D5/D6/D9 — the egress decisions this ADR re-homes (see Consequences) ; D6 — the non-overridable IOC floor the mediator may add to but never subtract from (D5 push-side asymmetry) ; D9 — the DNS `forward_to` seam D5's `network.http.forward_to` is the HTTP analog of
- [ADR-021](ADR-021-layered-rip-cage-config.md) D6 — `session.multiplexer` config shape (default none, manifest-derived allowed-set, not a fixed enum) that `network.egress.mediator` (D5) directly mirrors
- [ADR-017](ADR-017-ssh-agent-forwarding-default.md) — ssh-agent forwarding unchanged standalone (D4)
- [ADR-022](ADR-022-ssh-allowlist.md) D4 — the welded ssh known_hosts/config mount floor (containment, D2); D5 — the ssh-bypass *hook* is **reclassified 2026-06-17** out of containment to a composable default-on command-guard recipe (ADR-025 D2 / wlwc), sibling to DCG; full ssh destination scoping = welded mount floor + default-on ssh-bypass recipe (D2 tie-break)
- [ADR-024](ADR-024-prompt-injection-threat-model.md) D2 (credential-exfil axis — standalone gap, D4) ; D4 (motivated adversary out of scope — D3 framing) ; D5 (cross-layer-coordination assumption — D1 invalidation)
- [ADR-025](ADR-025-host-adoptable-dcg-policy.md) D2 (revised 2026-06-17) — DCG demoted from welded floor to a composable default-on command-guard recipe; the command-guard tier (DCG, ssh-bypass) sits above the containment line that D1/D2 weld
- bead `rip-cage-ta1o` — converged design + adversarial-review record (verdict:pass)
- bead `rip-cage-4c5` — wpu/herdr composable-tool-manifest epic (the pluggability direction this is the network-layer sibling of)
- External: github.com/denoland/clawpatrol — **alternative appliance** (D5; read from source @`124cb3d`: gateway WG-tunnel-only ingress with no transparent-proxy port, `cmd/clawpatrol/tailscale.go` loopback `:8443` is the dashboard/join surface not the inject path, injection scoped to WG-peer identity — cannot plug into the `forward_to` seam; MIT-licensed injection core in `internal/config/plugins/credentials/bearer_token.go` is extractable into a micro-mediator if ever wanted)
- External: github.com/ironsh/iron-proxy — recommended adopt reference mediator (D5; GA, Apache-2.0, transparent intake + OOTB placeholder→secret injection)
- External: mitmproxy — first reference provider / validation target (D5; transparent intake + small injection addon)
