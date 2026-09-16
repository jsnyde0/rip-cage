# Stage 1: Go builder for beads (bd)
FROM golang:1.26-trixie AS go-builder
ARG BEADS_VERSION=v1.1.0
RUN apt-get update && apt-get install -y libicu-dev libzstd-dev pkg-config git && rm -rf /var/lib/apt/lists/*
# Clone + build (not `go install @latest`): upstream's go.mod carries a `replace`
# directive, which `go install` rejects unless the module is the main module.
RUN git clone --depth=1 --branch ${BEADS_VERSION} https://github.com/steveyegge/beads.git /src/beads \
 && cd /src/beads \
 && go build -o /go/bin/bd ./cmd/bd

# Stage 2: Runtime (previously Stage 3+4; rust-builder removed in rip-cage-wlwc.10 — dcg is opt-in via manifest ADR-025 D2/ADR-005 D12)
# Stage 4: Runtime — sentinel for manifest from-source builder stage injection (rip-cage-buuo.2)
FROM debian:trixie

ARG CLAUDE_CODE_VERSION=latest
ARG PI_VERSION=latest
ARG BUN_VERSION=1.3.14

# Terminal / locale — needed for Claude Code's TUI to render correctly in a terminal multiplexer
ENV TERM=xterm-256color
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV MISE_TRUSTED_CONFIG_PATHS=/workspace

# System packages
# iptables/ip6tables-legacy + dnsutils were installed for the in-cage egress
# firewall/DNS-resolver engine (rip_cage_router.py/rip_cage_dns.py,
# init-firewall.sh) -- retired per ADR-029 D2 (containment is msb's job now).
RUN apt-get update && apt-get install -y \
    curl wget git ssh openssh-client zsh jq sudo \
    build-essential pkg-config libicu-dev libzstd-dev \
    python3 python3-venv perl ca-certificates gnupg \
    openssl procps xxd \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && cp /root/.local/bin/uv /usr/local/bin/uv \
    && cp /root/.local/bin/uvx /usr/local/bin/uvx

# Mise (project toolchain provisioner) — see ADR-015
ARG MISE_VERSION=2026.4.5
RUN curl -fsSL https://mise.run | MISE_VERSION=v${MISE_VERSION} MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && chmod +x /usr/local/bin/mise \
    && /usr/local/bin/mise --version

# Node 22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# npm resilience: cap per-request stall at 90s (npm default is 5 min) so a flaky
# registry fails fast instead of hanging the build for ~80 min across many
# transitive deps. Outer retry loops (below) absorb transient EIDLETIMEOUTs.
# Written to /root/.npmrc — inherited by every npm install in this stage.
RUN npm config set fetch-timeout 90000 \
    && npm config set fetch-retries 1 \
    && npm config set fetch-retry-mintimeout 5000 \
    && npm config set fetch-retry-maxtimeout 20000

# Bun
RUN npm install -g bun@${BUN_VERSION}

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# DCG (Dangerous Command Guard): opt-in via examples/dcg recipe (rip-cage-wlwc.10).
# Binary, guard wrapper, cage config, and sentinel are all provisioned by the recipe.
# Un-baked from the base image (ADR-025 D2/D3: dcg engine is a composable recipe, not floor).

# Dolt (storage backend for beads) — required by bd v0.62.0+
# Sync (push/pull) won't work without SSH keys, but local ops work fine
ARG DOLT_VERSION=1.84.0
RUN curl -fsSL https://github.com/dolthub/dolt/releases/download/v${DOLT_VERSION}/install.sh | bash

# bd (beads issue tracker)
# bd-real is compiled in the golang:1.26-trixie builder, which links against
# the same ICU76 that trixie's runtime ships — no soname shim needed.
COPY --from=go-builder /go/bin/bd /usr/local/bin/bd-real
COPY cage/substrate/bd-wrapper.sh /usr/local/bin/bd
RUN chmod +x /usr/local/bin/bd /usr/local/bin/bd-real

# Claude Code — bounded retry loop survives transient registry flakiness.
RUN for i in 1 2 3; do \
      npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && break; \
      [ "$i" = 3 ] && exit 1; \
      echo "claude-code npm install failed (attempt $i/3); retrying in 10s" && sleep 10; \
    done

# Pi coding agent — bounded retry loop survives transient registry flakiness.
RUN for i in 1 2 3; do \
      npm install -g @mariozechner/pi-coding-agent@${PI_VERSION} && break; \
      [ "$i" = 3 ] && exit 1; \
      echo "pi-coding-agent npm install failed (attempt $i/3); retrying in 10s" && sleep 10; \
    done

# Per-tool launch wrappers (ADR-027 D4, ADR-031 D4). The manifest's launch_args
# codegen is gone; the wrapper is baked here for claude and pi instead, and an
# extension contributes its launch command through the boot descriptor's
# tools[].launch field. ONE generic file serves both — it names no tool (its own
# basename selects the descriptor entry), so the base image stays tool-agnostic
# (ADR-005 D12) and no cross-recipe path is hardcoded in any launch leg.
# The real binary moves to a fixed rip-cage-owned path and the wrapper takes its
# place, so NOTHING here depends on PATH order: the wrapper IS the binary at the
# name npm installed, and it resolves the real one by absolute path. (An
# extension that prepends to PATH must not be able to shadow either half --
# measured hazard, rip-cage-ely4.16.) `command -v` finds wherever npm's prefix
# actually put it rather than assuming a directory, and <tool>-real is an
# ABSOLUTE symlink to the resolved target: npm's own bin entry is a RELATIVE
# symlink, which would dangle the moment it moved to another directory.
COPY cage/boot/tool-launch-wrapper /usr/local/lib/rip-cage/tool-launch-wrapper
RUN mkdir -p /usr/local/lib/rip-cage/bin \
    && for _t in claude pi; do \
         _p="$(command -v "${_t}")" || { echo "base image: ${_t} not on PATH after install" >&2; exit 1; }; \
         _real="$(readlink -f "${_p}")"; \
         ln -sfn "${_real}" "/usr/local/lib/rip-cage/bin/${_t}-real"; \
         rm -f "${_p}"; \
         cp /usr/local/lib/rip-cage/tool-launch-wrapper "${_p}"; \
         chmod 0755 "${_p}"; \
       done

# Non-root user
RUN groupadd -g 1000 agent \
    && useradd -m -u 1000 -g agent -s /usr/bin/zsh agent \
    && echo "agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/chown agent\:agent /home/agent/.claude, /usr/bin/chown agent\:agent /home/agent/.claude-state, /usr/bin/chown agent\:agent /home/agent/.pi/agent, /usr/bin/chown -R agent\:agent /home/agent/.local/share/mise" > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

# rip-proxy user + /opt/rip-cage-proxy venv (PyYAML/dnspython for the SNI
# router + DNS resolver sidecar) and /etc/rip-cage/ca (the deleted
# init-mediator.sh's MITM CA install target) retired with the in-cage egress
# engine (ADR-029 D2).
# cage-env is populated at container start by the ADR-016 D2 preflight probe.
# Pre-create it as agent-writable so the probe doesn't need a sudoers entry.
RUN mkdir -p /etc/rip-cage \
    && : > /etc/rip-cage/cage-env \
    && chown agent:agent /etc/rip-cage/cage-env \
    && chmod 0644 /etc/rip-cage/cage-env

# Canonical in-guest "inside the cage" marker (ADR-002 D14, rip-cage-r5f9):
# root-owned, root:root 0444 — deliberately NOT agent-writable like cage-env
# above. The whole point is injection-resistance: the agent's sudo grant is
# scoped (see the sudoers.d/agent line below) and cannot touch a root-owned
# /etc/ file, so this is unforgeable by a prompt-injected agent trying to
# convince a tool it's on the host. Replaces the retired /.dockerenv check
# (absent in msb guests — no Docker runtime in-guest at all).
RUN : > /etc/rip-cage/release \
    && chown root:root /etc/rip-cage/release \
    && chmod 0444 /etc/rip-cage/release

# Copy rip-cage files — stable files first (fewer cache busts), frequently-edited last
RUN mkdir -p /etc/ssh/ssh_config.d
COPY cage/guards/ssh/known_hosts.github /etc/ssh/ssh_known_hosts
COPY cage/guards/ssh/ssh_config /etc/ssh/ssh_config.d/00-rip-cage.conf
RUN chmod 0644 /etc/ssh/ssh_known_hosts /etc/ssh/ssh_config.d/00-rip-cage.conf
COPY tests/test-safety-stack.sh /usr/local/lib/rip-cage/test-safety-stack.sh
COPY tests/_safety-stack-assert-lib.sh /usr/local/lib/rip-cage/_safety-stack-assert-lib.sh
COPY tests/run-recipe-smokes.sh /usr/local/lib/rip-cage/run-recipe-smokes.sh
COPY cage/agent/settings.json /etc/rip-cage/settings.json
# CC managed-settings floor-lock, cage-claude.md, and cage-pi.md are provisioned by
# composable recipes (examples/claude/, examples/pi/) via root-owned install_cmd.
# Un-baked from base image per rip-cage-wlwc.2.2 (ADR-005 D12; floor-lock preserved:
# install_cmd runs as root, writes chown root:root, parent dir root-owned — ADR-027 D3).
# Boot descriptor (ADR-031 D4) — the one declarative file init reads at boot,
# at the fixed path /etc/rip-cage/boot.json. Root-owned and not agent-writable:
# it declares what starts inside the cage, so an agent that could edit it could
# start whatever it liked. Extensions merge fragments in at BUILD time via
# rc-boot-merge (root context, before USER agent). Schema: the file's own
# _readme key, and one line in docs/reference/in-cage-daemon.md.
COPY cage/boot/boot.json /etc/rip-cage/boot.json
COPY cage/boot/rc-boot-merge /usr/local/bin/rc-boot-merge
RUN chmod 0755 /usr/local/bin/rc-boot-merge \
    && chown root:root /etc/rip-cage/boot.json \
    && chmod 0444 /etc/rip-cage/boot.json
COPY cage/init/init-rip-cage.sh /usr/local/bin/init-rip-cage.sh
COPY cage/substrate/skill-server.py /usr/local/lib/rip-cage/skill-server.py
COPY tests/test-skills.sh /usr/local/lib/rip-cage/test-skills.sh
COPY tests/_agent-readability.sh /usr/local/lib/rip-cage/_agent-readability.sh
COPY tests/test-bd-roundtrip.sh /usr/local/lib/rip-cage/test-bd-roundtrip.sh
RUN chmod +x /usr/local/bin/init-rip-cage.sh \
    /usr/local/lib/rip-cage/test-safety-stack.sh \
    /usr/local/lib/rip-cage/test-skills.sh \
    /usr/local/lib/rip-cage/test-bd-roundtrip.sh \
    /usr/local/lib/rip-cage/run-recipe-smokes.sh

# Pi's dcg-gate.ts guard is provisioned by the composable examples/dcg recipe via
# install_cmd (runs as root before USER agent) at its OWN separate root-owned load
# path /etc/rip-cage/pi/dcg-gate.ts — NOT inside the agent's extensions/ dir, which
# is agent-owned (olen retired per ADR-027 D1/D3; the guard loads via assembled
# launch_args: --no-extensions -e <path>). Relocated from pi recipe to dcg recipe
# per rip-cage-l72i.1 (ADR-027 D4): pi recipe no longer names dcg (ADR-005 D12).
# Un-baked from base image per rip-cage-wlwc.2.2 (ADR-005 D12).

USER agent
WORKDIR /home/agent
# Pre-create mount targets so Docker inherits agent ownership on first use.
# If Docker overrides ownership at mount time, init-rip-cage.sh has scoped
# sudo chown as a fallback (see sudoers above).
RUN mkdir -p /home/agent/.claude /home/agent/.claude-state /home/agent/.local/share/mise
# Mise global config: enable idiomatic version file detection for tools that use
# .nvmrc (node) and packageManager field in package.json (yarn). Without this,
# mise's core backends don't detect these files even with legacy_version_file=true.
# See: ADR-015 D3 (init.rip-cage.sh hooks), Tier 2 test scenarios.
RUN mkdir -p /home/agent/.config/mise \
    && printf '[settings]\nidiomatic_version_file_enable_tools = ["node", "yarn"]\n' \
       > /home/agent/.config/mise/config.toml
COPY --chown=agent:agent cage/agent/zshrc /home/agent/.zshrc
# Pi cage-pi.md is provisioned by examples/pi recipe (install_cmd runs in root context
# before USER agent). See examples/pi/build-fragment.sh. The pi launch shim and guard
# wiring are assembled by rc build from manifest launch_args (rip-cage-l72i.1).
# (rip-cage-wlwc.2.2: un-baked from base image per ADR-005 D12)

# Version label — baked in at build time so rc up can detect stale local images.
# Placed last so version bumps don't invalidate upstream layer cache.
# ADR-008 D6.
ARG RC_VERSION=""
LABEL org.opencontainers.image.version="${RC_VERSION}"

CMD ["zsh"]
