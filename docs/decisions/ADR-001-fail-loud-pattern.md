# ADR-001: Fail-Loud Error Handling

**Status:** Accepted
**Date:** 2026-04-21

## Context

When `rc` encounters state it doesn't recognize — a container created by an older version, a missing label, an absent script, an image drift — it has two choices:

1. **Silent fallback** — substitute a "safe" default (e.g. treat a missing `rc.egress` label as `off`) and carry on.
2. **Fail loud** — refuse to proceed, print a clear error that names the root cause and the user-facing remedy.

Rip-cage is a safety harness. Silent fallbacks in a safety harness are worse than crashes: they make the tool appear to work while quietly downgrading the guarantees the user is relying on. A container resumed with `rc.egress=off` "because the label was missing" looks identical to one that was explicitly created with egress off, but the user believes they have the firewall.

This pattern is borrowed from Mapular's ADR-001 (fail-loud error handling), which reaches the same conclusion from a data-integrity angle.

## Decision

`rc` uses a **fail-loud** error handling pattern for state mismatches: missing labels, missing scripts, image/container drift, and unknown configurations cause an immediate, descriptive error rather than a silent fallback.

Specific behaviors:

- **Legacy containers** (missing `rc.egress` label on resume) — error out with a message pointing to `rc destroy && rc up`. Do not guess the intended egress mode.
- **Image/script drift** — if an expected script is absent inside the container, surface the underlying `docker exec` error verbatim rather than swallowing it.
- **Unknown states** — `docker inspect` returning an unexpected status, or a label with an unrecognized value, must abort with a clear message, not default silently.
- **Errors are actionable** — every fail-loud message includes the concrete command the user should run next.

## Consequences

**Positive:**
- Safety-stack guarantees (egress firewall, sudoers, hooks) can be trusted: if `rc` proceeds, the features are wired up.
- Upgrades surface cleanly: legacy containers are flagged explicitly instead of degrading into half-protected sessions.
- Debugging is straightforward — the failing component names itself.

**Trade-offs:**
- Users hit more hard stops during version transitions (e.g. adding a new label). Mitigated by always emitting the recreate command.
- No graceful degradation for old containers; `rc destroy` + `rc up` is mandatory.

**Non-goals:**
- This ADR is not about transient infrastructure errors (docker daemon unreachable, transient network). Those may be retried. The rule applies to state/config mismatches.

## Related

- Mapular ADR-001 (fail-loud data handling) — origin of the pattern.
- ADR-012 (egress firewall) — the feature whose first legacy-container upgrade motivated writing this down.
