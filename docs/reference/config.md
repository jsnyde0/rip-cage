# Layered `.rip-cage.yaml` config

Rip cage reads two optional YAML files on every `rc up` and merges them into one **effective config**. The result is what downstream consumers (the msb egress allowlist / credential bindings, etc.) see.

| File | Path | Scope | Tracked in git? |
|---|---|---|---|
| Global | `~/.config/rip-cage/config.yaml` | All projects on this host | N/A (host config) |
| Project | `<project-root>/.rip-cage.yaml` | This project only | **Yes** (committed by default) |

Both are optional. With both absent, `rc up` behaves identically to a rip cage with no loader at all (per [ADR-021](../decisions/ADR-021-layered-rip-cage-config.md) D5) except for the curated default `network.allowed_hosts` seed auto-written into the global file on first `rc up` (see [egress.md](egress.md)). The substrate this page describes lands the loader; per-domain consumers (the egress allowlist, credential bindings, etc.) are layered on top in their own beads.

---

## The effective view — `rc config show`

`rc config show` is the one command that answers "what does this cage see, and *why*". It prints the effective merged config with per-field provenance, and — separately — the tool-manifest egress, so "what can this cage reach and WHY" is a single command. Four provenance sources contribute ([ADR-021](../decisions/ADR-021-layered-rip-cage-config.md) D4): `default` (the schema), `global` (`~/.config/rip-cage/config.yaml`), `project` (`<repo>/.rip-cage.yaml`), and `manifest:<tool>` (a baked tool's declared egress hosts).

```
$ rc config show
# Effective rip-cage config (rc config show)
# Layers loaded:
#   global  = /home/me/.config/rip-cage/config.yaml
#   project = /home/me/code/personal/kinky-bubbles/.rip-cage.yaml
#
version: 2               # from default
network:
  allowed_hosts:                   # union(global, project)
    - api.anthropic.com          # global
    - github.com                 # project
auth:
  credentials: []                 # from default
# manifest egress (host manifest — pending, requires rebuild to change):
#   docs.astral.sh               # manifest:uv
```

Provenance is shown two ways: a per-field comment (`# from default`, `# from global`, `# from project`, `# union(global, project)` for a union list that both layers contributed to) and, for list fields, a per-element label (`# global`, `# project`, `# global+project`, `# default`).

The **manifest egress** block is a *separate* provenance source printed after the config body — it is **never** folded into `network.allowed_hosts`. Its header names the source:
- **`baked into this cage — applied`** when a cage is in scope (`rc allowlist show --effective --cage <name>`, `rc doctor <name>`): the per-tool egress actually baked into that cage at create/reload, even if the host `tools.yaml` has drifted since.
- **`host manifest — pending, requires rebuild to change`** with no cage in scope: derived from the current host manifest; applying a change means editing the manifest + `rc build` + recreate (see [egress.md](egress.md)).

Add `--json` for machine consumers — emits parallel `.config` and `.provenance` objects, the layer paths, a `sha256` of the canonical effective config, and the two manifest-egress fields.

```
$ rc config show --json
{
  "config":     { "version": 2, "network": { "allowed_hosts": [...] }, "auth": { "credentials": [] } },
  "provenance": { "version": "default", "network.allowed_hosts": ["global","project"] },
  "layers":     { "global": "/home/me/.config/rip-cage/config.yaml", "project": "..." },
  "sha256":     "bffbf8172a20a...",
  "manifest_egress":        { "uv": ["docs.astral.sh"] },
  "manifest_egress_source": "pending"
}
```

`manifest_egress` is a per-tool map (`{"<tool>": ["host", ...]}`); `manifest_egress_source` is `applied`, `pending`, or `none`. Both are always present and never merged into `.config` — `rc reload`'s eligibility diff runs on `.config` only, so a manifest egress change can never surface as spurious config drift.

The command works without docker; pass a workspace path (or none, for the CWD) to inspect from anywhere. `rc config get <dotted.key> [path]` is the single-field companion (prints just the resolved value; `--json` for the JSON form).

> **`rc config init` is RETIRED, not merely undocumented.** It bootstrapped `ssh.allowed_hosts`/`ssh.allowed_keys` from `git remote -v` + `ssh -G <host>` — detection logic that only made sense for the retired ssh cluster ([ADR-029](../decisions/ADR-029-msb-migration.md) D3). Today `cmd_config` (`cli/config.sh`) supports `show`, `get`, and the three host-side **write verbs** `set`/`add`/`remove` (see [Write verbs](#write-verbs) below). Authoring a fresh project's `network.allowed_hosts`/`auth.credentials` is either a `rc config add` / hand edit of `.rip-cage.yaml` — see [egress.md](egress.md) for the full flow and worked example.

---

## `session.multiplexer` — in-cage multiplexer

Controls which terminal multiplexer (if any) the cage runs inside. Mirrors [ADR-021 D6](../decisions/ADR-021-layered-rip-cage-config.md#d6-sessionmultiplexer-field--in-cage-multiplexer-selection-added-2026-06-13-rip-cage-1f59).

| Field | Type | Default | Allowed values |
|---|---|---|---|
| `session.multiplexer` | enum | `none` | `none` + any multiplexer provider baked into the image (validated against the `rc.multiplexers` image label; **not** a fixed `tmux`/`herdr` set) |

**`none` (default):** `rc up` / `rc attach` drops into a plain interactive shell. Closing the window ends the process — normal terminal semantics, no surprising persistence.

**`tmux`:** `rc up` starts a tmux session in the cage (or picks from existing sessions). `rc attach` connects to the running tmux session. Closing the window detaches; the agent keeps running. Good for long autonomous runs where you want to reattach.

**`herdr`:** `rc up` / `rc attach` opens the herdr supervisor view. Herdr is installed via the rip-cage tool manifest (no separate Homebrew dependency).

**Merge semantics:** enum — project replaces global if present; absent → inherit global or use default `none`. A value not in the baked registry (`rc.multiplexers` image label; `tmux`/`herdr` ship as `examples/` providers, [ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)) aborts loud, naming the fix (`add the provider to your manifest and run rc build`).

```yaml
# <project>/.rip-cage.yaml
version: 2
session:
  multiplexer: tmux   # or: none, or any baked provider
```

Run `rc config show` to see the effective value with provenance.

---

## `mounts.config_mode` — project config file access inside the cage

Controls whether `.rip-cage.yaml` (the project config file) is writable inside the cage. Default: read-only. ([ADR-021 D7](../decisions/ADR-021-layered-rip-cage-config.md))

| Field | Type | Default | Allowed values |
|---|---|---|---|
| `mounts.config_mode` | enum | `ro` | `ro`, `rw` |

**`ro` (default):** `rc up` adds a nested `:ro` bind-mount over `/workspace/.rip-cage.yaml`, shadowing the broader `/workspace` read-write mount. The in-cage agent cannot write to or unlink the config file. The host can still edit it freely; an in-place host edit shows through the ro mount (editors that write-temp-then-rename replace the inode, so the in-cage view may lag until recreate — but in-cage visibility is not load-bearing: enforcement re-reads the host file). To apply a config change, edit on the host and run `rc reload <cage>`.

**Threat rationale (ADR-024 prompt-injection):** A prompt-injected in-cage agent could bury a containment-weakening line (extra egress host / ssh host / risky mount) in an otherwise-legitimate edit that a human rubber-stamps on `rc reload`/`rc up`. Making the config author-side-only structurally prevents hidden in-cage lines.

**`rw` opt-in:** When `mounts.config_mode: rw` is set, the shadow-mount is omitted and the agent can write to `/workspace/.rip-cage.yaml` directly via the workspace mount. Since `mounts.config_mode` itself is in the config file (which is ro by default), the agent cannot flip ro→rw from inside — opting into rw requires a host-side edit. This preserves the human-approval property.

**Scope:** Project `.rip-cage.yaml` only. The global config (`~/.config/rip-cage/config.yaml`) is never mounted inside the cage — it is unaffected by this field.

**Absent-config case:** If no `.rip-cage.yaml` exists at `rc up` time, no shadow-mount is added. The agent may author a new file via the rw workspace mount; a new file is reviewed wholesale at apply-time, so there is no buried-edit risk ([ADR-021 D5 both-absent posture](../decisions/ADR-021-layered-rip-cage-config.md)).

**Mount-shape label-lock:** `mounts.config_mode` is a create-time mount-shape decision. Toggling between `ro` and `rw` on a running cage requires `rc destroy <name> && rc up` — `rc up` aborts loud on mismatch. `rc reload` also refuses loud on a `config_mode` change (not reload-eligible).

```yaml
# .rip-cage.yaml — opt in to writable config (rare; most projects keep the default ro)
version: 2
mounts:
  config_mode: rw
```

When the in-cage agent needs a new host allowed for egress, the correct flow (default ro) is:
1. Agent surfaces the request in prose: "please add `<host>` to `.rip-cage.yaml` under `network.allowed_hosts`"
2. Human (or a host-side assistant) edits `.rip-cage.yaml` on the host
3. Human runs `rc reload <cage>` to apply — post-cutover this is a **cold-recreate** ([ADR-029](../decisions/ADR-029-msb-migration.md) D4), not a live in-place apply; host mounts and named volumes (including the Claude session) survive, only the guest's ephemeral overlay is lost. See [CLAUDE.md](../../CLAUDE.md#when-you-need-a-new-host-allowed-for-egress-inside-the-cage) and [egress.md](egress.md).

---

## `mounts.denylist` and `mounts.allow_risky` — secret-path denylist

Rip-cage blocks `rc up` from mounting paths that match a set of secret-path patterns (e.g. `.aws`, `.ssh`, `credentials`). This is the **secret-path denylist** ([ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md)).

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `mounts.denylist` | list (**replace-forbidden**) | 16 patterns (see below) | Path-component patterns. If any component of a non-workspace mount surface path exactly equals a pattern, `rc up` aborts with a fail-loud error. Unions across layers; **`!replace` is refused loud** ([ADR-023 D2](../decisions/ADR-023-secret-path-mount-denylist.md)) — the secret-path denylist is additive-only: a project may expand it but never contract or clear it. |
| `mounts.allow_risky` | list | null | Resolved (realpath) paths explicitly allowed to bypass the denylist. **Unions by default** across layers (v2 — this flipped from v1's replace semantics); use `!replace` to narrow, or `!replace []` to zero-out inherited entries. |

### Default 16 patterns

The default denylist is seeded by `rc install` into `~/.config/rip-cage/config.yaml`:

```
.ssh, .gnupg, .gpg, .aws, .azure, .gcloud, .kube, .docker,
credentials, .netrc, .npmrc, .pypirc, id_rsa, id_ed25519, private_key, .secret
```

Note: `.env` is **not** in the defaults — mounting a project's own `.env` as `--env-file` is a common legitimate workflow. Add `.env` project-by-project if needed.

### What the denylist applies to

The denylist applies to **non-workspace** mount surfaces only:
- `--env-file <path>` passed to `rc up`
- `.beads/redirect` resolved target directory
- Skill/agent symlink targets collected from `~/.claude/skills/` and `~/.claude/agents/`

The workspace path (`rc up <path>`) is **never** checked — it is already validated by ADR-003 D3's allowed-roots gate.

### Additive project config

```yaml
# ~/.config/rip-cage/config.yaml — global (sets the floor)
version: 2
mounts:
  denylist:
    - .ssh
    - .aws
    # ... (full 16-pattern default list installed by `rc install`)
```

```yaml
# <project>/.rip-cage.yaml — additive project extensions
version: 2
mounts:
  denylist:
    - my-secrets-dir   # add a project-only secret path
    - build-secrets
```

Effective denylist = global ∪ project (deduplicated, global first). `mounts.denylist` is the one **replace-forbidden** list — `!replace` on it aborts loud ([ADR-023 D2](../decisions/ADR-023-secret-path-mount-denylist.md)); a project can only expand it.

### Bypassing the denylist

One-shot bypass (this invocation only):
```bash
rc up --allow-risky-mount /path/to/allowed-file --env-file /path/to/allowed-file <workspace>
```

Persistent bypass for a project:
```yaml
# <project>/.rip-cage.yaml
version: 2
mounts:
  allow_risky:
    - /Users/alice/.aws/my-tools-credentials  # resolved (realpath) path — unions with any global entries
```

`mounts.allow_risky` unions across layers by default in v2. To make a project's list authoritative (discard inherited entries), tag it `!replace`; `!replace []` clears them entirely.

Both forms require the **resolved (realpath)** form of the path — `rc up` shows the resolved path in the error message so you can copy-paste it.

### Verifying active denylist

```bash
rc config show          # shows effective denylist with per-pattern provenance
```

Example output with both global and project patterns:
```
mounts:
  denylist:                   # union(global, project)
    - .aws                 # global
    - .ssh                 # global
    - .env                 # project
  allow_risky: null               # from default
```

Cross-reference: [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md) for full design rationale, pattern semantics, and failure-mode contract.

---

## `network.*` — msb egress allowlist

> **Retired ([ADR-029](../decisions/ADR-029-msb-migration.md) D2/D4):** the in-cage engine this section used to describe (SNI router, DNS sidecar, iptables REDIRECT, observe-mode traffic logging, the `network.egress.mediator`/`network.http.forward_to` auto-launched-mediator seam) is **deleted**. Egress is now an msb host-side runtime primitive: `--net-default deny` + one `--net-rule allow@<host>` per entry in `network.allowed_hosts`, generated straight from this config by `cli/lib/msb_flags.sh` — there is no in-cage process to inspect or restart.

Cages boot **default-deny**: only hosts in the effective allow set are reachable at all — everything else is a fake-accepted TCP connect delivering zero bytes, or a denied+logged DNS query. The effective allow set is `network.allowed_hosts` **union** every baked tool's manifest egress (see [egress.md](egress.md)). `network.allowed_hosts` itself unions its file layers over the schema default — the "seed ∪ global ∪ project" phrasing describes *where the file content comes from* (the curated seed is auto-written content of the global file), not a distinct merge layer; the loader folds two file layers over the schema default ([ADR-021 D2](../decisions/ADR-021-layered-rip-cage-config.md)). There is no observe mode (msb logs nothing for *allowed* flows, so rebuilding it would mean rebuilding the deleted engine) — a curated default allowlist plus a fast **deny→fix→reload** repair loop replaces it. See [egress.md](egress.md) for the full workflow.

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `network.allowed_hosts` | list | `[]` (plus the curated seed below) | Domains allowed for egress. **Unions by default** across the stack (schema default, global, project). A layer may tag it `!replace` to narrow (`!replace []` = deny all config hosts); the tag is visible in the project-file diff at point of use. The agent inside the cage cannot mutate this — edits apply via the host-only `rc reload` (a **cold-recreate** post-cutover, [ADR-029](../decisions/ADR-029-msb-migration.md) D4 — see [egress.md](egress.md)). **Curated default seed** (auto-written to the global config on first `rc up`, `rip-cage-o2h0`): `api.anthropic.com` (hard requirement — a basic `claude -p` turn fails without it), `mcp-proxy.anthropic.com`, `http-intake.logs.us5.datadoghq.com` (both attempted-but-nonblocking, included for denial-log-noise-free defaults). **Note: `github.com` (or any other git host) is NOT in the seed** — add it explicitly for any project that pushes over HTTPS (see `auth.credentials` below and [egress.md](egress.md)'s worked example). **Manifest-egress residual:** hosts a baked tool declares under its `egress:` list in `tools.yaml` are *also* reachable (unioned at runtime), but they are **not** part of `network.allowed_hosts` and cannot be narrowed by `!replace` — they travel with the tool; the only removal path is dropping the tool from the manifest + `rc build`. `rc config show` attributes them as `manifest:<tool>` in a separate block. |
| `auth.credentials` | list | `[]` | **New in the msb era** (`rip-cage-rj68`, S6 fold a — the credential→host binding surface the deleted MEDIATOR archetype used to carry). Each entry names up to four fields — `source_env` + `hosts` required, `source_file` + `target_env` optional (added by the tt22 migration, `rip-cage-9dlw`): <br>• **`source_env`** — a bare host env-var NAME (validated `[A-Za-z_][A-Za-z0-9_]*`; the inline `ENV=VALUE@HOST` form is rejected). msb synthesizes the guest secret var from it and injects the real value on the wire toward each listed host only, while the guest env/disk/proc hold just a synthesized placeholder (`$MSB_…`), per [ADR-029](../decisions/ADR-029-msb-migration.md) D5/D3. <br>• **`hosts`** — the domain(s) the real value is injected toward. **Does NOT imply network reachability** — a host must ALSO be in `network.allowed_hosts` or the connection is denied before `--secret` ever gets a chance to inject anything. <br>• **`source_file`** (optional) — an absolute host path; `rc` reads the real value from THIS file into the `--secret` machinery instead of requiring a pre-exported host env var. This is the **no-manual-pre-export** path (how claude's setup-token is wired). <br>• **`target_env`** (optional list) — guest env-var name(s) that receive the placeholder, so a tool that reads a fixed var (claude reads `CLAUDE_CODE_OAUTH_TOKEN`) gets it. **Enforced single-host, loud:** a `target_env` binding must be bound to exactly one host — both config validation and the msb-flags generator abort naming the var otherwise (a fixed guest var carries a single placeholder). <br>**When `source_file` is absent**, `source_env` must be set and non-empty in the host environment at every `rc up`/`resume`/`reload` (msb re-resolves `--secret` from host env at every boot) — an unset/empty var fails loud naming the var, before any sandbox is created. |
| `auth.placeholder_env_file` | scalar | unset (null) | Host path to a `KEY=VALUE`-per-line file carrying the agent's non-secret placeholder token (e.g. `CLAUDE_CODE_OAUTH_TOKEN`) — a persisted POINTER, applied at cage **create only** (never on resume — the guest env is frozen at create time). CLI `--env-file` always wins when both are given (the pointer is ignored, with a log note — no additive merge). Must be an absolute path (no `~`/relative resolution). Fails loud at create if the file is missing, or if its path matches the secret-path denylist (`mounts.denylist`) — this file's contents land in the guest's PID 1 environment where the agent can read them (`/proc/1/environ`), so an operator accidentally pointing at a real secret file (e.g. `~/.aws/credentials`) is refused. Not validated under `--dry-run` (dry-run exits before the create path). |

There is also an **IOC floor** — a curated denylist of known exfil sinks — that is always enforced and **cannot be overridden** by `network.allowed_hosts` (re-homed to the msb-runtime floor, [ADR-029](../decisions/ADR-029-msb-migration.md) D2).

> **Retired `network.*` fields (loud-reject, not silent-drop).** `network.mode`, `network.dns.forward_to`, and `network.http.forward_to` were **removed from the schema** in the v1→v2 bump ([ADR-021 D9](../decisions/ADR-021-layered-rip-cage-config.md)). They were vestigial post-msb-cutover (egress is msb default-deny at the VM boundary — there is no observe/block mode, and msb owns DNS with no host-side forward-to seam). A file still carrying any of them **aborts loud** naming the field, the ADR cite, and the fix (`delete this line`), rather than silently ignoring it (`_config_retired_fields`, `cli/lib/config.sh`). Same treatment as the retired `ssh.*` / `network.egress.mediator*` fields.

### Example — a project that pushes to GitHub over HTTPS

```yaml
# <project>/.rip-cage.yaml
version: 2
network:
  allowed_hosts:
    - github.com
auth:
  credentials:
    - source_env: GH_TOKEN     # a host env var holding a scoped GitHub PAT
      hosts: [github.com]
```

```bash
export GH_TOKEN=ghp_your_scoped_token_here
rc up ~/code/my-project
```

`network.allowed_hosts` **unions by default** across the schema default, global, and project layers (deduplicated, lower layers first); a layer may `!replace` to narrow. Edits are reload-eligible via `rc reload` (cold-recreate, see [egress.md](egress.md)). Use `rc config add network.allowed_hosts <host> --scope project` (or its sugar `rc allowlist add`, host-only) rather than hand-editing, or hand-edit `.rip-cage.yaml` directly and run `rc reload`.

Cross-reference: [egress.md](egress.md) for the full workflow and the curated default allowlist; [ADR-029](../decisions/ADR-029-msb-migration.md) D2/D4 for the msb-runtime design rationale; [composition-seam.md](composition-seam.md) for opt-in composed mediators (compose-only today, never rc-launched).

---

## `dcg.*` — destructive-command guard policy

Rip-cage's DCG (destructive_command_guard) is a **composable recipe** (`examples/dcg/`) — not baked into the base image (ADR-025 D2). When the DCG recipe is composed, the `dcg.*` fields let you **additively** enable extra built-in DCG packs and load custom YAML rule packs from the workspace. The `core` pack floor enforced by the DCG binary cannot be lowered once DCG is present; the `dcg.*` fields only expand policy, never contract it.

See [ADR-025](../decisions/ADR-025-host-adoptable-dcg-policy.md) for full design rationale.

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `dcg.packs` | list | `[]` | Extra built-in DCG pack names to enable on top of `core`. `core` is always present and cannot be removed. Unions across layers by default; `!replace` narrows if you need a project to override the inherited set. |
| `dcg.custom_rule_paths` | list | `[]` | Workspace-relative glob patterns pointing at custom YAML rule pack files (e.g. `.rip-cage/dcg-rules/*.yaml`). Resolved at `rc up` time to cage-absolute `/workspace/*` paths in the generated DCG config. Unions across layers by default; `!replace` narrows. |

### How it works

At `rc up`, the effective `dcg.*` (global∪project, union-merged — the v2 list default) is translated into a merged DCG TOML config file that is bind-mounted **read-only** over the wrapper's pinned config path (`/usr/local/lib/rip-cage/dcg/config.toml`). The generated config always contains `core` in the enabled list — additive only, never subtractive.

**Fail-closed (ADR-025 D5):** If the translated config fails to parse, `rc up` refuses to launch the container and exits non-zero with an actionable message. Fix your `dcg.*` fields and retry.

**Safe-by-default:** With no `dcg.*` configured, no extra mount is added — the recipe-provisioned DCG config stays in effect and behavior is unchanged (requires the DCG recipe to be composed; omitting the recipe means no DCG binary is present and no config is needed).

### Example

```yaml
# ~/.config/rip-cage/config.yaml — global: enable net pack everywhere
version: 2
dcg:
  packs:
    - net

# <project>/.rip-cage.yaml — project: add custom rules for this project
version: 2
dcg:
  packs:
    - filesystem   # additional built-in pack
  custom_rule_paths:
    - .rip-cage/dcg-rules/*.yaml   # workspace-relative glob
```

Effective policy (global ∪ project): `core` + `net` + `filesystem` + custom rules from `.rip-cage/dcg-rules/*.yaml`.

### Custom rule pack format

Custom rule files are YAML files in DCG's rule-pack format. Place them in your project under a workspace-relative path and reference them via `dcg.custom_rule_paths`. Inside the cage, they are accessible at `/workspace/<your-path>`.

DCG loads the custom rule packs at runtime when the cage starts; any DCG-format YAML that passes DCG's own parse is valid.

### Notes

- The `core` pack (`core.filesystem` + `core.git`) is **always** enabled; it cannot be disabled or downgraded via `dcg.*` config.
- `dcg.*` fields are **not** reload-eligible via `rc reload` — they affect container-create-time mounts. Change requires `rc destroy <name>` then `rc up`.
- Both Claude Code's PreToolUse hook and pi's `dcg-gate.ts` extension route through the same wrapper and see the same merged config.

Cross-reference: [ADR-025](../decisions/ADR-025-host-adoptable-dcg-policy.md) for the full design; [ADR-004](../decisions/ADR-004-phase1-hardening.md) for the DCG baseline.

---

## `mounts.symlinks.*` — host-side symlink follow

When rip-cage-managed dotfile mount roots (currently only `~/.pi/agent`, which maps to `/pi-agent` inside the cage) contain absolute symlinks that would dangle inside the container, the `mounts.symlinks` group controls how they are handled.

Default posture: follow the symlink, mount its target at the same absolute path inside the cage, read-write. This is intentional per rip-cage's philosophy: "agent autonomy is the product; it's annoying = design signal."

```yaml
# .rip-cage.yaml or ~/.config/rip-cage/config.yaml
mounts:
  symlinks:
    on_dangling: follow   # follow | warn | skip | error
    scope: file           # file | parent
    mode: rw              # rw | ro
```

| Field | Type | Default | Description |
|---|---|---|---|
| `mounts.symlinks.on_dangling` | enum-scalar | `follow` | What to do when an absolute symlink in a managed dotfile root would dangle inside the cage. `follow` silently adds a second bind mount at the host-target path. `warn` same as `follow` but always logs loudly. `skip` logs a warning and continues without the second mount. `error` aborts `rc up` loud with a remediation message. |
| `mounts.symlinks.scope` | enum-scalar | `file` | Whether to mount the symlink's resolved target file (`file`) or its containing directory (`parent`). `file` is recommended for dotfiles with a few absolute-symlinked config entries; `parent` for cases where the entire containing directory is needed. **`parent` exposes the whole directory, including any sensitive-named leaf files inside it.** The secret-path denylist (ADR-023) is checked against what actually mounts — under `parent` that is the *containing directory's* path, so a denied leaf name (e.g. `credentials`, `id_rsa`) sitting in an otherwise-undenied directory still rides in. This is consistent with how every directory mount behaves (rip-cage never scans directory contents); prefer `scope: file` when a directory holds secrets you don't want in the cage. |
| `mounts.symlinks.mode` | enum-scalar | `rw` | Read-write (`rw`) or read-only (`ro`) for the second bind mount. Default `rw` is intentional for dotpi users who edit canonical files from the cage. Use `ro` if the cage should treat dotfiles as read-only from the project. |

All three fields are `enum` type in the schema (per [ADR-021 D2](../decisions/ADR-021-layered-rip-cage-config.md); v1's `selection_list` name for enum-shaped scalars is retired): unknown values abort loud. Each field is a single scalar value.

**Merge behavior:** project file replaces global when explicitly present (the v2 enum rule — project replaces global replaces default).

**What gets scanned:** Only host paths mapping to rip-cage-managed dotfile mounts. Currently: `~/.pi/agent`. `/workspace` is **never** scanned, regardless of config (D2 FIRM whitelist).

**Mount expansion log:** Every resolved symlink emits one `[rip-cage] follow-symlink: <link> → <target> (<mode>)` line to stderr unconditionally (per ADR-001 D1 — mount-surface expansion is never silent).

**Collision protection:** Targets that resolve to Debian FHS reserved top-level paths (`/bin`, `/boot`, `/dev`, `/etc`, `/home`, `/lib`, `/opt`, `/proc`, `/root`, `/run`, `/sbin`, `/sys`, `/usr`, `/var`, `/tmp`, `/workspace`, `/pi-agent`, `/ssh-agent.sock`) abort `rc up` loud.

**Mount-shape label-lock:** At create time, `rc up` computes and persists a `rc.symlink-follow-fingerprint=<sha256>` container label. On `rc up` resume, if the fingerprint differs (symlink set or `mode` changed), `rc up` aborts with a "destroy and re-up" remediation. This is a host-state-derived label (distinct from config-derived labels like `rc.config-loaded`) — its value changes when host state changes, even with identical `.rip-cage.yaml` content.

**`rc reload` behavior:** `mounts.symlinks.*` changes are mount-shape changes and are **not** reload-eligible. `rc reload` refuses loud with a "destroy and re-up" hint when these fields differ from the applied-config snapshot.

---

## `auth.credential_mounts` / `auth.per_tool.{claude,pi}` — host credential mount posture

Controls whether `rc up` bind-mounts host Claude Code / pi credential files into the cage at all — globally, or **per tool** (rip-cage-xhgr).

```yaml
# <project>/.rip-cage.yaml
version: 2
auth:
  credential_mounts: real   # real (default) | none — global default, applies to both tools
  per_tool:
    claude: none            # optional override: null (default, inherit global) | real | none
    pi: real                # optional override: null (default, inherit global) | real | none
```

| Field | Type | Default | Description |
|---|---|---|---|
| `auth.credential_mounts` | enum-scalar | `real` | Global default. `real` (default) preserves today's behavior bit-for-bit: `~/.claude.json` and `~/.claude/.credentials.json` are bind-mounted read-write, the per-cage macOS-keychain credential extraction runs, and the symlink-follow synthesis may mount a dotpi-managed `auth.json` symlink's resolved target. `none` means the actual credential surface is suppressed — `~/.claude/.credentials.json` is **not** mounted, the symlink-follow `auth.json` leaf is filtered, and the per-cage keychain extraction is skipped; `~/.claude.json` still mounts (see next paragraph — it holds no credentials, rip-cage-t7cu). Intended for cages that obtain credentials via msb `--secret` injection (`auth.credentials`) rather than a mounted file — the non-possession posture. |
| `auth.per_tool.claude` | enum (null-default) | `null` | Optional override for Claude Code's credential mounts (keychain extraction + `.credentials.json`, plus `.claude.json`'s read/write mode). `null` (default, unset) inherits `auth.credential_mounts`; `real` or `none` overrides it for claude only. |
| `auth.per_tool.pi` | enum (null-default) | `null` | Optional override for pi's credential mount (`auth.json`, including the symlink-follow leaf). `null` (default, unset) inherits `auth.credential_mounts`; `real` or `none` overrides it for pi only. |

**Resolution:** `effective(T) = auth.per_tool.T if set, else auth.credential_mounts`. A bare `credential_mounts: none` with no `per_tool` block suppresses **both** tools — byte-identical to the pre-per-tool behavior. `per_tool` lets you express **mixed posture** in a single cage, e.g. `{claude: none, pi: real}` — claude runs non-possession (placeholder + msb `--secret`-injected token via `auth.credentials`) while pi keeps its real, self-refreshing `auth.json`. This is the shape a caged `pi` needs today: pi's third-party OAuth providers have no long-lived static token, so pi cannot ride the same non-possession mechanism claude uses (see [ADR-026](../decisions/ADR-026-containment-mediation-identity.md) D3, D7).

**`~/.claude.json` is not gated with the credential unit (rip-cage-t7cu):** `~/.claude.json` holds no token-shaped fields — it's account metadata (organization/tier/email), MCP server config, and workspace-trust/onboarding state, not a secret. Under `real` it mounts read-write, unchanged. Under `none` it still mounts (skip-if-missing, same as `real`) but **read-only** (`:ro`) — an RW bind would hand a prompt-injected in-cage agent (ADR-024 in-scope) a write primitive into the host's real-credential claude config (poisoned `mcpServers`/hooks executed later by host claude with real creds); under possession RW is no escalation. The actual credential unit gated together under `none` is now `~/.claude/.credentials.json` (the token secret) + the per-cage macOS-keychain extraction — both Claude Code state a non-possession cage genuinely shouldn't receive. For pi, the single `~/.pi/agent/auth.json` (direct mount and symlink-follow leaf) is the credential unit — one file holds all of pi's provider credentials, so there is no finer grain than per-tool.

**Existing `none`-cage upgrade note:** this changes what a *newly created* `effective(claude)=none` cage mounts; it does not retroactively change any running/stopped cage. No resume guard fires — the container label recording `rc.auth.credential-mounts.claude=none` is unchanged (still `none`), so `rc up` resumes a pre-existing non-possession cage exactly as before, simply **without** the `~/.claude.json:ro` mount, until you `rc destroy <name> && rc up` to recreate it. This is expected, not drift.

**Mount-shape, create-time only:** the effective value for each tool determines what gets bind-mounted at container **create** time; `rc up` on an existing container never re-runs mount setup. Toggling either tool's effective value on a running/stopped cage requires `rc destroy <name> && rc up` — `rc up` aborts loud on a mismatch, naming the specific tool that changed. Container labels record the create-time values: `rc.auth.credential-mounts` (the global value, unchanged) plus `rc.auth.credential-mounts.claude` / `rc.auth.credential-mounts.pi` (the per-tool effective values, added by rip-cage-xhgr). A container created before this label pair existed resumes clean as long as its effective values are unchanged (legacy derivation: per-tool label → stored global label → `real`) — upgrading `rc` never bricks a running cage.

**Not reload-eligible:** these fields affect create-time mounts, not live container state — `rc reload` refuses loud if either tool's effective value differs from the applied-config snapshot (same posture as `mounts.config_mode` and `mounts.symlinks.*`).

**`rc auth refresh` is unaffected:** the host-side keychain-to-file maintenance command (`rc auth refresh` → `cmd_auth_refresh`) is project-agnostic and always runs regardless of `auth.credential_mounts` / `auth.per_tool.*` — a `none` cage simply never mounts the file it refreshes. See [auth.md](auth.md).

**Distinguishable skip:** under `none` (global or per-tool), `rc up` logs a distinct `auth.credential_mounts=none — ... intentionally skipped (non-possession posture)` line at each gated site (CC block, pi block, symlink-follow leaf, keychain extraction) — never the ordinary existence-gated "not found — skipping" warning, so the two states are never confused in the log.

**Unknown per-tool keys abort loud:** a typo'd or unsupported key under `auth.per_tool.` (anything other than `claude`/`pi`) fails config validation loud, naming the key, the file, and the allowed set — it never silently inherits `real` (fail-closed, since this is a credential-suppression knob).

**`:ro` in-cage:** like every other config field, this key lives in `.rip-cage.yaml`, which is shadow-mounted `:ro` in-cage by default (`mounts.config_mode`) — the agent inside the cage cannot self-flip `none` → `real`.

---

## Per-field-type merge rules (v2)

The merge stack is exactly three elements, folded left: **[schema defaults, global file, project file]** ([ADR-021 D2](../decisions/ADR-021-layered-rip-cage-config.md)). There is no distinct "seed" layer — the curated default hosts are auto-seeded *content* of the global file. The schema declares each field's type (`list`, `enum`, or `scalar`); the loader applies the matching rule.

| Type | Examples | Rule |
|---|---|---|
| **`list`** | `network.allowed_hosts`, `auth.credentials`, `mounts.allow_risky`, `dcg.packs` | **Union by default** — every layer's items are combined, deduplicated, order-preserving (lower layers first). A layer may tag the field **`!replace`** to discard everything inherited from lower layers and become the new base; **`!replace []`** is the explicit zero-out. The tag is visible in the project-file diff at point of use. |
| **`list` (replace-forbidden)** | `mounts.denylist` | Union only — `!replace` **aborts loud** ([ADR-023 D2](../decisions/ADR-023-secret-path-mount-denylist.md)). A project may expand the secret-path denylist, never contract or clear it. |
| **`enum`** | `mounts.config_mode`, `session.multiplexer`, `auth.credential_mounts`, `auth.per_tool.*`, `mounts.symlinks.*` | Project replaces global replaces default. A value outside the allowed set **aborts loud** naming the field and the allowed values. (v1's `selection_list` name for these enum-shaped scalars is retired.) |
| **`scalar`** | `version`, `auth.placeholder_env_file` | Project replaces global if present. |

Validation **aborts loud naming the exact path** for: an unknown custom tag; `!replace` on a non-list or undeclared field; `!replace` on `mounts.denylist`.

**Example 1 — union (the default).** Global seeds two hosts; project adds a third:

```yaml
# ~/.config/rip-cage/config.yaml
version: 2
network:
  allowed_hosts:
    - api.anthropic.com
    - github.com
```

```yaml
# <project>/.rip-cage.yaml
version: 2
network:
  allowed_hosts:          # effective = [api.anthropic.com, github.com, chatgpt.com]
    - chatgpt.com
auth:
  credential_mounts: none # enum → project replaces
```

**Example 2 — `!replace` narrowing.** The same project narrows the inherited allowlist to a single host:

```yaml
# <project>/.rip-cage.yaml
version: 2
network:
  allowed_hosts: !replace   # effective = [api.anthropic.com] — inherited set discarded
    - api.anthropic.com
```

`!replace []` (an empty block under the tag) discards the inherited set entirely.

---

## Write verbs

`rc config set/add/remove` edit the posture files host-side so the file taxonomy stops being prerequisite knowledge — the verb routes intent to the right home ([ADR-021 D8](../decisions/ADR-021-layered-rip-cage-config.md)). **The verbs are sugar; the two YAML files stay the source of truth** — a hand edit is always equivalent and remains first-class.

```bash
rc config set  <dotted.key> <value> --scope global|project [path]
rc config add  <dotted.key> <item>  --scope global|project [path]
rc config remove <dotted.key> <item> --scope global|project [path]
```

- **`--scope` is required** — no default guessing. `global` targets `~/.config/rip-cage/config.yaml` (seeding the canonical template first if the file is absent); `project` targets `<path-or-CWD>/.rip-cage.yaml`.
- **Surgical, comment-preserving edits.** `yq` only *locates* the key/anchor line; the change is a minimal textual splice of the original bytes, then the full loader re-validates the result. On any validation failure the original file is untouched and the verb refuses with "edit the file." (`yq` *re-emit* is forbidden as a write path — it drops blank lines, normalizes comment spacing, and relocates free-standing comments.)
- **`set`** replaces only the value token on an existing key's line (preserving a trailing `# comment`). It does **not** create a new nested key inside a populated file — that is structural, and refuses with "edit the file."
- **`add`** is idempotent: re-adding an item already present reports `'<item>' already present … — no changes made` and changes nothing.
- **Created files declare `version: 2`.**
- **Refusals (each says "edit the file"):** placing/removing a `!replace` tag; a structural key (`auth.credentials` and other lists-of-maps / nested-map creation); removing from `mounts.denylist` (replace-forbidden, [ADR-023 D2](../decisions/ADR-023-secret-path-mount-denylist.md)); an ambiguous current-value shape; a value containing a newline/CR (injection guard). `add`/`remove` on an already-`!replace`-tagged list preserve the tag and edit that layer's items.
- **Host-side only.** The verbs refuse when run inside a cage (`.rip-cage.yaml` is `ro` in-cage by default, and `rc` is not on the cage PATH) — the in-cage flow is to surface the request in prose for the human. `rc allowlist add` is sugar over `rc config add network.allowed_hosts` (same write engine and safety guards).

```bash
# Add a host to this project's allowlist (surgical; keeps comments)
rc config add network.allowed_hosts files.example-cdn.net --scope project

# Set a per-project multiplexer
rc config set session.multiplexer tmux --scope project
```

---

## Schema versioning

Each file declares `version: <integer>` at the top level. The supported set is exactly **`{2}`** ([ADR-021 D3](../decisions/ADR-021-layered-rip-cage-config.md)/D9). The 1→2 bump is a **breaking change** — v1 files must be hand-migrated.

| Condition | Behavior |
|---|---|
| `version` absent | Assume `version: 2`; warn loud once per `rc up` invocation per file (`'<file>' has no 'version:' field; assuming version 2. Add 'version: 2' to silence.`). **EXCEPTION:** a version-absent file that declares `mounts.allow_risky` **aborts loud demanding an explicit version declaration** — that field's v1→v2 semantics flip (replace → union, capability-widening), so rc refuses to assume a version for it. |
| `version: 2` | Load normally. |
| `version: 1` | **LOUD ABORT** with an actionable migration hint (change `version: 1` to `version: 2`; express any v1 replace-narrowing with the `!replace` tag, since lists now union by default). Never reinterpreted, never silently skipped. |
| `version` higher than supported | **Abort loud iff the file uses any `!replace` tag** (dropping a file whose narrowing intent rides on tags is the capability-EXPANDING failure direction). Otherwise warn loud + skip that file's contents (load defaults / other layer only). |

Per-file independence: a global `version: 2` and a project `version: 99` are evaluated separately. The project file may be skipped or aborted; the global file still loads.

---

## First-run hint and drift notice

When `rc up` first creates a container, it stamps a `rc.config-loaded=<sha256>` label using the canonical sha of the effective config AND writes a per-container snapshot at `~/.cache/rip-cage/<cname>/config-applied.json`. Subsequent `rc up` invocations diff the live effective config against the snapshot:

- **First-run** (no snapshot yet): one-time `Loaded .rip-cage.yaml (sha256:<prefix>). Run 'rc config show' to inspect.`
- **Reload-eligible drift** (only `network.allowed_hosts` differs from snapshot — it is the *sole* reload-eligible path post-schema-v2, `_RC_RELOAD_ELIGIBLE_PATHS` in `cli/reload.sh`): `Notice: .rip-cage.yaml has reload-eligible changes since last apply: ... Run: rc reload <cname>`
- **Non-eligible drift** (any other field, e.g. `auth.credentials`, `mounts.*`, `session.multiplexer`): `Notice: .rip-cage.yaml has changes since this container was created (paths: ...). Some fields require 'rc destroy <cname> && rc up' to take effect.`
- **Manifest-egress drift** (a baked tool's `egress:` list changed since this cage was baked): reported by `rc reload`/`rc reload --dry-run` as **"requires rebuild"** — never as reload-eligible or refuse-loud drift. Its remedy is edit the manifest + `rc build` + recreate, *not* `rc reload` (which only re-materializes from the current config, and the tool binary needs a rebuild anyway).

Most fields apply on resume; capability-changing fields that affect create-time mounts/net-rules/secrets (e.g. `auth.credentials`, `mounts.config_mode`) require `rc destroy <name> && rc up`. `rc up --reload` / `RC_UP_CONVERGE` and `rc reload` converge **only reload-eligible drift** (`network.allowed_hosts`) — they are **not** a general substitute for destroy+up: on a stopped cage with non-eligible drift, `rc up --reload` falls through to a plain resume and the resume-time mount-shape guards (`mounts.config_mode`, `mounts.symlinks.*`, `auth.credential_mounts`) abort loud, themselves naming `rc destroy && rc up` as the fix (`_up_eligible_drift_paths`, `cli/up.sh`). Pure-content edits to `network.allowed_hosts` apply via `rc reload` — **a cold-recreate post-cutover**, not a live in-place apply ([ADR-029](../decisions/ADR-029-msb-migration.md) D4; [ADR-022](../decisions/ADR-022-ssh-allowlist.md) D6's retirement note). Each consumer documents which of its fields are reload-eligible vs recreate-required vs resume-applicable.

---

## Dependencies

The loader uses [`yq`](https://github.com/mikefarah/yq) (mikefarah/yq, the Go reimplementation) to parse YAML.

- **macOS:** `brew install yq`
- **Linux:** the [mikefarah/yq release binary](https://github.com/mikefarah/yq/releases) (or via brew on Linux) — NOT apt's `yq`, which is [kislyuk/python-yq](https://github.com/kislyuk/yq) and does not understand the mikefarah v4 flags this repo uses

If `yq` is missing, `rc config show` and any `rc up` that needs the loader exit with an actionable error per [ADR-001](../decisions/ADR-001-fail-loud-pattern.md). The loader does not silently degrade to "skip config" — that would silently nullify a user-authored capability scoping (same failure class as silently skipping an unsupported-version file that uses `!replace`).

`rc up` with no `.rip-cage.yaml` present does **not** require yq — the loader is only invoked when a file is detected.

---

## See also

- [ADR-021](../decisions/ADR-021-layered-rip-cage-config.md) — substrate decisions (file location, merge rules, schema versioning, regression contract)
- [ADR-001](../decisions/ADR-001-fail-loud-pattern.md) — fail-loud pattern (why `yq` missing aborts; why a higher-version file using `!replace` aborts)
- [egress.md](egress.md) — `network.allowed_hosts`/`auth.credentials` worked example (git-over-HTTPS host allow + token binding); [SSH Identity Routing](ssh-routing.md) is retired — kept only as a historical record
