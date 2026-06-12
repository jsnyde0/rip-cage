#!/bin/sh
# cm (CASS Memory System CLI) from-source build script for the rip-cage manifest mechanism.
# This script runs INSIDE an isolated Docker builder stage (rip-cage-buuo.2 / ADR-005 D6).
# Builder image: see manifest-cm-example.yaml build_source.builder_image.
#
# Arch-adaptive: bun build auto-detects the build-host architecture when no --target flag
# is given — arm64 builds arm64, amd64 builds amd64 (subsuming rip-cage-ywek: the old
# Dockerfile cm-builder stage had a hardcoded arch target flag that broke on non-arm64 hosts).
#
# No --target flag is used here. Bun compiles a NATIVE binary for the build platform.
# Output: /usr/local/bin/cm (the path declared in build_source.output_path).

set -eu

CM_REF="2e63e9b"
BUN_VERSION="1.3.14"

# Install system deps
apt-get update
apt-get install -y --no-install-recommends git curl ca-certificates unzip nodejs
rm -rf /var/lib/apt/lists/*

# Install Bun (pinned version, no --target = native arch)
# Bun installer is bash; pipe explicitly to bash (debian:trixie sh=dash would fail).
curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash -s "bun-v${BUN_VERSION}"

# Clone at pinned ref, install deps, compile natively (arch-adaptive — no --target)
git clone https://github.com/Dicklesworthstone/cass_memory_system.git /src/cm
cd /src/cm
git checkout "${CM_REF}"
bun install --frozen-lockfile
bun build src/cm.ts --compile --outfile /usr/local/bin/cm

echo "[build-cm-from-source] done: $(ls -lh /usr/local/bin/cm)"
