# Rip Cage Roadmap

**Last updated:** 2026-09-17
**Status:** pre-publication. Directional, not a contract.

Rip cage is a distribution of [microsandbox](https://github.com/microsandbox/microsandbox) — a curated agent image, one native msb config per project, a six-verb launcher, three skills, and a suite that proves the cage holds. The positioning and its consequences are [ADR-031](decisions/ADR-031-opinionated-distribution-of-microsandbox.md).

---

## Shipped — the subtracted distribution

msb 0.6.18 ships natively what rip-cage used to claim as its own: the microVM boundary, default-deny egress and DNS, destination-bound `--secret` credentials, read-only mounts, and a config schema. So the work was subtraction — removing everything that reimplemented msb, and keeping only what msb does not do.

- **Six verbs** — `up`, `auth`, `doctor`, `build`, `test`, `destroy`. A verb exists only where plain shell plus a skill cannot do the job identically every run. Twelve verbs were deleted; the `cage-ops` skill is the sole home of each one's successor ([ADR-031](decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D3).
- **One config file per project** — msb's own `--conf` schema, host-side, read by `rc up`. No rip-cage schema, no three-layer merge, no provenance view. The file carries its lists in full ([ADR-031](decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2).
- **A shipped protected-paths list** — known credential locations, as data an operator may edit. `rc up` refuses a config that mounts one, covers any found inside a mounted tree, and aborts before any msb call if the list is unreadable.
- **Images extend the base** — `FROM rip-cage:latest` plus one small boot descriptor naming daemons and multiplexers. The tools manifest, its codegen, its validator and its ~12k-line test corpus are gone ([ADR-031](decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D4).
- **A fail-closed floor probe on the built image** — it inspects the artifact, not a declaration describing it, and runs at every boot and at the head of `rc test`, with no opt-out ([ADR-031](decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5).
- **Three skills as the front door** — [`cage-config`](../.claude/skills/cage-config/SKILL.md) writes the config, [`cage-image`](../.claude/skills/cage-image/SKILL.md) writes the Dockerfile, [`cage-ops`](../.claude/skills/cage-ops/SKILL.md) runs and repairs a live cage.

## In flight

1. **Refactor pass against Unix design** (`rip-cage-sygz`) — where the agent-first CLI contract lands: `--output json` everywhere, an exit-code table, an ANSI/stderr policy, machine-readable errors.
2. **Dogfood** (`rip-cage-ely4.17`) — several days of the human's own real work on the thinned product. Human-owned, and the gate publication waits behind ([ADR-031](decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D7).
3. **Publish** — the ceremony itself is unchanged ([release-ceremony.md](reference/release-ceremony.md), [ADR-008](decisions/ADR-008-open-source-publication.md)); D7 only says when it may start.

## Next — fog, not charted

Each line is a direction, not a plan. None has a bead tree yet.

- **Generalized credential discovery.** Today rip-cage finds one login: Claude's, in the macOS keychain. Next is pi's OpenAI Codex login — currently a file mount plus env forwarding, never refreshed by `rc auth`. After that, 1Password and `gh auth`. Until this lands, opinion 1 is a single-vendor trick, and the README says so.
- **The floor probe as a publishable artifact.** It proves containment properties of any image, not just rip-cage's. Whether that is worth shipping on its own is open.
- **Restart cages from a list after a host reboot.** A launchd or systemd unit looping `msb start`. This is the whole of "fleet" today; it lives under `rip-cage-tncg`.
- **An in-cage read-only denial feed.** So a caged agent can name the exact host it was denied, instead of asking the human to go read the trace log.
- **A known-good msb pin plus a compatibility gate.** Every egress fact rip-cage documents is measured against one msb version; nothing today catches an upstream change that moves them.
- **A black-box recorder recipe.** Capture what an unattended cage did, for the morning after.

**Not planned: a Composefile.** msb 0.6.18 has no `msb compose` — six reserved keys and one reverted attempt — and sandboxes cannot reach each other by name. A second sandbox per project (a browser or database sidecar) would be rip-cage's to compose, and is parked until a project needs one.

---

## Reference

| Document | What |
|----------|------|
| [ADR-031](decisions/ADR-031-opinionated-distribution-of-microsandbox.md) | The distribution positioning and everything it subtracts |
| [ADR-029](decisions/ADR-029-msb-migration.md) | The Docker → microsandbox cutover |
| [ADR-024](decisions/ADR-024-prompt-injection-threat-model.md) | Prompt-injection threat model |
| [ADR-009](decisions/ADR-009-ux-overhaul.md) | Harm-reduction positioning |
| [ADR-008](decisions/ADR-008-open-source-publication.md) | Versioning, CI gate, release ceremony |
| [decisions/INDEX.md](decisions/INDEX.md) | Every ADR, with retired-or-evolved status |

Design docs from earlier phases stay in `docs/2026-*.md` and `history/` with their original mechanism text. They are history, not instruction.
