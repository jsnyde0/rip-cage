# The Fail-Closed Manifest Validator (contract reference)

This is the reference for **ADR-005 D11 mechanism 2** (FIRM — the non-skippable enforcement arm of D9): every check `rc` runs against a tool manifest, with the conditions that trip them and the error text you will see. It is derived from the `rc` source (function names cited throughout; line numbers deliberately omitted — they drift). The goal: a manifest author can predict what will fail **without reading `rc`**.

**Failure semantics:** every check here is fail-closed — a violation refuses the build/up with an error naming the entry and the rule (ADR-001 fail-loud; ADR-005 D10 safety-side asymmetry). Contrast the *runtime* side: a composed user daemon that fails its health probe is fail-**warn** (the cage still starts). Validation is never warn.

**Entrypoint completeness (FIRM):** the checks are wired into *every* build path — `cmd_build` (`rc build`) and `_pull_or_build_local` (the `rc up` auto-build) — plus the pre-Docker floor checks at `rc up`. A new `docker build` call site must inherit them or it reintroduces the bypass rip-cage-buuo.6 closed.

The pipeline, in firing order:

| Phase | Function | When |
|---|---|---|
| 1. Strict-parse | `_manifest_validate` | at every manifest load (build and up) |
| 2. IOC egress floor | `_manifest_check_ioc_egress` | before any Docker call (build and up) |
| 3. Mount denylist + dest allowlist | `_manifest_check_mounts_denylist` (and again per-mount at `rc up` via `_manifest_build_mount_args`) | before any Docker call |
| 4. Build isolation | `_manifest_check_build_isolation` | after Dockerfile codegen, **before** `docker build` |
| 5. Binary root-owned | `_manifest_check_binary_root_owned` | **after** `docker build` (stats the built image) |
| 6. Mount-asset root-owned | `_manifest_check_mount_root_owned` | after `docker build` (same gate as 5) |

In `rc build --json`, phase-2 failures surface as error code `MANIFEST_IOC_EGRESS_DENIED`, phase-4 failures as `MANIFEST_BUILD_ISOLATION_VIOLATED`, and phase-5/6 failures as `MANIFEST_BINARY_NOT_ROOT_OWNED`. The `rc up`-side re-checks emit `MANIFEST_IOC_EGRESS_DENIED` (phase 2) and `MANIFEST_MOUNT_DENYLIST_DENIED` (phase 3) under `--json`.

---

## 1. Strict-parse (`_manifest_validate`)

Validate-by-parsing, never by running a fail-open consumer (ADR-001, ADR-025 D5). First violation wins; errors follow the pattern `Error: manifest '<file>' tools[<idx>] ('<name>'): …`.

### File-level

| Condition | Error (key text) |
|---|---|
| `yq` missing from PATH | `yq not found on PATH … NOT apt's yq, which is the incompatible python-yq` |
| file not parseable as YAML | `failed to parse as YAML` |
| `version` present but not a positive integer | `invalid 'version' field … must be a positive integer` |
| `tools` present but not a list | `field 'tools' must be a list` |

An empty/null file passes (treated as "use defaults").

### Every entry, any archetype

| Condition | Error (key text) |
|---|---|
| `name` missing/empty | `required field 'name' is missing` |
| `archetype` missing | `required field 'archetype' is missing` |
| `archetype` not one of the allowed set | `unknown 'archetype' value '<v>'. Allowed: TOOL, SHELL-INTEGRATION, IN-CAGE-DAEMON, MULTIPLEXER` |
| `version_pin` missing | `required field 'version_pin' is missing (… use "bundled" for image-bundled tools)` |

(Note: the validator accepts **four** archetype values, matching ADR-005 D7's prose. The fifth, MEDIATOR — added by the now-retired ADR-026 D5 — is **deleted, not just undocumented**, per [ADR-029](../decisions/ADR-029-msb-migration.md) D2/D5: `cli/lib/manifest_checks.sh` has no MEDIATOR handling left.)

### TOOL entries

**Declarations:**

| Condition | Error (key text) |
|---|---|
| `egress` absent | `required field 'egress' is missing (… even if empty: egress: [])` |
| `egress` not a list | `field 'egress' must be a list` |
| `mounts` absent / not a list | `required field 'mounts' is missing` / `must be a list` |
| a `mounts[]` element not an object | `mounts[i] must be an object with 'host' and 'dest' fields` |
| mount `host` or `dest` missing/empty | `required field 'host' is missing or empty` / same for `dest` |
| mount `mode` present but not `ro`/`rw` | `field 'mode' must be 'ro' or 'rw' … default is 'ro'` |
| mount `root_owned_required` present but not boolean | `must be a boolean (true or false)` |

**Install-path coupling** (`version_pin` × `install_cmd` × `build_source`):

| Condition | Error (key text) |
|---|---|
| `version_pin: "bundled"` + `install_cmd` | `'install_cmd' must not be set when version_pin is "bundled"` |
| `version_pin: "bundled"` + `build_source` | `'build_source' must not be set when version_pin is "bundled"` |
| both `install_cmd` and `build_source` | `mutually exclusive (use build_source for from-source builds; install_cmd for prebuilt …)` |
| neither (non-bundled) | `required field 'install_cmd' is missing` |
| `install_cmd` contains a newline | `must be a single line (newlines inject arbitrary Dockerfile directives)` — enforced in the **TOOL, SHELL-INTEGRATION, and IN-CAGE-DAEMON cases** (every archetype that can carry `install_cmd`; rip-cage-62a9), and re-checked at the generation site (`_manifest_generate_extra_dockerfile_steps`) as defense-in-depth |

**`build_source` sub-fields** (from-source path — see [building-from-source.md](building-from-source.md)):

| Condition | Error (key text) |
|---|---|
| `builder_image` / `build_script` / `output_path` missing | `required field 'build_source.<field>' is missing` |
| any of the three contains a newline | `must be a single line (newlines inject arbitrary Dockerfile directives)` |
| `build_script` absolute | `must be a relative path within the build context (repo root) — absolute paths are outside the Docker build context` |
| `build_script` contains `..` traversal | `must not escape the build context — '../' traversal resolves outside the repo root` |

**Optional fields on TOOL entries:**

- `binary_path` (string or list of strings; enables the phase-5 check on prebuilt entries): each value must be non-empty, single-line, absolute (`must be an absolute path starting with '/'`); wrong type → `must be a string or a list of strings`.
- `launch_args` (list of strings; ADR-027 D4): must be an array (`use launch_args: ["--flag", "value"]`); each element a non-empty, single-line string.
- `init` (the one-shot agent-context boot hook, ADR-005 D7): must be non-empty/non-whitespace (`an empty hook is never run as eval ""`), single-line, **and passes the hook-bounds check** (same forbidden patterns as MULTIPLEXER hooks — see below).

### SHELL-INTEGRATION entries

| Condition | Error (key text) |
|---|---|
| `shell_init` missing/empty | `required field 'shell_init' is missing (SHELL-INTEGRATION archetype)` |
| `shell_init` contains a newline | `must be a single line (newlines inject arbitrary Dockerfile directives)` — checked again at the generation site (`_manifest_generate_shell_init_zshrc_steps`) as defense-in-depth |
| optional `install_cmd` contains a newline | `field 'install_cmd' must be a single line …` — SHELL-INTEGRATION entries may carry `install_cmd` for binary baking; the generator consumes it identically to TOOL, so the same newline guard applies (rip-cage-62a9) |

### IN-CAGE-DAEMON entries

| Condition | Error (key text) |
|---|---|
| `start` / `health` / `state_dir` missing | `required field '<field>' is missing (IN-CAGE-DAEMON archetype)` |
| `state_dir` not absolute | `must be an absolute path (starting with '/')` |
| `state_dir` contains whitespace | `must not contain whitespace (word-split injection risk)` |
| `state_dir` contains shell metacharacters | ``must not contain shell metacharacters ($`;&|><()\)`` |
| optional `install_cmd` contains a newline | `field 'install_cmd' must be a single line …` — IN-CAGE-DAEMON entries may carry `install_cmd` for binary baking; the generator consumes it identically to TOOL, so the same newline guard applies (rip-cage-62a9) |

### MULTIPLEXER entries

| Condition | Error (key text) |
|---|---|
| name outside `[a-z0-9_-]` | `name … must be lowercase alphanumeric, hyphens, or underscores only` (names become registry dir components `/etc/rip-cage/multiplexers/<name>`) |
| unknown top-level field | `unknown field '<k>' (strict-parse — only name/archetype/version_pin/hooks are allowed)` |
| `hooks` missing / not an object | `required field 'hooks' is missing` / `must be an object` |
| `hooks.start` or `hooks.attach` missing | `required field 'hooks.start' is missing (… start hook is required)` / same for `attach` |
| unknown key inside `hooks` | `unknown hook key '<k>' … only start/attach/exec/new_session/teardown are allowed` |
| any hook trips the hook-bounds patterns | see **Hook-bounds** below |

> **Retired: MEDIATOR entries.** The egress-mediator manifest archetype (isomorphic to MULTIPLEXER, with `run_as_uid`/`ca_cert_path`/`hooks.start` fields and its own hook-bounds checks including an `RIP_CAGE_EGRESS=`/`iptables` guard) is **deleted, not just undocumented** ([ADR-029](../decisions/ADR-029-msb-migration.md) D2/D5) — `cli/lib/manifest_checks.sh` has no MEDIATOR handling left; `MEDIATOR` is not in the validator's allowed archetype set (see the table above). See [composition-seam.md](composition-seam.md) for what replaced it.

### Hook-bounds check (shared: MULTIPLEXER hooks, TOOL `init`)

Every declared hook command is **statically parsed, never executed**, against the floor-weakening patterns (ADR-005 D9/D10/D11). Any match rejects the manifest with a `hook-bounds violation` error naming the hook and pattern:

1. **DCG config write** — command references a `.config/dcg/` path.
2. **Workspace DCG config** — command references `.dcg.toml`.
3. **PATH manipulation** — command contains `PATH=` (the PATH-shadow mechanism; legitimate hooks never need PATH overrides, so any occurrence rejects).
4. **Safety-binary write** — command references `/usr/local/lib/rip-cage/bin/dcg-guard`, `/usr/local/lib/rip-cage/hooks/block-ssh-bypass.sh`, or `/usr/local/bin` / `/usr/bin` paths for `dcg`, `dcg-policy`, `block-ssh-bypass`.
5. **Lifecycle-interceptor registration** — command references `/etc/rip-cage/`, `settings.json`, `PreToolUse`, or `PostToolUse`.

These are substring/regex matches on the command string — an *innocent* hook that merely mentions one of these strings (e.g. echoes a path containing `settings.json`) is also rejected. That is deliberate fail-closed posture: reword the hook.

### Cross-cutting: `required` / `assert_loaded` (ADR-005 D13)

Truth table (any archetype):

| Combination | Result |
|---|---|
| `required: true` + `assert_loaded: "<cmd>"` | ACCEPT (check baked verbatim) |
| `required: true`, no `assert_loaded`, TOOL with `binary_path` or `build_source.output_path` | ACCEPT (codegen synthesizes `test -x <path>`) |
| `required: true`, no `assert_loaded`, no declarable path | REJECT — `a required tool must be presence-checkable or carry assert_loaded` |
| `required: true` on a non-TOOL archetype without `assert_loaded` | REJECT — `non-TOOL archetypes have no declarable binary path` |
| `assert_loaded` without `required: true` | REJECT — `a check command that would never fire is a footgun` |
| `required` not boolean | REJECT — `field 'required' must be a boolean` |
| `assert_loaded` empty/whitespace or multi-line | REJECT — `an empty check is never run as bash -c ""` / single-line-required |
| tool `name` contains a space while `required: true` | REJECT — `the baked asserted-file is space-delimited` |

---

## 2. IOC egress floor (`_manifest_check_ioc_egress`)

Every `egress:` host declared by **any** entry (no archetype filter) is matched against the `deny: true` rules in `egress-rules.yaml` — exact `match.host` and suffix `match.host_suffix` (`.ngrok.io` matches `foo.ngrok.io`). Parsed with yq/jq, not grep. A hit refuses build/up:

> `manifest tool '<name>' declares egress host '<host>' which is on the IOC denylist (egress-rules.yaml deny:true). Remove this host … (ADR-005 D3 / ADR-012 D1)`

Fail-closed hardening: a missing rules file, missing `yq`, or an unparseable denylist is itself an error (`refusing to build/up`) — the check never degrades to an empty denylist. Declared egress that *passes* is unioned into the cage allowlist at `rc up` (`_manifest_egress_hosts_json`) but always stays **under** the non-overridable IOC floor (ADR-012 D1).

## 3. Mount denylist + dest allowlist (`_manifest_check_mounts_denylist`)

For every `mounts[]` entry: the `host` path gets safe expansion (leading `~/`, literal `$HOME`/`${HOME}` only — no arbitrary variable interpolation; `_manifest_expand_mount_host`), then **realpath-first** resolution, then:

- **Secret-path denylist** (ADR-023 D1/D6 FIRM): a resolved host path matching the denylist refuses with `matched secret-path denylist pattern '<pat>'. Remove this path … or add to mounts.allow_risky in .rip-cage.yaml`.
- **Dest allowlist** (rip-cage-rc09 / ADR-027 D1): the `dest` is lexically normalized (blocks `/home/agent/../etc/…` escapes) and must land under `/home/agent` or `/workspace` — *unless* the mount declares `root_owned_required: true` **and** the resolved host source is genuinely root-owned (uid 0, not group/other-writable). A `root_owned_required: true` mount with a non-root host source gets **no exemption**. Violation: `dest '<d>' … is outside the agent-writable allowlist (/home/agent, /workspace)`.

The same two checks run again per-mount at `rc up` when the `-v` args are built (`_manifest_build_mount_args`), which additionally **skips** (with a stderr note, not an error) any mount whose host dir does not exist (`skip-if-host-missing`).

## 4. Build isolation (`_manifest_check_build_isolation`)

Static scan of the generated Dockerfile, restricted to `rc-builder-*` stages, **before** `docker build`. Rejected inside a builder stage:

| Vector | Error (key text) |
|---|---|
| `RUN --mount=type=bind` with absolute `src=` | `absolute host path in builder stage violates build-isolation invariant … must not bind-mount host paths` |
| `RUN --mount=type=ssh` | `SSH agent socket injection in a builder stage …` |
| `RUN --mount=type=secret` | `host secret injection in a builder stage …` |
| `VOLUME` directive | `VOLUME in a builder stage introduces host-path access … must be fully isolated` |

All errors cite the stage name and Dockerfile line. Scope note (honest limit, named in ADR-005 D11): this is **filesystem** isolation — builder stages retain network access, and the validator does not observe the build script's runtime behavior. Human review of the build script remains load-bearing.

## 5. Binary root-owned (`_manifest_check_binary_root_owned`)

Effect-based, **after** `docker build`: `docker run --rm <image> stat -c '%U %a' <path>` on every checkable binary —

- **from-source entries:** `/usr/local/bin/<basename of build_source.output_path>` (same derivation as codegen);
- **prebuilt entries that declare `binary_path`:** each declared path as-is;
- **prebuilt entries without `binary_path`:** skipped — the deliberate 80/20 coverage boundary (ADR-024 D11; package-manager installs land root-owned anyway, and forcing a declaration would gate legitimate work). These fall to human review.

Rejections:

| Condition | Error (key text) |
|---|---|
| path cannot be stat'd in the image | `could not stat '<path>' inside image … binary may be absent or image not built` |
| owner not root | `is owned by '<user>' (not root). An agent-writable binary violates the safety floor — an injected agent could rewrite its own tool` |
| mode group- or other-writable | `has mode '<mode>' which is group/other-writable. The agent user could overwrite this binary` |

Unlike phase 1, this phase collects **all** violations before failing (one error line per bad binary).

## 6. Mount-asset root-owned (`_manifest_check_mount_root_owned`)

Sibling to phase 5, keyed off the generic mount flag rather than binary paths: every mount declaring `root_owned_required: true` has its `dest` stat'd inside the built image and must be root-owned and not group/other-writable. Errors mirror phase 5's (`A root_owned_required asset must be root-owned — an agent-writable asset is fail-open against the ro-mount guarantee`). Mounts without the flag (or with `false`) are skipped.

---

## What the validator does NOT do

So you don't over- or under-trust it:

- It does not sandbox or observe `install_cmd` / build-script **execution** — it bounds declarations statically and asserts output effects. Build-time network egress from a builder stage is unrestricted (named residual, ADR-005 D11).
- It does not check binary ownership for prebuilt entries with no declared `binary_path` (the 80/20 boundary above).
- It does not verify `version_pin` against what the install actually fetched — the pin is your declaration; your `install_cmd`/script is the source of truth.
- It is not a review substitute: the manifest is host-only (ADR-005 D7 FIRM) precisely because the human deciding what goes in it — not this validator alone — is the composition authority.

## See also

- [adding-a-tool.md](adding-a-tool.md) / [building-from-source.md](building-from-source.md) / [shell-integration.md](shell-integration.md) / [in-cage-daemon.md](in-cage-daemon.md) — the archetype walkthroughs whose entries this contract bounds
- [docs/reference/README.md](README.md) — seam catalog
- [ADR-005 D9/D10/D11](../decisions/ADR-005-ecosystem-tools.md) — the availability-only invariant, the fail-closed/fail-warn asymmetry, and the validator's FIRM standing
- [ADR-012](../decisions/ADR-012-egress-firewall.md) (IOC floor), [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md) (mount denylist), [ADR-026 D5](../decisions/ADR-026-containment-mediation-identity.md) (mediator hook bounds), [ADR-027 D1](../decisions/ADR-027-agent-substrate-projection.md) (root-owned assets / dest allowlist)
