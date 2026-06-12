#!/bin/sh
# Test fixture build script for rip-cage-buuo.2 from-source builder stage tests.
# This script is COPY'd into an isolated Docker builder stage and run inside it.
# It produces a tiny static binary at /usr/local/bin/hello-from-source.
# Builder image: alpine:3.19 — no arch lock, arch-adaptive by construction.
set -e
mkdir -p /usr/local/bin
printf '#!/bin/sh\necho "hello from source"\n' > /usr/local/bin/hello-from-source
chmod +x /usr/local/bin/hello-from-source
