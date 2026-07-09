# msb spike — beads embedded-Dolt over virtiofs: locking + host/guest concurrent writes (2026-07-09)

Bead: **rip-cage-9iab**. Epic: rip-cage-tsf2. Machine: mac mini, msb v0.6.4
(`/Users/jonatanpi/.local/bin/msb`), image `rip-cage:latest` (host bd: `bd version 1.1.0 (Homebrew)`;
guest baked-in bd: `bd version 1.0.5 (dev)`). Sandbox prefix `bdvfs-` used throughout, all removed at
cleanup. Feeds rip-cage-1mkq's substrate matrix (incumbent x concurrent-writes cell).

**VERDICT: UNSAFE.** Both Q2 directions show cross-boundary flock is **not respected** — that alone is
disqualifying per the bead's own framing ("hammer-green with locks-broken is still UNSAFE"). But this
spike did not even get hammer-green: Q3 surfaced a silently-lost write (a `bd create` that printed
success and vanished), and Q4 surfaced silent loss of an entire completed write burst on a guest hard-kill.
The concurrent-write hammer also repeatedly triggered fatal Dolt engine panics
(`fatal error: runtime error: Noms format version cannot be empty`) on the guest side. Do not route
daily-driver cage beads writes through the msb virtiofs mount as currently configured.

---

## Orchestrator reviewer note (confound disentanglement, added 2026-07-09 at review)

The UNSAFE verdict stands, but the load-bearing evidence is narrower and cleaner than the body's framing
implies — worth separating for the design decision:

- **The decisive, version-INDEPENDENT finding is Q2**: `flock` advisory locks are not propagated across
  msb's virtiofs boundary (both directions, marker-confirmed overlap). This is an OS-syscall property of
  the mount — the bd/Dolt version is irrelevant to it — and per the bead's own framing it alone → UNSAFE
  for any topology where host and guest coordinate writes to one embedded-Dolt store via file locks. This
  is the finding to build the design decision on. **Q4** (a `--force` hard-kill mid-burst silently loses
  completed-but-unflushed guest writes over virtiofs) is also clean and version-independent, but scoped to
  hard-kill; the deny→fix→reload repair loop uses a *graceful* `msb stop`, which the session-resume spike
  (rip-cage-1ujn) showed persists state fine.
- **Q1 and the Q3 guest-side panics/lockout are substantially CONFOUNDED by a bd version skew** (host
  `bd 1.1.0` vs the image's baked-in guest `bd 1.0.5`) that the hammer did NOT eliminate. The store was
  guest-*initialized* to match 1.0.5, but every mixed test still interleaves host 1.1.0 writes against it —
  and a 1.1.0 write reshapes the `events`-table schema, after which the 1.0.5 guest's INSERT fails with
  exactly the `Field 'id' doesn't have a default value` / `Noms format version` errors seen here (the same
  errors the pure schema-mismatch setup case produced with no concurrency at all). So "a host write
  permanently breaks guest writes" and "the guest bd panics under contention" should be read as version
  skew resurfacing *through* the mount, NOT as independent evidence that virtiofs corrupts beads. A clean
  virtiofs-corruption test would require matched bd versions on both sides (bake host-matching bd into the
  image, or run the host at the image's version) — not run here, and not needed to reach UNSAFE, since Q2
  is decisive on its own.
- The **version skew is itself a real, separately-fixable migration footgun**: the image's baked-in bd
  trails the host formula, and the two are not write-compatible against a shared store. Whatever beads
  topology the migration lands on, the image's bd must be pinned to match the host's. This is orthogonal to
  the virtiofs-locking verdict.

Net for the design: the sound, actionable conclusion is "advisory locks are not shared across msb virtiofs,
so concurrent host+guest file-lock-coordinated writes to one Dolt store are unsound" — which points at
single-writer-side or the parked host-service (single-writer-process) topology for beads, exactly as the
body's recommendation (a)/(b) says. The dramatic corruption/panic evidence is real as observed but
version-confounded, so it should not be the pillar the decision rests on.

All commands below are live output from this session. Every `bd` mutation ran either directly on the
host against a throwaway fixture under `/Users/jonatanpi/tmp/bdvfs-spike-fixture*`, or inside an
`bdvfs-*`-prefixed sandbox with that same fixture bind-mounted read-write at `/workspace`
(`--net-default deny` throughout — bd embedded needs no network). **No command in this session ever ran
against the real rip-cage or dotpi beads stores** except read-only `bd list` / `bd show` / `bd memories` /
`bd recall` calls used for orientation and the before/after safety check (§8).

---

## Setup and an early confound: bd schema-version mismatch (host 1.1.0 vs guest 1.0.5 baked-in)

Fixture recipe (per `bd memories rip-cage-validation-fixture-pattern`): `mkdir` → `git init` → empty
commit → `bd init --non-interactive` (embedded Dolt) → seed issues.

First attempt initialized the fixture with the **host's** bd (1.1.0), mounted it into a sandbox, and
tried a guest-side `bd create`:

```
$ msb exec bdvfs-main -- bd create "guest-created issue" -d "created from guest via virtiofs"
Error: failed to record event for bdvfs-spike-fixture-ip6: record event in events: Error 1105: Field 'id' doesn't have a default value
EXIT:1
```

Isolated with a control: a fixture initialized by the **guest's own** bd (1.0.5, via `msb exec ... bd
init`) accepts guest writes fine, and the host (1.1.0) can read *and* write that same guest-initialized
store without error:

```
$ msb exec bdvfs-ctrl -- bd init --non-interactive          # guest-init, schema matches guest bd
$ msb exec bdvfs-ctrl -- bd create "guest-init test issue" -d "control test"
✓ Created issue: workspace-58k — guest-init test issue
$ cd fixture2 && bd create "host-created issue on guest-init fixture" -d "host write test"   # host, same store
✓ Created issue: workspace-2pc — host-created issue on guest-init fixture
```

**Conclusion:** a newer-schema (host-1.1.0-initialized) store forward-rejects the older guest bd's writes;
an older-schema (guest-1.0.5-initialized) store is read/write-compatible from both sides. This is a real
version-skew footgun for the migration (the baked-in image bd trails the host formula), but it is
**not itself a virtiofs finding** — it reproduces from a pure schema mismatch. All fixtures used for the
rest of this spike (Q1–Q4) are **guest-initialized** to remove this confound and isolate the virtiofs
question.

---

## Q1 — in-guest CRUD, and an unexpected virtiofs-specific write-availability bug

With the confound isolated, guest CRUD against the guest-initialized, virtiofs-mounted fixture:

```
$ msb exec bdvfs-ctrl -- bd list                     # EXIT:0 — sees issues host also sees
$ msb exec bdvfs-ctrl -- bd show bdvfs-spike-fixture-c7n   # EXIT:0
$ msb exec bdvfs-ctrl -- bd create "guest-init test issue" -d "control test"   # EXIT:0 (workspace-58k)
```

Host read-back matches guest's view exactly (`bd list` on host from the fixture dir shows the same 2–3
issues, same IDs). So far consistent with a working mount.

Then guest `bd update --claim` on the same store:

```
$ msb exec bdvfs-ctrl -- bd update workspace-58k --claim
Error claiming workspace-58k: failed to record claim event: record event in events: Error 1105: Field 'id' doesn't have a default value
EXIT:1
```

Reproduced twice (`workspace-2pc`, `workspace-58k`, both fail identically), and `bd close` from guest
fails the same way:

```
$ msb exec bdvfs-ctrl -- bd close workspace-2pc --reason "test close from guest"
Error closing workspace-2pc: failed to record event: record event in events: Error 1105: Field 'id' doesn't have a default value
EXIT:1
```

**Host performing the identical claim on the identical store succeeds:**

```
$ cd fixture2 && bd update workspace-58k --claim
✓ Updated issue: workspace-58k — guest-init test issue
```

This is asymmetric: same store, same schema, host writes succeed, guest writes to the `events` table
fail. Minimal-repro isolation, ruling out "guest bd binary is just broken":

- **Guest write to a pure LOCAL (non-virtiofs) guest filesystem succeeds**, both create and claim:
  ```
  $ msb exec bdvfs-ctrl -w /home/agent/local-fixture -- bd init --non-interactive   # local fs, no mount
  $ msb exec bdvfs-ctrl -w /home/agent/local-fixture -- bd create "local fs test issue" -d "..."
  ✓ Created issue: local-fixture-2eg …                                              # EXIT:0
  $ msb exec bdvfs-ctrl -w /home/agent/local-fixture -- bd update local-fixture-2eg --claim
  ✓ Updated issue: local-fixture-2eg …                                              # EXIT:0
  ```
- **A brand-new, virtiofs-mounted, guest-only fixture accepts guest writes fine — for a while:**
  ```
  $ msb exec bdvfs-pure -- bd create "pure guest issue 1" … # EXIT:0
  $ msb exec bdvfs-pure -- bd create "pure guest issue 2" … # EXIT:0
  $ msb exec bdvfs-pure -- bd create "pure guest issue 3" … # EXIT:0
  $ msb exec bdvfs-pure -- bd create "pure guest issue 4" … # EXIT:0
  ```
- **The trigger: a single HOST write to that same store, interleaved once, permanently breaks all
  subsequent guest writes:**
  ```
  $ cd fixture3 && bd create "host write into pure-guest fixture" -d "trigger test"
  ✓ Created issue: workspace-0zy …                                                  # EXIT:0 (host)
  $ msb exec bdvfs-pure -- bd create "pure guest issue 5 after host write" -d "..."
  Error: failed to record event for workspace-0n3: record event in events: Error 1105: Field 'id' doesn't have a default value
  EXIT:1
  $ msb exec bdvfs-pure -- bd create "pure guest issue 6 retry" -d "retry"
  Error: failed to record event for workspace-33i: …                                # EXIT:1, still broken
  ```

**Finding:** a single host write to a virtiofs-mounted embedded-Dolt store permanently and deterministically
breaks the guest's ability to perform any subsequent write (create, claim, or close) against that store —
while host writes continue to succeed and reads stay consistent on both sides (no orphan/partial rows from
the failed guest attempts; `bd list` from both sides agreed throughout). This is a genuine cross-boundary
consistency defect, not corruption of already-committed data, but it means daily-driver mixed host+guest
usage would leave the guest permanently unable to write beads after the very first host-side touch.

---

## Q2 — the flock cross-boundary discriminator (the crux question)

`flock` (the CLI) is not present on macOS by default; the host side uses Python's `fcntl.flock` — the same
underlying `flock(2)` syscall the CLI wraps. Target file: `.beads/embeddeddolt/.lock` inside the fixture.

### Direction A — host holds, guest tries

Host acquires an exclusive lock and holds it for 12s (`nohup`'d so it survives the tool's per-call shell
boundary):

```
$ python3 host_lock_hold.py .beads/embeddeddolt/.lock 12 > host_hold_A2.log 2>&1 &
$ date -u   # 16:44:26 CEST — host launches
$ cat host_hold_A2.log
HOST_LOCK_ACQUIRED
```

While the host still holds the lock (confirmed: host released only at 16:44:38, ~12s after acquire), the
guest tries non-blocking:

```
$ date -u   # 16:44:35 CEST — squarely inside host's [16:44:27, 16:44:39] hold window
$ msb exec bdvfs-pure -- flock -n /workspace/.beads/embeddeddolt/.lock -c 'echo GOT_LOCK'
GOT_LOCK
GUEST_EXIT:0
```

**Result: GOT_LOCK. The guest acquired the lock while the host held it. Lock NOT respected, direction A.**

### Direction B — guest holds, host tries

To avoid `msb exec`'s output-buffering hiding the guest's real acquire time, the guest touches a
virtiofs-shared marker file the instant it acquires the lock, so the host can poll for genuine overlap
instead of guessing timing:

```
$ msb exec bdvfs-pure -- flock .beads/embeddeddolt/.lock -c 'touch .guest_holding; date -u; sleep 15; rm -f .guest_holding; date -u' &
$ # host polls for the marker
marker appeared after ~10.5s poll   # guest genuinely holding now
$ ls -la fixture3/.guest_holding
-rw-------@ 1 jonatanpi staff 0 Jul 9 16:46 .guest_holding   # confirmed present
$ date -u   # 14:46:56 UTC
$ python3 host_lock_try.py fixture3/.beads/embeddeddolt/.lock
GOT_LOCK
HOST_TRY_EXIT:0
$ date -u   # 14:46:57 UTC — marker still present at this instant (confirmed separately)
```

Post-hoc confirmation of the guest's real hold window from its own log: acquired 14:46:50 UTC, released
14:47:05 UTC. The host's non-blocking try at 14:46:56–57 UTC was solidly inside that window.

**Result: GOT_LOCK. The host acquired the lock while the guest held it. Lock NOT respected, direction B.**

**Q2 verdict: locks are per-side fictions across the virtiofs boundary, in BOTH directions.** An exclusive
`flock` held on one side does not block a non-blocking `flock -n` attempt on the other side, ever, in
either direction, with genuine timing overlap confirmed via a shared marker file (not inferred from sleep
timing alone). Per the bead's own framing, this single fact is sufficient for UNSAFE regardless of how the
hammer test (Q3) turns out.

---

## Q3 — concurrent-write hammer (3 rounds of 25 host + 25 guest, same fixture across rounds)

Fresh guest-initialized fixture (`bdvfs-spike-fixture4` / sandbox `bdvfs-hammer`). Host loop and guest loop
launched within ~2s of each other each round (host: direct shell loop; guest: single `msb exec` wrapping a
25-iteration shell loop, to avoid per-call VM-exec overhead).

### Round 1

Guest log (`guest_hammer_round1.log`, 1191 lines): **4 EXIT:0, 21 EXIT:2**, and the 21 failures include 21
**fatal Go panics** crashing the `bd` process outright:

```
panic: goroutine 1 [running]:
    …
    github.com/dolthub/dolt/go/store/nbs.(*NomsBlockStore).Close(...)
    …
fatal error: runtime error: Noms format version cannot be empty: fatal error closing table persister
```

Repeated crashes were preceded by the underlying error each time:

```
time="2026-07-09T14:48:19Z" level=warning msg="Error getting database workspace: cannot resolve default branch head for database 'workspace': 'main'"
```

Host loop: all 25 `bd create` calls eventually returned `✓ Created issue` / EXIT:0, but under severe
latency degradation from lock/store contention with the crashing guest loop — normal uncontended
`bd create` is sub-second; round 1's host loop took **~7 minutes** for 25 creates (progress polled live:
4 done at +90s, 8 at +150s, 12 at +210s, 19 at +390s, 25 at +555s).

**Post-round-1 integrity check — a silently lost write:**

```
$ bd list --format json --limit 0 | jq length      # host
28
$ msb exec bdvfs-hammer -- bd list --format json --limit 0 | jq length   # guest
28
```

Expected 25 (host) + 4 (guest, the successes) = 29 distinct issues; only **28** are present. Diffing
titles against the host log shows **`host round1 issue 1` is missing** — yet the host log shows it
reported success with a real ID:

```
$ grep -A2 "host round1 issue 1$" host_hammer_round1.log
✓ Created issue: workspace-fug — host round1 issue 1
  Priority: P2
  Status: open
```

```
$ bd show workspace-fug          # host
Error fetching workspace-fug: no issue found matching "workspace-fug"
$ msb exec bdvfs-hammer -- bd show workspace-fug   # guest
Error fetching workspace-fug: no issue found matching "workspace-fug"
```

**A `bd create` that printed success (exit 0, issue ID returned) is completely absent from the store on
both sides, afterward.** This is a genuine silent-write-loss under concurrent host/guest access — not a
crash artifact (the process reported success and moved on to the next issue), and not a listing quirk
(`bd show` by exact ID also fails, from both host and guest). No duplicate IDs were found; host and guest
list views agreed with each other post-round (28 = 28), just both missing the one lost write.

### Round 2

Guest: 0/25 succeeded, all EXIT:2/panic — the guest exec session itself terminated early after 13 of 25
attempted iterations (verified: sandbox `bdvfs-hammer` was still `running` and responsive to a fresh
`msb exec … echo` immediately after). Host: 25/25 eventually succeeded (~5.5 min, faster than round 1).
Post-round-2 integrity: host and guest both report **53** issues, exact agreement, matching
28 (round 1 net) + 25 (round 2 host) + 0 (round 2 guest) — **no new loss this round**, but round 1's loss
is permanent.

### Round 3

Guest: 0/25 succeeded (7 of 25 iterations attempted before the exec session ended early again, sandbox
still alive/responsive afterward). Host: 25/25 succeeded (~2 min, fastest round). Post-round-3 integrity:
host and guest both report **78** issues, exact agreement — 53 + 25 (round 3 host) + 0 (round 3 guest) =
78. No new loss, no duplicate IDs, no divergence between host/guest views, at any round after round 1.

### Q3 summary

| Round | Host attempted | Host landed | Guest attempted | Guest landed | Host/guest list agree? | New silent loss? |
|---|---|---|---|---|---|---|
| 1 | 25 | 24 (1 silently lost) | 25 | 4 (21 panicked) | Yes (28=28) | **Yes — 1 lost write** |
| 2 | 25 | 25 | 25 (cut short at 13) | 0 | Yes (53=53) | No |
| 3 | 25 | 25 | 25 (cut short at 7) | 0 | Yes (78=78) | No |

Across 150 attempted creates: 0 duplicate IDs ever observed; the store remained listable/readable
throughout (aside from one benign false alarm — `bd list --format json` appends a plain-text pagination
notice after the JSON array past the default 50-row limit, which breaks naive JSON parsing but is not a
store fault; resolved with `--limit 0`). But the store is **not hammer-clean**: one reported-successful
write vanished, and the guest side degraded from "some creates succeed" (round 1) to "zero creates succeed,
every attempt panics, exec session terminates early" (rounds 2–3) once any host write had touched the
store — consistent with, and compounding, the Q1 finding.

---

## Q4 — crash consistency: hard-kill during a guest write burst

Fresh guest-initialized fixture (`bdvfs-spike-fixture5` / sandbox `bdvfs-crash`), 1 sanity issue seeded.

First attempt (40-item burst, killed after ~19s) completed the entire burst before the kill landed — not
a useful mid-write test. Redone with a 300-item burst and a virtiofs-shared progress marker so the kill
could be timed to a confirmed in-flight state:

```
$ msb exec bdvfs-crash -- sh -c 'for i in $(seq 1 300); do bd create "crash burst2 issue $i" -d "…"; echo $i > /workspace/.burst_progress; done; echo DONE > /workspace/.burst_progress' &
$ # poll for marker
progress marker: 19    # confirmed mid-burst
$ date -u; msb stop --force bdvfs-crash; date -u
Thu Jul 9 15:07:03 UTC 2026
   ✓ Stopped      bdvfs-crash
Thu Jul 9 15:07:03 UTC 2026
$ cat fixture5/.burst_progress
37
```

Marker confirms the burst was genuinely mid-flight (item 37 of 300) at the moment of the hard `msb stop
--force`. This means up to 37 individual `bd create` invocations — each its own process, each having to
exit successfully before the loop's `echo $i > marker` line could run — had already **individually
completed** before the kill.

**Post-kill host-side read:**

```
$ cd fixture5 && bd list --format json --limit 0 | jq length
41
```

**41 = the pre-existing 1 sanity issue + all 40 issues from the first (fully-completed) burst. Zero of the
second burst's issues (up to item 37, individually reported complete) are present.** The store did not
become unreadable or corrupt in the sense of failing to open — `bd list`, `bd doctor` (not supported in
embedded mode, expected), and a fresh host-side write all worked immediately afterward:

```
$ bd doctor
Note: 'bd doctor' is not yet supported in embedded mode.
$ bd create "post-crash host sanity write" -d "verify store still writable after hard kill"
✓ Created issue: workspace-90u …
$ bd list --format json --limit 0 | jq length
42
$ msb exec bdvfs-crash -- bd list --format json --limit 0 | jq length   # after restart
42
```

**Q4 finding: the store remains readable and writable after a hard-kill mid-burst (no "damage" in the
sense of an unopenable or structurally broken store), but an entire run of already-individually-completed
guest writes (up to 37 issues) is silently and completely lost.** This is a durability gap, not a
corruption-to-unreadable failure mode: writes that a completed guest `bd create` process reported as
successful were never durably persisted to the host-visible virtiofs-backed file before the VM's state
was discarded. A plain single-write marker file (`echo $i > .burst_progress`) DID survive the same kill
(showed `37` immediately after, matching the in-flight state) — so the loss is specific to Dolt's
multi-file/multi-step embedded-storage commit path over virtiofs, not a blanket "virtiofs never
persists anything" failure.

---

## Verdict

**UNSAFE.** Per the bead's own framing, the verdict keys on Q2, not on how clean the hammer round looked:

- **Q2 (the crux): locks are NOT respected across the virtiofs boundary, in both directions**, confirmed
  with genuine timing overlap (marker-file-verified, not sleep-guessed). A guest `flock -n` succeeded while
  the host held an exclusive lock; a host `flock` (non-blocking) succeeded while the guest held one. This
  alone is disqualifying.
- **Q3 was not even hammer-clean anyway**: one host write that reported success silently vanished from the
  store (0/1 = data loss, not merely "no duplicates"), and guest write-availability degraded to 0% after
  the store had seen any host write, with the guest's own `bd` process repeatedly hitting fatal internal
  Dolt panics (`Noms format version cannot be empty`) under contention.
- **Q4 confirms real durability loss on crash**: a hard-kill mid-burst silently discarded an entire run of
  already-individually-completed writes (up to 37 issues) while leaving the store itself readable and
  writable — the failure mode is silent data loss, not the sort of loud, obviously-detectable corruption
  that would at least get noticed.
- **Q1's version-mismatch confound** (host bd 1.1.0 vs guest's baked-in bd 1.0.5) is a separate,
  addressable footgun (pin/match bd versions in the image) — worth fixing regardless, but not itself why
  this is UNSAFE; it was isolated and controlled for before Q2–Q4 ran.

**Recommendation for rip-cage-tsf2 / rip-cage-1mkq:** do not route daily-driver cage beads writes through
the msb virtiofs `/workspace` mount as currently configured. The locking discriminator result (Q2) means
any topology relying on host+guest processes coordinating writes to the same embedded-Dolt store via file
locks over this mount is unsound regardless of how many hammer rounds happen to pass clean — and this
round did not even pass clean. If file-based beads-over-virtiofs remains the plan, either (a) restrict
writes to exactly one side (host-only or guest-only) with the other side read-only, accepting staleness,
or (b) revisit the parked host-service topology (a single writer process, not filesystem-shared locking)
for beads specifically — consistent with rip-cage-1mkq's broader substrate-fit question.

---

## Safety verification: zero mutations to any real beads store

Real rip-cage repo baseline (captured before any spike command ran):

```
$ cd /Users/jonatanpi/code/personal/rip-cage && bd list --format json | wc -l    # then parsed
baseline count: 49
```

Final count at end of session:

```
$ bd list --format json | wc -l   # then parsed
final count: 47
```

The raw count differs, but this is **not attributable to this spike**. Diffing baseline vs final JSON
shows the only content changes are (a) a large notes-field append to the `rip-cage-tsf2` epic recording
the results of an unrelated, concurrently-running spike (`rip-cage-1mkq`, task-substrate-fit — visible in
the diff as "SPIKE RESULT — task-substrate fit matrix... NOT a tsf2 gate"), and (b) two issues
(`rip-cage-1mkq`, `rip-cage-9odv`) dropping out of the default (open-only) `bd list` view, consistent with
them being closed by that concurrent session. This repo is actively multi-machine, multi-session worked
(the epic notes reference an ongoing "Fable" orchestration round with multiple parallel spike workers on
2026-07-09) — the count drift is ordinary concurrent activity by other sessions, not this spike.

Independent confirmation this spike caused none of it:

```
$ grep -c "hammer test\|crash burst\|guest round\|host round\|bdvfs\|pure guest\|workspace-" /tmp/real_repo_final.json
2
```

Both matches are benign: `bdvfs` appears only inside bead `rip-cage-9iab`'s own design text (which
literally specifies "Sandbox prefix: bdvfs-" as part of this bead's brief), and `workspace-` matches an
unrelated substring ("workspace-trust posture (ADR-024)"), not this spike's `workspace-xxx` issue-ID
prefix (which lives only in the throwaway fixtures). No `bd create` / `bd update` / `bd close` / `bd init`
was ever run with the real rip-cage repo as the working directory or target store in this session — every
mutating `bd` command targeted a fixture under `/Users/jonatanpi/tmp/bdvfs-spike-fixture*`, either
directly on the host or inside a `bdvfs-*` sandbox with that fixture mounted at `/workspace`. The only
commands run against the real repo were read-only: `bd show rip-cage-9iab`, `bd memories …`,
`bd recall …`, and the two `bd list --format json` calls used for this before/after check.

---

## Cleanup

All `bdvfs-*` sandboxes removed (prefix-scoped, per the bead's safety constraint):

```
$ msb remove --force bdvfs-crash bdvfs-hammer bdvfs-pure bdvfs-ctrl bdvfs-main
   ✓ Removed      bdvfs-crash
   ✓ Removed      bdvfs-hammer
   ✓ Removed      bdvfs-pure
   ✓ Removed      bdvfs-ctrl
   ✓ Removed      bdvfs-main
$ msb list
No sandboxes found.
```

Fixture directories under `/Users/jonatanpi/tmp/` are **not yet deleted** — this session's `rm -rf` on
those paths was blocked by the local destructive-command guard (`dcg`), which requires explicit human
execution rather than agent bypass. Paths still on disk, safe to remove manually:

- `/Users/jonatanpi/tmp/bdvfs-spike-fixture` (host-init'd, schema-mismatch demo)
- `/Users/jonatanpi/tmp/bdvfs-spike-fixture2` (Q1 control/main)
- `/Users/jonatanpi/tmp/bdvfs-spike-fixture3` (Q1 pure-guest + Q2 locking)
- `/Users/jonatanpi/tmp/bdvfs-spike-fixture4` (Q3 hammer)
- `/Users/jonatanpi/tmp/bdvfs-spike-fixture5` (Q4 crash)
- `/Users/jonatanpi/tmp/bdvfs-spike-fixture-path.txt`, `/Users/jonatanpi/tmp/host_lock_hold.py`,
  `/Users/jonatanpi/tmp/host_lock_try.py`, `/Users/jonatanpi/tmp/host_hammer_round.sh`, and the
  `/Users/jonatanpi/tmp/{host,guest,crash}_*.log` evidence logs from this session.

None of these paths overlap with, or are referenced by, the real rip-cage or dotpi beads stores.
