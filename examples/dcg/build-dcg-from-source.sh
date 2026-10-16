#!/bin/sh
# DCG (Destructive Command Guard) from-source build script for the rip-cage dcg recipe.
# This script runs INSIDE the isolated `dcg-builder` stage of examples/dcg/Dockerfile.snippet,
# which COPYs it to /rc-build/build.sh and runs it (builder image: that stage's FROM line).
#
# Arch-adaptive: cargo install with --locked builds a native binary for the build-host
# architecture (arm64 on arm64, amd64 on amd64).
#
# Pinned tag: v0.4.0 — matches the tag previously used by the Dockerfile rust-builder stage.
# Output: /usr/local/cargo/bin/dcg → copied into the runtime image by the snippet's `COPY --from=dcg-builder` line.

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

# Move binary to the output path the snippet's `COPY --from=dcg-builder` reads
mv /usr/local/cargo/bin/dcg /usr/local/bin/dcg

echo "[build-dcg-from-source] done: $(ls -lh /usr/local/bin/dcg)"
