# `rc reload <cage>` — host-side hot-reload for `.rip-cage.yaml` allowlists

**Date:** 2026-05-13
**Bead:** [rip-cage-ocn](#) (unblocked by rip-cage-g2q)
**Decisions:** [ADR-022 D6](../docs/decisions/ADR-022-ssh-allowlist.md)
**Builds on:** ADR-021 (`.rip-cage.yaml` substrate), ADR-022 D2/D3/D4 (allowlist mechanism), rip-cage-rx8 (inode-preserving in-place write recipe), rip-cage-jxy (`rc.ssh-key-filter` label-lock pattern)

## Problem

Today, editing `.rip-cage.yaml` requires `rc destroy && rc up` to take effect. That kills the tmux session, in-flight agent state, and any unattached work. For pure allowlist edits (the common case after the 2026-05-13 `switch.berlin` incident), the destroy/recreate is overkill — only the filtered cache file at `~/.cache/rip-cage/<cname>/known_hosts` actually needs to change.

The agent-facing pain shape, observed in the transcript that led to rip-cage-g2q:

1. Agent hits a wall ("can't ssh to switch.berlin")
2. Agent edits `.rip-cage.yaml`, asks human to recreate cage
3. Human runs `rc destroy && rc up`, tmux dies, agent reattaches
4. Agent retries, may still fail (would-be g2q etc.), debugging continues in a fresh session that lost prior context

`rc reload <cage>` collapses steps 3 onward to "no session interruption."

## Design forks resolved (brainstorm 2026-05-13)

### Fork 1 — Scope

**Decision: SSH allowlists only (`ssh.allowed_hosts`).** Refuse loud on everything else.

Rationale: smallest viable target that addresses the observed pain. `allowed_hosts` reload is mechanically trivial (rewrite cache file in-place; bind mount propagates). Other fields require mount-shape changes (allowed_keys null↔non-null), running-process reconfig (ssh-agent-filter daemon for allowed_keys content), or full container re-creation (egress mode, ports, identity). Keeping scope tight lets `rc reload` ship without a sprawling refuse-loud taxonomy.

### Fork 2 — `allowed_keys` reload

**Decision: v1 refuses loud on any `allowed_keys` change.** Both content changes (different list, same on/off shape) AND mount-shape transitions (null↔non-null↔[]) get `rc destroy && rc up` message.

Rationale: content changes would require restarting the `ssh-agent-filter` daemon inside the cage (find PID, kill, relaunch, re-symlink the socket) — possible but invasive, and only worth it if real usage demands. Mount-shape changes can't be done on a running container (mirrors `rc.ssh-key-filter` label-lock from rip-cage-jxy). Defer until someone asks.

### Fork 3 — Security boundary

**Decision: exposure boundary only.** No in-cage hook, no host-side container-detection check.

Initial draft considered an in-cage `block-rc-reload.sh` hook as defense-in-depth. Rejected for two reasons:

1. **Bypassable.** `~/.claude/settings.json` (the file that registers hooks) ends up at agent-owned `/home/agent/.claude/settings.json` per `init-rip-cage.sh:139`. An agent that decided to be hostile (or confused) could neuter the hook by editing settings.json. The hook script itself is root-owned at `/usr/local/lib/rip-cage/hooks/`, but the registration glue isn't.
2. **Leaks the bypass.** A deny message would advertise the existence of `rc reload` to an agent that hadn't otherwise discovered it. The cage telling you how to undermine itself is a self-defeating defense.

The actual enforcement is: `rc` binary is not on cage PATH, docker socket is not mounted into the cage. Same trust model as `rc up` today. Agent can edit `.rip-cage.yaml` (writable inside the cage); human is the approval step when they choose whether to run `rc reload`.

Hook-layer enforceability is a broader project gap tracked in rip-cage-2uv.

### Fork 4 — UX shape

**Decision: `rc reload <cage>` applies after printing diff; `--dry-run` prints diff without applying.**

Workflow: cage agent edits `.rip-cage.yaml` and surfaces a request to the human ("please run `rc reload <cage>` on the host"). Human (or host-side agent) optionally runs with `--dry-run` first to preview, then without. Non-interactive by default (script-friendly).

## Mechanism

Host-side. Re-uses existing primitives:

1. **Acquire reload lock** — `mkdir ~/.cache/rip-cage/<cname>/.reload.lock.d` (atomic on POSIX) to serialize against concurrent `rc reload`. Released via `trap rmdir EXIT`. Chosen over `flock` for macOS portability (no native flock binary). `rc up` resume's filter-refresh path is not lock-protected today — the race is benign (same content written). On non-acquisition, exit 3 with a message naming the lock dir.
2. **Validate** — read effective config (workspace `.rip-cage.yaml` + user/global), compute JSON-path diff against the per-container "applied-config snapshot" at `~/.cache/rip-cage/<cname>/config-applied.json` (written by `cmd_up` at create-time, refreshed by `cmd_up` resume for reload-eligible paths, and rewritten by `rc reload` after a successful apply). Use the JSON-path diff, **not** label comparison, because the `rc.config-loaded` label only carries the create-time sha and is immutable. If any differing path is not `.ssh.allowed_hosts`, refuse loud with the path name + remediation. Legacy containers without a snapshot are told to `rc destroy && rc up` to rebaseline.
3. **Re-filter** — call existing `_filter_known_hosts` (rc:1560) against the host's `~/.ssh/known_hosts`, write result to `~/.cache/rip-cage/<cname>/known_hosts` **in-place** per rip-cage-rx8 recipe: truncate + write the same inode, never `mv`-into-place. Bind mount points at the host path by inode, so mv would break the cage's view of the file. (Verified: `_filter_known_hosts` at rc:1577 already uses `: > "$_output"` truncate; existing code is rx8-correct.)
4. **Update snapshot** — rewrite `~/.cache/rip-cage/<cname>/config-applied.json` to the live effective-config JSON. `_config_emit_hint` consults this snapshot on subsequent `rc up` invocations: live == snapshot → silent; reload-eligible-only delta → hint "run `rc reload`"; any non-eligible delta → hint "run `rc destroy && rc up`".
5. **Propagate** — none needed. The bind mount inside the cage (`/home/agent/.ssh/known_hosts`, RO) reflects the new content on the next SSH call. No `docker exec`, no daemon restart, no tmux interruption.

Output: yaml diff (effective config before/after) and a one-line summary ("reloaded; 2 hosts added, 0 removed"). Exit codes: `0` (applied or no-op), `1` (refuse-loud — field changed that reload cannot handle), `2` (cage not running), `3` (concurrent reload in progress).

### Drift-hint update (resolves BLOCK from adversarial review)

Container labels (`rc.config-loaded=<sha>`) are immutable after creation. After `rc reload` succeeds, the label's sha is permanently stale relative to the live effective config. Without intervention, every subsequent `rc up` resume would emit a false-positive "config changed, recreate needed" hint.

Fix: `cmd_up` writes a per-container "applied-config snapshot" at `~/.cache/rip-cage/<cname>/config-applied.json` (effective-config JSON) on create. `cmd_up` resume merges reload-eligible paths from live into the snapshot (since resume re-applies `allowed_hosts` content via `_up_resolve_ssh_allowlists`). `rc reload` rewrites the snapshot to the new live config after a successful apply. `_config_emit_hint` then diffs live vs snapshot: empty → silent; reload-eligible-only → hint at `rc reload`; non-eligible → hint at `rc destroy && rc up`. Legacy containers (created before ocn) lack the snapshot and fall back to the original sha-label comparison.

### Stopped-cage handling

Design picks exit 2 (refuse) for stopped cages even though writing the cache while stopped technically works (the bind mount source is host-side). Rationale: the verb "reload" promises "the cage sees the change now"; running-only keeps the promise honest. Silent-rewrite-while-stopped would create a confusing "I reloaded but my ssh test still failed because the cage was stopped, then started, and now it works" failure mode. If usage shows demand for stopped-cage reload, revisit.

## Test plan

`tests/test-rc-reload.sh` (new). Cases:

- **Happy path**: write a `.rip-cage.yaml` with `allowed_hosts: [test.example]`, ensure host known_hosts has the entry, `rc reload <cage>` → `ssh-keygen -F test.example` inside cage finds the key.
- **No-op**: run `rc reload <cage>` with no yaml changes → exits 0, no file mutation, no sidecar update.
- **Refuse-loud, content**: change `allowed_keys` list → `rc reload` exits 1 with message naming `allowed_keys` and `rc destroy && rc up`.
- **Refuse-loud, mount-shape**: toggle `allowed_keys` from null to `[key1]` → same loud refusal.
- **Refuse-loud, other field**: change egress mode → loud refusal naming the field.
- **`--dry-run`**: change `allowed_hosts`, run with `--dry-run` → prints diff, does NOT modify cache file (inode + mtime unchanged), does NOT write sidecar.
- **Stopped cage**: `rc reload <cage>` on a stopped cage → exits 2 with "container not running; use `rc up`" message.
- **Inode preservation**: after `rc reload`, the cache file's inode equals what it was before reload (rx8 regression guard).
- **Concurrent reload**: two `rc reload` invocations in parallel — the second exits 3 while the first holds the lock dir.
- **Drift-hint (post-reload, allowed_hosts only)**: edit yaml + `rc reload` + `rc up` resume → resume emits NO drift warning (sidecar suppresses the false positive).
- **Drift-hint (post-reload, non-eligible delta)**: edit yaml to change egress mode → `rc up` resume STILL emits the recreate-needed warning (sidecar doesn't mask real drift).
- **Cache file mode + ownership** preserved across reload (0644, host user).
- **In-cage invocation negative test**: `docker exec <cage> rc reload <cage>` fails with command-not-found (rc binary not on PATH inside).

`docs/reference/ssh.md` gains a section on `rc reload`. `README.md` cage-lifecycle table adds the new verb. `CLAUDE.md` (project) gains one paragraph telling the agent the shape of the request to make of the human when SSH host trust changes.

## Composition with existing layers

- `block-ssh-bypass.sh` deny message currently points at `rc destroy <cage> && rc up <workspace>`. Updates to also suggest `rc reload <cage>` as the lighter-weight option when only `allowed_hosts` changed.
- `_up_resolve_resume_ssh_key_filter` (rip-cage-jxy) already aborts on mount-shape change at `rc up` time. `rc reload` re-uses the same comparison logic with a refuse-loud verdict instead of the resume-path abort.
- Documentation: project `CLAUDE.md` (mounted into cage) gets one paragraph telling the agent to ask the human about `rc reload` for new SSH host trust.

## Out of scope (deliberately)

- `allowed_keys` reload (content or mount-shape). Filed as latent extension if usage demands.
- Other `.rip-cage.yaml` fields (egress, ports, identity, env_file). Each has its own reconfig path that doesn't fit a content-only reload.
- Interactive prompt before applying. Non-interactive by default; the diff print is the human review step.
- Hot-reload triggered from inside the cage (filesystem watcher, agent-callable RPC, etc.). Would defeat the security boundary.
