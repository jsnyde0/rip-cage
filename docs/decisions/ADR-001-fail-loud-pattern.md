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
- **Unknown states** — `docker inspect` returning an unexpected status, or a label with an unrecognized value, must abort with a clear message, not default silently. This applies to `cmd_up`'s state switch: `paused`, `restarting`, `removing`, and `dead` must fail loud with actionable hints, not fall through to the "create new container" branch where they produce a confusing name-conflict error.
- **Inventory surfaces name the problem** — listing commands (`cmd_ls`) must annotate containers that would fail loud on resume (missing or invalid `rc.egress` label) rather than rendering a blank column. Operators should not have to probe via `rc up` to discover that a container is legacy.
- **Errors are actionable** — every fail-loud message includes the concrete command the user should run next.

### Exceptions

The fail-loud rule applies to state/config mismatches that affect safety
guarantees or execution. It does **not** apply to purely informational
fields whose degraded value is visibly labeled and cannot be mistaken
for a real value. The canonical example is `RC_VERSION`: when
`SCRIPT_DIR/VERSION` is absent (e.g. `git clone && ./rc` during
development), `RC_VERSION` falls back to the string `"unknown"`. This
is acceptable because:

1. `RC_VERSION` is not a safety gate — no decision branches on its value.
2. It is not load-bearing for any ADR-001 scenario (missing label,
   script drift, unknown state).
3. The degraded value is explicitly labeled `"unknown"`, not a
   plausible-looking fake version string.

Adding an informational field to rip-cage does not create a new
fail-loud obligation; adding a safety-relevant field does.

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
