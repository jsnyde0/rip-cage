<!-- begin:rip-cage-topology-pi -->
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

### Notable pi state paths

- Pi auth (ADR-019 D1): `/pi-agent/auth.json` is the auth credential file (`PI_CODING_AGENT_DIR=/pi-agent`)
- Pi extensions: `/pi-agent/extensions/` — global pi extensions directory

If a tool *inside* the cage works but your new connection doesn't, the problem
is almost always (a) wrong hostname (`localhost` instead of `$CAGE_HOST_ADDR`),
or (b) no published port on the target compose service.
<!-- end:rip-cage-topology-pi -->
