---
name: construct-cage
description: Interviews a human, one question at a time, to compose a rip-cage host manifest (~/.config/rip-cage/tools.yaml) by reading examples/ recipes and hand-writing the tools entries by judgment — no generator script, no setup tool. Covers tool selection, the DCG guard (including its open-vs-locked extension posture), multiplexer choice, egress posture, and the pi provider/model pin. Use when a human says "set up a rip-cage cage", "configure a cage", "which tools/guards for my cage", "compose a rip-cage manifest", or otherwise wants help composing their rip-cage tools.yaml before running rc build.
---

# Construct a rip-cage cage

You are helping a human compose a rip-cage host manifest (`~/.config/rip-cage/tools.yaml`).
Your output is a **reviewable YAML file the human can read before `rc build` ever runs** —
not a running cage. You do the composition **by judgment**, the same way any engineer would:
read the recipe catalog, understand what each fragment provides, and hand-write the entries
that match what the human told you they want.

**You do not run `rc build`.** That is a host operation the human triggers themselves,
after reviewing what you wrote.

## Read the catalog first

Before interviewing, orient yourself (or refresh if you already know this repo):

- [`examples/README.md`](../../../examples/README.md) — the recipe index: every
  composable fragment (guards, multiplexers, mediators, plain tools, launch-composition
  examples), grouped by archetype, with a one-line description and a path to its
  `manifest-fragment.yaml`.
- [`docs/reference/README.md`](../../../docs/reference/README.md) — the seam catalog:
  what each of the six composable seams (TOOL, mounts, launch_args/extension
  composition, multiplexer/mediator providers, guard recipes, launch composition) is
  for and the manifest field shape it uses.

Do not memorize recipe bodies into this skill file. Each time you compose a manifest,
go **read the actual `manifest-fragment.yaml`** for the recipes the human chose — recipes
change independently of this skill, and a copy pasted in here would silently drift from
the source of truth. This file tells you *where to look and what to ask*, not what the
fragments contain.

## The interview

Ask **one question at a time**, in this order. For each dimension, state the
**recommended default first**, then the one-line tradeoff, then ask what they want.
Most humans using this skill only talk to their agent and never hand-edit
`tools.yaml` — so lead with the default and let them accept it with a single "yes"
or "sounds good."

### 1. Tools

> Recommended default: the minimal floor — Claude Code (`examples/claude/`) and pi
> (`examples/pi/`). Tradeoff: every additional tool composed is more image surface;
> add only what the actual work needs (e.g. a database CLI, a language runtime).

Ask which coding agent(s) and any extra tools they want beyond the floor. Point them
at the TOOL section of `examples/README.md` for what's available; don't enumerate
every possible tool in this skill — the catalog is the source of truth and it grows
independently of this file.

### 2. DCG guard (destructive-command guard)

> Recommended default: ON (`examples/dcg/`). Tradeoff: DCG is a removable
> accident-guardrail that blocks `rm -rf`-class destructive commands — it is not an
> adversarial wall. Containment (the container boundary, egress firewall, non-root
> user, filesystem sandbox) is the real floor; DCG just catches a common accident
> class on top of it.

### 3. DCG extension posture — open vs locked (MANDATORY to surface)

This dimension must always be surfaced explicitly when DCG is composed — do not skip
it even if the human seems eager to move fast. It is the naive-user mitigation the
cage's OPEN default relies on: the human needs to have heard the tradeoff, not just
inherit it silently.

> Recommended default: **OPEN**. Under OPEN, pi's own extension auto-discovery paths
> (`/workspace/.pi/extensions/`, `~/.pi/agent/extensions/`) stay live, so pi can load
> and write its own extensions autonomously — the DCG guard extension still loads and
> still DENIES destructive commands regardless. The honest tradeoff: a
> prompt-injected pi could, in principle, write its own extension into an
> auto-discovery path and have it auto-load, and nothing in the open posture guards
> against that specific vector — it's a knowingly-accepted residual (containment
> still bounds the blast radius even if this happens). The alternative, **LOCKED**
> (`--no-extensions`, opt-in only), closes that vector, but at the cost of pi no
> longer auto-loading its own extensions — every extension the agent wants active
> then has to be baked into a recipe's `launch_args` at image build time, which is a
> real autonomy cost.

Read [`examples/dcg/README.md`](../../../examples/dcg/README.md) §"pi launch wiring:
OPEN by default, LOCKED opt-in" for the exact mechanism (which `launch_args` array
gets `--no-extensions` prepended, and where). Relay both options plainly, recommend
OPEN, and apply whichever the human picks.

### 4. Multiplexer

> Recommended default: **none** — a plain shell (`session.multiplexer: none` in
> `.rip-cage.yaml`, the config default). Tradeoff: `tmux` (`examples/tmux/`) adds
> terminal-session persistence; `herdr` (`examples/herdr/`, or
> `examples/herdr-pi/` for the paired pi status extension) adds a supervisor view
> suited to walk-away multi-agent runs. Both add a TOOL + MULTIPLEXER entry pair and
> some install surface; `none` is simplest and is fine for a single interactive
> session.

### 5. Egress posture

> Recommended default: **observe-mode** whitelist. Tradeoff: observe-mode won't
> block anything yet — it learns real outbound traffic first so you can promote
> observed hosts to the allowlist before flipping to enforce. Enforce mode blocks
> immediately but risks false-blocking legitimate work if the allowlist hasn't been
> learned yet. See [`docs/reference/egress.md`](../../../docs/reference/egress.md)
> for the observe → promote → block workflow and `rc allowlist` commands (an
> `.rip-cage.yaml`/`rc allowlist` concern, not a `tools.yaml` entry).

### 6. pi provider/model pin (MANDATORY to surface)

This dimension must always be surfaced when pi is one of the chosen tools — do not
skip it. It closes a real, previously-hit failure mode (rip-cage-tl6q): a fresh
headless `pi` invocation (scripted, herdr-spawned pane, `pi --print`) defaults to
resolving the Claude subscription entitlement, and Anthropic now returns a 400
("Third-party apps now draw from your extra usage, not your plan limits") for
third-party apps on that path — so an unpinned headless pi can simply stop working
mid-run with no warning.

> Recommended default: pin a **static-key provider** so headless/walk-away runs
> don't depend on OAuth-subscription resolution. A verified-working example is
> `openai-codex/gpt-5.5` (via a ChatGPT-account codex login; the `-codex`/
> `-codex-mini` model-name variants are rejected for ChatGPT accounts — use
> `gpt-5.5`). Tradeoff: pinning forces every pi launch (interactive, herdr-spawned,
> scripted) onto the chosen provider — right for autonomous/headless use, but it
> does override pi's own interactive-picked default for humans who never hit the
> throttle. Ask what provider/model the human actually has working auth for; don't
> force the example value if they use something else.

The pin is expressed as a `--model <provider/model>` entry in a `launch_args`
array. Read the commented `--model` example block in
[`examples/pi/manifest-fragment.yaml`](../../../examples/pi/manifest-fragment.yaml)
(search for "OPTIONAL: pin pi's provider/model") for the exact field shape and where
it composes — it is intentionally commented out there (a shipped default must not
force one provider on every operator); you add an uncommented `launch_args` line
with the operator's chosen value to the manifest you compose.

## Composing the manifest — by judgment, not by machinery

Once you have all six answers, **write `tools.yaml` yourself**, the way an engineer
hand-writing config from documented building blocks would:

1. Start from the bare floor entries (`beads`, `dolt`, `gh` — same as rc's own
   seeded default) plus whichever tool/guard/multiplexer recipes the interview
   selected.
2. For each selected recipe, **open its `manifest-fragment.yaml`, read the actual
   `tools[]` entries, and copy the ones it says to copy** into the manifest you're
   building — verbatim, per that recipe's own "How to enable" instructions.
3. Apply the human's DCG posture choice by editing the `dcg-wiring` entry's
   `launch_args` (add or omit `--no-extensions`) per `examples/dcg/README.md`.
4. Apply the human's pi model pin by adding a `launch_args: ["--model",
   "<provider/model>"]` entry to a composed pi-lifecycle fragment, following the
   commented example in `examples/pi/manifest-fragment.yaml`.
5. If DCG and the pi model pin both contribute `launch_args` to the pi shim, they
   combine in **fragment order** — DCG's guard fragment first (see
   [`examples/herdr-pi/README.md`](../../../examples/herdr-pi/README.md) for the
   canonical worked example of multiple fragments' `launch_args` coming together).

This is manual work you perform by reading and understanding each fragment — **not**
a script, generator, setup tool, or config-file merger. Do not write or invoke any
of the following, in any form, as part of this workflow:

- a directive or config field, anywhere, that pulls fragments together for you
  without you reading them
- a setup script that writes `tools.yaml` for you
- a "manifest builder/generator" script (e.g. no `scripts/write-tools-yaml.py`, no
  `merge-fragments.sh`)
- any other deterministic mechanism that takes recipe fragments as input and emits
  `tools.yaml` as output without an agent reading and judging each fragment

If you find yourself reaching for any of these — stop. The point of this skill is
that **you**, the agent, read the recipes and write the YAML, the same way a human
engineer would hand-put-together a config file from documented examples. rip-cage
is a composable seam, not a bundler (ADR-005 D12): it gives you legible recipes and
a manifest format, and putting them together is your job, every time, fresh — not a
one-time mechanism you build once and rerun.

## Show your work — transparency before build

Before writing the file, show the human the **composed `tools.yaml`** in full, so
they can review it like they would review a diff.

Also surface the **resulting pi launch line** in plain terms — walk the composed
`launch_args` across every contributing fragment, in the order they'll be
concatenated, and write out what the resulting pi launch shim will actually run,
e.g.:

```
Resulting pi launch args (in fragment order):
  -e /etc/rip-cage/pi/dcg-gate.ts --model openai-codex/gpt-5.5
```

This is the step that makes the wiring legible *before* `rc build` bakes it into an
image — the composed launch args (which extensions load, whether
`--no-extensions` is present, which model is pinned) are otherwise invisible until
someone reads the generated Dockerfile.

## Emit and hand off

1. Write the composed manifest to `~/.config/rip-cage/tools.yaml` (creating the
   directory if needed).
2. Hand off with something like: **"I've written `~/.config/rip-cage/tools.yaml` —
   review it, then run `rc build` when you're ready."**

Do not run `rc build` yourself. Do not run `docker build`. The human reviews and
triggers the build.

## What this skill is not

- Not a directive, setup tool, or config-file merger — see "Composing the
  manifest" above.
- Not a mechanism that ships recipe bodies inline — recipes live in `examples/` and
  you read them fresh each time; this file only points at them.
- Not a build trigger — it produces a reviewable file, never runs `rc build`.
- Not a cross-recipe wiring layer of its own — each recipe's `launch_args`
  combines by manifest fragment order (`rc build`'s existing mechanism); this skill
  does not add any new wiring path.
