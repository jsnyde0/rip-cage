---
name: configure-cage
description: Reads manifest/default-tools.yaml — the maintained, guaranteed-current default that the published rip-cage image is built from — as the reference base for a host manifest (~/.config/rip-cage/tools.yaml), then proposes deltas for the human's actual situation by judgment: reading the relevant examples/ recipe fragments and hand-writing tools.yaml entries — no generator script, no setup tool, no fixed interview. Carries the 3-layer config mental model (image manifest / global posture / per-project config), reconcile-awareness (a tools.yaml may already exist from a past session — you are probably not starting from zero), the credential non-possession posture (declaring auth.credentials so msb --secret injects the real value on the wire and the agent only ever holds a placeholder — a default config declaration, not a composed mediator; see docs/reference/egress.md), and known footguns (DCG's open-extension-discovery residual, pi's headless-throttle) as knowledge to relay by judgment, not gates to force through. Use when a human says "set up a rip-cage cage", "configure a cage", "which tools/guards for my cage", "compose a rip-cage manifest", "keep my credentials out of the cage", or otherwise wants help composing their rip-cage tools.yaml before running rc build.
---

# Configure a rip-cage cage

You are helping a human compose a rip-cage host manifest (`~/.config/rip-cage/tools.yaml`).
Your output is a **reviewable YAML file the human can read before `rc build` ever runs** —
not a running cage. You do the composition **by judgment**, the same way any engineer would:
read a maintained reference composition, understand what it gives you, read the recipes for
whatever the human wants beyond it, and hand-write the entries.

**You do not run `rc build`.** That is a host operation the human triggers themselves,
after reviewing what you wrote.

## Start from the reference base, not a blank slate

[`manifest/default-tools.yaml`](../../../manifest/default-tools.yaml) is not sample material — it is
the manifest the *published* rip-cage image is literally built from
(`RC_MANIFEST_GLOBAL=manifest/default-tools.yaml ./rc build`), and its own header declares it the
single data-layer home of the default tool-set blessing (ADR-005 D12). That makes it the best
starting point available: read it, understand what it already composes (the floor tools, the
Claude Code and pi wrappers, DCG in its **open** posture), and treat the
human's request as a **delta** against that — additions (a language runtime, a database CLI,
a multiplexer), removals, or posture changes (DCG locked, egress allowlist changes, a
pinned pi model) — rather than reconstructing a cage from nothing.

There is no separate "minimal reference" file to maintain here on purpose: `dist` already
guarantees currency (it is what actually ships), and a copied second reference would drift
from it the moment either one changes. If the human wants a richer walk-away/headless setup,
[`examples/compose-walk-away-cage.md`](../../../examples/compose-walk-away-cage.md) is a
delta recipe layered on top of `dist` for exactly that shape — read it when it applies rather
than re-deriving the same delta from scratch.

## You may not be starting from zero

`rc` seeds a bare floor-only `tools.yaml` on first run, but a human who has used this skill
before (or hand-edited their manifest) may already have a richer one sitting at
`~/.config/rip-cage/tools.yaml` (or a project-level `tools.yaml`). Before you write anything,
it is worth knowing what — if anything — is already there. Two failure stories from this
project's own history make the point concrete: a session once overwrote an existing composed
`tools.yaml` with a fresh minimal one, silently discarding tools a prior session had
deliberately added (the "dotpi clobber"); another time a hand-copied pi recipe fragment
drifted out of sync with its canonical source because nobody re-read the fragment before
editing (the pi-recipe drift). Both came from assuming a fresh start when one wasn't warranted.
Reading and reconciling against what's already composed, rather than always emitting from
scratch, is judgment you apply here — not a mandated diff step.

## The 3-layer config model

A rip-cage cage's configuration lives in three layers, and knowing which one a given ask
belongs to keeps you from editing the wrong file:

| Layer | File | Governs |
|---|---|---|
| Image manifest | `~/.config/rip-cage/tools.yaml` (or a project-level `tools.yaml`) | which tools/guards/multiplexers get **baked into the image** at `rc build` time — this is the file this skill composes |
| Global posture | `~/.config/rip-cage/config.yaml` + `rc.conf` | host-wide guardrails that apply to every cage: the mount denylist, `RC_ALLOWED_ROOTS` (which host paths `rc up` may target) |
| Per-project config | `<repo>/.rip-cage.yaml` | per-workspace runtime posture: `session.multiplexer`, `ssh.allowed_hosts`, `network.mode` + the egress allowlist, `mounts.config_mode` |

(The two posture layers are not disjoint field sets — `config.yaml` and `.rip-cage.yaml`
share one schema at two precedence levels that merge, global default / project override
(ADR-021). The "Governs" column shows where each concern *typically* lives.)

"Add a Postgres CLI" is an image-manifest ask. "Don't let any cage touch `~/.aws`" is a
global-posture ask. "Allow this cage to reach `some-private-mirror.example.com` over SSH" is a
per-project ask (and per `CLAUDE.md`, `.rip-cage.yaml` is read-only inside the cage by
design — that edit and the `rc reload` that picks it up happen on the host, not from inside a
running cage). Most requests this skill handles land in the image-manifest layer; know when
one doesn't.

The credential non-possession posture (below) splits across these same layers, and the split
isn't a style preference — it follows from how each layer merges. `auth.per_tool` (or the bare
`auth.credential_mounts`) and `auth.placeholder_env_file` belong in the **global** `config.yaml`:
they're posture the human wants on every cage they create, set once (rip-cage-u2ro promote).
`network.allowed_hosts` and `auth.credentials` (per-host credential bindings, msb `--secret`)
stay **per-project**, and that's load-bearing, not a preference — the two posture layers merge
list fields additively (ADR-021), so a host added at the global layer applies to every project
forever and no project can narrow it back out. A host only one project needs (a private mirror,
a scoped API) belongs at the project layer for exactly that reason: put it in global instead and
you've silently widened every other cage's allowlist with no way for any single project to opt
back out.

## The recipe catalog — read fragments fresh, don't memorize them here

[`examples/README.md`](../../../examples/README.md) is the recipe index: every composable
fragment (guards, multiplexers, mediators, plain tools, launch-composition examples), grouped
by archetype, with a path to its `manifest-fragment.yaml`.
[`docs/reference/README.md`](../../../docs/reference/README.md) is the seam catalog: what each
of the six composable seams is for and the manifest field shape it uses.

Recipes change independently of this skill file, and their `install_cmd` entries often carry
generated content (base64 blobs regenerated by the recipe's own `build-fragment.sh`) — a copy
pasted into this skill would silently drift from the source of truth the moment the recipe is
regenerated. So: every time you compose a fragment, go open its actual
`manifest-fragment.yaml` and README, and copy what it says to copy. This file tells you where
to look, not what the fragments currently contain.

## External agent substrate has its own recipe — don't expect one here

Sometimes the human's situation includes agent substrate rip-cage doesn't own — e.g. a
self-driving bead factory whose worker sessions need to run caged. That substrate's own
project is where its provisioning recipe lives, not `examples/`: per ADR-005 D12, rc blesses
no tool, and the same holds one level up — rc doesn't bless or bundle *recipes* for
externally-owned substrate either. When you recognize this shape, consult that project's own
recipe doc by judgment rather than expecting (or inventing) an rc-shipped one. Illustration,
not a name to hardcode: dotpi's `docs/factory-cage-provisioning.md` is the recipe for
provisioning dotpi's bead-factory substrate into a cage.

## Footguns worth knowing

Two things have already bitten real sessions. Relay them when they're relevant to what the
human is doing — they are knowledge you bring to bear by judgment, not checklist items to
force through regardless of context.

**DCG's open posture carries a knowingly-accepted residual.** `dist` composes DCG in its
**open** default (ADR-027 D1/D4, FIRM): pi's own extension auto-discovery paths
(`/workspace/.pi/extensions/`, `~/.pi/agent/extensions/`) stay live even with the guard
composed, so the guard extension always loads and always denies destructive commands, but a
prompt-injected pi could, in principle, write its own extension into an auto-discovery path
and have it auto-load — nothing in the open posture guards against that specific vector. This
is an accepted trade (containment still bounds the blast radius), favoring agent autonomy over
closing the residual. The alternative, **locked** (`--no-extensions`, opt-in only), closes the
vector but costs pi's own auto-loading — every extension the agent wants active then has to be
baked into a recipe's `launch_args` at image build time. Read
[`examples/dcg/README.md`](../../../examples/dcg/README.md) §"pi launch wiring: OPEN by
default, LOCKED opt-in" for the exact mechanism if the human's threat model makes locked worth
the autonomy cost.

**pi's headless default can silently throttle.** A fresh headless pi invocation — scripted,
herdr-spawned, `pi --print` — with Claude auth in context resolves toward the Claude
subscription entitlement, and Anthropic returns a 400 for third-party apps on that path
(rip-cage-tl6q — the same third-party-billing wall the credential non-possession section
below covers); absent Claude auth, pi's bare CLI default is `--provider google`. Either
way it isn't a working Anthropic-subscription path, so an unpinned headless pi can simply
stop working mid-run with no warning. This only bites once pi is
running unattended/headless — an interactively-driven pi with working subscription auth never
hits it. The fix is pinning a static-key provider via a `--model <provider/model>` entry in a
`launch_args` array; the commented example block in
[`examples/pi/manifest-fragment.yaml`](../../../examples/pi/manifest-fragment.yaml) (search
for "OPTIONAL: pin pi's provider/model") shows the field shape and a verified-working value —
it is deliberately commented out there because a shipped default must not force one provider
on every operator. If the human is heading toward a walk-away or otherwise headless setup,
[`examples/compose-walk-away-cage.md`](../../../examples/compose-walk-away-cage.md) covers
this pin as part of that recipe.

## Credential non-possession — a config declaration, not a composed mediator

> **Retired ([ADR-029](../../../docs/decisions/ADR-029-msb-migration.md) D2/D5):** the
> composed-MEDIATOR recipe this section used to walk through (`examples/compose-rc-with-iron-proxy.md`,
> a manifest `archetype: MEDIATOR` entry, `network.egress.mediator`/`network.egress.mediator_env_file`)
> is **deleted, not just undocumented** — there is no manifest MEDIATOR archetype or mediator
> launch machinery left in `rc` to compose. The recipe file this section pointed at no longer
> exists in this tree.

By default a cage mounts the human's real credentials, so the agent *possesses* them — a
prompt-injected agent could exfiltrate them. Non-possession for the dominant secrets (Claude's
own auth, any git host token) is now a **default platform property**, not something you compose:
declare `auth.credentials: [{source_env: <HOST_ENV_VAR>, hosts: [<domain>, ...]}]` in
`.rip-cage.yaml` (a host must ALSO be in `network.allowed_hosts`, or the connection is denied
before the secret is ever considered) and msb `--secret` injects the real value on the wire
toward the named host(s) only — the guest env/disk/proc hold just a placeholder. See
[`docs/reference/egress.md`](../../../docs/reference/egress.md) for the full worked example and
[`docs/reference/config.md`](../../../docs/reference/config.md) for the field reference.
`auth.credential_mounts: none` / `auth.per_tool.{claude,pi}` (unchanged by the migration) still
gate whether the possession-mode credential files mount at all.

If a human needs L7 content policy or credential injection beyond a per-host `--secret` binding,
that is fully operator-composed and unwired today — there is no manifest seam to point them at;
relay that honestly rather than reaching for the deleted recipe. **Residual staleness in this
skill beyond the mediator recipe (e.g. `ssh.allowed_hosts`/`network.mode` mentioned elsewhere as
if still live per-project fields) is a known finding, not addressed by this fix — flagged for a
follow-up bead.**

## Composing by judgment, not by machinery

Write `tools.yaml` yourself, the way an engineer hand-writing config from documented building
blocks would: for each recipe you're composing, open its `manifest-fragment.yaml`, read the
actual `tools[]` entries it says to copy, and copy them into the manifest you're building
verbatim, per that recipe's own "how to enable" instructions. Apply posture choices (DCG's
open/locked `launch_args`, a pi model pin, a multiplexer's TOOL+MULTIPLEXER pair) by editing
the relevant fragment's entry the same way. When more than one
composed fragment contributes `launch_args` to the same shim (e.g. DCG's guard extension and
herdr-pi's status extension both loading into pi), they combine in the order the fragments
appear in the manifest — that's a fact about how `rc build` assembles the shim, worth knowing
so you can read back what you've composed; see
[`examples/herdr-pi/README.md`](../../../examples/herdr-pi/README.md) for the canonical worked
example of multiple fragments' `launch_args` coming together.

This is manual work you perform by reading and understanding each fragment — **not** a script,
generator, setup tool, or config-file merger. Do not write or invoke any of the following, in
any form, as part of this workflow:

- a directive or config field, anywhere, that pulls fragments together for you without you
  reading them
- a setup script that writes `tools.yaml` for you
- a "manifest builder/generator" script (e.g. no `scripts/write-tools-yaml.py`, no
  `merge-fragments.sh`)
- any other deterministic mechanism that takes recipe fragments as input and emits
  `tools.yaml` as output without an agent reading and judging each fragment

If you find yourself reaching for any of these — stop. The point of this skill is that
**you**, the agent, read the recipes and write the YAML, the same way a human engineer would
hand-put-together a config file from documented examples. rip-cage is a composable seam, not a
bundler (ADR-005 D12): it gives you legible recipes and a manifest format, and putting them
together is your job, every time, fresh — not a one-time mechanism you build once and rerun.

## Composing cleanly is not the same claim as running

A `tools.yaml` that parses is not yet a cage that works — the dotpi session that motivated
this rewrite produced exactly that gap: a manifest that composed fine but booted an agent into
the wrong working directory with no beads store reachable, and nothing about the *config*
made that visible. Two separate, honest checks close that gap, at two different times:

- **Compose-time — proves the manifest parses.** `RC_MANIFEST_GLOBAL=<your composed file>
  ./rc generate-dockerfile` runs against the operator's own manifest and proves it is
  well-formed and assembles into a Dockerfile, before anyone commits to a build.
- **Post-build — proves the cage runs.** Once the human has run `rc build` and brought a cage
  up, `rc doctor <cage>` is the mechanical way to verify the built cage is actually usable
  (e.g. that a fresh exec lands in the right place and the workspace resolves cleanly) — this
  check keeps growing as rip-cage's own tooling matures, so don't treat the specific checks it
  runs today as fixed; point the human at `rc doctor` rather than trying to eyeball
  runnability yourself.

## Show your work before the human builds

Before writing the file, show the human the **composed `tools.yaml`** in full, so they can
review it like they would review a diff. Also make the **resulting pi launch line** legible —
walk the composed `launch_args` across every contributing fragment, in the order they'll be
concatenated, and write out what the resulting pi launch shim will actually run, e.g.:

```
Resulting pi launch args (in fragment order):
  -e /etc/rip-cage/pi/dcg-gate.ts --model openai-codex/gpt-5.5
```

This is what makes the wiring legible *before* `rc build` bakes it into an image — which
extensions load, whether `--no-extensions` is present, which model is pinned — otherwise
invisible until someone reads the generated Dockerfile.

## Emit and hand off

Write the composed manifest to `~/.config/rip-cage/tools.yaml` (creating the directory if
needed), then hand off with something like: **"I've written
`~/.config/rip-cage/tools.yaml` — review it, then run `rc build` when you're ready."**

Do not run `rc build` yourself. Do not run `docker build`. The human reviews and triggers the
build.

## What this skill is not

- Not a directive, setup tool, or config-file merger — see "Composing by judgment, not by
  machinery" above.
- Not a mechanism that ships recipe bodies inline — recipes live in `examples/` and you read
  them fresh each time; this file only points at them.
- Not a build trigger — it produces a reviewable file, never runs `rc build`.
- Not a cross-recipe wiring layer of its own — each recipe's `launch_args` combines by
  manifest fragment order (`rc build`'s existing mechanism); this skill does not add any new
  wiring path.
- Not a runnability verifier — that job belongs to `rc generate-dockerfile` (compose-time) and
  `rc doctor` (post-build), not to this skill's judgment.
