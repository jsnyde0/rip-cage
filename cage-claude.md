<!-- begin:rip-cage-topology -->
## Rip-Cage Network Topology (cage-authored)

You are running inside a **rip-cage** Docker container on the user's host (macOS
or Linux). This section tells you where things are and how to reach them from
*inside* the cage.

### Filesystem

- `/workspace` is the only host path mounted in. Everything outside `/workspace`
  is cage-local (ephemeral, lost on `rc destroy`).
- Cage `$HOME` is `/home/agent` — agent-local, not the user's real home.

### Networking

- `localhost` and `127.0.0.1` refer to the **cage**, not the host. A service
  on `localhost:5432` inside the cage is a service running in this container.
- To reach a service running on the **host**, use `$CAGE_HOST_ADDR`
  (set by init; falls back to literal `host.docker.internal`). Example:
  ```bash
  # Probe a specific host port without guessing
  python3 -c "import socket; s=socket.socket(); s.settimeout(2); \
    s.connect(('$CAGE_HOST_ADDR', 5432)); print('OPEN')"
  ```
- A sibling `docker-compose` service from *another* project is only reachable
  from the cage if one of these is true:
  (a) that service publishes its port via `ports:` in its compose file, in
      which case it's reachable at `$CAGE_HOST_ADDR:<published-port>`; or
  (b) the cage is attached to that project's compose network (future
      `rc up --join-network`; not available today).
  If neither applies, you will see `connection refused` or `no route` no
  matter what hostname or IP you try.
- The egress firewall (ADR-012) restricts *internet* access, not host access.
  "I can reach `$CAGE_HOST_ADDR`" and "I can reach github.com" are independent
  questions — do not conflate `connection refused` (no service on that port)
  with `firewall blocked` (destination not in allowlist).

### Debug recipes

```bash
# Is the host bridge resolvable?
getent hosts "$CAGE_HOST_ADDR"

# Is a specific host port reachable?
python3 -c "import socket; s=socket.socket(); s.settimeout(2); \
  s.connect(('$CAGE_HOST_ADDR', PORT)); print('OPEN')"

# Where am I? (runtime / bridge name)
echo "CAGE_HOST_ADDR=$CAGE_HOST_ADDR"
```

### Precedents inside the cage that already use this bridge

- Beads Dolt server (ADR-007): `BEADS_DOLT_SERVER_HOST=host.docker.internal`
- Firewall CA trust (ADR-012): proxy endpoint lives on the host

If a tool *inside* the cage works but your new connection doesn't, the problem
is almost always (a) wrong hostname (`localhost` instead of `$CAGE_HOST_ADDR`),
or (b) no published port on the target compose service.

### Troubleshooting: subagent fails fast (0 tokens, ~2s)

If a subagent dispatch (`Agent(subagent_type=...)`) returns after ~2 seconds
with **0 tool uses and 0 tokens**, the parent model will often narrate this as
"auth error" or similar — **do not trust that narration**. It is a guess, not a
diagnosis. Get the real error before theorizing or switching subagent types:

```bash
claude -p --debug --debug-file /tmp/sub.log \
  "Use the Agent tool with subagent_type=general-purpose, prompt=\"reply hello\""
cat /tmp/sub.log | tail -50
```

Known causes, in order of likelihood:

1. **1M-context beta model + subagent dispatch.** If the parent is on a
   `[1m]` model variant, subagent spawn can fail opaquely. Try `/model` → a
   non-1M variant and retry.
2. **Rate limit / quota ceiling** surfaced as a fast rejection. Check account
   usage on the host.
3. **Stale session state** in a long-running conversation. Starting a fresh
   session often clears it.

The cage itself is almost never the cause — subagent dispatch, custom agent
mounts, and OAuth all work in a clean rip-cage container. Reproduce against a
fresh scratch project if you're unsure which layer owns the bug.
<!-- end:rip-cage-topology -->
