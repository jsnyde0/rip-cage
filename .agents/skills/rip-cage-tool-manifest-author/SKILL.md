---
name: rip-cage-tool-manifest-author
description: Use when a user wants to add a new tool to their rip-cage Docker image via the host-only manifest mechanism (ADR-005 D11). Guides a HOST-SIDE agent to read a named tool's source and release situation, determine whether a prebuilt Linux binary exists or a from-source build is needed, and draft a manifest entry (plus a build script for the from-source path) as HUMAN-REVIEWABLE host files under ~/.config/rip-cage/. The human approves the drafted files before running rc build; the fail-closed validator enforces the contract. Does NOT perform any in-cage write or runtime injection. cm is the worked example (no prebuilt linux-arm64 release -> from-source path).
---

# rip-cage Tool Manifest Authoring

Use this skill when a user asks to add a tool to their rip-cage image. You are running
HOST-SIDE under the user's supervision. You draft REVIEWABLE FILES; the human approves
before `rc build`. You do NOT write into a running cage.

---

## Host-only invariant (FIRM — ADR-005 D7, ADR-024)

The rip-cage manifest lives at `~/.config/rip-cage/tools.yaml` on the HOST. The
in-cage agent cannot reach this file: `rc` is not copied into the container image,
and `RC_MANIFEST_GLOBAL` / `XDG_CONFIG_HOME` are not forwarded into the cage. This
is not a path-based lock — it is enforced by `rc` being a host-only process.

**You are the host-side agent. Your job:**
1. Draft a manifest entry (and build script if needed) as HOST files for human review.
2. Tell the human what to review and how to apply it.
3. Never write into a running cage. Never instruct the in-cage agent to modify the
   manifest. Never produce a runtime injection.

---

## Step 0 — Orient before drafting

Before proposing any manifest entry, read the tool's actual source / release page:
- Check GitHub releases for a prebuilt linux-arm64 asset.
- Check GitHub releases for a prebuilt linux-amd64 asset.
- Check the Dockerfile / package manager (apt, apt-get) install path if one exists.
- Identify the version you want to pin (`version_pin`).

This is open-ended per-tool judgment. The goal: determine which of the two manifest
paths fits the tool.

---

## Two paths: prebuilt vs from-source

### Path A — Prebuilt binary (install_cmd)

Use when: a prebuilt Linux binary is available (as a release asset, apt package, or
a single-line install command).

Required fields (TOOL archetype):

```yaml
version: 1
tools:
  - name: <tool-name>
    archetype: TOOL
    version_pin: "<semver, commit-ref, or 'bundled'>"
    egress:
      - <hostname-1>       # every host the tool phones home to; [] if none
    mounts: []             # list of {host, dest} objects; [] if none needed
    install_cmd: "<single-line install command>"
```

Field rules:
- `version_pin` — required on every entry. Use the pinned version, commit hash, or
  `"bundled"` for image-baked tools. `"bundled"` MUST NOT have `install_cmd`.
- `install_cmd` — MUST be a single line (no newlines — newlines inject arbitrary
  Dockerfile directives; ADR-024 newline-injection defense).
- `egress` — MUST be a list (empty list `[]` if the tool opens zero external
  connections). Declaring egress is mandatory even for offline tools.
- `mounts` — MUST be a list (empty list `[]` if no host-side data to mount).
  Each element MUST be an object: `{host: "/path/on/host", dest: "/path/in/cage"}`.
  Scalar strings are REJECTED by the validator.
  The `host` path supports `~/` and `$HOME/` expansion at `rc up` time.
- `install_cmd` and `build_source` are MUTUALLY EXCLUSIVE.
- `install_cmd` MUST NOT appear when `version_pin` is `"bundled"`.

### Path B — From source (build_source)

Use when: no suitable prebuilt Linux binary is available for the target arch, OR the
user prefers to compile from source for reproducibility.

This is the **cm case** — cm ships no prebuilt linux-arm64 release, so rip-cage
builds it from source in an isolated Docker builder stage.

Required fields (TOOL archetype, from-source):

```yaml
version: 1
tools:
  - name: <tool-name>
    archetype: TOOL
    version_pin: "<commit-ref or semver>"
    egress: []             # declare even if empty
    mounts: []             # declare even if empty
    build_source:
      builder_image: "<docker-image>:<tag>"   # e.g. "debian:trixie" — single line
      build_script: "<path/to/build-script.sh>"  # relative to repo root — single line
      output_path: "<absolute-path-inside-builder>"  # e.g. "/usr/local/bin/tool" — single line
```

Field rules:
- `build_source` and `install_cmd` are MUTUALLY EXCLUSIVE.
- All three `build_source` sub-fields are required: `builder_image`, `build_script`,
  `output_path`. Each MUST be a single line.
- `builder_image` — the Docker image used for the isolated build stage. Must match the
  runtime stage's libc to avoid compat issues (e.g., `debian:trixie` matches rip-cage's
  runtime stage).
- `build_script` — path to a host-side shell script (relative to the repo root or an
  absolute path). The script runs INSIDE the isolated builder stage, NOT on the host.
  It must install deps, clone/checkout at the pinned ref, and compile to `output_path`.
- `output_path` — the binary's location inside the builder stage after the build script
  runs. The rip-cage generic builder copies this to the runtime stage.
- The build script MUST be arch-adaptive: do NOT hardcode `--target <arch>`. Let the
  build tool (e.g., `bun build --compile`) auto-detect the native arch. This makes the
  same manifest entry work on arm64 and amd64 hosts.

---

## Other archetypes (non-TOOL)

Two other archetypes exist. They are less common for user-added tools but are documented
here so you can recognize them and draft them correctly if needed.

### SHELL-INTEGRATION

Use when: the tool integrates via a shell `eval` line in `.zshrc` (e.g., a version
manager, a completion shim, or a prompt plugin).

Required fields:

```yaml
  - name: <tool-name>
    archetype: SHELL-INTEGRATION
    version_pin: "<version>"
    shell_init: "<single-line eval or source command>"
```

- `shell_init` MUST be a single line.
- No `egress`, `mounts`, `install_cmd`, or `build_source` fields for this archetype.

### IN-CAGE-DAEMON

Use when: the tool runs as a persistent background service inside the cage (e.g., a
local database, a key-value store, or a local HTTP service).

Required fields:

```yaml
  - name: <tool-name>
    archetype: IN-CAGE-DAEMON
    version_pin: "<version>"
    start: "<command to start the daemon>"
    health: "<command that exits 0 when daemon is healthy>"
    state_dir: "/absolute/path/to/state"   # must be absolute, no spaces, no metacharacters
```

Optional field: `mcp_fragment` — an MCP server config fragment to inject into the
cage's `settings.json`.

- `state_dir` must be an absolute path starting with `/`, no whitespace, no shell
  metacharacters.

---

## Drafting the build script (from-source path)

When `build_source` is needed, also draft a build script. Place it at a path the
user can review, e.g. `~/.config/rip-cage/build-<tool>.sh` (or anywhere the user
prefers, as long as `build_script` in the manifest points to it).

Build script conventions (matching the cm worked example):
1. Start with `#!/bin/sh` and `set -eu`.
2. Pin tool version and any toolchain version at the top (named variables).
3. Install system deps via `apt-get` (the builder image is typically Debian).
4. Download / install any build toolchain (e.g., Bun, Rust, Go) — pinned version.
5. Clone the tool's repo at the pinned ref, install deps, compile natively.
6. Output the binary to the path declared in `build_source.output_path`.
7. Do NOT hardcode `--target <arch>`. Let the compiler auto-detect.
8. End with a confirmation echo (e.g., `echo "[build-<tool>] done: $(ls -lh <output>)"`).

---

## Mounts: when to include them

Add a `mounts` entry when the tool reads/writes persistent host-side data that should
survive `rc destroy` and be shared between the host and cage sessions. Examples:
- A memory/knowledge store (like cm's `~/.cass-memory`)
- A credential or config file the tool needs (verify against the ADR-023 denylist
  before proposing — `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh` etc. are denied)

`mounts` is required on TOOL entries even if empty (`mounts: []`).

Each mount element must be an object:
```yaml
mounts:
  - host: "~/path/on/host"      # ~/  and $HOME/ are expanded to $HOME at rc up time
    dest: "/path/in/cage"       # absolute path inside the container
```

Security note: the ADR-023 denylist check runs AFTER tilde expansion. A mount like
`host: "~/.ssh"` is still rejected. Only safe paths pass.

---

## Egress: what to declare

The `egress` list declares hostnames the tool's in-cage process opens outbound
connections to. This feeds the cage's L7 egress whitelist.

- Declare every hostname — do not omit any.
- Use `egress: []` for tools that open zero external connections (like cm).
- Do NOT declare sub-paths or IPs — hostnames only (e.g. `api.github.com`).
- Declaring egress is required on TOOL entries even if empty.

---

## How to apply the drafted files

After drafting, tell the human:

1. **Review the manifest entry** and the build script (if any) before applying.
   The build script fetches and compiles arbitrary upstream source — human review of
   the script is the load-bearing mitigation for supply-chain risk (ADR-005 D11).
2. **Merge the entry** into `~/.config/rip-cage/tools.yaml` (create the file if it
   does not exist; add the `version: 1` header and `tools:` list).
3. **Place the build script** at the path declared in `build_source.build_script`
   (from-source path only).
4. **Validate** before building:
   ```bash
   source rc && _manifest_validate ~/.config/rip-cage/tools.yaml
   ```
5. **Build** the image:
   ```bash
   rc build
   ```
6. **Test** the result:
   ```bash
   rc test <container-name>
   ```

The fail-closed validator (invoked by `rc build`) rejects any entry with an invalid
schema. It runs before any Docker build step — it will not silently skip bad entries.

---

## Worked example: cm (from-source path)

cm (`github.com/Dicklesworthstone/cass_memory_system`) is the canonical from-source
example. It ships no prebuilt linux-arm64 release — the cage target on Apple Silicon.
It must be built from source using Bun.

### Manifest entry (`~/.config/rip-cage/tools.yaml`)

Merge the following entry into your manifest (add after the `tools:` list header):

```yaml
version: 1
tools:
  - name: cm
    archetype: TOOL
    # Pin to the commit ref used by the original rip-cage cm-builder stage.
    version_pin: "2e63e9b"
    # cm opens zero external connections — pure local storage.
    egress: []
    # RW bind mount for the host cm store. ~/  expands to $HOME at rc up time.
    # The mount is skip-if-missing: if ~/.cass-memory does not exist, rc up skips
    # the mount silently; cm then uses container-local storage (lost on rc destroy).
    mounts:
      - host: "~/.cass-memory"
        dest: "/home/agent/.cass-memory"
    build_source:
      # debian:trixie matches the runtime stage — same libc, no compat issues.
      builder_image: "debian:trixie"
      # Path to the build script relative to the repo root (adjust if you placed
      # the script elsewhere — must match the actual path).
      build_script: "tests/fixtures/build-cm-from-source.sh"
      output_path: "/usr/local/bin/cm"
```

### Build script (`tests/fixtures/build-cm-from-source.sh`)

The repo ships this script at `tests/fixtures/build-cm-from-source.sh`. Its shape:

```sh
#!/bin/sh
# cm (CASS Memory System CLI) from-source build script for the rip-cage manifest.
# Runs INSIDE an isolated Docker builder stage (arch-adaptive — no --target flag).
set -eu

CM_REF="2e63e9b"
BUN_VERSION="1.3.14"

# Install system deps
apt-get update
apt-get install -y --no-install-recommends git curl ca-certificates unzip nodejs
rm -rf /var/lib/apt/lists/*

# Install Bun (pinned version, no --target = native arch)
curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash -s "bun-v${BUN_VERSION}"

# Clone at pinned ref, install deps, compile natively (arch-adaptive — no --target)
git clone https://github.com/Dicklesworthstone/cass_memory_system.git /src/cm
cd /src/cm
git checkout "${CM_REF}"
bun install --frozen-lockfile
bun build src/cm.ts --compile --outfile /usr/local/bin/cm

echo "[build-cm-from-source] done: $(ls -lh /usr/local/bin/cm)"
```

Key design decisions baked into this script:
- **No `--target` flag** — `bun build --compile` auto-detects the build platform's
  native arch (arm64 on arm64, amd64 on amd64). This is the arch-adaptive property.
- **Pinned refs** — `CM_REF` and `BUN_VERSION` are explicit pins for reproducibility.
- **`debian:trixie` builder** — matches the rip-cage runtime stage's libc.
- **Zero `egress` in manifest** — cm is pure local storage; no outbound connections.
- **RW mount** — the cm store mount is read-write (Docker's default for `-v host:dest`).
  cm needs write access to add observations and calibrations during cage sessions.

### ADR-005 D5 four-point opt-in pattern (cm as illustration)

1. `build_source` — builds cm from source in an isolated stage (arch-adaptive).
2. `egress: []` — cm opens zero external connections.
3. `mounts` — RW bind mount for the host cm store (skip-if-missing if `~/.cass-memory`
   does not exist).
4. Detection — in-cage agents discover cm via `command -v cm`.

---

## Validation check

Before applying, validate with:

```bash
source /path/to/rip-cage/rc
_manifest_validate ~/.config/rip-cage/tools.yaml
```

Or run the repo's cm-specific test suite (host-only tier, no container needed):

```bash
bash tests/test-manifest-cm.sh
```

The T3c check validates the cm manifest example (`tests/fixtures/manifest-cm-example.yaml`)
against `_manifest_validate` directly. The T3e check asserts the build script
(`tests/fixtures/build-cm-from-source.sh`) is arch-adaptive (no hardcoded `--target`).

---

## What NOT to do

- Do NOT write any file inside a running cage.
- Do NOT instruct the in-cage agent to modify the manifest.
- Do NOT produce a runtime injection (the manifest is HOST-ONLY — ADR-005 D7 FIRM).
- Do NOT invent manifest fields. The only valid fields are those documented above.
  Unknown fields are passed through silently by the YAML parser but are meaningless —
  and signal a misread of the schema. Cross-check every field against the rc validator
  (`_manifest_validate` in `rc`).
- Do NOT hardcode architecture targets in build scripts (`--target bun-linux-arm64`
  etc.). Always let the compiler auto-detect.
- Do NOT omit `egress` or `mounts` on a TOOL entry — they are required even if empty.
- Do NOT set `install_cmd` when `build_source` is present — they are mutually exclusive.
- Do NOT set `install_cmd` or `build_source` when `version_pin` is `"bundled"`.
- Do NOT propose `mounts` entries for denylist-protected paths (`~/.ssh`, `~/.gnupg`,
  `~/.aws`, `~/.config/gh`, etc.) — the validator rejects them (ADR-023).

---

## Schema summary (quick reference)

```
version: 1          # required top-level field
tools:              # required list
  - name: ...       # required; all archetypes
    archetype: TOOL | SHELL-INTEGRATION | IN-CAGE-DAEMON   # required
    version_pin: "..." # required; all archetypes; "bundled" for baked tools

    # TOOL archetype only:
    egress: [...]                     # required (even if [])
    mounts: [{host: ..., dest: ...}]  # required (even if []); objects not strings
    install_cmd: "..."                # mutually exclusive with build_source
    build_source:                     # mutually exclusive with install_cmd
      builder_image: "..."            # required if build_source present
      build_script: "..."             # required if build_source present
      output_path: "..."              # required if build_source present

    # SHELL-INTEGRATION archetype only:
    shell_init: "..."                 # required; single line

    # IN-CAGE-DAEMON archetype only:
    start: "..."                      # required
    health: "..."                     # required
    state_dir: "/absolute/path"       # required; absolute, no spaces/metacharacters
    mcp_fragment: ...                 # optional
```
