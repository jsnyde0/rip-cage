# ADR-024: Prompt-Injection-Driven Harm as First-Class Threat Class

**Status:** Accepted (revised 2026-06-09 — D6 added: MCP posture)

> **Migration status (ADR-029, 2026-07-10):** The threat model itself is unaffected by [ADR-029](ADR-029-msb-migration.md) — the axes, vectors, and out-of-scope items in D1/D3/D4/D5 are unchanged. Only the layer *mappings* in D2 evolve (mechanisms re-home to msb), and D6's egress-firewall reference restates as the msb VM boundary. The msb cutover has landed (S1-S14, branch `wave/s13-docs` off `msb-cutover`) — the mechanisms below are retired/replaced per the dispositions above; this ADR is retained for historical record, not current behavior. See [ADR-029](ADR-029-msb-migration.md) for what replaced them.

**Date:** 2026-05-27
**Design:** Brainstorm-converged epic — bead created from `/tmp/brainstorm/pi-security-model-design.md` (filed alongside this ADR). D6 added 2026-06-09 (rip-cage-b4c).
**Related:**
- [ADR-002 Rip Cage Containers](ADR-002-rip-cage-containers.md) (D5 framing referenced — container as safety boundary; threat model expansion here updates the rationale that decision rests on; D18 meta-skill MCP shim is the sanctioned in-cage MCP server per D6)
- [ADR-005 Ecosystem Tools](ADR-005-ecosystem-tools.md) (D7 IN-CAGE-DAEMON archetype — `mcp_fragment` reaches MCP-capable agents only; the integration-side counterpart to D6's posture)
- [ADR-012 Network Egress Firewall](ADR-012-egress-firewall.md) (D1 and D8 evolved in place under this threat model; the network-layer firewall is what makes in-cage MCP egress already-contained per D6)
- [ADR-017 SSH-Agent Forwarding](ADR-017-ssh-agent-forwarding-default.md) (D1 evolved in place — scope collapses into network allowlist under this threat model)
- [ADR-019 Pi-Coding-Agent Support](ADR-019-pi-coding-agent-support.md) (D4 evolved in place — Phase 1 promoted to required under this threat model; D9 CLI-over-MCP for bash-only agents — the integration-side counterpart to D6's posture)
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

> [ADR-029 D2/D3/D5: EVOLVED — the axes themselves (exfiltration, on-device harm) are unaffected; the layer-mapping table below re-maps mechanism-by-mechanism (see inline notes on the Egress firewall and ssh-agent-scope rows) and gains a DNS-exfil residual note per ADR-029 D2 item 3. The credential-exfil axis largely closes at cutover — msb `--secret` non-possession means the dominant secret (Claude's token) is never a real credential inside the guest — with the per-tool boundary named honestly: pi stays possession-mode (no static openai-codex token), so the axis does not close uniformly across tools. The t7cu fixed-`/workspace`-path residual (below) survives conceptually under msb's fixed guest mount path — marked re-verify, not assumed identical.]

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
| Egress firewall (ADR-012, evolved) — **re-maps to msb host-side egress (ADR-029 D2) at cutover; shipped as ADR-012 until then** | strong (network-layer block) | n/a |
| ssh-agent scope (ADR-017, evolved) — **retired (ADR-029 D3); HTTPS tokens + `--secret` replace this row at cutover** | strong (cannot mirror to attacker repo) | n/a |
| Workspace-trust (epic-introduced) | strong (no base-URL redirect) | n/a |
| DNS default-deny (msb, ADR-029 D2 item 3) — **new row, cutover-only; re-homes the ADR-012 D9 DNS sidecar** | strong, with accepted narrow residual (subdomains of an *allowlisted* domain are not otherwise flagged — requires attacker NS control over an allowed domain) | n/a |

**Named residual (rip-cage-t7cu, 2026-07-06):** Claude Code's workspace-trust gate (`checkHasTrustDialogAccepted`) keys off `~/.claude.json`'s `projects[<cwd>].hasTrustDialogAccepted` (checked for the exact cwd and every filesystem ancestor up to `/`) — it is a **per-path**, not per-content, trust flag. Because rip-cage always mounts the workspace at the fixed in-container path `/workspace` regardless of which host project a cage corresponds to, this key structurally collapses across every cage that shares the same `~/.claude.json`: the first cage (any project) for which a user accepts the trust dialog persists `projects["/workspace"].hasTrustDialogAccepted:true`, and every later cage carrying that same file inherits pre-accepted trust regardless of that cage's actual workspace content. This is a property of rip-cage's fixed mount path, not of any single ADR-024 layer decision, and it predates t7cu — it already applied to every possession-posture (`auth.per_tool.claude: real`) cage. t7cu's effect is to extend its reach: non-possession cages previously never carried `~/.claude.json` at all (mount fully suppressed) and so were incidentally immune (no `projects{}` map existed for the dialog to consult); after t7cu they carry the real file (read-only) when the host has one, and so can inherit the same collapsed trust state. **Accepted, not fixed here:** (1) the egress firewall row above already blocks the network-layer exfil (base-URL redirect) this gate exists to prevent, independent of trust-dialog state; (2) under non-possession specifically, the credential riding along is a worthless placeholder token, so a bypassed-trust early redirect captures nothing of value. Closing the root cause (fixed `/workspace` mount path causing project-key collapse) is out of scope for a credential-gate re-scope bead — it is a candidate for its own future bead if the residual is judged to need active closure.

> [ADR-029: RE-VERIFY, not decided — msb guests also mount the workspace at a fixed guest path, so this residual survives *conceptually* (the structural cause — a fixed mount path collapsing a per-path trust key — is not itself Docker-specific). Whether `~/.claude.json`'s trust-dialog key and mount path resolve identically under msb is unconfirmed; this is flagged for re-verification at cutover, not assumed to carry over unchanged.]

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

### D6: MCP posture — CLI-over-bash is the blessed integration path; third-party MCP servers are allowed-but-unsupported (acknowledged residual risk)

**Firmness: FLEXIBLE** *(added 2026-06-09, rip-cage-b4c — retires the MCP-server-trust research bead via its "acknowledged-residual-risk" option.)*

Rip-cage's **blessed** way for an in-cage agent to reach a service or tool is **CLI-over-bash** — invoking the service's own command-line interface over the agent's bash tool, not loading it as an MCP server. This is the integration-side counterpart to [ADR-019 D9](ADR-019-pi-coding-agent-support.md) (bash-only agents reach in-cage daemons via the daemon's CLI) and [ADR-005 D7](ADR-005-ecosystem-tools.md) (a daemon's optional `mcp_fragment` reaches MCP-capable agents *only*); here it is elevated from "how bash-only agents cope" to "the preferred path for *all* agents," because it is agent-agnostic (works for pi, which has no MCP client, and for Claude) and rides the cage's existing bash + egress controls rather than MCP's separate process/declaration surface.

Consequences of the posture:

- **Third-party / user-added MCP servers are NOT a blessed surface.** They remain *allowed but unsupported*. An agent (or user) that loads one accepts the MCP hostile-input vectors already named in D3 (tool-declaration injection, tool-result injection) and — for **host-placed** MCP only — possible out-of-proxy egress. Rip-cage does not certify, sandbox, or gate them.
- **In-cage MCP egress is already contained, so the residual exposure is narrow.** A MCP server running *inside* the cage has its network egress intercepted by the L7 egress firewall (ADR-012) like any other process — the firewall is network-layer and process-agnostic, so MCP-origin traffic is not special. The genuinely-uncovered case is therefore only **host-side MCP placement** (e.g. a `host.docker.internal` shim), which originates outside the cage's network namespace and so escapes the cage firewall. That narrow gap is the acknowledged residual risk.
- **The `meta-skill` skill-server (`skill-server.py`) is the one *sanctioned* in-cage MCP server and is out of scope of this posture.** It is a harness-internal skill-discovery shim with **no network egress** (it reads mounted skill files), transient by design — slated for replacement when the official `ms` tool ships Linux binaries ([ADR-002 D18](ADR-002-rip-cage-containers.md)). It is not a third-party trust surface and is not what "MCP not blessed" refers to.
- **No MCP trust machinery is built at this time** — deliberately no MCP allowlist analogous to `network.allowed_hosts`, no per-server / per-tool trust, no nested MCP sandboxing.

> [ADR-029, LANDED: this decision's own rationale below restates its "L7 egress firewall" / "cage's network-layer firewall" reference as msb VM-boundary capture, post-cutover: msb's `--net-default deny` + `--net-rule` + DNS default-deny is the mechanism that neutralizes in-cage MCP egress, in place of ADR-012's (now-retired) SNI router.]

**Rationale:** the scary part of an untrusted MCP server is covert exfil, and the cage's network-layer firewall already neutralizes that for anything running inside the cage (pre-cutover, [ADR-012](ADR-012-egress-firewall.md)'s SNI router; post-cutover, the msb VM-boundary capture per [ADR-029](ADR-029-msb-migration.md) D2). The remaining hole (host-placed MCP) is not reachable by anything rip-cage ships today. Building a trust system for a surface that is (a) already firewall-covered in its common placement and (b) not used as a blessed path would be over-engineering against the cage's stated threat model (D4 #2 agent-not-adversarial; CLAUDE.md "layers not walls / 80/20 / autonomy is the product"). CLI-over-bash gives the same capability through a path the cage already governs.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Declare CLI-first posture; third-party MCP allowed-but-unsupported (this decision)** | Zero new code; closes the open research item; consistent with the just-landed CLI-over-MCP integration decisions; rides existing egress controls | Names a residual risk (host-placed MCP) it does not close; relies on users not treating MCP as a supported surface |
| Same posture **plus** close the host-side out-of-proxy egress gap now | Turns the named residual into a mitigated one | `reasoned:` rejected for now — no host-placed MCP server runs in any cage today, so the gap is not reachable by anything shipped; deferred behind revisit-trigger 1 rather than built speculatively |
| Full MCP trust model — MCP allowlist + per-server/per-tool trust + nested sandboxing | MCP becomes a first-class governed surface | `reasoned:` over-engineered against the threat model — in-cage MCP egress is already firewall-caught, so most of the machinery defends a surface the network layer already covers; `direct:` CLAUDE.md philosophy ("layers not walls / 80/20-not-100/0") treats this kind of wall-building as the over-strict failure mode |

**What would invalidate this** (revisit triggers):

1. Rip-cage decides to **support host-placed MCP servers** as a blessed surface → then the host-side out-of-proxy egress gap must be closed (it is currently the named residual).
2. A concrete need arises to run an **untrusted third-party MCP server as a first-class / blessed surface** — at which point per-server trust becomes worth its cost.
3. **pi (or another bash-only agent) gains a native MCP client** — MCP becomes a default reach path again, and "CLI-first" stops being the universal answer (the D8 guard-parity tripwire in ADR-019 watches for exactly this pin moving).
4. The threat model shifts to admit an **adversarial** (not merely injection-affected) agent (D4 #2 narrows) — a hostile agent could use an MCP server as a deliberate exfil channel, which CLI-first does not prevent.

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
