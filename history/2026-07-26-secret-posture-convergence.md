# Converged design: durable secret posture for caged workspaces

Bead: rip-cage-23cp. Inputs: community scan digest (`2026-07-26-secret-posture-community-scan.md`, ~40 cited sources) and live spikes S1–S4 (`2026-07-26-secret-posture-spikes.md`, all validated). This doc is the convergence: posture, seam shape, ADR reconciliation, honest residuals, and the rip-cage-vjuv delta.

## Posture — classify project secrets by USE, not location

The brain's three-class hypothesis survived contact with both the community scan and the spikes, with one mandatory refinement: **Class B splits in two.**

| Class | Definition | Mechanism | Status |
|---|---|---|---|
| **A — wire-bearer** | Sent verbatim toward a known host (API keys, PATs, bearer tokens) | Non-possession: real value host-side only, placeholder in repo `.env`, `auth.credentials` binding → msb `--secret` wire substitution | **Works TODAY as a pure recipe, zero rc code.** Spike S2 (substitution) + S3 (anti-exfil block) validated; independently shipped by Daytona Secrets and Claude Code `sandbox.credentials` mask mode — convergent evolution, not a rip-cage invention |
| **B1 — locally-consumed, dynamically issuable** | Consumed by local processes but issuable short-lived (DB passwords, cloud session creds) | Community pattern: per-cage short-lived issuance (Vault-style dynamic secrets). Not "give up" — but it is a *composition*, not rc machinery | Accept-or-exclude interim; agent-composed broker recipes are the future path |
| **B2 — static key material** | Structurally static, locally consumed (signing keys, mTLS client keys, age/PGP keys) | None — substitution is on-the-wire; these never transit in substitutable form | The irreducible possession core. Accept-or-exclude, honestly named |
| **C — not-needed-by-caged-work** | Present in the mounted tree, unused by the cage's task | Boot-time ro overmount mask (spike S1: clean shadow, EROFS on write, rest of workspace rw) or relocate out of tree | Mask primitive is the one NEW rc seam this posture asks for |

Classification aids (community-sourced, for recipe docs, never auto-enforced): TruffleHog's per-detector verification endpoints approximate a Class-A membership oracle; the IETF bearer-vs-proof-of-possession cut (RFC 6750 vs 9449/8705) is the same boundary; Secretless Broker shows the A/B border is protocol-support cost, not physics (it substitutes inside Postgres/MySQL handshakes) — B1 can migrate toward A as substitution grows protocol support.

Differentiation check from the scan: **no mainstream platform hides secrets from the workload that uses them** (Fly, Lambda, K8s, GitHub/GitLab CI all deliver plaintext and defend with at-rest encryption + log masking + short lifetimes; log masking is documented-weak — exact-match, base64-defeated, CVE-2025-30066). Non-possession is rip-cage's differentiator, not table stakes.

## Seam shape (ADR-005 D12 reconciliation)

**rc-invariant (the seam/floor side):**
1. **NEW: a declarative workspace-mask primitive.** A config list (ADR-021-layered, e.g. `mounts.mask:` — workspace-relative paths), consumed at `rc up` into nested single-file ro overmounts (the S1-validated mechanics rc already uses for `config_mode: ro`; note S1 tested a static, present source — see residuals 8–9 for the operational edges). Mechanical, identical every run, tool-agnostic → legitimately invariant seam. Union merge (additive list) fits ADR-021 D2. Two design decisions belong to the governing ADR, not the impl: mask content should be a **legible breadcrumb** ("masked by rip-cage", not empty bytes — silent-breakage mitigation), and a **missing mask source must fail loud** at `rc up` (never the bind-mount silently-becomes-a-directory failure).
2. **EXISTING: `auth.credentials` → `--secret`** already carries Class A for arbitrary credential-host pairs. No rc change; Class A is docs/recipe only.

**Agent-composed (never rc):** the classification itself, which paths go in the mask list, placeholder `.env` authoring, Class-A binding entries, B1 broker compositions. **Explicitly rejected as the named drift shape:** any secrets installer, auto-classifier, `.env` scanner-wirer, or "detect and mask" magic — that freezes the varying judgment part into deterministic machinery.

## ADR reconciliation

- **ADR-023 (mount denylist) — NOT contradicted, no evolution required.** D1/D5's workspace-exclusion rejected *pattern-matching* workspace paths (false-positive argument). The mask list is the opposite mechanism: explicit per-path operator declaration, opt-in, no patterns. `.env`'s denylist exclusion (D4) also stands — masking is orthogonal to env-file sourcing. A cross-reference note in ADR-023 is worthwhile when the posture ADR lands.
- **ADR-024 D2 (exfil axis) — evolution warranted.** Workspace contents were defended by the egress wall only; the posture adds two content-level layers (Class-C masking, Class-A non-possession). The reflection residual (below) also belongs in its threat-model text.
- **ADR-029 D3/D5 — mechanism unchanged, framing extends.** `--secret` non-possession generalizes from tool creds to project Class-A creds as a recipe; no decision text is contradicted.
- **ADR-021 — new mask key rides the existing three-layer merge**; additive-list semantics, provenance via `rc config show`. No evolution needed beyond the key itself.
- **Canonicalization: warranted.** The classify-by-use posture is cross-cutting and load-bearing → route through `/adr-write` (likely a new ADR; alternatively fold into ADR-024). Filed as a bead, not authored inline.

## Honest residuals (named, not hidden)

1. **B2 possession is irreducible** (and B1 until a broker composition exists). Accept-or-exclude, stated in docs.
2. **Create-time limit (S4):** masking is boot-time-only; a secret file created after boot is unmasked. Accident-class residual.
3. **Reflection defeats non-possession — observed live, not hypothetical.** In S2 the echo host returned the substituted real value in the response body and the guest read it. msb does no response scrubbing (Daytona ships exactly this). Consequence chain: bound host reflects real value → guest possesses it → the violation guard is blind (it keys on the *placeholder*), so the real value can ride egress to any allowlisted host. Prompt-injection-relevant (an injected agent could deliberately elicit reflection via error pages / echo endpoints on the bound host). Mitigation path: upstream msb response-scrubbing question + probe bead; docs warn meanwhile.
4. **In-guest indistinguishability of secret-violation vs plain egress deny (S3):** the block is host-log-only; `rc doctor`'s fix-hint flow would today advise "add the host to the allowlist" for what was actually a blocked credential misdirection — an operator following the hint would convert a caught exfil into an allowed one. Doctor disambiguation is a follow-up bead.
5. **Substitution dead zones:** transformed credentials (Basic-auth base64, creds in bodies/query params) and mTLS/cert-pinned channels are outside the TLS-intercepting substitution model. Class-A membership must be checked per credential, documented in the recipe.
6. **Capability outlives possession:** non-possession doesn't shorten the upstream credential's lifetime; pair with short-lived/OIDC-style upstream creds where the provider offers them.
7. **Masked tracked files vs git:** if a masked path is git-tracked, in-cage commits would commit the mask content (community-observed failure). `.env` is conventionally untracked; recipe docs must carry the warning; the mask primitive should not try to be clever about it (judgment, not machinery).
8. **Misclassification → silent breakage (autonomy-relevant).** Masking a file a local process actually needs (Class B mislabeled C) yields empty-read/EROFS-on-write with confusing downstream errors — exactly the "it's annoying → turn it off" failure the philosophy warns about. Mitigation: legible breadcrumb mask content (seam decision above) + recipe docs framing classification as per-repo judgment.
9. **Single-file overmount operational edges (untested by S1):** a nonexistent bind source silently becomes a directory mount (hence the fail-loud requirement above), and single-file binds track inodes — a host-side rename-replace save desyncs the mask (moby#15793 class). S1 validated only a static, present source; both edges are impl/ADR concerns for the mask primitive.

## rip-cage-vjuv (factory cage) config delta

The pooled `~/code/personal` mount (54 repos, 8 live `.env` files, 5 in repos the cage doesn't need) resolves cleanly under the posture: the 5 unneeded `.env`s are Class C → entries in the new mask list once the primitive lands; the needed repos' secrets get classified per-repo (A → placeholder recipe; B → accept-or-exclude call per repo). **Recommendation: vjuv stays parked until the mask primitive lands** (it is the only blocking piece; Class-A recipe needs no code), unless the operator prefers interim mount-narrowing to only-needed repos. Mechanically: vjuv's live blocker is this brainstorm bead, which clears at close — the dependency edge must be **re-pointed to the mask-primitive bead** so vjuv doesn't falsely unblock.
