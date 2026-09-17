# Reference — index

Mechanism reference for rip-cage: what each moving part does, field by field. **How to do a thing** lives in the three skills, which are the front door:

- [`cage-config`](../../.claude/skills/cage-config/SKILL.md) — write or repair the one config file a cage launches from.
- [`cage-image`](../../.claude/skills/cage-image/SKILL.md) — extend the base image with your own Dockerfile and boot fragment.
- [`cage-ops`](../../.claude/skills/cage-ops/SKILL.md) — run and troubleshoot a live cage; the sole home of the deleted-verb successor table.

---

## What you compose

rip-cage is a **composable seam, not a bundler** ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)). It owns the containment floor and the mechanical seams; it never names or blesses an optional tool. There are exactly three things you author, and all three live host-side, outside every cage mount ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5a):

| Input | What it decides | Where it lives | Reference |
|---|---|---|---|
| **Your Dockerfile** | What is *in* the image — tools, runtimes, guards, multiplexers | anywhere host-side; `rc build --file <path>` | [`cage-image`](../../.claude/skills/cage-image/SKILL.md) |
| **A boot descriptor fragment** | What *starts* at boot — long-running daemons, multiplexer providers | baked into your image | [in-cage-daemon.md](in-cage-daemon.md) |
| **The project config** | What the cage *gets* — mounts, secrets, egress, resources | `~/.config/rip-cage/projects/<cage>.yaml` | [config.md](config.md) |

Your Dockerfile starts `FROM rip-cage:latest` and adds `RUN` lines. There is no manifest, no codegen, no declaration validator — the floor is checked on the **built image** by a probe that inspects the artifact, because a check that reads a description can be lied to by the description ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D4/D5).

Worked recipes live in [`examples/`](../../examples/README.md), outside the binary and never special-cased.

## A fourth file you do not author

`share/rip-cage/protected-paths` is a shipped list of known credential locations. `rc up` refuses to launch a config that mounts one of them, covers any it finds inside a mounted tree, and aborts before any msb call if the list is unreadable. It is operator-editable *configuration*, not code — but it is not part of a cage's composition, and no cage config can point at it ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2/D5).

---

## Reference docs

### Setup
| File | What it covers |
|---|---|
| [auth.md](auth.md) | OAuth token extraction (macOS keychain / Linux), API-key fallback, pi's providers, how the credential reaches the cage without entering it |
| [whats-in-the-box.md](whats-in-the-box.md) | What the base image carries, the cage user model, sudo scope |
| [cli-reference.md](cli-reference.md) | The six verbs — `up`, `auth`, `doctor`, `build`, `test`, `destroy` — their flags and JSON output |

### Configuration
| File | What it covers |
|---|---|
| [config.md](config.md) | The project config field by field: image, resources, mounts, named volumes, `secrets:`, `env:`, `network:` |
| [egress.md](egress.md) | Default-deny egress, the allowlist form, and the deny → fix → relaunch repair loop |
| [git-lfs.md](git-lfs.md) | What rip-cage does and does not fetch for Git LFS; the pointer-stub advisory |

### Safety
| File | What it covers |
|---|---|
| [safety-stack.md](safety-stack.md) | The containment floor, the floor probe, `bypassPermissions`, hard-denied operations, composable command guards |
| [secret-posture.md](secret-posture.md) | Project secrets: the opt-in gradient, the non-possession recipe, membership heuristics, and the dead zones |

### Composition
| File | What it covers |
|---|---|
| [in-cage-daemon.md](in-cage-daemon.md) | The boot descriptor's schema, the daemon lifecycle contract, and the daemon-vs-simpler decision aid |
| [`examples/base/`](../../examples/base/) | The smallest real extension image: `FROM rip-cage:latest`, one `RUN`, one `RUN which <tool>` assertion |

### Operations
| File | What it covers |
|---|---|
| [release-ceremony.md](release-ceremony.md) | Tag → GHCR publish → Homebrew formula pin, the pre-tag gates, the two-repo tap sync |

---

## See also

- [examples/README.md](../../examples/README.md) — the recipe catalog
- [docs/decisions/INDEX.md](../decisions/INDEX.md) — every ADR, with retired-or-evolved status
- [docs/ROADMAP.md](../ROADMAP.md) — what shipped, what is fog
- [README.md](../../README.md) — the quickstart
