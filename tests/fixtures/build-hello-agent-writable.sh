#!/bin/sh
# Test fixture build script — rip-cage-buuo.3 HOSTILE fixture.
# Produces a binary with world/agent-writable permissions (mode 777).
# Used to prove _manifest_check_binary_root_owned rejects agent-writable binaries.
# The build script is COPY'd into an isolated builder stage and run inside it.
# Builder image: alpine:3.19
set -e
mkdir -p /usr/local/bin
printf '#!/bin/sh\necho "hello agent-writable"\n' > /usr/local/bin/hello-agent-writable
chmod 777 /usr/local/bin/hello-agent-writable
