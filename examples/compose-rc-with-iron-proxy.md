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

## What actually works today (worked example: Claude Code on the Anthropic subscription)

The steps below use the concrete case rip-cage validated end-to-end with the **real
agent binary**: Claude Code holding a placeholder, iron-proxy injecting a real
`claude setup-token`, drawing on your Max/Pro subscription (rip-cage-ahnp, 2026-07-03).

Two honest scope notes before you invest in this:

- **Claude Code: works, subscription-billed.** A real `claude -p` turn completes on
  the placeholder; the injected `setup-token` is long-lived (~1yr, no OAuth refresh) and
  bills against your plan limits because Claude Code is a *first-party* app. This is the
  recommended, proven configuration.
- **pi (and other third-party agents on Anthropic): does NOT ride the subscription.**
  The injection mechanism itself works for pi once you clear two mechanical hurdles
  (pin an anthropic model — pi defaults to `--provider google`, which a single-host
  floor blocks — its bare CLI default is `--provider google`; and set `NODE_EXTRA_CA_CERTS`,
  see step 6). But Anthropic then returns
  `400 "Third-party apps now draw from your extra usage, not your plan limits"` — it
  bills third-party apps as metered extra-usage, which a subscription-only account has
  disabled. This is Anthropic-side billing, not a rip-cage limitation. For pi
  non-possession, use a **static-key provider** (e.g. openrouter) instead of the
  Anthropic subscription path, or accept metered extra-usage.

The bare `auth.credential_mounts` toggle (step 3) still suppresses the real Claude
**and** pi credentials together by default. To express **mixed posture** — claude
non-possession alongside pi possession, which is exactly the recommended shape
given the billing constraint above — use the per-tool overrides instead:
`auth.per_tool.claude: none` with `auth.per_tool.pi: real` (or simply leave
`auth.per_tool.pi` unset, since `real` is the global default). See
[config.md](../docs/reference/config.md#authcredential_mounts--authper_toolclaudepi--host-credential-mount-posture)
for the full field reference (rip-cage-xhgr).

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

In the workspace `.rip-cage.yaml` (this is the validated non-possession posture):

```yaml
version: 1
auth:
  # Suppress the real Claude + pi credential mounts (and keychain extraction).
  # WITHOUT this line the agent still possesses the real credentials — this key is
  # what makes non-possession real. Default is `real` (today's mount-everything behavior).
  # Bare form covers claude AND pi together; use auth.per_tool.{claude,pi} instead
  # for mixed posture (rip-cage-xhgr). Create-time only (a resume flip refuses loud).
  credential_mounts: none
network:
  mode: block
  allowed_hosts:
    - api.anthropic.com
    - platform.claude.com
    # platform.claude.com IS on the allowlist (flipped 2026-07-06, rip-cage-e770):
    # (i) it's on Anthropic's documented required-domains list for Claude Code
    #     (code.claude.com/docs/en/network-config — "Console account authentication");
    # (ii) interactive Claude Code >=2.1.19x hard-fails startup with
    #     ERR_SOCKET_CLOSED when this host is unreachable (headless `-p` does not);
    # (iii) safety re-derivation: under non-possession the agent holds only the
    #     worthless placeholder (step 5) — there is no real refresh token in the
    #     cage to refresh or leak via this host, so omitting it protected nothing.
  egress:
    mediator: iron-proxy
    # Persisted pointer to a chmod-600 host file holding the real secret (step 4).
    # rc re-applies this on every up AND resume, so the cage keeps working unattended.
    mediator_env_file: /Users/you/.config/rip-cage/anthropic-mediator.env
  http:
    forward_to: "127.0.0.1:8888"
```

`network.http.forward_to` tells the router to send allowed HTTP/HTTPS traffic to
iron-proxy's tunnel listener via HTTP CONNECT, instead of origin-splicing directly.
`auth.credential_mounts: none` is what suppresses the real credentials so the agent
holds only the placeholder (step 5). `.rip-cage.yaml` is read-only inside the cage
(ADR-021 D7), so a prompt-injected agent cannot flip `credential_mounts` back to `real`.

**Note (rip-cage-t7cu):** `credential_mounts: none` only suppresses `~/.claude/.credentials.json`
(the token secret) and keychain extraction — it does **not** suppress `~/.claude.json`.
That file holds no credentials (account metadata, MCP server config, onboarding/trust
state), so under `none` it still carries into the cage, read-only (`:ro`). If your host
`~/.claude.json` has user-scope `mcpServers` entries or onboarding state you rely on,
those come along automatically; if you'd rather the cage start from a clean slate, there
is currently no per-field carve-out — see [config.md](../docs/reference/config.md) for
the full behavior.

`network.egress.mediator: iron-proxy` tells rip-cage to run the MEDIATOR lifecycle
(start hook at cage init) and is validated against the baked `rc.mediators` label.

**Note on iron-proxy's allowlist transform:** iron-proxy's baked config ships with
an empty `domains: []` allowlist (default-deny at the iron-proxy layer). For iron-proxy
to forward traffic to the upstream, you must also populate its allowlist. The
recommended approach is to align iron-proxy's allowlist with `network.allowed_hosts`
in `.rip-cage.yaml` — that means BOTH `api.anthropic.com` AND `platform.claude.com`,
not just the API host; omitting the latter from iron-proxy's `domains:` list
reproduces the same startup hard-fail even if `allowed_hosts` is correct. You can do
this by overwriting `/etc/iron-proxy/proxy.yaml` at cage init with the final
allowlist, or by running iron-proxy with a config template that is rendered at
start time. The simplest approach for a single cage: add the upstream hosts
(`api.anthropic.com`, `platform.claude.com`) to the `domains:` list in the baked
config before `rc build`.

### 4. Configure the real secret (mediator process env only)

The real credential must be in the iron-proxy process environment at cage start time,
NOT in the agent's environment. This keeps the real secret out of the agent's reach
(it cannot be read via `/proc/self/environ` because iron-proxy runs as `rip-ironproxy`,
a different uid from `agent`).

**For the Anthropic subscription case, the real secret is a `claude setup-token`** —
a long-lived (~1yr) `sk-ant-oat01-…` subscription token that never triggers OAuth
refresh in-cage. **Mint it yourself, on the host** (an agent tool-call would print it
to stdout and leak it into the transcript):

```bash
# On the HOST, in your own terminal — not via any agent:
claude setup-token          # prints the sk-ant-oat01-… token; copy it

# Write the chmod-600 mediator env file, OUTSIDE any workspace
# (the repo dir bind-mounts into the cage as /workspace):
umask 077
printf 'RIPCAGE_MEDIATOR_BEARER_SECRET=%s\n' '<paste-the-setup-token>' \
  > ~/.config/rip-cage/anthropic-mediator.env
chmod 600 ~/.config/rip-cage/anthropic-mediator.env
```

**Delivery — the persisted pointer (recommended, autonomous):** point
`network.egress.mediator_env_file` at that file in `.rip-cage.yaml` (step 3). rc reads
it and threads each `KEY=VALUE` into the mediator via `docker exec -u root -e` into the
`rip-ironproxy` uid — never into the container-level env — on **every** `rc up` AND
resume. rc persists only the *path*, never the value. This is the autonomy win: you set
it once, and unattended restarts keep working.

Ad-hoc alternative (retyped each `rc up`): `rc up <ws> --mediator-env-file /path/to/file`
or `--mediator-env KEY=VALUE`. Same leak-free `docker exec -e` channel.

**What not to do:** do not use `rc up --env RIPCAGE_MEDIATOR_BEARER_SECRET=...` —
this injects the secret into the container-level environment, making it readable
by the agent process via `/proc/1/environ`. The secret must reach iron-proxy's
process env only.

### 5. Configure the agent proxy token

The agent holds a **placeholder**, never the real secret. `.rip-cage.yaml` has no env
block — the placeholder is supplied via `rc up --env-file` (a CLI flag). Create a
non-secret placeholder env file:

```
# ~/.config/rip-cage/agent-placeholder.env  (NOT secret — a fixed fake token)
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-ripcage-placeholder
ANTHROPIC_OAUTH_TOKEN=sk-ant-oat01-ripcage-placeholder
```

```bash
rc up /path/to/workspace --env-file ~/.config/rip-cage/agent-placeholder.env
```

**The placeholder MUST be `sk-ant-oat01-…`-shaped.** Claude Code and pi route a token
to the OAuth/Bearer branch (`Authorization: Bearer …`) only when its string contains
`sk-ant-oat`; a differently-shaped placeholder would be sent as `x-api-key` instead,
and iron-proxy's `match_headers: [Authorization]` swap would miss it. `CLAUDE_CODE_OAUTH_TOKEN`
is honored by Claude Code; `ANTHROPIC_OAUTH_TOKEN` by pi. With `auth.credential_mounts: none`
(step 3) suppressing the real credential files, these env tokens become the active auth
(a mounted `auth.json`/`.credentials.json` would otherwise win over the env).

**Match `proxy_value` in the baked config.** The shipped
`/etc/iron-proxy/proxy.yaml` uses a generic `proxy_value: RIPCAGE_MEDIATOR_PLACEHOLDER_VALUE`
sentinel — change it to this exact placeholder string (`sk-ant-oat01-ripcage-placeholder`)
before `rc build`, so the secrets transform recognizes what the agent sends. The
placeholder is not a secret; it just has to match on both sides.

### 6. CA trust — system store is automatic, but Node tools need one more env var

iron-proxy MITM-terminates TLS using the CA generated at build time. Every HTTPS
client in the cage must trust that CA or the handshake fails.

- **System trust store: automatic.** The MEDIATOR entry's
  `ca_cert_path: /etc/iron-proxy/ca.crt` makes `init-mediator.sh` install the CA via
  `update-ca-certificates` at cage start. This covers `curl` and **Claude Code** (it
  reads the system store) — no manual step, and this is why `claude` works out of the box.

- **Node tools (pi, and any Node-based agent): NOT covered by the above.** Node's
  default TLS uses its own bundled CA store and **ignores the system store**, so even
  with `ca_cert_path` set, a Node client rejects the MITM cert with
  `SELF_SIGNED_CERT_IN_CHAIN` — surfaced as a generic `Connection error`. You must point
  Node at the mediator CA explicitly via `NODE_EXTRA_CA_CERTS`. Add it to the same
  `--env-file` as the placeholder (step 5), since it's not a secret:

  ```
  # append to ~/.config/rip-cage/agent-placeholder.env
  NODE_EXTRA_CA_CERTS=/etc/iron-proxy/ca.crt
  ```

  (Validated: with this unset a raw `node` POST to a MITM'd host fails
  `SELF_SIGNED_CERT_IN_CHAIN`; set to the mediator CA it returns 200 — rip-cage-ahnp.)
  A seam-level fix that would export this automatically from the manifest `ca_cert_path`
  is tracked in **rip-cage-yid0**; until it lands, set it here.

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

From inside the cage (via `rc exec <cage>`). **Do not verify by echoing the injected
header to an echo service** (e.g. `httpbin.org/headers`) — that would print the *real*
secret to your terminal. Verify by *outcome* instead:

```bash
# 1. Agent holds ONLY the placeholder:
echo $CLAUDE_CODE_OAUTH_TOKEN   # → sk-ant-oat01-ripcage-placeholder

# 2. A real agent turn succeeds (proves injection end-to-end, no secret printed):
claude -p "Reply with exactly: RCOK" --model claude-haiku-4-5-20251001   # → RCOK

# 3. Negative control — a bearer iron-proxy will NOT swap must be rejected,
#    proving the success above is load-bearing on the injection:
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://api.anthropic.com/v1/messages \
  -H "Authorization: Bearer sk-ant-oat01-not-the-placeholder" \
  -H "anthropic-beta: oauth-2025-04-20" -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  --data '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
  # → 401

# 4. Floor still holds — a non-allowlisted host is refused even with the mediator up:
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://example.org   # → 000/refused

# 5. Non-possession — the real secret is NOT in the agent's reach:
cat /proc/1/environ | tr '\0' '\n' | grep RIPCAGE_MEDIATOR_BEARER_SECRET   # → (empty)
```

The iron-proxy structured audit log (`/tmp/rip-cage-mediator-iron-proxy.log`, readable
only as root) shows each proxied request and its transform result (`secrets` → `allow`)
without printing secret values — that's the safe place to confirm the swap fired.

### 9. Troubleshooting

- **iron-proxy not starting**: Check `/tmp/rip-cage-mediator-iron-proxy.log` inside
  the cage. The binary exits immediately if the config is malformed.
- **Proxy token not replaced**: Confirm `RIPCAGE_MEDIATOR_BEARER_SECRET` is set in
  iron-proxy's process env (NOT the agent env). Check the audit log for the
  `secrets` transform trace — it logs which secrets were swapped and why.
- **`SELF_SIGNED_CERT_IN_CHAIN` / a bare `Connection error` from a Node tool (pi)**:
  Node ignores the system CA store. Set `NODE_EXTRA_CA_CERTS=/etc/iron-proxy/ca.crt` in
  the agent env (step 6) — this is required even though `update-ca-certificates` ran.
  `curl` and Claude Code work without it; pi and other Node tools do not.
- **pi returns `400 "Third-party apps now draw from your extra usage…"`**: not a
  rip-cage bug — Anthropic bills third-party apps (pi) as metered extra-usage, not
  against your subscription plan, and a subscription-only account has that disabled.
  The setup-token subscription path is Claude-Code-only. Use a static-key provider
  (openrouter) for pi non-possession, or enable extra-usage. Also make sure pi is pinned
  to an anthropic model (`--provider anthropic`) — its default `--provider google` is
  blocked by a single-host floor and also surfaces as `Connection error`.
- **Other TLS errors / CERT_VERIFY_FAILED** (non-Node clients): iron-proxy's CA is at
  `/etc/iron-proxy/ca.crt`; confirm `init-mediator.sh` ran `update-ca-certificates`.
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
