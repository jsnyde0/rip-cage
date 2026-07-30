# CLI Reference

## Commands

| Command | Description |
|---------|-------------|
| `rc build [allowed docker flags...] [-t/--tag <ref>]` | Build the rip-cage Docker image. **Not a pass-through**: `rc build`'s docker-flag surface is a fail-closed **allowlist** (rip-cage-zqjz.2) — see [`rc build` flag allowlist](#rc-build-flag-allowlist) below for the full admit/reject table and rationale. A caller-supplied `-t`/`--tag` **overrides** the image built/tagged — it does not add a second tag alongside the default `rip-cage:latest`, so `rip-cage:latest` is left untouched by a custom-tagged build (rip-cage-fo4z: previously docker applied *both* tags to the same image, silently re-tagging — and clobbering any composed bake on — `rip-cage:latest`). See [`rc build -t`/`--tag` details](#rc-build---t---tag-details) below for every accepted spelling, the fail-loud cases, and precedence vs `RC_IMAGE`. A caller-supplied `-f`/`--file`, `-o`/`--output`, or `--build-arg` (any spelling) is **rejected outright**, before any docker call — see [`rc build -f`/`--file` is rejected](#rc-build--f---file-is-rejected), [`rc build -o`/`--output` is rejected](#rc-build--o---output-is-rejected), and the [flag allowlist](#rc-build-flag-allowlist) below. |
| `rc up <path> [--port PORT] [--env-file FILE] [--new] [--session NAME]` | Start or resume a container |
| `rc ls` | List rip-cage containers |
| `rc attach [name]` | Attach to a running container (multiplexer-neutral — plain shell under `none`, tmux attach under `tmux`, supervisor view under `herdr`) |
| `rc exec <cage> -- <cmd...>` | Run a one-off command in a running container non-interactively (safe for CI and scripts); supports `--output json` |
| `rc down [name]` | Stop a container |
| `rc destroy [-f] [name]` | Remove a container and its volumes (prompts for confirmation) |
| `rc reload [name] [--dry-run] [--allow-transcript-loss]` | Apply `network.allowed_hosts` changes from `.rip-cage.yaml` (the sole reload-eligible path post-schema-v2) — a **cold-recreate** post-cutover, not a hot in-place apply ([details](egress.md#the-denyfixreload-repair-loop)). Also repairs a **stopped** cage's stale image (`rc build` ran since it was created/last repaired) without touching its `rc-state-`/`rc-history-` named volumes — the repair leaves the cage **running** afterward, unlike an ordinary running-cage reload. A running cage's own image drift still has no in-place repair (`rc down <name> && rc reload <name>`). Refuses loud if the cage's `~/.claude/projects` isn't host-bound (a legacy, pre-2026-07-08 cage) — the recreate would silently destroy in-flight caged-claude conversation transcripts; `--allow-transcript-loss` overrides |
| `rc allowlist add <host> [--cage=<name>]` | Append a host to `network.allowed_hosts` in `.rip-cage.yaml` (idempotent); `--cage` applies it via `rc reload` ([details](egress.md#rc-allowlist-command-reference)) |
| `rc allowlist show [--effective]` | Show configured / effective egress hosts ([details](egress.md#rc-allowlist-command-reference)) |
| `rc test [name]` | Run the safety stack smoke test inside a cage |
| `rc doctor [name]` | Per-cage diagnostic — labels + live probes (msb egress posture + recently-denied domains, auth, beads, dead-mount detection) |
| `rc config show [--json]` | Print effective `.rip-cage.yaml` config with provenance ([details](config.md)) |

`rc config init` is **retired** (it bootstrapped `ssh.*` fields via `git remote -v` + `ssh -G` — ssh-cluster-specific detection logic that no longer applies, [ADR-029](../decisions/ADR-029-msb-migration.md) D3). `cmd_config` supports only `show`/`get` today; author `network.allowed_hosts`/`auth.credentials` by hand — see [config.md](config.md).

## Flags

| Flag | Description |
|------|-------------|
| `--output json` | Machine-readable JSON output (human messages go to stderr) |
| `--dry-run` | Preview what would happen without executing (supported for `up`, `destroy`, and `reload`) |
| `--version` | Print version |

### `rc build -t`/`--tag` details

`rc build`'s hardcoded docker invocation always leads with `-t "$IMAGE"` (default `rip-cage:latest`, or `RC_IMAGE` if set). A caller-supplied `-t`/`--tag` **overrides** `$IMAGE` for the whole build — the docker call, the post-build root-owned validators, the fail-closed untag-on-violation cleanup — rather than being appended as a second tag (rip-cage-fo4z).

**Accepted spellings** — all of docker's own flag forms are recognized, not just the two obvious ones:

| Spelling | Example |
|----------|---------|
| Separate-arg, short | `-t custom:tag` |
| Separate-arg, long | `--tag custom:tag` |
| Equals-attached, long | `--tag=custom:tag` |
| Equals-attached, short | `-t=custom:tag` |
| Value-attached, short (no equals) | `-tcustom:tag` |
| Clustered behind docker's other boolean short flags (`-D`/`-q`) | `-qt custom:tag`, `-Dqt=custom:tag` |

Any of these left unrecognized and passed through unmodified would reproduce the original co-tag clobber, so all are parsed out and normalized to a single override — any leading `-D`/`-q` boolean flags in a cluster are preserved as their own token so their effect (debug/quiet) still reaches docker.

**Precedence:** `-t`/`--tag` wins over `RC_IMAGE` (both ultimately just set the effective `$IMAGE` for the build; the flag is parsed last and always takes priority when both are present).

**Repeated `-t`/`--tag`:** last occurrence wins (only ever a single effective tag — rc's `-t` does not accumulate the way docker's own `stringArray` semantics would).

**Fails loud, before any docker call, for:**
- A missing value (`-t` / `--tag` as the last argument with nothing after it).
- An **explicitly empty** value (`-t ""`, `--tag=`, `-t=`, …) — this is distinguished from "not supplied" internally; treating them the same was a real regression risk (an empty tag would otherwise silently fall back to building/tagging the default `rip-cage:latest`, rather than erroring the way plain `docker build -t ""` does).

**`--`:** stops rc from scanning further arguments for `-t`/`--tag`, but is **not** a general verbatim-pass-through escape hatch — `cmd_build` always appends the build context path as its own final positional after `"$@"`, so any non-empty content placed after `--` yields two or more positionals and `docker build` hard-errors (`requires 1 argument`) rather than doing something unexpected. Fails loud; does not clobber.

**Stale-container warning:** `rc build`'s informational "container was created from a different image" warning (about existing cages `rc up` will refuse to resume) is skipped when a custom `-t`/`--tag` was supplied — that warning's premise ("cages running the image you just rebuilt") doesn't hold for a scratch/throwaway-tagged build, and every real cage is still pinned to whatever image it actually was, untouched by the custom-tagged build.

### `rc build -f`/`--file` is rejected

`rc build`'s hardcoded docker invocation always leads with `-f "$_dockerfile"` (rc's own manifest-resolved Dockerfile — the one `_manifest_check_build_isolation`, the pre-build build-isolation gate, ADR-005 D9 / ADR-024, actually audits). Unlike `-t` (additive — docker applies both), a duplicate `-f` is **last-wins** in docker: `docker build -f A -f B .` builds only from `B`. So a caller-supplied `-f`/`--file` would silently replace rc's audited Dockerfile with the caller's file for the *actual* build, while the isolation gate would still only ever have inspected rc's own resolved path — a safety-floor validator bypass, not a UX surprise (rip-cage-zqjz).

Unlike `-t`, there is no legitimate `rc build -f` use and no override-then-audit fix: resolving the Dockerfile from the manifest **is** rc's job, and there is no "effective Dockerfile" concept to swap to. So every spelling of `-f`/`--file` is **rejected outright**, fail-loud, before any docker call:

| Spelling | Example |
|----------|---------|
| Separate-arg, short | `-f path/to/Dockerfile` |
| Separate-arg, long | `--file path/to/Dockerfile` |
| Equals-attached, long | `--file=path/to/Dockerfile` |
| Equals-attached, short | `-f=path/to/Dockerfile` |
| Value-attached, short (no equals) | `-fpath/to/Dockerfile` |
| Clustered behind docker's other boolean short flags (`-D`/`-q`) | `-qf path/to/Dockerfile`, `-Dqf=path/to/Dockerfile` |

Cluster parsing follows the same left-to-right rule as `-t`'s: whichever value-taking short flag (`f`/`o`/`t`) appears first in a token wins. `-ft` is `-f` with value `"t"` (rejected); `-tf` is `-t` with value `"f"` (still a legal tag override, not a file flag) — the two are distinguished, not conflated.

### `rc build -o`/`--output` is rejected

`docker build`'s BuildKit backend supports `-o`/`--output`, which controls where the build **result** lands — a filesystem directory, a registry, or (the default) the local docker image store. `docker build -t X -o type=local,dest=DIR .` exits **0** and exports the build result to `DIR` **without loading `X` into the docker image store**.

That is a false-green risk specific to this flag, distinct from `-f`'s clobber and `-t`'s co-tag bug: if a prior `X` already existed in the image store (from an earlier real build), `rc build`'s post-build root-owned validators (`_manifest_check_binary_root_owned` / `_manifest_check_mount_root_owned`, ADR-005 D9/D11, ADR-024, ADR-027 D1) silently pass against the **stale** `X`, while `rc build` reports `status: "built"` — the operator has no signal that anything is wrong (rip-cage-zqjz.2).

There is no legitimate `rc build -o` use — rc's contract is "produce a tagged image in the local image store this host can run" — so every spelling of `-o`/`--output` is **rejected outright**, fail-loud, before any docker call, using the identical spelling/clustering rules as `-f`/`--file` above (separate-arg, `--output=`, `-o=`, `-ovalue`, and boolean-prefixed clusters). Directionally: `-ot` is `-o` with value `"t"` (rejected); `-to` is `-t` with value `"o"` (still a legal tag override, not an output flag).

### `rc build` flag allowlist

rip-cage-fo4z (`-t`, additive co-tag), rip-cage-zqjz (`-f`, last-wins Dockerfile swap), and rip-cage-zqjz.2 (`-o`, BuildKit output-redirection false-green) found **three distinct validator-defeat mechanisms** in the same six lines of `cmd_build`'s docker invocation, in three consecutive passes. An open pass-through with a growing per-flag reject list is unwinnable by construction — docker's flag surface evolves outside rc's control, and each new flag is a fresh chance at a fresh mechanism.

So `rc build`'s docker-flag surface is a **fail-closed allowlist**, not a pass-through: every caller-supplied token is classified BEFORE any docker call. `-t`/`--tag` is intercepted (see above); `-f`/`--file` and `-o`/`--output` are rejected (see above); a small set of flags verified benign against docker 29.4.0's real flag surface is admitted; **everything else — including a bare `--`, which previously bypassed this scanning entirely — fails loud**, naming this section and the escape hatch below.

**Admitted** (pass through to `docker build` unmodified):

| Flag | Rationale |
|------|-----------|
| `--no-cache`, `--pull` | Booleans; affect cache/base-image freshness only, touch nothing the floor reads. |
| `--progress=<mode>` | Output formatting only — a small enumerated set of literal display modes (`auto`, `none`, `plain`, `quiet`, `rawjson`, `tty`); an unrecognized value errors cleanly, no path/frontend/redirect content accepted. |
| `-q`/`--quiet`, `-D`/`--debug` | Booleans; only affect docker's own log verbosity. Safe specifically because neither `docker build` call site parses docker's own stdout (the JSON branch redirects it to `/dev/null`; the plain branch lets it go straight to the terminal). |

Each admitted flag above was re-verified (rip-cage-zqjz.2 round 2) against both its **name** *and* its **value namespace** — `docker build --help` only shows names, and `--build-arg` (below) was previously admitted on a name-level reading that its value namespace falsified.

**Rejected by name** (each would violate the admission test — touching image identity, the Dockerfile source, the build context, the output destination/image-store load, or image metadata the floor reads):

| Flag | Why rejected |
|------|--------------|
| `-f`/`--file` | Dockerfile source (see above). |
| `-o`/`--output` | Output destination / image-store load (see above). |
| `--build-arg` (any spelling, including the bare `--build-arg KEY` inherit-from-environment form) | **Rejected wholesale** — re-judged rip-cage-zqjz.2 round 2 (adversarial review). Originally admitted (rip-cage-fo4z) on the reasoning that it "only ever feeds `_image_is_current`'s staleness heuristic," narrowed in round 1 to reject only the `RC_VERSION` key. Both were name-level readings; the flag's *value* namespace defeats them: `--build-arg BUILDKIT_SYNTAX=<image>` replaces the Dockerfile **frontend** BuildKit uses to interpret the Dockerfile at all (verified live, docker 29.4.0 — an arbitrary caller-named image then interprets the Dockerfile; `cage/Dockerfile` has no `# syntax=` pin to contest it), making `_manifest_check_build_isolation`'s static text analysis of rc's own resolved Dockerfile vacuous. Independently, `cage/Dockerfile` interpolates several ARGs (`DOLT_VERSION`, `MISE_VERSION`, `BUN_VERSION`, ...) into `RUN` shell strings, so an admitted caller `--build-arg` is build-time command injection into the image tagged `rip-cage:latest`. No in-repo caller and no manifest build-arg mechanism exists to preserve. rc's own `--build-arg RC_VERSION=...` is set internally by both `docker build` call sites, not routed through this allowlist scan — unaffected. |
| `--target` | Selects a build stage — can skip stages that install the safety floor (verified against `cage/Dockerfile`: `--target go-builder` would build only the Go compiler stage, never reaching the runtime stage that sets up the safety-stack assets the validators check). |
| `--label` | Forges image metadata the floor reads: `cli/lib/config.sh`'s `rc.multiplexers` label is the SOLE authoritative source for the multiplexer registry. |
| `--secret`, `--ssh` | Build-time credential injection (ADR-005 D9 / ADR-024). |
| `--push`, `--load` | Registry/image-store side effects (redundant with `rc build`'s own default store-load; part of the same `-o`/output family this bead closes). |
| `--platform` | Could produce an image this host cannot run while the validators still inspect it; no legitimate `rc build`-path need found (the multi-arch release build uses `docker/build-push-action` directly, not `rc build`). |
| `--build-context`, `--builder`, `--cache-from` | Build context / build-execution-environment surface: an alternate context directory, a redirected (possibly remote/untrusted) builder instance, or cache-import content that could substitute layer content without re-running the Dockerfile's own steps. |
| `--add-host`, `--allow`, `--network`, `--cgroup-parent` | Build-isolation surface: `--allow` explicitly grants privileged entitlements (`network.host`, `security.insecure`, `device`); `--network=host` and custom `--add-host` mappings similarly extend a builder stage's reach beyond the isolated build container (ADR-005 D9 / ADR-024). |
| `--call`, `--check` | Changes the fundamental build action from "build" to "check"/"outline"/"targets" — the same false-green shape as `-o`: may exit 0 without ever producing a built-and-loaded image. |
| `--cache-to`, `--iidfile`, `--metadata-file`, `--annotation`, `--attest`, `--provenance`, `--sbom`, `--policy` | Output/metadata-adjacent surfaces with no compelling `rc build`-path need; default reject. |
| `--no-cache-filter`, `--shm-size`, `--ulimit` | No compelling need; default reject (fail-closed). |
| A bare `--` | Previously (a51b5da/fb79d10) dumped every subsequent token into the docker invocation **unfiltered**, bypassing this entire allowlist — closed by removing that special case; `--` now falls into the same fail-closed default as any other unrecognized token. |
| A build-context positional | `rc build` supplies the build context itself (the final argument to both `docker build` call sites) — a caller-supplied one fails loud in `rc`, rather than reaching docker as an unexpected second positional. |
| Anything else not named above | **Unknown → rejected.** An unrecognized/future docker flag fails closed instead of silently reaching docker — this closes rip-cage-fo4z's own forward-compat caveat. |

**Escape hatch:** if you need a docker flag `rc build` doesn't admit, run `rc generate-dockerfile > Dockerfile.composed` and invoke `docker build` yourself — explicitly outside `rc`'s safety floor.

### `rc up` — denylist and `--allow-risky-mount`

`rc up` runs a secret-path denylist check on every non-workspace mount surface (e.g. `--env-file`) before starting the container. If the path matches a default pattern (`.aws`, `.ssh`, `credentials`, etc.), `rc up` aborts with a fail-loud error naming the matched path, the matched pattern, and the available escape hatches.

| Flag | Description |
|------|-------------|
| `--allow-risky-mount <resolved-path>` | One-shot bypass: allow the named path to pass the denylist check for this invocation only. Accepts the **resolved (realpath)** form of the path — copy it from the error message. May be repeated for multiple paths. |

Example:
```bash
# Allow a specific credential path for this invocation only
rc up --allow-risky-mount /Users/alice/.aws/my-tools-creds \
      --env-file /Users/alice/.aws/my-tools-creds \
      /path/to/project
```

For a persistent per-project allow, use `mounts.allow_risky` in `.rip-cage.yaml`. To add custom patterns on top of the global defaults, use `mounts.denylist` in `.rip-cage.yaml`. Run `rc config show` to see the effective denylist with provenance.

See [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md) and [`docs/reference/config.md`](config.md#mountsdenylist-and-mountsallow_risky----secret-path-denylist) for the full denylist design.

`rc up` also boot-time-masks any paths declared in `mounts.mask` — a nested `:ro` overmount presents a legible breadcrumb over each declared workspace-relative path, so the real content is unreadable in-cage while the rest of the workspace stays read-write. A declared path that doesn't exist on the host aborts `rc up` loud (never a silent no-op). See [`docs/reference/config.md`](config.md#mountsmask--workspace-mask-primitive-tier-1-project-secret-posture) and [ADR-030](../decisions/ADR-030-classify-by-use-secret-posture.md).

### `rc allowlist` — egress allowlist

Manage the msb egress allowlist (`network.allowed_hosts` in `.rip-cage.yaml`). Cages boot **default-deny**; there is no observe mode post-cutover ([ADR-029](../decisions/ADR-029-msb-migration.md) D4) — see [egress.md](egress.md) for the deny→fix→reload repair loop that replaced it.

`add` is **host-only** (it mutates effective config, and via `--cage`, runs `rc reload`); `show` is read-only and works inside the cage too.

| Subcommand | Description |
|------|-------------|
| `add <host> [--cage=<name>]` | Append `<host>` to `network.allowed_hosts` (idempotent). With `--cage`, runs `rc reload` to apply (cold-recreate). Supports `--output json`. |
| `show [--effective]` | Default: configured `network.allowed_hosts`. `--effective`: merged allowlist with provenance. |
| `show --observed` / `promote --from-observed` | **Legacy, non-functional under msb** — read JSONL log files the deleted in-cage engine used to write; nothing writes them anymore, so these always report/apply nothing. Use `rc doctor`/`rc reload --dry-run`'s trace-log fix-hint instead. See [egress.md](egress.md#rc-allowlist-command-reference). |

```bash
# Add one host and apply it (cold-recreate)
rc allowlist add api.deepseek.com --cage my-cage

# Inspect configured vs. effective allowlist
rc allowlist show
rc allowlist show --effective
```

See [`docs/reference/egress.md`](egress.md) and [ADR-029](../decisions/ADR-029-msb-migration.md) D2/D4 for the full egress model.

## JSON output

When `--output json` is set, structured output goes to stdout. Human-readable messages (progress, warnings) go to stderr. Error responses include `"error"` and `"code"` fields.

## Container resolution

Commands that target a container (`attach`, `down`, `destroy`, `reload`, `test`) resolve the name in order:

1. **Explicit name** — if you pass a name, it's used directly
2. **CWD match** — derives the expected name from your current directory (same logic as `rc up`) and checks if that container exists
3. **Singleton fallback** — if only one rip-cage container exists, it's auto-selected

This means `rc down` from a project directory targets that project's container, just like `rc up` does.

## Container naming

Container names are derived from the last two path components of the project directory. When collisions occur, a 4-character hash suffix is appended. Use `rc ls --output json` to discover exact container names — do not construct them manually.

## `rc attach` — multiplexer-neutral attach

`rc attach [name]` attaches to a running container. Its behavior depends on the `session.multiplexer` config field ([details](config.md#sessionmultiplexer--in-cage-multiplexer)):

| `session.multiplexer` | `rc attach` behavior |
|---|---|
| `none` (default) | Drops into a plain interactive shell; closing the window ends the process |
| `tmux` | Attaches the tmux session (with a session picker when multiple sessions exist) |
| `herdr` | Opens the herdr supervisor view |

## `rc exec` — one-off commands

```
rc exec <cage> -- <cmd...>
rc --output json exec <cage> -- <cmd...>
```

Runs a single command inside a running cage non-interactively. The `--` separator is required. Safe for CI pipelines, scripts, and host-side automation — does not open a TTY or attach a session.

```bash
# Run a test suite inside the cage
rc exec my-cage -- pytest tests/

# Get structured output from a command
rc --output json exec my-cage -- cat /workspace/VERSION
```

`rc exec` is **container resolution**-aware (auto-selects the cage if only one is running).

## Running multiple agents

When `session.multiplexer` is set to `tmux`, a cage supports multiple independent tmux sessions. `rc up <path>` shows a numbered picker when one or more sessions already exist, letting you attach an existing session or spawn a new one. The first `rc up` on a fresh cage creates a session named `rip-cage` and attaches it directly (no picker — current behavior preserved).

With the default `session.multiplexer: none`, each `rc up` connects a single shell process — multiple agents means multiple cages (one per workspace path).

### Session picker (tmux multiplexer only)

When `rc up <path>` finds one or more existing sessions, it renders a numbered list sorted by most-recently-attached first, with a `[new] new session` entry at the bottom. Pressing **Enter** (empty input) attaches the most-recently-attached session. Type a number to select. `rc attach <cage>` uses the same picker.

On a cage with no sessions, `rc up` creates and attaches `rip-cage` with no picker.

### `rc up` session flags

| Flag | Behavior |
|------|----------|
| `--new` | Skip picker; always create a new auto-named session (`rip-cage-2`, `rip-cage-3`, …). |
| `--session NAME` | Attach session `NAME` if it exists; create and attach it if not. |
| `--dry-run` | Previews the container action; never shows the picker. |

`--new` and `--session` are mutually exclusive (exits 2 if both are given).

Non-TTY invocations (CI, piped stdin) skip the picker entirely and fall back to attaching `rip-cage` if it exists or creating it.

### Other shapes still supported

**Multiple windows in one cage (tmux multiplexer, one session, multiple windows).** From inside an attached cage with `session.multiplexer: tmux`, press `Ctrl-b c` to create a new tmux window, then run `claude` (or `pi`, etc.) in it. `Ctrl-b n` / `Ctrl-b p` switch between windows; `Ctrl-b 0..9` jumps directly. The windows share the same workspace bind mount, credentials, and tmux session — useful when you want a second agent slot without a separate terminal on the host.

**Multiple cages (one per workspace).** `rc up <other-path>` from a second host terminal starts an independent cage on a different project path. Each cage has its own container and state. This is the right shape when you want full container isolation between agents — e.g. one cage per git worktree (see [Quick start → The worktree workflow](../../README.md#the-worktree-workflow)).
