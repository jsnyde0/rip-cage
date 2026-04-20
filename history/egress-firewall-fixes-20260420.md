# Fixes: egress-firewall
Date: 2026-04-20
Review passes: 2

## Critical

- **init-firewall.sh:5-11,59-68** — mitmproxy CA cert disconnection. `--set confdir=/etc/rip-cage/mitmproxy` points to an empty directory. mitmproxy auto-generates its own CA, ignoring the custom-generated one in `/etc/rip-cage/ca/`. All HTTPS fails because clients trust one CA but the proxy presents another. Fix: create `/etc/rip-cage/mitmproxy/`, copy the custom CA keypair into it using mitmproxy's expected filenames (`mitmproxy-ca.pem` = combined key+cert, `mitmproxy-ca-cert.pem` = cert only), and `chown rip-proxy:rip-proxy /etc/rip-cage/mitmproxy`.

- **Dockerfile:75 + rip_cage_egress.py:8 + init-firewall.sh:92** — PyYAML not installed. `import yaml` requires PyYAML but mitmproxy depends on `ruamel.yaml` (different package). Addon fails to load → proxy crashes → fail-closed blocks all traffic. Fix: add `PyYAML` to the pip install: `RUN /opt/rip-cage-proxy/bin/pip install --no-cache-dir mitmproxy PyYAML`.

- **init-firewall.sh:78-86** — Readiness wait loop broken by `set -e`. Bare `curl` exits non-zero when proxy isn't up yet → `set -e` aborts the script → `curl_exit=$?` is never reached. Script always fails before proxy has time to start. Fix: protect curl from set -e: `curl -s --max-time 1 http://127.0.0.1:8080/ >/dev/null 2>&1 || curl_exit=$?`.

- **init-firewall.sh:65,70** — `/var/log/rip-cage-proxy.log` not writable by rip-proxy. Stderr redirect fails → mitmdump never starts. Fix: before the `su` call, add `touch /var/log/rip-cage-proxy.log` and `chown rip-proxy:rip-proxy /var/log/rip-cage-proxy.log`.

- **rip_cage_egress.py:156-171** — rip-proxy user cannot write audit log to `/workspace/.rip-cage/egress.log`. `/workspace` is owned by `agent:agent`, rip-proxy has no write access. Fix: pre-create `/workspace/.rip-cage/` in init-firewall.sh with `mkdir -p /workspace/.rip-cage && chmod 777 /workspace/.rip-cage` (or add rip-proxy to agent group, or chown the directory).

- **init-firewall.sh:59-70** — `/tmp/rip-proxy-start.sh` is world-writable. After init, agent user can replace the restart wrapper script. When proxy crashes and restarts, agent-supplied code runs as rip-proxy (UID excluded from REDIRECT rule = full firewall bypass). Fix: bake the wrapper script into the image at `/usr/local/lib/rip-cage/rip-proxy-start.sh` (root-owned, 755). Reference from init-firewall.sh instead of writing to /tmp.

## Important

- **rc:919-927,1124-1126,1158-1159** — `_up_init_firewall` failure not handled. If init-firewall.sh fails, execution continues without firewall. In JSON mode, no error is emitted. Fix: add `_UP_FIREWALL_OK` flag mirroring `_UP_INIT_OK` pattern; on failure emit json_error and abort.

- **rc:955,1124-1126** — Resume path reads `RIP_CAGE_EGRESS` from host env, not from container's `rc.egress` label. If container was created with egress=off (no NET_ADMIN), resuming without the env var defaults to on → iptables fails (no capability). Fix: on resume path, read `docker inspect --format '{{ index .Config.Labels "rc.egress" }}' "$name"` and use that.

- **tests/test-egress-firewall.sh:42-46** — Check 2 false positive. `curl -w '%{http_code}'` writes `000` on connection failure. `[[ -n "000" ]]` is true. Fix: add `[[ "$proxy_response" != "000" ]]` condition.

- **init-rip-cage.sh:157-159** — `.zshrc` grows on every resume. `cat firewall-env >> .zshrc` with no idempotency guard. Fix: `if ! grep -q 'NODE_EXTRA_CA_CERTS' /home/agent/.zshrc 2>/dev/null; then cat ...; fi`.

- **rc:256-292** — Devcontainer path: CA trust env vars not available to VS Code extension processes. Only interactive shells source .zshrc. Claude Code running in VS Code extension host lacks NODE_EXTRA_CA_CERTS → HTTPS to api.anthropic.com fails through MITM proxy. Fix: add `containerEnv` block to devcontainer.json with hardcoded paths (they're fixed and correct when firewall is on; harmless when off).

- **rip_cage_egress.py:57-59 + egress-rules.yaml** — host_suffix root domain bypass. `endswith(".ngrok.io")` doesn't match bare `ngrok.io`. Affects all 11 host_suffix rules. Fix: change matching to also check `host == suffix.lstrip(".")`.

## Minor

- **rip_cage_egress.py:165** — `client_uid` via `os.getuid()` always reports rip-proxy UID (useless). Fix: remove the field or replace with a note that it reflects the proxy, not the client.

- **tests/test-egress-firewall.sh:113-120** — Check 9 fails on GitHub API rate limit (403). Fix: accept 403 in the success pattern, or check for absence of `X-Rip-Cage-Denied` header instead.

- **tests/test-egress-firewall.sh:134-139** — Check 11 doesn't verify UDP protocol. A TCP DROP for 443 would also pass. Fix: grep for `udp.*dpt:443` instead of just `DROP.*dpt:443`.

- **init-firewall.sh:30-35** — `CLAUDE_CODE_CERT_STORE` not set. Anthropic docs reference it alongside NODE_EXTRA_CA_CERTS. Fix: add `export CLAUDE_CODE_CERT_STORE=/etc/ssl/certs/ca-certificates.crt` to firewall-env.

- **egress-rules.yaml** — Missing interactsh alt domains (oast.pro, oast.me, oast.fun, oast.site), ngrok newer domains (ngrok.app, ngrok.dev), canarytokens.org. Fix: add host_suffix entries for each.

- **tests/test-egress-firewall.sh:22-28** — No positive assertions for egress-off state. Design doc specifies testing "no iptables rules, no proxy, direct HTTPS works" when disabled. Fix: add 2-3 positive checks when firewall-env is absent.

## ADR Updates

- No ADR changes needed. All findings are implementation bugs or gaps, not design decision challenges. FIRM decisions (D1-D6) remain valid and correctly motivated.

## Discarded

- **anonfiles missing from rules** — anonfiles.com is defunct. Low value.
- **update-ca-certificates --fresh redundant on resume** — harmless, ensures clean state.
- **regex compiled per-request** — no path_regex rules exist in current YAML. Latent only.
- **sed && fragility (Impl P1 F12)** — already fixed during implementation review.
- **Rule count includes non-deny (Impl P1 F13)** — all current rules are deny. Latent.
- **Dockerfile layer ordering (Arch P2 F16)** — premature optimization for dev-phase project.
- **rc ls column header (Arch P2 F18)** — Docker table format is adequate for current needs.
