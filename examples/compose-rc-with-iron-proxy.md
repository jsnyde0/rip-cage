# Compose rip-cage with iron-proxy (Reference MEDIATOR Recipe)

This recipe shows how to attach [iron-proxy](https://github.com/ironsh/iron-proxy)
as a co-located in-cage egress mediator. The combination yields:

- **rip-cage provides:** forced capture of all HTTP/HTTPS and DNS egress (the agent
  cannot bypass); destination-level allow/deny (SNI router); DNS exfil heuristic;
  IOC floor (non-overridable deny list).
- **iron-proxy provides:** TLS-MITM; default-deny egress enforcement; credential
  non-possession (the agent holds a proxy token; the secrets transform replaces it with
  the real secret on the wire, before the request reaches the upstream); structured
  per-request audit trail.

**Threat tier achieved:** exfil-grade — credential non-possession closes the
credential-exfil axis that standalone rip-cage leaves open (see
[ADR-026 D6](../docs/decisions/ADR-026-containment-mediation-identity.md)).

**Tool-agnosticism proof:** iron-proxy plugs through the SAME MEDIATOR seam
as mitmproxy with zero rip-cage edits — proving the seam is not mitmproxy-shaped
(see [ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md)). This is the
**recommended-adopt** provider for new deployments: single binary, single YAML
config, built-in default-deny, and OOTB secret injection (no addon to write).

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
  │  HTTP CONNECT <orig-dst>:<port> → iron-proxy tunnel listener on :8888
  ▼
iron-proxy (rip-ironproxy uid, 127.0.0.1:8888)
  │
  │  TLS-MITM: sees plaintext request
  │  secrets transform: replaces proxy token → real secret
  │    (reads real secret from RIPCAGE_MEDIATOR_BEARER_SECRET in its process env)
  │  allowlist transform: enforces default-deny (iron-proxy layer)
  │  Re-originates TLS to actual upstream (rip-ironproxy uid,
  │  exempted from REDIRECT by init-firewall.sh Step 1a)
  ▼
Real upstream (httpbin.org, api.anthropic.com, ...)
```

The agent sends a proxy token in the Authorization header. iron-proxy intercepts
it via the HTTP CONNECT tunnel, replaces the token with the real secret (from
`RIPCAGE_MEDIATOR_BEARER_SECRET` in iron-proxy's process env), and re-originates
the request. The real secret is never in the agent's environment — credential
non-possession.

---

## Steps

### 1. Add the iron-proxy entries to your manifest

Edit `~/.config/rip-cage/tools.yaml` (global) or a project-level `tools.yaml`.
**Two entries are required** — copy them from `examples/iron-proxy/manifest-fragment.yaml`:

```yaml
version: 1
tools:
  - name: iron-proxy-bin
    archetype: TOOL
    version_pin: "v0.45.0"
    install_cmd: "..."   # see manifest-fragment.yaml for the full command
    egress:
      - github.com
      - objects.githubusercontent.com
    mounts: []

  - name: iron-proxy
    archetype: MEDIATOR
    version_pin: "v0.45.0"
    run_as_uid: "rip-ironproxy"
    hooks:
      start: "/usr/local/bin/iron-proxy -config /etc/iron-proxy/proxy.yaml > /tmp/rip-cage-mediator-iron-proxy.log 2>&1"
      teardown: "pkill -u rip-ironproxy iron-proxy || true"
```

See `examples/iron-proxy/manifest-fragment.yaml` for the full, copy-paste-ready entries.

### 2. Build the image

```bash
rc build
```

This bakes iron-proxy into the image:
- Creates the `rip-ironproxy` system user (uid-exemption subject, ADR-026 D5).
- Downloads and verifies iron-proxy v0.45.0 (SHA-256 verified).
- Installs the binary to `/usr/local/bin/iron-proxy` (root-owned).
- Generates a self-signed CA at `/etc/iron-proxy/ca.crt` and `/etc/iron-proxy/ca.key`.
- Writes the YAML config at `/etc/iron-proxy/proxy.yaml` with:
  - `proxy.tunnel_listen: ":8888"` — the HTTP CONNECT intake the rip-cage router
    sends allowed traffic to.
  - `tls`: references the generated CA (iron-proxy uses it for TLS MITM).
  - `transforms.allowlist`: empty domains list (default-deny; host allowlist is
    set at runtime via `network.allowed_hosts` in `.rip-cage.yaml`).
  - `transforms.secrets`: maps the proxy token → real secret on the Authorization header.
- Bakes the `start` and `teardown` hook strings into
  `/etc/rip-cage/mediators/iron-proxy/` in the image.
- Stamps `LABEL rc.mediators="iron-proxy"` so the config validator accepts
  `network.egress.mediator: iron-proxy` in `.rip-cage.yaml`.

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
    mediator: iron-proxy
  http:
    forward_to: "127.0.0.1:8888"
```

`network.http.forward_to` tells the router to send allowed HTTP/HTTPS traffic to
iron-proxy's tunnel listener via HTTP CONNECT, instead of origin-splicing directly.

`network.egress.mediator: iron-proxy` tells rip-cage to run the MEDIATOR lifecycle
(start hook at cage init) and is validated against the baked `rc.mediators` label.

**Note on iron-proxy's allowlist transform:** iron-proxy's baked config ships with
an empty `domains: []` allowlist (default-deny at the iron-proxy layer). For iron-proxy
to forward traffic to the upstream, you must also populate its allowlist. The
recommended approach is to align iron-proxy's allowlist with `network.allowed_hosts`
in `.rip-cage.yaml`. You can do this by overwriting `/etc/iron-proxy/proxy.yaml`
at cage init with the final allowlist, or by running iron-proxy with a config
template that is rendered at start time. The simplest approach for a single cage:
add the upstream hosts to the `domains:` list in the baked config before `rc build`.

### 4. Configure the real secret (mediator process env only)

The real credential must be in the iron-proxy process environment at cage start time,
NOT in the agent's environment. This keeps the real secret out of the agent's reach
(it cannot be read via `/proc/self/environ` because iron-proxy runs as `rip-ironproxy`,
a different uid from `agent`).

**Secret delivery mechanism:** pass the real secret with `rc up --mediator-env`,
which threads it ONLY into the mediator's process environment — never into the
container-level env (where the agent could read it via `/proc/1/environ`, since
PID 1 runs as the `agent` uid):

```bash
rc up /path/to/workspace --mediator-env RIPCAGE_MEDIATOR_BEARER_SECRET=sk-real-key-here
# or from a file not in version control:
rc up /path/to/workspace --mediator-env-file /path/to/.cage-secrets
```

This must be re-supplied on every `rc up` (including resume after `rc down`) —
the secret intentionally never persists in the image or container. Same mechanism
as the mitmproxy recipe; see
[compose-rc-with-mitmproxy.md](compose-rc-with-mitmproxy.md).

**What not to do:** do not use `rc up --env RIPCAGE_MEDIATOR_BEARER_SECRET=...` —
this injects the secret into the container-level environment, making it readable
by the agent process via `/proc/1/environ`. The secret must reach iron-proxy's
process env only.

### 5. Configure the agent proxy token

In the agent's environment inside the cage, set the proxy token (not the real secret):

```bash
# In .rip-cage.yaml env block:
ANTHROPIC_API_KEY=ripcage-placeholder
# Or any distinct proxy token — never the real key
```

The agent sends `Authorization: Bearer ripcage-placeholder` on its requests.
iron-proxy's secrets transform intercepts the CONNECT-tunneled request, finds the
proxy token `ripcage-placeholder` in the Authorization header, and replaces it with
the real secret from `RIPCAGE_MEDIATOR_BEARER_SECRET` in its process env.

**Note on proxy_value in the config:** the baked `/etc/iron-proxy/proxy.yaml` uses
a fixed `proxy_value: RIPCAGE_MEDIATOR_PLACEHOLDER_VALUE` sentinel. Replace this
with the actual proxy token string (e.g., `ripcage-placeholder`) before running
`rc build`. The proxy token is not a secret — it just needs to match what the agent
sends. For multi-cage deployments, generate a distinct token per cage and bake it
in at build time (or render the config template at cage init).

### 6. CA trust (automatic)

iron-proxy MITM-terminates TLS using the CA generated at build time. The agent's
HTTPS client must trust this CA to avoid certificate verification errors — and the
MEDIATOR manifest entry's `ca_cert_path: /etc/iron-proxy/ca.crt` makes this
**automatic**: the root-phase launcher (`init-mediator.sh`) installs that CA into
the cage trust store (`update-ca-certificates`) when the mediator starts. No manual
step is needed.

Manual fallback (only if you removed `ca_cert_path`):

```bash
# Inside the cage (via rc exec <cage>):
cp /etc/iron-proxy/ca.crt /usr/local/share/ca-certificates/iron-proxy-ca.crt
update-ca-certificates
# For Node.js (Claude Code):
export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/iron-proxy-ca.crt
```

### 7. Start the cage

```bash
rc up /path/to/workspace
```

At `rc up` time (same ordering as the firewall — the mediator is launched as a
root-phase step, sibling to `init-firewall.sh`):
1. The cage container starts with `sleep infinity`.
2. rip-cage's firewall initializes (`init-firewall.sh`, host-driven `docker exec -u root`):
   - `iptables` REDIRECT rules capture all TCP 80/443 egress to the router.
   - Step 1a reads `/etc/rip-cage/mediators/iron-proxy/run_as_uid` and adds an OUTPUT
     RETURN rule for `rip-ironproxy`'s numeric uid — this prevents iron-proxy's own
     re-originated egress from being re-captured (loop prevention).
3. The mediator launcher runs (`init-mediator.sh`, a separate host-driven
   `docker exec -u root`, after the firewall and before the agent-context init):
   - Reads `RC_MEDIATOR=iron-proxy` (threaded in by `rc up`) + the baked registry,
     validates `run_as_uid` (fail-closed: empty/0/root → refuse), then drops to
     `rip-ironproxy` and backgrounds `/etc/rip-cage/mediators/iron-proxy/start`.
   - The `start` hook launches `iron-proxy` with the baked YAML config, listening
     on `:8888` (the tunnel listener for HTTP CONNECT).
   - Installs the `ca_cert_path` CA into the cage trust store (update-ca-certificates).
   - The secret arrives via `rc up --mediator-env` into iron-proxy's process env only.
   - Logs go to `/tmp/rip-cage-mediator-iron-proxy.log` (cage-lifetime).

### 8. Verify the injection is working

From inside the cage (via `rc exec <cage>`):

```bash
# The agent env has only the proxy token:
echo $ANTHROPIC_API_KEY   # → ripcage-placeholder

# Confirm the router is on-path (force-through guarantee):
curl -v http://selftest.rip-cage.internal/ 2>&1 | grep x-rip-cage-selftest

# Confirm credential injection: the echo shows the REAL secret, not the proxy token.
# (httpbin.org/headers echoes back all request headers)
curl -H "Authorization: Bearer ripcage-placeholder" https://httpbin.org/headers

# Expected: Authorization header in response body contains "Bearer sk-ant-real-key..."
# NOT "Bearer ripcage-placeholder"

# Confirm the floor still holds — a non-allowlisted host is still denied:
curl https://evil.example.com 2>&1   # → connection refused (router blocks at destination)
```

The iron-proxy structured audit log (`/tmp/rip-cage-mediator-iron-proxy.log`) shows
each proxied request with the full transform pipeline result, including which secrets
were swapped and which requests were blocked.

### 9. Troubleshooting

- **iron-proxy not starting**: Check `/tmp/rip-cage-mediator-iron-proxy.log` inside
  the cage. The binary exits immediately if the config is malformed.
- **Proxy token not replaced**: Confirm `RIPCAGE_MEDIATOR_BEARER_SECRET` is set in
  iron-proxy's process env (NOT the agent env). Check the audit log for the
  `secrets` transform trace — it logs which secrets were swapped and why.
- **TLS errors / CERT_VERIFY_FAILED**: iron-proxy's generated CA cert is at
  `/etc/iron-proxy/ca.crt`. Trust it inside the cage:
  ```bash
  cp /etc/iron-proxy/ca.crt /usr/local/share/ca-certificates/iron-proxy-ca.crt
  update-ca-certificates
  ```
- **Port conflict**: The tunnel listener MUST be on a port distinct from the rip-cage
  router's own listen port (`127.0.0.1:8080`). `8888` (the router's
  `_MEDIATOR_DEFAULT_PORT`) is the recommended default. If `8888` is also taken,
  change `proxy.tunnel_listen` in `/etc/iron-proxy/proxy.yaml` AND
  `network.http.forward_to` in `.rip-cage.yaml` to another unused port (e.g. `8889`).
  Rebuild after changing the config.
- **iron-proxy allowlist blocking legitimate traffic**: iron-proxy runs its own
  allowlist transform before forwarding to upstream. If you see 403 responses, check
  that the target host is in iron-proxy's `transforms.allowlist.domains` config
  (distinct from rip-cage's `network.allowed_hosts`). Both layers must permit the host.
- **Proxy token not found in request**: Confirm the agent is sending the proxy token
  in the Authorization header and that it matches the `proxy_value` in the iron-proxy
  config. iron-proxy's `require: false` default means a missing proxy token passes
  through without substitution (not blocked). Set `require: true` to reject requests
  missing the proxy token.

---

## Integration note: mediator lifecycle launcher

The mediator `start` hook is launched at cage init by the root-phase `init-mediator.sh`
(a host-driven `docker exec -u root` from `rc up`, sibling to `init-firewall.sh` — NOT
the agent-context `init-rip-cage.sh`). It reads `RC_MEDIATOR` (threaded in by `rc up`)
and the baked registry `/etc/rip-cage/mediators/<name>/{start,teardown,run_as_uid,ca_cert_path}`,
validates the uid fail-closed, drops to that uid, backgrounds the start hook (nohup, so it
survives the exec returning), installs the CA, and writes a PID file for idempotency. This
runs on both the create and resume paths (rip-cage-ta1o.5.8).

> **Manual validation (optional):** to drive the launcher by hand against a running cage:
> ```bash
> docker exec --user rip-ironproxy <cage> /usr/local/bin/iron-proxy -config /etc/iron-proxy/proxy.yaml
> ```
> The dispatcher wiring is tracked as a follow-up integration step.

---

## Comparison: iron-proxy vs mitmproxy as a MEDIATOR provider

| | iron-proxy | mitmproxy |
|---|---|---|
| Secret injection | Built-in (YAML config) | Custom Python addon required |
| Default-deny | Built-in | Requires addon / passthrough block |
| TLS CA | Auto-generated at build | Generated at runtime by mitmdump |
| Config surface | Single YAML file | CLI flags + Python addon |
| Audit trail | Structured JSON (built-in) | Plugin-based |
| Setup | Binary install + YAML | pip install + addon write |
| License | Apache-2.0 | MIT |

iron-proxy is the **recommended-adopt** provider for new deployments. mitmproxy
remains the **reference/proof** provider that validated the seam.

---

## Security notes

- The real secret (`RIPCAGE_MEDIATOR_BEARER_SECRET`) lives in iron-proxy's process env
  only — the agent cannot read it via `/proc/self/environ` because iron-proxy runs as
  `rip-ironproxy` (a different uid from `agent`).
- iron-proxy must be in the egress allowlist at the rip-cage router layer for any
  upstream it re-originates to (it runs as `rip-ironproxy`, uid-exempted from the
  REDIRECT rule — its traffic goes direct to the upstream, not back through the router).
- rip-cage's IOC floor (known exfil sinks) is enforced at the router before the CONNECT
  handoff — iron-proxy cannot receive traffic destined for IOC-denied hosts.
- iron-proxy's own allowlist transform runs inside the tunnel, after rip-cage's floor.
  Both layers are enforced; iron-proxy can only ADD restriction, not subtract
  (rip-cage's router denies before forwarding — additive-only, ADR-012 D6).

---

## See Also

- [composition-seam.md](../docs/reference/composition-seam.md) — GUARANTEES/SUPPLIES contract
- [ADR-026](../docs/decisions/ADR-026-containment-mediation-identity.md) — FIRM seam design
- [ADR-005 D12](../docs/decisions/ADR-005-ecosystem-tools.md) — rip-cage as composable seam
- [egress.md](../docs/reference/egress.md) — standalone egress workflow
- [compose-rc-with-mitmproxy.md](compose-rc-with-mitmproxy.md) — mitmproxy recipe (reference provider)
- [github.com/ironsh/iron-proxy](https://github.com/ironsh/iron-proxy) — upstream (authoritative for CLI flags and config)
