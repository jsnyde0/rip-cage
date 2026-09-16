# ADR-031: rip-cage is an opinionated distribution of microsandbox

**Status:** Accepted — 2026-09-15, epic `rip-cage-ely4.7`; decisions human-ratified in-pane over two brainstorm sittings (`rip-cage-ely4`, 2026-09-14 and 2026-09-15) after two adversarial review rounds. This ADR is the canon; the code children of `rip-cage-ely4.7` implement it.

**Firmness:** per-decision, see each Dn. D1, D2, D4, D5, D7 are FIRM; D3 is split (the rule FIRM, the verb set FLEXIBLE).

**Citation form:** this repo's ADR numbers collide with the global methodology corpus across the whole low range — both corpora run from ADR-001, so a bare `ADR-011` is genuinely ambiguous (shell completions here, the in-place-evolution rule there), and so is `ADR-013`, `ADR-008`, and every other number both corpora use. Every citation below therefore carries its corpus prefix — `rip-cage ADR-NNN Dk` or `dotclaude ADR-NNN Dk` — or is a markdown link to the file, per dotclaude ADR-008 D9.

## Context

microsandbox (msb) 0.6.18 ships natively what rip-cage was positioned on: microVM isolation, default-deny egress and DNS at the VM boundary, destination-bound `--secret` credential non-possession, read-only mounts, and a sparse YAML config. rip-cage ADR-029 called this move "contribution moves up a level" (D2) at the Docker→msb cutover; this ADR is the next step of the same move, stated as an identity rather than a migration.

The evidence is a stamped honest assessment (`rip-cage-ely4.1`): rip-cage's whole daily drive was reproduced on plain msb in about twenty minutes from a nineteen-line native config. Four of the README's claimed differentiators collapsed — credential non-possession is msb's `--secret`, skills projection is two mount flags, session continuity is `msb create --replace` with the same mounts, and the read-only policy file is a `:ro` suffix. A thirteen-project landscape survey (2026-09-14) found the headline "local microVM for coding agents" already owned by Docker Sandboxes and by msb itself, and found five territories nobody claims: the denial→fix→relaunch repair loop, a suite that proves the sandbox's own claims on the operator's composed image, credential discovery from host stores, an operator-facing fleet on one box, and prompt injection as the organizing principle.

The honest name for what remains is a **distribution**. A Linux distribution does not write the kernel; it picks a kernel, curates what ships on top, and takes a position on how the pieces fit. rip-cage stands in that relation to msb. This is not a pivot — it is the subtracted thing named accurately, and the subtraction is the work the rest of `rip-cage-ely4.7` does.

**Decision numbering.** D1–D5 and D7 below carry the epic `rip-cage-ely4.7`'s decisions of the same numbers, one-to-one, so a citation of "epic D4" and a citation of "rip-cage ADR-031 D4" name the same decision. The gap at D6 is deliberate: the epic's D6 (three skills — `cage-config`, `cage-image`, `cage-ops`) is FLEXIBLE product-surface shaping, not a cross-cutting load-bearing decision, and stays in the epic and its child `rip-cage-ely4.13`. The epic's D8 (roadmap) is EXPLORATORY fog and stays there too.

**Why a new file rather than an in-place edit.** dotclaude ADR-008 D7's five-dimension overlap scan was run before this file was created (fresh-context, 2026-09-15). It scored **5/5 against rip-cage ADR-021** and recommended folding in, on the ground that D2 below is a direct reversal of rip-cage ADR-021's three-layer merge, provenance view and write verbs. That recommendation is recorded and **not taken**, for two reasons: (1) a *reversal* is not shared decision space — rip-cage ADR-021 answers "how do rip-cage's own config layers compose", which is a question this ADR deletes rather than re-answers; and (2) rip-cage ADR-021 **retires whole** under D2 below, so folding a six-decision positioning record into it would home live canon inside a retired document. The new-file-at-the-next-free-number choice is the one recorded in `rip-cage-ely4.8`'s decision list, filed out of the ratified brainstorm; it is a filing decision made there, not separately ruled on by the human, and is noted as such rather than claimed as a human ruling. The scan's residual point is honored instead: rip-cage ADR-021's row and Status line state the retirement and point here, so a reader who lands on the old model is one hop from the new one.

## Terms

Defined once here; this ADR is the term home until the repo grows a glossary file.

- **Distribution** — a published base image plus one native msb config per project plus a small launcher plus skills plus a proving suite. rip-cage curates and takes positions; msb provides the isolation primitive. rip-cage never reimplements what msb ships.
- **Composition inputs** — the three artifacts an operator (or the agent acting for them) authors to define a cage: the Dockerfile that extends the base image, the boot descriptor, and the project's msb config file. All three live host-side, outside every cage mount (D5a).
- **Boot descriptor** — one small declarative file, read by init's existing generic loop, naming long-running processes to start (`daemons`: start / health / state_dir) and multiplexer providers (`multiplexers`: start / attach, plus an optional `launch` field). It is what keeps base init tool-agnostic once the manifest is gone.
- **Floor probe** — a fail-closed check of the containment floor **on the built image**, run by init at boot and by `rc test`. It inspects the artifact (non-root agent user, sudo scope, release-marker mode and owner, git-hooks deny entry, PATH order, guard files root-owned and not world-writable, and so on), never a declaration describing the artifact.
- **Protected paths** — a plain list file of known credential locations (ssh, cloud, gpg, kube, env files) that rip-cage ships as default configuration and the operator may edit. It is data, not code, and it drives one rule at `rc up` (D2).

## Decisions

### D1: Identity — rip-cage is an opinionated distribution of msb for coding agents

**Firmness: FIRM**

rip-cage is a published base image + one native msb config per project + a small launcher + skills + a proving suite. Isolation and credential non-possession are **credited to msb by name**, everywhere rip-cage describes itself. The README carries a permanent two-column "what msb provides / what rip-cage adds" table, and never again claims the four differentiators that `rip-cage-ely4.1` collapsed.

Three opinions carry the positioning, and they are the thing rip-cage is actually selling:

1. **Credentials are discovered where you keep them, and never enter the VM.** Today that is the Claude login pulled from the macOS keychain and handed to msb's `--secret`; generalizing the discovery to other stores is roadmap, not claim.
2. **A blocked host becomes a one-line fix.** The denial trace is mined into the exact config line to add; the repair loop is short enough that default-deny egress stays livable.
3. **The cage proves itself.** The proving suite runs against *your* composed image, not against a reference image someone else built.

The buyer is a developer running Claude Code or pi with permissions off, on their own machine.

The two-column table is canon, not decoration: **msb provides** the microVM boundary, default-deny egress and DNS, `--secret` non-possession, read-only mounts, recreate-with-the-same-mounts, and the config schema. **rip-cage adds** the curated agent image and its init, the keychain→`--secret` credential bootstrap, the denial→fix→relaunch repair loop, the floor probe, the proving suite, and the operating knowledge in the skills — the survivor list `rip-cage-ely4.1` left standing. **Session continuity is deliberately absent from the right-hand column:** it is `msb create --replace` plus the same mounts, which is one of the four differentiators the assessment collapsed, and putting it back under "rip-cage adds" is the exact claim this decision forbids.

**Rationale:** `direct:` `rip-cage-ely4.1` (stamped) — what survives the collapse is "closer to a curated, tested, opinionated setup that already knows the answers" than to a product with its own isolation technology. `external:` the 2026-09-14 landscape survey — the microVM headline is owned territory, while all three opinions above are unclaimed. `reasoned:` naming the subtraction honestly is cheaper to maintain than defending four claims that a twenty-minute reproduction defeats.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| "Unattended-agent host / fleet" as the vision | `reasoned:` unattended-for-days is orchestration, which is dotpi's territory, not VM technology. The cage-level slice of it is one property, stated once, not a vision. |
| "Provable cage" as the vision | `reasoned:` a feature, not a vision — msb tests msb, rip-cage tests the composed cage. Kept as opinion 3 rather than promoted. |
| "Your workflow, caged" | `direct:` `rip-cage-ely4.1` collapsed it to two mount flags. |
| docker-compose analogy ("rip-cage is compose for sandboxes") | `reasoned:` holds for verb shape, fails on topology — and msb 0.6.18 has no Composefile or `msb compose` (six reserved keys and one reverted attempt), and sandboxes cannot reach each other by name. Parked until a project needs a second sandbox. |
| Keep the four differentiators and argue them harder | `direct:` `rip-cage-ely4.1` reproduced each on plain msb; defending them would be a false claim in the README. |

**What would invalidate this:** upstream msb ships a distribution of its own for coding agents (an agent image + recipes + denial diagnostics), which would leave rip-cage curating nothing; or credential discovery proves infeasible beyond the Anthropic token, which would take opinion 1 down to a single-vendor trick and force a re-argument of the three opinions.

### D2: One native msb config file per project is the whole project config

**Firmness: FIRM** (the FIRM-to-FIRM mutation of rip-cage ADR-021 this implies was signed off by the human in-pane on **2026-09-14**, sitting 1 — "ADR-021 D1/D2/D4/D8 must be evolved … human said yes in-pane"; the protected-paths half was ratified 2026-09-15)

The project file is msb's own `--conf` schema. It is produced by the `cage-config` skill from a template rip-cage ships — image, resources, the mount set that makes sessions survive a recreate, the curated allowlist, and the mount lines that cover the usual secret files inside a mounted project. The file **is** the consolidation: it carries its lists in full, and `rc` merges nothing.

Retiring, as a consequence: the rip-cage config schema, the three-layer merge, the provenance view, the `rc config` and `rc allowlist` verbs, `rc.conf`, and the allowed-roots guard (there is nothing left to guard once every mount is an explicit line). DCG policy is the DCG recipe's business and was never `rc`'s. The msb-flag generator (`cli/lib/msb_flags.sh`) survives as the launcher's core, still bound by rip-cage ADR-029 D3 and D5 on multi-host `--secret` naming.

One **protected-paths** rule, shipped as default *configuration*, not as code. `rc up` reads the list file and:

- (a) **refuses to launch** a config that mounts any listed path directly;
- (b) **auto-covers** any listed path found inside a mounted tree — a file gets an empty read-only file mount, a directory gets an empty tmpfs mount;
- (c) **aborts before any msb call** if the list file is unreadable.

If msb cannot express the cover for a given entry, `rc up` refuses rather than proceeding — fail closed, never fail open. Same list, one rule. The list is an operator-editable default, not a hardcoded constant (human-ratified 2026-09-15).

**Amended in place 2026-09-15 (`rip-cage-ely4.9`, ruled by `brain:rip-cage` on a driver raise): credential bindings live in the config's `secrets:` block; the value never does.** Retiring the rip-cage schema deleted `auth.credentials`, the only declarative home for the credential→host binding that [ADR-029](ADR-029-msb-migration.md) D3/D5 makes a floor property — and the obvious replacement looked unavailable, because msb's native `secrets:` schema has a `value:` field and putting a secret in an operator-edited file is the opposite of non-possession. Measured on msb 0.6.18 (probe verbatim in `rip-cage-ely4.9`'s notes): **omit `value:` and the field is inert** — msb records `source: {kind: env}` and resolves the real value from the host variable of the same name at boot, while the guest holds only the `$MSB_<NAME>` placeholder on disk, in its environment and in `/proc`. So the binding is native after all: `hosts` becomes `secrets.<NAME>.allow`, `target_env` becomes a line in the config's own `env:` block, and the env-var name is the key itself. One field has no native home — `source_file`, which existed so an unattended `rc up` needs no pre-exported variable. `rc` keeps that autonomy by convention over its own config location rather than through any schema: it reads the value from `$XDG_CONFIG_HOME/rip-cage/secrets/<NAME>` when that file exists, which is the same D5(a) class as the protected-paths list. This corrects `rip-cage-ely4.1`'s Part A table, which rated the `--secret` family "partial" on the assumption that a config-file binding must carry its value.

**Rationale:** `direct:` human, 2026-09-15 — "layering is a vitamin", "not a fan of transpiling", "a project file is the consolidation". `direct:` msb overlays `--conf` files per field but **replaces lists**, so a defaults file plus a project overlay would silently drop the session mounts and the allowlist — the worked example is in `rip-cage-ely4`'s notes. Two files buy nothing. `direct:` `rip-cage-ely4.1` — native layering is lossy on lists, so any layering rip-cage offered would be rip-cage's own merge engine wearing msb's schema.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Keep the rip-cage schema + the three-layer merge | `reasoned:` it is a transpiler — rip-cage would maintain a second config language whose only job is to emit msb's. |
| A host-side `rc`-scoped config file for `rc`'s own knobs | `direct:` human struck it in-pane 2026-09-15 — DCG policy belongs to the recipe, secret masking is a mount line, and allowed-roots has no job left. Nothing remained to put in the file. |
| Floor config file + project overlay, both native msb `--conf` | `direct:` msb replaces lists rather than merging them, so the floor's session mounts and allowlist vanish the moment a project file declares its own. |
| Hardcode the protected-paths list in `rc` | `reasoned:` a list of credential locations is data that drifts per operator; freezing it in code makes every new store an `rc` edit, against rip-cage ADR-005 D12. |
| Drop the protected-paths rule and teach it in the skill instead | `reasoned:` the rule is mount-side containment floor — it is what stops a config from showing your ssh keys into a cage. A floor taught by documentation is not a floor. |

**What would invalidate this:** msb ships **additive** list merge (not replace) *and* operators want host-wide defaults — a two-file shape may then return through the `cage-config` skill, never through merge code in `rc`. Separately, if the protected-paths rule starts refusing legitimate configs often enough that the right response is "just turn it off", the default list is wrong and D2's list contents (not the rule) come back for re-argument.

### D3: The CLI thins to six verbs

**Firmness: FIRM (the rule) / FLEXIBLE (the set)**

**The rule, FIRM:** a verb exists only where plain shell plus a skill cannot do the job identically every run.

**The set, FLEXIBLE:** `rc up`, `rc auth`, `rc doctor`, `rc build`, `rc test`, `rc destroy`.

- **`rc up`** — the keychain→`--secret` bootstrap, the flags no config file holds (`--name`, `--log-level trace`, `--replace`, the symlink-parent read-only mounts computed from the host filesystem, the protected-paths check), then `msb create`, then attach. **`rc reload` folds into `rc up`**: a *stopped* cage is recreated against the current config on a plain `rc up` (today's converge-on-up behavior); a *running* cage is never recreated implicitly, because that kills the live session (rip-cage ADR-029 D4) — `rc up --replace` is the explicit graceful-stop-then-recreate.
- **`rc auth`** — pulls the Claude login from the macOS keychain, and standalone re-applies a refreshed token to an existing cage without the operator recreating it by hand. *(Whether msb applies a secret change to a live sandbox or only on restart is still open — spike `rip-cage-ely4.16` Q5. The verb exists either way; only how quiet the re-apply is depends on the answer.)*
- **`rc doctor`** — mines the trace log for denied hosts and prints the exact config line to add.
- **`rc build`** — `docker build` of a host-side Dockerfile, then load into msb's image cache.
- **`rc test`** — the proving suite, including the floor probe.
- **`rc destroy`** — the cage plus the named volumes `rc` created; `msb remove` alone orphans them.

Deleted: `ls`, `attach`, `exec`, `down`, `allowlist`, `config`, `schema`, `completions`, `setup`, `manifest`, `install`, `generate-dockerfile`. For each, the `cage-ops` skill is the sole home of either its msb one-liner (`ls`, `attach`, `exec`, `down`) or the plain statement that it has no successor (`config`, `schema`, `setup`, `allowlist`: edit the file; `manifest`, `install`, `generate-dockerfile`: retired with the manifest). An unknown verb prints plain usage and exits 1. The first-run interactive prompt is deleted outright — agent-first means no prompts. `--dry-run` behavior is unchanged by this ADR (it prints and falls through; exit codes are refactor work).

The agent-first contract on the surviving verbs — `--output json` everywhere, an exit-code table, an ANSI/stderr policy, machine-readable errors — is **refactor** work under D7 stage 2 (`rip-cage-sygz`), not subtraction. rip-cage ADR-003 D1 is honored, not weakened.

**Rationale:** `external:` the `design-claude-extension` CLI-design guidance — knowledge belongs in the skill, workflows belong in recipes, and only determinism belongs in the CLI. `reasoned:` every deleted verb is either a one-line msb command an agent can run directly, or a wrapper around editing a file — and a wrapper that adds nothing costs a surface to document, test and keep honest. The six that stay each do something shell cannot do identically every run: reach the keychain, compute mounts from the host filesystem, mine a trace log, build-and-load, prove the floor, or clean up state msb does not know it owns.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Keep the pass-through verbs for convenience | `reasoned:` convenience never earns a seam exception — rip-cage ADR-005 D12. A pass-through is a second way to do the thing, which drifts from the first. |
| Fold `rc auth` into `rc doctor` | `reasoned:` refreshing a credential on a live cage without recreating it is a distinct *action* an unattended agent needs; `doctor` is diagnostic. Merging them makes a mutating operation hide inside a read-only-sounding verb. |
| Keep `rc completions` / `rc setup` | `reasoned:` what they complete is mostly being deleted — `completions/rc.bash` declares fifteen subcommands and `rc` dispatches nineteen, of which six survive, and the container-name completion they also offered is now an msb one-liner. A completion surface for six memorable verbs earns less than it costs to keep honest. (Not among the epic's own enumerated alternatives; recorded here because the verb is deleted and a reader will ask.) |
| Thin to fewer than six by dropping `rc test` | `reasoned:` opinion 3 in D1 *is* the proving suite; deleting its entry point deletes the opinion. |

**What would invalidate this:** the rule fires the wrong way — an operator or agent repeatedly reaching for a shell incantation long enough to get wrong, which is the cue that it should have been a verb. Conversely, a surviving verb whose body reduces to a single msb call after the refactor has stopped earning its place. Either cue re-opens the *set*; the rule itself only falls if `rc` stops having a skill alongside it.

### D4: The tools manifest retires; base-image extension plus one boot descriptor replace it

**Firmness: FIRM** (human-ratified 2026-09-14 after a three-agent design-it-twice pass)

Users extend the published base image with `FROM ghcr.io/jsnyde0/rip-cage:latest` in their own Dockerfile. Deleted: `tools.yaml`, the `rc build` codegen, the manifest validator, reconcile and seed-drift, the build-flag allowlist, and the manifest test corpus — roughly 4,344 lines of implementation plus 12,238 lines of tests plus 1,200 further lines, spanning about 80 hostile fixtures.

**One** small declarative **boot descriptor** stays (`daemons`: start / health / state_dir; `multiplexers`: start / attach), read by init's existing generic loop. That loop is the invariant that keeps base init tool-agnostic, which is what rip-cage ADR-005 D12 was protecting all along. A recipe becomes a Dockerfile snippet plus a boot-descriptor fragment.

The per-tool launch wrapper that `rc build` used to assemble from manifest `launch_args` (rip-cage ADR-027 D4) moves into the base image for `claude` and `pi`, and into the descriptor's optional `launch` field for extensions. The mechanism evolves; rip-cage ADR-027 D4's FIRM principle — no hardcoded cross-recipe paths in any launch leg — is honored unchanged.

**Rationale:** `direct:` the retire-steelman found that 16 of the 22 commits touching the manifest seam are fixes, and that the validator "exists to simulate the review a real Dockerfile diff gets for free". `direct:` the hybrid agent's counter — free-form boot scripts would grow tool-specific branches inside base init (exactly the D12 drift the manifest prevented), and the multiplexer contract genuinely needs two hooks — is why the boot descriptor survives rather than everything collapsing into the Dockerfile. `direct:` premise correction from the human, 2026-09-14: **no human reviews builds** — agents author the Dockerfile, so a validator that simulates human review is simulating a reviewer who does not exist. D5 is what replaces it.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Keep the manifest as-is | `direct:` the keep-steelman's strongest argument was host-only authoring — which is about *location*, not *format*, and is preserved intact by D5(a). |
| Retire the manifest and add an advisory Dockerfile linter | `reasoned:` a second surface for agents to learn, checking the same floor the probe on the built image checks directly and more honestly. |
| Retire the manifest with no boot descriptor (free-form init scripts) | `direct:` the hybrid agent's finding — tool-specific branches migrate into base init, and the multiplexer contract's start/attach pair has nowhere to live. |
| Keep the validator, drop the rest of the manifest | `reasoned:` the validator's input was the manifest's declarations; without them it has nothing to validate but a description it cannot check against the artifact. |

**What would invalidate this:** the floor probe fires on legitimate extension images often enough that the right human response is "just turn it off". That is the cue that the artifact-side check is mis-specified, and it re-opens the declaration-side alternatives.

### D5: What keeps the floor honest without a human in the loop

**Firmness: FIRM**

**(a) Composition inputs live host-side, outside any cage mount.** The Dockerfile, the boot descriptor, the msb config and **the protected-paths list** are all authored where the caged agent cannot reach them. This was the manifest's real security property, and it is preserved as a *location* rule rather than a format.

**Amended in place 2026-09-15 (`rip-cage-ely4.9`, implementing D2).** The protected-paths list is the **fourth** composition input, not a fifth kind of thing — it was left unnamed when this decision was written and [ADR-023](ADR-023-secret-path-mount-denylist.md) D2 flagged the gap rather than assuming an answer. It is named here now: `rc up` reads the list only from its own install directory or the operator's host config directory, never from a path any cage config can point at. The reason is the same one that puts the other three here — a caged agent that could edit the list could delete the line protecting the thing it wants, which would make every other mount-side rule advisory. Implementation: `cli/lib/protected_paths.sh`, whose resolution order is `$RC_PROTECTED_PATHS`, then `$XDG_CONFIG_HOME/rip-cage/protected-paths`, then the shipped default beside `rc` itself. The same run also enforces the location rule *on the msb config*: a config that resolves inside a tree it mounts is refused before any msb call.

**(b) A fail-closed floor probe on the BUILT image** runs in init at boot and in `rc test`, replacing the declaration validator. It checks the artifact: non-root agent user, sudo scope, release-marker mode and owner, git-hooks deny entry, pinned ssh key, PATH order, guard files root-owned *and* not world-writable, the `bd` wrapper, `python3`, and the mise trust path. The 2026-09-14 image-floor audit sized this at 14–16 checks, about 9 of them liftable verbatim from `tests/test-safety-stack.sh` and init, for roughly 80–120 new lines.

**(b) REALIZED 2026-09-16 (`rip-cage-ely4.12`) — the shipped check list, and where it differs from the sizing above.** The probe is `cage/floor/floor-probe.sh`, baked root:root 0555, run by init before any other work and by `rc test` before any other suite, with no opt-out. The list above was an audit *sizing*, not a specification, and three items resolved differently once written against the artifact. **`agent-home` was added**: asserting a non-root user is not enough, because a `USER <anyone>` extension boots silently with `$HOME` elsewhere while all twenty host mounts stay stranded at `/home/agent` — the home check names the real damage and catches more cases (`rip-cage-ely4.16` Q2). **PATH order became PATH *resolution*, in the interactive shell**: presence on `PATH` proves nothing when an extension's `ENV PATH` prepend shadows `/usr/local/bin` in the login zsh, so the check asserts each floor wrapper resolves to the floor's own file, resolved through `zsh -i` (`rip-cage-ely4.16` Q3). **The pinned ssh key stays on the list, its fingerprint does not** — see the dated note on [ADR-029](ADR-029-msb-migration.md) D3 for why the two static ssh files are floor under HTTPS+`--secret` and why pinning a value upstream may rotate would make this probe fire on a legitimate image. Nothing here asserts read-only-ness from a mount table: `mount -o remount,rw` returns 0 and flips the guest table while the write still fails `EROFS`, so only an attempted write proves it (`rip-cage-ely4.16` Q1), and mount modes are (d)'s half anyway. The probe's own file header carries the full list with the `cage/Dockerfile` line each check guards.

**(c) `rc build` accepts exactly one user input** — the host-side Dockerfile path, which must resolve outside every cage mount, fail-closed with no opt-out — and passes docker exactly `-f <path> -t <tag> <context>`, nothing else.

**Clarified in place 2026-09-16 (`rip-cage-ely4.11`, brain ruling on a raise).** "Nothing else" governs **caller-reachable** argv. The exact argv docker receives is `-f <path> --build-arg RC_VERSION=<read from the VERSION file beside rc> -t <tag> <context>`. `RC_VERSION` is rc-supplied and never caller-supplied, so it is part of the fixed argv rather than an exception to it; the version label it bakes exists because [ADR-008](ADR-008-open-source-publication.md) D6's staleness check reads it, and dropping it would make every locally built image read stale and send `rc up` into a re-provision on every launch. `-t`'s value is rc's own `$IMAGE`, with `RC_IMAGE` the documented test-only override — `rc build -t` is rejected like every other caller flag.

**(d) The protected-paths rule (D2) is the mount-side floor.** It is what stops a config from showing your ssh keys into a cage. (b) guards what is *in* the image; (d) guards what is *mounted into* the cage; together they are the floor that no human review backstops.

**Rationale:** `direct:` the image-floor audit — everything else in the floor is either msb config emitted by `rc up` (egress, DNS, secrets, read-only mounts) or the protected-paths rule in `rc up`, which runs before the cage exists. No Dockerfile line can touch either, which is precisely why the remaining exposure is image *content*, and why the check has to be on the built image. `reasoned:` a check that reads a declaration can be lied to by the declaration; a check that reads the artifact cannot.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Keep the declaration validator | `reasoned:` it checks a description, not the artifact — it cannot see a `USER root` the Dockerfile ends with. |
| Let `rc build` pass through the caller's docker flags | `direct:` rip-cage ADR-005 D14's worked example — `--build-arg BUILDKIT_SYNTAX=<image>` swaps the Dockerfile frontend, so admission is a value-level question and a name-level allowlist is not a floor. Fixed argv is the only shape that holds. |
| Run the floor probe only in `rc test`, not at boot | `reasoned:` a probe the operator must remember to run is not fail-closed; a broken image would boot and serve an agent before anyone looked. |
| Allow an opt-out for the host-side Dockerfile-path rule | `reasoned:` the opt-out is the vector — a caged agent that can point `rc build` at a path it controls has written its own image. |

**What would invalidate this:** the probe's check list drifting out of step with the image (a floor property added to the Dockerfile and not to the probe) shows up as a real containment gap surviving a green `rc test` — that is the cue that the probe needs a coupling rule, not just more checks. And, as in D4, a probe that fires on legitimate images often enough to invite disabling is mis-specified.

### D7: Sequence — subtract, then refactor, then dogfood, then publish

**Firmness: FIRM**

Publication waits for three things in order (the publication *mechanics* — versioning, the CI gate, the release ceremony — are rip-cage ADR-008's and are untouched by this decision; D7 only says when that ceremony may start): the subtracted codebase (the code children of `rip-cage-ely4.7`), a refactor pass against Unix design (`rip-cage-sygz`, re-planned on this outcome — stage 2, where the agent-first CLI contract from D3 lands), and days of the human's own dogfooding on the thinned product. The README, ADR and ROADMAP prose lands on the thinned product, not on today's code. Dogfood-and-publish is its own child (`rip-cage-ely4.17`), human-owned, with a checkable done-condition.

**Rationale:** `direct:` human, 2026-09-15 — "(b) subtract first … test drive the hell out of it … then publish". `reasoned:` prose written against code that is about to be deleted is prose that has to be written twice, and a release tag on an undogfooded subtraction is the most expensive place to discover the subtraction went too far.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Publish the positioning first, subtract after | `direct:` human ruled for (b) in-pane. `reasoned:` the README would describe a product that does not exist yet, which is the exact failure this repositioning is correcting. |
| Skip the refactor stage, dogfood the raw subtraction | `reasoned:` the agent-first contract was deliberately moved out of the subtraction children into the refactor stage; dogfooding before it lands would measure the wrong surface. |
| Skip dogfooding, gate publication on the test suite alone | `reasoned:` the suite proves the floor, not the ergonomics — and "it's annoying" is the design signal this project explicitly listens to. |

**What would invalidate this:** the dogfooding stage stops producing findings — several days of real use on the thinned product turning up nothing the earlier stages had not already caught is the cue that the gate has become ceremony, and that the sequence should collapse to subtract → refactor → publish. The opposite cue also fires: dogfooding that keeps surfacing subtraction regressions past the point where fixes converge says the subtraction went too far and D3's verb set, not the sequence, needs re-opening. An external publication deadline would override the sequence without invalidating it, and should be recorded as an override rather than a revision.

## Sibling reconciliation (the edits this ADR anchors)

Every edit below is an in-place evolution per dotclaude ADR-011 D1, dated 2026-09-15 and citing this ADR by number. Enumerated so a reader can check the set is complete; the executable form is `tests/test-adr-evolution-notes.sh`.

- **rip-cage ADR-021** (layered rip-cage config) — **retires whole** per D2.
- **rip-cage ADR-011** (shell completions — this repo's ADR-011, not dotclaude's) — **retires whole** per D3.
- **rip-cage ADR-005** (ecosystem tools) — D1, D3, D4, D7, D8, D9, D11, D14 revised per D4 and D5; **D12 and D13 explicitly HONORED** (FROM-extension *is* composition by agents; a `RUN which <tool>` line in the operator's own Dockerfile *is* D13's presence assertion, failing the build exactly as the declared check failed it).
- **rip-cage ADR-002** D3 (lifecycle verbs) — `down` deleted, `destroy` kept, per D3.
- **rip-cage ADR-003** D3 (allowed-roots guard deleted) and D5 (`rc schema` retires), per D2 and D3. D1 (`--output json`) is honored and re-homed to D7 stage 2.
- **rip-cage ADR-009** D7 (first-run prompt deleted) per D3. D1 (harm-reduction positioning) is honored.
- **rip-cage ADR-010** D1 — **HONORED**: `rc auth` survives on function, per D3.
- **rip-cage ADR-023** D2 — patterns move to the shipped protected-paths list; the pre-flight stays in `rc up` and gains auto-cover, per D2.
- **rip-cage ADR-025** D1 — substance untouched (DCG stays a recipe); its `.rip-cage.yaml` transport becomes the recipe's own mount line, per D2.
- **rip-cage ADR-027** D4 — the launch-wrapper mechanism moves to the base image and the descriptor, per D4; the FIRM principle survives.
- **rip-cage ADR-029** D4 — `rc reload` re-homes into `rc up --replace`, per D3.
- **rip-cage ADR-030** D8 — masking becomes template mount lines plus the auto-cover half of the protected-paths rule, per D2.
- **`docs/decisions/INDEX.md`** — a row for this ADR, and the rows of every ADR above rewritten so a reader sees retired-or-evolved status without opening the file.

Not touched, deliberately: rip-cage ADR-024 (the prompt-injection threat model is unaffected; D5(a)'s host-side location rule is a new layer *under* it) and rip-cage ADR-026 (containment/mediation identity — msb is still the delegate).

## Open, not decided here

- Migration for existing `.rip-cage.yaml` users. rip-cage is pre-publication and the human is its only user, so the cost is near zero; if it turns out not to be, it is a note, not a shim.
- Where exactly the boot descriptor lives inside the image, and its precise schema. Constraint from D4: one file, declarative, read by init's existing loop. `rip-cage-ely4.11` decides.
- Whether the floor probe becomes a publishable artifact in its own right (epic D8 roadmap, EXPLORATORY).

## canonical_refs

- `docs/decisions/ADR-029-msb-migration.md` (rip-cage corpus) — D2 "contribution moves up a level" is the prior step this ADR completes; D1, D3, D5 honored intact; D4's `rc reload` disposition re-homes into `rc up --replace` per D3 here.
- `docs/decisions/ADR-005-ecosystem-tools.md` (rip-cage) — D12 honored and governing (FROM-extension is composition by agents); D13 honored (the floor probe is its presence assertion); D1/D3/D4/D7/D8/D9/D11/D14 evolved per D4 and D5 here.
- `docs/decisions/ADR-021-layered-rip-cage-config.md` (rip-cage) — retires whole per D2 here.
- `docs/decisions/ADR-011-shell-completions.md` (rip-cage corpus, **not** dotclaude ADR-011) — retires whole per D3 here.
- `docs/decisions/ADR-003-agent-friendly-cli.md` (rip-cage) — D1 `--output json` honored (re-homed to D7 stage 2); D3 allowed-roots guard deleted; D5 `rc schema` retires.
- `docs/decisions/ADR-002-rip-cage-containers.md` (rip-cage) — D3 lifecycle verbs evolved per D3 here.
- `docs/decisions/ADR-009-ux-overhaul.md` (rip-cage) — D1 harm-reduction positioning honored; D7 first-run prompt deleted per D3 here.
- `docs/decisions/ADR-010-auth-refresh.md` (rip-cage) — D1 honored: `rc auth` kept on live-refresh function.
- `docs/decisions/ADR-023-secret-path-mount-denylist.md` (rip-cage) — D2 evolved per D2 here.
- `docs/decisions/ADR-025-host-adoptable-dcg-policy.md` (rip-cage) — D1 transport note only; DCG stays a recipe.
- `docs/decisions/ADR-027-agent-substrate-projection.md` (rip-cage) — skills projection stays as `rc up` generated mounts; D4 launch-wrapper mechanism evolved per D4 here, principle honored.
- `docs/decisions/ADR-030-classify-by-use-secret-posture.md` (rip-cage) — D8 masking re-homed per D2 here.
- `docs/decisions/ADR-024-prompt-injection-threat-model.md` (rip-cage) — threat model honored unchanged; D5(a) is a new layer under it.
- `docs/decisions/ADR-026-containment-mediation-identity.md` (rip-cage) — untouched: msb is still the delegate, and nothing here re-opens the containment/mediation split.
- `docs/decisions/ADR-008-open-source-publication.md` (rip-cage) — D5 bash 3.2 and D6/D7/D8 publication mechanics bind D7 here's publish stage.
- `~/.claude/docs/decisions/ADR-011-*.md` (dotclaude) D1 — ADRs reflect target architecture and evolve in place; the rule this ADR's sibling reconciliation follows.
- `~/.claude/docs/decisions/ADR-008-adr-predicates-and-plan.md` (dotclaude) D1 (per-decision predicates), D5 (`canonical_refs` mandate), D8 (signal-shaped invalidation), D9 (corpus-prefixed citation form).
- `~/code/personal/superradcompany-skills/microsandbox/SKILL.md` — the upstream msb skill; referenced by the `cage-*` skills, never copied.
- Beads: `rip-cage-ely4` (the HITL brainstorm — two sittings, the human's in-pane rulings, the ship-record), `rip-cage-ely4.1` (the stamped honest assessment — primary evidence), `rip-cage-ely4.7` (the epic this ADR canonizes), `rip-cage-ely4.8` (this ADR's own bead), `rip-cage-ely4.9` through `rip-cage-ely4.17` (the implementing children), `rip-cage-sygz` (the refactor stage under D7), `rip-cage-tncg` (where the fleet roadmap line lives).
