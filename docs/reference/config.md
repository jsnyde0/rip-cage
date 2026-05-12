# Layered `.rip-cage.yaml` config

Rip cage reads two optional YAML files on every `rc up` / `rc init` and merges them into one **effective config**. The result is what downstream consumers (SSH allowlist, future egress overrides, etc.) see.

| File | Path | Scope | Tracked in git? |
|---|---|---|---|
| Global | `~/.config/rip-cage/config.yaml` | All projects on this host | N/A (host config) |
| Project | `<project-root>/.rip-cage.yaml` | This project only | **Yes** (committed by default) |

Both are optional. With both absent, `rc up` behaves identically to a rip cage with no loader at all (per [ADR-021](../decisions/ADR-021-layered-rip-cage-config.md) D5). The substrate this page describes lands the loader; per-domain consumers (SSH allowlist, etc.) are layered on top in their own beads.

---

## `rc config show`

Prints the effective merged config with provenance.

```
$ rc config show
# Effective rip-cage config (rc config show)
# Layers loaded:
#   global  = /home/me/.config/rip-cage/config.yaml
#   project = /home/me/code/personal/kinky-bubbles/.rip-cage.yaml
#
version: 1               # from project
ssh:
  allowed_keys:                   # from project
    - id_ed25519_personal
  allowed_hosts:                   # union(global, project)
    - github.com                 # global
    - switch.berlin                 # project
```

Add `--json` for machine consumers — emits parallel `.config` and `.provenance` objects plus the layer paths and a `sha256` of the canonical effective config.

```
$ rc config show --json
{
  "config":     { "version": 1, "ssh": { "allowed_keys": [...], "allowed_hosts": [...] } },
  "provenance": { "version": "project", "ssh.allowed_keys": "project", "ssh.allowed_hosts": ["global","project"] },
  "layers":     { "global": "/home/me/.config/rip-cage/config.yaml", "project": "..." },
  "sha256":     "bffbf8172a20a..."
}
```

The command works without docker; pass no arguments to inspect from any CWD.

---

## Per-field-type merge rules

The schema declares each field's merge type; the loader applies the matching rule.

| Type | Examples | Rule | Direction |
|---|---|---|---|
| **Additive list** | `ssh.allowed_hosts` | Union — global ∪ project, deduplicated, order-preserving (global first) | Project EXPANDS; cannot contract |
| **Selection list** | `ssh.allowed_keys` | Three-state: project absent ⇒ inherit global; project non-empty ⇒ replace; project `[]` ⇒ explicit zero-out | Project CAN narrow a global capability |
| **Scalar** | `version` | Project replaces global if present | Project replaces |

**Example.** Global config grants two keys and `github.com`; project grants `switch.berlin` additively and narrows the key set to one:

```yaml
# ~/.config/rip-cage/config.yaml
version: 1
ssh:
  allowed_keys: [id_ed25519_personal, id_ed25519_work]   # selection list
  allowed_hosts: [github.com]                            # additive list
```

```yaml
# <project>/.rip-cage.yaml
version: 1
ssh:
  allowed_hosts: [switch.berlin]                         # additive → union
  allowed_keys: [id_ed25519_personal]                    # selection → replace
```

Effective:
```yaml
version: 1
ssh:
  allowed_keys: [id_ed25519_personal]
  allowed_hosts: [github.com, switch.berlin]
```

---

## Schema versioning

Each file declares `version: <integer>` at the top level. The loader's behavior on version mismatch depends on the field types in the file (per [ADR-021](../decisions/ADR-021-layered-rip-cage-config.md) D3):

| Condition | Behavior |
|---|---|
| `version` absent | Treat as `version: 1`. Warn loud once per `rc up` invocation per file. |
| `version` matches a supported version | Load normally. |
| `version` higher than supported, file uses **selection-list field(s)** | **Abort loud.** Silent skip would silently expand capability beyond user intent. |
| `version` higher than supported, **additive-only/scalar-only** | Warn loud, skip the file's contents. Effective config falls back to defaults / other layer. |

Per-file independence: a global `version: 1` and a project `version: 99` are evaluated separately. The project file may be skipped or aborted; the global file still loads.

---

## First-run hint and drift notice

When `rc up` first creates a container, it stamps a `rc.config-loaded=<sha256>` label using the canonical sha of the effective config. Subsequent `rc up` invocations compare this label to the current sha:

- **First-run** (label not yet set): one-time `Loaded .rip-cage.yaml (sha256:<prefix>). Run 'rc config show' to inspect.`
- **Drift** (sha changed since container was created): `Notice: .rip-cage.yaml has changed since this container was created (label=..., current=...). Some fields may require 'rc destroy && rc up' to take effect.`

Most fields apply on resume; capability-changing fields that affect docker-create-time mounts/args (e.g., `ssh.allowed_keys` — once shipped) require `rc destroy && rc up`. Each consumer documents which of its fields are recreate-required vs resume-applicable.

---

## Dependencies

The loader uses [`yq`](https://github.com/mikefarah/yq) (mikefarah/yq, the Go reimplementation) to parse YAML.

- **macOS:** `brew install yq`
- **Linux:** `sudo apt install yq` (or via brew on Linux)

If `yq` is missing, `rc config show` and any `rc up` that needs the loader exit with an actionable error per [ADR-001](../decisions/ADR-001-fail-loud-pattern.md). The loader does not silently degrade to "skip config" — that would silently nullify a user-authored capability scoping (same failure class as silently skipping an unsupported-version file with selection-list fields).

`rc up` with no `.rip-cage.yaml` present does **not** require yq — the loader is only invoked when a file is detected.

---

## See also

- [ADR-021](../decisions/ADR-021-layered-rip-cage-config.md) — substrate decisions (file location, merge rules, schema versioning, regression contract)
- [ADR-001](../decisions/ADR-001-fail-loud-pattern.md) — fail-loud pattern (why `yq` missing aborts; why selection-list version-drift aborts)
- [SSH Identity Routing](ssh-routing.md) — orthogonal `~/.config/rip-cage/identity-rules` for github.com identity pinning
