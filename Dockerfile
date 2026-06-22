# Stage 1: Go builder for beads (bd)
FROM golang:1.25-trixie AS go-builder
ARG BEADS_VERSION=v1.0.2
RUN apt-get update && apt-get install -y libicu-dev libzstd-dev pkg-config git && rm -rf /var/lib/apt/lists/*
# Clone + build (not `go install @latest`): upstream's go.mod carries a `replace`
# directive, which `go install` rejects unless the module is the main module.
RUN git clone --depth=1 --branch ${BEADS_VERSION} https://github.com/steveyegge/beads.git /src/beads \
 && cd /src/beads \
 && go build -o /go/bin/bd ./cmd/bd

# Stage 2: Rust builder for DCG
FROM rust:1-slim-trixie AS rust-builder
ARG DCG_VERSION=0.4.0
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
RUN cargo install --git https://github.com/Dicklesworthstone/destructive_command_guard --tag v${DCG_VERSION} destructive_command_guard

# Stage 3: Runtime (previously Stage 4; cm-builder removed in rip-cage-buuo.5 — cm is opt-in via manifest ADR-005 D2/D6)
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
RUN apt-get update && apt-get install -y \
    curl wget git ssh openssh-client zsh jq sudo \
    build-essential pkg-config libicu-dev libzstd-dev \
    python3 python3-venv perl ca-certificates gnupg \
    iptables openssl procps xxd \
    dnsutils \
    ssh-agent-filter \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

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

# DCG (Dangerous Command Guard) — built from source in rust-builder stage
COPY --from=rust-builder /usr/local/cargo/bin/dcg /usr/local/bin/dcg

# Dolt (storage backend for beads) — required by bd v0.62.0+
# Sync (push/pull) won't work without SSH keys, but local ops work fine
ARG DOLT_VERSION=1.84.0
RUN curl -fsSL https://github.com/dolthub/dolt/releases/download/v${DOLT_VERSION}/install.sh | bash

# bd (beads issue tracker)
# bd-real is compiled in the golang:1.25-trixie builder, which links against
# the same ICU76 that trixie's runtime ships — no soname shim needed.
COPY --from=go-builder /go/bin/bd /usr/local/bin/bd-real
COPY bd-wrapper.sh /usr/local/bin/bd
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

# Per-session Claude config isolation (rip-cage-p1p).
# This wrapper is placed at /usr/local/bin/claude which precedes /usr/bin/claude on PATH.
# It resolves CLAUDE_CONFIG_DIR (seeding the session dir if absent) then exec-s the real
# claude binary at /usr/bin/claude. Both the interactive (tmux) and headless (docker exec)
# paths are covered; see claude-session-wrapper.sh for full logic.
COPY claude-session-wrapper.sh /usr/local/bin/claude
RUN chmod +x /usr/local/bin/claude

# Pi launch hardening (rip-cage-sn1h): wrapper at /usr/local/bin/pi (precedes /usr/bin/pi on PATH).
# Adds --no-extensions -e <dcg-gate.ts> to EVERY pi invocation, disabling auto-discovery
# so /workspace/.pi/extensions/ admits NO agent-dropped extension (the workspace-path DCG bypass
# vector confirmed in rip-cage-sn1h source analysis). Load order is deterministic.
# wlwc D5 half (b): this is the per-agent recipe launch hook baked as a cage artifact.
COPY pi/pi-wrapper.sh /usr/local/bin/pi
RUN chmod +x /usr/local/bin/pi

# Non-root user
RUN groupadd -g 1000 agent \
    && useradd -m -u 1000 -g agent -s /usr/bin/zsh agent \
    && echo "agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/chown agent\:agent /home/agent/.claude, /usr/bin/chown agent\:agent /home/agent/.claude-state, /usr/bin/chown agent\:agent /home/agent/.pi/agent, /usr/bin/chown agent\:agent /ssh-agent.sock, /usr/bin/chown agent\:agent /ssh-agent-upstream.sock, /usr/bin/ln -sfT /tmp/rip-cage-filter/agent.* /ssh-agent.sock, /usr/local/lib/rip-cage/init-firewall.sh, /usr/sbin/iptables -t nat -L OUTPUT -n, /usr/sbin/iptables -L OUTPUT -n, /usr/bin/chown -R agent\:agent /home/agent/.local/share/mise, /usr/bin/ln -sfT /home/agent/.rc-context/pi-ext-subagent /home/agent/.pi/agent/extensions/subagent, /bin/rm -rf /home/agent/.pi/agent/extensions/subagent" > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

RUN useradd -r -s /usr/sbin/nologin -M rip-proxy

RUN python3 -m venv /opt/rip-cage-proxy
# Pure SNI destination router (rip-cage-ta1o.1): only PyYAML + dnspython needed.
# mitmproxy removed — no TLS decryption, no CA, no per-host cert.
RUN /opt/rip-cage-proxy/bin/pip install --no-cache-dir PyYAML dnspython

RUN mkdir -p /etc/rip-cage/ca
# cage-env is populated at container start by the ADR-016 D2 preflight probe.
# Pre-create it as agent-writable so the probe doesn't need a sudoers entry.
RUN : > /etc/rip-cage/cage-env \
    && chown agent:agent /etc/rip-cage/cage-env \
    && chmod 0644 /etc/rip-cage/cage-env

# Copy rip-cage files — stable files first (fewer cache busts), frequently-edited last
RUN mkdir -p /etc/ssh/ssh_config.d
COPY ssh/known_hosts.github /etc/ssh/ssh_known_hosts
COPY ssh/ssh_config /etc/ssh/ssh_config.d/00-rip-cage.conf
RUN chmod 0644 /etc/ssh/ssh_known_hosts /etc/ssh/ssh_config.d/00-rip-cage.conf
COPY hooks/ /usr/local/lib/rip-cage/hooks/
COPY dcg/dcg-guard /usr/local/lib/rip-cage/bin/dcg-guard
COPY dcg/default-config.toml /usr/local/lib/rip-cage/dcg/config.toml
COPY tests/test-safety-stack.sh /usr/local/lib/rip-cage/test-safety-stack.sh
# Sentinel fixture for the DCG additive-rule-fires check (ADR-025 D1). Baked into the
# image so `rc test <cage>` check 11e is portable across ALL cages, not only the
# rip-cage repo's own workspace (rip-cage-16t).
COPY tests/fixtures/ripcage-testsentinel-rule.yaml /usr/local/lib/rip-cage/dcg/fixtures/ripcage-testsentinel-rule.yaml
COPY settings.json /etc/rip-cage/settings.json
# CC managed-settings: baked root-owned highest-precedence CC hook layer (rip-cage-r9n4).
# /etc/claude-code/managed-settings.json is CC's managed-settings path — hooks here merge
# un-suppressibly with user/project hooks and PreToolUse is deny-wins. This delivers the
# DCG guard hook via a layer the in-cage agent CANNOT edit or unregister, closing the
# self-disable vector (ADR-027 D3 floor-lock slot; ADR-002 D5 managed-settings target).
# root:root + mode 644: agent can read, cannot write.
RUN mkdir -p /etc/claude-code
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN chown root:root /etc/claude-code/managed-settings.json \
    && chmod 644 /etc/claude-code/managed-settings.json
COPY cage-claude.md /etc/rip-cage/cage-claude.md
COPY cage-pi.md /etc/rip-cage/cage-pi.md
COPY init-rip-cage.sh /usr/local/bin/init-rip-cage.sh
COPY skill-server.py /usr/local/lib/rip-cage/skill-server.py
COPY tests/test-skills.sh /usr/local/lib/rip-cage/test-skills.sh
COPY tests/_agent-readability.sh /usr/local/lib/rip-cage/_agent-readability.sh
COPY egress-rules.yaml /etc/rip-cage/egress-rules.yaml
COPY rip_cage_egress.py /usr/local/lib/rip-cage/rip_cage_egress.py
COPY rip_cage_router.py /usr/local/lib/rip-cage/rip_cage_router.py
COPY rip_cage_dns.py /usr/local/lib/rip-cage/rip_cage_dns.py
COPY init-firewall.sh /usr/local/lib/rip-cage/init-firewall.sh
COPY init-mediator.sh /usr/local/lib/rip-cage/init-mediator.sh
COPY rip-proxy-start.sh /usr/local/lib/rip-cage/rip-proxy-start.sh
COPY rip-dns-start.sh /usr/local/lib/rip-cage/rip-dns-start.sh
COPY tests/test-egress-firewall.sh /usr/local/lib/rip-cage/test-egress-firewall.sh
COPY tests/test-bd-roundtrip.sh /usr/local/lib/rip-cage/test-bd-roundtrip.sh
COPY tests/test-pi-dcg-gate.sh /usr/local/lib/rip-cage/test-pi-dcg-gate.sh
RUN chmod +x /usr/local/bin/init-rip-cage.sh \
    /usr/local/lib/rip-cage/bin/dcg-guard \
    /usr/local/lib/rip-cage/hooks/*.sh \
    /usr/local/lib/rip-cage/test-safety-stack.sh \
    /usr/local/lib/rip-cage/test-skills.sh \
    /usr/local/lib/rip-cage/test-egress-firewall.sh \
    /usr/local/lib/rip-cage/test-bd-roundtrip.sh \
    /usr/local/lib/rip-cage/test-pi-dcg-gate.sh \
    /usr/local/lib/rip-cage/init-firewall.sh \
    /usr/local/lib/rip-cage/init-mediator.sh \
    /usr/local/lib/rip-cage/rip-proxy-start.sh \
    /usr/local/lib/rip-cage/rip-dns-start.sh

# Pi extensions/ dir: root-owned so the in-cage agent cannot write new extensions
# or replace dcg-gate.ts (rip-cage-olen). Mode 755: agent can read/traverse/load,
# cannot write. pi only READS extensions/ (auto-discovery glob, loader.ts:583-585)
# and never writes it, so root-ownership does not impede pi (ADR-019 D1).
# Must be created in root context (before USER agent) to stay root:root.
RUN mkdir -p /home/agent/.pi/agent/extensions \
    && chmod 755 /home/agent/.pi/agent/extensions

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
COPY --chown=agent:agent zshrc /home/agent/.zshrc
# Pi DCG gate extension (rip-cage-bl1): baked into cage-owned container-local extensions dir.
# Loaded via EXPLICIT -e flag by the pi-wrapper (rip-cage-sn1h) — NOT auto-discovered.
# (Prior: auto-discovered via extensions/*.ts glob; rip-cage-sn1h replaced auto-discovery
# with --no-extensions + -e <dcg-gate> to close the /workspace/.pi/extensions/ bypass vector.)
# NOT under the host-mounted auth.json sub-mount — cage-owned, root-owned, host-clean.
# Root-owned (no --chown): agent can read/load but cannot overwrite or delete (rip-cage-olen).
COPY pi/dcg-gate.ts /home/agent/.pi/agent/extensions/dcg-gate.ts

# Version label — baked in at build time so rc up can detect stale local images.
# Placed last so version bumps don't invalidate upstream layer cache.
# ADR-008 D6.
ARG RC_VERSION=""
LABEL org.opencontainers.image.version="${RC_VERSION}"

CMD ["zsh"]
