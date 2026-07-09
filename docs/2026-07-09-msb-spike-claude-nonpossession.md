# Spike: real Claude Code CLI under msb `--secret` non-possession — RE-RUN, AUTHORIZED

Bead: rip-cage-cmqb. Machine: mac mini (msb v0.6.4, rip-cage:latest). Date: 2026-07-09.

**This re-run SUPERSEDES the earlier same-day stop-and-flag content of this
file.** The prior run stopped at the credential precondition because the only
long-lived token found on the host (`~/.rc-secrets/claude-work-token`) is
explicitly earmarked, by its own README, for a different shared account
(`finn@mapular.com`) and a different purpose (the `claude work` shell
shortcut). The user has now **explicitly authorized** spending that account's
agent credit on this spike's handful of `claude -p` probes (see bead NOTES,
"REOPENED 2026-07-09"). This document reports the actual Q1–Q3 run that
authorization unblocked.

## Verdict: WORKS

Claude Code CLI ran fully non-possessed inside an `msb` sandbox: the guest
process only ever held the `msb` placeholder string (`$MSB_CCTOK`), never the
real token; `msb`'s host-side secret-injection layer substituted the real
long-lived token on the wire only for requests to `api.anthropic.com`; and
three separate `claude -p` invocations returned real, distinct model
completions.

## Precondition and token type

- Precondition (per bead design): a long-lived token, not a short-lived
  refreshing OAuth session, must exist on-host. `~/.rc-secrets/claude-work-token`
  satisfies this and is now authorized for this spike.
- Token type, determined **without printing the value** via
  `case "$(head -c 10 "$TOKFILE")" in sk-ant-oat*) ...; sk-ant-api*) ...; esac`:
  **`sk-ant-oat` — a `claude setup-token` output (subscription setup-token,
  long-lived, no refresh cycle)**. Per the token-type branch, it was injected
  as `CLAUDE_CODE_OAUTH_TOKEN`, never `ANTHROPIC_API_KEY`.
- The token value was never read into this session's context, echoed, or
  logged. It was read host-side only via `export CCTOK="$(cat
  "$HOME/.rc-secrets/claude-work-token")"` in a bash call whose output is not
  the token, then handed to `msb run --secret "CCTOK@api.anthropic.com"` and
  immediately `unset`.

## Mechanism used

```
export CCTOK="$(cat "$HOME/.rc-secrets/claude-work-token")"
msb run -d --name ccnp-a01 --replace --log-level trace \
  --net-default deny \
  --net-rule "allow@api.anthropic.com:tcp:443" \
  --net-rule "allow@mcp-proxy.anthropic.com:tcp:443" \
  --net-rule "allow@http-intake.logs.us5.datadoghq.com:tcp:443" \
  --secret "CCTOK@api.anthropic.com" \
  --on-secret-violation block-and-log \
  rip-cage:latest -- sleep 3600
unset CCTOK
```

Note on CLI shape vs. the bead design's example: this `msb` version rejects
inline `ENV=VALUE@HOST` secrets ("the value would be stored in the sandbox
config at rest") and requires `ENV@HOST`, resolving `ENV` from a host
environment variable of the **same name** at sandbox-start time. So the host
export and the guest-visible variable are both named `CCTOK` (not two
different names) — the real value never appears in the `msb` command line or
config, only the env-var *name* does. Confirmed via `msb inspect ccnp-a01
--format json`, `network.secrets.secrets[0]`: `"env_var": "CCTOK"`,
`"placeholder": "$MSB_CCTOK"`, `"value": ""` (the sandbox's own persisted
config stores an **empty string**, never the real token, matching the CLI's
stated at-rest guarantee).

`claude` (baked into `rip-cage:latest` at `/usr/local/bin/claude`, v2.1.199 —
confirmed via `msb exec ccnp-a01 -- claude --version`, no `npx` install
needed) was run with:

```
msb exec ccnp-a01 -- sh -c \
  'CLAUDE_CONFIG_DIR=/tmp/ccnp-scratch-home CLAUDE_CODE_OAUTH_TOKEN=$CCTOK claude -p "..."'
```

`CLAUDE_CONFIG_DIR` pointed at a fresh, empty directory created in-guest
(`/tmp/ccnp-scratch-home`) — no real credential file mounted or present.
Verified before every run:

```
$ msb exec ccnp-a01 -- sh -c 'ls -la $HOME/.claude; find / -iname "*.credentials.json" 2>/dev/null; find / -iname "auth.json" 2>/dev/null'
HOME=/home/agent
total 8
drwxr-xr-x 2 agent agent  27 Jul  7 17:33 .
drwx------ 6 agent agent 189 Jul  7 17:33 ..
(no matches from either find)
$ msb exec ccnp-a01 -- sh -c 'ls -la /home/agent/.claude.json'
ls: cannot access '/home/agent/.claude.json': No such file or directory
```

The `[claude-wrapper] WARNING: no ~/.claude/.claude.json.seed snapshot
found...` banner that appears on every `claude` invocation is benign — it
fires on ENOENT of an unrelated seed file (rip-cage-p1p R4), not on presence
of a credential.

## Q1 — does claude even send the placeholder?

**PASS — reaches the wire, no client-side shape-check block.** The known risk
(client-side token-shape validation rejecting a placeholder with no
`sk-ant-oat`/`sk-ant-api` substring) did **not** materialize: `claude -p`
proceeded to a real TLS handshake against `api.anthropic.com` using the
non-shaped placeholder `$MSB_CCTOK` as the `CLAUDE_CODE_OAUTH_TOKEN` value.
Confirmed via `msb logs ccnp-a01 --source system --log-level trace`:

```
DEBUG microsandbox_network::tls::proxy: TLS intercept sni=api.anthropic.com dst=160.79.104.10:443 guest_dst=160.79.104.10:443
TRACE rustls::server::hs: we got a clienthello ... server_name: SingleDnsName(DnsName("api.anthropic.com")) ...
```

Multiple real TLS ClientHellos to `api.anthropic.com` were observed across
the three `claude -p` invocations in this spike (msb's TLS-intercepting
proxy terminates and re-originates each connection, which is why the trace
shows the guest-facing side of the handshake — the important fact is the SNI
and destination IP are the real Anthropic API host, not a decoy, and the
result is a real completion, per Q2).

## Q2 — does substitution produce a real completion?

**PASS.** Per the `msb-netstack-fake-accepts-tcp-connect-not-egress` memory,
`connect()`-success is not proof; the required proof is a real application
response body. Three separate `claude -p` calls, all under
`CLAUDE_CODE_OAUTH_TOKEN=$CCTOK` (guest-side placeholder only), returned real,
content-distinct completions:

| Prompt | Response | Evidence it's real inference, not an echo/cache |
|---|---|---|
| `reply exactly: NONPOSSESSION-OK` | `NONPOSSESSION-OK` | Baseline instruction-following |
| `What is 47 times 61? Reply with only the numeric product, nothing else.` | `2867` | **Correct** (47×61=2867); computed, not verbatim from the prompt; ~3.9s wall time (`date +%s.%N` before/after: `1783620403.297972000` → `1783620407.181227000`), consistent with real network + inference latency, not an instant local echo |
| Haiku about non-possession + literal marker `PROC-CHECK-DONE` on the final line | `Secrets held loosely,`<br>`open hands cast no locked doors—`<br>`what's kept is not mine.`<br><br>`PROC-CHECK-DONE` | Generative content (a haiku is not derivable from the prompt by any local echo/cache mechanism) |

**Discovered host list** (all `claude -p` traffic observed via
`--log-level trace`, unique SNI/DNS-query domains across all three runs):

- `api.anthropic.com` — **required**; this is the only host `claude -p`
  actually contacted for the model call itself.
- `http-intake.logs.us5.datadoghq.com` — contacted (Datadog telemetry),
  **non-blocking**: it was allowlisted for network but **not** bound to the
  `CCTOK` secret (see negative control below), and the run succeeded whether
  or not this host's connection completed.
- `mcp-proxy.anthropic.com` — allowlisted per the headstart brief but **not
  observed to be contacted** in any of the three basic non-interactive
  `claude -p` runs in this spike. It may only fire under MCP-tool-loading or
  interactive-session conditions not exercised here. Recorded for
  completeness; no new host beyond the headstart's three was discovered.

**Token-to-host binding** (the 7fqe footgun — distinct env-var names per host
if a secret must be sent to multiple hosts): only **one** binding was needed.
`CCTOK` was bound to `api.anthropic.com` only. No other host required the
Anthropic credential — confirmed both structurally (`msb inspect`:
`network.secrets.secrets[0].allowed_hosts == [{"exact":"api.anthropic.com"}]`)
and behaviorally (the negative control below shows the placeholder is
actively blocked, not silently substituted, when it heads toward any other
host).

## Q3 — non-possession verification

All checks below with the sandbox mid-run (or immediately after, for disk).

**Guest env is placeholder-only:**

```
$ msb exec ccnp-a01 -- sh -c 'echo "CCTOK=$CCTOK"; echo "len=${#CCTOK}"'
CCTOK=$MSB_CCTOK
len=10
```

**Own-process /proc/self/environ is placeholder-only** (the same shell that
sets `CLAUDE_CODE_OAUTH_TOKEN=$CCTOK` before exec'ing `claude`, so `claude`
inherits the identical placeholder value by POSIX exec() semantics):

```
$ msb exec ccnp-a01 -- sh -c 'cat /proc/self/environ | tr "\0" "\n" | grep -i cctok'
CCTOK=$MSB_CCTOK
```

(A live-PID capture of the running `claude` subprocess's own
`/proc/<pid>/environ` mid-flight was attempted via a backgrounded probe +
poll loop, but each `claude -p` call in this spike completed inside the
polling interval before the poller caught a readable environ for its PID —
not a possession leak, just a timing miss. The shell-inheritance evidence
above is equivalent proof: `exec()` does not mutate the environment, so
`CLAUDE_CODE_OAUTH_TOKEN` in the `claude` process is byte-identical to
`$CCTOK` in the invoking shell, which is confirmed placeholder-only.)

**`/proc/1/environ` is unreadable** (satisfies the design's "unreadable or
placeholder-only" either/or):

```
$ msb exec ccnp-a01 -- sh -c 'cat /proc/1/cmdline | tr "\0" " "; cat /proc/1/environ'
/init.krun
cat: /proc/1/environ: Permission denied
```

**No token-shaped string on guest disk** (scratch home + `/tmp`, per the
design; plus a broader whole-filesystem pass for extra diligence):

```
$ msb exec ccnp-a01 -- sh -c 'grep -rlE "sk-ant-(oat|api)[A-Za-z0-9_-]{6,}" /tmp /home/agent 2>/dev/null; echo "grep_exit=$?"'
grep_exit=1                    # 1 = no match found
$ msb exec ccnp-a01 -- sh -c 'grep -rlE "sk-ant-(oat|api)[A-Za-z0-9_-]{6,}" / --exclude-dir=proc --exclude-dir=sys 2>/dev/null; echo "exit=$?"'
exit=2                          # 2 = some unreadable paths (permission-denied dirs), NOT a match; grep -l prints nothing when no match, and nothing was printed
```

**Negative control** — send `$CCTOK` (placeholder) from the guest toward an
allowlisted-but-**not**-secret-bound host
(`http-intake.logs.us5.datadoghq.com`):

```
$ msb exec ccnp-a01 -- sh -c 'curl -sS -m 10 -o /dev/null -w "http_code=%{http_code} size=%{size_download}\n" -H "Authorization: Bearer $CCTOK" https://http-intake.logs.us5.datadoghq.com/ ; echo "curl_exit=$?"'
http_code=000 size=0
curl_exit=56
curl: (56) OpenSSL SSL_read: OpenSSL/3.5.6: error:0A000126:SSL routines::unexpected eof while reading, errno 0
```

**Blocked-and-logged**, confirmed via the secret-handler's own WARN line
(not just a generic connection failure — the log line names the exact
mechanism):

```
$ msb logs ccnp-a01 --source system --since 2m | grep -iE "violat|secret" | grep -v clienthello | grep -v extended_master_secret
DEBUG microsandbox_network::tls::proxy: TLS proxy task ended dst=34.149.66.137:443 guest_dst=34.149.66.137:443 error=secret violation: placeholder sent to disallowed host
WARN microsandbox_network::secrets::handler: secret violation: placeholder detected for disallowed host action=block-and-log secret_env_var=CCTOK placeholder=$MSB_CCTOK protocol=http/1.1 sni=http-intake.logs.us5.datadoghq.com host=http-intake.logs.us5.datadoghq.com method=GET path=/ location=header match_form=raw guest_dst=34.149.66.137:443 http2_stream_id=
```

This single log line is strong corroborating evidence for **both** Q3 (the
guest's placeholder is actively tracked and blocked outside its bound host —
it is not a dead/no-op value) and Q1/Q2 (the same substitution machinery,
observed here refusing to act for the wrong host, is what silently and
correctly acted for `api.anthropic.com` to produce the three real completions
above — no separate "substitution succeeded" log line was emitted at any
verbosity for the successful path, only violations are logged, by design of
`--on-secret-violation`).

## Non-possession decision impact

Per the bead: this **WORKS** outcome does not need to reverse anything — it
is a **confirming** result for the credential non-possession decision
(`credential-non-possession-shipped-and-proven`). It additionally proves,
against the *real* Claude Code CLI (not a fixture), the worked-example tier
the bead was scoped to close: msb's native `--secret` mechanism holds up
end-to-end for Anthropic's `claude setup-token` credential class, with one
host binding required (`api.anthropic.com`), no client-side shape-check
blocker, and an active (not merely configured) secret-violation guard on
misdirected use of the placeholder.

## Cleanup performed

```
$ msb remove --force ccnp-a01
   ✓ Removed      ccnp-a01
$ msb list
No sandboxes found.
$ msb status -a
No sandboxes found.
```

No other `ccnp-*` sandboxes existed before or after this spike. The scratch
`CLAUDE_CONFIG_DIR` (`/tmp/ccnp-scratch-home`) was guest-internal and was
destroyed with the sandbox on removal (tmpfs `/tmp` mount, non-persistent).
Host-side, the `CCTOK` environment variable was `unset` immediately after the
`msb run` boot command in the same shell invocation, and confirmed absent in
a fresh shell afterward (`test -n "${CCTOK+x}"` → not set).

## No-token-value-leaked verification

```
$ grep -rniE 'sk-ant-(oat|api)[A-Za-z0-9_-]{6,}' /Users/jonatanpi/code/personal/rip-cage/docs/2026-07-09-msb-spike-claude-nonpossession.md
(no output — see note below)
```

This document intentionally does **not** repeat the earlier stop-and-flag
run's ellipsis-prefix format quote (`sk-ant-oat01-…`, `sk-ant-api…`); it only
uses the general regex-class prose `sk-ant-(oat|api)` (no trailing digits or
dashes attached) when describing the check pattern itself, which does not
match the leak-detection regex's `{6,}`-characters-following requirement. No
token value, partial token fragment, or raw content from
`~/.rc-secrets/claude-work-token` or any `~/.claude*` credential file appears
anywhere in this document, in `msb inspect` output (`"value": ""`), or in
`msb logs` (checked: `msb logs ccnp-a01 --source all | grep -oE
'sk-ant-(oat|api)[A-Za-z0-9_-]{6,}'` → no matches before sandbox removal).
