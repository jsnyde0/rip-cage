# ADR-023: Secret-path denylist on host-side mount validation

**Status:** Proposed
**Date:** 2026-05-22 (revised 2026-05-29 — D5/D6 two-tier failure mode)
**Builds on:** [ADR-003](ADR-003-agent-friendly-cli.md) (D3 allowed-roots path validation — composition layer), [ADR-021](ADR-021-layered-rip-cage-config.md) (D1+D2 config substrate this ADR consumes), [ADR-022](ADR-022-ssh-allowlist.md) (D4+D5 two-layer precedent — explicitly contrasted in D3 below)
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (fail-loud + actionable error), [ADR-010](ADR-010-auth-refresh.md) (OAuth credential mount — scope OUT), [ADR-014](ADR-014-push-less-cage.md) (D2 non-interactive fail-loud posture — failure mode discipline), [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (SSH-agent forwarding — scope OUT), [ADR-020](ADR-020-ssh-identity-routing.md) (SSH identity routing, known_hosts mount — scope OUT), project [CLAUDE.md](../../CLAUDE.md) philosophy section ("layers, not walls", "80/20, not 100/0")

## Context

Rip-cage's host-side path validation (`validate_path` in `rc`) checks arbitrary path arguments against `RC_ALLOWED_ROOTS` per ADR-003 D3 — rejecting paths with control characters, null bytes, or those resolving outside allowed roots. This stops workspace-escape accidents. It does not stop a user (or agent) from pointing a mount surface at a secret-heavy path that happens to sit inside an allowed root.

The concrete gap: `rc up --env-file ~/.aws/credentials` passes `validate_path` today if `~/` is an allowed root. The credentials file is bind-mounted into the cage in plain text, visible to every tool the agent runs.

A second surface is the beads redirect file: if an agent writes a `.beads/redirect` file pointing at an arbitrary host path, `rc up` reads that path and may bind-mount or reference content from it. The denylist should cover this surface for the same reason.

NanoClaw's mount-security module (`src/modules/mount-security/index.ts:39-57, 137-143`) applies a 17-pattern denylist after `realpath` resolution. This ADR adapts that pattern to rip-cage's threat model and config substrate. Per CLAUDE.md's "layers, not walls" philosophy, the denylist is blast-radius reduction, not a security boundary against a motivated attacker.

## Decisions

### D1: Default-on secret-path denylist applies to non-workspace bind-mount surfaces

**Firmness: FIRM**

A pattern-based denylist runs on the host at `rc up` time, before the container exists. It applies to every non-workspace mount surface that accepts an arbitrary host path argument — specifically: the `--env-file` source path, the `.beads/redirect` target file path, and any future user-supplied bind-mount surface that accepts an arbitrary host path.

Default-on: the policy is active out of the box. Users opt *out* to allow specific paths — they do not opt in to enable the feature.

Validation runs after `validate_path` (ADR-003 D3's allowed-roots check) completes successfully. Both checks must pass.

**Rationale:** An opt-in security feature is one that nobody opts in to. The denylist's value is proportional to coverage: default-on means every project benefits without authoring.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Opt-in mode — user enables the denylist per project via `.rip-cage.yaml` | `reasoned:` An opt-in security feature is one that nobody opts in to; defeats the value. Projects that benefit most (those with secrets paths in scope) are precisely the ones most likely to be run by users who haven't thought about the denylist at all. |

**What would invalidate this:** Routine dev workflows hitting >N false positives per session across multiple users, OR a class of legitimate mount that cannot be pattern-distinguished from a secret path. At that point, flip to opt-in with a default-off hint at `rc up`.

### D2: Patterns live in `.rip-cage.yaml` config substrate per ADR-021, not hardcoded in `rc`

**Firmness: FIRM**

The denylist field is `mounts.denylist`, typed as `additive_list` per ADR-021 D2 merge rules. Default patterns are populated in the global `~/.config/rip-cage/config.yaml`. Project `.rip-cage.yaml` may *add* patterns on top of the defaults; it may not remove default patterns (additive semantics — project expands, never contracts).

Schema example:

```yaml
# ~/.config/rip-cage/config.yaml — global
version: 1
mounts:
  denylist:
    - .ssh
    - .aws
    - credentials
    # ... full list per D4 defaults
```

```yaml
# <project>/.rip-cage.yaml — project-specific additions
version: 1
mounts:
  denylist:
    - .env           # project adds .env on top of global defaults
    - secrets/
```

Per ADR-021 D2: effective `mounts.denylist` = global list ∪ project list, deduplicated, order-preserving (global first, then project additions).

**Rationale:** The config substrate (ADR-021 D2) already defines the `additive_list` merge type for exactly this use case — a global floor of policy that projects can extend. Hardcoding the patterns in `rc` would fragment substrate that future agents, contributors, and `rc config show` all have to reconcile from two places.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Hardcoded constant array in `rc` script | `external:` ADR-021 D2 merge schema already exists and is the canonical place for per-field-type config; `reasoned:` hardcoding fragments substrate that downstream agents (e.g. anything querying `rc config show`) have to reconcile separately from the live effective config. |
| Project-only (no global file) | `reasoned:` Loses the "global floor across all my projects" property that makes defaults effective. Every new project would need a `.rip-cage.yaml` to gain any protection. |

**What would invalidate this:** The config substrate (ADR-021) is deprecated or restructured with a breaking schema change. At that point, migrate `mounts.denylist` to the new substrate shape.

### D3: Single-layer enforcement — host-side at `rc up` only; no PreToolUse hook

**Firmness: FIRM**

The secret-path denylist requires only host-side enforcement. No in-cage PreToolUse hook is added.

This is a deliberate contrast with ADR-022's two-layer model (D4 mount layer + D5 hook layer). ADR-022 needs both layers because OpenSSH's CLI `-o` override escapes the mount-layer filter at runtime — the agent can bypass the filtered `known_hosts` via a flag passed at invocation time. The mount surfaces this ADR covers — `--env-file` value, `.beads/redirect` target — are resolved once on the host at `rc up` and do not have a runtime bypass path available to the agent inside.

The in-scope surfaces (`--env-file` flag value, `.beads/redirect` target file contents, future user-supplied bind-mount surfaces) are processed on the host before the container starts. The agent inside has no runtime path to alter them.

The agent inside the cage can write `mounts.allow_risky` entries to the workspace's `.rip-cage.yaml` before the next `rc up`. This is the same trust model accepted in ADR-022 D6: the human running `rc up` is the approval step. An agent that wants to bypass the denylist must persuade the human to re-run `rc up`. This ADR does not add a hook layer for this surface — the human-in-the-loop gate that already exists for `rc up` is sufficient under the cage's blast-radius-reduction model. If we later move to auto-reload or daemon-mode mount lifecycle, this constraint must be revisited (see "What would invalidate this" below).

**Rationale:** A PreToolUse hook here would be dead code — there is no in-cage agent action that re-evaluates or re-mounts these paths at runtime. Adding a hook would add detection-rule maintenance surface, registration complexity in `settings.json`, and an actionable-but-misleading deny message for a bypass path that doesn't exist.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Two-layer enforcement mirroring ADR-022 (mount layer + PreToolUse hook) | `reasoned:` No agent-runtime bypass surface exists for this class of decision. The mount surfaces this ADR covers are fully resolved host-side before container start; a hook watching for in-cage re-mount would be dead code with no detection surface. ADR-022's hook layer is warranted by the specific OpenSSH CLI override path (`-o UserKnownHostsFile=...`) — a bypass that doesn't exist here. |

**What would invalidate this:** Introducing a runtime mount surface the agent can influence — for example, a future `rc remount` command, a dynamic bind-mount via container API, or a new `--env-file`-like flag that accepts paths from inside the cage at runtime. At that point, add a hook layer covering the new surface. OR `rc up` gains auto-reload / daemon-mode mount lifecycle that removes the human-in-the-loop step for mount-config changes.

### D4: Default pattern list

**Firmness: FLEXIBLE**

The starting default denylist in `~/.config/rip-cage/config.yaml`:

```
.ssh, .gnupg, .gpg, .aws, .azure, .gcloud, .kube, .docker,
credentials, .netrc, .npmrc, .pypirc, id_rsa, id_ed25519, private_key, .secret
```

16 patterns. Derived from NanoClaw's 17-pattern list (`src/modules/mount-security/index.ts:39-57`) with one deliberate exclusion:

- **`.env` excluded from defaults.** `.env` files are ubiquitous in normal dev workflows — mounting a project's own `.env` as an env-file source is a standard pattern. Including `.env` in the global default would produce routine false positives in the majority of legitimate uses. Users who want to block `.env` files can add the pattern project-by-project via `.rip-cage.yaml`.
- **`.claude` not in list.** Intentional: `~/.claude/.credentials.json` is a defined OAuth credential mount (ADR-010 D1, scope OUT per D5 below). Adding `.claude` to the denylist would break the cage's primary auth flow.

FLEXIBLE because empirical — the exact list will be tuned as usage data arrives.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Include `.env` in defaults | `reasoned:` Too common in legitimate dev workflows; would produce routine false positives (projects mounting their own `.env` as env-file source) that make the default-on policy (D1) actively hostile to normal use. Tunable per-project is the right scope for `.env`. |
| Start with a minimal list (e.g., only SSH keys) and expand | `reasoned:` Under-protective; users who don't manage the list get weaker defaults from day one. The NanoClaw precedent demonstrates these 17 patterns are the well-understood starting point for this class of tool. Starting from a well-established base is lower-risk than discovering gaps via incidents. |

**What would invalidate this:** A specific pattern in the defaults causes routine false positives in real workflows (signal: users adding the same exception in many `.rip-cage.yaml` files, or filing issues naming the same pattern repeatedly). Remove or reclassify that pattern from the global defaults. Also: if component-equals matching misses a real secret-path convention (e.g., a tool that stores credentials in a file whose component name varies), revisit toward suffix-match or filename-glob shapes.

### D5: Scope — what the denylist applies to, and what is explicitly out

**Firmness: FIRM**

**IN scope (denylist applies):**
- `--env-file <path>` source path passed to `rc up`
- `.beads/redirect` resolved target directory — when `rc up` reads `.beads/redirect` and resolves it to a target directory for bind-mounting, the resolved target directory is checked against the denylist. A redirect pointing to `~/.aws/some-bd-mirror/` would have `.aws` as a path component and fail loud.
- Skill and agent symlink-target parent directories collected by `_collect_symlink_parents` — when a host symlink under `~/.claude/skills/` or `~/.claude/agents/` resolves to a target whose parent matches the denylist, that parent is skipped from mounting via **warn-and-skip per D6's incidental tier** (stderr warning naming the matched parent + pattern; `rc up` continues). This is an *incidental decoration surface* — the user did not explicitly request the mount; the secret is blocked either way.
- Symlink-follow targets under `~/.pi/agent` — the symlink-follow scanner (`_collect_dangling_symlinks`, rip-cage-c1p.2) resolves dangling absolute symlinks and adds second bind mounts so they resolve inside the cage. When a resolved target matches the denylist, it is skipped via **warn-and-skip per D6's incidental tier** — same treatment as the skill/agent symlink-parents, and for the same reason (incidental surface, not an explicit mount request).
- Any future user-supplied bind-mount surface that accepts an arbitrary host path argument (tier — fail-loud vs warn-and-skip — per D6, by whether the surface encodes explicit mount-intent)

**OUT of scope (denylist does NOT apply):**
- Workspace mount (`-v ${_path}:/workspace`) — not an arbitrary user path; it is the validated workspace root, already checked by ADR-003 D3's allowed-roots gate
- `~/.claude/.credentials.json` — intentional OAuth credential mount, design-defined and narrow, not a user-controlled arbitrary path (ADR-010 D1)
- SSH agent socket (`/run/host-services/ssh-auth.sock` or `$SSH_AUTH_SOCK`) — not a file path the user supplies; it is a fixed protocol socket (ADR-017 D1)
- SSH config, filtered known_hosts, and public keys mounted by ADR-020 D1 — paths are tightly-defined by ADR-020's config-translation logic, not arbitrary user arguments; ADR-022 covers the known_hosts surface with its own enforcement model

**Rationale:** The OUT surfaces don't accept arbitrary user-controlled path arguments — they are tightly-defined, intentional flows whose source paths are determined by other ADRs' validated logic. Applying the denylist to them would break the cage's own auth and SSH flows (e.g., `~/.claude/` pattern matching against the credentials mount). The denylist targets *user-controlled path inputs*, not all bind-mount surfaces.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Apply denylist to all bind-mount surfaces including workspace | `direct:` Workspace path is the primary project directory; it commonly lives under `~` (a denylist-adjacent root). Matching workspace paths against secret patterns would fire on any project with a matching directory component (e.g. `~/projects/aws-infra` matching `.aws`). ADR-003 D3's allowed-roots gate is the right layer for workspace validation. |
| Apply denylist to the SSH agent socket path | `direct:` Socket paths aren't files — applying a filename-pattern denylist to a socket path doesn't provide a meaningful security property and would misfire on socket paths that happen to contain pattern strings. |
| Leave skill/agent symlink-target parents OUT of denylist (current behavior validates only `$HOME` prefix) | `reasoned:` `_collect_symlink_parents` accepts arbitrary user-resolved targets under `$HOME`; without denylist coverage, a skill symlink to `~/.aws/some-tool/` mounts the `.aws` parent into the cage. Closing this surface is the same threat-class as `--env-file` and consistent with the realpath-first model in D7. |

**What would invalidate this:** Any of the OUT surfaces gains a user-controllable path argument at invocation time (e.g., a future `--ssh-config <path>` flag, a user-controllable `rc.credentials-path` override). At that point, add that new surface to IN scope. Also: if the set of user-controlled path inputs that feeds `_collect_symlink_parents` changes (e.g., additional host directories beyond `~/.claude/skills/` and `~/.claude/agents/` are scanned for symlinks), review whether symlink-target parent coverage extends to those new sources.

### D6: Failure mode — two-tier by surface intent (revised 2026-05-29)

**Firmness: FIRM**

On a denylist match, the response depends on whether the matched mount surface (D5 IN scope) encodes *explicit user mount-intent* or is an *incidental/decoration surface*. Both tiers share the realpath-first match (D7), the same effective denylist (D1/D2), and the same escape hatches (`--allow-risky-mount`, `mounts.allow_risky`) — an allow-risky entry suppresses the response on either tier. The only difference is whether a match aborts the whole `rc up` or just drops the one mount.

**Explicit mount-intent surfaces** (`--env-file` source, `.beads/redirect` target) → **fail loud.** `rc up` exits non-zero immediately. The user explicitly asked to mount this path; a denied match means their explicit request is unsafe, and the right response is to stop and tell them. The error message (to stderr) names: (1) the matched path after realpath resolution, (2) the matched pattern, (3) the escape-hatch options.

```
Error: --env-file path matches secret-path denylist pattern '.aws':
  Matched: /Users/alice/.aws/credentials  (pattern: .aws)

To allow this path for this invocation:
  rc up --allow-risky-mount /Users/alice/.aws/credentials ...

To allow this path persistently for this project:
  Add to .rip-cage.yaml:
    mounts:
      allow_risky:
        - /Users/alice/.aws/credentials

To add patterns to the denylist or review the active list:
  rc config show
```

Aligns with ADR-014 D2's non-interactive fail-loud posture: exit non-zero, actionable message, no prompt.

**Incidental / decoration surfaces** (skill + agent symlink-target parents, and the symlink-follow surface under `~/.pi/agent` — all D5 IN scope) → **warn-and-skip.** Emit a stderr warning naming the matched path and pattern, skip mounting *that one target*, and continue `rc up`. The cage launches; the denied target is simply absent. Message shape:

```
Warning: skipping <surface> mount <resolved-target> — matched secret-path denylist pattern '<pattern>'
```

Warn-and-skip is **not** the rejected "warn-only" alternative below: warn-only mounts the secret anyway, whereas warn-and-skip does **not** mount it. The blast-radius reduction (secret never enters the cage) is identical to fail-loud; the difference is only that the cage still launches. And it remains loud (stderr warning), consistent with ADR-001's no-silent-failure principle.

**Rationale (why the incidental tier does not fail loud):** On an incidental surface the secret is not mounted under *either* policy — that is the entire security win, and warn-and-skip already delivers it. Fail-loud's only additional effect would be refusing to launch the whole cage because one optional/incidental symlink happened to point at a denied path: zero extra blast-radius reduction, pure launch friction, against the CLAUDE.md autonomy posture ("autonomy is the product"; aborting a legitimate launch is the flagged anti-pattern). Explicit-intent surfaces differ because the user *asked* for that exact mount — failing loud answers their explicit request, rather than vetoing an incidental side-mount they never requested.

**Escape hatches (both tiers):**
- **`--allow-risky-mount PATH`** flag: one-shot, per-invocation bypass for the named path
- **`mounts.allow_risky`** field in `.rip-cage.yaml` / `~/.config/rip-cage/config.yaml`: `selection_list` per ADR-021 D2 — project may list specific allowed paths persistently; project-level `allow_risky` is explicit opt-in for that project

**Path-form contract:** `--allow-risky-mount` and `mounts.allow_risky` entries are matched against the **resolved (realpath) form** of the input path, not the as-typed form. This is consistent with D7's realpath-first validation model. The messages (above) show the resolved form so the user can copy-paste it directly into the flag or YAML. Users typing the symlink form into `mounts.allow_risky` will see the denylist re-fire on the next `rc up` with the resolved path in the message — the system tells them what to write.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Uniform fail-loud — incidental surfaces also exit non-zero | `reasoned:` On an incidental surface the secret is not mounted either way (warn-and-skip already blocks it), so exit-non-zero buys zero added blast-radius reduction — it only refuses to launch the whole cage over an optional/incidental side-mount the user never requested. Pure friction against the CLAUDE.md autonomy posture. (This also never matched shipped behavior: the skill/agent symlink-parent loops always warn-and-skipped; the prior uniform-fail-loud wording was a contradiction this revision resolves.) |
| Silent skip (don't mount the path, no message) | `direct:` CLAUDE.md philosophy "fail loud on risky configuration" (`CLAUDE.md:7-16`); silent skip hides that a mount was dropped, producing a harder-to-diagnose downstream failure. Rejected on *both* tiers — warn-and-skip is loud. |
| Warn-only (print warning but continue mounting) | `reasoned:` Distinct from warn-and-skip: warn-only mounts the secret anyway, so the denylist provides zero blast-radius reduction. The only value of a denylist is stopping the mount. Rejected on both tiers. |
| No escape hatch (hard block, no bypass path) | `reasoned:` Per CLAUDE.md "'It's annoying' is a design signal" — a legitimate use case with no self-recovery path forces human intervention for every exception, breaking agent autonomy. The escape hatch keeps the default protective while preserving the cage's core value proposition. |

**What would invalidate this:** (a) An incidental surface is promoted to an explicit opt-in (e.g. the symlink-follow surface gains a flag by which the user explicitly requests the mount) — move it to the fail-loud tier, mirroring the explicit-intent rationale. (b) `rc config init` (rip-cage-97n) gains the ability to auto-detect and pre-populate `mounts.allow_risky` for known-legitimate paths, reducing escape-hatch friction enough that the message format needs updating — update the message, not the policy.

### D7: Validation runs after realpath resolution

**Firmness: FIRM**

Pattern matching runs against the resolved target path (after `realpath` / symlink resolution), not the path as written by the user. This is consistent with ADR-003 D3's realpath-first model for allowed-roots validation.

The sequence:
1. Receive path argument
2. Run `realpath` to resolve symlinks to the final target
3. Match the resolved path against denylist patterns (component-equals match — see implementation notes for exact semantics)
4. If matched, fail loud per D6

Symlink-escape is a well-documented bypass class: a user could construct `~/.myapp/config -> ~/.aws/credentials` and pass `~/.myapp/config` — pattern matching on the link path alone would miss it. Resolving first closes this class. NanoClaw resolves first for the same reason (`src/modules/mount-security/index.ts:137-143`).

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Validate the link path only (not the resolved target) | `external:` NanoClaw `src/modules/mount-security/index.ts:137-143` resolves first; symlink-escape is a known documented bypass class. Validating only the link path makes the denylist trivially bypassable via a single symlink layer. |
| Validate both link path and resolved target | `reasoned:` More work, same outcome. If either matches, we deny; resolving first and checking once covers the threat without adding a second code path. |

**What would invalidate this:** a use case where resolving symlinks before validation produces false positives (e.g., a symlink to a normally-secret path that the user legitimately wants to pass through after `--allow-risky-mount`). The `--allow-risky-mount` escape hatch in D6 accepts the *resolved* path to prevent bypass, so this case is already handled — user names the resolved path, not the link.

## Consequences

**Positive:**
- Accidental secret-path mounts (the most common class: `--env-file ~/.aws/credentials`, `--env-file ~/.npmrc`) are caught before the container starts, with an actionable error.
- Default-on means every project benefits without config authoring.
- Denylist lives in the ADR-021 config substrate, so `rc config show` surfaces the active list, provenance, and project additions in one command.
- Blast-radius reduction for the `--env-file` and beads-redirect surfaces — the two user-controlled path inputs in scope — without restricting the cage's existing intentional mount flows.
- Composable with ADR-003 D3: allowed-roots check runs first (coarse-grained), denylist check runs second (pattern-grained). Clear layering, no entanglement.

**Negative:**
- New default-on policy will fail-loud for users who currently pass secret-path env-files to `rc up`. They need to add `--allow-risky-mount` or `mounts.allow_risky` to continue.
- Pattern maintenance: as new secret-path conventions emerge (new cloud tools, new dotfile locations), the default list needs updating. Tracked as detection-rule maintenance.
- `additive_list` merge semantics mean project files can't remove a global default pattern. Users who need to remove a global pattern must update the global `~/.config/rip-cage/config.yaml` directly. (This is intentional — see D2.)

**Neutral:**
- Validation cost: one `realpath` + string pattern match per validated path at `rc up` time. Negligible vs `docker run`.
- The `mounts.allow_risky` escape hatch adds one new field to the ADR-021 schema (selection_list type). Schema version stays at 1; the field is additive.

## Implementation notes

- **`validate_path` extension** (`rc`): after the existing allowed-roots check (ADR-003 D3), call `_check_secret_path_denylist <resolved_path>`. Load effective `mounts.denylist` via the ADR-021 loader (`_load_effective_config`). Pattern matching is **component-equals**, not substring. For each pattern in the effective denylist, split the resolved path on `/`, and check whether any component is exactly equal to the pattern OR (for bareword filename patterns) whether the basename (last component) is exactly equal to the pattern.

  Concretely:
  - Dotfile-directory patterns (`.ssh`, `.aws`, `.gnupg`, `.gpg`, `.azure`, `.gcloud`, `.kube`, `.docker`, `.netrc`, `.npmrc`, `.pypirc`, `.secret`) match if any path component is exactly equal to the pattern. `~/.aws/credentials` has component `.aws` → match. `~/code/my-aws-tool/` has no `.aws` component → no match.
  - Bareword filename patterns (`credentials`, `id_rsa`, `id_ed25519`, `private_key`) match if any path component is exactly equal to the pattern. `~/.aws/credentials` has component `credentials` → match. `~/code/my-credentials-manager/app.env` has no component exactly `credentials` → no match.

  This is stricter than NanoClaw's substring match (`src/modules/mount-security/index.ts:148-166`); rip-cage's tighter rule was chosen to eliminate the false-positive class identified during ADR review (e.g., `~/code/my-credentials-manager/` should not match `credentials`). First match → fail loud per D6.
- **`mounts.allow_risky` check**: before the denylist match, check if the resolved path appears in the effective `mounts.allow_risky` selection_list; if so, skip the denylist check for this path and continue.
- **`.beads/redirect` resolution**: after `_path_under_allowed_roots` and `realpath`, the resolved target directory passes through `_check_secret_path_denylist` before the bind-mount is added.
- **`--allow-risky-mount PATH`** CLI flag: accepted by `rc up`. Accepts a path that will be matched against the **resolved (realpath) form** of any in-scope input path. The flag effectively pre-populates an in-process `mounts.allow_risky` entry; runs before denylist matching; equivalent to a one-invocation `.rip-cage.yaml` entry. Multiple `--allow-risky-mount` flags may be passed.
- **Schema fields** added to ADR-021 loader schema:
  - `mounts.denylist`: `additive_list`, default populated in `~/.config/rip-cage/config.yaml`
  - `mounts.allow_risky`: `selection_list`, default empty; project replaces if present
- **Default patterns file**: **Default patterns are written to `~/.config/rip-cage/config.yaml` by `rc install` (or by `rc config init` on first run) as part of the install flow.** If the global file is absent at `rc up` time, `rc` fails loud with an actionable message directing the user to `rc install` or `rc config init`, consistent with ADR-014 D2's non-interactive fail-loud posture. The patterns do not exist as hardcoded values inside `rc`; they exist as a seed list in the installer, which is the install-time analogue of the config substrate.
- **Tests**: `tests/test-secret-path-denylist.sh` covering: (a) `--env-file ~/.aws/credentials` matched and blocked; (b) symlink to a denied path is resolved and blocked (D7); (c) `--allow-risky-mount` bypass succeeds; (d) `mounts.allow_risky` bypass via `.rip-cage.yaml` succeeds; (e) workspace path is not checked; (f) `.env` path passes without a project-level denylist entry (D4 `.env` exclusion); (g) project-level additional pattern is respected; (h) `rc config show` lists effective denylist with provenance.
- **Docs**: update `docs/reference/config.md` with the `mounts.denylist` and `mounts.allow_risky` schema fields; cross-reference from the `rc up` reference page.

## canonical_refs

- `docs/decisions/ADR-001-fail-loud-pattern.md` — no-silent-failure principle; D6's incidental-tier warn-and-skip stays loud (stderr warning), consistent with it
- `docs/decisions/ADR-003-agent-friendly-cli.md` — D3 allowed-roots input validation; `validate_path` and `realpath`-first model that this ADR extends (composition layer)
- `docs/decisions/ADR-010-auth-refresh.md` — D1 OAuth credential mount (`~/.claude/.credentials.json`); explicitly in D5 scope OUT
- `docs/decisions/ADR-014-push-less-cage.md` — D2 non-interactive fail-loud SSH posture; D6 failure-mode discipline follows the same non-interactive pattern
- `docs/decisions/ADR-017-ssh-agent-forwarding-default.md` — D1 SSH-agent forwarding; SSH socket is explicitly in D5 scope OUT
- `docs/decisions/ADR-020-ssh-identity-routing.md` — D1 SSH config + filtered known_hosts mount; ADR-020's tightly-defined mount surfaces are explicitly in D5 scope OUT
- `docs/decisions/ADR-021-layered-rip-cage-config.md` — D1+D2 config substrate and `additive_list`/`selection_list` merge schema; this ADR adds `mounts.denylist` (additive_list) and `mounts.allow_risky` (selection_list) as consumers of that substrate
- `docs/decisions/ADR-022-ssh-allowlist.md` — D3 two-layer precedent (mount layer + PreToolUse hook); explicitly contrasted in D3 of this ADR — denylist uses single-layer enforcement because no agent-runtime bypass surface exists
- rip-cage-c1p.2 (closed) — introduced `_collect_dangling_symlinks` and the symlink-follow mount surface that D5 now lists as an incidental IN-scope surface
- External: NanoClaw `src/modules/mount-security/index.ts:39-57` (17-pattern default list source); NanoClaw `src/modules/mount-security/index.ts:137-143` (realpath-first resolution pattern)
