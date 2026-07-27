# Roster resume after involuntary cage restarts — converged design (2026-07-27)

Bead: **rip-cage-xqi5** (brainstorm). Converged Socratically with the human 2026-07-27;
each core decision below was ratified explicitly (architecture, headless handling, repair
layer, work split, ADR routing). Evidence: `docs/2026-07-27-msb-spike-roster-resume.md`
(this brainstorm's live spikes S1'-S4, all phases PASS), `docs/2026-07-09-msb-spike-session-resume.md`
(rip-cage-1ujn, the foundation spike). Standing calibration from the human, applied
throughout: every design claim gets spike-(in)validated, not theorized. Canonical refs: ADR-029 D4 (reload = cold-recreate,
resume = fresh boot), ADR-005 D7/D12 (MULTIPLEXER provider contract; composable seam, no
blessed provider — FIRM), ADR-006 D7 (orchestration intelligence lives in the consumer,
never rc), ADR-006 D8 (init owns in-cage integration install).

## Problem

Every `rc reload` is a cold-recreate and every resume is a fresh kernel boot (ADR-029 D4).
Session FILES survive (host mounts + named volumes) and init re-runs each boot
(rip-cage-1ujn), but the running agent PROCESSES die and nothing re-opens them — a human
must relaunch each interrupted session pane by pane. In the factory-cage shape
(rip-cage-vjuv: one cage, whole herdr roster) one allowlist fix bounces EVERY agent, so
the deny→fix→reload repair loop stops being cheap exactly when the cage is busiest.

## Restart classes and state availability (honest mapping)

| Class | Survives | Lost | Advance notice |
|---|---|---|---|
| **Planned reload** (`rc reload`: stop → remove → recreate) | host mounts, named volumes | guest overlay (incl. `~/.config/herdr` today), all processes | yes — host-side rc initiates; graceful stop |
| **Crash** (VM kill / OOM; spike P3) | host mounts (transcripts byte-identical post-`kill -9` for completed turns), named volumes, **and** the overlay (`msb start` restarts in place, 0.178s) | processes | none; msb reports honest `crashed` status |
| **Host reboot** | presumed same as crash; **firmness gated on rip-cage-ji2t** (operator-assisted reboot check, open) | processes | none |

**Design invariant that unifies all three: resume-state must be continuously durable —
host mounts / named volumes only.** A stop-time snapshot would only cover the planned
class; the overlay only survives the crash class. Nothing in the recovery path may depend
on either. Graceful stop may *enrich* state (clean-shutdown marker) but never be
load-bearing. All three classes then collapse to one recovery path: fresh boot → init →
multiplexer `start` hook → provider rehydrates from its durable state. (Spike P3: the
artifact delta between crash and graceful stop is *zero* — only the msb status label
differs — so this collapse is evidence-backed, not aspirational.)

## The four design surfaces

### 1. Where resume-state lives: the multiplexer's own continuously-persisted roster, made durable by a recipe `mounts:` entry

Scouted fact: herdr already persists its roster continuously to
`~/.config/herdr/session.json` — per pane: `cwd`, `label`, `agent_name`, and
`agent_session {source, agent, kind: id|path, value}` (the native session reference; the
runtime is identifiable from `agent`). That is exactly the roster snapshot S2 needed —
maintained by the provider, updated on every change, no snapshot-at-stop step.

What breaks it in a cage: `~/.config/herdr` sits on the ephemeral guest overlay, so the
roster dies on every recreate. The fix is **pure composition**: the herdr recipe
(`examples/herdr/manifest-fragment.yaml`) grows a `mounts:` entry placing herdr's state
dir on a per-cage **host directory (virtiofs)** — the mount shape the manifest seam
actually emits (`_msb_flags_emit_mount` → `--mount-dir host:guest`; it has no named-volume
form). The live unix sockets in that dir are NOT a blocker: S4 found `HERDR_SOCKET_PATH`
relocates both server and client sockets, so the recipe's `start` hook points sockets at
a guest-local path and only the hardcoded, host-mount-safe files (`session.json`,
`session-history.json`, logs) live on the mount. Zero rc edits — the TOOL entry mount
seam already exists (ADR-005 D12 upheld). *(Corrected in adversarial review: an earlier
draft claimed a named-volume mount via the manifest seam, which that seam cannot emit.)*

**Fallback / repair layer — derive-from-artifacts:** spike P2 proved the roster is fully
derivable from `~/.claude/projects/*/*.jsonl` alone (session id = filename, cwd = the
`cwd` field, recency = last-record timestamp). Caveat: over-inclusive — artifacts cannot
distinguish roster-worthy sessions from throwaway `-p` one-shots, so derivation needs a
policy filter (recency / turn-count / opt-in marker). Position: this is the *diagnostic
and repair* layer (`rc doctor` fix-hints, host-side `hand ls` stale-row reconciliation),
not the primary mechanism.

### 2. Who re-spawns: the provider itself, via its existing `start` hook — no rc change, no new contract leg

Scouted fact: herdr ≥0.6.7 re-execs eligible agent panes after a server restart by
default (`[session] resume_agents_on_restore`, restore firing on the first client attach
— see the S4 resolution below), using its own per-runtime native resume table. In-cage,
every boot already re-runs init, which already dispatches the baked
`/etc/rip-cage/multiplexers/<name>/start` hook (registry dispatch, no hardcoded names).
With the state dir durable (surface 1), a fresh boot *is* a herdr server restart, and
restore fires provider-side once the scripted attach step runs.

**Consequence: the MULTIPLEXER provider contract does NOT grow a resume/rehydrate leg in
this design.** Resume is provider-internal behavior activated by durable state — which
keeps resume *policy* (whether, what, how) entirely in the provider/consumer per ADR-006
D7, and rc purely mechanical.

**The attach-gating question was spike-resolved, not deferred (S4, host-level, herdr
0.7.4):** native restore does NOT fire on server start alone (9-minute headless window,
9 eligible panes, nothing) — it fires within ~10s of a client attach, and a **scripted
headless PTY attach suffices** (python `pty.fork` + winsize ioctl; no human, no real
terminal; pane processes survive client detach). So walk-away viability holds with one
scripted attach step in the recipe's resume path (interim, recipe-owned), and the durable
fix — a herdr config flag to fire restore on server start without a client — is filed
upstream as a dotpi/herdr feature request. Ratified shape: validate-first, prefer the
herdr-side fix, scripted attach as proven interim.

### 3. Runtime-agnostic resume contract: the provider's native per-runtime table; `hand resume` is the host-side sibling

herdr's restore already dispatches per runtime (claude: interactive `--resume`; pi:
session-path leg) keyed off `agent_session.agent` — no claude-isms enter rc or the cage
init. Host-side, dotpi's `hand resume <session_id> <nudge>` is the same verb for
factory-driven single-session resumes (grants-registry warm-session check, roster-absence
check, per-runtime dispatch, nudge injection). The two are siblings by design; neither is
baked into rc.

### 4. Partial-failure semantics: degrade per-pane, never wedge the roster

- herdr's documented behavior for ineligible/stale panes: restore as a plain shell in the
  saved cwd — the pane survives visibly, the roster continues. This is the right shape.
- The ghost-metadata caveat is now explained (S4): ghost rosters are the **pre-attach
  phase** — after server boot herdr restores layout + agent metadata with zero live
  processes; the real re-exec happens on (scripted) client attach, after which
  `pane process-info` shows a genuinely live `claude --resume` process that answers
  questions from the pre-restart conversation. Any automation over a restored roster
  still liveness-checks via `pane process-info` before trusting an entry (dotpi `hand`'s
  existing discipline); a corrupt/completed/image-drifted session (rip-cage-h2hl class)
  surfaces as a dead or shell pane, not a wedged cage.
- **Ratified repair layer:** in-cage, surface-and-continue only — no in-cage auto-repair
  watchdog (would freeze roster-worthiness judgment into a daemon and race herdr's own
  restore). Repair is a **host-side `hand` batch-reconcile verb** (walk `hand ls` stale
  rows → liveness-check → `hand resume` each), operator- or factory-invoked.
  Derive-from-artifacts stays diagnostic-only (doctor-style cross-check), never
  auto-resumes — its over-inclusion needs consumer judgment per ADR-006 D7.
- **Interaction with rip-cage-6s5a** (transient state-inspect failure mid-resume silently
  creating a FRESH cage): auto-resume raises that hazard's stakes — a silently-fresh cage
  now auto-populates with resumed sessions, making the wrong world *look* continuous.
  The 6s5a review should weigh this as an argument for warn/abort over silent fallback
  (noted on that bead; not re-decided here).

## Validated / open

**Validated live (spikes 2026-07-27 + 1ujn):** single-session resume across cold-recreate
under today's rc (3.34s full loop); scripted 3/3 multi-session restore (reload→all-resumed
10.85s sequential, ≈0.3s + N×3.3s — claude relaunch dominates, parallelizable); crash-path
zero-loss for completed turns with honest msb status; derive-from-artifacts feasible
(over-inclusive, diagnostic-only); herdr native restore fires on scripted headless PTY
attach (~10s) and produces genuinely live resumed processes (S4); integration floors met
today (claude v7 ≥ 6, pi v4 ≥ 2 — S4).

**Open — carried into the implementation bead's acceptance (spike-first, per the
standing calibration), not assumed:**
1. **In-cage confirmation of the S4 result** — S4 ran host-level on herdr 0.7.4; the
   in-cage e2e (durable mount + scripted attach in the resume path + reload→roster-
   restored with N live sessions) is the impl bead's acceptance, in the factory cage.
2. **Pin bump v0.7.0 → v0.7.5** — hygiene; integration floors already met, but restore
   behavior was validated on 0.7.4.
3. **Env hygiene on the resume path** — S4 traps: resume runs through the pane's login
   shell (cage zshrc is controlled — verify no interception), and an inherited
   `CLAUDE_CODE_CHILD_SESSION` marker silently disables transcript saving (must be
   scrubbed on the spawn/resume path or restored sessions stop persisting).
4. **Host-reboot class firmness** — gated on rip-cage-ji2t (unchanged, still open).

## Resulting work (ratified split, filed ungranted at brainstorm close)

- **ADR evolution (before bead filing, via `/adr-write`)** — new decision on ADR-029
  codifying the cross-cutting rule: restart recovery depends only on continuously-durable
  state; roster resume is provider-owned; the rc MULTIPLEXER contract grows no resume
  leg. Both beads cite it.
- **rip-cage impl bead** — durable host-dir mount for `~/.config/herdr` in the herdr
  fragment (S4: the session.json path is hardcoded to `~/.config/herdr` — mount exactly
  that; sockets relocated guest-local via `HERDR_SOCKET_PATH` in the start hook),
  scripted-PTY-attach step in the recipe's resume path (interim), pin bump,
  `CLAUDE_CODE_CHILD_SESSION` scrub, spike-first in-cage e2e = reload→roster-restored
  with N live sessions. Composes with rip-cage-vjuv (factory cage stand-up).
- **dotpi bead** — upstream deltas: herdr feature request (headless restore trigger on
  server start, retiring the scripted attach), `hand` batch reconcile-after-reload verb
  (walk `hand ls` stale rows → liveness-check → `hand resume`), pi integration bump
  (v4 → v5, hygiene).
- **Comment on rip-cage-6s5a** — auto-resume amplification noted (above).
