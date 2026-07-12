# ADR-025: Host-adoptable DCG policy layer (additive-only, floor-uncrossable)

**Status:** Proposed (D2 revised 2026-06-17 — wlwc: DCG demoted from the welded uncrossable floor to a composable default-on recipe; the welded floor is now CONTAINMENT per ADR-026 D1/D2. D2's retained config-floor + D3 wrapper engine unchanged.)
> **Migration status (ADR-029, 2026-07-10):** This ADR is evolved by [ADR-029](ADR-029-msb-migration.md) — DCG-as-recipe survives wholesale; D2's floor list moves to the lockstep msb floor list; the "DCG, ssh-bypass" sibling pairing retires (ssh-bypass retires per ADR-029 D3, DCG survives). D1/D3/D4/D5 are otherwise untouched. The msb cutover has landed (S1-S14, branch `wave/s13-docs` off `msb-cutover`) — the mechanisms below are retired/replaced per the dispositions above; this ADR is retained for historical record, not current behavior. See [ADR-029](ADR-029-msb-migration.md) for what replaced them.

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

**Scope limitation (known, accepted):** translation runs on the `rc up` (CLI/headless) path only. The `rc init` → VS Code "Reopen in Container" devcontainer path uses a static `devcontainer.json` and does **not** translate custom `dcg.*` — devcontainer users get the baked core floor but not their additive host policy. The **floor is intact on both paths** (the baked default config + wrapper ship in the image); only the additive feature is absent on the devcontainer path. Not pursued (deprioritized 2026-06-02 — devcontainer adoption is not a priority surface).

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

### D2: DCG is a composable, default-on safety recipe — its CONFIG floor (additive-only, can't downgrade core) stays uncrossable for whoever runs it (revised 2026-06-17)

> [ADR-029 D2, LANDED: DCG-as-recipe survives wholesale; the demotion this decision made (DCG is a composable recipe, not welded floor) needed no further change at the msb migration. **Lockstep floor list (ADR-029 D2, replacing the enumeration below, post-cutover):** the microVM boundary itself; msb default-deny egress + net rules; msb DNS default-deny; `--secret` credential non-possession (ADR-029 D5); the secret-path mount denylist (ADR-023); the `.git/hooks` read-only weld (ADR-002 D11); and the in-guest floor items (root-owned guard artifacts, scoped sudo, ro mounts). The ADR-012/ADR-022 mechanisms are retired, not shipped. This exact list is duplicated in lockstep across ADR-005 D9, ADR-025 D2 (here), and [ADR-026](ADR-026-containment-mediation-identity.md) D2. **Sibling-pairing note (struck):** this decision's framing of DCG alongside its command-string-guard sibling (ssh-bypass, per ADR-002 D5's "DCG + block-ssh-bypass.sh remain the command-string guards") no longer holds symmetrically — ssh-bypass, `block-ssh-bypass.sh`, and `examples/ssh-bypass/` are deleted per [ADR-029](ADR-029-msb-migration.md) D3, while DCG survives as a recipe. No literal "DCG, ssh-bypass" enumeration string exists in this file's body to strike; this note covers the pairing conceptually wherever this ADR's framing implicitly assumes both guards persist together.]

**Firmness: FIRM** (revised 2026-06-17 — wlwc / [ADR-027 D2/D3](ADR-027-agent-substrate-projection.md), [ADR-026 D1/D2](ADR-026-containment-mediation-identity.md): DCG is **no longer part of the welded uncrossable floor**; that floor is now CONTAINMENT. DCG becomes a composable default-on recipe. The two properties this decision RETAINS — DCG's config floor is additive-only and cannot downgrade core, and the dcg-guard wrapper/engine of D3 — are unchanged; what changed is that *running DCG at all* is composed, not welded. Verification mechanism clarified 2026-06-25 — rip-cage-wiwa: `rc test` now runs recipe-carried behavioral smoke tests via a generic name-free runner; guard-named probes are no longer baked in the core in-cage suite.)

**The welded uncrossable floor is CONTAINMENT, not DCG.** Per [ADR-026 D1/D2](ADR-026-containment-mediation-identity.md) (rip-cage IS containment; layers sort by drift-rate) and the wlwc reclassification, the always-on never-composable floor is the agent-agnostic containment layers — container boundary, egress destination-control + IOC denylist + DNS exfil (ADR-012 D1), fs sandbox, non-root + scoped sudo (ADR-002 D12), the secret-path mount denylist (ADR-023), the `.git/hooks` RO weld (ADR-002 D4), and the ssh known_hosts/config mount floor (ADR-022 D4). A **command-string classifier like DCG is high-drift, harness-specific policy** — it sits *above* the containment line as a default-on accident-guardrail (ADR-002 D5), not at it. DCG is therefore demoted to a **composable, default-on safety recipe** built from three ordinary pieces: (i) the `dcg` binary added via the tool manifest (ADR-005 D7); (ii) the **guard wiring** (the CC PreToolUse hook entry / pi extension that invokes the dcg-guard wrapper) delivered at an **agent-unwritable load path** (ADR-027 D1); (iii) a recipe binding them, shipped **enabled by default for bundled agents** (CC, pi) and asserted on by `rc test`.

**Verification mechanism (clarified 2026-06-25 — rip-cage-wiwa):** `rc test` verifies this recipe in two layers: (a) a generic presence-assert (`_run_asserted_checks`, rip-cage-m8zc) fires for each required tool declared in the asserted-file; (b) the **generic name-free runner** (`run-recipe-smokes.sh`) globs `/usr/local/lib/rip-cage/recipe-tests/*.sh` and runs every recipe-carried behavioral smoke test present. The DCG recipe's behavioral smoke test (`examples/dcg/smoke.sh`) is installed by the recipe's `install_cmd` into the recipe-tests dir as root:root (ADR-027 D1 write-gate floor) and covers the full behavioral depth: deny-probe, wrapper CWD-anchor, user-layer suppression, sensitivity proof, additive-rule-fires, chaining-robustness, and pi-conditional guard-parity checks. Guard-named behavioral probes are **no longer baked in the core in-cage suite** (`tests/test-safety-stack.sh`) — the core suite carries only name-free floor assertions (managed-settings layer-placement, `.git/hooks` RO weld, generic drop-assert). This preserves user-facing behavioral coverage: a downstream user who composes the DCG recipe and misconfigures it gets a RED `rc test` (the in-cage runner catches it), not a false-green.

**Uncrossable-from-inside is PRESERVED in the `ro`-default config** (ADR-027 D1) by two independent mechanisms, so the ADR-024 prompt-injection threat is still met without welding DCG into the image: the guard wiring is at an **agent-unwritable load path** (managed-settings for CC / baked-root-owned for pi / `ro`-mounted for host-supplied agents — cannot be edited or suppressed from inside), AND **which** guards a cage runs is composed **host-side at `rc up`** (an in-cage agent cannot re-compose a running cage; `rc reload` is the human-gated change point). What is traded away is "welded into the image, unremovable even by the host operator" — and operator removal is the human-approval point, not a threat.

**Two RETAINED properties (unchanged by the demotion):**
1. **The DCG config floor is additive-only and cannot downgrade core.** For whoever runs DCG, host and workspace config can only ADD coverage above the baked core packs (`core.git` / `core.filesystem`); they cannot disable a core pack or downgrade its deny to warn/log, exactly as `network.allowed_hosts` cannot shrink the egress IOC floor (ADR-012 D1) and `mounts.denylist` cannot remove a global default pattern (ADR-023 D2). Two layers deliver this config floor: DCG's own built-in guarantees (the `core` category is force-enabled — `config.rs:946-947` — and Critical-severity rules resist pack-level/global downgrade), plus the operational enforcement in D3 that closes the agent-writable config weakening vectors (`/workspace/.dcg.toml`, `~/.config/dcg/config.toml`).
2. **The dcg-guard wrapper/engine (D3)** — CWD-anchor + `DCG_CONFIG` pin + env-strip — stays rip-cage-owned as the recipe's engine.

**Required FIRM inline counter-argument (rebutting the original "a safety floor a project can lower is not a floor"):** The original D2 rationale held that a floor a project can lower is not a floor, and welded DCG into the image to make that true. That warrant is now satisfied differently and more honestly: (a) the welded floor is **containment** — the thing that genuinely cannot be agent-variable — and DCG was always an **accident-guardrail above containment** (ADR-002 D5 frames the command-hook layer as "default-on, not an adversarial boundary"), so welding it conflated two tiers; (b) DCG-as-recipe is still **uncrossable from inside the `ro`-default cage** via the unwritable load path + host-side composition (ADR-027 D1) — a project (or prompt-injected agent) still cannot lower it from within the cage, which is the property the original rationale actually needed; (c) welding it forced bespoke per-agent floor-lock machinery (the olen root-own-dir for pi; the planned r9n4 second snowflake for CC) that did not generalize and conflicted with `rw` self-improvement (ADR-027 D1). So "a project can't lower it" is preserved; "the *operator* can't remove it" is consciously given up, because operator removal is the human-approval point, not the ADR-024 threat. ADR-024 D2 (on-device-harm symmetry) remains the threat warrant for the in-cage uncrossability — now delivered by the recipe's unwritable wiring, not by welding.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Keep DCG inside the welded uncrossable floor (status quo, original D2) | `reasoned:` a command-string classifier is high-drift harness-specific policy (ADR-026 D2), not containment; welding it forced bespoke per-agent floor-lock machinery (olen for pi, the planned r9n4 snowflake for CC) that does not generalize and conflicts with `rw` self-improvement (ADR-027 D1). The in-cage uncrossability the weld delivered is preserved by the recipe's unwritable load path + host-side composition. |
| Let projects fully replace the policy (including disabling core) | `reasoned:` Directly defeats the guard's purpose under the ADR-024 threat model — an injected agent writing project config would disable the floor. The retained DCG config floor (additive-only) and ADR-002 D12 (scoped sudo) forbid it. |
| Config floor = DCG built-ins only; accept the config weakening vectors | `direct:` DCG v0.4.0's built-in floor is partial — `overrides.allow` (checked first, no severity guard, `evaluator.rs:1229-1232`) and `[policy.rules]` per-rule downgrade bypass even Critical core. The operational enforcement (D3) is required to make the config floor real. |
| Drop the command-guard entirely now that it's not welded floor | `reasoned:` it remains a valuable default accident-guardrail (ADR-002 D5); demote to a default-on recipe, do not delete. |

**What would invalidate this:** If the agent-unwritable load path + host-side composition turn out NOT to be uncrossable from inside the `ro`-default config (e.g. an agent can `sudo umount` a guard mount; the `ro`/`rw` scheme forces a new `mount`/`umount` sudo grant that reopens it; a runtime re-composition path from an agent-writable source exists), the in-cage uncrossability basis fails and DCG-as-recipe no longer meets the ADR-024 threat in the default config. OR routine legitimate workflows need to *remove* a core rule (not just add around it) with no additive expression → reconsider a narrowly-scoped cage-owned override. Signal: users repeatedly forced to fork the image to drop a single core rule, or an enumerated in-cage disable path that survives the unwritable-path + host-composition lock.

### D3: Floor enforced operationally (CWD-anchor wrapper + pinned valid `DCG_CONFIG` + env-strip), not by patching DCG

> [ADR-029: UNAFFECTED-mechanism-prose-updated — untouched by the migration in decision content; the cage-owned RO config file this decision pins via `DCG_CONFIG` is delivered via a read-only mount, and that ro-mount delivery mechanism needs to re-verify on msb virtiofs (scoped macOS/HVF per ADR-029 D6 until Linux/KVM reconfirmation), same as every other ro-mount floor item.]

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
- **Tests** (`tests/test-safety-stack.sh` + the pi test path): (a) an added rule causes both a Claude Code cage and a pi cage to refuse a newly-covered command; (b) a hostile `/workspace/.dcg.toml` disabling core / downgrading `rm -rf /` to warn does NOT weaken the guard (floor holds); (c) a hostile `~/.config/dcg/config.toml` with a wildcard `overrides.allow` does NOT weaken the guard (user-layer suppressed); (d) no-host-config cage still ships the core floor; (e) malformed translated config fails `rc up` closed. The floor-uncrossable regression (b)/(c) runs on the Claude Code path in rip-cage-hhh.11; the pi-cage-path regression rides with rip-cage-bl1 (which routes pi's `dcg-gate.ts` through the wrapper), sequenced last.
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
