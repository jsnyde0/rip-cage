# `rc` decomposition map — module split, hazards, coverage (input for /harness)

**Status: DRAFT — structural analysis feeding bead rip-cage-gto1 (decompose the rc monolith).**
Produced 2026-07-08 from a full structural pass over `rc` (12,866 lines, 193 top-level functions).
This is the raw material the **/harness** pass consumes to design the behavior-preservation
golden-master. It is NOT yet a verified minimal module cut — the lib/-vs-module boundary for the
mid-tier helper families is a *proposal* the harness pass must confirm against actual caller sets.

## The headline: this is riskier than "split by verb"
`cmd_up` is **~4,700 lines** and is a **global-mutable state machine, not a call tree** — it and its
~55 `_up_*` helpers communicate through **~24 `_UP_*` shell globals/arrays** (e.g. `_UP_RUN_ARGS`, the
`docker run` argv accumulator, appended by dozens of helpers and consumed in `cmd_up`), NOT return
values. Three giants — **up (~4,700) / manifest (~3,770) / config (~1,390)** — are 78% of the file.
The regression surface is those mutable globals + cross-verb helpers + a single conditional
`set -euo pipefail` predicate that the test suite depends on. **Do NOT sub-split `cmd_up` in this
pass** — keep the whole up constellation in one `cli/up.sh`.

## Ground truth — dispatch + strict mode (must be preserved verbatim in the `rc` shim)
- **Strict mode is CONDITIONAL** (`rc:5-7`): `set -euo pipefail` runs only when `rc` is *executed*,
  gated by a `BASH_SOURCE`-vs-`$0` predicate — **tests SOURCE `rc` and rely on strict mode being
  OFF**. The identical predicate gates dispatch at `rc:12775`; the two "must stay in sync" (rc:2-4).
  **Do NOT add `set -euo pipefail` to individual `cli/*.sh`** — that flips strict mode ON when a test
  sources one module, changing behavior. The shim owns strict mode exactly once.
- **Main dispatch:** single `case "${1:-}"` at `rc:12842-12866`, verb → `cmd_<verb>`. Verbs: `build up
  ls attach exec down destroy reload allowlist test doctor auth config manifest completions install
  setup schema generate-dockerfile` (+ two `__bd-*-test` internals).
- **Pre-dispatch top-level logic NOT in any function** (stays in the shim, not a module):
  `_resolve_script_dir`+`SCRIPT_DIR` (rc:11-22), completions fast-path (rc:28-37, before the container
  guard), `/.dockerenv` host-guard (rc:39-43), `rc.conf` sourcing (rc:52-59), global-flag parse loop
  (rc:12777-12795), `--dry-run` allow-list `up|destroy|reload` (rc:12799), `--output json` allow-list
  (rc:12810), `check_jq`/`check_docker` gates (rc:12821-12839).
- **Sub-dispatch verbs:** `auth`→`cmd_auth_refresh`; `allowlist`→`_allowlist_{add,show,promote}`;
  `manifest`→`_manifest_reconcile`; `config`→`cmd_config_{show,get,init}`.

## Proposed module split
### `cli/lib/` — shared helpers (called by ≥2 verb-modules)
| lib file | key functions | ~lines |
|---|---|---|
| `lib/output.sh` | `log` (115 call-sites), `json_error` (70), `_prereq_error`, `check_jq`, `usage` | ~82 |
| `lib/docker.sh` | `_docker_call`, `_run_with_timeout`, `check_docker` | ~84 |
| `lib/container.sh` | `container_name`, `resolve_name`, `verify_rc_container`, `_container_multiplexer` | ~79 |
| `lib/path.sh` | `validate_path`, `_path_under_allowed_roots`, `_lexical_normalize_path`, `_manifest_dest_in_allowed_roots`, `_host_source_is_root_owned` | ~230 |
| `lib/config.sh` | `_load_effective_config` (**41 call-sites**) + `_config_*` loader/merge/provenance/schema family | ~900 |
| `lib/manifest_checks.sh` | `_manifest_check_ioc_egress`, `_manifest_check_{binary,mount}_root_owned`, `_manifest_check_seed_drift`, `_manifest_ensure_seeded`, `_manifest_build_dockerfile_path`, `_manifest_check_mounts_denylist`, `_manifest_expand_mount_host` | ~700 |

> The `_config_*` and `_manifest_check_*` families have BOTH loader/check primitives (→ lib) and
> verb-facing glue (→ module). Drawing that line precisely is the single biggest design decision —
> the harness pass must validate each lib-candidate's real caller set before finalizing.

### `cli/` — verb modules
| module | owns | ~lines |
|---|---|---|
| `cli/build.sh` | `cmd_build`, `cmd_generate_dockerfile`, `_image_is_current`, `_pull_or_build*` | ~273 |
| `cli/up.sh` | `cmd_up` (1,082) + ~55 `_up_*/_ssh_*/_identity_*/_egress_*/_mediator_*/_bd_*` helpers | **~4,700** |
| `cli/ls.sh` | `cmd_ls`, `_rc_ls_mode_from_source_path` | ~95 |
| `cli/attach_exec.sh` | `cmd_attach`, `cmd_exec` | ~123 |
| `cli/down_destroy.sh` | `cmd_down`, `cmd_destroy` | ~117 |
| `cli/reload.sh` | `cmd_reload` (holds the only `trap`) | ~184 |
| `cli/allowlist.sh` | `cmd_allowlist`, `_allowlist_*` (8) | ~359 |
| `cli/test.sh` | `cmd_test` (execs `tests/*` via `$SCRIPT_DIR`) | ~151 |
| `cli/doctor.sh` | `cmd_doctor`, `_doctor_*` (5) | ~702 |
| `cli/setup.sh` | `cmd_setup` | ~113 |
| `cli/manifest.sh` | `cmd_manifest`, `_manifest_reconcile`, `_manifest_validate` (847!), ~18 `_manifest_generate_*` (the Dockerfile emitter), seed/fingerprint | **~3,770** |
| `cli/config.sh` | `cmd_config{,_show,_get,_init}`, `_config_init_*`, verb-facing config glue | ~490 |
| `cli/auth.sh` | `cmd_auth`, `cmd_auth_refresh`, `_extract_credentials*` | ~130 |
| `cli/install_schema.sh` | `cmd_install`, `cmd_schema` | ~162 |

## Hazards (grounded, ordered by regression risk)
1. **`cmd_up` global-mutable state (CRITICAL).** ~24 `_UP_*` globals cross helper boundaries by
   reference, not return. Split them across files and one helper that `local`-shadows or fails to
   re-declare an array = silent behavior change. **Keep the entire up-block in one file.** Other
   cross-file globals: `OUTPUT_FORMAT` (111 refs), `DRY_RUN` (shim→up/destroy/reload),
   **`RC_VALIDATE_WARNING` written by `validate_path` [lib/path] and read by `cmd_up`** (classic
   write→read trap), `WS_CONFIG_HOSTILE_*`, `IMAGE`/`RIP_CAGE_IMAGE_REGISTRY`/`RC_VERSION`.
2. **Cross-verb helpers → MUST be lib/, not a verb module.** `_load_effective_config` (41 sites:
   build-denylist/up/reload/allowlist); `_manifest_check_ioc_egress` (build/up/reload); the
   `_manifest_check_*`/`_manifest_build_dockerfile_path` set (build); **`_up_reload_*` /
   `_up_resolve_egress_rules` are DEFINED in the up-block but CALLED by `cmd_reload`** — an up↔reload
   coupling: either lift those three to lib, or `cli/reload.sh` hard-depends on `cli/up.sh` being
   sourced. (Flag for harness.)
3. **Definition/source-order dependence.** Top-level executable statements sit *between* function
   defs (`_EGRESS_BASELINE_HOSTS=(…)` rc:3597, `_UP_EGRESS_MODE=` rc:3794, `_UP_DCG_CONFIG_PATH=`
   rc:3981, `RC_CONFIG_SUPPORTED_VERSION_MAX=1` rc:7474, `_RC_RELOAD_ELIGIBLE_PATHS=` rc:12042) — run
   at source time. Shim must source all lib+modules (defining every fn + initializing these globals)
   BEFORE flag-parse + dispatch. 193 unique names, no redefinition — collision-safe, but re-verify.
4. **strict mode / trap / IFS.** Only one `trap` (rc:5988, EXIT rmdir inside `cmd_reload`) — keep in
   `cli/reload.sh`. All `IFS=` uses are function-local → safe. Error handling relies on strict-mode-on
   at execution (comments rc:2368/4684/7124/12336).
5. **`$SCRIPT_DIR` reads (29 sites)** assume the current flat layout — coordinate with the restructure
   (`rip-cage-5jp3`): keep `SCRIPT_DIR` = repo root, computed once in the shim, exported to modules.

## Coverage inventory (input for the golden-master net)
Verb-level test-driver counts (files invoking `rc <verb>`): up **59**, build 37, destroy 16, test 10,
doctor 9, ls 9, reload 7, down 6, allowlist 5, auth 5, config 5, schema 5 — then the **thin ones**:
attach **2**, exec **2**, manifest-verb **2**, install **2**, `generate-dockerfile` **1** (never
invoked as the verb), setup **~0 direct**.

**Coverage gaps (where /harness must add golden masters BEFORE the split):**
1. `generate-dockerfile` verb — 0 tests invoke it; no verb-level golden master.
2. `setup` verb — no test drives `rc setup` (only manifest-layer indirection).
3. `attach`/`exec` — 2 each, interactive/container-exec, depend on `lib/container.sh`; high split-exposure.
4. `rc manifest reconcile` (verb) — thin vs. the huge *validator* coverage; reconcile/backup path.
5. `install` — 2 incidental refs; installer/symlink path has no dedicated master.
6. **up↔reload seam** (`_up_reload_*` up-defined/reload-consumed) — exactly where a source-order split
   regresses; needs an explicit seam test.
7. **`RC_VALIDATE_WARNING` write→read seam** (validate_path → up json output) — assert it propagates
   end-to-end after the path/up split.

**Caveat:** internal-helper "tested by name" is presence-based (overcounts — a name in a comment
counts). Every one of the 193 names appears somewhere in `tests/`, which is NOT the same as
behaviorally asserted. Dense internal coverage for up/manifest/config does NOT mean "safe to split
without a golden master" — the hazard-1/2/3 seams are precisely what name-presence doesn't exercise.
