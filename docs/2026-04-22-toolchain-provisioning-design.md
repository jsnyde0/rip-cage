# Project Toolchain Provisioning

**Date:** 2026-04-22
**ADR:** [ADR-015](decisions/ADR-015-mise-toolchain-provisioning.md)
**Related:** [ADR-001](decisions/ADR-001-fail-loud-pattern.md) (fail-loud), [ADR-002](decisions/ADR-002-rip-cage-containers.md) (blast radius), [ADR-005](decisions/ADR-005-ecosystem-tools.md) (ecosystem tools pattern), [ADR-012](decisions/ADR-012-egress-firewall.md) (egress allowlist), [ADR-013](decisions/ADR-013-test-coverage.md) (tiered tests)

## Problem

On 2026-04-21, an agent session inside a rip-cage container hit `yarn: command not found` while typechecking a Node project:

```
Bash(yarn --cwd app/frontend typecheck 2>&1 | tail -20)
⎿  (eval):1: command not found: yarn
```

Yarn is not in the rip-cage image. The image ships Node + npm + bun + uv + Python + git + gh + jq + tmux, and nothing else for language ecosystems. The agent eventually unstuck itself with `npx --yes yarn` (which populates `~/.npm/_npx/<hash>/node_modules/.bin/` — first entry in PATH by npm-exec convention), but the cold-start tax was 20+ seconds and the unstick pattern only happens to exist for Node. A Rust, Elixir, Go, Ruby, or Java project would have no equivalent fallback.

The underlying gap: **rip-cage has no general mechanism for "provision the toolchain this project needs."** Today's options are to either bake every conceivable language into the image (bloat; version wrong for half of projects) or for the agent to reinvent installation per project (slow, inconsistent, frequently insecure).

## Goal

When a rip-cage container starts in a workspace, the language toolchain(s) that workspace declares should be available on PATH by the time the agent's first prompt runs — without the user having to configure rip-cage per project, without baking every ecosystem into the base image, and without re-downloading the same toolchain on every `rc up`.

Non-goals:

- System-level packages (`libpq-dev`, `ffmpeg`, `imagemagick`) — out of scope; handled separately if/when a project hits that need.
- Custom binaries that aren't a language runtime (e.g., a project-local CLI you built). Out of scope.
- Deterministic builds across machines (Nix-grade reproducibility). Overkill for the failure mode in play.

## Design

### Mise as image-level plumbing, triggered by standard project files

Mise (a single ~15MB Go binary, formerly `rtx`) is installed into the base image. At `init-rip-cage.sh` runtime, if `/workspace` contains any mise-supported declaration file, the init script runs `mise install` once and activates mise globally. Downloaded runtimes live in a **shared Docker named volume** so that every container on the host — across every project — reuses the same toolchain cache.

The user never runs `mise` directly and does not install it on the host. Mise is an implementation detail of the cage.

**1. Add mise to the runtime stage of the Dockerfile**

Install the pinned version as root, so the binary lives in `/usr/local/bin/mise` (on PATH for all users) before the `USER agent` switch:

```dockerfile
# Mise (project toolchain provisioner) — see ADR-015
ARG MISE_VERSION=2026.4.5
RUN curl -fsSL https://mise.run | MISE_VERSION=v${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && chmod +x /usr/local/bin/mise \
    && /usr/local/bin/mise --version
```

Placed in the runtime stage after `uv` (Dockerfile:36) and before the `gh` block. Pinned to a specific version via `ARG` so reproducible; bumped on a cadence similar to other pinned tools (`BEADS_VERSION`, `DOLT_VERSION`).

Activation for the agent shell happens via `~/.zshrc`. Rip-cage already owns the agent's `.zshrc` (`COPY --chown=agent:agent zshrc /home/agent/.zshrc`, Dockerfile:117), so we add one line to that file:

```zsh
# mise (project toolchain). No-op when no tool files are declared.
eval "$(/usr/local/bin/mise activate zsh)"
```

The `mise activate` hook prepends `$MISE_DATA_DIR/installs/<tool>/<version>/bin` to PATH *when you `cd` into a directory with a tool file*, and removes it when you `cd` out. No-project = no-op.

**2. Shared cache volume for `MISE_DATA_DIR`**

Mise's "installed toolchains" directory is the expensive part. It's a content-addressable cache of language runtimes by version (e.g., `mise/installs/node/22.11.0/`). We mount it as a Docker named volume that is **shared across every rip-cage container**, not per-container like the existing `rc-state-<name>` / `rc-history-<name>` volumes (rc:834-835).

- Volume name: `rc-mise-cache` (literal — not `${_name}`-suffixed).
- Mount point inside container: `/home/agent/.local/share/mise`.
- Added to `_UP_RUN_ARGS` in `cmd_up` (rc:~834) alongside the state/history volumes:

  ```bash
  _UP_RUN_ARGS+=(-v "rc-mise-cache:/home/agent/.local/share/mise")
  ```

- Added symmetrically to the devcontainer `mounts[]` array (rc:214-215, 234-235).

`rc destroy` does **not** delete this volume (`rc-mise-cache` is a host-level cache, not container-scoped — matches the principle `rc destroy` applies to per-container state). A new `rc mise-cache-clear` / `docker volume rm rc-mise-cache` is a manual-only operation; not ADR-worthy.

Ownership: the volume is created on first `rc up` by Docker as root; mise itself runs as `agent` and expects to write there. This mirrors the `~/.claude` + `~/.claude-state` pattern already handled by `init-rip-cage.sh`: a `sudo chown agent:agent /home/agent/.local/share/mise 2>/dev/null || true` in the init script (before mise is invoked) covers the first-boot case. The sudoers entry already permits `chown agent:agent` for known paths — add `/home/agent/.local/share/mise` to that allowlist (Dockerfile:74).

**3. `init-rip-cage.sh` hook**

Insert a new step between step 6 (git identity) and step 7 (Claude Code verification). The block is fail-loud in the spirit of ADR-001 for the detection path, but tolerant for the install path:

```bash
# 7. Project toolchain provisioning (mise)
#    No-op unless /workspace declares tools via .tool-versions / .mise.toml / .nvmrc / etc.
if [ -r /workspace ]; then
  _toolfiles=(.mise.toml mise.toml .tool-versions .nvmrc .node-version .python-version .ruby-version rust-toolchain.toml go.mod)
  _found_tool=""
  for f in "${_toolfiles[@]}"; do
    if [ -f "/workspace/$f" ]; then _found_tool="$f"; break; fi
  done
  if [ -n "$_found_tool" ]; then
    echo "[rip-cage] Toolchain: detected /workspace/$_found_tool — running mise install"
    # Ensure cache volume is writable by agent
    if [ ! -L /home/agent/.local/share/mise ]; then
      sudo chown -R agent:agent /home/agent/.local/share/mise 2>/dev/null || true
    fi
    # Fail-loud on install errors so the agent sees them; but don't block container start —
    # a broken lockfile shouldn't render the whole cage unusable.
    if (cd /workspace && mise install 2>&1 | tee /tmp/mise-install.log); then
      echo "[rip-cage] Toolchain: mise install complete"
    else
      echo "[rip-cage] WARNING: mise install failed (see /tmp/mise-install.log). Toolchain may be unavailable." >&2
    fi
  else
    echo "[rip-cage] Toolchain: no tool-version files detected — skipping"
  fi
  unset _toolfiles _found_tool
fi
```

The tool-file list deliberately skips `package.json` (most Node projects without `engines.node` or `packageManager` shouldn't incur an install), but **does** include `.nvmrc` / `.node-version` / the `packageManager` field (via `mise` auto-detect when `.mise.toml` is absent but `package.json` declares it — mise 2024+ reads `packageManager` natively). If the project wants yarn, they add `packageManager` to `package.json` — a two-character edit in a file they already own.

The `cd /workspace && mise install` pattern runs in a subshell so it doesn't mutate the init script's CWD.

**4. Trust prompt suppression**

Mise has a security feature: `.mise.toml` files in a workspace are not trusted until the user runs `mise trust`. Inside the cage, this is the wrong default — the agent can't respond to a trust prompt, and the trust boundary already exists at the `rc up` moment (you trusted the project enough to mount it into a bypassPermissions container).

Set `MISE_TRUSTED_CONFIG_PATHS=/workspace` via the Dockerfile `ENV` so `/workspace/**/*.mise.toml` and `/workspace/**/.tool-versions` are pre-trusted inside the cage. This is strictly narrower than `MISE_YES=1` (which would auto-confirm all prompts) and scoped to the bind mount only.

### Interaction with existing ADRs

- **ADR-001 (fail-loud):** The detection step is loud (`echo ... detected $_found_tool`). The install step is loud on success *and* failure; failure writes to stderr but does not `exit 1`, so an agent can observe and recover. A hard failure to `exit 1` would mean a broken `packageManager` field crashes the container — worse than the current state where the agent can at least read and fix the file.
- **ADR-002 (blast radius):** No new credentials. Mise fetches binaries over HTTPS from upstream registries (GitHub Releases, nodejs.org, python.org, etc.) subject to ADR-012. The shared cache volume contains only compiled/packaged binaries, no secrets.
- **ADR-005 (ecosystem tools):** Mise follows the same build-arg pinning pattern (`ARG MISE_VERSION`) and is stage-3-runtime (not a separate builder stage — mise.run script is small and doesn't need Go/Rust). It is **not** behind a `--with-mise` flag: it's core infrastructure, not an opt-in ecosystem tool. UBS, RANO, CASS are optional analytical tools; mise is how the cage honors the project's own declarations.
- **ADR-012 (egress allowlist):** Mise needs HTTPS egress to its download endpoints. The relevant domains are already in common use and mostly present in `egress-rules.yaml`: `github.com`, `objects.githubusercontent.com`, `nodejs.org`, `python.org`. A follow-up is required to verify/extend `egress-rules.yaml` for the languages the user intends to use (e.g., `static.rust-lang.org`, `rubygems.org`, `packages.erlang-solutions.com`). This is tracked as a beads issue, not blocking the image change.
- **ADR-013 (tiered tests):** New asserts land at Tier 1 (in-container safety-stack) and Tier 2 (e2e lifecycle) — see Verification below.

### What mise does *not* do

- Install system libraries via apt (out of scope; deferred to a possible future `bootstrap.sh` ADR if/when real demand appears).
- Install project-local CLIs from arbitrary sources.
- Run `yarn install` / `npm ci` / `pip install -r requirements.txt` / `cargo build`. It provisions the **runtime** (`node`, `python`, `rustc`, `yarn` the binary itself) — running the project's own install step remains the agent's job, same as outside a cage.

## Verification

**Tier 1 (safety-stack, `tests/test-safety-stack.sh`):**

- `[ -x /usr/local/bin/mise ]` — mise binary installed.
- `mise --version` exits 0.
- `grep -q 'mise activate zsh' /home/agent/.zshrc` — activation hook present.
- `[ "$MISE_TRUSTED_CONFIG_PATHS" = "/workspace" ]` — trust-path env var set.
- `sudo -n -l | grep -q 'chown agent:agent /home/agent/.local/share/mise'` — sudoers permits the chown fallback.
- Directory existence: `[ -d /home/agent/.local/share/mise ]` (created by the volume mount).

**Tier 2 (e2e lifecycle, lands in `tests/test-e2e-lifecycle.sh` per ADR-013 D1):**

- Create a temp workspace with `/workspace/.nvmrc` containing `20.18.0`.
- `rc up <workspace>` and wait for init to complete.
- Inside the container: `node --version` returns `v20.18.0` (not the image's default Node 22).
- Inside the container: `readlink -f $(which node)` points under `/home/agent/.local/share/mise/installs/node/20.18.0/`.

**Tier 2 cache-reuse regression:**

- Destroy the container from the previous test (`rc destroy -f`). Volume `rc-mise-cache` survives.
- `rc up` the same workspace again. `mise install` runs in <2 seconds (cache hit).

**Regression target:** the exact failing sequence from the problem statement (`yarn --cwd app/frontend typecheck` inside the cage, project declares `packageManager: yarn@1.22.22`) should succeed on first attempt, with no `npx --yes yarn` dance and no `command not found`.

## Implementation sketch

Files to add/change:

- **Edit** `Dockerfile`
  - Add `ARG MISE_VERSION=...` + install block (near the existing `uv` install, Dockerfile:36).
  - Add `ENV MISE_TRUSTED_CONFIG_PATHS=/workspace` near the other `ENV` lines (Dockerfile:23-25).
  - Extend the sudoers line (Dockerfile:74) to permit `/usr/bin/chown agent:agent /home/agent/.local/share/mise`.
  - `RUN mkdir -p /home/agent/.local/share/mise` in the "pre-create mount targets" block (Dockerfile:116) so ownership inherits from `USER agent`.
- **Edit** `zshrc` — append `eval "$(/usr/local/bin/mise activate zsh)"`.
- **Edit** `init-rip-cage.sh` — insert the toolchain-provisioning block between existing step 6 and step 7.
- **Edit** `rc`
  - Add `rc-mise-cache` to `_UP_RUN_ARGS` in `cmd_up` (rc:~834).
  - Add `rc-mise-cache` to the devcontainer `mounts[]` array in `cmd_init` (rc:214-215 and 234-235).
  - **Do not** add `rc-mise-cache` to the `destroy` volume-removal list (rc:~1641, ~1655-1660). The cache survives container destruction.
- **Edit** `tests/test-safety-stack.sh` — add the six Tier 1 checks.
- **Edit** `tests/test-e2e-lifecycle.sh` (or `tests/test-integration.sh` if e2e doesn't exist yet per ADR-013 D1 pending) — add the Tier 2 nvmrc scenario and cache-reuse regression.
- **New** beads issue — verify/extend `egress-rules.yaml` for runtime-download endpoints (nodejs.org, static.rust-lang.org, etc.) as each language is actually used. Not blocking.

No changes to:

- `settings.json` — no Claude Code surface involvement.
- `hooks/block-compound-commands.sh` — mise runs as plumbing, not user commands.
- Host-side code outside `rc` and tests.

## Risks and open questions

- **`packageManager` detection for Node.** Mise reads `package.json`'s `packageManager` field natively only in recent versions. Pin `MISE_VERSION` to a known-good release and re-verify on bumps. If the pinned version lacks this, projects can add a one-line `.mise.toml` instead — equivalent cost.
- **First-boot download cost.** A cold `rc-mise-cache` volume + a project declaring Rust 1.82 will block the init step for 1-2 minutes. Acceptable (first time only; shared thereafter). The init output makes the reason visible (`mise install` log streams to terminal).
- **Egress-rule drift.** A new language the user hasn't used before will hit ADR-012's deny-by-default for its download endpoint and `mise install` will fail. Failure mode is loud (the WARNING line in the init block names the log path). Fix: add the domain to `egress-rules.yaml` and rebuild. Documented.
- **Cache corruption.** A partial download aborted by a container kill could leave `rc-mise-cache` in a bad state. Mise's install is version-keyed per-directory; corruption is localized to that version. Recovery: `docker volume rm rc-mise-cache` (full reset) or `mise uninstall <tool>@<version> && mise install`. Not auto-recovered.
- **Mise version lag vs upstream.** Mise ships frequently. A pin to `2026.4.5` will go stale. Cadence is similar to `DOLT_VERSION` and `BEADS_VERSION` — bumped on demand or quarterly. No auto-update inside the cage (consistent with ADR-002: the image is the trust boundary).
- **`bootstrap.sh` escape hatch deferred.** Projects needing `libpq-dev` or `ffmpeg` have no first-class answer yet. They can run `sudo apt-get install` inside the container manually, or add their own layer via a downstream Dockerfile. A future ADR may codify `.rip-cage/bootstrap.sh`; this design explicitly does not (auto-exec risk; YAGNI until there's demand).

## Not doing

- **Bake every language runtime into the image.** Rejected: bloat, wrong versions, doesn't scale.
- **`.rip-cage/bootstrap.sh` escape hatch now.** Rejected: introduces a new auto-execute-on-container-boot attack surface before any concrete case needs it. Deferred to a future ADR.
- **`asdf` instead of `mise`.** Rejected: asdf is shell-plugin-based (slower activation, bash/zsh-only), mise covers the same registry faster with a native binary. Direct improvement.
- **Nix / flakes.** Rejected: overkill for the failure mode; steep learning curve; massive store; doesn't compose with the existing `apt`-based image. Reconsider if reproducibility requirements ever justify it.
- **Devcontainer Features for toolchains.** Rejected: build-time-only mechanism, doesn't fit the `rc up` model where workspace files drive provisioning at container-start.
- **Lazy install via `command_not_found_handler`.** Rejected: surprising latency on first invocation of any tool; no clean way to pick the right version without declarative input anyway.
- **Mount the host's toolchains.** Rejected: macOS→Linux architecture mismatch; platform coupling defeats the cage.
- **`MISE_YES=1` blanket auto-confirm.** Rejected: too broad. `MISE_TRUSTED_CONFIG_PATHS=/workspace` is the narrower form and sufficient.
