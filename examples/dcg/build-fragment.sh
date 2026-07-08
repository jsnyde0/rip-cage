#!/usr/bin/env bash
# build-fragment.sh — regenerate examples/dcg/manifest-fragment.yaml from the
# canonical recipe source artifacts (cage/guards/dcg/dcg-guard, cage/guards/dcg/default-config.toml,
# tests/fixtures/ripcage-testsentinel-rule.yaml, examples/dcg/smoke.sh,
# examples/pi/dcg-gate.ts).
#
# The manifest fragment is self-contained (a user copies it into tools.yaml and
# runs `rc build` with ZERO rc source edits). The recipe provisions the dcg engine
# (guard wrapper + cage config + sentinel fixture) root-owned at their dest paths
# via a single-line, base64-encoded install_cmd (injection-safe — no newlines
# reach the Dockerfile).
#
# Also installs the recipe's behavioral smoke test into the recipe-tests dir
# (/usr/local/lib/rip-cage/recipe-tests/dcg-smoke.sh) as root:root so the
# generic name-free runner (run-recipe-smokes.sh) can run it (ADR-027 D1).
#
# rip-cage-l72i.1 (ADR-027 D4): the DCG fragment now ALSO bakes the pi-agent
# DCG guard extension (examples/pi/dcg-gate.ts) at its root-owned load path
# (/etc/rip-cage/pi/dcg-gate.ts) AND declares launch_args with -e. This
# relocates both the gate file and the launch wiring FROM the pi recipe TO
# the dcg recipe, so the pi recipe no longer names dcg (ADR-005 D12).
# Composing pi WITHOUT this dcg fragment = clean generic shim, no guard.
#
# rip-cage-p35a.1 (ADR-027 D1, FIRM 2026-07-02): the shipped default posture
# is OPEN — launch_args is `-e /etc/rip-cage/pi/dcg-gate.ts` only. It does
# NOT add `--no-extensions`, so pi's own extension auto-discovery paths stay
# live even with DCG composed (accepted residual: a prompt-injected pi could
# write a bypass extension into an auto-loaded path — "vector-b"). The
# locked posture (`--no-extensions` prepended, closing vector-b at the cost
# of pi extension autonomy) is a documented opt-in — see examples/dcg/README.md.
#
# This generator exists only so the artifacts stay human-readable/editable in
# version control; the COMMITTED manifest-fragment.yaml is the load-bearing,
# copy-pasteable recipe. Re-run this after editing any source artifact:
#   examples/dcg/build-fragment.sh > examples/dcg/manifest-fragment.yaml
#
# rip-cage-wlwc.10 (dcg engine demoted from base image to recipe; ADR-025 D2/D3).
set -euo pipefail

_here="$(cd "$(dirname "$0")" && pwd)"
_root="$(cd "${_here}/../.." && pwd)"

b64() { base64 < "$1" | tr -d '\n'; }

GUARD_B64="$(b64 "${_root}/cage/guards/dcg/dcg-guard")"
CONFIG_B64="$(b64 "${_root}/cage/guards/dcg/default-config.toml")"
SENTINEL_B64="$(b64 "${_root}/tests/fixtures/ripcage-testsentinel-rule.yaml")"
SMOKE_B64="$(b64 "${_here}/smoke.sh")"
# dcg-gate.ts: the pi-agent DCG guard extension (relocated from pi recipe — rip-cage-l72i.1)
GATE_B64="$(b64 "${_here}/../pi/dcg-gate.ts")"

cat <<YAML
version: 1
# DCG (Destructive Command Guard) — composable from-source TOOL recipe (rip-cage-wlwc.10).
#
# DCG is NOT floor (ADR-025 D2, ADR-026 D2) — it is a composable command-guard recipe.
# To enable DCG in your cage, copy these entries into ~/.config/rip-cage/tools.yaml and
# run \`rc build\`. No rc source edits required; this composes via the existing TOOL
# archetype + from-source build + install_cmd wiring (ADR-005 D12).
#
# What this recipe provisions:
#   1. dcg (build_source) — builds the \`dcg\` binary from source in an isolated Rust
#      builder stage (arch-adaptive: arm64 and amd64 each get a native binary,
#      ADR-005 D6/D11). Pinned to v0.4.0.
#   2. dcg-wiring (install_cmd) — provisions the dcg-guard wrapper engine + cage config
#      + sentinel fixture at their root-owned, agent-unwritable dest paths (ADR-025 D3).
#      Also bakes the pi-agent guard extension (dcg-gate.ts) at its OWN root-owned load
#      path (/etc/rip-cage/pi/dcg-gate.ts) — relocated from the pi recipe (rip-cage-l72i.1).
#      All written chown root:root so the agent cannot overwrite or weaken the guard.
#      Also installs examples/dcg/smoke.sh as /usr/local/lib/rip-cage/recipe-tests/dcg-smoke.sh
#      root:root so the generic name-free runner can execute it (ADR-027 D1).
#      Declares launch_args: -e /etc/rip-cage/pi/dcg-gate.ts
#      (the pi launch flag that loads the DCG guard; contributed by this fragment so
#      the pi recipe no longer names dcg — ADR-005 D12; ADR-027 D4). OPEN by default
#      (ADR-027 D1, FIRM): does NOT add --no-extensions, so pi's own extension
#      auto-discovery paths stay live. --no-extensions is a documented LOCKED
#      opt-in (see examples/dcg/README.md) that trades pi extension autonomy
#      for closing the agent-dropped-extension residual (vector-b).
#
# How DCG works in the cage:
#   - The managed-settings.json PreToolUse hook invokes /usr/local/lib/rip-cage/bin/dcg-guard
#     for EVERY Bash tool call.
#   - dcg-guard (the ENGINE, root-owned via recipe wiring):
#       - cd to a root-owned dir so DCG never walks up to /workspace for project config
#       - sets DCG_CONFIG to the cage-owned config, suppressing the agent-writable user layer
#       - strips DCG_* override env vars that could weaken policy
#       - exec-s /usr/local/bin/dcg (the binary installed by the dcg entry)
#   - Without this recipe, dcg is absent; dcg-guard will error and fail-open (non-blocking).
#
# Agentic composition model (ADR-005 D12, "built for the agentic era"):
#   An agent reads this recipe, copies the tools[] entries into ~/.config/rip-cage/tools.yaml,
#   and runs \`rc build\`. The agent does the wiring; rip-cage provides the seam and recipe.
#   No installer, no auto-wire mechanism, no rc source edit required.
#
# GENERATED by examples/dcg/build-fragment.sh from the canonical source artifacts
# (cage/guards/dcg/dcg-guard, cage/guards/dcg/default-config.toml, tests/fixtures/ripcage-testsentinel-rule.yaml,
# examples/dcg/smoke.sh, examples/pi/dcg-gate.ts).
# Do not hand-edit the base64 blobs — edit the source files and re-run the generator.
#
# egress: [] — DCG opens zero external connections (local guard only).

tools:
  # ---------------------------------------------------------------------------
  # TOOL entry 1: build the dcg binary from source (arch-adaptive, pinned tag).
  # ---------------------------------------------------------------------------
  - name: dcg
    archetype: TOOL
    # Pinned to v0.4.0 — the same tag used by the removed Dockerfile rust-builder stage.
    version_pin: "v0.4.0"
    egress: []
    build_source:
      # rust:1-slim-trixie matches the removed rust-builder stage — same toolchain, no compat issues.
      builder_image: "rust:1-slim-trixie"
      build_script: "tests/fixtures/build-dcg-from-source.sh"
      # output_path: the binary produced inside the builder stage; copied to /usr/local/bin/dcg
      # in the runtime image via COPY --from=rc-builder-dcg.
      output_path: "/usr/local/bin/dcg"
    mounts: []

  # ---------------------------------------------------------------------------
  # TOOL entry 2: provision the dcg engine wiring root-owned (guard + config + sentinel + smoke test
  #               + pi-agent guard extension — relocated from pi recipe, rip-cage-l72i.1).
  # install_cmd runs as root in the runtime stage (RUN). It:
  #   - writes /usr/local/lib/rip-cage/bin/dcg-guard (the ENGINE wrapper; ADR-025 D3),
  #     root:root mode 0755 — the agent can execute but cannot replace it.
  #   - writes /usr/local/lib/rip-cage/dcg/config.toml (cage-owned DCG config; ADR-025 D5),
  #     root:root mode 0644 — the agent can read but cannot overwrite.
  #   - writes /usr/local/lib/rip-cage/dcg/fixtures/ripcage-testsentinel-rule.yaml
  #     (sentinel fixture; ADR-025 D1), root:root mode 0644.
  #   - writes /usr/local/lib/rip-cage/recipe-tests/dcg-smoke.sh (behavioral smoke test),
  #     root:root mode 0755 — installed by root, dir+file root-owned (ADR-027 D1).
  #   - writes /etc/rip-cage/pi/dcg-gate.ts (the pi-agent DCG guard extension) on its OWN
  #     separate root-owned load path (ADR-027 D1/D3 — olen retired). The file AND parent dir
  #     /etc/rip-cage/pi are root-owned so the agent cannot unlink or replace the guard.
  #     (Relocated from pi recipe — rip-cage-l72i.1; pi recipe no longer names dcg.)
  # No apt packages needed; the leading ':' is a no-op so the rc-generated
  # 'apt-get update && <install_cmd> && rm ...' wrapper stays valid.
  # launch_args: contributed pi launch flags for this fragment (ADR-027 D4 / rip-cage-l72i.1).
  #   -e /etc/rip-cage/pi/dcg-gate.ts: loads the DCG guard from its root-owned path.
  #   Fragment order matters: composing this fragment first => this arg prepends => guard loads first.
  #   OPEN by default (ADR-027 D1, FIRM 2026-07-02): --no-extensions is deliberately
  #   NOT included here, so pi's own extension auto-discovery paths stay live. The
  #   accepted residual (a prompt-injected pi writing a bypass extension into an
  #   auto-loaded path — "vector-b") is knowingly accepted in the open default.
  #   --no-extensions is a documented LOCKED opt-in — see examples/dcg/README.md.
  - name: dcg-wiring
    archetype: TOOL
    version_pin: "bundled-recipe"
    required: true
    assert_loaded: "test -x /usr/local/lib/rip-cage/bin/dcg-guard && test -f /usr/local/lib/rip-cage/dcg/config.toml"
    install_cmd: ": && mkdir -p /usr/local/lib/rip-cage/bin /usr/local/lib/rip-cage/dcg/fixtures /usr/local/lib/rip-cage/recipe-tests /etc/rip-cage/pi && echo '${GUARD_B64}' | base64 -d > /usr/local/lib/rip-cage/bin/dcg-guard && chown root:root /usr/local/lib/rip-cage/bin/dcg-guard && chmod 0755 /usr/local/lib/rip-cage/bin/dcg-guard && echo '${CONFIG_B64}' | base64 -d > /usr/local/lib/rip-cage/dcg/config.toml && chown root:root /usr/local/lib/rip-cage/dcg/config.toml && chmod 0644 /usr/local/lib/rip-cage/dcg/config.toml && echo '${SENTINEL_B64}' | base64 -d > /usr/local/lib/rip-cage/dcg/fixtures/ripcage-testsentinel-rule.yaml && chown root:root /usr/local/lib/rip-cage/dcg/fixtures/ripcage-testsentinel-rule.yaml && chmod 0644 /usr/local/lib/rip-cage/dcg/fixtures/ripcage-testsentinel-rule.yaml && echo '${SMOKE_B64}' | base64 -d > /usr/local/lib/rip-cage/recipe-tests/dcg-smoke.sh && chown root:root /usr/local/lib/rip-cage/recipe-tests/dcg-smoke.sh && chmod 0755 /usr/local/lib/rip-cage/recipe-tests/dcg-smoke.sh && chown root:root /usr/local/lib/rip-cage/recipe-tests && echo '${GATE_B64}' | base64 -d > /etc/rip-cage/pi/dcg-gate.ts && chown root:root /etc/rip-cage/pi/dcg-gate.ts && chmod 0644 /etc/rip-cage/pi/dcg-gate.ts && chown root:root /etc/rip-cage/pi && chmod 0755 /etc/rip-cage/pi"
    launch_args: ["-e", "/etc/rip-cage/pi/dcg-gate.ts"]
    egress: []
    mounts: []
YAML
