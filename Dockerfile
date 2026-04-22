# Stage 1: Go builder for beads (bd)
FROM golang:1.25-bookworm AS go-builder
ARG BEADS_VERSION=v1.0.2
RUN apt-get update && apt-get install -y libicu-dev libzstd-dev pkg-config git && rm -rf /var/lib/apt/lists/*
# Clone + build (not `go install @latest`): upstream's go.mod carries a `replace`
# directive, which `go install` rejects unless the module is the main module.
RUN git clone --depth=1 --branch ${BEADS_VERSION} https://github.com/steveyegge/beads.git /src/beads \
 && cd /src/beads \
 && go build -o /go/bin/bd ./cmd/bd

# Stage 2: Rust builder for DCG
FROM rust:bookworm AS rust-builder
ARG DCG_VERSION=0.4.0
RUN cargo install --git https://github.com/Dicklesworthstone/destructive_command_guard --tag v${DCG_VERSION} destructive_command_guard

# Stage 3: Runtime
FROM debian:bookworm

ARG CLAUDE_CODE_VERSION=latest
ARG BUN_VERSION=latest

# Terminal / locale — needed for Claude Code's TUI to render correctly in tmux
ENV TERM=xterm-256color
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV MISE_TRUSTED_CONFIG_PATHS=/workspace

# System packages
RUN apt-get update && apt-get install -y \
    curl wget git ssh openssh-client zsh tmux jq sudo \
    build-essential pkg-config libicu-dev libzstd-dev \
    python3 python3-venv perl ca-certificates gnupg \
    iptables openssl procps \
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
COPY --from=go-builder /go/bin/bd /usr/local/bin/bd-real
COPY bd-wrapper.sh /usr/local/bin/bd
RUN chmod +x /usr/local/bin/bd /usr/local/bin/bd-real

# Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Non-root user
RUN groupadd -g 1000 agent \
    && useradd -m -u 1000 -g agent -s /usr/bin/zsh agent \
    && echo "agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/chown agent\:agent /home/agent/.claude, /usr/bin/chown agent\:agent /home/agent/.claude-state, /usr/local/lib/rip-cage/init-firewall.sh, /usr/sbin/iptables -t nat -L OUTPUT -n, /usr/sbin/iptables -L OUTPUT -n, /usr/bin/chown -R agent\:agent /home/agent/.local/share/mise" > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

RUN useradd -r -s /usr/sbin/nologin -M rip-proxy

RUN python3 -m venv /opt/rip-cage-proxy
RUN /opt/rip-cage-proxy/bin/pip install --no-cache-dir mitmproxy PyYAML
RUN ln -sf /opt/rip-cage-proxy/bin/mitmdump /usr/local/bin/mitmdump

RUN mkdir -p /etc/rip-cage/ca

# Copy rip-cage files — stable files first (fewer cache busts), frequently-edited last
RUN mkdir -p /etc/ssh/ssh_config.d
COPY ssh/known_hosts.github /etc/ssh/ssh_known_hosts
COPY ssh/ssh_config /etc/ssh/ssh_config.d/00-rip-cage.conf
RUN chmod 0644 /etc/ssh/ssh_known_hosts /etc/ssh/ssh_config.d/00-rip-cage.conf
COPY hooks/ /usr/local/lib/rip-cage/hooks/
COPY tests/test-safety-stack.sh /usr/local/lib/rip-cage/test-safety-stack.sh
COPY settings.json /etc/rip-cage/settings.json
COPY init-rip-cage.sh /usr/local/bin/init-rip-cage.sh
COPY skill-server.py /usr/local/lib/rip-cage/skill-server.py
COPY tests/test-skills.sh /usr/local/lib/rip-cage/test-skills.sh
COPY egress-rules.yaml /etc/rip-cage/egress-rules.yaml
COPY rip_cage_egress.py /usr/local/lib/rip-cage/rip_cage_egress.py
COPY init-firewall.sh /usr/local/lib/rip-cage/init-firewall.sh
COPY rip-proxy-start.sh /usr/local/lib/rip-cage/rip-proxy-start.sh
COPY tests/test-egress-firewall.sh /usr/local/lib/rip-cage/test-egress-firewall.sh
COPY tests/test-bd-roundtrip.sh /usr/local/lib/rip-cage/test-bd-roundtrip.sh
RUN chmod +x /usr/local/bin/init-rip-cage.sh \
    /usr/local/lib/rip-cage/hooks/*.sh \
    /usr/local/lib/rip-cage/test-safety-stack.sh \
    /usr/local/lib/rip-cage/test-skills.sh \
    /usr/local/lib/rip-cage/test-egress-firewall.sh \
    /usr/local/lib/rip-cage/test-bd-roundtrip.sh \
    /usr/local/lib/rip-cage/init-firewall.sh \
    /usr/local/lib/rip-cage/rip-proxy-start.sh

USER agent
WORKDIR /home/agent
# Pre-create mount targets so Docker inherits agent ownership on first use.
# If Docker overrides ownership at mount time, init-rip-cage.sh has scoped
# sudo chown as a fallback (see sudoers above).
RUN mkdir -p /home/agent/.claude /home/agent/.claude-state /home/agent/.local/share/mise
COPY --chown=agent:agent zshrc /home/agent/.zshrc
COPY --chown=agent:agent tmux.conf /home/agent/.tmux.conf
CMD ["zsh"]
