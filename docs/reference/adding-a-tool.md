# Adding a Plain Tool to Your Cage

This walkthrough shows how to add a binary-on-PATH tool to your rip-cage image using the **TOOL manifest entry** — the generic seam for any installable tool ([ADR-005 D7](../decisions/ADR-005-ecosystem-tools.md)).

**Scope:** this is the "plain tool" path. Multiplexers, mediators, and guards use the same `TOOL` archetype for the install step but also need additional fields (`MULTIPLEXER`/`MEDIATOR` archetype entries, hooks, etc.). See [docs/reference/README.md](README.md) for the full seam catalog.

**ADR-005 D12 (FIRM):** the tool you add is **not** blessed, bundled, or defaulted by rip-cage. The example below uses `ripgrep` (`rg`) as an illustration. You can replace it with any binary that installs similarly. Never modify `rc` source to add a tool — a manifest entry with zero source edits is the entire point.

---

## The manifest field shape

A TOOL entry declares:

- **`name`** — a unique identifier (no spaces; appears in image labels and error messages)
- **`archetype: TOOL`** — signals the plain-tool install path
- **`version_pin`** — a human-readable version string (used in labels and drift detection; does not drive any auto-download — your `install_cmd` is the source of truth)
- **`install_cmd`** — shell fragment executed inside a Dockerfile `RUN` step as root in the runtime stage. `rc build` wraps it with `apt-get update && <install_cmd> && rm -rf /var/lib/apt/lists/*` when apt packages are involved; a non-apt `install_cmd` (curl, copy) runs as-is.
- **`egress`** — list of hostnames the `install_cmd` must reach at build time (used for documentation; enforced by the build host's normal network, not by the cage firewall)
- **`mounts`** — list of host-path → cage-path bind mounts needed at runtime (may be empty)

```yaml
# Example shape (illustration only — replace with your tool)
- name: ripgrep
  archetype: TOOL
  version_pin: "14.1.1"
  install_cmd: >-
    ARCH=$(uname -m) &&
    if [ "$ARCH" = "aarch64" ]; then
      TARGET=aarch64-unknown-linux-musl
      EXPECTED_SHA=...
    else
      TARGET=x86_64-unknown-linux-musl
      EXPECTED_SHA=...
    fi &&
    curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${TARGET}.tar.gz" \
      -o /tmp/rg.tar.gz &&
    echo "${EXPECTED_SHA}  /tmp/rg.tar.gz" | sha256sum -c - &&
    tar -xzf /tmp/rg.tar.gz -C /tmp &&
    install -m 755 "/tmp/ripgrep-14.1.1-${TARGET}/rg" /usr/local/bin/rg &&
    rm -rf /tmp/rg.tar.gz "/tmp/ripgrep-14.1.1-${TARGET}"
  egress:
    - github.com
    - objects.githubusercontent.com
  mounts: []
```

**Key points:**
- Pin the version explicitly in both `version_pin` and the download URL — no `latest` ([ADR-005 D3](../decisions/ADR-005-ecosystem-tools.md)).
- Verify checksums before installing (sha256sum or equivalent). This matters especially for binary downloads.
- Install to `/usr/local/bin/` (or `/usr/local/lib/rip-cage/bin/` for cage-internal tooling). Root-owned binary, no agent-writable path.
- The `install_cmd` runs as root inside Docker, so `sudo` is not needed here.

---

## Step-by-step

### 1. Locate or create your global tool manifest

```bash
# Default location (rc install creates this file if absent):
cat ~/.config/rip-cage/tools.yaml
```

If the file does not exist yet, create it:

```yaml
version: 1
tools: []
```

### 2. Append your TOOL entry

Add the entry to the `tools:` list. The order matters for multi-tool compositions: entries are installed in declared order, and `launch_args` are assembled in fragment order ([ADR-027 D4](../decisions/ADR-027-agent-substrate-projection.md)).

```yaml
version: 1
tools:
  # ... existing entries ...
  - name: ripgrep
    archetype: TOOL
    version_pin: "14.1.1"
    install_cmd: >-
      ARCH=$(uname -m) &&
      if [ "$ARCH" = "aarch64" ]; then
        TARGET=aarch64-unknown-linux-musl; EXPECTED_SHA=your-sha-here
      else
        TARGET=x86_64-unknown-linux-musl; EXPECTED_SHA=your-sha-here
      fi &&
      curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-${TARGET}.tar.gz" -o /tmp/rg.tar.gz &&
      echo "${EXPECTED_SHA}  /tmp/rg.tar.gz" | sha256sum -c - &&
      tar -xzf /tmp/rg.tar.gz -C /tmp &&
      install -m 755 "/tmp/ripgrep-14.1.1-${TARGET}/rg" /usr/local/bin/rg &&
      rm -rf /tmp/rg.tar.gz "/tmp/ripgrep-14.1.1-${TARGET}"
    egress:
      - github.com
      - objects.githubusercontent.com
    mounts: []
```

### 3. Build the image

```bash
rc build
```

`rc build` reads `~/.config/rip-cage/tools.yaml`, generates the Dockerfile `RUN` steps for each entry, and builds the image. The image label `rc.tools` is updated to include the new tool name. If the `install_cmd` fails, the build fails loudly — no silent tool-absent cages ([ADR-005 D11](../decisions/ADR-005-ecosystem-tools.md)).

### 4. Start a cage and verify

```bash
rc up /path/to/workspace
# Inside the cage:
rg --version
```

---

## Runtime mounts (if needed)

If the tool needs a host-side config file inside the cage, add a mount:

```yaml
- name: my-tool
  archetype: TOOL
  version_pin: "1.0.0"
  install_cmd: "apt-get install -y my-tool"
  egress: []
  mounts:
    - host: "~/.config/my-tool"
      dest: "/home/agent/.config/my-tool"
      mode: "ro"   # ro = read-only (default, recommended); rw = writable from inside
```

`mode: ro` means the cage can read the config but cannot write back to the host. `mode: rw` is a live write-through bind mount — opt-in for workflows where the agent improves its own config. See [config.md — `mounts.*`](config.md) for the per-asset ro/rw mechanics and security posture.

---

## Apt-installed tools (simpler path)

If your tool ships in the Debian repos, `install_cmd` is just the apt install step:

```yaml
- name: jq
  archetype: TOOL
  version_pin: "1.6-debian"
  install_cmd: "apt-get install -y --no-install-recommends jq"
  egress: []
  mounts: []
```

`rc build` wraps this with `apt-get update` and list cleanup automatically.

---

## See also

- [docs/reference/README.md](README.md) — seam catalog (TOOL manifest + all other seams)
- [examples/dcg/manifest-fragment.yaml](../../examples/dcg/manifest-fragment.yaml) — a real TOOL entry for a from-source build (DCG)
- [examples/herdr/manifest-fragment.yaml](../../examples/herdr/manifest-fragment.yaml) — TOOL + MULTIPLEXER entry pattern
- [examples/herdr-pi/README.md](../../examples/herdr-pi/README.md) — TOOL entry with `launch_args` (launch composition)
- [ADR-005 D7/D11/D12](../decisions/ADR-005-ecosystem-tools.md) — manifest contract, validator, composable-seam principle
