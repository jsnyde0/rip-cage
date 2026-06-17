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
  │  network.http.forward_to = "127.0.0.1:8080"
  │  HTTP CONNECT <orig-dst>:<port> → mitmdump on :8080
  ▼
mitmdump (rip-mitmproxy uid, 127.0.0.1:8080)
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
      start: "su -s /bin/sh rip-mitmproxy -c '...'  # see manifest-fragment.yaml
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
    forward_to: "127.0.0.1:8080"
```

`network.http.forward_to` tells the router to send allowed HTTP/HTTPS traffic to
mitmdump's listen address via HTTP CONNECT, instead of origin-splicing directly.

`network.egress.mediator: mitmproxy` tells rip-cage to run the MEDIATOR lifecycle
(start hook at cage init) and is validated against the baked `rc.mediators` label.

### 4. Configure the real secret (host-side only)

The real credential must be in the mitmproxy process environment at cage start time,
NOT in the agent's environment. Pass it via `--env` or an env file:

```bash
rc up /path/to/workspace --env RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-real-key-here
```

Or use the `RC_CAGE_ENV_FILE` pattern:

```bash
# In a file NOT committed to version control:
RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-real-key-here
```

```bash
rc up /path/to/workspace --env-file /path/to/.cage-secrets
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

Also configure `RIPCAGE_MEDIATOR_PLACEHOLDER=ripcage-placeholder` in the mitmproxy
process env (same env-file / `--env` as the secret above) so the addon only fires on
the matching placeholder and passes other headers through:

```
RIPCAGE_MEDIATOR_BEARER_SECRET=sk-ant-real-key-here
RIPCAGE_MEDIATOR_PLACEHOLDER=ripcage-placeholder
```

If `RIPCAGE_MEDIATOR_PLACEHOLDER` is absent, the addon replaces the Authorization
header unconditionally (useful for development).

### 6. Start the cage

```bash
rc up /path/to/workspace
```

At `rc up` time:
1. The cage container starts with `sleep infinity`.
2. rip-cage's firewall initializes:
   - `iptables` REDIRECT rules capture all TCP 80/443 egress to the router.
   - `init-firewall.sh` Step 1a reads `/etc/rip-cage/mediators/mitmproxy/run_as_uid`
     and adds an OUTPUT RETURN rule for `rip-mitmproxy`'s numeric uid — this prevents
     mitmproxy's own re-originated egress from being re-captured (loop prevention).
3. `init-rip-cage.sh` runs:
   - The mediator lifecycle dispatcher reads `RC_MEDIATOR=mitmproxy` (threaded in
     by `rc up`) and executes `/etc/rip-cage/mediators/mitmproxy/start`.
   - The `start` hook launches `mitmdump` in regular CONNECT-proxy mode under the
     `rip-mitmproxy` uid, listening on `127.0.0.1:8080`.
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
- **TLS errors / CERT_VERIFY_FAILED**: mitmproxy generates a self-signed CA cert at
  `~/.mitmproxy/mitmproxy-ca-cert.pem` under the `rip-mitmproxy` user's home
  (`/opt/rip-cage-mitmproxy-home/.mitmproxy/`). Trust it inside the cage:
  ```bash
  cp /opt/rip-cage-mitmproxy-home/.mitmproxy/mitmproxy-ca-cert.pem \
     /usr/local/share/ca-certificates/mitmproxy-ca.crt
  update-ca-certificates
  # For Node.js (Claude Code):
  export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mitmproxy-ca.crt
  ```
  Or mount the CA cert from the host and add it at cage init via `init-rip-cage.sh`
  extensions (IN-CAGE-DAEMON pattern).
- **Port conflict**: If another process is already on `127.0.0.1:8080`, change
  both `--listen-port` in the MEDIATOR `start` hook and `network.http.forward_to`
  in `.rip-cage.yaml` to an unused port (e.g. `8081`). Rebuild after changing the hook.

---

## Integration note: mediator lifecycle dispatcher

The mediator `start` hook is dispatched at cage init by `init-rip-cage.sh` via the
`RC_MEDIATOR` env var (threaded in by `rc up`, same mechanism as `RC_MULTIPLEXER` for
multiplexers). The dispatcher reads `/etc/rip-cage/mediators/<name>/start` from the
baked registry and runs it via `sh`.

> **Integration gap (current):** As of bead `rip-cage-ta1o.5.4`, the mediator
> lifecycle dispatcher in `init-rip-cage.sh` may not yet be wired up (unlike the
> multiplexer dispatcher which is in section 11). If the mediator does not start
> automatically on `rc up`, run the start hook manually for validation:
> ```bash
> docker exec <cage> sh /etc/rip-cage/mediators/mitmproxy/start
> ```
> The dispatcher wiring is tracked as a follow-up integration step.

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
