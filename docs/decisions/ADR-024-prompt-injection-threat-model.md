# ADR-024: Prompt-Injection-Driven Harm as First-Class Threat Class

**Status:** Accepted
**Date:** 2026-05-27
**Design:** Brainstorm-converged epic — bead created from `/tmp/brainstorm/pi-security-model-design.md` (filed alongside this ADR).
**Related:**
- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) (D5 framing referenced — container as safety boundary; threat model expansion here updates the rationale that decision rests on)
- [ADR-012 Network Egress Firewall](ADR-012-egress-firewall.md) (D1 and D8 evolved in place under this threat model)
- [ADR-017 SSH-Agent Forwarding](ADR-017-ssh-agent-forwarding-default.md) (D1 evolved in place — scope collapses into network allowlist under this threat model)
- [ADR-019 Pi-Coding-Agent Support](ADR-019-pi-coding-agent-support.md) (D4 evolved in place — Phase 1 promoted to required under this threat model)
- [ADR-023 Secret-Path Mount Denylist](ADR-023-secret-path-mount-denylist.md) (mount-side accident closure under this threat model)
- Project [CLAUDE.md](../../CLAUDE.md) philosophy section ("layers not walls / 80/20 / autonomy is the product / annoying is a design signal") — preserved by this ADR; the philosophy's surface grows to admit the new threat class.

## Context

Rip-cage's existing philosophy and ADR-002 D5 framing implicitly cover one threat class: **honest-mistake accidents by the agent.** The framing ("agent not adversarial") explicitly excluded adversarial-agent threats as out of scope; the cage's job was to limit blast radius of an agent that's trying to do the right thing but gets confused.

That framing did not encode a third reality: **a non-adversarial agent following hostile instructions injected via attacker-controlled content.** The agent itself is still trying to do its job — its goals are intact — but its instructions have been hijacked by content the agent reads as part of normal operation: a fetched README, a third-party MCP server's output, a workspace file written by another agent, a malicious package's install script.

Three rounds of research during the brainstorm that produced this ADR confirmed:

- Documented Claude Code attack vectors include DNS subdomain exfil via auto-approved `ping`/`dig` (a documented exfil *technique* — a ~100 bytes/query covert channel — with no CVE assigned to the DNS-specific class; the adjacent allowlist-bypass network-exfil flaw is [CVE-2025-55284](https://nvd.nist.gov/vuln/detail/CVE-2025-55284), Claude Code < 1.0.4) and the project-file `ANTHROPIC_BASE_URL` redirect that fires API requests with the key before the trust prompt ([CVE-2026-21852](https://nvd.nist.gov/vuln/detail/CVE-2026-21852), Claude Code < 2.0.65, per Check Point Research's "Caught in the Hook" disclosure; note [CVE-2025-59536](https://nvd.nist.gov/vuln/detail/CVE-2025-59536) in the same disclosure is the *separate* startup-trust RCE, not this base-URL redirect).
- Peer agent sandboxes (Anthropic devcontainer, OpenAI Codex sandbox, StepSecurity harden-runner, Cursor agent sandboxing, Vercel Sandbox) all encode prompt-injection-driven exfil as an explicit concern in their egress designs — rip-cage was the outlier in not naming it.
- Simon Willison's "lethal trifecta" (private data access + untrusted content + external comms) and Meta's Nov 2025 "Agents Rule of Two" both frame the threat as a first-class concern for agentic systems.

This ADR canonicalizes the expanded threat model. **It does not displace any existing philosophy or decision.** "Agent not adversarial / layers not walls / 80/20 / autonomy is the product" all remain in force. What changes is that "accident" now includes "honest agent following hostile instructions" — the surface the existing philosophy covers grows; the philosophy's shape does not.

## Decisions

### D1: Prompt-injection-driven harm is in scope

**Firmness: FIRM**

The cage's blast-radius-reduction goal explicitly covers harm caused by a non-adversarial agent following hostile instructions injected via attacker-controlled content. This is admitted alongside the existing "honest-mistake accidents" class, not in place of it.

**Rationale:** the prior implicit framing ("agent not adversarial") only protected against agents trying to do the right thing. Prompt injection turns a well-intentioned agent into a confused deputy that has been hijacked by attacker-controlled content. Without explicit admission of this threat class in the threat model, every layer's coverage decision is being made against an incomplete picture.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Admit as first-class threat class (this decision)** | Layer design now has a coherent target | Threat-model expansion ripples into multiple ADR evolutions |
| Bifurcate cages into accident-mode vs injection-hardened mode | Tighter control per cage | `direct:` rejected during brainstorm — fragments cage behavior, multiplies config surface, "it's annoying" risk on hardened mode pushes users to disable it |
| Treat injection as out of scope | Smaller surface | `direct:` rejected — user's stated primary concern is exfil-via-injection; ignoring would defeat the cage's purpose for the user |

**What would invalidate this:** evidence that rip-cage users routinely face motivated targeted adversaries (e.g., shared multi-tenant cages, hostile-codebase research mode) — at which point the "agent not adversarial" carve-out itself would need re-examination, beyond this ADR.

### D2: Two harm axes named explicitly — exfiltration and on-device harm

**Firmness: FIRM**

Under D1's threat class, two distinct harm axes are in scope:

- **Exfiltration:** sensitive information leaves the cage. Targets include credentials, workspace contents, host files reachable via mounts (covered by ADR-023 mount denylist), and host files reachable via ssh-agent forwarding (covered by ADR-017 evolution).
- **On-device harm:** files inside the cage or its mounts are deleted/corrupted/rewritten; resources consumed (fork bomb, disk fill). Targets include the workspace, mounted dotfiles, cage configuration, and any host paths the cage can reach via mounts.

Layer mapping (informative — load-bearing decisions live in their own ADRs):

| Layer | Exfil axis | On-device-harm axis |
|---|---|---|
| DCG (ADR-004) — chaining-robust (unanchored whole-command regex) | weak (curl is not destructive) | strong |
| ~~Compound-blocker~~ (removed rip-cage-4r8; see ADR-002 D5 — DCG is chaining-robust) | n/a | n/a |
| Mount denylist (ADR-023) | strong (creds not in cage) | strong (host files not reachable) |
| Egress firewall (ADR-012, evolved) | strong (network-layer block) | n/a |
| ssh-agent scope (ADR-017, evolved) | strong (cannot mirror to attacker repo) | n/a |
| Workspace-trust (epic-introduced) | strong (no base-URL redirect) | n/a |

**Rationale:** distinct enforcement layers cover distinct axes. Naming the axes explicitly avoids "layer X protects against prompt injection" hand-waving — each layer's contribution to each axis is auditable.

**What would invalidate this:** discovery of a third axis (e.g., agent-to-agent compromise via shared workspace) that doesn't fit either name. Threat model gets extended; the two-axis carve-out narrows.

### D3: Hostile-input vectors named explicitly

**Firmness: FIRM**

The threat model names the following hostile-input vectors so layer design can target them:

1. **Web fetches by the agent** — `curl`, `wget`, MCP fetch tools, language SDK HTTP clients.
2. **Fetched/cloned repository content** — READMEs, code, comments in repos cloned during work.
3. **Third-party MCP server outputs** — any MCP server the agent loads contributes both tools and tool-result content; both can carry injection.
4. **Workspace files authored by other agents or fetched externally** — files in `/workspace` written by sibling agents, downloaded artifacts, package READMEs.
5. **Package-install scripts** — `npm install`'s post-install scripts, `pip install`'s `setup.py`, equivalents in other ecosystems.

**Rationale:** enumeration enables targeted layer design. "Hostile input could come from anywhere" produces vague, defense-in-depth-by-default designs; named vectors produce layer assignments. Out-of-scope vectors (e.g., side channels, hardware-level attacks) are excluded by D4.

**What would invalidate this:** a real exfil incident via a vector NOT on this list, demonstrating the list is non-exhaustive in ways that matter. Vector added; layer assignment re-derived.

### D4: Explicit out-of-scope items

**Firmness: FIRM**

The following are EXPLICIT non-goals — not oversights:

1. **Motivated targeted attacker with persistent toolkit.** Same explicit non-goal as before D1. Rip-cage is not a security boundary against someone studying internals to build bypasses.
2. **Adversarial agent.** Agent intentionally working against the user. Same explicit non-goal. The threat class admitted in D1 covers *non-adversarial* agents following hostile instructions; it does not cover agents whose own goals are hostile.
3. **Novel injection vectors that bypass every named layer.** Implicit in "limits blast radius, doesn't make agents safe." Not pursued further at the threat-model level.
4. **Side channels.** Timing, power analysis, hardware-level attacks. Out of scope by default for any practical software boundary.

**Rationale:** explicit non-goals prevent scope creep at layer-design time. A future bead arguing "we need to defend against X" should check this list before assuming it's in scope.

**What would invalidate this:** a real incident in any of the named non-goal classes that the user judges should be in-scope. Non-goal list narrows; new threat class admitted; layer design re-evaluated.

### D5: Implicit assumption preserved — injection-affected agent is still "trying to do its job"

**Firmness: FIRM**

The cage's layers assume the agent, even when its instructions are hijacked by injection, is still trying to do its declared job. Specifically:

- A blocked action surfaces as a refusal the agent will tell the user about, not as something the agent silently routes around.
- Self-describing error messages (per ADR-001 fail-loud and per the epic's host-agent-fix-path discipline) are useful: the agent reads them and acts on them in good faith.
- "Layers, not walls" remains coherent: each layer raises friction for a specific harm class; an honest agent (even an injection-affected one) does not coordinate across layers to find a bypass.

This assumption is what distinguishes D1's threat class from "adversarial agent" (D4 #2). An adversarial agent would defeat layers-not-walls by treating refusals as obstacles to route around. The injection-affected agent, by definition, has goals compatible with the user's; only its instructions are hostile. The instructions are subject to the same friction layers apply to honest mistakes — that's what makes the layers work.

**Rationale:** without this assumption, "layers not walls" collapses; every layer would need to be a wall (because the agent would otherwise bypass it), and the cage would have to satisfy a much harder design problem. The assumption is load-bearing for the existing philosophy AND for D1's admissibility.

**What would invalidate this:** evidence that injection-affected agents in practice do coordinate-across-layers to bypass (e.g., a prompt-injected agent that, when egress is blocked, switches to writing exfil data into a git commit that the user later pushes). At that point, the line between "injection-affected" and "adversarial" effectively collapses for that vector, and either the threat model or the layer set needs to harden.

## Consequences

**Positive:**
- Layer design across the security stack has a coherent threat-model target. Each layer's contribution to each axis is auditable per D2's table.
- Existing FIRM ADRs (012 D1+D8, 017 D1, 019 D4) can evolve coherently in place under this threat model without supersession chains.
- The cage's philosophy ("layers not walls / 80/20") gains an explicit threat-class without changing shape.

**Negative:**
- Several existing FIRM decisions need in-place evolution to remain coherent under D1. The brainstorm-converged epic (filed alongside this ADR) carries that evolution work.
- "Out of scope" items (D4) require active enforcement at design-review time — future beads will be tempted to expand the threat model implicitly. The explicit non-goals list is the gate.

## Carry-forward

- `docs/reference/safety-stack.md` and `CLAUDE.md` philosophy section reference this ADR.
- The epic implementing the layer changes (egress whitelist + observe-mode + DNS inspection + HTTP/3 block + ssh-agent scope + pi parity + workspace-trust + agent-first CLI for the fix path) is the immediate consumer.
- Future ADR work touching any in-cage safety layer references this ADR's threat model unless explicitly diverging.
