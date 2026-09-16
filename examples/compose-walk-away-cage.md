# Compose a walk-away cage (base + herdr + herdr-pi)

This recipe shows the **delta** on top of [`examples/base/`](base/) for a cage
meant to run **unattended, multi-agent, walk-away** sessions: a human kicks off
one or more headless agents, disconnects, and checks back later via a
supervisor view rather than a live terminal. It is a composition recipe, not a
pre-built image — read the fragments fresh each time you compose them, per
"No pre-composed image" below.

## What "walk-away" changes about the composition

A cage running interactively has a human at the keyboard who notices if
something looks wrong. A walk-away cage doesn't — which shifts what's worth
composing:

- **A supervisor view matters.** Without one, checking on multiple unattended
  agents means attaching to each pane in turn. herdr gives a single view
  across agents and their semantic status (working/blocked/idle).
- **Headless failure modes that a human would shrug off start mattering.**
  pi's default provider resolution assumes an interactive session; run
  headless long enough and an unattended agent can silently stop making
  progress (see the pi model pin below).
- **Credential handling becomes more of a live question**, since nobody is
  present to notice a credential behaving oddly — see "Credential
  non-possession" below for how msb `--secret` addresses this by default.

## The delta: herdr + herdr-pi on top of base

Paste two recipes' `Dockerfile.snippet`s into your own Dockerfile, in this order:

- **[`examples/herdr/`](herdr/)** — the herdr multiplexer: installs the
  `herdr` binary and the `multiplexers[]` boot-descriptor entry (`herdr server`
  at start, `herdr` TUI on attach). This is what gives you the cross-agent
  supervisor view. Read [`examples/herdr/README.md`](herdr/README.md) for the
  exact lines and the durable-state mount your project's cage config needs.
- **[`examples/herdr-pi/`](herdr-pi/)** — herdr's pi semantic-status extension,
  baked in and wired into pi's combined launch line so pi's status reports to
  herdr reliably regardless of DCG posture or extension auto-discovery. Read
  [`examples/herdr-pi/README.md`](herdr-pi/README.md) — it is also the
  **canonical worked example** of how two recipes' `launch` contributions
  (DCG's guard extension, herdr-pi's status extension) combine into one pi
  launch command, since `rc-boot-merge` cannot do that combination for you.
  Read it once to understand that mechanism generally, not just for herdr's
  sake.

Read each recipe's own "How to compose"/"Use it" section before pasting — do
not copy a Dockerfile snippet shown in prose elsewhere without checking the
current file first; snippets move independently of any prose describing them.

DCG (if you compose it) stays in its **open** default (ADR-027 D1/D4, FIRM)
unless your threat model specifically warrants locking it — walk-away autonomy
is exactly the case the open default is optimized for (a locked cage can't have
pi author its own extensions without a rebuild, which cuts against "the agent
keeps working while nobody's watching"). See
[`examples/dcg/README.md`](dcg/README.md) for the open-vs-locked tradeoff in
full.

## The pi provider/model pin — this is where the headless throttle actually bites

A fresh headless pi invocation (scripted, herdr-spawned pane, `pi --print`)
defaults to resolving the Claude subscription entitlement. Anthropic returns a
400 for third-party apps on that path ("Third-party apps now draw from your
extra usage, not your plan limits"), so an unpinned headless pi can simply
stop working mid-run with no warning. This is exactly the failure mode a
walk-away cage cannot tolerate — nobody is watching to notice the agent went
quiet.

Interactively-driven pi with working subscription auth never hits this; it
only matters once pi is running unattended, which a walk-away cage's whole
point is. Pin a static-key provider by appending `--model <provider/model>` to
whichever `tools[].launch` command you author for `pi` (see
[`examples/pi/README.md`](pi/README.md#pinning-pis-providermodel-headless-throttle)
for the exact shape). A spike-verified working value is
`openai-codex/gpt-5.5` via a ChatGPT-account codex login — the `-codex`/
`-codex-mini` model-name variants are rejected for ChatGPT accounts. Use
**your own** working provider/model, not that example value, unless it
happens to be what you use.

## Credential non-possession: a cage-config declaration, not a composed proxy

Non-possession for the dominant secrets (Claude's own auth, and any git host
token) is a **default platform property**: declare a `secrets:` entry in your
project's cage config (`~/.config/rip-cage/projects/<cage>.yaml`) with
`value:` deliberately omitted, plus the matching line in that config's `env:`
block — msb resolves the real value from a same-named host variable at boot
and injects it on the wire toward the bound host(s) only, while the guest
holds just a placeholder on disk, in its environment, and in `/proc`
([ADR-031](../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md)
D2's 2026-09-15 amendment, [ADR-029](../docs/decisions/ADR-029-msb-migration.md)
D5). This is exactly the property a walk-away cage — nobody watching for a
credential behaving oddly — benefits from, and it ships in
[`share/rip-cage/cage.yaml.template`](../share/rip-cage/cage.yaml.template)
by default. If you need L7 content policy or audit-trail-grade request
logging beyond that, that remains fully operator-composed and unwired — run
something yourself, outside `rc`'s declared composition surface.

## No pre-composed image

This recipe deliberately does not ship a pre-built `walk-away` image or a
checked-in combined Dockerfile. Composing herdr + herdr-pi (and optionally
DCG) means pasting each recipe's own `Dockerfile.snippet` in sequence into
your own Dockerfile — the same judgment call `examples/herdr-pi/` walks
through for combining `launch` contributions. A pre-built combined artifact
would drift the moment any one recipe's snippet changed; reading the
fragments fresh each time is what stays in sync.

## See also

- [`examples/README.md`](README.md) — the full recipe index.
- [`docs/reference/README.md`](../docs/reference/README.md) — the seam catalog.
- `rc doctor <cage>` — mines the trace log for denied hosts and prints the
  exact config line to add, once the cage is up and something gets blocked.
