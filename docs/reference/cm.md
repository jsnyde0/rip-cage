# cm — Host L2A Store in the Cage

`cm` is the **cass-memory CLI** (`github.com/gastownhall/cass-memory`). When the operator's
host has a cm store, rip-cage bind-mounts it read-write into the cage at
`/home/agent/.cass-memory` so the in-cage agent can read from and write to the **same**
Tier 2A (L2A) observation/calibration store as the host agent.

---

## Mount mechanics

`rc up` resolves the host cm store path using cm's own precedence
(mirroring `src/utils.ts` store resolution):

1. `$CASS_MEMORY_HOME` — if set and the directory exists
2. `$XDG_DATA_HOME/cass-memory` — if `XDG_DATA_HOME` is set and that directory exists
3. `~/.cass-memory` — the default fallback

The resolved path is mounted at `/home/agent/.cass-memory` (read-write). The cage sets
neither `CASS_MEMORY_HOME` nor `XDG_DATA_HOME`, so in-cage `cm` resolves to the default
`~/.cass-memory = /home/agent/.cass-memory` — the mount target.

**If the host store does not exist:** `rc up` logs a warning and skips the mount. In-cage
`cm` then reads/writes a container-local store (lost on `rc destroy`). No crash.

**If the host store is present:** `rc up` logs the mount expansion to stderr:

```
[rip-cage] cm store: mounting /path/to/host/cass-memory → /home/agent/.cass-memory (rw)
```

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
this surface so in-cage Claude Code agents discover it automatically.

---

## Security note (ADR-024 D1)

The cm mount is **read-write**. This means a prompt-injected in-cage agent can read from
and write to the host L2A store — injecting or modifying observations and calibrations that
would influence future agent sessions on the host.

**This risk is accepted** for the following reasons:

- The rip-cage threat model is **non-adversarial** (ADR-024 D1): it targets accident and
  prompt-injection from non-adversarial fetched content, not a motivated attacker operating
  inside the cage.
- In-cage L2A participation is the **point** of the mount. Preventing writes would defeat it.
- The operator opts in by having a host cm store. If no store exists, the mount is skipped.

**Operator mitigation options:**
- Run with no host cm store to skip the mount entirely (in-cage L2A is container-local only).
- Periodically audit `cm playbook list` on the host for anomalous entries after cage sessions.
- If you need read-only in-cage access, file a rip-cage issue — the current design is RW.

---

## Image availability

`cm` is compiled into the image from source via the `cm-builder` Dockerfile stage
(rip-cage-l0u2.1). It is available at `/usr/local/bin/cm` in every cage built from
`rip-cage:latest`. No manifest entry is required — it is a baked tool, not an
IN-CAGE-DAEMON archetype.

`init-rip-cage.sh` detects cm via `command -v cm` (ADR-005 D5 pattern) and logs its
availability at startup.
