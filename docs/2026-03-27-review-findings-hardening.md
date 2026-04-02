# Design: Review Findings — Safety Stack Hardening

**Date:** 2026-03-27
**Status:** Accepted
**Decisions:** Amends [ADR-002](decisions/ADR-002-rip-cage-containers.md) D12; no new ADR decisions needed
**Origin:** Code review of epic rip-cage-a5m surfaced 4 findings (1 important, 3 minor).

---

## Problem

The rip-cage-a5m review identified four issues, ranging from a security gap to minor robustness and test coverage improvements:

1. **`chown *` sudoers is overly permissive** — The agent can `sudo chown agent:agent /usr/local/bin/dcg` then overwrite DCG with a no-op. This is the same safety-stack tampering that D12 exists to prevent and that motivated removing `npm install -g`. The actual usage is only two paths: `~/.claude` and `/home/agent/.claude-state`.

2. **`resolve_name` swallows Docker errors** — When Docker daemon is unreachable, `docker ps` returns empty stdout and writes to stderr. The function reports "no rip-cage containers found" instead of the actual error, giving a misleading message.

3. **`respawn-pane` doesn't specify working directory** — If the user `cd`'d to a since-deleted directory, the respawned pane may fail silently. Specifying `-c /workspace` ensures a reliable starting point.

4. **Security test 4 is static-only** — `test-security-hardening.sh` test 4 greps the Dockerfile source for the sudoers line rather than verifying runtime behavior. It passes without a built image and wouldn't catch manual edits inside a running container.

## Goal

Address all 4 findings in minimal, targeted changes.

## Non-Goals

- Redesigning the sudoers model beyond what's needed for Phase 1
- Adding a Docker daemon health-check framework
- Runtime integration tests that require a running container (those belong in `test-safety-stack.sh`, run via `rc test`)

---

## Design

### 1. Scope `chown` in sudoers — exact paths + pre-created directories

**Approach:** Belt-and-suspenders. Pre-create directories in the Dockerfile (reducing how often chown is needed) AND pin sudoers to exact paths (safety net when Docker overrides ownership at mount time).

**Decision rationale:** Three options were evaluated via parallel adversarial analysis:

| Option | Approach | Verdict |
|---|---|---|
| A: Wrapper script (`rc-chown`) | Bash script validates paths via `realpath` | Rejected — new bash running as root is itself an attack surface; TOCTOU risk; over-engineering for 2 static paths |
| B: Pre-create dirs, remove chown entirely | `mkdir` in Dockerfile, zero sudoers | Rejected alone — Docker bind mounts can overwrite image-layer ownership at runtime; no recovery path if ownership is wrong |
| C: Exact-path sudoers | Pin to exact command strings | Adopted — minimal, auditable, zero new code; exact-match sudoers does literal string comparison |

**Combined approach (B+C):** Pre-create directories (B) so chown is rarely needed, plus exact-path sudoers (C) as the fallback.

#### Dockerfile changes

**Pre-create directories** (after `USER agent`, before COPY):
```dockerfile
USER agent
WORKDIR /home/agent
# Pre-create mount targets so Docker inherits agent ownership on first use.
# If Docker overrides ownership at mount time, init-rip-cage.sh has scoped
# sudo chown as a fallback (see sudoers below).
RUN mkdir -p /home/agent/.claude /home/agent/.claude-state
COPY --chown=agent:agent zshrc /home/agent/.zshrc
COPY --chown=agent:agent tmux.conf /home/agent/.tmux.conf
```

**Pin sudoers to exact paths** (line 64):
```
agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/chown agent\:agent /home/agent/.claude, /usr/bin/chown agent\:agent /home/agent/.claude-state
```

**Why exact paths, not wildcards:** Sudoers `*` matches across word boundaries in arguments. `/usr/bin/chown agent:agent /home/agent/*` would match `sudo chown agent:agent /home/agent/.claude /usr/local/bin/dcg` — the agent could chown the safety binary by appending it as a second argument. Exact-match entries prevent this.

**Why keep chown at all (not pure Option B):** Named volumes copy image-layer ownership on first creation, but NOT on subsequent mounts. If a volume was created by a previous Docker version or runtime, ownership may be root. The `|| true` on the existing chown calls confirms this edge case has been observed. Removing chown entirely leaves no recovery path.

**Symlink concern:** With exact-path sudoers, the agent could `ln -s /usr/local/bin/dcg /home/agent/.claude` then run the sudoers-approved chown. However, this requires the agent to already control `/home/agent/` (self-attack, not privilege escalation) AND the symlink would break Claude Code's init. Acceptable risk for Phase 1.

#### init-rip-cage.sh changes

No changes needed. The existing `sudo chown agent:agent ~/.claude` and `sudo chown agent:agent /home/agent/.claude-state` calls match the exact sudoers entries. The `|| true` guard on line 7 remains correct — the chown may be unnecessary when pre-created dirs retain ownership.

### 2. Surface Docker errors in `resolve_name`

**File:** `rc` (function `resolve_name`, lines 426-427)

**Current:**
```bash
containers=$(docker ps -a --filter label=rc.source.path --format '{{.Names}}')
```

**Replace with:**
```bash
if ! containers=$(docker ps -a --filter label=rc.source.path --format '{{.Names}}'); then
  echo "Error: failed to list containers (is Docker running?)" >&2
  return 1
fi
```

Docker's own stderr already reaches the user's terminal, so we just add a clear error message and exit non-zero. No temp files needed.

### 3. Specify working directory for `respawn-pane`

**File:** `init-rip-cage.sh` (line 83)

**Current:**
```bash
tmux set-hook -t rip-cage pane-died 'respawn-pane' 2>/dev/null || true
```

**Replace with:**
```bash
tmux set-hook -t rip-cage pane-died 'respawn-pane -c /workspace' 2>/dev/null || true
```

Trivial one-line change. Ensures respawned panes always start in the project root.

### 4. Improve security test coverage

**File:** `test-security-hardening.sh`

Update existing test 4 to verify exact-path sudoers (no unrestricted `chown *`), and add a new test 5 for runtime verification when a container is available.

**Updated test 4:**
```bash
# --- Test 4: Dockerfile sudoers does NOT contain unrestricted chown ---
echo "-- Test 4: Dockerfile sudoers pins chown to exact paths --"
SUDOERS_LINE=$(grep 'sudoers.d/agent' "$SCRIPT_DIR/Dockerfile")
if echo "$SUDOERS_LINE" | grep -q '/usr/bin/chown \*'; then
  fail "sudoers still contains unrestricted /usr/bin/chown *"
elif echo "$SUDOERS_LINE" | grep -q '/usr/bin/chown agent'; then
  pass "sudoers pins chown to exact paths (static check)"
else
  fail "sudoers does not contain any chown entry"
fi
```

**New test 5 (runtime, skipped if no container):**
```bash
# --- Test 5: Runtime sudoers verification (requires running container) ---
echo ""
echo "-- Test 5: runtime sudoers denies unsafe chown (skip if no container) --"
CONTAINER=$(docker ps --filter label=rc.source.path --format '{{.Names}}' 2>/dev/null | head -1)
if [[ -z "$CONTAINER" ]]; then
  echo "  SKIP: no running rip-cage container"
else
  # Should be denied: chown on safety-stack binary
  if docker exec "$CONTAINER" sudo chown agent:agent /usr/local/bin/dcg 2>&1 | grep -qi 'not allowed\|sorry\|permission'; then
    pass "runtime: sudo chown on /usr/local/bin/dcg denied"
  else
    fail "runtime: sudo chown on /usr/local/bin/dcg was NOT denied"
  fi
  # Should succeed: chown on allowed path
  if docker exec "$CONTAINER" sudo chown agent:agent /home/agent/.claude 2>/dev/null; then
    pass "runtime: sudo chown on /home/agent/.claude allowed"
  else
    fail "runtime: sudo chown on /home/agent/.claude denied"
  fi
fi
```

---

## File Change Summary

| File | Change | Lines |
|---|---|---|
| `Dockerfile` | Pre-create dirs; pin sudoers to exact chown paths | ~4 |
| `rc` | `resolve_name`: check `docker ps` exit code, surface errors | ~4 |
| `init-rip-cage.sh` | `respawn-pane` → `respawn-pane -c /workspace` | 1 |
| `test-security-hardening.sh` | Update test 4 (static), add test 5 (runtime) | ~20 |
| ADR-002 | Amend D12: document exact-path scoping + pre-created dirs | ~5 |

**Total:** ~34 lines changed/added across 5 files. No new files.

---

## Risks

- **Symlink attack on exact-path sudoers** — Agent could replace `/home/agent/.claude` with a symlink to a safety-stack binary before chown runs. Mitigated: requires agent to already control `/home/agent/` (self-attack) and would break Claude Code init. Acceptable for Phase 1.
- **Future mount paths** — Adding a new bind mount under `/home/agent/` that needs chown requires updating both the Dockerfile `mkdir` and the sudoers line. This is intentional — explicit > implicit for security policy.

## Testing

1. `./rc build` — validates Dockerfile (pre-created dirs, pinned sudoers)
2. `bash test-security-hardening.sh` — 5+ tests pass (static checks, no Docker needed for tests 1-4)
3. `./rc up . && ./rc test` — 6/6 safety stack tests pass
4. Inside container: `sudo chown agent:agent /usr/local/bin/dcg` → denied
5. Inside container: `sudo chown agent:agent /home/agent/.claude` → allowed
6. Inside container: `sudo chown agent:agent /home/agent/.zshrc` → denied (not in exact-path list)
