#!/bin/sh
# DCG (Destructive Command Guard) from-source build script for the rip-cage manifest mechanism.
# This script runs INSIDE an isolated Docker builder stage (rip-cage-buuo.2 / ADR-005 D6).
# Builder image: see examples/dcg/manifest-fragment.yaml build_source.builder_image.
#
# Arch-adaptive: cargo install with --locked builds a native binary for the build-host
# architecture (arm64 on arm64, amd64 on amd64).
#
# Pinned tag: v0.4.0 — matches the tag previously used by the Dockerfile rust-builder stage.
# Output: /usr/local/cargo/bin/dcg → copied to /usr/local/bin/dcg by the manifest mechanism.

set -eu

DCG_TAG="v0.4.0"
DCG_REPO="https://github.com/Dicklesworthstone/destructive_command_guard"

# Install system deps for Rust/SSL
apt-get update
apt-get install -y --no-install-recommends pkg-config libssl-dev
rm -rf /var/lib/apt/lists/*

# Build dcg from the pinned tag (arch-adaptive — no --target flag)
cargo install \
  --git "${DCG_REPO}" \
  --tag "${DCG_TAG}" \
  --locked \
  destructive_command_guard

# Move binary to the output path expected by manifest build_source.output_path
mv /usr/local/cargo/bin/dcg /usr/local/bin/dcg

echo "[build-dcg-from-source] done: $(ls -lh /usr/local/bin/dcg)"
