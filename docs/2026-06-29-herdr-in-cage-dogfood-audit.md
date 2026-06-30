# Dogfood audit: herdr-in-cage (rip-cage 0.9.0)

**Date:** 2026-06-29
**Author:** Claude (dogfooding session, run from the `resume` project on the mac-mini)
**Purpose:** Findings from setting up and running `herdr` as the in-cage multiplexer, to align with the rip-cage agent on architecturally sound fixes. This is a *report*, not a patch — fix decisions are deferred to the rip-cage agent.

> **Evidence discipline:** Claims marked **[verified]** were observed directly via `rc exec` against a live cage (`personal-resume`, built from this repo's `rc build`, image `rip-cage:latest`, 2026-06-29). Claims marked **[source]** come from reading repo files. Claims marked **[inferred — verify]** are second-hand or deduced and should be checked before acting.

---

## 0. What was done (the dogfood)

Intended workflow being dogfooded (per dotpi epic *"Self-driving bead factory — AFK recursive orchestration"*): instead of `mosh mac-mini` → `herdr` on the host, run `mosh mac-mini` → `rc up <project>` → herdr **inside** the cage, with pi/claude agents as supervised panes.

Steps taken:
1. Upgraded `rc` 0.8.0 → **0.9.0** (`brew upgrade rip-cage`; the tap had lagged the repo `VERSION` until `brew update`).
2. The global `~/.config/rip-cage/tools.yaml` already had the `herdr-bin` TOOL + `herdr` MULTIPLEXER entries, but pinned to a **stale v0.6.10**. Bumped to the latest **v0.7.1**, downloaded both linux binaries, computed fresh SHA-256s, repinned. Build verified `/tmp/herdr: OK`.
3. Added `resume/.rip-cage.yaml` → `session.multiplexer: herdr`.
4. `rc build` (herdr v0.7.1 baked + start/attach hooks into `/etc/rip-cage/multiplexers/herdr/`), then `rc up`.

### What works ✅
- **[verified]** herdr v0.7.1 server starts inside the cage via the baked start hook (`PID=193`), socket at `/home/agent/.config/herdr/herdr.sock`, client/server protocol-compatible.
- **[verified]** claude's herdr integration installs cleanly (`herdr integration installed: claude`).
- **[verified]** claude auth survives into the cage (`rc doctor` → `auth: OK — ~/.claude/.credentials.json present`), despite a scary boot warning (see Finding 4).
- **[verified]** egress firewall, ssh-forwarding (2 keys), git identity all green.

The end-to-end plumbing is sound. Two real defects degrade the workflow (Findings 1 & 2); two are minor (Findings 3 & 4).

---

## Resolution (2026-06-29 — epic rip-cage-l72i)

**Finding 1 (pi↔herdr integration fails in cage) — RESOLVED.** Root cause was narrower than the audit inferred: the ADR-025→027 guard migration was already shipped in HEAD; the real blocker was the *launch leg* — `pi-wrapper.sh` forced `--no-extensions -e <dcg-gate>` with a single hardcoded `SUBAGENT_EXT` slot, so `herdr integration install pi`'s extension (written to the agent-owned `~/.pi/agent/extensions/`) was silently ignored. Fixed by **ADR-027 D4** (manifest-declared `launch_args`/extensions assembled by `rc build` into a generic guard-first pi shim — no hardcoded cross-recipe paths; recipes are inspiration, not machinery): herdr's pi extension now composes as an `examples/herdr-pi/` recipe fragment (`herdr integration install pi` via public CLI → `ro`-mount + `launch_args -e`), loaded alongside the DCG guard. Live-verified by a real RC_E2E composed DCG+herdr+pi cage.

**Open Question 1 (is herdr-in-cage first-class?) — YES**, via the composable `examples/herdr-pi/` recipe (opt-in composition, ADR-005 D12). **Open Question 2 (is the ADR-025→027 pi-guard migration sanctioned?) — YES**, it landed (wlwc.2/.3/.4) and ADR-027 is now ACCEPTED; D4 completes the launch-leg so the guard-vs-integration collision is dissolved (guard on its own root-owned path + `--no-extensions` + explicit manifest-declared `-e` set; the herdr ext is one of those `-e` entries). **Finding 3 (stale herdr pin) — RESOLVED** (`examples/herdr` bumped v0.6.10→v0.7.0, computed SHAs, provenance comment fixed — rip-cage-1pgp.2).

**Still open:** Finding 2 (broken skill symlinks, Open Question 3) is tracked under epic rip-cage-1pgp, not this epic. Finding 4 (keychain warning) likewise. A pre-existing floor defense-in-depth gap surfaced during this work — manifest-mount dests aren't denylisted against reserved cage paths — filed as rip-cage-rc09.

---

## Finding 1 — pi↔herdr integration fails inside the cage (P1)

**Symptom [verified]:** During cage init, the herdr start hook installs integrations for agents on PATH. claude succeeds; **pi fails**:

```
[rip-cage] herdr integration installed: claude
[rip-cage] WARNING: herdr integration install pi failed (exit=1): Permission denied (os error 13)
```

`herdr integration install pi` re-run by hand inside the cage reproduces it verbatim: `Permission denied (os error 13)`.

**Impact:** herdr cannot register its pi extension, so it gets **no semantic working/idle status** for pi panes inside the cage — it falls back to screen-detection. For a herdr-as-cockpit-over-parallel-pi workflow, that is precisely the signal the cockpit depends on (cf. ADR-006 D8 semantic status). pi still *runs*; the supervision surface is degraded, not dead.

### Root cause [verified]

The pi config tree in the cage has **mixed ownership**:

```
drwxr-xr-x root  root   /home/agent/.pi                      # root-owned
drwxr-xr-x agent agent  /home/agent/.pi/agent                # agent-owned (init chowns this)
drwxr-xr-x root  root   /home/agent/.pi/agent/extensions     # root-owned  ← herdr's write target
-rw-r--r-- root  root   /home/agent/.pi/agent/extensions/dcg-gate.ts
```

herdr writes its pi integration into `~/.pi/agent/extensions/`. That directory is **root-owned**, the agent runs as uid 1000, so the write is denied. claude's integration target (`~/.claude`) is agent-owned, which is why claude succeeds. (Confirmed I could not even `touch` inside `~/.pi` — top-level is also root-owned, but the operative blocker is `extensions/`.)

### Why `extensions/` is root-owned — and the real tension

This is **not** a simple "missing chown." `extensions/` is root-owned *on purpose*, to protect the baked DCG guard from agent tampering:

- **[verified]** The pi wrapper `/usr/local/bin/pi` loads the guard from inside this dir:
  ```
  DCG_GATE="/home/agent/.pi/agent/extensions/dcg-gate.ts"
  SUBAGENT_EXT="/home/agent/.pi/agent/extensions/subagent/index.ts"
  VETTED_EXTENSIONS=("--no-extensions" "-e" "$DCG_GATE")
  ```
  The wrapper's own comments cite **ADR-025 D3/D4** and expect the guard + subagent extension to live in `~/.pi/agent/extensions/`.
- **[verified]** `/etc/rip-cage/pi/` does **not exist** in the shipped 0.9.0 image.

So in the **shipped image**, the guard lives in `~/.pi/agent/extensions/` and that dir is root-owned to keep the guard tamper-proof. That requirement **directly collides** with herdr needing the same directory agent-writable to drop its integration. Two correct-sounding requirements, same directory:

| Requirement | Wants `extensions/` to be |
|---|---|
| DCG guard tamper-proofing (ADR-025 D3/D4) | **root-owned** |
| herdr integration install (ADR-006 D8) | **agent-writable** |

### Shipped-vs-intended drift [source / inferred — verify]

There is evidence of a half-finished migration that, if completed, would resolve the collision:

- `init-rip-cage.sh` (lines ~34–42) chowns **only** `~/.pi/agent` (top-level, not `-R`) and its comment asserts: *"extensions/ is no longer root-owned (olen retired per ADR-027 D1/D3 — the DCG guard now lives at `/etc/rip-cage/pi/dcg-gate.ts` on its own separate root-owned load path)."* **[source]**
- That comment **contradicts the shipped image** [verified]: the guard is still loaded from `~/.pi/agent/extensions/dcg-gate.ts`, `extensions/` is still root-owned, and `/etc/rip-cage/pi/` doesn't exist.

So **ADR-027 (separate root-owned guard load path + agent-owned `extensions/`) appears designed but not realized in the image.** The herdr-in-cage failure is most likely a *symptom of that incomplete ADR-025 → ADR-027 migration*. The init comment's "not `-R` on purpose because extensions/ is agent-owned now" reasoning is stale relative to what `rc build` actually produces.

> **Note on a second-hand reading:** an earlier sub-investigation cited ADR-019 D1 / ADR-027 D1 as if `extensions/` were *already* agent-owned by design. The live image shows that is **not** the shipped reality. Treat ADR-027 as target-state to verify, not current-state.

### Architectural options (for the rip-cage agent to weigh)
- **(A) Complete the ADR-027 migration:** move the guard to its own root-owned load path (`/etc/rip-cage/pi/dcg-gate.ts`), load via the wrapper from there, and make `~/.pi/agent/extensions/` agent-owned. Cleanly separates "tamper-proof guard" from "agent-writable integrations." Most aligned with the documented intent; biggest change surface.
- **(B) Keep guard in `extensions/` but split integration target:** mount/agent-own a sibling integrations dir herdr writes into, while the guard file stays root-owned in place. Smaller change; needs herdr to honor a configurable extension path (verify herdr supports this).
- **(C) Narrow chown:** chown just `~/.pi/agent/extensions/` to agent but keep `dcg-gate.ts` itself root-owned (file-level immutability inside an agent-owned dir). Smallest change, but weakens the tamper-proofing guarantee (agent could rename/replace files in a dir it owns) — likely **rejected** on the same grounds ADR-025 exists.

**Open question for alignment:** is the ADR-025→ADR-027 migration the sanctioned direction, and is herdr-in-cage a first-class supported config that should gate on it? (If herdr-in-cage is meant to be supported now, this is a release blocker for that recipe.)

---

## Finding 2 — 21 broken skill symlinks inside the cage (P2)

**Symptom [verified]:** `rc doctor` → `skills-mount: WARN — 55 entries, 21 broken symlink(s)`. The 21 broken skills include: `guide, secrets-via-stdin, bd-memories-write, ast-grep, mermaid-diagrams, subagents, static-site-publish, web-fetch, yt-transcript, worktree, herdr, bd-drift-review, bd-roadmap-tldr, publish-harness, steal-design, install-substrate, web-perf, tldr, browser-automation, turnstile-spin, sync-substrate`.

**Impact:** Those skills don't resolve inside the cage — unavailable to caged agents. Several are workflow-load-bearing (`subagents`, `tldr`, `bd-roadmap-tldr`, `web-fetch`, `browser-automation`, `herdr` itself).

### Root cause [verified]

The broken skills are **relative symlinks** authored against the host home:

```
~/.claude/skills/guide -> ../../code/personal/dotpi/agent/skills/guide
~/.claude/skills/herdr -> ../../code/personal/dotpi/agent/skills/herdr
(… all 21 follow ../../code/personal/dotpi/agent/skills/<name>)
```

Skills that **work** in the cage are *real directories* in `~/.claude/skills` (e.g. `brainstorm`, `recall`, `decompose` — `readlink` returns empty), served directly by the `~/.claude/skills` ro mount.

Inside the cage, the skills mount lives at **`/home/agent/.rc-context/skills/`**. Resolving `../../code/personal/dotpi/agent/skills/<name>` relative to that path yields **`/home/agent/code/personal/dotpi/agent/skills/<name>`** — which is **not mounted**. rip-cage *does* bind-mount the dotpi target, but at its **host-absolute path** `/Users/jonatanpi/code/personal/dotpi/agent/skills` (per `rc up` dry-run: *"skill symlink target"*). The relative link, anchored at the cage home `/home/agent`, never reaches the host-absolute mountpoint. Classic **host-home (`/Users/jonatanpi`) vs cage-home (`/home/agent`) path mismatch under relative symlinks.**

### Architectural options
- Mount the dotpi skills target *also* at the cage-relative-resolvable path (`/home/agent/code/personal/dotpi/agent/skills`) so `../../` resolves.
- Or rewrite host symlinks to absolute targets that match a mounted path (couples host substrate layout to the cage).
- Or have the skills-link step in `init-rip-cage.sh` re-materialize symlink targets inside the cage home instead of relying on host-relative links resolving.
- Most robust: detect symlinks whose targets escape the mounted tree and re-point/re-mount them at init (and surface the count, which `rc doctor` already does well).

**Open question:** is `~/.rc-context/skills` *meant* to dereference host-relative symlinks, or should the skill projection resolve+copy at init (parallel to the pi-substrate "linked from host" logic)?

---

## Finding 3 — stale herdr recipe in `examples/herdr/` (P3, repo hygiene)

**[source]** `examples/herdr/manifest-fragment.yaml` and `examples/compose-rc-with-herdr.md` pin **v0.6.10** (latest is **v0.7.1**). Two issues:
1. The pin is ~2 minor versions behind; a fresh user composing herdr gets an old binary.
2. The comment says *"SHA-256 checksums sourced from GitHub API release asset digest field."* The GitHub release API does **not** expose per-asset sha256 digests that way — I had to download both binaries and `shasum -a 256` them. The comment is misleading and will send someone down a dead end.

**What I changed (host-local only, not this repo):** bumped my `~/.config/rip-cage/tools.yaml` `herdr-bin` to v0.7.1 with freshly computed SHAs:
- `herdr-linux-aarch64`: `3d757ac30c631e79dc45038c3ecc6423fe13a89f9cffa0f415aedd2c27f1576c`
- `herdr-linux-x86_64`: `b965acaffc2c22f54b6e6c64af7cf8e98a3f4ac2622630a0599c67a4b9d8a654`

**Suggested repo fix:** bump the example pin to v0.7.1, correct the SHA-provenance comment to "computed from downloaded release assets," and consider documenting a `herdr update`-in-cage story (the cage herdr and host herdr are independent servers; they need not match versions).

---

## Finding 4 — noisy keychain warning at boot despite auth succeeding (P3, cosmetic but alarming)

**[verified]** `rc up` prints, prominently:

```
Warning: failed to extract credentials from macOS keychain — auth may not work inside container
  Run 'claude auth login' on the host to set up credentials, or set ANTHROPIC_API_KEY
```

…yet `rc doctor` later reports `auth: OK — ~/.claude/.credentials.json present` and claude works. The warning appears to be a transient/false alarm (keychain momentarily unavailable during init while credentials still arrive via the `.credentials.json` path). It reads as a hard failure and would make a new user think the cage is broken.

**Suggested fix:** either retry keychain extraction, or downgrade the message and reconcile it with the actual post-init auth state (don't warn "auth may not work" when `.credentials.json` is present).

---

## Open questions for the rip-cage agent (alignment agenda)

1. **Is herdr-in-cage a first-class supported config today?** If yes, Finding 1 is a blocker for it. If it's experimental, the docs should say so.
2. **Is the ADR-025 → ADR-027 pi-guard migration the sanctioned direction** (separate root-owned guard load path + agent-owned `extensions/`)? Completing it appears to dissolve the guard-vs-integration collision (Finding 1, option A).
3. **What's the intended contract for `~/.rc-context/skills`** — dereference host-relative symlinks (needs the target re-mounted at a cage-resolvable path) or resolve+copy at init (Finding 2)?
4. **Should the broken-symlink WARN be a fail-loud** for skills that are load-bearing, or is silent degradation acceptable?

---

## Appendix — reproduction & raw evidence

Environment: mac-mini (`Jonatans-Mac-mini.local`), host, OrbStack. rip-cage repo `feat`/`main` ahead by 3 commits (clean otherwise). Cage `personal-resume`, image `rip-cage:latest` from `rc build` on 2026-06-29.

```bash
# Setup
brew upgrade rip-cage                       # 0.8.0 -> 0.9.0
# edit ~/.config/rip-cage/tools.yaml: herdr-bin v0.6.10 -> v0.7.1 (+ fresh SHAs)
# write resume/.rip-cage.yaml: session.multiplexer: herdr
rc build                                    # bakes herdr v0.7.1 + hooks
rc up .                                      # starts cage + herdr server

# Finding 1 repro
rc exec personal-resume -- herdr integration install pi
#   -> Permission denied (os error 13)
rc exec personal-resume -- ls -ld /home/agent/.pi /home/agent/.pi/agent /home/agent/.pi/agent/extensions
#   -> .pi root-owned, .pi/agent agent-owned, extensions/ root-owned
rc exec personal-resume -- sh -c 'grep DCG_GATE /usr/local/bin/pi'
#   -> DCG_GATE="/home/agent/.pi/agent/extensions/dcg-gate.ts"
rc exec personal-resume -- ls /etc/rip-cage/pi/        # -> No such file or directory

# Finding 2 repro
rc doctor personal-resume                              # skills-mount: WARN 21 broken
rc exec personal-resume -- sh -c 'find -L /home/agent/.rc-context/skills -maxdepth 2 -type l'
readlink ~/.claude/skills/herdr                        # -> ../../code/personal/dotpi/agent/skills/herdr
```

Cleanup when done dogfooding: `rc down personal-resume` (and `rm resume/.rip-cage.yaml` if reverting that project to no-multiplexer).
