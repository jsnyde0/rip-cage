# cm — Host L2A Store in the Cage

`cm` is the **cass-memory CLI** (`github.com/Dicklesworthstone/cass_memory_system`). When the operator's
host has a cm store, rip-cage bind-mounts it read-write into the cage at
`/home/agent/.cass-memory` so the in-cage agent can read from and write to the **same**
Tier 2A (L2A) observation/calibration store as the host agent.

---

## Image availability (opt-in via manifest — ADR-005 D2/D6)

**cm is NOT baked into the default `rip-cage:latest` image.** It is provisioned as an
opt-in tool via the rip-cage manifest mechanism (ADR-005 D2/D6/D11, rip-cage-buuo.5).

To add cm to your cage, copy the worked-example manifest entry from
`tests/fixtures/manifest-cm-example.yaml` into your host manifest
(`~/.config/rip-cage/tools.yaml` — the ADR-005 D7 host manifest path):

```yaml
# In ~/.config/rip-cage/tools.yaml
version: 1
tools:
  - name: cm
    archetype: TOOL
    version_pin: "2e63e9b"
    egress: []
    mounts:
      # ~/.cass-memory works as-is — rc expands ~/ to $HOME at rc-up time.
      # mode: rw is explicit — ro is now the default (rip-cage-wlwc.3).
      - host: "~/.cass-memory"
        dest: "/home/agent/.cass-memory"
        mode: rw
    build_source:
      builder_image: "debian:trixie"
      build_script: "tests/fixtures/build-cm-from-source.sh"
      output_path: "/usr/local/bin/cm"
```

Then rebuild your image: `rc build`. The `build_source` entry compiles cm from source in
an isolated Dockerfile stage (arch-adaptive — no hardcoded `--target` flag; arm64 and amd64
both produce a native binary).

**ADR-005 D5 four-point opt-in pattern:**
1. `build_source` — builds cm from source in an isolated stage (arch-adaptive)
2. `egress: []` — cm opens zero external connections (pure local storage)
3. `mounts` — RW bind mount for the host cm store (see note below)
4. Detection — agents discover cm via `command -v cm` inside the cage

---

## Mount mechanics

The manifest `mounts` entry binds the host cm store RW at `/home/agent/.cass-memory`.
The mount declares `mode: rw` explicitly — **ro is the default** as of rip-cage-wlwc.3,
so write-through mounts must always be declared with `mode: rw`. The generic mount consumer
(`_manifest_build_mount_args`) emits `:rw` when `mode: rw` is declared, `:ro` otherwise.

**Tilde and `$HOME` expansion (rip-cage-buuo.5):**
The rc mount consumer expands a leading `~/` or `$HOME/` (and `${HOME}/`) prefix to the
host's `$HOME` before the existence check and ADR-023 denylist run. The `~/.cass-memory`
entry in the cm manifest example works out of the box — no per-user absolute-path editing
required. The ADR-023 denylist check runs **after** expansion, so `~/.ssh` and similar
patterns are still rejected by the denylist (expansion does not bypass security).

If you use `CASS_MEMORY_HOME` or `XDG_DATA_HOME` to point cm to a non-default location,
update the manifest entry's `mounts.host` to that absolute path.

**If the host store does not exist:** the manifest mount consumer skips the mount silently
(skip-if-missing). In-cage `cm` then reads/writes a container-local store (lost on
`rc destroy`). No crash.

---

## In-cage usage

```bash
# Surface context relevant to a task before starting work
cm context "<task description or keywords>"

# Add an observation (something discovered during a session)
cm playbook add --category=observation "Short descriptive title"

# Add a calibration (a confirmed behavioral adjustment)
cm playbook add --category=calibration "Short descriptive title"

# List all stored entries
cm playbook list
```

The cage's `~/.claude/CLAUDE.md` (appended from `/etc/rip-cage/cage-claude.md`) documents
this surface so in-cage Claude Code agents discover it automatically (when cm is installed).

---

## Security note (ADR-024 D5)

The cm mount is **read-write**. This means a prompt-injected in-cage agent can read from
and write to the host L2A store — injecting or modifying observations and calibrations that
would influence future agent sessions on the host.

**This risk is accepted** for the following reasons:

- ADR-024 D5 ("injection-affected agent is still trying to do its job") is the load-bearing
  rationale: the cage's "layers not walls" philosophy is coherent precisely because an
  honest (or injection-affected) agent does not coordinate across layers to find a bypass —
  it surfaces refusals and acts in good faith. D1 only admits prompt-injection as a threat
  class in scope; D5 is what actually permits accepting the RW-mount risk.
- The rip-cage threat model covers **non-adversarial** agents (ADR-024 D5): an
  injection-affected agent following hostile instructions is still "trying to do its job"
  and subject to cage controls; it is not coordinating to route around them.
- CLAUDE.md "layers not walls / operator opt-in": the operator opts in by having a host
  cm store AND a manifest entry; absent either → no mount.
- In-cage L2A participation is the **point** of the mount. Preventing writes would defeat it.

**Operator mitigation options:**
- Do not include the cm manifest entry to skip cm entirely.
- Use no host cm store — the mount is skipped silently (skip-if-missing).
- Periodically audit `cm playbook list` on the host for anomalous entries after cage sessions.
- If you need read-only in-cage access, file a rip-cage issue — the current design is RW.
