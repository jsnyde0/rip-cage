# rip-cage-tsf2 decomposition — implementation children

**Status:** proposed for Fable review (2026-07-10). Decompose delegated to the mac-mini orchestrator per the epic's "Decompose delegated to mini orchestrator" note. **No implementers dispatched** — this tree gets reviewed (shape / acceptance contracts / harness targets) before implementation starts.

**Anchor:** `docs/decisions/ADR-029-msb-migration.md` — decisions D1–D6 FIRM, D7 FLEXIBLE. The "Sibling reconciliation" section governs which ADR/doc edits land as children.

**Inputs:** ADR-029; the epic's named-children floor (`bd show rip-cage-tsf2` → "Fable ADR-stamping pass COMPLETE"); `docs/2026-07-08-msb-migration-partition-map.md`; `docs/2026-07-07-microvm-spike-findings.md` §8b; `docs/2026-07-10-current-stack-parity-and-lan-exposure.md` (606c probe).

## Ground truth (verified live, 2026-07-10 — supersedes the partition map's monolith framing)

- `rip-cage-gto1` **CLOSED** (cbfdfb4): the ~12,866-line `rc` monolith is now a 179-line shim + **14 `cli/*.sh` verb-modules + 6 `cli/lib/*.sh` helpers**. The whole `up`-constellation stayed intact in `cli/up.sh` (~241KB); the Dockerfile-generation engine moved to `cli/lib/manifest_checks.sh`. Engine deletion (S4) is therefore a **function-level survivor-vs-engine split inside the modules**, concentrated in `cli/up.sh`, not a file delete.
- `rip-cage-9oyh` **CLOSED** (baseline f6ecd3b): the golden-master harness (`tests/golden-master/capture.sh --record/--check`) exists and is docker-argv-shaped. gto1's close-notes flag it green **only run serially** — de-flake is a precondition for leaning on it here (S12).
- **No implementation children of `tsf2` exist yet.** The only current deps are the (closed) spikes, the in-progress test-refresh `rip-cage-7atw`, and the KVM gate `rip-cage-4fxg`.

## Existing siblings (not new children)

- **`rip-cage-7i2p`** (P1, in flight): bump the cage image's baked bd 1.0.5 → host 1.1.0. The floor's "bd version pin in image" — already filed, being fixed now. Wire as `blocks tsf2`. Independent of the msb children (fixes the current stack) but D7 lists it as an unconditional migration child.
- **`rip-cage-7atw`** (P2, in progress): refresh the bit-rotted Part-B/E2E test tier to a trustworthy green baseline **before** the migration. Already a `blocks tsf2` dep; the safety-test migration (S10) builds on its output. (S12 builds on the *closed* golden-master harness `rip-cage-9oyh`, not 7atw.)

## Flags for Fable (dep-hygiene, out of decompose scope)

- **`rip-cage-4fxg` (KVM gate) is wired as a `blocks tsf2` dependency**, but ADR-029 D6 states the gate "blocks the future VPS thread, **not this epic**." The wiring likely should be cut (or re-typed `related`) so the mac-mini cutover isn't gated on a Linux box. Left as-is pending Fable's call.
- **S1 image-update posture:** the epic notes reference image-update-flow questions (added to the r8jl spike), but ADR-029 does not settle a digest-pinned update-adoption decision. S1's acceptance is scoped to import + boot only; the update posture is surfaced as an open design question, not baked in.
- **S14 factory-stack scope boundary:** the epic acceptance names "factory stack (dotpi-3bi) run per-cage," but the epic also frames dotpi-3bi as "ONE cage config/recipe, not the product" with dogfooding as the *next* step. S14 is included so the clause isn't silently dropped — **Fable to rule whether the factory-stack-per-cage smoke belongs in tsf2 or defers to the first dogfooding itch.**

---

## Dependency graph

```
S1 (image-import + boot-root)
 ├─> S3 (claude-dirs)                    [S1 only; parallel with S2]
 └─> S2 (generator)
      ├─> S5  (ssh-retire)
      ├─> S9  (mount-denylist re-verify)
      ├─> S11 (dind disk-kind volume)
      └─> S4 (engine-deletion)           [needs S1,S2]
           └─> S6 (lifecycle-verbs)      [also needs S3]
                ├─> S7  (default-allowlist)       [needs S2,S6]
                ├─> S8  (label-lock)              [also needs S1]
                ├─> S10 (safety-tests)            [also needs S1,S2,S4; +7atw]
                ├─> S12 (golden-master)           [also needs S2,S4,S5]
                ├─> S13 (docs-sweep)              [also needs S4,S5,S7,S8]
                └─> S14 (factory-stack dotpi-3bi) [scope-boundary — Fable rules in/deferred]
```

Critical path: **S1 → S2 → S4 → S6 → {S12, S13}**. S3, S5, S9, S11 parallelize off S1/S2. Rationale for the S4-before-S6 and S2-before-S4/S5 ordering: D1's hard-cutover-no-dual-backend means the old containment/git path must not be deleted before its msb replacement is proven, and the create-path orchestration in `cli/up.sh` cannot have both the old root-exec init calls (removed by S4) and the new msb-flag path (installed by S6) as its single source of truth at once. S4↔S6 is **non-circular** because S4's effect-probe cage is stood up via S2's flags directly (`msb run …`), not via rc's create verb (S6) — see S4's verifiability note.

---

## Children

### S1 — Image import (`docker save` → `msb load`) + bootable-cage smoke root
**Design.** The `build` verb stays (image is the artifact, findings §8b) and gains the one-time image-format conversion so a cage boots from the msb-loaded image. This is the **testability root**: every downstream child's effect-based harness needs a bootable msb cage to run in. Touches the build path + a thin `msb load` adoption step. Scoped to import + boot; the image-**update** posture (digest pinning / per-cage adoption) is an open question for Fable, NOT in this acceptance.
**Acceptance.** (1) `docker save` of a current rc image + `msb load` produces a cage that boots. (2) The baked toolchain actually **executes inside the guest** with real output (e.g. a real command/completion run in-cage returns its actual result), not merely that the image is listed as loaded. (3) A negative control: a cage from an un-imported/absent image fails to boot loud.
**Harness target.** Boot the imported image and run a real in-guest command; assert the real output value, never image-listing/`msb load` exit-0.
**Depends-on.** none.

### S2 — Config → msb-flags generator
**Design.** New code (partition-map §C: every current reader of `egress-rules.yaml` is on the retire list). Translates survivor intent-data (allowed-hosts, manifest MEDIATOR credential bindings, mount declarations, tls-body-rewrite need) into `--net-default deny` + `--net-rule`, `--secret ENV@HOST`, mount flags, and `--tls-intercept` (only when body rewrite is declared). Implements D2's "declare, don't run the engine" and D5's non-possession default. **Must also emit possession-mode mounts** (D5: pi keeps a real mounted `auth.json` — mixed posture survives). Binding generator constraints from D3, acceptance-shaping: `--secret` accepts only bare `ENV@HOST` (inline `ENV=VALUE@HOST` rejected at create); binding one credential to N hosts requires N **distinct** synthesized env-var names — a same-name repeat or comma-list silently blocks **both** hosts with zero boot error.
**Acceptance.** (1) A cage created from generator-emitted flags yields **real bidirectional application data** from an allow-ruled host and **zero bytes** (not connect-success) from a denied host. (2) A secret bound to host X delivers the real value only on the wire toward X and is provably **absent from guest env/proc/disk** regardless of host; a placeholder sent toward an unbound host is blocked-and-logged. (3) One credential → two hosts emits two **distinct** env-var names and both hosts actually receive the value (guards the silent double-block footgun). (4) A pi-style possession-mount cage has the real credential file present in-guest (mixed posture preserved). (5) `--tls-intercept` emitted only when body-rewrite is declared. (6) The generator emits only the bare `ENV@HOST` secret form; an inline `ENV=VALUE@HOST` input is rejected at create (D3 constraint 1).
**Harness target.** Effect probes: real data from allowed host / zero data from denied host; secret-value wire-presence toward bound host + absence in guest + absence toward unbound host. No rule-listing, no connect()-success.
**Depends-on.** S1.

### S3 — Pre-create claude-home session/project dirs on provisioning
**Design.** Sharply-scoped fix for the D4 resume footgun: the mounted claude-home's `projects`/`sessions` dirs must exist before first mount or resume silently breaks with no error. Provisioning-time directory seeding; isolable from S2/S6.
**Acceptance.** (1) A real agent session planted before a cage recreate is **recovered** after resume (session content read back correctly). (2) Negative control: a cage lacking the fix fails to recover the same session.
**Harness target.** Plant real session state, recreate, assert read-back of the actual content; the fix-absent path is the negative control.
**Depends-on.** S1. Parallel with S2 (no code dependency).

### S4 — Engine deletion sweep (production code)
**Design.** RETIRE-bucket removal per D2, as a **function-level split** across the `cli/` modules (concentrated in `cli/up.sh`'s init-phase orchestration + `cli/lib/manifest_checks.sh` mediator-field enforcement): the router/egress-policy/DNS-exfil-heuristic logic, iptables firewall init, the mediator launch machinery + its manifest archetype, corresponding image-build fragments, and every call site that root-execs or probes them (the doctor engine-probe, the manifest validator's mediator enforcement). Per D2 the ssh-allowlist lib entangled in firewall-init does **not** need extraction-before-delete (the whole ssh cluster also retires, S5 — they die together); this child confirms nothing else survives inside those scripts. **Cutover landing posture (Fable review R1 — this bead is S4, engine deletion):** S4 (engine deletion), S5 (ssh-cluster retirement), and S6 (msb lifecycle verbs) develop on a shared cutover branch and merge to main TOGETHER — S4 alone leaves main's `rc up` broken/uncontained; S5 alone removes ssh git autonomy from Docker cages before the msb HTTPS+--secret path is reachable through rc. During development S4 and S5 stay independently verifiable via S2's generator flags driven directly (`msb run`), not through rc's not-yet-rewritten verbs. Before the cutover merge, cut the pinned pre-cutover release — ADR-029 D1's rollback artifact. Sequencing (Fable harness review item 2): the Part-B baseline ledger (rip-cage-7atw.14) must complete and be an ancestor of the pinned pre-cutover release tag before the cutover branch merges — after the engine-deletion sweep lands, the Docker-era baseline is unobtainable.
**Acceptance.** (1) A cage built from the post-deletion image has **no engine processes** present and still **demonstrably enforces containment via msb primitives only** — a denied host yields no data and a DNS-exfil-shaped query is refused at the resolver before egress — with the deleted engine entirely **absent**, not dormant. (1b) **Positive control (guards the dead-network confound):** an *allowed* host returns **real bidirectional data** on the **same** post-deletion cage — proving msb is selectively enforcing, not that networking is simply broken. (2) Direct structural check: the generated `create` invocation (produced by S2's generator) contains no engine calls — no egress/credential/DNS/mediator engine argv, env, or in-cage hook references remain. (3) The surviving floor items (ADR-023 mount-denylist, ADR-002 D11 `.git/hooks` weld, in-guest root-owned guard artifacts) remain intact. (4) Makefile BASH_SCRIPTS list is updated for every deleted/added shell file; `make lint` is green on the post-diff tree.
**Harness target.** Effect: allowed-host-real-data AND denied-host-no-data AND DNS-exfil-refused-at-resolver on a cage where the engine is gone; assert absence of engine processes, not rule-listing. Plus: `make lint` green after this child's diff.
**Depends-on.** S1, S2. (Delete only after the msb replacement is proven, else cages have no containment mid-migration.) **Verifiability note (S4↔S6 non-circular):** S4's effect-probe cage is stood up by applying S2's generator flags **directly** (`msb run …`), NOT via rc's create verb (which S6 builds) — so S4 is verifiable before S6 exists. S6 then installs the rc lifecycle create verb over the same flag path.

### S5 — Retire the ssh cluster
**Design.** D3 (own-predicate firing for ADR-017 D4 / ADR-018 D1): remove agent-forwarding default, socket discovery, identity routing, host+key allowlist (ADR-017/018/020/022) — the allowlist verb, its hook, filtered `known_hosts`, `ssh-agent-filter`. The LAN-IP agent bridge is **demoted to a documented-but-never-blessed composed recipe** (ADR-005 D12), not erased — that demotion is docs work folded into S13. **Cutover landing posture (Fable review R1 — this bead is S5, ssh-cluster retirement):** S4 (engine deletion), S5 (ssh-cluster retirement), and S6 (msb lifecycle verbs) develop on a shared cutover branch and merge to main TOGETHER — S4 alone leaves main's `rc up` broken/uncontained; S5 alone removes ssh git autonomy from Docker cages before the msb HTTPS+--secret path is reachable through rc. During development S4 and S5 stay independently verifiable via S2's generator flags driven directly (`msb run`), not through rc's not-yet-rewritten verbs. Before the cutover merge, cut the pinned pre-cutover release — ADR-029 D1's rollback artifact. Sequencing (Fable harness review item 2): the Part-B baseline ledger (rip-cage-7atw.14) must complete and be an ancestor of the pinned pre-cutover release tag before the cutover branch merges — after the engine-deletion sweep lands, the Docker-era baseline is unobtainable.
**Acceptance.** (1) A cage with the ssh cluster removed completes a **real** clone → commit → push → `gh pr create` cycle using only HTTPS + `--secret`, with **no ssh-agent socket present in the guest**. (2) Negative control: no ssh path remains reachable (no forwarded agent).
**Harness target.** Real git push + PR over HTTPS+`--secret`; assert the actual push landed (remote ref moved), assert ssh socket absent. No connect()-success. Plus: `make lint` green after this child's diff.
**Depends-on.** S1, S2. (Git-push autonomy is autonomy-critical; the HTTPS replacement must be proven before the only other path is removed.)

### S6 — rc lifecycle verbs on msb (create / resume / reload / doctor)
**Design.** REFACTOR state-machine rewrite in `cli/up.sh` + reload/doctor modules: create moves onto S2's flags; the D4 deny→fix→reload repair loop with the **snapshot-amend vs cold-recreate** choice; the **graceful-stop-only** corollary (force-kill silently discards completed guest writes — 9iab Q4); **cockpit/herdr re-registration on every resume** (every resume is a fresh kernel boot); **doctor redesign** (its engine-process probe is gone per S4 — needs a new msb posture-inspection story) and **reload redesign** (net-rule changes are recreate/snapshot-amend, not hot-swap). **Cutover landing posture (Fable review R1 — this bead is S6, msb lifecycle verbs):** S4 (engine deletion), S5 (ssh-cluster retirement), and S6 (msb lifecycle verbs) develop on a shared cutover branch and merge to main TOGETHER — S4 alone leaves main's `rc up` broken/uncontained; S5 alone removes ssh git autonomy from Docker cages before the msb HTTPS+--secret path is reachable through rc. During development S4 and S5 stay independently verifiable via S2's generator flags driven directly (`msb run`), not through rc's not-yet-rewritten verbs. Before the cutover merge, cut the pinned pre-cutover release — ADR-029 D1's rollback artifact. Sequencing (Fable harness review item 2): the Part-B baseline ledger (rip-cage-7atw.14) must complete and be an ancestor of the pinned pre-cutover release tag before the cutover branch merges — after the engine-deletion sweep lands, the Docker-era baseline is unobtainable.
**Acceptance.** (1) A cage survives a full deny → fix → reload cycle with **real data**: an initially-denied host returns no data, the loop applies an amended rule, the same host then returns **real application data** on retry, with pre-existing overlay/session state intact where snapshot-amend was used. (2) A graceful stop provably **persists** a completed guest write; a `--force` stop is refused/avoided on state-bearing cages (regression guard for the silent-loss footgun). (3) After resume, cockpit/herdr state is re-registered and an attached pane is usable. (4) `doctor` reports cage posture without referencing deleted engine processes. (5) **Deny-visibility (D2 re-home):** cages boot with trace logging on by default, and a denied egress surfaces the **denied domain** as a readable fix-hint (the `domain=` field rc tails) that the repair loop consumes — verified by triggering a real denial and observing the denied domain in the fix-hint output, not merely present in a raw log line. (6) After resume, the init-established in-guest state (git identity, hooks wiring, auth posture) is re-established — verified by a real post-resume EFFECT: a git commit made inside the resumed cage carries the correct identity (per ADR-029 D4's 'rc re-runs init on each resume' corollary). Cockpit/cage re-registration alone does not satisfy this.
**Harness target.** Effect: denied→amended→real-data across a repair cycle; graceful-stop write-persistence with a real read-back; hard-kill-loses-write as the negative control. Plus: `make lint` green after this child's diff.
**Depends-on.** S1, S2, S3, S4. (S3 first: the resume harness needs the dir-seed fix. S4 real, not thematic: both edit `cli/up.sh` create-path orchestration — S4 removes old root-exec init calls, S6 installs the replacement; hard-cutover means old gone before new is the single source of truth.)

### S7 — Curated default egress allowlist contents
**Design.** D4's seed allowlist (data content, not mechanism) so fresh cages aren't denial whack-a-mole. Seed from 1ujn: `api.anthropic.com:tcp:443` as the hard entry a basic `claude -p` turn requires; `mcp-proxy.anthropic.com` + datadog intake as attempted-but-nonblocking (for denial-log-noise-free defaults). Contents finalized here.
**Acceptance.** (1) A freshly created cage with **only** the shipped defaults completes a real basic agent turn end-to-end with **zero** denial-driven repair-loop trips. (2) A host outside the defaults is denied (no data) — confirming the defaults are a tight allowlist, not allow-all.
**Harness target.** Real agent turn on defaults-only cage with no denials; out-of-default host yields no data.
**Depends-on.** S2, S6. (Content is only verifiable against a real create path emitting real flags + the repair loop.)

### S8 — Label-lock re-binding to msb sandbox metadata (ADR-028)
**Design.** Re-target the surviving label-lock instances (set-valued fingerprint, config-mode, re-shaped per-tool credential-mount) + the image-drift sibling from Docker container labels / image-ID inspection onto msb's sandbox-metadata + image-record equivalents. **Must adjudicate** ADR-028's own open question: whether msb snapshot-amend makes **mount shape** (not just net-rule shape) amendable on a running/stopped sandbox — if so, D-clause invalidation fires and the mount-shape label-lock family collapses into plain re-synthesis for those fields (a real fork this child resolves).
**Acceptance.** (1) A cage resumed after a config change that alters mount shape **aborts loud** with the mismatch (not a silent re-mount) — verified by attempting a read/write **through the mount** and observing which shape the guest actually sees, not by reading a stored label. (1b) A **matching** config resumes clean with no false abort (proves the abort is mismatch-specific, not resume-blanket). (2) The mount-mutability question is resolved with a written verdict + evidence (amendable → re-synth path; not → keep the abort guard). (3) Image-drift sibling compares against msb's image record. (4) The mount-mutability verdict is written back into ADR-028 itself (evolve in place — fire or discharge the D-clause invalidation, adjust the instance tally), not left in bead notes.
**Harness target.** Effect: mismatched-mount resume aborts; guest-observed mount shape is the evidence, not label inspection.
**Depends-on.** S6, S1. (Re-binds resume-time compare onto S6's mechanics; the mount-mutability question is about S6's snapshot-amend behavior; image-drift target is S1's image record.)

### S9 — Re-verify ADR-023 mount-denylist against msb mount-flag syntax
**Design.** ADR-029 canonical_refs flags ADR-023's mechanics for re-verification on msb mount syntax. The secret-path denylist survives (KEEP per the partition-map correction — isolation-independent), but its realpath-resolution assumptions and the mount-flag forms it gates need confirming against S2's actual output (incl. any uid-virtualization msb applies to mounts).
**Acceptance.** (1) A path matching the denylist is actually **absent/unreadable from inside the guest** under the msb-syntax mount flags in use — verified by an in-guest read attempt of the resolved path, not by checking host-side validation returned an error. (2) A non-denylisted path is readable (control). (3) realpath/symlink-escape cases still caught under msb mount semantics.
**Harness target.** In-guest read attempt of a denylisted resolved path returns nothing; host-side validator error is not sufficient evidence.
**Depends-on.** S2. (The mount-flag syntax under test is S2's output.)

### S10 — Safety test-suite migration to msb-side effect probes
**Design.** The decompose-scoped item ADR-029 reserves (Sibling reconciliation): retire the engine-coupled test files (probing the deleted router/egress/DNS/mediator) and replace their coverage with **msb-side effect probes** per D2's re-homed effect-verification principle, reusing the spikes' proven techniques (real-bidirectional-data, two-port discriminator, host-side QNAME wire-observation). Classify the ~170 test files per partition-map §F; builds on `rip-cage-7atw`'s refreshed baseline.
**Acceptance.** (1) Each migrated test asserts a **real effect** — denied host returns no application data; a secret-violation toward an unbound host is blocked-and-logged with the guest never observing the real value; a DNS-exfil-shaped query never reaches an upstream resolver — **never** rule/flag presence in an inspect output. (2) Every engine-coupled test is either retired or re-homed (no dead tests referencing deleted machinery). (3) The suite runs green under `msb exec`. (4) Makefile BASH_SCRIPTS list is updated for every deleted/added shell file; `make lint` is green on the post-diff tree.
**Harness target.** The migrated suite itself — its assertions are the effect checks; a rule-presence assertion anywhere is a defect. Plus: `make lint` green after this child's diff.
**Depends-on.** S1, S2, S4, S6. Also builds on `rip-cage-7atw`.

**Transitional note (Fable harness review R3c):** the full host suite is transitional while S10 rewrites it — per-child harness runs the still-relevant subset; full post-migration host suite green is the EPIC-CLOSE gate at parent (`rip-cage-tsf2`) re-verify, not a per-child gate.

### S11 — DinD/compose disk-kind docker-data volume support
**Design.** Wire the proven-but-unwired capability (findings §10b): cages needing nested Docker/compose get a **disk-kind** (virtio-blk, not virtiofs) named volume for `/var/lib/docker` as a manifest-declarable concern (`--mount-named NAME:/var/lib/docker:kind=disk,size=…`), plus the in-cage client knobs the spike found necessary (`PGSSLMODE=disable`; connect over TCP from the cage, not `docker exec` into nested containers; `--init` handoff for dockerd). Distinct manifest surface from S2's base generator.
**Acceptance.** (1) A compose-launched service inside a cage using the disk-kind volume accepts a **real write+read round trip over TCP** (actual data returned, not a healthy-container status). (2) A virtiofs-dir volume for the same path fails overlay2 (negative control confirming disk-kind is required). (3) dockerd survives via `--init` handoff (not reaped when `msb exec` returns).
**Harness target.** Real DB write+read over TCP through the disk-kind-backed compose service; container-status is not evidence.
**Depends-on.** S1, S2.

### S12 — Golden-master harness re-alignment + de-flake for msb
**Design.** The existing golden-master (`tests/golden-master/capture.sh`, baseline f6ecd3b) captured **docker-argv-shaped** output; re-target it to msb-shaped output now that behavior deliberately changed (not preserved), and **de-flake** it first (gto1 close-notes: green only run serially — concurrency-fragile / host-state-sensitive). "Alignment" = bring existing infra into agreement with shipped reality; lands after the mechanism children, not as an upfront preservation gate (that pattern applied to the pure-refactor, not this cutover).
**Acceptance.** (1) Re-recorded snapshots are **byte-stable across repeated capture/check runs under real concurrency** (the flagged non-determinism no longer reproduces). (2) A deliberately mutated build makes at least one snapshot go **RED** (the net detects drift, not trivially passes). (3) Snapshots reflect the final post-cutover CLI surface (msb argv), not docker argv. (4) Re-recorded golden-master snapshots confirm the S4/S5-removed verbs and argv are absent from the generated output.
**Harness target.** Repeated concurrent record/check stability + a mutation canary that goes red. (This child hardens the net others rely on.) Plus: `make lint` green after this child's diff.
**Depends-on.** S2, S4, S5, S6. (Needs the final post-cutover create/resume/reload/doctor surface to snapshot meaningfully.)

### S13 — CLAUDE.md + reference-docs + examples cutover sweep
**Design.** The sibling-reconciliation prose living in the primary tree: rewrite CLAUDE.md's ssh-trust section (D3); update reference docs describing the retired egress/credential/ssh machinery; and the `examples/` dir — drop the mediator/MITM composition recipes that die with S4, demote the LAN-IP ssh bridge to documented-recipe-only (S5), and add the opt-in observation + method/path-aware-egress composed-mediator recipes D2/D4 keep as compose-only options. The D7 interim beads single-writer discipline (convention, no code) folds in here as documented guidance. **(Fable review R2)** The ADR-corpus banner flip is now IN SCOPE at cutover — previously excluded ("not the ADR docs"); at cutover the sibling ADRs' interim migration-status banners are flipped to record the cutover as landed, and ADR-029's own status is updated.
**Acceptance.** (1) A reader following **only** the post-cutover docs completes a real git push and a real denied-host repair-loop cycle end-to-end with **no reference to retired ssh/engine machinery** — the docs' own procedure, executed literally, produces the claimed effects. (2) No doc/example references a deleted verb, flag, or script. (3) The D7 single-writer discipline is documented as interim guidance. (4) At cutover, the sibling ADRs' interim migration-status banners are flipped to record the cutover as landed (mechanisms retired/replaced as of the cutover release); ADR-029's own status is updated; and a grep for 'remain shipped and load-bearing in the Docker path' returns zero stale hits.
**Harness target.** Execute the docs' own procedures literally; assert the real effects land (push, repair cycle). Grep for dead references as a secondary structural check. Plus: `make lint` green after this child's diff.
**Depends-on.** S4, S5, S6, S7, S8. (Docs describe shipped behavior; land last.)

### S14 — Factory stack (dotpi-3bi) runs per-cage via the socket-API drive path
**Design.** The epic acceptance names "herdr and the intended factory stack (dotpi-3bi) run per-cage." S6(3) proves herdr re-registration + interactive attach, but the factory drives herdr via the **socket-API pane run/read path** (not interactive attach) — server socket at `~/.config/herdr/sessions/NAME/herdr.sock`, dimensions set explicitly (epic herdr gotchas). This child stands up the dotpi-3bi cage config on msb and drives a real pane run/read through the socket API. **Scope-boundary item:** the epic frames dotpi-3bi as "ONE cage config/recipe, not the product" and dogfooding as the *next* step after migration — **Fable rules whether this is in-scope for tsf2 or deferred to the first dogfooding itch.** Included here so the epic acceptance clause isn't silently dropped.
**Acceptance.** (1) A dotpi-3bi cage on msb drives a real herdr pane via the socket-API path — a command run through the socket returns its **actual output** read back (real data, not attach-liveness). (2) The pane is correctly sized (no ~4-col headless wrap) when dimensions are set explicitly.
**Harness target.** Socket-API pane run→read returns real command output; assert the actual output value, not pane-attach success.
**Depends-on.** S6. (Needs cockpit/herdr re-registration + the lifecycle verbs.)

---

## Coverage against epic acceptance

| Epic acceptance clause | Slot(s) |
|---|---|
| cages boot via msb | S1 |
| rc verbs regenerated to msb equivalents | S2, S6; removal side S4, S5; mount syntax S9 |
| in-guest egress+credential engine retired for msb `--net-*`/`--secret`/`--tls-intercept` | S2, S4 |
| ssh cluster fate (D3) | S5 |
| dind/compose cages use disk-kind docker-data volumes | S11 |
| herdr + factory stack (dotpi-3bi) run per-cage | S1 (boot), S6 (cockpit/herdr re-registration), S14 (factory socket-API drive — scope-boundary, Fable rules in/deferred) |
| default allowlist / repair-loop UX (D4) | S7, S6 |
| mount-shape drift guards survive (ADR-028) | S8 |
| secret-path mount denylist survives (ADR-023) | S9 |
| effect-based safety coverage (D2) | S10 |
| CLI-surface regression net | S12 |
| docs/CLAUDE.md/examples describe shipped reality | S13 |
| settled decisions stamped as ADRs | already complete (ADR-029 + 14-ADR reconciliation) — no child |
| bd image pin (D7 unconditional child) | existing `rip-cage-7i2p` |
| trustworthy pre-migration test baseline | existing `rip-cage-7atw` |
