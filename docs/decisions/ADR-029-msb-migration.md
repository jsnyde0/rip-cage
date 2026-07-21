# ADR-029: Migrate the Isolation Primitive to microsandbox (msb)

**Status:** Accepted — 2026-07-10, epic `rip-cage-tsf2`; decisions user-locked 2026-07-09/10 after adversarially-verified spikes. **Cutover LANDED** on branch `msb-cutover` (S1–S14: engine deletion, ssh-cluster retirement, msb lifecycle verbs, egress allowlist seed, mount-shape label-lock rebind, dotpi-3bi factory drive path, and this sibling-reconciliation docs sweep, S13). The Docker path is deleted on this branch; the sibling ADRs' migration-status banners are flipped to record the cutover as landed.

**Firmness:** per-decision, see each Dn. Platform-scoping rule in D6.

## Context

rip-cage's containment floor today is a co-located-uid boundary inside one shared kernel (Docker containers on OrbStack). microsandbox (msb, libkrun microVMs) offers a host/VM boundary — and, decisively, ships the entire egress + credential stack as *host-side runtime primitives*: `--net-default deny` + `--net-rule` (per-domain/port allow rules enforced at the VM NIC), TLS interception with guest-auto-trusted CA, `--secret VAR@HOST` placeholder substitution with a block-and-log violation guard, and APFS CoW snapshots (~30-60ms create) enabling sub-second cage recreation.

This means the migration is not a container-runtime swap: everything ADR-012 built in-cage (SNI router, iptables REDIRECT chains, DNS resolver sidecar, startup self-test) and everything ADR-026 D5 built to launch composed mediators becomes a *declaration* against runtime primitives instead of an *engine* rip-cage maintains. The build-vs-compose drift-rate logic of ADR-026 D2, which already outsourced mediation, now applies to containment itself.

Evidence base (all adversarially verified, macOS/HVF, msb v0.6.4): platform evaluation (`docs/2026-07-07-microvm-spike-findings.md`, spike `rip-cage-gljd`); HTTPS git-push e2e incl. real push + `gh api` (`rip-cage-7fqe`); LAN-IP guest→host delivery with two-port discriminator (`rip-cage-akg5`); snapshot-amend repair mechanics (`rip-cage-0n25`); real Claude session resume across recreate (`rip-cage-1ujn`); real Claude CLI fully non-possessed under `--secret` (`rip-cage-cmqb`); beads embedded-Dolt over virtiofs locking (`rip-cage-9iab`). All docs at `docs/2026-07-09-msb-spike-*.md`. Vision and the earn-its-keep guardrail: `docs/rip-cage-on-msb-direction.md`.

A known msb netstack property governs all verification here: disallowed TCP connects are **fake-accepted** (connect() succeeds, zero bytes flow; :443 grabbed by the TLS interceptor then dropped; :53 answered by msb's own DNS forwarder for any IP). Every "works/reaches" claim in the evidence base rests on real bidirectional application data, never connect() success (bd memory `msb-netstack-fake-accepts-tcp-connect-not-egress`).

## Decisions

### D1: Adopt msb as the isolation primitive — hard cutover, no dual backend

**Firmness: FIRM**

rc targets msb exclusively after the cutover release. The Docker path is deleted, not deprecated-in-place; rollback is "pin the pre-cutover release."

**Rationale:** the boundary upgrade is qualitative (host/VM vs co-located-uid in a shared kernel — credential non-possession moves from a uid-permission argument to a hypervisor argument). A dual-backend period would mean maintaining two *safety* surfaces, where divergence is not a bug class but a false-confidence class: a guard proven on one backend reads as proven on both. The install base is personal-scale; a hard cutover is honest and cheap. This reverses ADR-002 D1 (OrbStack as runtime); ADR-002 D1's own invalidation clause ("Apple ships native container support") is adjacent rather than fired — msb rides Apple's Hypervisor framework rather than a third-party container runtime, but is not Apple-native container support.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Dual-backend transition (Docker + msb behind a flag) | `reasoned:` two containment floors to keep honest; every safety probe forks; the divergence failure mode is silent false-green on the unproven backend. |
| Stay on Docker, harden in place | `direct:` the co-located-uid boundary is the weakness (2026-07-07 findings); no amount of in-cage engine work changes the kernel-sharing fact. |

**What would invalidate this:** msb project abandonment, or an unfixable defect in a core path (boot, virtiofs mounts, net rules, secrets) with no upstream horizon — rollback is the pinned pre-cutover release while re-evaluating.

### D2: Delete the in-cage security engine — containment is the runtime's job

**Firmness: FIRM**

`rip_cage_router.py` / `rip_cage_egress.py` / `rip_cage_dns.py`, `init-firewall.sh`, the iptables REDIRECT machinery and the legacy-iptables pin, `init-mediator.sh` and the MEDIATOR launch machinery: **deleted, not ported**. Egress destination control, TLS interception, and secret injection are consumed as msb host-side primitives that rc *declares* (config → `--net-rule` / `--secret` flags at cage create/amend).

Three properties of the deleted engine are **re-homed, not dropped**:

1. **Deny visibility** (was ADR-012 D7's JSONL denial log — load-bearing for agent self-correction): re-homed to msb trace-level DNS-denial log lines (`domain=` field), which rc tails to produce fix-hints for the D4 repair loop. Cages boot with trace logging for this reason.
2. **Effect-based enforcement verification** (was ADR-012 D11's startup self-test — the fail-open lesson of bd memory `rip-cage-firewall-rule-presence-not-enforcement`): the principle transfers as (a) spike-tier evidence discipline (real-data-only, per the fake-accept property above) and (b) an msb-side effect probe in the migrated test suite — assert a denied host actually yields no data, not that a rule is listed. The Linux/KVM gate (D6) is this principle applied at platform grain.
3. **DNS-exfil coverage** (was ADR-012 D9's heuristic sidecar; ADR-024 names DNS exfil in scope — Context + the D2 exfiltration axis): re-homed to msb's default-deny DNS — resolution of non-allowlisted domains is *denied and logged* (proven operationally by the `rip-cage-1ujn` allowlist-discovery loop), which is categorically stronger than the old allow-but-flag heuristic for the dominant channel (queries to attacker-controlled domains). **Accepted narrow residual:** exfil shaped as subdomains of an *allowlisted* domain is no longer heuristically flagged; it requires attacker NS control over an allowed domain, which the curated default allowlist (github.com, api.anthropic.com tier) makes impractical. ADR-024 D2's layer table records this residual.

The **welded containment floor** enumeration changes with this decision. New floor: the microVM boundary itself, msb default-deny egress + rules, msb DNS default-deny, `--secret` non-possession (D5), **plus the surviving host-mount floor items msb does not subsume** — the secret-path mount denylist (ADR-023) and the `.git/hooks` read-only weld (ADR-002 D11), both of which guard the host-filesystem side of the boundary and are orthogonal to the VM primitive — and the surviving in-guest floor items (root-owned guard artifacts, scoped sudo, ro mounts). This enumeration is duplicated near-verbatim in ADR-005 D9, ADR-025 D2, and ADR-026 D2 — **all three must carry the identical new list** (lockstep edit; a fork here forks the floor definition).

**Rationale:** ADR-026 D2 sorted safety layers by maintenance drift-rate and kept only low-drift container-native layers in-house. The runtime now provides those layers as commodity primitives; maintaining a parallel in-cage engine fails the same test that outsourced mediation. ADR-026 D3's invalidation predicate ("if a mediator ships a container-runtime that itself owns the netns and force-captures... this stops being rip-cage's to claim") fired in substance — msb is a runtime rather than a mediator and owns capture at the VM NIC rather than a netns, but the predicate's consequence (the force-through chokepoint stops being rip-cage's irreducible contribution) lands exactly as written. rip-cage's irreducible contribution moves up a level: the composition/policy surface (what rc declares) and the workbench layer above the runtime (per the earn-its-keep guardrail).

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Port the engine onto msb (run the SNI router/DNS sidecar in-guest) | `reasoned:` duplicates runtime primitives at high drift cost; the in-guest position is also the *weaker* altitude (agent-reachable) vs the hypervisor. |
| Keep the DNS exfil-shape heuristic as an in-guest add-on | `reasoned:` the dominant exfil channel (attacker-controlled domains) is closed harder by default-deny DNS; the surviving residual (subdomains of allowed domains) does not justify keeping a Python sidecar + its iptables plumbing alive. Revisit under D2's invalidation below. |
| Rebuild allow-traffic observation (observe-mode) on msb | `direct:` rejected in D4 — it would re-add the engine this decision deletes. |

**What would invalidate this:** a containment class ADR-024 requires that msb cannot express host-side (e.g. the allowed-domain-subdomain exfil residual proving practically exploited, or a method/path-grade control becoming containment-necessary) — the answer would be a composed mediator first (ADR-026 D1 still holds), an in-guest layer only if the mediator path fails the drift test.

### D3: Canonical git path is HTTPS + `--secret` — the ssh cluster retires

**Firmness: FIRM**

Git in cages authenticates as `https://x-access-token:$TOKEN@...` with the token injected by msb `--secret` (guest holds a placeholder, even in `.git/config`). Proven e2e: clone, commit, push, `gh api`, `gh pr create` (`rip-cage-7fqe`). The per-cage token **is** the identity scoping.

The entire ssh cluster retires with the engine: ADR-017 (agent forwarding default), ADR-018 (socket discovery), ADR-020 (identity routing), ADR-022 (host+key allowlist, `ssh-agent-filter`, filtered `known_hosts`, `block-ssh-bypass.sh` hook, `examples/ssh-bypass/`). Two of these retire **by their own written predicates**: ADR-017 D4 and ADR-018 D1 both named "a future shift to bot-identity tokens... makes the agent-reachability question moot" — that shift is this decision, arrived at because msb made token non-possession free (dissolving the setup-burden grounds on which ADR-017 originally rejected the token alternative). The LAN-IP ssh-agent bridge (`rip-cage-akg5`) is documented as a composed example recipe only, never blessed (ADR-005 D12) — the spike itself showed it forwards the *whole* host agent (it authenticated as the operator's work account), i.e. no key scoping without rebuilding the filter; strictly worse than per-cage tokens as a default.

Two hard **generator constraints** from spike evidence, binding on the config→flags generator: (1) `--secret` accepts only the `ENV@HOST` form (value resolved from a same-name host env var at sandbox start; inline `ENV=VALUE@HOST` is rejected at create). (2) Binding one credential to N hosts requires N *distinct* synthesized env-var names — a same-name repeat or comma-list silently blocks **both** hosts with zero boot error (also an upstream msb bug-report candidate).

Successor design pointer: the per-project "which identity does this cage push as" problem survives the transport change. ADR-020 D3's four-layer selection shape (flag → label → rules file → loud unset, no built-in default) and D6's match/mismatch/unset state machine are the reusable designs for **token selection**, with `gh api user` (the parallel diagnostic ADR-020 D6 already named) as the natural identity probe over HTTPS.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| ssh via LAN-IP agent bridge as the default git path | `direct:` whole-agent forwarding with no per-key scoping (spike-observed work-account identity leak); would require rebuilding ssh-agent-filter atop an exposure surface D7's probe set is still measuring. |
| Keep ssh allowlist machinery for non-git ssh use | `reasoned:` no current consumer; the machinery's cost was justified by git; a future ssh need composes a recipe against msb net rules. |

**What would invalidate this:** a required git host/workflow that cannot mint scoped HTTP tokens; or msb `--secret` regressing on the proven substitution path.

### D4: Observe-mode retired — curated default allowlist + deny→fix→reload  *(revised 2026-07-21 — port-tight default, `rip-cage-mzu6`)*

**Firmness: FIRM**

msb logs nothing for allowed flows; rebuilding allow-observation means rebuilding the engine D2 deletes. Replacement, three parts:

1. **Curated default allowlist** shipped in config, so fresh cages are not denial whack-a-mole. Seed from `rip-cage-1ujn`: `api.anthropic.com:tcp:443` is the only host a basic `claude -p` turn *requires*; `mcp-proxy.anthropic.com` and the datadog intake are attempted-but-nonblocking (include for denial-log-noise-free defaults). Contents finalized at decompose.

   **Port-tight default (revised 2026-07-21, `rip-cage-mzu6`; human sign-off jsnyde0 on the bead):** the config→msb-flags generator scopes each default floor host to **`allow@<host>:tcp:443`**, not host-wide all-ports `allow@<host>` (`cli/lib/msb_flags.sh`, unit test T17). *Counter to the prior all-ports default:* host-wide port openness on an allowed host was the generator's initial emission, never a deliberated choice; :443-scoping is strictly tighter, and spike `rip-cage-uuh9` (`tests/spike-uuh9-port443.sh`, macOS/HVF, msb 0.6.4, 17/17 probes, verified 2×) proved it costs the *entire* live default set **nothing** — a real `claude -p` turn completed with zero denials; `github.com`/`api.github.com` returned real bodies; `doltremoteapi.dolthub.com` completed its TLS+HTTP round-trip — while closing a real wrong-port hole (`example.com:80` provably blocked under :443-scoping, triangulated against an all-ports baseline and a same-cage :443 control). The tighter default dominates the looser one on evidence, so the FIRM default flips. Design constraints:

   - **Port stays OVERRIDABLE (C2).** Only floor hosts *lacking* an explicit port are scoped to :443; a host given **with** an explicit port in `network.allowed_hosts` (a self-hosted service, or an apt/registry mirror on a nonstandard port) keeps that port verbatim — the generator scopes only colon-free host strings. Unconditional hardcoded :443 would break legitimate custom traffic (`reasoned:` + ADR-005 D12, "block the accident, don't gate legitimate work").
   - **macOS/HVF-proven ONLY.** The 17/17 evidence is HVF; the Linux/KVM path is **unverified** and gated separately by D6 — Linux port-tight verification is a **pre-release gate item**, not a proven property. Do not read this decision as Linux-proven.
   - **tcp:443 drops udp:443/QUIC — acceptable.** The real claude turn proved TCP suffices (QUIC→TCP fallback). A *future* HTTP/3-only default host would need an explicit `udp:443` entry; nothing in today's default set does.
   - **C1 observability caveat.** A wrong-port block on an *allowed* domain emits **no** msb log line on any source (trace level, msb 0.6.4) — it drops at the NIC after DNS resolves fine, so the deny→fix→reload fix-hint miner (`_msb_denied_domains_from_trace_log`, DNS-domain-keyed) is **blind** to it. It stays self-diagnosable at the point of failure: the client gets an immediate ~12ms connection-refused (curl rc=7), **not** a fake-accept hang. Closing the *proactive* fix-hint gap is descoped to follow-up bead `rip-cage-ffmc` (load-bearing only now that this lands).

   **What would invalidate the port-tight default:** a legitimate member of the *default* set that requires a non-443 port (it would need its own explicit `:port` entry, or the default reverts), or the Linux/KVM gate (D6) revealing HVF-only :443 behavior.
2. **deny→fix→reload repair loop:** rc tails trace-level DNS-denial lines for fix-hints; apply = **snapshot-amend** (`msb run --snapshot ... --net-rule <amended>`, 0.783s, overlay preserved — default for cages with overlay state) or **cold-recreate** (0.303s, mount-only cages); the agent session resumes from host-mounted state. Proven honest wall-clock including agent relaunch: 6.085s, 94% of it Claude cold-start, msb lifecycle 0.363s (`rip-cage-1ujn`).

   **LANDED disposition (`rip-cage-rj68`, S6): `rc reload` implements the mount-only branch — COLD-RECREATE, not snapshot-amend — unconditionally.** `net-rule`/`net-default` have no live-mutation path on a running msb sandbox (`msb modify` carries no network parameter; confirmed live, `docs/2026-07-09-msb-spike-egress-observability.md` Q1), so applying an amended allowlist is inherently a recreate. rip-cage cages are mount-projected **by construction** — workspace, `~/.claude/{projects,sessions}`, pi's `auth.json` are host bind mounts; `rc-state-*`/`rc-history-*`/`rc-mise-cache` are **named volumes**, which reattach by name independent of the sandbox's own OCI overlay — so the mount-only branch is not a special case for rip-cage, it is the *only* case. Concretely, `rc reload` runs **graceful stop → remove → the same create pipeline `cmd_up` uses, against the now-current `.rip-cage.yaml`** (`cli/reload.sh`):
   - **SURVIVES the recreate:** everything host-mounted or volume-backed — the workspace, `~/.claude/{projects,sessions}` (so the Claude session **resumes**, it is not lost), pi's `auth.json`, and the named volumes (`rc-state-*`, `rc-history-*`, `rc-mise-cache`).
   - **LOSES:** only the guest's own ephemeral rootfs overlay — state an in-cage process wrote that was never baked into the image or captured by a mount (e.g. an ad-hoc `apt-get install` at runtime). This is a narrow, documented tradeoff, not a session-continuity loss, and cold-recreate is ~2.6x cheaper than snapshot-amend (0.303s vs 0.783s).
   - Snapshot-amend remains a valid *mechanic* this ADR names for a future cage shape that carries meaningful guest-overlay state; it is not what rip-cage's own `rc reload` invokes today.
3. **Opt-in observation** stays available by composing a mediator recipe (operators who want traffic visibility).

Lifecycle corollary (FIRM): any cage-stop path that must preserve state uses **graceful stop only** — `--force` hard-kill silently discards guest writes that already reported success (`rip-cage-9iab` Q4); graceful stop provably persists (`rip-cage-1ujn`).

Resume-path corollary: every resume is a fresh kernel boot (processes die); `rc` re-runs init and re-registers cockpit/multiplexer state on each resume. The mounted Claude home must have its `projects`/`sessions` dirs pre-created by rc — absent dirs silently break session resume with no error (`rip-cage-1ujn` footgun).

**Rationale:** observe-mode existed because deny-first adoption produced the "just turn it off" exit (ADR-012 D1). A sub-6-second repair loop answers that pressure directly — the agent hits a wall, surfaces the fix, the operator (or a policy) applies it, work continues — without maintaining an observation engine. This is the "annoying is a design signal" philosophy applied with better mechanics rather than looser policy.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Rebuild observe-mode via msb trace logs | `reasoned:` msb traces denials, not allows; allow-observation would need TLS-intercept-side logging = rebuilding the engine. |
| Deny-only with no default allowlist | `direct:` fresh-cage whack-a-mole; the 1ujn discovery loop exists precisely to seed defaults once, centrally. |

**What would invalidate this:** the repair loop's real-world wall-clock or friction regressing to where operators disable egress control entirely (the D4-rationale pressure returning) — measured by the same "just turn it off" signal.

### D5: Credential non-possession — msb-native `--secret` is the primary mechanism

**Firmness: FIRM**

The real Claude Code CLI runs fully non-possessed under msb `--secret` (`rip-cage-cmqb`): guest env/disk/proc hold only the placeholder; msb injects the real token on the wire toward the bound host only; the violation guard blocks-and-logs the placeholder toward any unbound host; real completions (computed arithmetic, generative content) defeat the fake-accept confound. One token→host binding sufficed for Claude.

Shipped completion of the flow (`rip-cage-9dlw` / commit `95a2f81`): `auth.credentials` entries now carry two fields that automate what `cmqb` proved by hand — `target_env` (guest env-var name(s) that receive the binding's `$MSB_<synth>` placeholder, so a tool reading a fixed var like `CLAUDE_CODE_OAUTH_TOKEN` gets the swappable value; single-host per credential, since a fixed var holds one placeholder) and `source_file` (a host-side token file feeding the `--secret` machinery, so a plain `rc up` needs no pre-exported host env var; the real value never reaches the guest). Extension of this decision, not a contradiction; firmness unchanged.

This **evolves ADR-026 D4/D5**: ADR-026 D4's invalidation predicate ("a single-mechanism, genuinely low-drift injection covering the dominant secret... that does NOT pull in per-service maintenance") fired verbatim — `--secret` is that mechanism. Non-possession moves from an opt-in composition property (iron-proxy mediator recipe, `rip-cage-seqc`) to a **default platform property**. The mediator-composition path remains valid for cases `--secret` cannot express; the seqc/ahnp validation record is preserved as design precedent, retired as architecture.

Boundaries stated honestly: per-tool posture (ADR-026 D7) survives and matters more — Claude rides `--secret` with a long-lived setup-token; pi's openai-codex provider still has no static token (bd memory `openai-codex-non-possession-needs-mixed-posture-or-refresh-mediator`), so pi stays possession-mode (real auth.json mounted) — mixed posture remains the caged-pi shape under a new mechanism. Subscription-OAuth full non-possession is an EXPLORATORY direction, not a decision here: a host-side refresher rotating the injected token via `msb modify --secret` (proven live-rotation primitive), the ADR-010 auth-refresh seam's msb binding — capture only, build on pull.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Keep the composed-mediator (iron-proxy) path as the primary non-possession mechanism | `reasoned:` ADR-026 D4's own predicate — the runtime primitive is lower-drift, needs no per-cage mediator lifecycle, and its violation guard is enforced below the guest. Mediator stays as the composition escape hatch. |
| Possession-mode default (mount real credentials), non-possession opt-in | `direct:` reverses the proven default for the dominant secret with no gain; today's possession behavior remains available per-tool (ADR-026 D7). |

**What would invalidate this:** msb `--secret` losing placeholder substitution or the violation guard; or a tool class whose client-side token-shape validation rejects placeholders (Claude proven; probe per-tool before extending FIRM claims — the pi/oat placeholder-shape concern from `rip-cage-cmqb` Q1 was not hit for Claude but is real for shape-checking clients).

### D6: Platform-scoped firmness — and the Linux/KVM hard gate

**Firmness: FIRM**

The *decisions* in this ADR (D1–D5 FIRM; D7 FLEXIBLE per its own header) hold platform-independently — where a decision rests on a platform-measured mechanic, it is **conservative under platform uncertainty**: D7's single-writer discipline is safe whether or not KVM's virtiofs propagates locks (if it does, the discipline is merely unnecessary there and can relax); D4's repair-loop *choice* stands independent of the exact timings. The *mechanics* — netstack fake-accept behavior, TLS-intercept-drop of denied :443, APFS CoW snapshot cost (D4's 0.783s/0.303s figures), LAN-IP-only guest→host delivery, virtiofs lock non-propagation (D7's basis) — are FIRM **scoped to macOS/HVF (msb v0.6.4)**, with a named invalidation: **Linux/KVM reconfirmation (`rip-cage-4fxg`) is a hard gate before any VPS/Linux deployment.** The gate blocks the future VPS thread, not this epic; its results may *relax* D7 per-platform and will re-measure D4's timings. ADR-002 D7's "same image local and VPS" property inherits this gate.

**Rationale:** every mechanical fact in the evidence base was measured on one platform; the honest firmness encodes that. This is ADR-012 D11's effect-verification principle at platform grain: never carry a macOS-proven enforcement claim to Linux by prose.

**What would invalidate this:** running `rip-cage-4fxg` — its results either discharge the scope qualifier or fork the mechanics per-platform.

### D7: Beads interim posture — single-writer discipline over the virtiofs mount

**Firmness: FLEXIBLE**

msb virtiofs does **not** propagate `flock` across the guest/host boundary (both directions, marker-confirmed overlap, version-independent — `rip-cage-9iab` Q2), so concurrent host+guest writes to one embedded-Dolt store are unsound. Interim posture: **while a cage is up rw on a repo, bd writes happen from exactly one side** — in practice the in-cage agent keeps its own bookkeeping and the host orchestrator batches writes for cage-idle windows (or relays through the worker). Convention-enforced; the race remains physically possible if violated — a named residual, not a solved problem.

Companions: the image's baked bd **must be pinned to the host formula version** (the 1.0.5-vs-1.1.0 skew makes a host-touched store reject guest writes — a separate, unconditional migration child; probe `rip-cage-606c` A2 proved the skew is LIVE on the current Docker stack today, so the pin is also a pre-migration bug fix). Regression framing resolved by probe `rip-cage-606c` A1: today's Docker/OrbStack bind-mount path does **not** propagate flock either (both directions, marker-confirmed) — msb regresses nothing on this axis; the race predates the migration and is *newly known*, not newly created (`docs/2026-07-10-current-stack-parity-and-lan-exposure.md`). The durable topology — host-service single-writer process vs substrate change — is deliberately **not** decided here: the host-service seam design is captured (EXPLORATORY) in bead `rip-cage-o7tx` + `docs/rip-cage-on-msb-direction.md` §6, decide-or-dismiss at the task-substrate brainstorm (fed by `docs/2026-07-09-task-substrate-spike.md`) or on second-consumer pull. ADR-007's embedded-mode and host-server decisions reconcile against this posture (edits in place there).

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Build the host-service beads topology now | `direct:` user call 2026-07-10 — a beads-only service is poor ROI while beads itself is under re-evaluation; the seam is captured, not committed. |
| Cage-read-only beads (host does all writes) | `reasoned:` breaks the standard in-cage agent workflow (bd claim/close is baked into agent instructions everywhere) for a race that single-writer discipline already avoids in the common case. |
| Ignore (rely on low collision odds) | `direct:` the spike's own framing — a race that didn't fire in 75 trials is still a race; and Q3 did observe one silently lost write. |

**What would invalidate this:** evidence that even single-side writes corrupt over msb virtiofs (would force guest-local store + sync, or the host-service); the substrate brainstorm replacing beads; or the host-service seam being built (supersedes the discipline).

## Sibling reconciliation (the edits this ADR anchors)

Deliberately decompose-scoped, not decided here: the safety test suite's migration (which probes port to msb-side effect checks, which retire with their mechanisms) — it lands as implementation children with per-child harness targets, governed by D2's re-homed effect-verification principle.

Evolve-in-place edits, each citing the Dn here: **ADR-002** (D1 reversed→D1 here; D2a pin retired; D5 containment enumeration → D2 here; D10 → D7 here; D14 in-guest detection re-mechanized; prose sweep for docker/OrbStack literals), **ADR-005** (D9 floor enumeration lockstep with D2; MEDIATOR archetype refs retired; D12 untouched and *governing* — msb primitives are floor, never blessed-optional), **ADR-007** (D1/D5/D8 → D7 here), **ADR-010** (D1 refresh target under non-possession → D5; D4 inode rule reversed-by-own-predicate — virtiofs is the backend change it named; re-verify), **ADR-012** (all decisions retired/re-homed per D2/D4 — banner + per-decision disposition), **ADR-017/018/020/022** (retired in place with banners; own-predicate citations for 017 D4/018 D1; ADR-020 D3/D6 flagged as successor designs; ADR-022 D6 verb re-homed to the D4 repair loop; CLAUDE.md ssh-trust section rewritten), **ADR-024** (D2 layer table re-mapped; DNS-exfil residual per D2; threat model itself unaffected), **ADR-025** (D2 floor list lockstep; ssh-bypass sibling mentions struck), **ADR-026** (D1 delegate re-named; D2 bucket exemplars updated, spine intact; D3/D4 reversed-by-own-predicate; D5 retired; D6 tiering collapsed — standalone default now carries non-possession + deny egress; D7 re-mechanized), **ADR-028** (D1 re-bound to msb metadata; the snapshot-amend-vs-immutability question resolved by migration child rip-cage-qzsx (S8), which owns writing the verdict back into ADR-028; instance tally shrinks), **ADR-014** (final disposition of its ssh-posture decisions checked at edit time), **INDEX.md** (rows + the ssh/identity topic cluster marked retired).

## canonical_refs

- ADR-002 (containers — runtime reversed by D1; D11 `.git/hooks` weld survives in the D2 floor), ADR-005 D12 (composable seam — governs D2/D3/D5's floor-vs-recipe sorting), ADR-007 (beads resilience — D7), ADR-010 (auth refresh — D5 exploratory seam), ADR-012 (egress engine — deleted by D2, properties re-homed), ADR-017/018/020/022 (ssh cluster — retired by D3), ADR-023 (secret-path mount denylist — survives in the D2 floor; mechanics re-verify on msb mount syntax), ADR-024 (threat model — layer re-map + D2 residual), ADR-025 (DCG floor list — lockstep), ADR-026 (containment/mediation identity — D2/D3/D4/D5/D6/D7 evolved or fired), ADR-028 (label-lock — re-binding).
- `docs/rip-cage-on-msb-direction.md` (vision, earn-its-keep, option map incl. host-service seam capture).
- Spike evidence: `docs/2026-07-07-microvm-spike-findings.md`, `docs/2026-07-09-msb-spike-{https-git-push,lan-ip-host-service,snapshot-amend,session-resume,claude-nonpossession,beads-virtiofs}.md`, `docs/2026-07-09-task-substrate-spike.md`.
- Beads: `rip-cage-tsf2` (epic; alignment rounds 1–3 in notes), `rip-cage-gljd`, `rip-cage-7fqe`, `rip-cage-akg5`, `rip-cage-0n25`, `rip-cage-1ujn`, `rip-cage-cmqb`, `rip-cage-9iab`, `rip-cage-1mkq`, `rip-cage-606c` (parity/exposure probe, open), `rip-cage-o7tx` (host-service seam capture), `rip-cage-4fxg` (KVM gate, parked), `rip-cage-uuh9` (port-tight spike, D4), `rip-cage-mzu6` (port-tight default flip, D4), `rip-cage-ffmc` (wrong-port fix-hint gap, D4 C1 follow-up).
- bd memories: `rip-cage-on-msb-direction`, `msb-netstack-fake-accepts-tcp-connect-not-egress`, `rip-cage-guard-engine-vs-policy-split` (drift-rate spine), `oauth-refresh-blocks-static-header-swap-injection`, `openai-codex-non-possession-needs-mixed-posture-or-refresh-mediator`, `credential-non-possession-shipped-and-proven` (pre-msb precedent), `rip-cage-firewall-rule-presence-not-enforcement` (effect-verification warrant for D2/D6).
