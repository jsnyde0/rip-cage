# `rc` decomposition — behavior-preservation harness (target spec)

**Status: DRAFT (rev.2 — two review rounds folded in 2026-07-08; round 2 confirmed the load-bearing
reachability fact and hardened the §3(i) shim to be content-keyed + fixed the §3(vi) reload test).** The verifiable target
the `rc`-decomposition (`rip-cage-gto1`) iterates against. Companion to
`docs/2026-07-08-rc-decomposition-map.md` (the split + hazards this harness exists to catch) and
`docs/2026-07-08-target-repo-layout.md` (the restructure that lands `cli/`). Produced 2026-07-08 by a
fresh harness-design pass grounded in `rc` + `tests/` (222 files) + `.claude/harness.md`.

Core requirement: **behavior-PRESERVING** — zero observable change to any `rc` verb across the split.
The harness = a **golden-master** of `rc`'s observable behavior captured once at current HEAD that must
hold byte-identical at every commit of both refactors.

## 1. Golden-master capture
`tests/golden-master/capture.sh` drives each verb against a **fixed fixture tree** under a pinned
sandbox env (`HOME`/`XDG_CONFIG_HOME`/`RC_CONFIG`/`RC_ALLOWED_ROOTS`/`RC_MANIFEST_GLOBAL` → fixtures;
mirrors `run-host.sh:101-120`), captures `{stdout,stderr,exit}`, applies the §2 scrub, then diffs.
`--record` at HEAD writes snapshots; `--check` (default) at every later commit requires byte-identity.
Reuses `rc`'s proven idioms (source-rc-and-call-fn-directly; PATH-shim fake `docker`) — NOT a
snapshot-library.

**(a) Container-free net (prioritized — the cheap, high-coverage tier):** `build`/`generate-dockerfile`
(bundled vs from-source), `up --dry-run` + `--output json` (all 8 container states via a `docker`
inspect-shim), `down`/`destroy`/`reload --dry-run`, `ls` (shim table), `config show/get/init`, `schema`,
`completions zsh/bash`, `usage`/unknown-verb, flag-parse errors (`--output json`/`--dry-run` allowlists,
missing args), `manifest reconcile`, `install --yes`, `setup` (zsh/bash/fish/unset), `attach`/`exec`
error paths, `allowlist show/add`, `auth refresh` (non-macOS path), `doctor --host`.

**(b) Live-container verbs — OUT of golden-master scope** (`up`/`attach`/`exec`/`down`/`destroy`/`reload`
actually running): governed by the EXISTING `run-host.sh` NEEDS_CONTAINER tier, not snapshotted
(too slow per-iteration + inherently non-deterministic container IDs). They contribute to the contract
via "full suite green," not byte-identity.

**(c) The `test` verb (F6 — was neither netted nor deferred).** `rc test` (dispatch rc:12842-12866 →
`cmd_test` rc:6479) `exec`s `${SCRIPT_DIR}/tests/run-host.sh` — not golden-mastered (it RUNS the suite),
but its `$SCRIPT_DIR`-relative exec is restructure-sensitive (5jp3). Add a smoke: `rc test` still
resolves+execs the runner after the restructure. (`__bd-preflight-test`/`__bd-port-inject-test` are
internal hooks — reasonably omitted.)

## 2. Determinism plan (byte-identity fails on nondeterminism)
| class | scrub |
|---|---|
| Absolute host paths | capture under a FIXED scratch root (not `mktemp` — macOS `/var/folders/<rand>` drifts), `sed` scratch-root → `<GM_ROOT>` |
| `$SCRIPT_DIR` / moved-file reads | **the subtle one.** Restructure (5jp3) relocates `${SCRIPT_DIR}/Dockerfile`→`/cage/Dockerfile` etc. Scrub must compare the **content served** (e.g. Dockerfile bytes for `generate-dockerfile`), NOT the raw path string, or 5jp3 spuriously breaks every snapshot referencing a moved file despite unchanged behavior. Where the path itself IS the observable (error msgs naming a config file via `$HOME`/`$XDG_CONFIG_HOME` — unaffected by 5jp3), keep it path-identical. |
| Timestamps/provenance | fixtures seeded with fixed content; regex-strip any live ISO-8601 → `<TS>` (grep as canary for new emitters) |
| Container IDs | N/A in (a)-tier; (b) excluded |
| Ordering | shim returns fixed `ls` table; jq `-c` stable; reconcile arrays follow fixture YAML order |
| Env leakage (`$SHELL`/`$HOME`) | captured as INPUTS (the case axis for setup/install), not scrubbed |

**Scrub self-check — TWO-DIRECTIONAL (F5).** (a) *Under-scrub:* run capture twice back-to-back on an
unmodified checkout, diff against itself — non-empty = a missing scrub. (b) *Over-scrub (the one a
self-diff can't catch):* a MUTATION CANARY — deliberately perturb a semantically-meaningful part of a
verb's output (e.g. a fixture change that makes `generate-dockerfile` emit a genuinely different
Dockerfile body) and confirm `--check` goes RED. If the scrub swallows it, the scrub is too broad
(especially the subtle content-vs-path `$SCRIPT_DIR` rule) and would false-GREEN a real regression.
Neither direction alone suffices; both must pass before the baseline is trusted.

## 3. Seam/hazard tests (what the golden master alone won't catch — one per map hazard)
**(i) `_UP_RUN_ARGS` global accumulation — CRITICAL, the docker-run argv byte-identical pre/post split.**
The `--dry-run` capture does NOT exercise this — `cmd_up`'s dry-run branch (rc:4693-4736) returns a
summary and never assembles the argv. TWO tests, both load-bearing:
- *Helper-level:* extend the proven idiom (`test-credential-mounts.sh:110-131` already resets
  `_UP_RUN_ARGS=()` + calls `_up_prepare_docker_mounts`) into a full-chain `test-up-run-args-full-chain.sh`
  replicating cmd_up's real create-path call order (rc:5137→5408→`_up_start_container` 5410), diff the
  final array vs a golden snapshot.
- *End-to-end (higher fidelity):* run a REAL `rc --output json up <fixture>` against a `docker` shim.
  **Build the shim CONTENT-KEYED (rev.2) — respond by WHAT is inspected, not by call-order position.**
  Two review rounds both mis-stated the exact create-path docker sequence, which is the tell that a
  positional-replay contract is the wrong shape: it breaks on any omitted or reordered call. A
  content-keyed shim is robust to both. Contract:
    - any `docker image inspect $IMAGE …` → SUCCESS, and when `--format` requests the image version,
      return a value == `$RC_VERSION`. (Covers BOTH the *bare* `docker image inspect "$IMAGE"` at
      rc:4635 AND the `--format '{{…version}}'` inspect in `_image_is_current` rc:399 — either returning
      absent sets `_image_absent=true` → `_pull_or_build` at rc:5126 before argv.)
    - `docker inspect --format` querying `.State.Status` → non-zero/absent (rc:4686; else rc:5115
      "unrecognized state" → return 1 before argv).
    - `docker inspect --format` querying a label (`.rc.source.path`, rc:4651) → empty.
    - `docker run …` → append `"$@"` to a capture file, then `exit 1`.
  (Real order is bare-inspect rc:4635 → version-inspect rc:399 → label rc:4651 → state rc:4686 → … →
  run — but a content-keyed shim does not depend on getting that order or the full list right; the §2
  scrub self-check + the first real run surface a mis-built shim loudly.)
  With a correct shim, `cmd_up` reaches the full `_UP_RUN_ARGS` (final append rc:5408) + the single
  `_up_start_container` (rc:5410) — **the review VERIFIED the argv is fully assembled at 5408 with NO
  intervening docker call**, before the firewall/mediator/init code (rc:5411+) needing a live container.
  **Termination (F2):** use `--output json` so the JSON branch's `json_error`→`exit 1` (rc:2005-2015, 71)
  fires deterministically (the human branch rc:2016-2018 aborts only via `set -euo pipefail`); pin JSON
  mode. Reaches cmd_up's REAL control flow (the helper test hand-replicates order and can drift). **This
  is the load-bearing gate for the whole decomposition — the content-keyed shim is what makes it robust.**

**(ii) up↔reload coupling.** Structural: after split, source `cli/reload.sh` (per shim order) and assert
`declare -F _up_reload_tcp22_allowlist`/`_up_reload_egress_proxy`/`_up_resolve_egress_rules` all succeed
(fails loud if the lift-to-lib-vs-depend-on-up.sh boundary is unresolved). Behavioral: `rc reload <name>`
against a docker-exec shim, assert `_up_resolve_egress_rules` ran (writes per-cage egress cache, rc:3748+).

**(iii) `RC_VALIDATE_WARNING` write→read seam.** `validate_path` (→lib/path) writes it; `_up_json_output`
reads it into JSON `warning`. **Reachability preconditions (F3):** the rc:4542 write is env-file-gated
(rc:4534 `[[ -n "$env_file" ]]`) and NOT hit by a no-env-file dry-run — only the rc:601 write fires, so
trigger THAT path (the validate_path warning, e.g. `RC_ALLOWED_ROOTS` unset). AND the read at rc:4769
runs only when `_image_absent==false` — else rc:4759 takes the would_build/would_pull blob (rc:4763-4766)
that emits no `warning` field. So the fixture MUST report the image present+current (shim per §3(i).1).
Then `rc --dry-run --output json up <path>`, assert the `warning` field's exact string pre+post split.
Folds into §1(a)'s dry-run-json matrix (with the image-present precondition).

**(iv) CONDITIONAL strict-mode contract under per-module sourcing.** `test-rc-source-isolation.sh`
proves it for `rc` itself but NOT for the new `cli/*.sh` modules. Add: per-module `source cli/X.sh
2>/dev/null; [[ "$-" != *e* ]]` + structural `grep -L 'set -euo pipefail' cli/*.sh` (catches any future
module too). The shim owns strict mode exactly once.

**(v) Source-order + name-collision.** Source the new shim, assert each of the 5 top-level globals
(`_EGRESS_BASELINE_HOSTS`, `_UP_EGRESS_MODE`, `_UP_DCG_CONFIG_PATH`, `RC_CONFIG_SUPPORTED_VERSION_MAX`,
`_RC_RELOAD_ELIGIBLE_PATHS`) is set BEFORE dispatch; `declare -F` count == 193 (loud fail on any silent
redefinition/shadow across files).

**(vi) reload EXIT-trap side-effect (F4 — golden-master-INVISIBLE).** The only `trap` (rc:5988,
`trap "rmdir '$lock_dir' 2>/dev/null" EXIT` in `cmd_reload`) is a FILESYSTEM side-effect the
golden-master (stdout/stderr/exit only) cannot see. A split that drops or rescopes it leaks `$lock_dir`
→ the NEXT `rc reload` hits the lock guard (rc:5981-5984) → `exit 3`. Add a test: run `cmd_reload`,
assert `$lock_dir` is ABSENT afterward; plus a two-run case asserting the second reload does not `exit 3`.
**Two requirements the construction must honor (rev.2):** (1) the trap (rc:5988) is reachable only
AFTER the reload docker gates — container exists (rc:5950), `verify_rc_container` (rc:5953/5808), state
== running (rc:5956, else exit 2), workspace label non-empty + dir exists (rc:5964) — so the shim must
present a RUNNING container with a valid `rc.source.path` label, not a bare stub. (2) the EXIT trap fires
at SHELL exit, not function return — so the two-run case MUST run each `cmd_reload` in a SEPARATE
process/subshell; two in-process calls leave run-1's `$lock_dir` (trap unfired) → run-2's `mkdir` fails →
spurious `exit 3` that inverts the test's conclusion.

## 4. Gap-fill (the 7 coverage gaps → tests to ADD before the split)
`generate-dockerfile` (`test-generate-dockerfile.sh`), `setup` (`test-rc-setup.sh`, incl. idempotency),
`attach`/`exec` error-path matrix (extend existing), `manifest reconcile` verb
(`test-manifest-reconcile-verb.sh`, incl. backup-before-overwrite), `install` (`test-rc-install.sh`),
up↔reload seam (§3ii), `RC_VALIDATE_WARNING` seam (§3iii). All container-free except live attach/exec
bodies and the reload behavioral case (docker-exec shim).

## 5. Boundary validation (confirm the lib-vs-module cut — the map's cut is a PROPOSAL)
Mechanical: for each `cli/lib/` candidate, `grep -n '<fn>' rc`, drop the def line, bucket call-sites
against the module line-range table — a genuine lib candidate has call sites in **≥2 distinct module
regions**. (Demonstrated: `_manifest_check_ioc_egress` → build rc:272 + up rc:4613 + allowlist rc:6077
= 3 modules, confirms map.) Run for the full lib-candidate set; output = a CORRECTED lib table folded
into the design before implementation. **Closure rule (F7):** ≥2-module call sites is the SEED, not the
whole rule — then take the closure: any function called by a lib member ALSO goes to lib, even if its
own call sites are single-region. Otherwise a helper called by one lib function gets pushed into a
module while the lib fn still calls it → a lib→module dependency, the exact coupling §3(ii) forbids.
So: seed lib with ≥2-module functions, then add every function transitively called by a lib member;
"single-module ⇒ move out" applies only to functions NOT in that closure (over-extraction widens every
module's source surface — itself a hazard). Structural/prose step; gates implementation start, not CI.

## 6. Per-module reachability
Post-split, map each `cli/*.sh` → its driver test files (from the map's verb-driver counts:
up←59, build←37, down/destroy←22, doctor←9, ls←9, reload←7, allowlist←5, auth←5, config←5,
manifest←validator suite ~30 + gap-filled verb, attach_exec←gap-filled, setup←gap-filled to 1).
A module with zero post-gap-fill drivers is a hard stop — none are.

## 7. Pass/fail contract (what GREEN means — full conjunction)
1. Golden masters byte-identical (`capture.sh --check` exit 0).
2. Full `tests/` suite green — `bash tests/run-host.sh` INCLUDING NEEDS_CONTAINER (a scoping bug in
   the up-block may only manifest under real `docker run`).
3. All §3 seam tests + §4 gap tests green.
4. `rc build` succeeds.
5. Dogfood `rc up` smoke in repo root (real end-to-end create path assembles a working argv;
   `.rip-cage.yaml` still discovered).
6. Cwd-independent sourcing incl. the Homebrew `libexec/` symlink case — add an explicit test:
   symlink `rc` + its `cli/` dir into a scratch bin, invoke via symlink, assert dispatch works
   (`_resolve_script_dir` is proven for the flat file but NOT for the new multi-file sourcing).
7. Committed behavior-neutral (only `rc`'s file structure changes; zero snapshot-content diff).

## Fast-tier vs slow-tier (the orchestrator's iteration loop)
- **Fast** (between iterations): `bash -n` on touched files + `capture.sh --check` (container-free,
  seconds, no daemon) + `grep -L 'set -euo pipefail' cli/*.sh` + the §3(v) count/global-init assert.
- **Slow** (pre-close gate): full `run-host.sh` (NEEDS_CONTAINER) + build + dogfood `rc up` +
  symlink-sourcing + `make lint`.

## What this harness will NOT catch (honest gaps)
- **Live-container verb bodies** — deferred to the existing NEEDS_CONTAINER tier; a change reachable
  only through a real container lifecycle could slip the fast-tier and surface only at slow-tier (or
  not at all if the existing live tests don't assert that field).
- **The `--dry-run`-bypasses-`_UP_RUN_ARGS` gap** means §3(i)'s TWO tests are load-bearing — skipping
  either re-opens the exact hazard this harness exists for. The novel fake-docker-exit-1 technique
  deserves adversarial review before being trusted as the CRITICAL-hazard gate.
- **Runtime-perf/readability of the cut** — §5 confirms caller-count boundaries only, not whether the
  resulting file sizes are actually more agent-tractable (the stated motivation). Judgment call.
- **shellcheck/lint regressions** — covered by the repo's `make lint`; fold into slow-tier explicitly.

> Note (provenance): the design pass had no `bd` CLI and read bead state from `.beads/issues.jsonl`
> (a lagging export). Bead facts used (5jp3 = FILE MOVES ONLY; gto1 = decomposition) match current
> state, but re-verify via `bd show` if these beads moved after 2026-07-08.
