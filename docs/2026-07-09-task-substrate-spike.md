# Task-substrate fit spike — beads-as-configured vs simpler-beads vs beads_rust vs plain-file

Bead: rip-cage-1mkq. FACTS-ONLY spike — no migration, no decision. The keep/simplify/migrate
call is a separate later brainstorm. Every non-obvious cell below cites a LIVE command run on
2026-07-09 (mac mini, darwin arm64). Live fixture = read-only `bd export --all` of the real
rip-cage store to `/tmp` (NOT into `.beads/`); zero mutations to any real store (guard at end).

## Fixtures & environment

- Real rip-cage store at spike time: **925 issues + 185 memories** (`bd export --all` →
  `Exported 925 issues and 185 memories`). Brief said "183 memories"; live count is 185.
- Read-only fixture: `/tmp/rc-substrate-fixture-export.jsonl` (1110 JSONL lines: 925 `_type:issue`
  + 185 `_type:memory`).
- `bd version 1.1.0 (Homebrew)`.
- `br` (beads_rust) `v0.2.16 (release)` — prebuilt darwin_arm64 binary from the GitHub release
  (the README-endorsed install route), extracted to `/tmp/br-bin/br`, 10.9 MB single static file.
  Source cloned to `/tmp/beads_rust_clone`.
- Each candidate probed in its own `mktemp -d` scratch repo with `git init`.

## Candidates

- **C1** — beads as configured today: embedded Dolt engine at `.beads/embeddeddolt/` (112 MB),
  Dolt-over-git sync, lagging `issues.jsonl` export.
- **C2** — beads in a simpler config (can bd run without Dolt / pure-JSONL?).
- **C3** — beads_rust (`br`): "classic" SQLite + JSONL-git architecture, a frozen fork of
  pre-Dolt Steve-Yegge beads.
- **C4** — minimal plain-file sketch (JSONL/markdown in git). Calibration control for "what does
  Dolt actually buy us".

---

## 1. Candidate × Requirement matrix (live evidence per cell)

Legend: PASS = requirement met natively; PARTIAL = met with caveat/extra work; FAIL = not met /
disqualifying; N/A-collapses = candidate does not exist as distinct from C1.

### R1 — Issue graph (deps, epics/children, claim/close, ready queries)

| C | Verdict | Live evidence |
|---|---------|---------------|
| C1 | PASS | Incumbent runs `bd list/ready/dep/epic/children` in production daily; `bd --help` shows the full graph surface (dep, epic, swarm, children, ready). |
| C2 | =C1 | No storage change (see R2/C2); graph surface identical to C1. |
| C3 | PASS | `br` has `dep add/remove/list/tree/cycles`, `epic`, `ready`, `blocked`, `search`, `list`. Live: after import, `br ready` → "Ready work (48 issues with no blockers)", `br search "substrate"` → "Found 8 issue(s)", `br list` returns rows. |
| C4 | PARTIAL | Graph is expressible in files but every query (ready/blocked/dep-tree/epic-rollup) is hand-built; no engine. No live tool exists — this is the calibration control. |

### R2 — PERSISTENT MEMORIES (store + keyword-search + update-in-place) — the biggest lock-in

| C | Verdict | Live evidence |
|---|---------|---------------|
| C1 | PASS | `bd remember/recall/memories/forget` are first-class. Store+update-in-place: `bd remember "<insight>" --key <k>` ("If a memory with this key already exists, it will be updated in place"). Keyword search: `bd memories dolt` → 5 memories matching "dolt" (live). 185 memories live in the Dolt store, injected at `bd prime`. |
| C2 | =C1 | Same engine, same memories surface. |
| C3 | **FAIL** | `br` has **no** memories concept. `br --help \| grep -iE 'memor\|remember\|recall'` → empty. Whole-source grep for a memories feature in `/tmp/beads_rust_clone/src` + `/docs` → only Rust "memory-safety" prose + two unrelated code comments; zero `remember/recall/memories` command. The word "memory" in the README is exclusively Rust memory-safety. Importer actively **rejects** memory records (see §2, C3). |
| C4 | PARTIAL | Memories-as-files: store = write a file, update-in-place = edit the file, keyword-search = `grep`/`ripgrep`. Works, but no `bd prime`-style auto-injection and no structured recall — the harness layer is DIY. |

### R3 — Multi-machine sync (MacBook + mac mini both write issues AND memories same day)

| C | Verdict | Live evidence |
|---|---------|---------------|
| C1 | PASS | `embeddeddolt/` is **gitignored** (`.beads/.gitignore` lists `dolt/`, `embeddeddolt/`, `proxieddb/`); the DB syncs as Dolt commits over git refs — live `git show-ref` shows `refs/remotes/origin/__dolt_remote_info__`; `bd dolt remote list` → `origin git+ssh://git@github.com/jsnyde0/rip-cage.git`. `bd dolt push/pull` moves the FULL DB (issues + memories + audit) with Dolt's row-level merge. This is bd's core value. Cost: it is the source of the R6 footguns. |
| C2 | =C1 | Same Dolt-over-git path. |
| C3 | PARTIAL | Git-native but JSONL-file merges, not row-level. README: `issues.jsonl` committed to git; `br sync --merge` does a three-way merge vs `.beads/beads.base.jsonl`. Line-based, "usually easy" per FAQ, but same-record concurrent edits conflict (see C4 demo — same failure class). Memories: N/A (none to sync). |
| C4 | PARTIAL/FAIL | Live demo: two branches editing the SAME issue's status line in a single `issues.jsonl` → `git merge` → `CONFLICT (content): Merge conflict in issues.jsonl` (manual resolution). Mitigation demo: one-file-per-record (`issues/x-1.json`), two branches editing DIFFERENT records → clean `ort`-strategy auto-merge. Residual break: two machines editing the SAME record still conflict. |

### R4 — Multi-agent concurrent writes on ONE machine (no corruption, no lost writes)

| C | Verdict | Live evidence |
|---|---------|---------------|
| C1 | PASS (slow) | Two parallel `bd q` loops (40 each = 80) against one scratch repo → final `bd count` = **80**, zero stderr errors, zero lost writes. BUT throughput is low: writes serialize through the single embedded Dolt sql-server; the 80 writes took ~4 min (climbing 54→66→80 across polls). |
| C2 | =C1 | Same engine. |
| C3 | PASS (fast) | Two parallel `br q` loops (40 each) against one scratch repo → `br count` = **80**, zero errors, zero lost writes, completed in seconds. SQLite WAL locking (`beads.db-wal` present) handles it. |
| C4 | FAIL (naive) | Same failure class as R3: concurrent same-file writes race. A single append-only JSONL or one-file-per-record reduces collision surface but same-record concurrent writes lose/corrupt without an external lock. No engine mediates. |

### R5 — Works inside a Linux cage (baked/trivially installable, no host-only daemon)

| C | Verdict | Live evidence |
|---|---------|---------------|
| C1 | PARTIAL | bd is a single Go binary with Dolt embedded (no external server) — installable in an image. Weight: the 112 MB `.beads/embeddeddolt/` working set + Dolt engine. In-cage viability (virtiofs locking, host/guest concurrent) is being proved separately by **rip-cage-9iab**; this spike does not contend for the msb runtime and cites it as covered elsewhere. Cages currently use beads file-based through the `/workspace` mount regardless. |
| C2 | =C1 | Same binary. |
| C3 | PASS | Release publishes `linux_amd64`, `linux_arm64`, **and static `linux_musl_amd64/arm64`** artifacts (`gh release view` asset list). ~11 MB single static binary, no daemon — trivially bakeable into a cage image (incl. Alpine via musl). |
| C4 | PASS | Just files + git + grep; nothing to install. |

### R6 — Footgun tally to beat (incumbent's documented operational costs)

| C | Verdict | Live evidence |
|---|---------|---------------|
| C1 | (the baseline) | Documented footguns, several confirmed live this session: (a) lagging derived export — `issues.jsonl` is NOT live state, needs manual `bd export --all -o` flush (config.yaml comment + memories `bd-close-clobbered-by-autosync-reimport-flush-export`); (b) shrink-guard vs memories — auto-export structurally impossible because it excludes memories and would shrink the committed file (`bd-autoexport-memories-shrink-guard-incompatible`); (c) schema-fork migrations needing a designated-migrator ceremony (`bd-schema-migration-fork-risk-only-for-dolt-remote-backed-repos`); (d) autosync re-import clobbering closes; (e) hook fragility across upgrades. Live `--backend=sqlite` also shows a hard breaking-change history (SQLite backend removed). |
| C2 | =C1 | Inherits every C1 footgun (same engine). |
| C3 | fewer, different | No Dolt → no shrink-guard, no schema-fork-ceremony, no lagging-export-vs-live-store split (SQLite IS the store, JSONL flushes by default on close). New footguns: JSONL merge conflicts on concurrent same-record edits; a separate `br` binary/toolchain to track; NO memories at all. |
| C4 | fewest infra, most DIY | No engine footguns; but every guarantee bd/br give for free (atomic writes, ready-queries, dedup, merge safety) becomes hand-rolled. Concurrent-write correctness is on you. |

---

## 2. Per-candidate migration cost for the incumbent data (925 issues + 185 memories)

**C1 (beads as-is): zero migration.** Data already lives here. Memories fully intact with search.

**C2 (simpler beads config): not a migration — the target does not exist.**
Live probes prove bd 1.1.0 has no non-Dolt storage:
- `.beads/config.yaml` documents `no-db` as **VESTIGIAL** — "bd parses but IGNORES it (per ADR-007
  D5, FIRM)". The real storage source of truth is `dolt_mode` in `metadata.json`.
- Fresh `bd init --non-interactive` in a scratch repo → `.beads/metadata.json` =
  `{"database":"dolt","backend":"dolt","dolt_mode":"embedded",...}`. No JSONL-only path offered.
- `bd init --backend=sqlite` → **`Error: --backend=sqlite is no longer supported`**
  ("The SQLite backend has been removed. Dolt is now the default (and only) storage backend").
- `bd init --help`: "Dolt is the default (and only supported) storage backend. The legacy SQLite
  backend has been removed."
Conclusion: "beads without Dolt / pure-JSONL beads" is **not achievable** in the current bd. The
only real simplification levers are Dolt config toggles (auto-export off — already off here;
`--sandbox` disables auto-push; external vs embedded server), none of which remove Dolt or change
the footgun surface. C2 collapses into C1.

**C3 (beads_rust / br): issues migrate with reshaping; memories DO NOT migrate.**
- README migration path is `cp .../issues.jsonl .beads/ ; br sync --import-only`. Tested live
  against the REAL `bd export --all` fixture → **FAILS**:
  `Error: Invalid JSON at line 15: invalid type: string "...", expected i64` — the failure is in
  bd's inline `comments` array shape (line 15 is an ordinary issue with comments). So a raw
  `bd export --all` is **not** directly br-importable; a transform is mandatory.
- After a transform to br's classic shape (map `design→description`, drop inline `comments`/
  `dependencies`, add `source_repo/compaction_level/original_size`), `br sync --import-only` →
  **`Processed: 925 issues / Created: 925 issues`**. Issues migrate cleanly once reshaped.
  Caveat: **dependency edges are dropped by that transform** — bd embeds deps inline, br wants a
  separate `br dep import edges.jsonl`; hence post-import `br ready` showed 48 "unblocked" (graph
  flattened). A faithful migration needs a SECOND edge-extraction pass. Comments also need a
  separate mapping (`br comments add`).
- **Memories: no import path exists.** br has no memories schema/command, and its importer
  actively rejects the records: feeding two raw `_type:memory` lines → **`Error: Invalid JSON at
  line 1: missing field 'id'`**. The 185 memories can only be preserved by (a) keeping them as
  plain files OUTSIDE br (losing `bd prime` injection + structured recall; search degrades to
  grep), or (b) rewriting each as a br ISSUE (losing the L2B memory semantics and the
  memories-vs-issues separation). Neither preserves "memories WITH keyword-search AS MEMORIES".

**C4 (plain-file): mechanical for issues, viable-with-loss for memories.**
- Issues: 925 records → JSONL or one-file-per-record is a scripted dump of the fixture (already in
  JSONL). Straightforward.
- Memories: 185 records → 185 files; keyword search = `grep`/`rg` (works, demonstrated conceptually
  — the fixture already carries each memory's YAML-frontmatter body). Update-in-place = edit file.
  Loss: no `bd prime` auto-injection, no dedup/recall tooling — the entire harness layer is DIY.

---

## 3. Explicit VIABLE / DISQUALIFIED verdict per candidate

- **C1 (beads as-is): VIABLE.** Meets R1–R5; it IS the R6 baseline (carries the documented
  footgun tally the brainstorm is weighing). Only candidate where memories are native + searched +
  synced with zero migration.

- **C2 (simpler / no-Dolt beads): DISQUALIFIED by construction — the target does not exist.**
  bd 1.1.0 has no non-Dolt backend (SQLite removed; `no-db` vestigial; fresh init forces
  `dolt_mode:embedded`). Any "simpler bd" is still full-Dolt bd; it collapses into C1 and inherits
  every C1 footgun. There is no simpler-beads configuration to migrate to.

- **C3 (beads_rust / br): DISQUALIFIED on R2 (persistent memories).** br has no memories layer at
  all — no command, no schema, and its importer errors on memory records (`missing field 'id'`).
  The single biggest lock-in (185 searchable memories) has NO survival path into br other than
  demoting them to plain files or to issues. (Secondary friction, not disqualifying: R1 migration
  needs a bespoke issue reshape + a separate dependency-edge import; a raw `bd export --all` does
  not import. Strengths: R4 fast + correct, R5 static Linux/musl binary, fewer Dolt footguns.)

- **C4 (plain-file): DISQUALIFIED on R4 (and R3) for concurrent correctness in the naive form.**
  Live-demonstrated: concurrent same-record edits → git merge CONFLICT / lost-write race with no
  mediating engine. One-file-per-record mitigates cross-record collisions (clean auto-merge shown)
  but not same-record concurrent writes. Useful as the calibration control — it shows Dolt's paid-
  for value is exactly row-level concurrent-write merge safety (R3+R4), not R1/R2/R5, which files
  cover adequately (R2 via grep, R5 trivially).

---

## 4. Open questions only a brainstorm/decision can settle (NOT recommendations)

1. **Is row-level concurrent-write merge (Dolt's paid-for R3+R4 value) actually exercised?** How
   often do MacBook + mac mini, or two cage agents, write the SAME record concurrently vs merely
   different records? If cross-record is the real pattern, one-file-per-record (C4) or br's JSONL
   (C3) may suffice — but that is a decision, not a fact this spike can settle.
2. **What is the 185-memory layer worth vs its migration cost?** Only C1/C2 keep memories native.
   Is grep-over-files (C4) or memories-as-issues (C3) an acceptable degradation of L2B, or is
   `bd prime` auto-injection + keyword recall load-bearing enough to pin the substrate to bd?
3. **Is bd's ~4-min-for-80-concurrent-writes throughput a real bottleneck** for AFK/swarm
   orchestration (dotpi-3bi bead factory), given br does the same in seconds? Depends on expected
   agent write-concurrency, unmeasured here.
4. **Could a hybrid split the layers** — br/plain-files for the fast-churn issue graph, bd retained
   only for the 185 memories — or does two-substrate overhead exceed the footgun it removes?
5. **If C3, who owns the migration tooling** (bd-export→br reshape + dependency-edge extraction +
   memories disposition)? br ships a "bd-to-br-migration skill" but it targets classic-bd JSONL,
   not the Dolt-era `bd export --all` shape that broke here.
6. **R5 in-cage locking** for whichever engine wins is deferred to rip-cage-9iab (embedded-Dolt
   over virtiofs) — its outcome feeds this decision but is out of scope here.

---

## Mutation guard (safety)

Real stores untouched — all real-repo commands were read-only (`bd list/show/memories/export -o
/tmp`); all candidate probing was in `mktemp -d` scratch repos.
- rip-cage before: 925 issues + 185 memories. rip-cage after: `bd list --all \| wc -l` = **1015**
  (unchanged framing) and `bd memories` header = **`Memories (185)`** (unchanged). No writes to
  the rip-cage or dotpi beads stores.
