# msb spike — egress-rule mutability + denial observability (the deny→fix→reload loop under msb) (2026-07-09)

Bead: rip-cage-hfno. Epic: rip-cage-tsf2. Machine: mac mini, msb v0.6.4 (`/Users/jonatanpi/.local/bin/msb`),
Python SDK `microsandbox==0.6.6` (installed fresh into a throwaway `uv` venv for introspection only —
removed at cleanup), image `rip-cage:latest`. Related: rip-cage-r8jl (lifecycle spike, CLOSED,
`docs/2026-07-09-msb-spike-lifecycle.md`).

All commands below were run live on this machine in this session. Sandboxes created:
`egress-spike`, `egress-spike2`, `egress-spike3`, `nonet-spike`, `secret-spike`, `observe-spike`,
`trace-spike` — all removed at the end (`msb remove --force <name>` × 7); machine restored to the
pre-existing `dockerdata`-volume-only clean slate (verified via `msb list` / `msb volume list` /
`msb image list` post-cleanup).

## 1. Q1 — live mutability: VERDICT = impossible, recreate-only

Checked three independent surfaces; all agree:

**a) CLI `--tree` full surface.** `msb --tree` enumerates every subcommand. There **is** a `msb modify`
verb (not documented in the cached `cli-reference.md` skill file — found live) that mutates a *running*
sandbox without a restart for a specific field set: `--cpus`, `--max-cpus`, `--memory`, `--max-memory`,
`--env`/`--env-rm`, `--label`/`--label-rm`, `--workdir`, `--secret`/`--secret-rm` (secret rotation is
live!), plus `--dry-run`/`--next-start`/`--restart` apply-policy flags. **No `--net-rule` / `--net-default`
flag exists on `modify`.**

**b) Live proof of rejection** — attempted the exact operation the bead asks to prove or disprove:

```
$ msb modify egress-spike2 --net-rule "allow@www.wikipedia.org:tcp:443"
error: unexpected argument '--net-rule' found

  tip: a similar argument exists: '--next-start'

Usage: msb modify --next-start <NAME>

For more information, try '--help'.
EXIT:2
```

The CLI parser doesn't even recognize `--net-rule` as a valid `modify` argument — this isn't a runtime
"not supported yet" error, it's not in the grammar at all.

**c) Python SDK type stub** (`microsandbox/_microsandbox.pyi`, the compiled Rust extension's exhaustive
public signature, shipped in the 0.6.6 wheel):

```
async def modify(
    self, /, *,
    cpus=None, max_cpus=None, memory=None, max_memory=None,
    env=None, env_rm=None, labels=None, labels_rm=None,
    workdir=None, secrets=None, secrets_rm=None,
    policy: str | None = None,
) -> ...
```

Same field set as the CLI, confirmed from the actual shipped binding (not docs) — `policy` here means the
*apply* policy (`no_restart`/`next_start`/`restart`), not network policy. No `network` parameter exists.
`grep -rin "net_rule\|update_network\|modify_network\|patch_network\|hot.reload" microsandbox/` across the
full installed package (source + stub) returned zero hits.

**Verdict: live-reload of `--net-rule`/`--net-default` on a running sandbox is not possible via any
CLI or SDK surface in msb 0.6.4/0.6.6. Rule changes require `msb create --replace` / `msb run --replace`
(recreate).** The "existing exec/TTY sessions survive" half of Q1 is moot — there's no live-mutation path
to test session survival against.

## 2. Q2 — denial experience in-guest: exact strings, and can an agent tell "blocked" from "down"?

Test cage: `msb run -d --name egress-spike --net-default deny --net-rule "allow@example.com:tcp:443"
rip-cage:latest -- sleep 3600`. Confirmed the allowed path first (control): `curl` to `https://example.com`
→ `HTTP_STATUS:200`.

**(a) Non-allowlisted HTTPS host via curl** — DNS fails first, before any TCP attempt:

```
$ msb exec --timeout 10 egress-spike -- curl -v --max-time 8 https://www.google.com
* Could not resolve host: www.google.com
* shutting down connection #0
curl: (6) Could not resolve host: www.google.com
```
Exit code 6.

**(b) Non-allowlisted DNS name via getent / dig:**

```
$ msb exec --timeout 10 egress-spike -- getent hosts www.google.com
EXIT:2                              # (no stdout, no stderr at all — completely silent)

$ msb exec --timeout 10 egress-spike -- dig www.google.com
; <<>> DiG 9.20.23-1~deb13u1-Debian <<>> www.google.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 5798
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0
;; QUESTION SECTION:
;www.google.com.			IN	A
;; SERVER: 172.16.0.229#53(172.16.0.229) (UDP)
```
Exit code 0 (`dig` itself succeeds — it got a valid, well-formed answer, the answer is just NXDOMAIN).

**Rating (a)+(b): an agent CANNOT distinguish "cage policy blocked this" from "network is down" /
"domain genuinely doesn't exist."** `curl: (6) Could not resolve host` is the *identical* string curl
prints for a real typo'd or non-existent domain. `dig` is worse: it returns a **textbook NXDOMAIN**
response — a real authoritative "this domain does not exist" answer, not a filtered/refused/timeout
signal. This sharpens (doesn't just confirm) the sibling ssh-spike's DNS-vs-IP gotcha: the denial doesn't
just surface as a DNS-stage failure, it surfaces as a *semantically indistinguishable-from-real* DNS
failure. `getent hosts` is even more opaque: exit code 2 and total silence, no message at all.

**(c) Blocked raw TCP port — and a major confound found while probing it.** First, the *intended* test:
connect to `example.com`'s resolved IP on port 80 (only `tcp:443` is allowlisted for that domain):

```
$ msb exec egress-spike -- curl -v --max-time 8 http://example.com
* Host example.com:80 was resolved.
* IPv4: 172.66.147.243, 104.20.23.154
*   Trying 172.66.147.243:80...
* connect to 172.66.147.243 port 80 from 172.16.0.254 port 47614 failed: Connection refused
*   Trying 104.20.23.154:80...
* connect to 104.20.23.154 port 80 from 172.16.0.254 port 56794 failed: Connection refused
* Failed to connect to example.com port 80 after 9 ms: Could not connect to server
curl: (7) Failed to connect to example.com port 80 after 9 ms: Could not connect to server
```
Exit code 7, `Connection refused`, ~9ms — instant, not a timeout. Note DNS resolution for `example.com`
itself succeeds (the domain name is allowlisted at all, independent of the port restriction on the rule);
only the actual `connect()` on the disallowed port is refused. `Connection refused` is also what a genuine
closed port on a real host looks like — again not self-distinguishing from "policy blocked this."

**⚠️ CORRECTED BY ORCHESTRATOR VERIFICATION (2026-07-09) — there is NO general raw-IP egress bypass; the original conclusion below is a MISREAD of `socket.connect()` success under msb's fake-accept netstack. The observations are left in place for the record, but the verdict is REVERSED. See the correction box at the end of this subsection. Bottom line: msb CONTAINS raw-IP egress — no data escapes a domain-only deny-default policy via raw IP.**

Original (uncorrected) observation — a raw-IP probe was run as a sanity check and the `socket.connect()` call *returned success*:

```python
# msb exec --timeout 15 egress-spike -- python3 -c "..."
s.connect(('172.66.147.243', 443))   # NOT the example.com domain rule's own IP-at-443 path — a raw IP connect
# → CONNECTED, elapsed 0.0
```

Widened to a completely unrelated IP never touched by any DNS lookup in the session:

```
8.8.8.8:443  → CONNECTED (0.0s)
8.8.8.8:53   → CONNECTED (0.0s), full DNS round-trip (30 bytes) actually received over the raw TCP socket
1.1.1.1:443  → CONNECTED (0.0s)
1.1.1.1:53   → CONNECTED (0.0s)
```

Reproduced on a **fresh sandbox with zero prior DNS activity** (`egress-spike2`, same policy:
`--net-default deny --net-rule "allow@example.com:tcp:443"`) — rules out "stale DNS-triggered dynamic
allow" as the explanation. Reproduced **again with an explicit CIDR/group-based `deny@public` rule added**
(`egress-spike3`: `--net-rule "allow@example.com:tcp:443,deny@public"`), confirmed via
`msb inspect egress-spike3 --format json` that the rule was correctly registered
(`{"action":"deny","destination":{"group":"public"},"direction":"egress",...}`) — still connected, still
received real data (raw DNS query to `8.8.8.8:53` got a real, correctly-formed DNS response).

**Control that rules out "msb never enforces anything":** a `--no-net` sandbox (`nonet-spike`, no
custom rules at all, pure default-deny) correctly **refuses** the identical raw-IP probe
(`8.8.8.8:443` → `ConnectionRefusedError`, 0.0s). So plain default-deny-with-no-rules works. The gap is
specific to **default-deny-with-a-domain-based-allow-rule-present** (with or without an added `deny@public`
group rule) — raw-IP egress passes through unfiltered in that configuration, on this platform
(macOS aarch64, confirmed via `msb doctor`).

> **CORRECTION BOX — orchestrator adversarial re-verification (2026-07-09). The "bypass" is not real; containment holds.**
>
> The original conclusion equated `socket.connect()` returning success with "traffic egressed." Under msb's userspace network stack (macOS/HVF), that equation is false — the netstack **fake-accepts** disallowed TCP connections (the same behavior the ssh-agent spike, rip-cage-r6bo, proved for `host.microsandbox.internal`: connect succeeds, then zero bytes flow and the real destination is never reached). The only probe in the original test that confirmed *real data* was port 53 — which is a red herring, because msb runs a **DNS forwarder** that answers all port-53 traffic itself. Verified live, deny-default + `allow@example.com:tcp:443` only:
>
> - **Raw-IP `1.1.1.1:80`** → `curl: (7) Could not connect` (refused, 0 ms). Blocked.
> - **Raw-IP `1.1.1.1:443`** → `curl: (35) unexpected eof while reading`, 0 bytes; and a raw socket `connect()` succeeds but `recv()` **times out with zero bytes**. The TCP connect is accepted (by msb's TLS-interception proxy, which grabs :443 to inspect SNI) then dropped — **no real remote, no data delivered in either direction**. This is the fake-accept, not egress.
> - **Bogus `192.0.2.1:53`** (TEST-NET-1, RFC 5737 — no server can possibly exist there) → returns a valid **31-byte DNS response**. This proves msb's DNS forwarder intercepts **all** port-53 traffic regardless of destination IP. So the original "`8.8.8.8:53` received real data" was the forwarder answering locally, **not** egress to 8.8.8.8. DNS-layer domain policy is enforced here (§2b/§3 — denied domains get NXDOMAIN).
>
> **Corrected verdict: a domain-based deny-default allowlist DOES contain raw-IP egress on this platform.** No data escapes to a non-allowlisted destination via raw IP: port 80 is refused, port 443 is accepted-then-dropped (zero bytes), port 53 is handled by msb's own DNS forwarder under domain policy. The residual is a **UX wart, not a containment hole** — a guest process gets a misleading "connection succeeded" for a raw-IP :443 attempt that actually goes nowhere (worth noting for agent-facing error clarity, and it compounds the §2 "can't tell blocked from down" problem, but it does not let data out). **Still macOS/HVF-only** — the fake-accept/TLS-intercept-then-drop behavior should be reconfirmed on Linux/KVM before any FIRM design decision, but the direction to verify is "containment holds," not "containment is broken."

## 3. Q3 — host-side denial logging: location, format, per-sandbox tailability, denied-destination recoverability

**Plain network-policy denials (the DNS/TCP denials from §2) are NOT logged anywhere host-side at the
default log level.** Searched exhaustively:

```
$ msb logs egress-spike --source all --json | grep -i "deny|block|reject|policy|firewall|network|dns|nxdomain"
# → only the guest's OWN dig/curl stdout/stderr (captured because msb exec pipes it back) —
#   zero msb-generated audit/decision log lines.
```

`msb logs <name> --source system` at the sandbox's default runtime log level shows only lifecycle/relay
housekeeping (`sandbox starting`, `entering VM`, `agent relay: client connected/disconnected`, etc.) — no
network-decision content at all.

**At `--log-level trace`, DNS-stage denials ARE logged** — a real, previously-undiscovered log channel,
found by re-running the same probes on a sandbox booted with `msb run --log-level trace ...`:

```
$ msb logs trace-spike --source all --json | grep -i "deny"
{"d":"DEBUG microsandbox_network::dns::forwarder: DNS query denied by network policy domain=www.wikipedia.org\n", "s":"system", "t":"2026-07-09T09:09:13.526Z"}
```
Format: JSON Lines (`msb logs ... --json`), `s:"system"` source, DEBUG level, includes the **denied
destination** (`domain=www.wikipedia.org`) — recoverable, exactly what a fix-hint needs. Per-sandbox and
tailable (`msb logs <name> -f --source system`, confirmed the flag exists and works for this stream).
**Caveat: only present at `--log-level trace`** (a boot-time flag on `msb run`/`msb create`, not
retroactively enabled) — the default log level emits nothing for this. No equivalent line was found for
the TCP/connect-stage denial (§2c, the port-80-refused case) at any log level tested (default or trace) —
only the DNS-forwarder layer logs denials; the TCP-connect layer does not, on this platform/version.

**`--on-secret-violation block-and-log` — this IS a distinct, real, always-on log channel** (confirmed the
bead's hunch). Booted a sandbox with a host-scoped secret and default `block-and-log`:

```
msb run -d --name secret-spike --net-default deny \
  --net-rule "allow@example.com:tcp:443,allow@example.org:tcp:443" \
  --secret "MSB_SPIKE_TOKEN@example.com" --on-secret-violation block-and-log \
  rip-cage:latest -- sleep 300
```
Sent the placeholder-substituted token to `example.org` (allowlisted for network, NOT for the secret):

```
$ msb exec secret-spike -- sh -c 'curl -H "Authorization: Bearer $MSB_SPIKE_TOKEN" https://example.org'
curl: (56) OpenSSL SSL_read: OpenSSL/3.5.6: error:0A000126:SSL routines::unexpected eof while reading, errno 0
```
(Distinct failure signature from plain network-deny — TLS connection reset mid-handshake, not a DNS/connect
failure — because this is enforced via the built-in TLS-interception proxy, confirmed present in this
sandbox's boot log: `tls: CA cert found at /.msb/tls/ca.pem, installing into guest trust store`.)

Host-side log, **at default log level, no `--log-level trace` needed** — `on_secret_violation` logging is
independent of runtime verbosity:

```
$ msb logs secret-spike --source system --json | grep -i violat
{"d":"WARN microsandbox_network::secrets::handler: secret violation: placeholder detected for disallowed host action=block-and-log secret_env_var=MSB_SPIKE_TOKEN placeholder=$MSB_MSB_SPIKE_TOKEN protocol=http/1.1 sni=example.org host=example.org method=GET path=/ location=header match_form=raw guest_dst=172.66.157.237:443 http2_stream_id=", "s":"system", "t":"2026-07-09T09:08:16.303Z"}
```
Format: JSON Lines, WARN level, `s:"system"`, per-sandbox, tailable. **Denied destination fully
recoverable and richer than the DNS-denial line**: `host`, `sni`, `guest_dst` (resolved IP:port), `method`,
`path`, `protocol` — everything a fix-hint needs and more. **This channel is scoped specifically to
secret-placeholder misuse (requires a `--secret` binding to exist and be sent toward a non-allowed host
via an HTTP-inspectable channel)** — it is not a general-purpose "any denied connection" log. Do not
conflate it with general egress-denial logging; it answers a narrower question than Q3 asks about broadly.

**Summary table:**

| Denial type | Logged host-side? | Level required | Channel / format | Denied destination recoverable? |
|---|---|---|---|---|
| DNS-stage domain denial | Yes | `--log-level trace` only | `msb logs --source system --json`, DEBUG, `microsandbox_network::dns::forwarder` | Yes (`domain=`) |
| TCP-connect-stage denial (right domain, wrong port; or raw-IP within a `--no-net` cage) | No | — (tested default and trace) | none found | No |
| Secret-placeholder-to-disallowed-host | Yes | any (WARN, always on with `block-and-log`) | `msb logs --source system --json`, WARN, `microsandbox_network::secrets::handler` | Yes, richly (`host`, `sni`, `guest_dst`, `method`, `path`) |
| Plain "allow" traffic (any) | No | tested default and trace, no positive hit | — | N/A |

## 4. Q4 — observe-mode feasibility: VERDICT = not usable as-is

Tested whether ALLOWED connections get logged anywhere that rc could mine for a learned allowlist.
Booted a plain public-only cage (`observe-spike`, no custom net rules), made one successful HTTPS
request, and searched every log source at both default and `trace` runtime log levels:

```
$ msb logs observe-spike --source all --json | grep -iv "relay|core.ready|--- sandbox|starting startup|entering VM|sandbox starting"
{"d":"STATUS:200\n", "s":"stdout", ...}     # only the guest's own curl stdout — not an msb-generated record
```
No allow-decision log line appears at any verbosity tested (confirmed again on `trace-spike` at
`--log-level trace`, where the ALLOWED `example.com` request produced zero corresponding `ALLOW`/`allow`
line — only the DNS *forwarder* logs *denials*, it does not symmetrically log allows).

**Verdict: msb has no allow-but-log / traffic-learning mode, and does not log allowed connections at any
tested verbosity.** An rc-side observe-mode (ADR-012) cannot be built by mining msb's own logs — it would
need its own instrumentation (e.g., a `--net-default allow` cage combined with rc's own proxy/mediator
layer capturing traffic, independent of anything msb emits). Say this plainly per the bead's instruction:
if msb logs nothing usable for this, state so — it logs nothing usable for this.

## 5. Q5 — rule change requires recreate: yes

Per §1, live mutation is impossible, so every allowlist change is a `msb create --replace` /
`msb run --replace` recreate. **Wall-clock: see rip-cage-r8jl** (`docs/2026-07-09-msb-spike-lifecycle.md`
§5) — not re-measured here per the bead's addendum. That spike measured a fully-configured cold boot
(mounts + `--net-default deny` + `--net-rule allow@…` + a label) at **0.303s**, essentially identical to a
bare boot or a snapshot restore.

**What a recreate loses** (cited from r8jl §5, live-confirmed there, not re-derived here): running
processes and in-flight state — tmux/herdr session-server processes, any backgrounded job, in-progress
long-running commands — plus overlay-fs writes outside a mounted path (apt/pip/npm installs, non-mounted
dotfiles, shell history, in-guest caches). What it does **not** lose: anything on a host-mounted directory
or named/disk volume — including, per rip-cage's actual manifest, `~/.claude`, `~/.pi`, and beads/dolt
state (all host-mounted, not overlay writes). So a rule-change-by-recreate is cheap in wall-clock terms
but — as the bead's framing anticipated — **does cost the in-flight session** (any running exec/TTY/tmux
state), requiring cockpit/session re-registration on top of the ~0.3s boot number. No live re-test was run
here to confirm session loss specifically for a *rule-change* recreate (as opposed to r8jl's general
stop/start and cold-boot tests) — r8jl already established process/session state does not survive any
guest-kernel-restarting event, and a `--replace` recreate is exactly such an event, so this generalizes by
the same argument r8jl already made; it was not re-run as its own experiment to avoid duplicating r8jl's
measurement per the bead's explicit instruction.

## 6. Cleanup confirmation

```
$ msb list
No sandboxes found.
$ msb volume list
NAME          KIND    SIZE    CREATED
dockerdata    dir     -       2026-07-08 08:25:14
$ msb image list
REFERENCE          DIGEST                 SIZE         CREATED
docker:dind        sha256:8a370e65c039    125.3 MiB    2026-07-08 08:19:40
rip-cage:latest    sha256:622d3bcaf310    1.1 GiB      2026-07-07 21:04:06
```
Matches the pre-spike clean-slate state exactly. The throwaway `uv` venv used for SDK introspection
(`/tmp/msb-spike`) was also removed.
