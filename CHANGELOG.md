# Changelog

All notable changes to rip-cage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2026-06-03

Smoother first run. A fresh `brew install` no longer needs a separate setup step before the first cage starts.

### Changed

- First `rc up` now **auto-seeds** the default secret-path denylist config instead of failing loud and directing the user to run `rc install`. Previously a new machine hit a chain of setup stops — and the sharp one was self-inflicted: rc told you to run `rc install`, which is exactly what made the next `rc up` fail on a missing `yq`. The seeded default only ever *adds* blocking (never widens capability), so it satisfies the "a valid config must exist before the mount matcher runs" invariant rather than bypassing it; seeding runs *before* config validation so the `yq` check still covers it (ADR-023 D6 evolved). `rc install` / `rc config init` remain for re-seeding and customization.

### Added

- `yq` is now a declared Homebrew dependency. It is required to parse rip-cage config, but `brew install rip-cage` previously didn't pull it, so the first `rc up` after a config existed failed on a missing parser.
- `rc doctor --host` now reports `yq` presence and global-config presence, surfacing fresh-device prerequisites up front instead of one failed `rc up` at a time.

### Fixed

- The `yq`-missing error no longer misleadingly references `.rip-cage.yaml`; it names `yq` as a rip-cage config dependency with install instructions.

## [0.5.0] - 2026-06-02

Security-layer expansion. The destructive-command guard becomes host-extensible without weakening its baked-in floor, the pi-coding-agent reaches guard parity with Claude Code, and the pi credential mount tightens to a container-local layout.

### Added

- **Host-adoptable DCG policy** — a project's `.rip-cage.yaml` can now add destructive-command rules above the baked-in guard floor via `dcg.*` fields. The additive layer is read-only and floor-uncrossable: host config can only tighten the guard, never disable or downgrade a baked rule (ADR-025). The cage routes through a CWD-anchoring `dcg-guard` wrapper that neutralizes the agent-writable `/workspace/.dcg.toml` self-disable hole.
- **pi-coding-agent DCG + compound-command parity** — pi cages now block the same destructive commands (`rm -rf`, `git reset --hard`, force-push, …) and chained commands (`&&`, `;`, `||`) that Claude Code cages do, via an image-baked `dcg-gate.ts` extension auto-loaded from a cage-owned path (ADR-019 D8).

### Changed

- **pi config is now container-local** — the pi agent directory lives at `/home/agent/.pi/agent` inside the cage; only `auth.json` bind-mounts (read-write) from the host, replacing the whole-directory mount (ADR-019 D1).

### Security

- Secret-path mount denylist now also covers the symlink-follow mount surface (its 5th surface; ADR-023).
- `dcg.custom_rule_paths` entries are sanitized against `../` path traversal before use.

### Fixed

- CI now reports every failing test instead of aborting at the first, and runs through a single test driver against a pinned `shellcheck` image so local lint == CI lint by construction (no more divergence-burned tags).

## [0.4.2] - 2026-05-28

### Fixed

- `rc` is now clean under the release CI's shellcheck (0.9.0). v0.4.2 is the first release of the prompt-injection security upgrade that ships a pre-built multi-arch GHCR image. v0.4.0 and v0.4.1 install identically via Homebrew but fall back to a local image build on first `rc up` (their release CI lint failed, so no image was published — SC2116 in v0.4.0, then SC2015 in v0.4.1 surfaced by the older CI shellcheck).

## [0.4.1] - 2026-05-28

### Fixed

- Removed a useless `echo` subshell in the `rc allowlist promote` path (`shellcheck` SC2116).

## [0.4.0] - 2026-05-28

Prompt-injection security upgrade. The egress layer flips from a denylist of known-bad hosts to a default-deny host allowlist, DNS becomes a first-class exfil surface, SSH is scoped into the allowlist, and a workspace-trust validator refuses hostile config at cage start. Threat model canonicalized in ADR-024.

### Added

- Default-deny egress: `network.allowed_hosts` whitelist with `observe` / `block` / `legacy` / `off` modes (ADR-012 D1 evolved). A non-allowlisted HTTP(S) host is refused with a structured 6-field stderr body (pattern, target, why, fix_command, config_file, config_path) that the in-cage agent can read and act on.
- `network.writable_hosts` — method-axis write-gating: a host can be read-only (GET/HEAD pass) while POST/PUT/etc. are refused (ADR-012 D6).
- DNS-exfil resolver sidecar: a transparent port-53 REDIRECT routes `dig` / `nslookup` / `ping` / `host` through an in-cage Python resolver that refuses subdomain-encoded exfil shapes (over-long labels or high per-second cardinality) against non-allowlisted apexes. Mode-aware like the HTTP layer (ADR-012 D9).
- SSH scoped into the egress allowlist: TCP-22 to non-allowlisted hosts is refused, closing the git-mirror exfil path (ADR-012 D8 evolved).
- QUIC / HTTP3 blocked (UDP-443 DROP) so traffic can't slip past the inspecting proxy.
- Workspace-trust validator: `rc up` refuses to start when `.claude/settings.json` redirects `ANTHROPIC_BASE_URL` to a non-trusted host, naming the key and value; `--allow-config-override` is the escape hatch (ADR-024).
- Agent-first allowlist CLI: `rc allowlist add` / `remove`, `rc doctor` egress sections, an `rc ls` mode column, and `rc promote --from-observed` to lift observed would-block hosts into the allowlist.
- ADR-024 — prompt-injection threat model (named exfil and on-device-harm vectors).

### Changed

- `rc reload` now bounces the egress proxy and DNS sidecar so allowlist/mode changes reach the running processes (both cache their rules at startup). Previously a host added inside the cage and reloaded stayed blocked until teardown — an autonomy bug this release fixes.
- Build resilience: npm per-request timeout capped at 90 s plus bounded retry loops around the Claude Code and pi installs, so a flaky registry fails in minutes instead of stalling a build for up to ~80.

### Known limitations

- pi cages get container isolation and the egress firewall, but not yet the command-level DCG / compound-blocker enforcement that Claude Code cages get. On-device-harm parity for pi is still in research; see "Pi safety model" in `docs/reference/auth.md`.

## [0.3.0] - 2026-05-22

### Added

- Secret-path denylist: host-side validation refuses mounting secret-heavy paths (e.g. `~/.aws`, `~/.ssh`) by default; `--allow-risky-mount` is the escape hatch (ADR-023). Closes the most common accidental-mount miss without proxy infrastructure.
- `rc install` command for first-time setup.
- Multi-session picker on `rc up <path>` and `rc attach <cage>`: when one or more tmux sessions already exist, a numbered list is shown (most-recently-attached first) with a `[new] new session` option. Enter reattaches the most-recent; no picker on the first `rc up`. `rc up --new` always creates a new auto-named session; `rc up --session NAME` attaches or creates by name; `rc sessions <cage>` lists active sessions (`--json`, `--kill NAME`, `--force`).
- `mounts.symlinks.*` config + host-side symlink resolution.

### Changed

- ADR-006 D1 evolved in place: Tier 1 (multiple containers) renamed Tier 1b; new Tier 1a (parallel tmux sessions in one cage) added. Cascade applied to `docs/2026-03-27-multi-agent-architecture.md` and `docs/ROADMAP.md`.
- `tmux.conf` gains `remain-on-exit on` and `pane-died 'respawn-pane -c /workspace'` as build-time globals (moved from `init-rip-cage.sh` runtime stanzas so picker-spawned sessions benefit).
- pi cage-topology written to cage-owned paths (stopped writing to `/pi-agent/AGENTS.md`).

## [0.2.0] - 2026-05-14

Super-easy install: rip-cage now ships via Homebrew, and first-run pulls a pre-built image from GHCR instead of building locally.

### Added

- Homebrew formula: `brew install jsnyde0/rip-cage/rip-cage` (ADR-008 D8 — single-repo tap pattern)
- `rc up` pulls the pre-built image from `ghcr.io/jsnyde0/rip-cage:<VERSION>` before falling back to local `docker build` (ADR-008 D6). Cuts first-run from 5–10 min to ~30 s.
- `RIP_CAGE_IMAGE_REGISTRY` env var to override the GHCR registry path or opt out of pull entirely (set to empty string for "always build locally").
- `scripts/update-formula-sha.sh` — release-helper that computes the sha256 of the current VERSION tarball and patches `Formula/rip-cage.rb` after a tag push.
- Multi-arch Docker image publish (`linux/amd64,linux/arm64`) — Apple Silicon no longer falls back to Rosetta.
- zsh + bash completions are now installed automatically by the Homebrew formula (from-source users still run `rc setup`).

### Changed

- README install lead is now `brew install jsnyde0/rip-cage/rip-cage`; the git-clone-and-symlink path moves to "From source."
- README quick-start no longer claims "builds the image automatically" — names the GHCR pull-first behavior with local-build fallback.
- CONTRIBUTING.md acknowledges that `rc build` is now the contributor path (end users pull from GHCR).
- ADR-008 D6 (pre-built image on GHCR) marked implemented at v0.2.0.
- ADR-008 D7 (install method) primary install changed from "symlink" to "Homebrew formula"; symlink retained as from-source path.
- ADR-008 Deferred section: "Homebrew formula" and "Multi-platform images" bullets removed (both now shipped).
- ADR-008 D8 (new, FLEXIBLE): documents the single-repo tap shape with full Alternatives table.
- ADR-002 D24 and ADR-011 D1 updated in place to reflect the new install paths and completion bundling.

### Release ceremony notes

- GHCR packages default to **private** on first push. After the v0.2.0 tag triggers the release workflow, set visibility to Public at `https://github.com/users/jsnyde0/packages/container/rip-cage/settings`. Until then, unauthenticated `docker pull` from end users fails silently and falls back to local build.
- The formula's stable `sha256` is updated post-tag via `scripts/update-formula-sha.sh`. Between the tag push and the sha256-update commit, `brew install jsnyde0/rip-cage/rip-cage` against the stable url is briefly broken; `brew install --HEAD jsnyde0/rip-cage/rip-cage` covers that window.
- Between this epic merging to main and the v0.2.0 tag being pushed, `brew install --HEAD` users' first `rc up` will try `docker pull :0.2.0`, get a 404, and fall back to local build. Resolves on tag.

## [0.1.0] - 2026-04-13

First public release of rip-cage — a Docker-based sandbox for running Claude Code
agents safely in full auto mode.

### Added

- `rc` CLI with commands: `build`, `init`, `up`, `ls`, `attach`, `down`, `destroy`, `test`, `schema`
- Multi-stage Dockerfile: Go (beads) → Rust (DCG) → Debian runtime
- Two usage paths: VS Code devcontainer (`rc init`) and headless CLI (`rc up`)
- Bind-mount workspace: file changes sync instantly, no git push needed
- Safety stack with two layers:
  - DCG (Rust binary) — blocks destructive shell commands
  - Compound command blocker (Perl) — denies `&&`, `;`, `||` chains to prevent allowlist bypass
- `settings.json` with auto mode, allowlisted safe commands, and `PreToolUse` hooks
- 32-check safety stack smoke test (`rc test`)
- OAuth credential extraction from macOS Keychain for container auth
- Git worktree support with corrected `.git` pointer inside the container
- Read-only `.git/hooks` bind mount to prevent hook tampering (D11)
- Resource limits: CPU, memory, and PID caps via `--cpus`, `--memory`, `--pids-limit`
- `--output json` for machine-readable output on all major commands
- `--dry-run` for `up` and `destroy` to preview actions without executing
- `--version` / `-V` flag to print the current version
- `VERSION` file as single source of truth for the version number
- Beads issue tracker integration (embedded and server Dolt modes)
- `rc.conf` for configuring allowed project roots
- Container user model: non-root `agent` user with restricted sudo paths

[0.5.1]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.1
[0.5.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.0
[0.4.2]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.2
[0.4.1]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.1
[0.4.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.0
[0.3.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.3.0
[0.2.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.2.0
[0.1.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.1.0
