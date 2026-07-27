# Project-secret posture: the opt-in effort gradient (Class A / Tier 2)

> Governing decision: [ADR-030](../decisions/ADR-030-classify-by-use-secret-posture.md) — classify-by-use project-secret posture. This page is the **recipe** for Tier 2 of that gradient: turning a project's own wire-bearer credential (a Class-A secret) into a non-possessed one, the same way [ADR-029 D5](../decisions/ADR-029-msb-migration.md) already does by default for the tool's own OAuth token. Evidence base: `history/2026-07-26-secret-posture-spikes.md` (S2/S3) and `history/2026-07-26-secret-posture-convergence.md`.

**Read this if:** a project's mounted workspace holds a live credential — an API key, a PAT, a bearer token — that the caged agent actually sends toward a known host, and you've decided the leak cost is high enough to be worth the rework. If that doesn't describe your situation, **you almost certainly want Tier 0 or Tier 1, not this page** — keep reading the next section before going further.

---

## The gradient — start here, not at Tier 2

Per [ADR-030 D2](../decisions/ADR-030-classify-by-use-secret-posture.md) (FIRM), project-secret posture is an **opt-in gradient with a zero-work default**, not a checklist every project must complete. No rip-cage surface — this doc included — may read as a required migration. Most projects should stop at Tier 0; a few should stop at Tier 1; Tier 2 is for the minority of credentials that clear the criterion in [§ When to opt a credential into Tier 2](#when-to-opt-a-credential-into-tier-2-a-criterion-not-a-list) below.

| Tier | What it costs | What it buys | Where |
|---|---|---|---|
| **Tier 0 — do nothing (the default)** | Zero authoring | The egress wall (default-deny + curated allowlist, [egress.md](egress.md)) already stops network exfil of anything in the tree, including secrets you never touched. | Nothing to configure — every cage starts here. |
| **Tier 1 — `mounts.mask`** | A few lines per unneeded secret file | Boot-time `ro`-overmounts a Class-C secret (present in the tree, not needed by the caged task) so it isn't even *readable* in-cage — cheap, additive, per-file. | [config.md → `mounts.mask`](config.md#mountsmask--workspace-mask-primitive-tier-1-project-secret-posture) |
| **Tier 2 — Class-A non-possession rework (this page)** | Per-credential: split the placeholder from the real value, wire an `auth.credentials` binding | The guest never holds the real credential bytes at all — msb substitutes them only on the wire toward the bound host. | Below. |

The tiers are cumulative in effort, not in obligation: a project can live happily at Tier 0 forever, add a Tier 1 mask entry when a pooled mount surfaces an unneeded sibling-repo secret, and reserve Tier 2 for the one credential where a leak would actually hurt. Nothing forces a project up the gradient.

---

## The Class-A recipe (Tier 2)

**What "Class A" means:** a secret is *wire-bearer* if it is sent **verbatim** toward a known host — an API key in an `Authorization` header, a PAT used as a git password, a bearer token. That's the property msb's `--secret` mechanism substitutes: a literal placeholder string in the guest, the real bytes only on the TLS-intercepted wire toward the one host the credential is bound to ([ADR-029 D5](../decisions/ADR-029-msb-migration.md)).

The recipe has three pieces, mirroring the egress worked example already documented in [egress.md § the `source_file` + `target_env` form](egress.md#the-source_file--target_env-form-no-manual-pre-export):

1. **A placeholder value committed in the repo.** The project's `.env` (or wherever the credential lives) holds a literal placeholder — not the real key — checked into the repo like any other config.
2. **The real value host-side only.** The actual credential lives in a host-side file (or host-exported env var), never committed, never mounted into the cage.
3. **An `auth.credentials` binding** in `.rip-cage.yaml` naming the host env var, the `source_file` holding the real value, the bound `hosts`, and the `target_env` the guest-side tool actually reads.

### Worked example: a project sending an API key to one host

Say a project calls `api.example-service.com` with a bearer token its own code reads from `SERVICE_API_KEY`.

```bash
# <project>/.env — committed to the repo; NOT the real key
SERVICE_API_KEY=$MSB_SERVICE_KEY
```

```yaml
# <project>/.rip-cage.yaml
version: 2
network:
  allowed_hosts:
    - api.example-service.com
auth:
  credentials:
    - source_env: SERVICE_KEY                                    # logical name; msb synthesizes $MSB_SERVICE_KEY
      source_file: /Users/you/.config/rip-cage/example-service-key  # host-only file holding the REAL key — never committed
      hosts: [api.example-service.com]                           # single-host binding, enforced
      target_env: [SERVICE_API_KEY]                               # the guest var the project's own code reads
```

```bash
# host-side, once: put the real key where source_file points
echo -n "sk_live_the_real_key_here" > ~/.config/rip-cage/example-service-key
rc up ~/code/my-project
```

Inside the cage, the project's own code reads `SERVICE_API_KEY` and sees only `$MSB_SERVICE_KEY` — in the env, in `/proc/self/environ`, in the `.env` file on disk, and in `msb inspect`'s at-rest config. When that code makes an HTTPS request to `api.example-service.com`, msb's TLS-intercepting proxy substitutes the real key on the wire; a request toward any *other* host carrying the placeholder is block-and-logged, not substituted. This is exactly the mechanism [ADR-029 D5](../decisions/ADR-029-msb-migration.md) already ships for Claude Code's own OAuth token, generalized to a project's credential — no `rc`/`cli` code changes, pure config.

**This is validated end-to-end, not theoretical.** `history/2026-07-26-secret-posture-spikes.md` S2 ran exactly this shape with a sentinel credential (`SPIKE_TOKEN`) bound to `httpbingo.org`: the guest env, `/proc/self/environ`, the on-disk `.env`, and the at-rest `msb inspect` config all held only the placeholder throughout; an echo endpoint confirmed the real sentinel value appeared on the wire toward the bound host and nowhere else on the guest filesystem. S3 is the matching negative control: the same placeholder sent toward a different, allowlisted-but-*unbound* host (`example.com`) was block-and-logged by msb's violation guard, not substituted — confirmed via the host-side `secret violation: placeholder detected for disallowed host` log line, not just an assumption that the deny worked.

---

## Class-A membership heuristics — judgment aids, not a checklist

Whether a given credential *is* Class A (wire-bearer) is a per-situation judgment call (per [ADR-030 D1](../decisions/ADR-030-classify-by-use-secret-posture.md), FIRM — classification is never rc machinery). Two heuristics from the community scan (`history/2026-07-26-secret-posture-community-scan.md`) are useful inputs to that judgment, not a mechanical test:

- **The TruffleHog verification-endpoint oracle.** TruffleHog's detector machinery classifies secret types by whether it "can log in to confirm if that secret is live" — i.e., whether the secret can be replayed verbatim against a remote verification endpoint. A credential that's verifiable this way is, by construction, wire-bearer: something a remote host accepts as bytes-on-the-wire is exactly what `--secret` substitution can intercept and replace. If a credential has no such verification endpoint (it's checked by a local process against local key material, say), that's a signal it's *not* Class A.
- **The IETF bearer-vs-proof-of-possession cut.** RFC 6750 bearer tokens ("any party in possession can use it") map to Class A — substitutable on the wire, because possession *is* the whole security property, so swapping the bytes at the network boundary changes nothing about what the token can do. RFC 9449 (DPoP) / RFC 8705 (mTLS-bound tokens) map to Class B — proof-of-possession requires a local private key the wire substitution can't stand in for; these are un-proxyable by construction.

Use both as inputs to the judgment call for the credential in front of you, not as a checklist to run down. A credential can be structurally bearer-shaped and still not worth Tier 2's cost — that's the separate question in the next section.

---

## When to opt a credential into Tier 2 — a criterion, not a list

Per [ADR-030 D3](../decisions/ADR-030-classify-by-use-secret-posture.md) (FIRM), the trigger for spending Tier 2's per-credential effort is a **judgment criterion**, deliberately not an enumerated list of credential types that "always need" non-possession:

> Opt a credential into Tier 2 when it is **high-value AND the cost of a leak is great or irreversible.**

That's the whole test. It is applied per credential, per situation — the same credential type can clear the bar in one project and not in another.

**Illustration, not a list entry:** a production database password is a natural example of a credential that clears this bar — it's high-value (broad read/write over real data) and a leak's cost is great and hard to walk back (the blast radius is whatever the database holds, and rotating it doesn't undo what already leaked). That's offered here as *one worked instance of the criterion in action*, not as the first entry of a taxonomy you're meant to complete. A staging database password with cheap rotate-on-demand and no real blast radius may sit fine at Tier 0. Do not read this doc (or any other rip-cage doc) as implying a fixed set of credential *types* that always warrant Tier 2 — that's exactly the brittle-checklist shape [ADR-030 D3](../decisions/ADR-030-classify-by-use-secret-posture.md) rejects. The question is always "how bad, here, if this specific credential leaks" — not "is this the kind of credential that's usually sensitive."

---

## Substitution dead zones

`--secret` substitution operates on the **TLS-intercepted wire, byte-for-byte, in the exact form the credential is sent in**. Several common credential-usage shapes fall outside that model — Tier 2 does not cover them, and attempting to force it will silently fail to protect the credential:

- **Transformed credentials.** If the credential is transformed before it hits the wire — Basic-auth's base64-encoded `user:pass`, a credential embedded inside a request body or query-string parameter rather than a raw header value — msb's substitution can't reliably find-and-replace it in its transformed form. The placeholder needs to appear on the wire in a form msb's proxy recognizes; a base64-wrapped or otherwise-encoded placeholder generally won't round-trip correctly.
- **mTLS / cert-pinned channels.** `--secret` substitution works by TLS-intercepting the connection (the same mechanism that lets msb inspect and rewrite the credential in transit). A channel using mutual TLS or certificate pinning is specifically designed to detect and refuse exactly that kind of interception — the connection either fails outright or the pinning check catches the substituted certificate. These channels are outside the model by construction, not by an implementation gap.

A credential that lands in either dead zone is Class B2 (static key material) in ADR-030's classification, not Class A — it has no substitutable-on-the-wire form. The honest response is accept-or-exclude (keep it out of the cage, or accept possession knowingly), not a Tier-2 recipe that looks like it's protecting the credential but isn't.

---

## Reflection residual

**State the residual plainly: a bound host that echoes the substituted real value back into the guest defeats non-possession.**

This was **observed live, not hypothesized**, in spike S2 (`history/2026-07-26-secret-posture-spikes.md`): the echo endpoint at the bound host reflected the substituted real sentinel value back in its HTTP response body, and the guest process could read it from the response. Two properties make this worse than a one-off leak:

- **msb does no response scrubbing.** Nothing strips a reflected real value out of an inbound response before the guest sees it — the substitution is one-directional (outbound placeholder→real), not a round-trip masking of the credential wherever it appears.
- **The violation guard is placeholder-keyed, so it's blind to a reflected real value.** The guard that blocks-and-logs a placeholder sent toward an unbound host (validated in S3) keys on the *placeholder string* appearing outbound. Once the real value has been reflected into the guest and the guest re-sends it — verbatim, no longer as `$MSB_...` — that outbound traffic looks like any other legitimate byte stream to the guard. A reflected-then-re-exfiltrated credential rides straight through to any allowlisted host with no guard firing.

This is **prompt-injection-relevant** ([ADR-024](../decisions/ADR-024-prompt-injection-threat-model.md)): an injected agent doesn't need to defeat the substitution mechanism at all — it only needs to induce the bound host (or something that looks like it, e.g. an error page or debug endpoint on that host) to echo the credential back, then have the guest forward that now-plaintext value onward. The wire substitution did its job; the residual is entirely in what happens to the credential *after* it's back inside the guest.

**msb has no response-path scrubbing — confirmed, not assumed (rip-cage-x640).** A probe of msb 0.6.4 across three surfaces — the CLI (`msb run/create --help`, `msb --tree`), the `microsandbox` skill docs, and the upstream secret handler source (`crates/network/lib/secrets/handler.rs` in `superradcompany/microsandbox`) — confirmed substitution is **outbound-only**: the handler scans decrypted *request* plaintext (guest→server) and has no response/inbound path at all. `--on-secret-violation` only governs the placeholder going *out* toward a disallowed host; nothing strips a *reflected real value* out of an inbound response. So this residual cannot be closed by configuration today — it is a genuine upstream gap. (Daytona Secrets ships response-path scrubbing as prior art — rewriting the real value back to the placeholder in every response before it reaches the sandbox: <https://www.daytona.io/docs/secrets>. An upstream msb feature request mirroring it is drafted and tracked in `rip-cage-yk3s`, pending maintainer authorization to file.)

**Interim guidance (operational, until upstream scrubbing exists):**

- **Prefer bound hosts that do not echo credentials** back in response bodies. Before opting a credential into Tier 2 against a given host, confirm the host's API does not reflect the `Authorization` value (or the credential in any form) in success or error responses.
- **Treat any echo/debug endpoint on a bound host as hostile** for the purposes of this residual — even one that is part of the "legitimate" API surface (a `/debug`, a request-echo test route, a verbose validation error that quotes the submitted token). A reflecting endpoint on the bound host is the whole attack surface here.
- **Non-possession is not a substitute for a short credential lifetime** against this residual — see [§ Capability outlives possession](#capability-outlives-possession). A short-lived / narrowly-scoped upstream credential bounds the damage of a reflected-then-re-exfiltrated value in a way non-possession alone does not.

---

## Capability outlives possession

Non-possession changes *where the credential's bytes are visible*; it does not change *how long the upstream credential itself remains valid*. A guest that never holds the real key is still, from the bound host's perspective, wielding a fully capable credential for as long as that credential is valid upstream — msb `--secret` doesn't shorten a token's lifetime, revoke it, or scope it down.

Where the Tier-2 criterion's leak-cost half is driving the decision, pair the recipe with **short-lived or OIDC-style upstream credentials** where the provider offers them — a substituted token that expires in minutes bounds the damage of *any* misuse path (reflection, a compromised bound host, a scope the credential shouldn't have had) far more than a long-lived one does, non-possession or not. Non-possession and short lifetime are complementary, not substitutes for each other.

---

## Agent-assisted composition — the answer to "54 repos by hand"

Hand-classifying every secret across a large pooled workspace mount (dozens of sibling repos, each with its own `.env`) doesn't scale as a manual recipe-reading exercise. The intended answer is **agent judgment, not rc machinery** (per [ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)): an agent sweeps the workspace tree for secret-looking files, proposes a `mounts.mask` list for the ones the caged task doesn't need (Tier 1) and flags any credential that plausibly clears the Tier-2 criterion above for human review, the human approves a handful of lines, and the agent writes the resulting config.

That sweep recipe lives in the **configure-cage skill** (`~/.claude/skills/configure-cage`), extended for exactly this purpose by `rip-cage-3npt` — see that skill for the full sweep walkthrough rather than duplicating it here.

---

## See also

- [ADR-030](../decisions/ADR-030-classify-by-use-secret-posture.md) — the governing decision: the classification model, the full D1–D8 decision set, and the named residual list this page's dead-zones/reflection sections summarize
- [ADR-029 D5](../decisions/ADR-029-msb-migration.md) — the `--secret` mechanics this recipe reuses (placeholder/real-value split, `target_env`/`source_file`, the violation guard)
- [config.md → `mounts.mask`](config.md#mountsmask--workspace-mask-primitive-tier-1-project-secret-posture) — Tier 1, the cheaper sibling of this page's Tier 2
- [egress.md](egress.md) — the Tier-0 default (egress allowlist) and the existing `auth.credentials` worked example this page's recipe extends
- [ADR-024](../decisions/ADR-024-prompt-injection-threat-model.md) — the exfil threat model the reflection residual belongs to
- `history/2026-07-26-secret-posture-spikes.md` — S1–S4 spike evidence (S2/S3 are this page's load-bearing citations)
- `history/2026-07-26-secret-posture-convergence.md`, `history/2026-07-26-secret-posture-community-scan.md` — the design convergence and the community-scan evidence base (TruffleHog, IETF RFCs) cited above
