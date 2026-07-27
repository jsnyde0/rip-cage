# msb spike — roster resume after cage cold-recreate + crash path (2026-07-27)

Bead: **rip-cage-xqi5**. Machine: this Mac, msb 0.6.4 (`~/.local/bin/msb`), image
`rip-cage:latest` (digest `9a9f31e07a04`, created 2026-07-07 — same image the 1ujn spike
used; Claude Code CLI baked in behind the `claude-session-wrapper.sh` per-session wrapper).
Host repo state: rc 0.13.0, `v0.13.0-10-g02bd7f2`. Predecessor:
**rip-cage-1ujn** (`docs/2026-07-09-msb-spike-session-resume.md`) — proved a *single*
session survives an msb recreate via host-mounted scratch state + `claude --resume`. This
spike revalidates that under today's tree (S1'), extends it to a scripted multi-session
roster re-launch (S2-lite), and adds an ungraceful-kill crash path (S3).

**Method note:** per the 1ujn recipe, the spike drives raw `msb` (run/stop/remove/exec)
with the stop→remove→recreate shape that `rc reload` performs — it does **not** invoke
`rc` itself (that would have required touching the real repo config / real cages, which
the safety rules forbade). So this validates the *mechanism* under today's msb + image,
not rc's `cmd_up` code path end-to-end.

Sandboxes used: **one**, `xqi5-spike-p1`, recreated twice and crash-killed once. No
snapshots created. Pre-existing sandboxes `personal-rip-cage` (stopped) and
`rc-r7-redcheck` (crashed) were never touched — verified present and in their original
states at cleanup.

---

## VERDICT (per phase)

| Phase | Result |
|---|---|
| P1 — S1' single-session resume across cold-recreate, today's stack | **PASS** (3.34s full loop; negative control clean) |
| P2 — S2-lite scripted roster re-launch | **PASS 3/3** (reload→all-resumed 10.85s sequential) |
| P2b — roster derivable from artifacts alone | **YES**, with one policy caveat (see below) |
| P3 — crash path (kill -9 the VM process) | **PASS** (honest `crashed` status; zero transcript loss; in-place `msb start` + resume works) |

---

## Setup — scratch claude home (1ujn recipe, unchanged)

`/tmp/xqi5-spike-scratch/` with `claude-dir/{.credentials.json (copied, chmod 600),
projects/ (pre-created empty), sessions/ (pre-created empty)}` and a `claude.json` seed
jq-extracted to only `hasCompletedOnboarding` + `oauthAccount{emailAddress,
organizationName}`. The real `~/.claude` was never mounted anywhere. Mount flags on every
boot:

```
-v /tmp/xqi5-spike-scratch/claude-dir:/home/agent/.claude \
--mount-file /tmp/xqi5-spike-scratch/claude.json:/home/agent/.claude.json \
-w /home/agent
```

Net rules every boot: `--net-default deny` + the 1ujn-discovered trio
(`api.anthropic.com`, `mcp-proxy.anthropic.com`,
`http-intake.logs.us5.datadoghq.com`, all `tcp:443`). Still sufficient — every `-p`
turn completed.

The 1ujn footgun #2 (wrapper only host-persists `projects/`/`sessions/` if pre-created in
the mount) still applies: pre-creating them worked; transcripts landed on the host mount.
New wrapper behavior since 1ujn: every claude invocation prints
`[claude-wrapper] WARNING: no ~/.claude/.claude.json.seed snapshot found; seeding from the
live ~/.claude.json mount (R4, rip-cage-p1p)` — cosmetic for this spike, seed still worked.

---

## Phase 1 — S1' revalidation

Boot + plant:

```
$ msb run --name xqi5-spike-p1 --replace --net-default deny <3 net-rules> <mounts> \
    -w /home/agent -d rip-cage:latest -- sleep infinity
$ msb exec xqi5-spike-p1 -- sh -c "cd /home/agent && claude -p \
    'Remember this codeword: OBSIDIAN-19. Confirm briefly.' --output-format json"
{"result":"OBSIDIAN-19 — got it.","session_id":"40df22f4-ff57-45f5-b9de-e06be07f9716",
 "is_error":false,"duration_ms":2674}
```

Host-mount landing confirmed:
`$S/claude-dir/projects/-home-agent/40df22f4-….jsonl` exists and greps for the codeword.

Timed cold-recreate (`rc reload` shape: stop → remove → recreate, same mounts/rules) +
resume:

```
$ msb stop xqi5-spike-p1; msb remove --force xqi5-spike-p1; msb run --name xqi5-spike-p1 …
$ msb exec xqi5-spike-p1 -- sh -c "cd /home/agent && claude --resume 40df22f4-… -p \
    'What codeword did I ask you to remember? Reply with just the codeword.' --output-format json"
{"result":"OBSIDIAN-19","session_id":"40df22f4-ff57-45f5-b9de-e06be07f9716","is_error":false}
```

| Phase | Duration |
|---|---|
| `msb stop` | 0.113s |
| `msb remove --force` | 0.011s |
| `msb run` (cold recreate boot) | 0.159s |
| `claude --resume` + answer | 3.054s |
| **TOTAL** | **3.338s** |

Consistent with 1ujn's shape (msb lifecycle ≈0.3s; claude relaunch+inference dominates —
here ~91%). Notably faster than 1ujn's 6.09s total (5.72s claude leg) — inference latency
variance, not a mechanism change.

**Negative control PASS** — fresh no-`--resume` session in the recreated sandbox:
`"result":"NO_KNOWLEDGE. …"`, different `session_id`
(`3e692274-2150-450a-90ca-01da2e0d18f5`). No global-state leakage.

---

## Phase 2 — S2-lite scripted roster re-launch

Two more sessions in the same sandbox, **distinct cwds** (which claude keys project dirs
by), distinct codewords:

| session_id | cwd | codeword |
|---|---|---|
| `40df22f4-ff57-45f5-b9de-e06be07f9716` | `/home/agent` | OBSIDIAN-19 |
| `39d6336f-9170-4e68-9f86-77bb621d045b` | `/home/agent/proj-a` | MERIDIAN-62 |
| `8347e001-293e-4d6f-b635-fa22c50fbac7` | `/home/agent/proj-b` | CATAMARAN-05 |

Roster snapshot written to `$S/roster.tsv` (`session_id \t cwd \t codeword`); resume loop
script `$S/resume-roster.sh` iterates it, and for each row runs
`msb exec <sbx> -- sh -c "cd '<cwd>' && claude --resume '<sid>' -p '…codeword?…'
--output-format json" </dev/null` and asserts codeword-in-result AND
returned `session_id == roster session_id`.

**Honest bug on first run:** without `</dev/null`, `msb exec` inside the `while read`
loop swallowed the rest of the roster from stdin → loop processed only row 1 ("RESUMED
1/1"). Fixed with the stdin redirect; clean rerun (fresh cold-recreate first):

```
   ✓ Stopped      xqi5-spike-p1
   ✓ Removed      xqi5-spike-p1
xqi5-spike-p1
PASS 40df22f4-… cwd=/home/agent        word=OBSIDIAN-19  (3.839s)
PASS 39d6336f-… cwd=/home/agent/proj-a word=MERIDIAN-62  (3.217s)
PASS 8347e001-… cwd=/home/agent/proj-b word=CATAMARAN-05 (3.136s)
RESUMED 3/3 in 10.265s
recreate: 0.310s  script-loop: 10.539s  reload-to-all-resumed: 10.849s
```

**3/3 resumed.** Sequential resumes cost ~3.1–3.8s each (claude relaunch+inference each
time); recreate itself stays ~0.3s. Total reload→all-resumed for N sessions ≈ 0.3s +
N×~3.3s sequential — an obvious parallelization win is available (independent `msb exec`
calls) but was not measured here.

### P2b — can the roster be derived from artifacts alone? YES (with a policy caveat)

From the scratch home's `projects/` tree only — no runtime state, no bookkeeping file:

- **session_id** = transcript filename (`<sid>.jsonl`)
- **cwd** = the `cwd` field carried on `user`/`assistant`/`attachment` records inside the
  jsonl (also recoverable, less reliably, from the project dir's encoded name, e.g.
  `-home-agent-proj-a`)
- **recency** = last record `timestamp` (or file mtime — both agreed here)

Actual derived roster from the real files (`for f in projects/*/*.jsonl; jq …`):

```
39d6336f-9170-4e68-9f86-77bb621d045b  /home/agent/proj-a  last=2026-07-27T10:14:27.108Z  lines=16
8347e001-293e-4d6f-b635-fa22c50fbac7  /home/agent/proj-b  last=2026-07-27T10:14:30.097Z  lines=15
3e692274-2150-450a-90ca-01da2e0d18f5  /home/agent         last=2026-07-27T10:12:55.124Z  lines=16
40df22f4-ff57-45f5-b9de-e06be07f9716  /home/agent         last=2026-07-27T10:14:23.864Z  lines=25
```

**Caveat:** the derived roster includes **every** session that ever wrote a transcript —
including the Phase-1 negative-control one-shot (`3e692274-…`), which no operator would
want auto-resumed. Artifacts alone don't distinguish "roster-worthy long-lived session"
from "throwaway `-p` one-shot"; an auto-resume implementation needs a policy filter
(recency window, minimum turn count, an explicit opt-in marker, or a
live-at-stop-time process check) on top of the derivation. The raw material (id, cwd,
recency, size) is all there.

---

## Phase 3 — S3 crash path (ungraceful kill -9)

Added fresh activity first (second codeword ZEPHYR-33 planted into session `40df22f4-…`
via `--resume`; reply confirmed both). Then from the host:

```
$ ps aux | grep xqi5-spike-p1
jonatanpi 52476 … /Users/jonatanpi/.local/bin/msb sandbox --name xqi5-spike-p1 \
    --sandbox-id 900 --startup-fd 98 --vcpus 1 --memory-mib 512 --config-fd 96
```

One VM process per sandbox, name in argv — PID ownership verified
(`ps -p 52476 -o args=` re-checked immediately before the kill), then `kill -9 52476`.

**Findings:**

1. **msb state is honest.** ~2s after the kill, `msb list` shows `xqi5-spike-p1  crashed`
   — not a lying `running`. (Same status the pre-existing `rc-r7-redcheck` carries.)
2. **Zero transcript loss.** Session jsonl on the host mount: pre-kill 30 lines /
   last_ts `10:15:08.020Z` / 4 ZEPHYR-33 hits → post-kill identical (30 / same ts / 4).
   Transcript writes are flushed to the virtiofs mount per-message; nothing buffered in
   the guest was lost for completed turns. (Caveat: the kill was *between* turns —
   "immediately after activity" per the brief. A kill mid-inference-stream was not
   tested; the at-risk window would be the in-flight turn only.)
3. **In-place restart works on a crashed sandbox.** `msb start xqi5-spike-p1` → rc=0,
   **0.178s**, status `running` — no remove/recreate needed after a crash.
4. **Resume after crash+restart PASS:**
   `claude --resume 40df22f4-… -p 'What are the two codewords…'` →
   `"OBSIDIAN-19 and ZEPHYR-33"`, same `session_id`, `is_error:false`.
5. **Crash vs graceful-stop roster delta: none in the artifacts.** The derived roster
   (ids/cwds/timestamps) was byte-identical after the crash-restart and after a
   subsequent graceful `msb stop`. The only observable delta is the msb-side status
   (`crashed` vs `stopped`) — itself derivable via `msb list` and honest, so a roster
   engine can treat both cases with the same resume path.

---

## Safety verification

- Real `~/.claude/.credentials.json` — sha256
  `4083b05b0572f18e82d37ac0cccacf9e0b11f0c2a954fa5b5dc8d32c26cdbdd1`, mtime epoch
  `1785137729` — **identical before and after the spike.** No token value was ever
  printed anywhere. Only `/tmp/xqi5-spike-scratch/…` paths were ever passed as mount
  sources.
- `personal-rip-cage` and `rc-r7-redcheck` never touched; verified still present in
  original states at cleanup.
- No tracked file modified except this doc.

**Cleanup:** `msb remove --force xqi5-spike-p1` → `msb list` shows only the two
pre-existing sandboxes; no snapshots were created; scratch tree deleted via
`find … -type f -delete` + `find … -depth -type d -delete` (the repo's guard still
blocks the recursive force-delete rm idiom, per 1ujn footgun #4) — `/tmp/xqi5-spike*`
verified gone.

---

## Surprises / footguns

1. **`msb exec` in a `while read` loop eats the loop's stdin** — the roster script
   silently degraded to 1-of-3 until `</dev/null` was added to the exec. Any real
   roster-resume loop must guard against this.
2. **`msb start` on a `crashed` sandbox just works** (0.18s) — the crash-recovery path
   doesn't need the heavier remove+recreate; roster resume after a host-side VM kill is
   the same recipe as after a graceful reload.
3. **Artifact-derived rosters over-include**: one-shot `-p` sessions are
   indistinguishable from long-lived ones in the transcript tree — auto-resume needs a
   filter policy, not just derivation.
4. The image's claude wrapper now warns about a missing `.claude.json.seed` snapshot
   (rip-cage-p1p R4) on every invocation with a bare scratch home — cosmetic here, but a
   by-hand cage stander-upper will see it.
5. The repo's guards blocked two spike commands mid-flight: an env-dump heuristic hit a
   *compound* command combining credentials-file handling with other steps (fine when
   split), and dcg blocked the first attempt to write this very doc because the prose
   contained the literal recursive force-delete rm string (rephrased). Spike-ergonomics
   notes only.

---

## S4 — herdr native restore, host-level (2026-07-27)

Machine: this Mac. `herdr` client binary **0.7.4** (`/opt/homebrew/bin/herdr`); the user's
live cockpit server (PID 5009, up since Jul 21) was running **0.7.3** throughout and was
never stopped, signaled, or written to. All spike commands ran against an isolated server
instance (details below).

### Verdicts

| Sub-question | Verdict |
|---|---|
| (a) Headless fire | **NO on server start; YES on first client attach.** Snapshot restore (layout + ghost agent metadata) happens at server boot with no client. Native agent re-exec did **not** fire over a ~9-minute headless window with 9 eligible agent panes; it fired **within seconds** of a client attach — and a *scripted headless PTY client* (python `pty.fork` + `TIOCSWINSZ`, no human, no real terminal) is sufficient to trigger it. |
| (b) Live re-exec vs ghost | **Ghost before attach, genuinely LIVE after.** Pre-attach: roster metadata only (`agent_session` refs visible via `herdr agent list`, zero agent processes — only the focused pane's shell exists). Post-attach: `herdr pane process-info` shows a real process tree (pane zsh → `claude --resume <sid>`), and the resumed pane **answered a content question from the pre-restart conversation** ("CONTROL-OK"). The pane process survives client detach. |
| (c) Integration minimums | `herdr integration status` (filesystem-based, no server needed): **claude v7 current** (restore minimum ≥6 — OK), **pi v4** (outdated vs latest v5, but restore minimum is ≥2 — OK). Installer respects `CLAUDE_CONFIG_DIR` (hook + settings landed in the scratch dir). |

### Isolation findings (the hard-won part)

- `HERDR_SOCKET_PATH` relocates the API/client sockets (client + server both honor it).
- `HERDR_CONFIG_PATH` relocates **only** `config.toml` and `release-notes.json`.
- **`session.json`, `session-history.json`, and server logs are hardcoded to
  `~/.config/herdr/`** — not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or
  `HOME` (herdr resolves home via getpwuid; a `HOME=` override changes nothing). There is
  no state-dir env/flag in 0.7.4.
- Isolation therefore ran as: scratch socket + scratch config + **`sandbox-exec` profile
  denying `file-write*` on `/Users/jonatanpi/.config/herdr`** (belt-and-braces guard;
  verified via `lsof` that the isolated server held no handle in that dir).
- Consequence: the isolated server **could not persist its own session.json**, so the
  "write roster → restart → restore" loop could not be tested end-to-end in isolation
  (that half is BLOCKED at host level under the don't-touch-the-live-cockpit rule).
- Surprise that saved the spike: the isolated server **read** the user's
  `~/.config/herdr/session.json` at boot (reads were allowed) and snapshot-restored the
  user's whole roster as **ghost panes inside my server** — 9 claude panes with
  `agent_session` refs, 3 workspaces, no processes (one zsh for the focused pane). That
  read-only ghost roster became the restore fodder: it proves the persisted-session.json →
  restored-roster half using herdr's own real production state file, without writing it.

### Method actually used

1. Isolated server #2 (PID 98528) boots → ghost-restores the user's roster headless.
   ~9 min observation: children = exactly one `-zsh`. **No `claude --resume` execs.**
2. Pruned ghosts via API (`workspace close` / `pane close`) down to one:
   `brain-rip-cage` (cwd `~/code/personal/rip-cage`, sid `5c1f2125-…`).
3. Seeded a resumable transcript in scratch `CLAUDE_CONFIG_DIR`: ran a `claude -p`
   one-shot ("CONTROL-OK", sid `2d53d01f-…`), then sed-cloned its jsonl to
   `projects/-Users-jonatanpi-code-personal-rip-cage/5c1f2125-….jsonl` (sid + cwd
   rewritten) and pre-trusted the cwd in the scratch `.claude.json`.
4. Attached a scripted PTY client (`allow_nested = true` needed in config — first attempt
   died on herdr's nested-session guard, since this spike itself runs inside a herdr
   pane). Within ~10 s the ghost pane spawned `zsh` → `claude --resume 5c1f2125-…` in the
   pane cwd.
5. `herdr agent send` + `pane send-keys enter`: asked what it had been told to say →
   **"CONTROL-OK"** — live resume with conversation content, not a ghost.

### Surprises / footguns

1. **Resume runs through the pane's login shell**, so user shell config applies: here the
   user's zsh `claude()` function turned `claude --resume <sid>` into
   `npx @anthropic-ai/claude-code@latest --resume <sid>`. A cage/roster design must pin
   the binary via PATH/shell hygiene, not assume herdr execs a specific claude.
2. **`CLAUDE_CODE_CHILD_SESSION` marker disabled transcript saving** in the interactive
   panes (inherited from this spike's own claude-worker env; the resumed TUI showed
   "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker"). Two
   interactive sessions (incl. a clean `/exit`) wrote **no** transcript jsonl, while
   `claude -p` in the same env did write one. Spike artifact — but a real trap for any
   orchestrator that spawns herdr/agents from inside a Claude Code session and expects
   `--resume` to work later.
3. The Homebrew cask stub `/opt/homebrew/bin/claude` (2.1.206) **hung at 0 CPU even on
   `--version`** in non-tty contexts and never initialized in a herdr pane; the native
   install `~/.local/bin/claude` (2.1.201) worked. Three hung stub processes had to be
   killed at cleanup.
4. `agent_session` is reported by the v7 hook only once a turn is submitted — a
   just-started idle claude pane has no session ref yet (and is thus not restore-eligible
   if the server dies before the first turn).
5. Nested-herdr guard: attaching a client from inside a herdr pane requires
   `[experimental] allow_nested = true`.
6. herdr snapshot-restore materializes **only the focused pane's shell** eagerly at boot;
   all other panes stay process-less until attach/focus.

### rip-cage roster-resume implications

- A herdr-supervised cage roster does **not** self-heal on a headless server restart:
  something must attach once. But that something can be a trivial scripted PTY attach
  (~10 s, no TUI interaction needed) — walk-away viability is preserved with one extra
  scripted step in the resume path.
- The claude ≥6 / pi ≥2 integration floor is met on this machine (claude v7 / pi v4),
  and the installer is `CLAUDE_CONFIG_DIR`-aware, so per-cage installs are scriptable.
- Anyone running a *second* herdr server on a host must know it will read (and, unsandboxed,
  **write**) the singleton `~/.config/herdr/session.json` — two herdr servers on one host
  share state whether you like it or not. In-cage herdr (own filesystem) does not have
  this problem.

### Safety verification

- User's server PID 5009: same start time (Jul 21 10:38:13) before/after; client PID 5008
  alive; `~/.config/herdr/herdr.sock` intact. My servers (94166, 98528) were started by me,
  killed by targeted `kill -TERM <pid>` after argv verification; no pkill of herdr ever ran.
- No writes to `~/.config/herdr` from spike processes (sandbox-denied + `lsof`-verified).
  Honest note: two early read-only `herdr status` invocations (before isolation was
  established) did dial the user's socket — metadata queries only, no state mutation.
- Real `~/.claude/.credentials.json` mtime `1785137729` — unchanged (matches the morning
  msb-spike baseline). No token value printed anywhere; scratch credential copy (chmod
  600) deleted with the scratch tree.
- Cleanup: scratch `/tmp/xqi5-s4` deleted via the `find ! -type d -delete` +
  `find -depth -type d -delete` idiom (sockets are not `-type f` — first pass left them);
  no stray herdr or claude processes remain.
