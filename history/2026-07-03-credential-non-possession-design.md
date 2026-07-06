# Credential non-possession via iron-proxy — design (rip-cage-seqc, part A)

**Date:** 2026-07-03. **Status:** adversarially reviewed (REVISE verdict, 8 findings, all folded in below) — pending user ratification of §9.1 (the one floor change).
**Supersedes:** the two-spike (B/D) sequencing in `/tmp/brainstorm/spike-{B,D}-design.md` and the reshaped plan in `/tmp/rip-cage-handoff/HANDOFF-credential-non-possession.md` §6. Mechanism detail in those files remains valid and is cited, not repeated.
**Authored by:** Fable 5 (main brain), incorporating the Opus handoff's five completed investigations and both adversarial reviews.

---

## 1. Problem

The personal cage bind-mounts real credentials read-write (`~/.claude/.credentials.json`, `~/.pi/agent/auth.json`), so the caged agent fully *possesses* them — a prompt-injected agent can exfiltrate them (ADR-024 D2 credential-exfil axis). Goal: the agent holds only a **placeholder**; the iron-proxy mediator injects the real credential on egress to `api.anthropic.com`. Hard constraints: keep **Max/Pro subscription billing** (Console API keys ~10x cost) and keep **autonomy** (no per-session human re-auth).

The crux inherited from the closed feasibility spike (rip-cage-i68c): subscription auth is OAuth-with-refresh. **M1** — iron-proxy's shipped env-source secret is read-once, but the access token expires in ~hours → dead injection. **M2** — near expiry the agent self-refreshes by POSTing the refresh token (JSON body) to a *different host* (`platform.claude.com/v1/oauth/token`) → a single-host header swap misses it.

## 2. FIRM constraints (verified against decision text — do not silently contradict)

- **ADR-026 D4** — no mediation/credential-injection in the rip-cage floor; non-possession is a composition property. Mediator + any refresher live in `examples/` + host helpers.
- **ADR-026 D5** — mediator is co-located in-container under a dedicated uid (NOT a sidecar container); push-side floor uncrossable. Tripwire 4: live-Anthropic-OAuth injection has never been proven (all E4 proofs used httpbin).
- **ADR-005 D12** — zero-rc-diff predicate: a green injection with a non-empty `git diff -- rc` is a RAISE, not a pass.
- **ADR-012 D4** — rip-cage itself never terminates TLS; only the composed mediator MITMs, with its CA trusted in-cage by both CC (`NODE_EXTRA_CA_CERTS`) and pi (rustls store).
- **ADR-024 D2** — prompt-injection in scope; motivated adversarial agent out of scope.

**Secret-handling protocol (binding on all execution):** real credentials never enter a subagent context and are never read into any session transcript. Token-touching turns run in the **main context** via the `secrets-via-stdin` skill or scripts that load the secret internally and print only metadata (status codes, hashes, expiry timestamps). Probes prefer garbage tokens or hash-only outputs. This is why the delegation map (§8) exists.

## 3. Established facts (inherited — do not re-derive; citations in the handoff §5)

- Both CC and pi start cleanly on a **future-dated placeholder**; they refresh only on a *local* `now >= expiresAt` check. A far-future placeholder never triggers in-cage refresh. (i68c)
- iron-proxy `secrets` transform: file-source + `ttl` = genuine live rotation; env-source = read-once; request-side only (cannot own an OAuth round-trip).
- iron-proxy `oauth_token` transform: owns the refresh loop, stubs the token endpoint (sandboxed client completes its token dance holding only a stub), credentials from secret sources, PKCE/public-client OK, **form-encoded** exchange (x/oauth2), **rotated refresh tokens held in memory only — no write-back, restart reseeds from original config**. This persistence gap is acknowledged-unsolved in the OSS tool; only commercial managed mode owns external token lifecycle.
- `--mediator-env` is the **proven leak-free delivery**: injected only into the mediator's `docker exec -u root`, lands in the mediator-uid process env, never in `/proc/1/environ`.
- **Non-possession must be verified against the surface the mechanism actually uses**: agent-uid read of `/proc/<mediator-pid>/environ` → EACCES (env delivery), or file-permission check (file delivery). `/proc/1/environ` is vacuously clean in both — a false-pass trap (convergent finding of both adversarial reviews).
- iron-proxy transform config is parsed by **iron-proxy's own strict parser** inside the `examples/` recipe — these are proxy-config-in-examples edits, cleanly zero-rc-diff (NOT rip-cage `med_known_fields`).
- Dual allowlist: target hosts must be in both rip-cage `network.allowed_hosts` (floor) AND iron-proxy's `transforms.allowlist.domains` (default-deny) — a miss masquerades as a CA failure.
- Single-file bind-mount + host atomic-rename = intermittent ENOENT (inode handle breaks). Directory mounts or exec-delivery avoid it.
- **NEW (this session):** `claude setup-token` exists in the installed CLI — "Set up a long-lived authentication token (requires Claude subscription)". Never considered by prior spikes. Potentially dissolves M1/M2 entirely.
- **NEW (this session):** `platform.claude.com/v1/oauth/token` rate-limits anonymous probes (429 on first garbage-token POST) — endpoint probes must be spaced and expect throttling.

## 4. Design: the path ladder

Rungs tried in order; each is strictly simpler than the next. A rung is only entered when the one above is factually ruled out. This replaces the B/D spike fork.

### Rung 1 — static setup-token injection (target design)

- Human mints a long-lived subscription token once: `claude setup-token` (interactive, host-side).
- In-cage: CC gets a **placeholder** `.credentials.json` (oat-shaped token, far-future `expiresAt` → never self-refreshes); pi gets a placeholder `auth.json` likewise. No real credential is mounted.
- iron-proxy `secrets` transform, **env source** (read-once is *fine* — the token is long-lived), delivered via `--mediator-env`, swaps the `Authorization` value on `api.anthropic.com`. All other headers (anthropic-beta etc.) are the in-cage tool's own and pass through untouched — **no paired header entry needed**, simpler than Spike D's config.
- Operational burden, honestly stated (review F2): (a) manual re-mint on the token's actual lifetime (believed ~1 year — S0 measures it); (b) **the secret must be re-supplied on every `rc up`, including resume** — `--mediator-env` is never persisted, and omitting it means the mediator relaunches with injection as a silent no-op → 401s. That (b) is an **autonomy regression vs today** (today's mounted creds re-establish automatically on any `rc up`). Mitigations, in preference order: a floor-change option `network.egress.mediator_env_file: <host path>` in `.rip-cage.yaml` (rc persists a *pointer*, never the secret; secret stays in a chmod-600 host file — folds into the same floor-change bead as §6.2), or a wrapper alias + an `rc doctor` check that flags a mediator-composed cage whose mediator env is empty.
- Zero OAuth machinery, zero refresh loops, zero restart-fragility. M1 dissolves (long-lived token), M2 dissolves (in-cage tools never refresh).
- Accepted forward-risk (review F8): on an S0 full pass, rung 2's make-or-break facts (F1 form-encoding, F2 rotation) are never resolved — if Anthropic later restricts setup-token, the fallback is *un-validated*, not proven. Deliberate staging choice: don't spend live-credential probes validating a fallback we may never need; the floor change and injection seam are rung-agnostic and reusable.

### Rung 2 — iron-proxy `oauth_token` transform (the handoff's Spike D)

Entered only if S0 fails (token short-lived, or rejected for CC- or pi-shaped traffic). iron-proxy owns the refresh loop; agent completes its token dance against the stubbed endpoint. Config per `/tmp/brainstorm/spike-D-design.md` + handoff §5.1: refresh-token + client_id via `--mediator-env` secret sources, `token_endpoint = platform.claude.com/v1/oauth/token`, paired `secrets` entry for the beta header (observed from live traffic, not pinned), dual allowlist. Gated on two facts: **F1** (endpoint accepts form-encoded refresh grant — x/oauth2 can't send JSON) and **F2** (rotation/invalidation behavior, which determines restart-fragility).

### Rung 3 — upstream write-back contribution

Entered only if rung 2 is live AND F2 says Anthropic rotates+invalidates. The clean fix is **contributing optional rotated-refresh-token persistence (write-back to a file source) to iron-proxy upstream** — the gap is acknowledged-unsolved in the OSS tool and this is its designed home; a rip-cage-side shim would fight the tool. Interim: accept re-auth-per-mediator-restart, documented as a named condition on the parent decision.

### Parked (with reasons, for the record)

- **Spike B** (host-side refresher + file/ttl): duplicates iron-proxy's own refresh loop outside it. Parking note: its fatal review finding (mounted token file agent-readable in co-location) has an unexplored workaround — deliver via `docker exec -u root` into a mediator-uid-owned path (no bind mount, dodges the ENOENT gotcha too). Revive only if rungs 1–3 all die.
- **Sidecar topology**: changes the isolation mechanism (container boundary vs uid boundary) but does nothing for the actual crux — a separate container restarting loses in-memory rotated state identically. Would revisit FIRM ADR-026 D5 for zero gain on the problem. Do not take.

## 5. Spikes (validation-first; ordered by cost and by secret exposure)

**S0 — setup-token viability (rung-1 gate).** Host-only, no cage.
1. **Human-only mint (review F5, hard constraint):** the user runs `claude setup-token` in their own terminal and stores the token in a chmod-600 host file themselves. The agent NEVER runs `setup-token` via a tool call — the command prints the token to stdout, which would land it in the transcript.
2. Inspect the minted token's shape and claimed lifetime — via a script that prints only metadata (prefix shape, length, expiry if present); the token value itself never enters the transcript.
3. Probe acceptance, via `secrets-via-stdin`, status codes only:
   - (a) one CC-shaped request (`Authorization: Bearer <token>` + CC's oauth beta header) against `api.anthropic.com`;
   - (b) one pi-shaped request (mirror pi's observed headers) — answers whether one injected token serves both tools;
   - (c) **placeholder-side check (no secret):** run host CC with `CLAUDE_CODE_OAUTH_TOKEN=<shape-conforming garbage>` and confirm it authenticates from the env var (sends it as Bearer; a 401 naming the token proves the path) — this decides whether in-cage CC needs any placeholder FILE at all (§6.1);
   - (d) same question for pi: does it read a token from env, or only `auth.json`?
4. **Entitlement parity, not just auth acceptance (review F1 — the constraint the project turns on):** a 200 does not prove subscription billing. Probe: compare rate-limit/usage response headers between a setup-token request and a normal subscription-token request; run a realistic CC turn under `CLAUDE_CODE_OAUTH_TOKEN=<real setup-token>` (secrets-via-stdin env, output discarded) and confirm it behaves like a subscription session (model access, no metered-billing signals); check the user's Console/billing surface shows no API-key charge. Unprobeable unknowns get NAMED as monitored residual risks, not assumed away: revocation-on-password-change, concurrent-use limits, silent future restriction of setup-token semantics.
5. Determine effective lifetime (token metadata, docs, or worst-case: schedule a re-check).
- **Acceptance:** a written verdict — {works for CC / works for pi / lifetime ≥ N days / env-var placeholder path viable per tool / **entitlement-parity evidence + named residual risks**} — recorded on the bead. Full pass → build rung 1. Partial/fail → S1.

**S1 — form-encoding probe (rung-2 gate, fact F1).** No secret at all: POST a **garbage** refresh token, form-encoded, to `platform.claude.com/v1/oauth/token` with CC's public client_id. `invalid_grant`-class error ⇒ the form was parsed ⇒ F1 favorable; a malformed-request/unsupported-content-type error ⇒ F1 unfavorable ⇒ rung 2 dead (skip to rung-3 discussion or park). Rate-limit-aware: space attempts, expect 429s.

**S2 — rotation observation (fact F2a).** Passive, no token exposure: hash-only diff (`sha256` of the refreshToken field + `expiresAt`) of the host credential file across one of host CC's own natural refreshes. Rotation confirmed if the hash changes. Costs nothing, burns nothing.

**S3 — invalidation replay (fact F2b).** **Destructive-capable, last, main-context only — and consider skipping it entirely (review F6):** if S2 shows rotation, the cheaper decision path is to *pessimistically assume invalidation* and take the rung-3 decision without burning a live credential; run S3 only if that decision genuinely hinges on the distinction. If run: refresh with current token R0 (secrets-via-stdin), capture new R1, then replay R0 → `invalid_grant` ⇒ invalidation confirmed. Recovery plan MUST be concrete before the probe fires: write R1 back to BOTH the macOS keychain item (`security add-generic-password` overwrite of the exact service/account CC uses — identify it first) AND `~/.claude/.credentials.json` (rc's `_extract_credentials` regenerates the file from keychain, so keychain is the authority — file-only write-back leaves the keychain holding dead R0); then VERIFY host CC still authenticates; declared fallback if write-back fails = interactive `claude` re-login (accepted, one-time).

**S4 — in-cage live E4 proof (whichever rung builds).** The first-ever live-Anthropic injection (retires ADR-026 D5 tripwire 4): real cage, placeholder creds, real injection, and the **corrected non-possession checks** — (a) agent-uid read of `/proc/<mediator-pid>/environ` returns EACCES (gated on the mediator pid being found, so it can't vacuously pass); (b) agent-visible credential files hash-match the placeholder, AND the agent-readable iron-proxy config (`/etc/iron-proxy/proxy.yaml`) contains only the env-var *reference* (`RIPCAGE_MEDIATOR_*` name), never an inlined secret value (review F7 — without this, the file hash-check can pass while the secret sits in a readable config); (c) zero-rc-diff **measured against main *after* the §6.2 floor-change bead has merged** (review F3): the injection work itself must add no rc edits — the reviewed floor change is the pinned baseline, not a RAISE; (d) dual allowlist verified by a probe through the proxy. Budget for one integration-bug cluster (ports, CA install, dns.enabled, wildcard rules) — this always happens on real-tool E4.

## 6. Build sketch — rung 1 (elaborated only for the target rung; rung 2 build detail lives in spike-D-design.md)

Scout findings (2026-07-03, source-verified with file:line) now baked in:

1. **In-cage placeholder auth = env var, not file seeding (probable — S0 verifies).** There is an already-documented zero-rc-diff placeholder pattern: a placeholder bearer in `.rip-cage.yaml` env + iron-proxy `transforms.secrets` swap (`examples/compose-rc-with-iron-proxy.md`). Claude Code supports env-var auth (`CLAUDE_CODE_OAUTH_TOKEN` — the documented CI companion of `setup-token`). If in-cage CC honors a shape-conforming placeholder env token (S0 step 3a verifies, host-testable), **no placeholder credential file needs seeding at all** for CC. pi's env-var support is unknown (S0 step 3b); if pi is file-only, pi gets a placeholder `auth.json` baked via the pi-recipe manifest entry (composition, zero-rc-diff) — safe ONLY once the real mount is suppressed (see 2; writing through the live RW mount corrupts the host credential — scout-confirmed shared-inode write-through).
2. **Real-mount suppression is the ONE floor change (user decision required).** The CC/pi credential mounts are hardcoded, unconditional (existence-gated only), RW, in `cmd_up` (`rc:1294-1303`, `rc:1450-1458`); the `.rip-cage.yaml` schema (17 fields) has no auth key; manifest mounts cannot shadow the same destination (Docker "Duplicate mount point", verified). Zero-rc-diff alternatives are all bad: host-file-absence is a machine-wide topology trick that fights `_extract_credentials`, and in-cage overwrite is the write-through hazard. **Proposal: a per-project `.rip-cage.yaml` key (e.g. `auth.credential_mounts: real|none`, default `real`) gating those two mount blocks + the keychain extraction.** Framing (corrected per review F4): ADR-005 D12 *names mount declarations as one of the composition interfaces rc owns* — so this is argued as parameterizing rc's own mount-declaration interface, exactly the kind of seam work D12 sanctions; it blesses no tool. The **named-and-rebutted alternative**: move the hardcoded cred mounts out of rc into ordinary manifest mount declarations ("manifest ownership") — rejected because it needs the same one-time rc change anyway, and it relocates the possession default into the hand-maintained personal manifest, the exact surface whose copy-drift already broke the cage twice; a floor-config default (`real`) keeps the standalone posture explicit and per-project. Landed as its own reviewed floor-change bead (adversarial review before impl — security-relevant). `.rip-cage.yaml` is ro in-cage (ADR-021 D7), so the agent cannot flip it back to `real`. The parent bead explicitly anticipated this fork ("flag whether conditional-mount needs rc support"). Scope the same bead to include the `network.egress.mediator_env_file` pointer option (autonomy fix — see rung 1 burden note in §4).
3. **iron-proxy Anthropic config = personal manifest fragment** (zero-rc-diff, but build-time): transform config is baked to `/etc/iron-proxy/proxy.yaml` by the TOOL `install_cmd` at `rc build`; no runtime override exists. So: copy `examples/iron-proxy/manifest-fragment.yaml` into the personal `tools.yaml` with an Anthropic config — `secrets` entry (env source `RIPCAGE_MEDIATOR_ANTHROPIC_TOKEN`, placeholder-value match), `rules`/allowlist `domains` for `api.anthropic.com` (+ pi's API hosts if distinct). Requires `rc build` per config change — acceptable (config is ~static in rung 1).
4. **Secret delivery, operationally:** `--mediator-env` is never persisted and must be re-supplied on every `rc up` including resume (scout Q4; `rc reload` never touches the mediator). Rung-1 story: setup-token lives in a host-side chmod-600 env file (or keychain-backed wrapper script), passed as `rc up --mediator-env-file <path>` — a shell alias makes it invisible. Document loudly: omitting it on resume = silent injection no-op (scout-confirmed failure mode).
5. **`.rip-cage.yaml`**: `network.egress.mediator: iron-proxy`, `network.http.forward_to: "127.0.0.1:8888"`, `network.allowed_hosts` including `api.anthropic.com` (and NOT `platform.claude.com` in rung 1 — in-cage tools never refresh; leaving the token endpoint unreachable is defense-in-depth against a confused in-cage refresh attempt). [2026-07-06: superseded — platform.claude.com is on Claude Code's documented required-domains list and interactive Claude Code >=2.1.19x hard-fails without it; guidance flipped, see examples/compose-rc-with-iron-proxy.md]
6. **Verification:** S4 as the acceptance harness.

## 7. Bead mapping (to be materialized after review)

- **rip-cage-seqc** (parent): notes updated with this doc as design-of-record; topology fork answered (parked, with reason); rung-3 escalation named.
- **NEW child (first)** — "S0: setup-token viability spike" (blocks seqc.2 and the build bead).
- **rip-cage-seqc.2** → kept as the rung-2 spike (its reviewed content — form-encoding F1, direct rotation probes F2, stub-expiry regime — already covers S1–S3); re-gated: dep on S0 instead of seqc.1, entered only if S0 partial/fails; its "fall back to B" verdict path replaced by "escalate to rung 3 (upstream write-back)".
- **NEW child** — "Floor change: config-gated credential mounts (`auth.credential_mounts`)" — pending user approval (§9.1); needed by every rung.
- **NEW child** — "Build + live E4 proof (S4) for the winning rung" (deps: S0, floor change).
- **rip-cage-seqc.1** (Spike B) → parked-fallback (deprioritized, parking note with the exec-delivery observation).
- Part B (composition cleanup) — untouched by this design, stays on the parent (handoff §7). One note: under non-possession the conditional-mount question likely dissolves (agent holds a placeholder regardless).

## 8. Delegation map (for /send-it execution)

| Work | Who | Why |
|---|---|---|
| Token-touching turns (S0 mint/probe, S3 replay, --mediator-env supply) | **Main brain only** | secrets never enter subagent contexts |
| Verdict synthesis, rung decisions, ADR calls | Main brain (Fable) | judgment |
| Adversarial reviews (design, then impl) | opus subagent | fresh context, strong |
| examples/ + manifest + .rip-cage.yaml edits, test wiring | sonnet implementer | mechanical against this spec |
| S4 integration debugging (the expected bug cluster) | opus debugger/implementer | real-tool E4 always surfaces one |
| File inventories, doc/source lookups | haiku/sonnet Explore | token volume, no judgment |

## 9. Open questions / decisions for the user

1. **[USER DECISION] The one floor change:** approve `auth.credential_mounts: real|none` (or equivalent) in rc gating the hardcoded credential mounts + keychain extraction (§6.2). Scout-established: no zero-rc-diff alternative exists that isn't a machine-wide topology hack or a host-credential-corrupting write-through. Without it, non-possession is impossible regardless of which rung wins.
2. pi acceptance of a CC setup-token (S0 step 3b; if pi rejects, rung 1 may apply to CC only and pi takes rung 2 — a split outcome is acceptable). Likewise pi's env-var-vs-file auth surface (S0 step 3d) decides whether pi needs a baked placeholder file.
3. setup-token actual lifetime (S0 step 4).
4. Bead-mapping addition per §6.2: the floor change, if approved, is its own bead (design + adversarial review before impl — security-relevant), sequenced before the build bead and after S0 (no point building the gate if every rung dies — though every rung needs it, so it can proceed in parallel with S0 once approved).
