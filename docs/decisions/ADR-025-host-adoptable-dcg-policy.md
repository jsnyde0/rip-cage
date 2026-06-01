# ADR-025: Host-adoptable DCG policy layer (additive-only, floor-uncrossable)

**Status:** Proposed
**Date:** 2026-06-01
**Builds on:** [ADR-004](ADR-004-phase1-hardening.md) (DCG + compound-blocker baseline this extends), [ADR-021](ADR-021-layered-rip-cage-config.md) (D1+D2 config substrate this consumes), [ADR-023](ADR-023-secret-path-mount-denylist.md) (D1+D2 the sibling additive-floor pattern this mirrors)
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud — D5 below), [ADR-002](ADR-002-rip-cage-containers.md) (D5 hooks-fire-regardless + D12 safety-stack-not-user-modifiable — FIRM constraints preserved), [ADR-012](ADR-012-egress-firewall.md) (D1 egress IOC floor — additive-floor precedent), [ADR-019](ADR-019-pi-coding-agent-support.md) (D3 cage-owned config, D4 pi DCG-equivalence — both engaged below), [ADR-024](ADR-024-prompt-injection-threat-model.md) (D2 on-device-harm symmetry — the threat warrant), project [CLAUDE.md](../../CLAUDE.md) philosophy section ("layers, not walls", "80/20, not 100/0")

## Context

rip-cage bakes the `dcg` (destructive_command_guard) binary into the image via `cargo install --git https://github.com/Dicklesworthstone/destructive_command_guard --tag v0.4.0` (Dockerfile:13-14, 75). Today it ships **zero** DCG config, so the guard runs DCG's compiled core-pack defaults only (`core.git` + `core.filesystem`). The external rules/config surface is untapped.

Two observations motivate this ADR:

1. **The policy layer is agent-agnostic.** Both Claude Code's PreToolUse hook (settings.json:92) and pi's `dcg-gate.ts` extension (rip-cage-bl1) call the *same* container-native `/usr/local/bin/dcg`. Defining destructive-command policy separately per-agent inside the container is redundant — the policy is shared even though the wiring is per-agent. Letting a user raise their policy **once on the host** and have both cages adopt it is the natural shape, mirroring how `network.allowed_hosts` (ADR-012) and `mounts.denylist` (ADR-023) are already host-adopted.

2. **There is a pre-existing self-disable hole.** DCG auto-discovers a project `.dcg.toml` by walking up from its process working directory (verified upstream at tag v0.4.0: `config.rs:2399` reads `env::current_dir()`, `find_repo_root` at `config.rs:255-266`). The PreToolUse hook is invoked with the working directory at `/workspace` — which is the agent-writable bind mount. So **today** an agent (or a prompt-injection following hostile content per ADR-024) can write `/workspace/.dcg.toml` with one wildcard `[[overrides.allow]]` entry and silently neuter the guard, including `rm -rf /`: `overrides.allow` is additive and checked first in the evaluator (`evaluator.rs:1229-1232`) with no severity guard. A `[policy.rules]` per-rule entry can likewise downgrade even Critical core rules.

DCG is an **external pinned dependency, not vendored** — we cannot patch it. And DCG v0.4.0 offers no flag/env/config to disable project-config discovery, and `DCG_CONFIG` *merges* (it does not replace), with `.dcg.toml` merged before it (`config.rs:2407-2434`). So the floor cannot be enforced through DCG's own config precedence. It can, however, be enforced operationally (D3).

Per CLAUDE.md's "layers, not walls" / "80/20" philosophy, this is blast-radius reduction, not a security boundary against a motivated attacker: DCG is a denylist, so a destructive command its patterns don't recognize is still not caught. The win is (a) host-adoptable additive policy shared across both agents and (b) closing the obvious config-based self-disable vector.

## Decisions

### D1: Host-adoptable additive DCG policy via `.rip-cage.yaml` config substrate

**Firmness: FIRM**

Users supply extra DCG policy — enable additional packs and/or add custom YAML rule packs — through a `dcg`-namespaced field in `.rip-cage.yaml`, typed as `additive_list` per ADR-021 D2 merge rules. Effective policy = global list ∪ project list (global first, then project additions); project EXPANDS coverage, never contracts it. Default-on: the mechanism is active out of the box (with an empty additive list, the effective policy is just the baked core floor — D5).

At `rc up` / init, the merged additive policy is **translated** into a single cage-owned DCG config file, mounted read-only, that `DCG_CONFIG` points at (D3).

Schema example:

```yaml
# <project>/.rip-cage.yaml — project additions on top of global
version: 1
dcg:
  packs:        # additive_list — extra built-in packs to enable
    - net
  custom_rule_paths:   # additive_list — globs to cage-readable custom YAML rule packs
    - .rip-cage/dcg-rules/*.yaml
```

**Rationale:** ADR-021 D2 already defines `additive_list` for exactly this shape — a global floor projects can extend. ADR-023 (`mounts.denylist`) and ADR-012 (`network.allowed_hosts`) are the two existing consumers of that substrate; DCG policy is the third. Hardcoding policy in `rc` or shipping a static `.dcg.toml` would fragment substrate that `rc config show` and future agents reconcile from one place.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Mount a host `.dcg.toml` directly into the cage as the project config | `direct:` The agent-writable `/workspace/.dcg.toml` is exactly the hole this ADR closes (Context); a host `.dcg.toml` would still ride DCG's merge precedence and could be shadowed/weakened by the in-workspace one. Translating into a cage-owned RO file pinned via `DCG_CONFIG` (D3) is what gives the floor. |
| Hardcode an expanded default pack set in the image, no host adoption | `reasoned:` Loses the "raise policy once on the host, both agents adopt" property that motivates the ADR; every policy change would require an image rebuild. |
| New config field outside ADR-021 substrate | `external:` ADR-021 D2 is the canonical per-field-type config; a parallel substrate fragments `rc config show`. |

**What would invalidate this:** The ADR-021 config substrate is deprecated or restructured with a breaking schema change → migrate the `dcg.*` fields to the new shape. OR DCG's custom-pack format changes incompatibly across a version bump → re-derive the translation step.

### D2: Baked core packs are an uncrossable floor

**Firmness: FIRM**

Host and workspace config can only ADD coverage above the baked core packs. They cannot disable `core.git` / `core.filesystem`, and cannot downgrade their deny decisions to warn/log. The baked core-pack set is the always-present floor; host adoption is one-directional (broaden only), exactly as `network.allowed_hosts` cannot shrink the egress IOC floor (ADR-012 D1) and `mounts.denylist` cannot remove a global default pattern (ADR-023 D2).

Two layers deliver the floor: DCG's own built-in guarantees (the `core` category is force-enabled — `config.rs:946-947` — and Critical-severity rules resist pack-level/global downgrade), plus the operational enforcement in D3 that closes the config paths by which an agent could otherwise reach the non-built-in weakening vectors.

**Rationale:** A safety floor a project can lower is not a floor. The additive-only/floor-uncrossable contract is the same one the two FIRM sibling ADRs already establish; this extends it to on-device-harm policy. ADR-024 D2 (on-device-harm symmetry, FIRM) is the threat warrant: a prompt-injected agent must not be able to talk the guard out of its own floor.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Let projects fully replace the policy (including disabling core) | `reasoned:` Directly defeats the guard's purpose under the ADR-024 threat model — an injected agent writing project config would disable the floor. Contradicts ADR-002 D12 (safety stack not user-modifiable at runtime). |
| Floor = DCG built-ins only; accept the config weakening vectors | `direct:` DCG v0.4.0's built-in floor is partial — `overrides.allow` (checked first, no severity guard, `evaluator.rs:1229-1232`) and `[policy.rules]` per-rule downgrade bypass even Critical core. The operational enforcement (D3) is required to make the floor real. |

**What would invalidate this:** Routine legitimate workflows need to *remove* a core rule (not just add around it) and there is no additive way to express the exception → reconsider whether a narrowly-scoped, cage-owned (not project) override mechanism is warranted. Signal: users repeatedly forced to fork the image to drop a single core rule.

### D3: Floor enforced operationally (CWD-anchor wrapper + pinned valid `DCG_CONFIG` + env-strip), not by patching DCG

**Firmness: FLEXIBLE**

Because DCG is an unpatchable external pin and offers no disable-project-config flag, the floor is enforced by controlling DCG's environment, not its source. A wrapper is baked into the image at a root-owned, agent-unwritable path (e.g. `/usr/local/lib/rip-cage/bin/dcg-guard`). The wrapper:

1. `cd`s to a **root-owned directory with no `.git` ancestor up to `/`** (e.g. `/usr/local/lib/rip-cage`). DCG then walks up from *that* CWD for project-config discovery and never reaches `/workspace`, so an agent-written `/workspace/.dcg.toml` — or one planted in any nested git repo under the mount — is never discovered. (Verified: discovery starts from the process CWD, `config.rs:2399`; the hook's stdin JSON carries no `cwd` field, `hook.rs`, so process CWD is the only source. Command **evaluation** is pure pattern-matching on the command string and is CWD-independent, `evaluator.rs:1207,1317-1328` — anchoring CWD does not change which commands match.)
2. Pins `DCG_CONFIG` to the cage-owned read-only config file. Setting `DCG_CONFIG` to a file that parses **suppresses the agent-writable user-layer config** `~/.config/dcg/config.toml` entirely (`config.rs:2417` — the user layer loads only `if explicit_layer.is_none()`).
3. Strips/pins the dangerous `DCG_*` override env vars (`DCG_PACKS`, `DCG_DISABLE`, `DCG_POLICY_DEFAULT_MODE`, `DCG_CUSTOM_PATHS`) before `exec`. (These are highest-priority and could weaken policy; the hook process is spawned by Claude Code / pi rather than the agent's shell so the agent cannot normally export onto it, but the wrapper pins defensively.)
4. `exec`s `/usr/local/bin/dcg`, passing stdin through.

With (1)+(2), every agent-writable config path is closed: project `.dcg.toml` (anchored away), user `~/.config/dcg/config.toml` (suppressed). The system layer `/etc/dcg/config.toml` always loads but is root-owned / agent-unwritable (sudoers scope is narrow per ADR-002 D12) and is left absent.

**Firmness rationale (why FLEXIBLE, not FIRM):** the *property* (D2 floor) is firm; this *mechanism* is the most replaceable part. If upstream DCG gains a `--no-project-config` flag, a locked-layer concept, or deny-wins reconciliation, the wrapper's CWD-anchor and/or env-pin can be swapped for the native flag without disturbing D1/D2/D4/D5.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Set `DCG_CONFIG` to a cage path and rely on precedence to win over `.dcg.toml` | `direct:` Falsified against v0.4.0: `DCG_CONFIG` *merges* and `.dcg.toml` is merged before it (`config.rs:2407-2434`); `overrides.allow` is additive and checked first (`evaluator.rs:1229-1232`), so a workspace `.dcg.toml` allow-rule cannot be out-prioritized by a later cage layer. Precedence alone does not close the hole. (This was the original bead plan; it does not work.) |
| Read-only bind-mount a safe file over `/workspace/.dcg.toml` | `reasoned:` Leaky — DCG walks up to the *nearest* `.git`; an agent that `git init`s a subdir and drops `subdir/.dcg.toml` gets a discovered config the RO-mount didn't cover. The CWD-anchor sidesteps the nested-repo dodge entirely. |
| Fork / patch DCG to add a locked layer or disable-project-config flag | `reasoned:` Turns a clean pinned upstream into a fork (maintenance burden) or a wait-on-upstream-PR dependency. The wrapper achieves the same floor today without forking; revisit only if the wrapper proves insufficient. |

**What would invalidate this:** Upstream DCG ships a native disable-project-config / locked-layer / deny-wins mechanism → replace the operational wrapper with the native flag. OR a future DCG version resolves project config from the hook-input `cwd` rather than process CWD → the CWD-anchor stops working; re-verify the discovery source on every DCG version bump (the pin lives in Dockerfile `DCG_VERSION`).

### D4: Both agents route guard invocation through the wrapper

**Firmness: FIRM**

The Claude Code PreToolUse hook (settings.json:92) and pi's `dcg-gate.ts` extension (rip-cage-bl1) both invoke the wrapper (D3), never the raw `/usr/local/bin/dcg`. If pi's extension calls the raw binary via `pi.exec`, that subprocess inherits a `/workspace` working directory and the floor-close does not hold for pi — leaving the two agents with asymmetric guards, which violates ADR-019 D4 (pi must have on-device-harm protection equivalent to Claude Code's).

This creates a cross-bead dependency on **rip-cage-bl1** (which authors `dcg-gate.ts`): bl1 must call the wrapper and its parity bar — currently calibrated to "rip-cage ships no dcg config, core-only" — must account for the cage's merged `DCG_CONFIG`.

**Rationale:** The whole value of a shared policy + uncrossable floor evaporates if one agent's invocation path bypasses it. Routing both through one wrapper is the single chokepoint that keeps them symmetric.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Only wrap the Claude Code hook; let pi call raw dcg | `direct:` `pi.exec` inherits `/workspace` CWD → `/workspace/.dcg.toml` is discovered on the pi path; floor holds for Claude Code only. Violates ADR-019 D4 parity. |
| Have each agent set its own anchored CWD instead of a shared wrapper | `reasoned:` Two implementations of the same security-critical anchoring drift independently; one chokepoint is auditable and testable once. |

**What would invalidate this:** rip-cage drops one of the two agents, OR a future agent's guard cannot shell to the wrapper (e.g. an in-process-only guard API) → that agent must replicate the anchor + env-pin contract and be tested against the same floor regression.

### D5: `DCG_CONFIG` always points at a valid baked file; fail-loud on malformed; safe-by-default preserved

**Firmness: FIRM**

`DCG_CONFIG` must **always** point at a config file that parses — even when the user has adopted zero host policy. The cage bakes a minimal valid default DCG config file; the host-adoptable additions (D1) are merged *into* that file, never replacing it with something that might fail to parse.

This is load-bearing, not hygiene: the user-layer suppression that closes the `~/.config/dcg/config.toml` hole (D3 step 2) is **conditional on `DCG_CONFIG` parsing successfully** (`config.rs:2417` — if the explicit layer is absent/invalid, `explicit_layer` is `None` and the agent-writable user config loads as normal). A missing or malformed `DCG_CONFIG` file therefore silently re-opens the floor.

`rc up` / init validates the translated config parses before launch; on failure it fails **closed** — surfaces an actionable error and refuses to launch rather than launching with a broken config that re-opens the hole (ADR-001 fail-loud; ADR-014 D2 non-interactive posture). With no host config, the cage still ships the baked core-pack floor — no regression to current behavior.

A fully-empty DCG config still denies Critical patterns (DCG falls through to `severity.map_or(Deny, …)`), so the baked floor is fail-closed on the critical class even in the degenerate case.

**Rationale:** The floor's integrity depends on an always-present, always-valid explicit config layer. Treating the config file as optional would make the security property depend on a file that might not exist.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Only set `DCG_CONFIG` when the user has adopted host policy | `direct:` Without `DCG_CONFIG` set, the user layer is not suppressed (`config.rs:2417`) → the agent-writable `~/.config/dcg/config.toml` hole stays open in the common (no-host-config) case, which is most cages. The default path must close the hole. |
| Fail-open (launch anyway) on malformed config | `reasoned:` Contradicts ADR-001; a broken config silently degrades to the user-layer hole. Fail-closed at `rc up` is the only safe posture. |

**What would invalidate this:** A future DCG version unconditionally suppresses the user layer (independent of `DCG_CONFIG`), OR removes the user-config search entirely → the "always set `DCG_CONFIG`" requirement relaxes (though baking a valid default remains good practice). Re-verify on DCG version bump.

## Consequences

**Positive:**
- A user raises destructive-command policy once on the host; both Claude Code and pi cages adopt it from the single shared `dcg` binary.
- Closes a pre-existing live self-disable hole (agent-written `/workspace/.dcg.toml`) — a security improvement independent of the additive feature.
- Floor is uncrossable by host/workspace config, consistent with the egress and mount-denylist ADRs; `rc config show` surfaces the effective DCG policy from the same substrate.
- No DCG fork — the pinned upstream stays clean.

**Negative:**
- The wrapper + always-valid-`DCG_CONFIG` invariant is DCG-version-coupled: each `DCG_VERSION` bump must re-verify config-discovery-from-process-CWD and user-layer-suppression-on-`DCG_CONFIG` (D3/D5 "what would invalidate").
- A new cross-bead dependency: rip-cage-bl1 must call the wrapper and recalibrate its parity bar (D4).
- Translation step (`.rip-cage.yaml` `dcg.*` → cage config file) is new maintenance surface, including custom-pack format coupling to the pinned DCG version.

**Neutral:**
- Anchoring the guard's CWD has no effect on which commands are blocked (evaluation is pattern-based, CWD-independent — verified); it only affects config discovery and allow-once scoping.
- One additional baked file (the default DCG config) and one wrapper script in the image.

## Implementation notes

- **Wrapper** (`/usr/local/lib/rip-cage/bin/dcg-guard`, root-owned, mode 0755): `cd /usr/local/lib/rip-cage` (root-owned, `.git`-free) → set `DCG_CONFIG=<cage RO config path>` → `unset DCG_PACKS DCG_DISABLE DCG_POLICY_DEFAULT_MODE DCG_CUSTOM_PATHS` → `exec /usr/local/bin/dcg "$@"` (stdin passes through). Confirm at cage init that the wrapper + config file exist and the config parses (fail-loud, mirror init-rip-cage.sh's existing guard-presence check).
- **Claude Code wiring:** change settings.json:92 hook command from `/usr/local/bin/dcg` to the wrapper.
- **pi wiring (rip-cage-bl1):** `dcg-gate.ts` calls the wrapper, not raw dcg. Cross-bead — see bl1.
- **Default baked config:** a minimal valid DCG config file (enabling the core packs explicitly is unnecessary since `core` is force-enabled, but the file must parse). Baked into the image at a cage-owned path.
- **Translation (`rc up`/init):** load effective `dcg.*` via the ADR-021 loader (`_load_effective_config`); render extra packs / custom-rule globs into the DCG config file; validate it parses; fail-closed on parse error. The file is mounted (or written) read-only into the cage.
- **Schema fields** added to the ADR-021 loader: `dcg.packs` (`additive_list`), `dcg.custom_rule_paths` (`additive_list`).
- **Tests** (`tests/test-safety-stack.sh` + the pi test path): (a) an added rule causes both a Claude Code cage and a pi cage to refuse a newly-covered command; (b) a hostile `/workspace/.dcg.toml` disabling core / downgrading `rm -rf /` to warn does NOT weaken the guard (floor holds); (c) a hostile `~/.config/dcg/config.toml` with a wildcard `overrides.allow` does NOT weaken the guard (user-layer suppressed); (d) no-host-config cage still ships the core floor; (e) malformed translated config fails `rc up` closed. The floor-uncrossable regression (b)/(c) runs in both the Claude Code and pi paths.
- **Docs:** `docs/reference/config.md` gains the `dcg.*` schema fields; cross-reference from the safety-stack reference.

## canonical_refs

- `docs/decisions/ADR-001-fail-loud-pattern.md` — no-silent-failure; D5 fail-closed-on-malformed follows it
- `docs/decisions/ADR-002-rip-cage-containers.md` — D5 (hooks fire regardless of mode) + D12 (safety stack not user-modifiable at runtime); preserved — binary/wiring stay cage-baked, only policy content is host-adoptable and the floor is uncrossable
- `docs/decisions/ADR-004-phase1-hardening.md` — DCG + compound-blocker baseline this ADR extends with a policy layer
- `docs/decisions/ADR-012-egress-firewall.md` — D1 egress IOC floor; additive-floor precedent (external-enforcer variant)
- `docs/decisions/ADR-019-pi-coding-agent-support.md` — D3 (cage-owned config not host-sourced-at-runtime) reconciled via the ADR-021/ADR-023 translation precedent; D4 (pi DCG-equivalence) advanced by D4 here
- `docs/decisions/ADR-021-layered-rip-cage-config.md` — D1+D2 config substrate + `additive_list` merge; this ADR adds `dcg.packs` / `dcg.custom_rule_paths` as consumers
- `docs/decisions/ADR-023-secret-path-mount-denylist.md` — D1+D2 the sibling additive-floor pattern this mirrors (default-on, global∪project additive_list, baked floor uncrossable)
- `docs/decisions/ADR-024-prompt-injection-threat-model.md` — D2 on-device-harm symmetry; the threat warrant for the uncrossable floor
- rip-cage-hhh.11 — the bead implementing this ADR
- rip-cage-bl1 — pi `dcg-gate.ts` guard; cross-bead dependency (D4): must call the wrapper, parity bar must account for host config
- rip-cage-hhh.12 — pi config-dir topology (container-local extensions/); shares the Dockerfile/rc/init surface
- DCG upstream (tag v0.4.0): `config.rs:2399` + `255-266` (project-config discovery from process CWD), `config.rs:2407-2434` (layer merge order), `config.rs:2417` (user layer suppressed when `DCG_CONFIG` parses), `config.rs:946-947` (core force-enabled), `evaluator.rs:1229-1232` (overrides.allow checked first), `evaluator.rs:1207,1317-1328` (CWD-independent pattern matching), `hook.rs` (no cwd field in hook input)
