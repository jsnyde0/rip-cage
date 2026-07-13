# Compose a walk-away cage (dist + herdr + herdr-pi)

This recipe shows the **delta** on top of [`manifest/default-tools.yaml`](../manifest/default-tools.yaml)
for a cage meant to run **unattended, multi-agent, walk-away** sessions: a human kicks off one or
more headless agents, disconnects, and checks back later via a supervisor view rather than a
live terminal. It is a composition recipe, not a pre-composed manifest — see "No new manifest
file" below for why.

`manifest/default-tools.yaml` is already the reference base for a rip-cage cage (floor tools, Claude
Code and pi wrappers, DCG in its open posture — the former ssh-bypass guard sibling retired wholesale
with the ssh cluster, [ADR-029](../docs/decisions/ADR-029-msb-migration.md) D3) — see the
[`configure-cage` skill](../.claude/skills/configure-cage/SKILL.md) for how an agent composes
from it by judgment. This recipe is the delta a walk-away setup adds on top: a supervisor
multiplexer to watch multiple agents from outside any one of their panes, and (for headless pi)
a fix for a throttle that only bites once pi stops being interactively driven.

## What "walk-away" changes about the composition

A cage running interactively has a human at the keyboard who notices if something looks wrong.
A walk-away cage doesn't — which shifts what's worth composing:

- **A supervisor view matters.** Without one, checking on multiple unattended agents means
  attaching to each pane in turn. herdr gives a single view across agents and their semantic
  status (working/blocked/idle).
- **Headless failure modes that a human would shrug off start mattering.** pi's default
  provider resolution assumes an interactive session; run headless long enough and an
  unattended agent can silently stop making progress (see the pi model pin below).
- **Credential handling becomes more of a live question**, since nobody is present to notice a
  credential behaving oddly — see "Credential non-possession" below for how msb `--secret`
  addresses this by default post-cutover.

## The delta: herdr + herdr-pi on top of dist

Add two fragments to whatever manifest you're composing from `dist`:

- **[`examples/herdr/`](herdr/)** — the herdr multiplexer: installs the `herdr` binary (a TOOL
  entry) and the MULTIPLEXER hooks (`herdr server` at start, `herdr` TUI on attach). This is
  what gives you the cross-agent supervisor view. Read
  [`examples/herdr/manifest-fragment.yaml`](herdr/manifest-fragment.yaml) and
  [`compose-rc-with-herdr.md`](compose-rc-with-herdr.md) for the exact entries and the
  `session.multiplexer: herdr` per-project config that activates it.
- **[`examples/herdr-pi/`](herdr-pi/)** — herdr's pi semantic-status extension, baked in and
  wired via `launch_args` so pi's status reports to herdr reliably regardless of DCG posture
  or extension auto-discovery. Read
  [`examples/herdr-pi/README.md`](herdr-pi/README.md) — it is also the **canonical
  worked example** of how multiple fragments' `launch_args` (DCG's guard extension, herdr-pi's
  status extension) assemble in fragment order into one pi launch shim; read it once to
  understand that mechanism generally, not just for herdr's sake.

Compose both fragments' `tools[]` entries into your manifest per each recipe's own "How to
compose" section — do not copy the YAML shown in either README verbatim without reading the
current `manifest-fragment.yaml` first; the entries carry generated `install_cmd` content that
can move independently of any prose describing it.

DCG stays composed in its **open** default from `dist` (ADR-027 D1/D4, FIRM) unless the human's
threat model specifically warrants locking it — walk-away autonomy is exactly the case the open
default is optimized for (a locked cage can't have pi author its own extensions without a
rebuild, which cuts against "the agent keeps working while nobody's watching"). See the
`configure-cage` skill's footgun notes for the open-vs-locked tradeoff in full.

## The pi provider/model pin — this is where the headless throttle actually bites

A fresh headless pi invocation (scripted, herdr-spawned pane, `pi --print`) defaults to
resolving the Claude subscription entitlement. Anthropic returns a 400 for third-party apps on
that path ("Third-party apps now draw from your extra usage, not your plan limits"), so an
unpinned headless pi can simply stop working mid-run with no warning (rip-cage-tl6q). This is
exactly the failure mode a walk-away cage cannot tolerate — nobody is watching to notice the
agent went quiet.

Interactively-driven pi with working subscription auth never hits this; it only matters once
pi is running unattended, which a walk-away cage's whole point is. Pin a static-key provider by
adding a `launch_args: ["--model", "<provider/model>"]` entry to a composed pi-lifecycle
fragment — the commented example block in
[`examples/pi/manifest-fragment.yaml`](pi/manifest-fragment.yaml) (search for "OPTIONAL: pin
pi's provider/model") shows the exact field shape and a spike-verified working value
(`openai-codex/gpt-5.5` via a ChatGPT-account codex login — the `-codex`/`-codex-mini`
model-name variants are rejected for ChatGPT accounts). It is commented out there deliberately;
uncomment it with **the human's own working provider/model**, not the example value, unless
that happens to be what they use.

## Credential non-possession: a config declaration now, not a composed mediator

Pre-cutover, credential non-possession for a walk-away cage meant composing an egress mediator
(`examples/compose-rc-with-iron-proxy.md`) — a co-located proxy `rc` launched and wired via the
manifest MEDIATOR archetype. **That machinery is deleted, not merely undocumented**
([ADR-029](../docs/decisions/ADR-029-msb-migration.md) D2/D5) — there is no MEDIATOR archetype,
launch hook, or HTTP-CONNECT forward-to seam left in `rc` to compose against; see
[`examples/README.md`](README.md#mediator-recipes--dropped).

Non-possession for the dominant secrets (Claude's own auth, and any git host token) is now a
**default platform property**: declare `auth.credentials: [{source_env, hosts}]` in
`.rip-cage.yaml` and msb's `--secret` injects the real value on the wire toward the named host(s)
only, while the guest env/disk/proc hold just a placeholder ([ADR-029](../docs/decisions/ADR-029-msb-migration.md)
D5, [egress.md](../docs/reference/egress.md)). This is exactly the property a walk-away
cage — nobody watching for a credential behaving oddly — benefits from, and it's now the default
rather than something you opt into by composing a proxy. If you need L7 content policy or
audit-trail-grade request logging beyond that, that remains fully operator-composed and unwired
— run something yourself, outside `rc`'s declared composition surface.

## No new manifest file

This recipe deliberately does not ship a pre-composed `walk-away.yaml`. `manifest/default-tools.yaml`'s
own header notes that its recipe entries carry *generated* `install_cmd` content (re-run each
recipe's `build-fragment.sh` to refresh) — a second, checked-in manifest built from the same
fragments would duplicate that generated content and silently drift the moment any composed
recipe regenerates, which is the exact failure class this project has already been burned by
(a hand-copied pi recipe fragment falling out of sync with its canonical source). Compose the
delta above by reading the fragments fresh, the same way the `configure-cage` skill does for
any other composition — there is no shortcut manifest to copy instead.

## See also

- [`.claude/skills/configure-cage/SKILL.md`](../.claude/skills/configure-cage/SKILL.md) — the
  skill that composes a manifest by judgment, using `dist` as its reference base and this
  recipe for the walk-away delta.
- [`examples/README.md`](README.md) — the full recipe index.
- [`docs/reference/README.md`](../docs/reference/README.md) — the seam catalog.
- `rc doctor <cage>` — post-build, proves the built cage is actually runnable (not just that
  the manifest composed cleanly).
