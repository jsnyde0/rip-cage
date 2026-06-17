# Compose rip-cage with mitmproxy (Reference MEDIATOR Recipe)

This recipe shows how to attach [mitmproxy](https://mitmproxy.org/) as a co-located
in-cage egress mediator. The combination yields:

- **rip-cage provides:** forced capture of all HTTP/HTTPS and DNS egress (the agent
  cannot bypass); destination-level allow/deny (SNI router); DNS exfil heuristic;
  IOC floor (non-overridable deny list).
- **mitmproxy provides:** TLS-MITM; L7 content inspection; credential non-possession
  (the agent holds a placeholder token; the injection addon replaces it with the real
  secret on the wire, before the request reaches the upstream).

**Threat tier achieved:** exfil-grade — credential non-possession closes the
credential-exfil axis that standalone rip-cage leaves open (see
[ADR-026 D6](../docs/decisions/ADR-026-containment-mediation-identity.md)).

**Important:** This recipe targets the **Linux-cage path** (the supported production
path). Docker containers on Linux support the `NET_ADMIN` capability and the
`iptables REDIRECT` rules that rip-cage's egress chokepoint requires.

This file lives under `examples/` per
[ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md) — rip-cage bundles
nothing; this is a copyable recipe, not a baked integration.

---

## How the seam works

```
Agent (inside cage)
  │
  │  TCP/443 or TCP/80
  ▼
rip-cage router (rip_cage_router.py)
  │
  │  Destination check: allowed? → yes
  │  network.http.forward_to = "127.0.0.1:8888"
  │  HTTP CONNECT <orig-dst>:<port> → mitmdump on :8888
  ▼
mitmdump (rip-mitmproxy uid, 127.0.0.1:8888)
  │
  │  TLS-MITM: sees plaintext request
  │  inject_credential.py: replaces placeholder → real secret
  │  Re-originates TLS to actual upstream (rip-mitmproxy uid,
  │  exempted from REDIRECT by init-firewall.sh Step 1a)
  ▼
Real upstream (httpbin.org, api.anthropic.com, ...)
```

The agent sends a placeholder Authorization header. mitmproxy intercepts it, replaces
the placeholder with the real secret (from `RIPCAGE_MEDIATOR_BEARER_SECRET` in
mitmdump's process env), and re-originates the request. The real secret is never in
the agent's environment — credential non-possession.

---

## Steps

### 1. Add the mitmproxy entries to your manifest

Edit `~/.config/rip-cage/tools.yaml` (global) or a project-level `tools.yaml`.
**Two entries are required** — copy them from `examples/mitmproxy/manifest-fragment.yaml`:

```yaml
version: 1
tools:
  - name: mitmproxy-bin
    archetype: TOOL
    version_pin: "11.0.2"
    install_cmd: "..."   # see manifest-fragment.yaml for the full command
    egress:
      - pypi.org
      - files.pythonhosted.org
    mounts: []

  - name: mitmproxy
    archetype: MEDIATOR
    version_pin: "11.0.2"
    run_as_uid: "rip-mitmproxy"
    hooks:
      start: "/opt/rip-cage-mitmproxy/bin/mitmdump --mode regular ... --listen-port 8888 ..."  # see manifest-fragment.yaml
      teardown: "pkill -u rip-mitmproxy mitmdump || true"
```

See `examples/mitmproxy/manifest-fragment.yaml` for the full, copy-paste-ready entries.

### 2. Build the image

```bash
rc build
```

This bakes mitmproxy into the image:
- Creates the `rip-mitmproxy` system user (uid-exemption subject, ADR-026 D5).
- Installs mitmproxy 11.0.2 into `/opt/rip-cage-mitmproxy/` (root-owned).
- Writes the injection addon at `/opt/rip-cage-mitmproxy/addon/inject_credential.py`.
- Bakes the `start` and `teardown` hook strings into
  `/etc/rip-cage/mediators/mitmproxy/` in the image.
- Stamps `LABEL rc.mediators="mitmproxy"` so the config validator accepts
  `network.egress.mediator: mitmproxy` in `.rip-cage.yaml`.

### 3. Configure the workspace

In the workspace `.rip-cage.yaml`:

```yaml
version: 1
network:
  mode: block
  allowed_hosts:
    - api.anthropic.com
    - httpbin.org
    # ... other hosts the agent needs
  egress:
    mediator: mitmproxy
  http:
    forward_to: "127.0.0.1:8888"
```

`network.http.forward_to` tells the router to send allowed HTTP/HTTPS traffic to
mitmdump's listen address via HTTP CONNECT, instead of origin-splicing directly.

`network.egress.mediator: mitmproxy` tells rip-cage to run the MEDIATOR lifecycle
(start hook at cage init) and is validated against the baked `rc.mediators` label.

### 4. Configure the real secret (host-side only)

The real credential must reach the mitmproxy process environment at cage start time,
**NOT the agent's environment**. Use `--mediator-env` (not `--env`):

> **Important — re-supply on every `rc up`, including resume.**
> The secret intentionally never persists in the container filesystem or
> `/proc/1/environ` (ADR-024 D2 non-persistence guarantee). After `rc down`, the
> mediator process is killed and the secret is gone. On the next `rc up` (resume or
> fresh start) `init-mediator.sh` re-launches the mediator, but if you omit
> `--mediator-env` the secret is absent and the injection addon silently no-ops —
> the agent will send the placeholder token to the upstream instead of the real
> secret. Always re-supply `--mediator-env RIPCAGE_MEDIATOR_BEARER_SECRET=...` on
> every `rc up`.

```bash
rc up /path/to/workspace \
  --mediator-env RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-real-key-here \
  --mediator-env RIPCAGE_MEDIATOR_PLACEHOLDER=ripcage-placeholder
```

**Why `--mediator-env`, not `--env`?**  
`--env` passes vars to `docker run`, which places them in the container's
`/proc/1/environ` (readable by the agent). `--mediator-env` delivers vars only to
the `init-mediator.sh` root docker exec that launches mitmdump — they never appear
in `/proc/1/environ` or the agent's own environment. This is the non-possession
guarantee (ADR-024 D2 / rip-cage-ta1o.5.8).

Or use a secrets file:

```bash
# In a file NOT committed to version control (.gitignore it):
RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-real-key-here
RIPCAGE_MEDIATOR_PLACEHOLDER=ripcage-placeholder
```

```bash
rc up /path/to/workspace --mediator-env-file /path/to/.mediator-secrets
```

**The real secret must never appear in the agent's environment.** Set only the
placeholder in the agent env (step 5).

### 5. Configure the agent placeholder

In the agent's environment inside the cage, set the placeholder:

```bash
# In .rip-cage.yaml env block, or via rc up --env:
ANTHROPIC_API_KEY=ripcage-placeholder
# Or any other placeholder value — just don't put the real key here
```

The agent sends `Authorization: Bearer ripcage-placeholder` on its requests;
mitmproxy's `inject_credential.py` intercepts and replaces it with
`Authorization: Bearer <real-secret>` before the request reaches the upstream.

`RIPCAGE_MEDIATOR_PLACEHOLDER=ripcage-placeholder` (set via `--mediator-env` in
step 4) tells the addon to only replace headers matching the placeholder, passing
other headers through unchanged.

If `RIPCAGE_MEDIATOR_PLACEHOLDER` is absent, the addon replaces the Authorization
header unconditionally (useful for development).

### 6. Start the cage

```bash
rc up /path/to/workspace \
  --mediator-env RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-real-key-here \
  --mediator-env RIPCAGE_MEDIATOR_PLACEHOLDER=ripcage-placeholder
```

At `rc up` time:
1. The cage container starts with `sleep infinity`.
2. rip-cage's firewall initializes:
   - `iptables` REDIRECT rules capture all TCP 80/443 egress to the router.
   - `init-firewall.sh` Step 1a reads `/etc/rip-cage/mediators/mitmproxy/run_as_uid`
     and adds an OUTPUT RETURN rule for `rip-mitmproxy`'s numeric uid — this prevents
     mitmproxy's own re-originated egress from being re-captured (loop prevention).
3. **`init-mediator.sh` runs as a host-driven root docker exec** (rip-cage-ta1o.5.8):
   - Reads the `mitmproxy` registry entry from `/etc/rip-cage/mediators/mitmproxy/`.
   - Privilege-drops to the `rip-mitmproxy` uid via `nohup su ...`.
   - Launches `mitmdump` in regular CONNECT-proxy mode under `rip-mitmproxy`,
     listening on `127.0.0.1:8888`. Uses `nohup ... &` so the process survives
     the exec session return.
   - Installs mitmproxy's CA cert into the system trust store (`ca_cert_path`
     registry field → `update-ca-certificates` → `NODE_EXTRA_CA_CERTS`).
   - Writes PID to `/run/rip-cage-mediator-mitmproxy.pid` for idempotency.
   - Logs go to `/tmp/rip-cage-mediator-mitmproxy.log` (cage-lifetime).

### 7. Verify the injection is working

From inside the cage (via `rc exec <cage>`):

```bash
# The agent env has only the placeholder:
echo $ANTHROPIC_API_KEY   # → ripcage-placeholder

# Confirm the router is on-path (force-through guarantee):
curl -v http://selftest.rip-cage.internal/ 2>&1 | grep x-rip-cage-selftest

# Confirm credential injection: the echo shows the REAL secret, not the placeholder.
# (httpbin.org/headers echoes back all request headers)
curl -H "Authorization: Bearer ripcage-placeholder" https://httpbin.org/headers

# Expected: Authorization header in response body contains "Bearer sk-ant-real-key..."
# NOT "Bearer ripcage-placeholder"

# Confirm the floor still holds — a non-allowlisted host is still denied:
curl https://evil.example.com 2>&1   # → connection refused (router blocks at destination)
```

### 8. Troubleshooting

- **mitmproxy not starting**: Check `/tmp/rip-cage-mediator-mitmproxy.log` inside the cage.
- **Placeholder not replaced**: Confirm `RIPCAGE_MEDIATOR_BEARER_SECRET` is set in the
  mitmproxy process env (NOT the agent env). The addon logs to stderr, redirected to
  `/tmp/rip-cage-mediator-mitmproxy.log`.
- **TLS errors / CERT_VERIFY_FAILED**: `init-mediator.sh` automatically installs
  mitmproxy's CA cert at cage start (`ca_cert_path` registry field). If it still
  fails (e.g. timing race — cert generated after init-mediator.sh ran), trigger
  a manual re-install:
  ```bash
  docker exec -u root <cage> bash -c "
    cp /opt/rip-cage-mitmproxy-home/.mitmproxy/mitmproxy-ca-cert.pem \
       /usr/local/share/ca-certificates/mitmproxy-ca.crt
    update-ca-certificates
  "
  ```
  For Node.js (Claude Code), `NODE_EXTRA_CA_CERTS` is set automatically by
  `init-mediator.sh` in `/etc/rip-cage/firewall-env`.
- **Port conflict**: The mediator MUST listen on a port distinct from the rip-cage
  router's own listen port (`127.0.0.1:8080`). `8888` (the router's
  `_MEDIATOR_DEFAULT_PORT`) is the recommended default. Using `8080` collides with
  the router (`EADDRINUSE`) and would loop the router back to itself. If `8888` is
  also taken, change both `--listen-port` in the MEDIATOR `start` hook and
  `network.http.forward_to` in `.rip-cage.yaml` to another unused port (e.g. `8889`).
  Rebuild after changing the hook.

---

## How the mediator lifecycle dispatcher works

The mediator `start` hook is dispatched at cage init by a **host-driven root docker
exec** step in `cmd_up` (rip-cage-ta1o.5.8). `rc up` calls `init-mediator.sh` as
root immediately after `init-firewall.sh` — both on container create and on resume
(stop re-kills the mediator; the resume path re-launches it).

`init-mediator.sh` reads `/etc/rip-cage/mediators/<name>/` from the baked registry,
privilege-drops to the configured uid via `nohup su ... &`, and writes the PID to
`/run/rip-cage-mediator-<name>.pid` for idempotency (re-run on an already-running
mediator is a no-op).

The secret (`--mediator-env` vars) reaches mitmdump's process env via the `docker
exec -e` channel and is never written to the container filesystem or `/proc/1/environ`.

---

## Security notes

- The real secret (`RIPCAGE_MEDIATOR_BEARER_SECRET`) lives in mitmproxy's process env
  only — the agent cannot read it via `/proc/self/environ` because mitmproxy runs as
  `rip-mitmproxy` (a different uid from `agent`).
- mitmproxy must be in the egress allowlist of any upstream it re-originates to (it
  runs as `rip-mitmproxy`, which is uid-exempted from the REDIRECT rule — its traffic
  goes direct to the upstream, not back through the router).
- rip-cage's IOC floor (known exfil sinks) is enforced at the router before the CONNECT
  handoff — mitmproxy cannot receive traffic destined for IOC-denied hosts.

---

## See Also

- [composition-seam.md](../docs/reference/composition-seam.md) — GUARANTEES/SUPPLIES contract
- [ADR-026](../docs/decisions/ADR-026-containment-mediation-identity.md) — FIRM seam design
- [ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md) — rip-cage as composable seam
- [egress.md](../docs/reference/egress.md) — standalone egress workflow
- [mitmproxy.org](https://mitmproxy.org/) — upstream (authoritative for CLI flags)
