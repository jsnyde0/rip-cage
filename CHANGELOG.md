# Changelog

All notable changes to rip-cage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.0] - 2026-06-30

### Changed

- **pi launch composition is fully manifest-declared** (epic rip-cage-l72i; [ADR-027](docs/decisions/ADR-027-agent-substrate-projection.md) D4, [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12). pi's launch wrapper no longer hardcodes `--no-extensions -e <dcg-gate>` plus a single `SUBAGENT_EXT` slot. A generic `launch_args` list field on `TOOL` fragments is concatenated by `rc build` in fragment order (guard-first) and baked into a generic pi shim — `rc` names no tool and the wrapper hardcodes no path. The DCG guard, the sub-agent extension, and herdr's pi extension are now **identical manifest contributions**; adding an extension is a recipe declaration with **zero `rc` edits**. Because `rc build` is host-side, the "agent drops a hostile extension into a scanned dir" prompt-injection vector is closed **by construction** — no runtime code-inspection validator is needed ([ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md) D4). The DCG guard stays loaded first and tamper-proof (root-owned file **and** parent dir on its own `/etc/rip-cage/pi` load path). (rip-cage-l72i.1)

### Added

- **`examples/herdr-pi/` recipe** (rip-cage-l72i.4) — composes herdr's pi integration extension into a cage: runs `herdr integration install pi` (the public CLI, [ADR-006](docs/decisions/ADR-006-cli-interface.md) D8), relocates the generated extension to a root-owned load path, and declares its `launch_args` + herdr socket-directory mount. This enables herdr semantic working/idle status for caged pi agents — the gap that the hardcoded `SUBAGENT_EXT` slot used to silently swallow.
- **`examples/pi/subagent-fragment.yaml`** (rip-cage-l72i.3) — a self-contained opt-in recipe that mounts the host sub-agent extension and adds its `-e` launch arg. This is the explicit, composable successor to the retired `SUBAGENT_EXT` wrapper slot.
- **herdr binary pin bumped v0.6.10 → v0.7.0** (rip-cage-1pgp.2) in `examples/herdr/` (per-arch SHA-256, fail-closed).

### Removed

- **`SUBAGENT_EXT` hardcoded slot in the pi wrapper** (rip-cage-l72i.3) — pi sub-agent extension dispatch is now **opt-in** via `examples/pi/subagent-fragment.yaml` rather than a hardcoded wrapper slot. The default cage no longer auto-loads a sub-agent extension; compose the recipe to retain it. `grep -ni subagent rc` is now empty — the special-casing is fully retired from `rc`.

## [0.9.1] - 2026-06-29

### Fixed

- **DNS non-QUERY opcode exfil bypass closed** (rip-cage-d9d3). The DNS resolver forwarded non-QUERY opcodes (UPDATE/STATUS/NOTIFY/etc.) straight to upstream with no exfil-heuristic and no mode awareness — a hole in the DNS chokepoint that also reached a configured `forward_to` specialist uninspected. The opcode branch now mirrors the QUERY path: **block mode refuses (never forwards)**, observe mode logs a `would-block` event then forwards, legacy mode passes through silently, and an unrecognized mode coerces to block (fail-closed). ([ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md) D2/D3, [ADR-024](docs/decisions/ADR-024-prompt-injection-threat-model.md) D4)
- **symlink-follow broken-chain detection repaired on macOS, fail-loud end-to-end** (rip-cage-l0bu). A truly-broken symlink chain (missing target parent) was silently missed on macOS — `readlink -f` returns a non-empty partial path with exit 1 there (Linux returns empty), so the empty-stdout-only guard fired on Linux but not macOS; and the consumer swallowed the collector's non-zero exit through a process-substitution loop under `set -e`, so the loud abort never reached the caller ([ADR-001](docs/decisions/ADR-001-architecture.md) D1). Both fixed; broken chains now abort loud on both platforms.
- **symlink-follow `scope: parent` validates the actual mount source** (rip-cage-6uz). In `scope: parent` mode the fingerprint and secret-path denylist now check the parent directory that actually mounts, not the leaf target — restoring the "validate exactly what mounts" invariant ([ADR-023](docs/decisions/ADR-023-symlink-follow.md) D7) and closing the leaf-check hole. (The residual that `parent` exposes the whole directory including sensitive-named leaf files is now documented in `docs/reference/config.md`; prefer `scope: file` for directories holding secrets — rip-cage-hs70.)
- **Spurious config "recreate to apply" hint suppressed** (rip-cage-1f59.9) when a field is absent from an older config snapshot but the live value already equals the schema default ([ADR-021](docs/decisions/ADR-021-rip-cage-yaml.md) D5).
- **`rc up` Claude-OAuth warnings reworded to an agent-neutral tone** (rip-cage-5kt) so they read sensibly for pi-only / API-key-only users (still actionable for Claude users; the warning is kept, not suppressed).

### Added

- **tmux recipe: copy-on-select via OSC 52** (rip-cage-q5i) — drag-select + release relays the selection to the host clipboard with no Cmd-C and no `y` keystroke. Opt-in recipe polish (`examples/tmux/`), not core-cage UX.

### Removed

- **VS Code devcontainer usage path removed** (rip-cage-kt25). The `.devcontainer/` path was legacy; `rc up` is the supported entry. (`.devcontainer/` / `.vscode/` remain gitignored.)

## [0.9.0] - 2026-06-25

### Changed

- **Agents, command-guards, and substrate collapse to two composable seams: `TOOL` + per-asset ro/rw mount** (epic rip-cage-wlwc; [ADR-025](docs/decisions/ADR-025-host-adoptable-dcg-policy.md) D2, [ADR-027](docs/decisions/ADR-027-agent-substrate-projection.md) D1/D3, [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12). There is no longer a bespoke AGENT archetype or an `agents.enabled` switch — an agent (Claude Code, pi) and its command-guard are each just a `TOOL` manifest recipe plus per-asset read-only / read-write mounts. Composing or swapping one is "edit the manifest, `rc build`" with **zero `rc` edits** and no `compose:` directive or auto-wiring (the agent does the wiring per ADR-005 D12). The welded floor is now strictly **containment** (container boundary, egress firewall, fs sandbox, non-root + scoped sudo, secret-path denylist, git-hooks RO weld, ssh known_hosts). (rip-cage-wlwc.2/.3/.9/.12)
- **DCG and the ssh-bypass blocker demoted from baked-in floor to composable recipes** ([ADR-025](docs/decisions/ADR-025-host-adoptable-dcg-policy.md) D2, [ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md) D2). dcg is now a from-source `TOOL` recipe (`examples/dcg/`, cargo-install at a pinned tag) and the ssh-bypass hook a composable recipe (`examples/ssh-bypass/`); **both are un-baked from the base image**, and their wiring rides a root-owned, separate load path — ownership (not mere presence) is what makes the guard wiring un-tamperable. The default published image still composes **CC + pi + dcg + ssh-bypass** via the default manifest; blessing happens at the distribution layer, not in `rc` code or the seam. (rip-cage-wlwc.10/.11/.12)
- **Guard floor-lock unified; the per-agent root-own + sudo "olen" machinery retired** ([ADR-027](docs/decisions/ADR-027-agent-substrate-projection.md) D1/D3, [ADR-002](docs/decisions/ADR-002-rip-cage-containers.md) D5). Each agent's guard wiring is delivered as a root-owned asset on its own cage-owned load path — the Claude Code DCG guard via root-owned managed-settings, the pi guard relocated to `/etc/rip-cage/pi` (root-owned file **and** parent dir) — replacing the previous per-agent ownership+sudo snowflake. pi's workspace-path extension auto-discovery bypass is closed; the `/usr/bin/pi` direct-binary launch remains a documented best-effort residual (containment holds underneath). (rip-cage-wlwc.4 / rip-cage-sn1h / rip-cage-r9n4)
- **`rc test` and the in-cage safety suite name zero specific guards** (rip-cage-m8zc, rip-cage-wiwa; [ADR-005](docs/decisions/ADR-005-ecosystem-tools.md) D12/D13). Drop-detection rides a generic per-tool `required` / `assert_loaded` manifest declaration (a baked, root-owned assert file), and each recipe carries its own behavioral smoke test (`examples/<recipe>/smoke.sh`) run by a generic name-free runner — so adding a guard recipe needs no `rc` edits.
- **Egress reshaped from a TLS-MITM proxy into a pure SNI destination router** (epic rip-cage-ta1o; [ADR-026](docs/decisions/ADR-026-containment-mediation-identity.md), [ADR-012](docs/decisions/ADR-012-egress-firewall.md) D2/D4/D5/D6). HTTP/HTTPS egress no longer terminates TLS or installs a rip-cage CA — the router reads the SNI in the clear, allow/denies the **destination host**, and splices the still-sealed bytes through. The agent now sees the **real upstream certificate**; no `NODE_EXTRA_CA_CERTS` / rip-cage CA is installed. Force-through (iptables capture + startup on-path selftest), destination allow/deny, the IOC floor, and the DNS sidecar all carry over. Content-layer enforcement (method/path, credential injection) is delegated to a **composed external mediator** — see the new `docs/reference/composition-seam.md` + `examples/compose-rc-with-clawpatrol.md`. (rip-cage-ta1o.1/.3)
- **DNS resolver gains a `network.dns.forward_to` forward-to-specialist seam** — clean queries (those the built-in exfil heuristic passes) can forward to a configurable upstream resolver (NextDNS / Umbrella / dnsdist / Zeek / a local forwarder) instead of the default `8.8.8.8`. Tool-agnostic (a configurable address, not a blessed product). The built-in heuristic and port-53 force-through are unchanged. (rip-cage-ta1o.2; [ADR-012](docs/decisions/ADR-012-egress-firewall.md) D9)

### Removed

- **AGENT archetype and the `agents.enabled` config key** (BREAKING) — removed in epic rip-cage-wlwc. The AGENT archetype, the `agents.enabled` schema row, the `rc.agents` image label, the `/etc/rip-cage/agents/<name>/` bake, and the AGENT-only guard validators are all gone; an `agents:` / `agents.enabled` block in your config is no longer recognized. Agents are now expressed as `TOOL` recipes + ro/rw mounts (see Changed above). (rip-cage-wlwc.9)
- **DCG and ssh-bypass no longer baked into the base image** (BREAKING) — a from-source or custom `rc build` that does not compose the dcg / ssh-bypass recipes produces a cage **without** those command-guards. The default published `rip-cage:latest` is unaffected (it composes both via the default manifest); custom manifests must add the `examples/dcg/` and `examples/ssh-bypass/` entries to retain them. The containment floor is unchanged. (rip-cage-wlwc.10/.11)
- **`network.writable_hosts` method-axis write-gate** — removed with the TLS-MITM stack it depended on (a pure SNI router can't see HTTP method/path). A `writable_hosts:` block in `.rip-cage.yaml` is now silently ignored. Method-asymmetry was leaky theater (GET still leaks via DNS / URL-query / allowlisted-API abuse) and is superseded by destination-only routing; per-request method/path policy returns when an external mediator is composed. (rip-cage-ta1o.1; [ADR-012](docs/decisions/ADR-012-egress-firewall.md) D2)

## [0.8.0] - 2026-06-15

### Changed

- **In-cage multiplexer is now a manifest-declared composable provider** — `rc` no longer hardcodes the multiplexer set. Adding a multiplexer (tmux, herdr, zellij, …) is a manifest entry with **zero edits to `rc` / `init-rip-cage.sh`**: `rc build` bakes each declared provider's hooks into the image (`/etc/rip-cage/multiplexers/<name>/<hook>`), the `session.multiplexer` allowed-set is derived dynamically from the baked registry (surfaced as the `rc.multiplexers` image label) rather than a hardcoded enum, and `rc` dispatches by name through that registry. A fixture multiplexer named nowhere in the source drives build → validate → start → attach end-to-end, and `grep 'tmux\|herdr' rc init-rip-cage.sh` is empty. The provider hooks are bounded at build by the fail-closed validator (they cannot weaken the welded CONTAINMENT floor). Realizes ADR-005 D12 (rip-cage is a composable seam, not a bundler); see ADR-005 D7 (MULTIPLEXER archetype) + D9 (realized mechanism). (epic rip-cage-61al)

### Removed

- **`rc agent` and `rc sessions`** — both commands were removed in epic rip-cage-1f59 (2026-06-13). They are no longer in the command dispatch, `--help`, schema, or completions. The in-cage multiplexer (`session.multiplexer: none | <any manifest-declared provider>`, ADR-021 D6) is the successor for spawning, listing, and supervising agent sessions inside a cage. `rc exec` (`rc exec <cage> -- <cmd>`) is the rip-cage box-entry replacement for running an arbitrary command inside a running cage (ADR-006 D7 re-decision). See ADR-006 D7 for the full rationale.

- **tmux unbaked from the default cage image** (BREAKING) — `tmux` is no longer installed in the Dockerfile's system-package stage, and `tmux.conf` is no longer COPY'd into the image. **Users relying on `session.multiplexer: tmux` with a default `rip-cage:latest` build will find `tmux` absent after `rc build`.** Migration: add a tmux entry to your manifest (`~/.config/rip-cage/tools.yaml`) using the example at `examples/tmux/`, then run `rc build` to bake tmux into your cage image. The `examples/tmux/tmux.conf` is the exact config previously shipped in the image. The init missing-multiplexer path (B1a/B1b) will fail loud and point at this migration. (ADR-005 D12; rip-cage-61al.5)

- **herdr removed from the default manifest** (BREAKING) — herdr is no longer seeded in `_manifest_default_yaml`. **Users relying on the default `rc build` to install herdr will find it absent after the next seed (first-run or explicit manifest reset).** Users with an existing `~/.config/rip-cage/tools.yaml` that already contains a herdr entry are unaffected. Migration: add the herdr entry to your manifest using the example at `examples/herdr/`, then run `rc build`. The default cage is now core-only: `beads`, `dolt`, `gh`, `claude`, `pi`, `dcg` — all bundled with no extra download steps. (ADR-005 D12; rip-cage-61al.5)

## [0.7.0] - 2026-06-12

This release rolls up everything user-facing since 0.5.3 — including the work tagged as 0.6.0, which never got its own changelog entry. Two big themes: **agent-first tool composability** (the cage now bakes in host-defined tools through a declarative, fail-closed manifest instead of hardcoded Dockerfile stages) and **concurrency** (`rc up` cages now run multiple Claude and multi-agent sessions side by side). The base OS also moves to Debian 13 trixie.

### Added

- **Declarative host-only tool manifest** — `rc build` now bakes host-defined tools into the cage from a manifest under `~/.config/rip-cage`, instead of every tool being a hand-wired Dockerfile stage (ADR-005 D7–D11, epic rip-cage-4c5 + rip-cage-buuo). Three tool archetypes are supported: plain `TOOL` binaries, `SHELL-INTEGRATION` tools that bake an eval line into `.zshrc` at build time, and `IN-CAGE-DAEMON` tools with full lifecycle plumbing. Each tool carries a per-tool egress declaration that the firewall floor enforces, and a `mounts[]` field that mounts host paths (with `~` / `$HOME` expansion) into the cage at `rc up`. The manifest is host-only by design — a host-side agent under human supervision can draft entries, but the in-cage agent can never reach or modify it (ADR-024, ADR-005 D7).
- **From-source tool builds** — a manifest entry can declare a `build_source` (builder image + host-side build script + output path) and rip-cage generates one isolated builder stage that COPYs out only the artifact, keeping the build toolchain out of the runtime image. Arch-adaptive (no hardcoded `--platform`), so it builds native-arch on Apple Silicon and amd64 alike (rip-cage-buuo.2).
- **Fail-closed manifest validator** — every build path that can produce a from-source tool (both `rc build` and the `rc up` auto-build path) now runs build-isolation assertions (no bind/VOLUME/ssh/secret leakage into the build) before the build and a binary-root-owned check after it, untagging any tainted image. A non-compliant tool is rejected loud, not silently shipped (ADR-005 D11 FIRM; rip-cage-buuo.1/.3/.6).
- **Tool-authoring skill** — a repo-shipped skill (`rip-cage-tool-manifest-author`) lets a host-side agent, pointed at a target tool, draft a manifest entry (and build script for the from-source case) as human-reviewable files. The human approves before `rc build`; the validator enforces the safety contract (ADR-005 D11 mechanism 3; rip-cage-buuo.4).
- **`am` / agent_mail as the worked-example in-cage daemon** — agent_mail ships as the real `IN-CAGE-DAEMON` worked example (docs + fixture, not a seeded default). Bash-only agents (pi) reach it through its own `am` CLI over their bash tool (`am mail send` / `am mail inbox` / `am mail read`, `am agents register`), and MCP-capable agents (Claude) reach it via an `mcp_fragment` — canonicalized as ADR-019 D9: in-cage daemons are reached by CLI-over-bash for bash-only agents, never via an MCP bridge (rip-cage-gucm, rip-cage-swv).
- **`cm` (cass-memory) as an opt-in manifest tool** — the cass-memory CLI is available in cages that opt in via a from-source manifest entry. The host L2A memory store mounts read-write into the cage, `cm context` / `cm playbook add` operations round-trip back to the host store, and the in-cage binary makes zero external network connections. `cm` started this release as a hardcoded Dockerfile stage (rip-cage-l0u2) and is now re-expressed purely through the generic manifest mechanism — the default cage no longer bakes it in (ADR-005 D2/D6).
- **Per-session Claude config isolation** — `rc up` cages now support multiple concurrent `claude` sessions. A wrapper resolves `CLAUDE_CONFIG_DIR` per tmux session and seeds each session its own config dir (shared inputs symlinked, `.claude.json` seeded from a stable container-local snapshot taken at init), fixing the non-atomic `.claude.json` write that previously dropped a second concurrent agent into a "configuration file not found" loop. Interactive sessions also get their git author identity from the session handle (rip-cage-p1p, ADR-006 D7).
- **`rc agent` multi-agent lever** — `rc agent <cage> --name=<handle> -- <command>` spawns a named tmux session running a command verbatim inside a running cage (Tier 1a parallel agents in one cage). Argv is passed through intact, a duplicate `--name` is refused without clobbering the existing session, and existing `rc sessions` / `--kill` / `rc attach` manage the spawned agents (no new kill surface). Combined with the per-session isolation above, `rc agent --name -- claude` gets config isolation for free (rip-cage-tlm, ADR-006 D7).
- **Egress firewall startup self-test** — the cage now verifies the egress firewall is *actually enforcing* (not merely that rules are present) and refuses to start on a confident fail-open. It probes a guaranteed-unroutable address through a locally-generated marker, so a kernel or backend change that silently no-ops the traffic REDIRECT is caught at startup instead of leaving the cage open with every status light green. Enforced in `block`/`legacy` modes; ambiguous results warn-and-proceed so it never false-alarms (rip-cage-fft, ADR-012 D11).
- **Getting Started guide** — `docs/guides/getting-started.md`: a throwaway-first first-run walkthrough covering what `rc up` does, the cage denying destructive commands, and the daily-loop command table. Linked from the README quick start.
- **ADR-024 D6 — MCP posture**: CLI-over-bash is the blessed in-cage integration path; third-party / user-added MCP servers remain allowed-but-unsupported (in-cage MCP egress is already caught by the firewall, so the only named residual is host-placed MCP). No MCP trust machinery is built (rip-cage-b4c).
- **`rc agent` / `rc sessions` shell completion** — both commands now complete running-container names in bash and zsh.

### Changed

- **Base OS bumped Debian 12 bookworm → Debian 13 trixie** (glibc 2.41). Both the Go (beads) and Rust (DCG) builder stages move to trixie too, so they compile against the same ICU 76 / glibc the runtime ships — removing a four-major-version ICU ABI shim (ADR-002 D2a).
- **Default cage no longer bakes in `cm`** — the cass-memory builder stage and runtime COPY are gone; a no-manifest cage is the previous default image minus cm. cm is now opt-in via the manifest (see Added).

### Fixed

- **Egress firewall stays enforcing on trixie** — Debian 13 defaults `iptables` to the nft backend, which would silently no-op the firewall's nat REDIRECT rules and fail *open*. rip-cage now pins the legacy backend at build time (`update-alternatives --set iptables iptables-legacy`), keeping the firewall armed; the startup self-test above is the backstop if this pin ever fails (ADR-012 D10).

### Documentation

- ADR-005 evolved through D7–D11: host-only manifest, generic from-source builder stage, fail-closed validator (with the FIRM clause that the validator must be wired into *every* build path, not just `rc build`), and the agent-first authoring skill. ADR-019 D9 (bash-only agents reach in-cage daemons via CLI over bash). ADR-024 D6 (MCP posture). ADR-006 D7 (Tier 1a session-granularity multi-agent levers + presence-only status). ADR-002 D2a (trixie forward base) and ADR-012 D10/D11 (iptables-legacy pin + effect-based egress self-test).
- Reference docs added/updated for the tool manifest, agent-mail daemon (`am` CLI surface + `serve-http` mode), and `cm` (opt-in-via-manifest mount mechanics).

## [0.5.3] - 2026-06-04

### Added

- **pi cold-start verified + fixed**: `rc up` seeds `~/.pi/agent/auth.json` with `{}` when absent so a first-run in-cage `pi /login` persists across rebuilds without re-login (rip-cage-wo9). Persistence verified against pi source (`auth.json` is written in place via `writeFileSync`, so a single-file bind mount round-trips to the host) and unit-tested in `tests/test-pi-cold-start-seed.sh` (cold / empty-dir / idempotent / dangling-symlink cases). The auth-present path was previously confirmed on real Apple Silicon hardware (v0.5.0).

### Fixed

- **`rc test` portability**: the DCG additive-rule safety check baked its sentinel fixture into the image instead of reading it from `/workspace`, so `rc test <container>` no longer spuriously fails in any cage that isn't the rip-cage repo's own (rip-cage-16t).
- **e2e auth-warn coverage**: the auth-warn checks asserted against empty `docker logs` (init output goes to `rc up` stdout), so the "no warning" branches passed trivially; they now assert on real captured init output, and a deterministic no-auth case exercises the "WARNING present" branch (rip-cage-igm, rip-cage-f4i).

### Documentation

- Documented the hook-layer enforceability limitation in ADR-002 D5: PreToolUse hook *registration* lives in agent-writable `~/.claude/settings.json`, so the command-hook layer is loaded-by-default, not tamper-proof; the network (egress) and filesystem/container layers are independent of it (rip-cage-2uv). Doc-hygiene: removed dead ADR-001 links and the stale "push-less defaults" claim (rip-cage-pr0).

## [0.5.2] - 2026-06-03

### Removed

- **Compound-command blocker** (`hooks/block-compound-commands.sh`) removed from the in-container safety stack (both Claude Code `settings.json` and pi `dcg-gate.ts`). The blocker's only real protection was permission-allowlist bypass (Claude Code prefix-matches only the first command in a chain), which is moot under `bypassPermissions` — the cage default since rip-cage 0.4.x. The destructive-command class is fully covered by DCG regardless of chaining: DCG rules are unanchored whole-command regexes, verified live against `echo hi && rm -rf ~`, `ls; rm -rf /important`, and `git status && git reset --hard HEAD~5` — all DENY. `block-ssh-bypass.sh` is likewise chaining-robust. Regression tests 11f/11g/11h in `test-safety-stack.sh` lock in DCG and ssh-bypass chaining-robustness. See ADR-002 D5.

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

[0.7.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.7.0
[0.6.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.6.0
[0.5.3]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.3
[0.5.2]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.2
[0.5.1]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.1
[0.5.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.5.0
[0.4.2]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.2
[0.4.1]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.1
[0.4.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.4.0
[0.3.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.3.0
[0.2.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.2.0
[0.1.0]: https://github.com/jsnyde0/rip-cage/releases/tag/v0.1.0
