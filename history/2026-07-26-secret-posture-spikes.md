# Spike: secret-posture mechanics under msb (overmount masking, --secret wire-bearer, anti-exfil negative control)

Date: 2026-07-26. Machine: mac mini (msb v0.6.4, image `rip-cage:latest`, digest `sha256:9a9f31e07a04` per `msb image list`). All values in this document are **sentinel placeholders** (`SENTINEL_*`) — no real secret or real `.env` from any real repo was touched, read, or copied at any point.

These are mechanics spikes, not feature work: no `rc`/`cli` code was modified. `msb` was invoked directly (mirroring the flag shapes `cli/lib/msb_flags.sh` / `cli/up.sh` already generate) rather than through `rc up`, since the object under test is `msb`'s own primitives (nested `-v`/`--mount-file` overmounts, `--secret`) — the same primitives `rc` already wires for `.rip-cage.yaml`'s ro shadow-mount (ADR-021 D7) and the Claude OAuth token (ADR-029 D5).

## Scratch dir and teardown record

- Scratch dir: `~/tmp-spike-23cp/` (removed at the end of this spike; contained `proj/`, `proj2/`, `masked.env`, plus guest-created artifacts `proj/.env.late`, `proj/scratch-write-test.txt`).
- Sandboxes created → destroyed (both `msb remove --force`, confirmed absent from `msb list` afterward):
  - `spike-s1-overmount` (S1, S4)
  - `spike-s2s3-secret` (S2, S3)
- Pre-existing sandboxes `personal-rip-cage` (stopped) and `rc-r7-redcheck` (crashed) were never touched — confirmed present, unchanged, in every `msb list` snapshot taken during the spike.

---

## S1 — overmount-mask a `.env`

**Question:** can a nested single-file `ro` mount cleanly shadow `/workspace/.env` under msb, the same mechanic `cli/up.sh:482-501` already uses for `.rip-cage.yaml`?

**Setup:**
- `~/tmp-spike-23cp/proj/.env` (host, workspace root): `API_KEY=SENTINEL_SHOULD_BE_HIDDEN`
- `~/tmp-spike-23cp/masked.env` (host, outside workspace): `API_KEY=SENTINEL_MASKED_PLACEHOLDER`

**Command:**
```
msb create --name spike-s1-overmount --replace \
  -v "$HOME/tmp-spike-23cp/proj:/workspace" \
  -v "$HOME/tmp-spike-23cp/masked.env:/workspace/.env:ro" \
  -w /workspace \
  rip-cage:latest
```
`exit=0`. (`msb create` boots the image's default entrypoint; there is no trailing command override — matches the documented `_up_translate_docker_args_to_msb` contract.)

**Observed:**

Guest sees the masked content, not the real one (avoided literally `cat`-ing a `.env` path per this session's own guard; used presence-only `grep -c` on each sentinel marker instead):
```
$ msb exec spike-s1-overmount -- sh -c 'grep -c SHOULD_BE_HIDDEN /workspace/.env; echo grep_exit=$?'
0
grep_exit=1
$ msb exec spike-s1-overmount -- sh -c 'grep -c MASKED_PLACEHOLDER /workspace/.env; echo grep_exit=$?'
1
grep_exit=0
```

Permissions / rest-of-workspace:
```
$ msb exec spike-s1-overmount -- ls -la /workspace/.env
-rw-r--r-- 2 agent agent 36 Jul 26 11:16 /workspace/.env
$ msb exec spike-s1-overmount -- ls -la /workspace
total 4
-rw-r--r-- 2 agent agent 36 Jul 26 11:16 .env
```
(Link count 2 — consistent with a bind/virtiofs single-file mount, not a copy.)

Write attempt to the masked file:
```
$ msb exec spike-s1-overmount -- sh -c 'echo PWNED_CONTENT > /workspace/.env; echo write_exit=$?'
write_exit=2
sh: 1: cannot create /workspace/.env: Read-only file system
$ msb exec spike-s1-overmount -- sh -c 'grep -c MASKED_PLACEHOLDER /workspace/.env; grep -c PWNED_CONTENT /workspace/.env'
1
0
```
Content is unchanged after the failed write (still the masked placeholder, not the attempted overwrite).

Rest of `/workspace` stays rw:
```
$ msb exec spike-s1-overmount -- sh -c 'echo hello_rw_test > /workspace/scratch-write-test.txt; echo write_exit=$?; cat /workspace/scratch-write-test.txt'
write_exit=0
hello_rw_test
```
Confirmed on the host side too (bidirectional rw sync, `.env` unaffected):
```
$ grep -q SHOULD_BE_HIDDEN ~/tmp-spike-23cp/proj/.env && echo "host .env still has original sentinel: YES"
host .env still has original sentinel: YES
$ ls -la ~/tmp-spike-23cp/proj/
-rw-r--r--  1 jonatanpi  staff   34 ... .env
-rw-------@ 1 jonatanpi  staff   14 ... scratch-write-test.txt
```

**VERDICT: validated.** The nested single-file `ro` mount cleanly shadows `/workspace/.env`: the guest reads the masking file's content (never the real one), the masked path is read-only (`EROFS` on write, content provably unchanged), and the rest of `/workspace` remains fully rw in both directions. No surprises — this matches the `.rip-cage.yaml` shadow-mount mechanic already shipped in `cli/up.sh`, now independently confirmed for an arbitrary `.env`-shaped file with a *different* masking source (not just "shadow the same file with a ro copy of itself").

---

## S2 — Class-A wire-bearer recipe end-to-end

**Question:** does a placeholder-only guest env value get substituted with the real credential only toward the bound host, on the actual wire?

**Setup:**
- `~/tmp-spike-23cp/proj2/.env`: `ECHO_TOKEN=$MSB_SPIKE_TOKEN` (literal placeholder string, matching the exact format `_msb_flags_generate` documents: for `--secret ENV@HOST`, the guest placeholder is the literal string `$MSB_ENV`).
- Host-side sentinel "real" value: `SPIKE_TOKEN=SENTINEL_REAL_abc123`, exported only for the `msb create` invocation, `unset` immediately after.
- Bound host: `httpbingo.org` (chosen per the given guidance — `httpbin.org` is flaky), allowlisted at `tcp:443`.
- A second allowlisted-but-unbound host, `example.com`, added at creation time for S3's reuse of this same cage.

**Command:**
```
export SPIKE_TOKEN="SENTINEL_REAL_abc123"
msb create --name spike-s2s3-secret --replace \
  -v "$HOME/tmp-spike-23cp/proj2:/workspace" -w /workspace \
  --net-default deny \
  --net-rule "allow@httpbingo.org:tcp:443" \
  --net-rule "allow@example.com:tcp:443" \
  --secret "SPIKE_TOKEN@httpbingo.org" \
  --on-secret-violation block-and-log \
  -e 'ECHO_TOKEN=$MSB_SPIKE_TOKEN' \
  --log-level trace \
  rip-cage:latest
unset SPIKE_TOKEN
```
`exit=0`. No `--tls-intercept` flag was passed explicitly — binding a `--secret` to a host is sufficient to trigger TLS interception for that host's traffic (consistent with the prior `rip-cage-cmqb` Claude-token spike, which also omitted it).

**At-rest config never holds the real value** (`msb inspect spike-s2s3-secret --format json`):
```
"secrets": [{
  "allowed_hosts": [{"exact": "httpbingo.org"}],
  "env_var": "SPIKE_TOKEN",
  "placeholder": "$MSB_SPIKE_TOKEN",
  "source": {"kind": "env", "var": "SPIKE_TOKEN"},
  "value": ""
}]
```

**Guest surfaces hold only the placeholder, before the wire call:**
```
$ msb exec spike-s2s3-secret -- sh -c 'echo "ECHO_TOKEN=$ECHO_TOKEN"; echo "len=${#ECHO_TOKEN}"'
ECHO_TOKEN=$MSB_SPIKE_TOKEN
len=16
$ msb exec spike-s2s3-secret -- sh -c 'grep -c MSB_SPIKE_TOKEN /workspace/.env; grep -c SENTINEL_REAL_abc123 /workspace/.env; echo grep_exit=$?'
1
0
grep_exit=1
```

**The wire call:**
```
$ msb exec spike-s2s3-secret -- sh -c 'curl -sS -m 10 -o /tmp/resp.json -w "http_code=%{http_code}\n" -H "Authorization: Bearer $ECHO_TOKEN" https://httpbingo.org/headers; echo curl_exit=$?'
http_code=200
curl_exit=0
$ msb exec spike-s2s3-secret -- cat /tmp/resp.json
{
  "headers": {
    "Authorization": ["Bearer SENTINEL_REAL_abc123"],
    "Host": ["httpbingo.org"],
    ...
  }
}
```
`httpbingo.org/headers` — an echo endpoint — shows `SENTINEL_REAL_abc123` on the wire. The guest sent the literal placeholder string; msb's TLS-intercepting proxy substituted the real value only toward the bound host.

**Guest-visible surfaces after the call still hold only the placeholder:**
```
$ msb exec spike-s2s3-secret -- sh -c 'echo "ECHO_TOKEN=$ECHO_TOKEN"'
ECHO_TOKEN=$MSB_SPIKE_TOKEN
$ msb exec spike-s2s3-secret -- sh -c 'grep -c MSB_SPIKE_TOKEN /workspace/.env'
1
$ msb exec spike-s2s3-secret -- sh -c 'cat /proc/self/environ | tr "\0" "\n" | grep -i echo_token'
ECHO_TOKEN=$MSB_SPIKE_TOKEN
```

**Whole-guest-filesystem scan for the real value — one caveat and its resolution:**

First pass found one hit: `/tmp/resp.json`, the file I had explicitly saved the echoed HTTP *response* to via `-o /tmp/resp.json` in the command above. This is **not** a possession leak by the guest process — it is the httpbingo.org echo endpoint's response body legitimately containing the substituted value, which I chose to persist to disk as part of inspecting the wire result. It is the same category of artifact as the response content itself (already shown above), not a new exposure surface. After removing that self-created artifact:
```
$ msb exec spike-s2s3-secret -- rm -f /tmp/resp.json
$ msb exec spike-s2s3-secret -- sh -c 'grep -rl "SENTINEL_REAL_abc123" / --exclude-dir=proc --exclude-dir=sys 2>/dev/null; echo scan_exit=$?'
scan_exit=2
```
`scan_exit=2` with no printed matches = some permission-denied paths encountered, zero matches (same convention as the prior `rip-cage-cmqb` spike's whole-fs scan). No sentinel-real value anywhere on the guest filesystem once the self-created response capture is cleaned up.

**VERDICT: validated.** Full Class-A wire-bearer recipe confirmed end-to-end with a sentinel credential: guest holds the placeholder everywhere (`.env`, env var, `/proc/self/environ`, at-rest sandbox config), the real value only ever appears on the wire toward the bound host, and (once a self-created response-capture artifact is accounted for) no guest-visible surface holds the real value. This corroborates — with an independent, non-Claude-API credential — the same mechanism `rip-cage-cmqb`/ADR-029 D5 already proved for the real Anthropic token; per the task brief, that leg is not re-claimed as newly proven here.

**Surprise (minor, methodological, not a design finding):** saving a wire response to disk inside the guest will of course contain the real value if the remote server echoes it back — a naive "grep the whole guest fs for the sentinel" check will flag your own diagnostic artifacts as false positives. Worth remembering for any future automated non-possession probe: exclude or account for locally-captured response bodies, or the check will cry wolf on its own instrumentation.

---

## S3 — negative control (anti-exfil claim)

**Question:** does sending the placeholder toward a *different*, allowlisted-but-not-secret-bound host block-and-log (not substitute)?

Reused the S2 cage (`spike-s2s3-secret`), which already had `example.com` allowlisted but never bound to the `SPIKE_TOKEN` secret.

**Command:**
```
$ msb exec spike-s2s3-secret -- sh -c 'curl -sS -m 10 -o /dev/null -w "http_code=%{http_code} size=%{size_download}\n" -H "Authorization: Bearer $ECHO_TOKEN" https://example.com/ ; echo curl_exit=$?'
http_code=000 size=0
curl_exit=56
curl: (56) OpenSSL SSL_read: OpenSSL/3.5.6: error:0A000126:SSL routines::unexpected eof while reading, errno 0
```
Guest observes a TCP connect that "succeeds" then dies mid-TLS (fake-accept, zero bytes) — indistinguishable, from the guest's own vantage point, from any other denied-host failure. The guest gets **no signal that this was specifically a secret violation** — that information lives only in the host-side log, not surfaced in-guest.

**Where the violation is logged** (`msb logs <name> --source system`, host-side only):
```
$ msb logs spike-s2s3-secret --source system --since 5m | grep -iE "violat|secret" | grep -v clienthello | grep -v extended_master_secret
WARN microsandbox_network::secrets::handler: secret violation: placeholder detected for disallowed host action=block-and-log secret_env_var=SPIKE_TOKEN placeholder=$MSB_SPIKE_TOKEN protocol=http/1.1 sni=example.com host=example.com method=GET path=/ location=header match_form=raw guest_dst=172.66.147.243:443 http2_stream_id=
DEBUG microsandbox_network::tls::proxy: TLS proxy task ended dst=172.66.147.243:443 guest_dst=172.66.147.243:443 error=secret violation: placeholder sent to disallowed host
```
The WARN line explicitly names the mechanism (`secret violation: placeholder detected for disallowed host`), the credential (`secret_env_var=SPIKE_TOKEN`), the disallowed destination (`sni=example.com`), and the enforced action (`block-and-log`) — this is not a generic connection failure, it is the secret-violation guard actively firing.

**VERDICT: validated (it did block, as claimed).** The anti-exfil claim holds: a placeholder sent toward an allowlisted-but-unbound host is actively blocked-and-logged, not substituted. Nothing here invalidates the claim.

**Notable nuance (not an invalidation, but worth flagging for design):** the block-and-log is **host-log-only**. From inside the guest, a secret violation is observationally identical to any other denied-host failure (`http_code=000`, `SSL_read unexpected eof`). An in-cage agent (or `rc doctor`'s trace-mining) cannot currently distinguish "this failed because of the egress allowlist" from "this failed because you tried to exfiltrate a bound credential" without the human/host pulling `msb logs --source system`. If credential-misdirection ever needs to be a *fast* deny→fix→reload loop the way host-allowlist denials already are (per this repo's `rc doctor`/`rc reload` fix-hint mechanism), that hint currently isn't mined from this specific log line — worth a follow-up bead if that gap matters, but out of scope for this spike to build.

---

## S4 — create-time limit (documentation + one probe)

**Question:** confirm masking is boot-time only — a file created after boot is unmasked, as expected (no mechanism claims otherwise).

Reused `spike-s1-overmount` before its teardown.

```
$ msb exec spike-s1-overmount -- sh -c 'echo SENTINEL_LATE=SHOULD_BE_VISIBLE_LATE > /workspace/.env.late; echo write_exit=$?'
write_exit=0
$ msb exec spike-s1-overmount -- sh -c 'grep -c SHOULD_BE_VISIBLE_LATE /workspace/.env.late'
1
$ grep -q SHOULD_BE_VISIBLE_LATE ~/tmp-spike-23cp/proj/.env.late && echo "host sees late file: YES"
host sees late file: YES
```

**VERDICT: validated (documentation confirmed, as expected — no surprise).** A file created by the guest after boot is plainly readable by the guest and syncs straight through to the host via the ordinary rw workspace mount; no masking mechanism intercepts it. **Residual, stated plainly:** overmount masking is a **boot-time, create-time-only** mechanism — it shadows a path that already exists (or is declared) at `msb create` time. It provides zero protection against a secret-looking file the guest (or an injected instruction driving the guest) creates or writes to *after* boot — `.env.late`, a stray `credentials.json` dropped by a build step, a config file an agent writes mid-session, etc. Anything created post-boot is exactly as exposed as any other file in the rw `/workspace` mount. This is a known, narrow scope for the mechanic (it protects a specific pre-declared path, not "any file that looks like a secret"), not a bug — but it means overmount masking is not a general secret-hygiene control on its own; it only helps for the specific case of "a real secret file already sits at a known path before the cage boots."

---

## Summary

| Spike | Verdict |
|---|---|
| S1 — overmount-mask a `.env` | **Validated.** Nested single-file `ro` mount cleanly shadows the path; masked file is read-only and unwritable; rest of `/workspace` stays rw both directions. |
| S2 — Class-A wire-bearer recipe | **Validated.** Sentinel real value appears on the wire toward the bound host only; guest surfaces (`.env`, env, `/proc`, at-rest config) hold only the placeholder throughout. |
| S3 — negative control (anti-exfil) | **Validated.** Placeholder toward an unbound allowlisted host is block-and-logged, not substituted — confirmed via the host-side `secret violation` WARN log. |
| S4 — create-time limit | **Validated / documented.** Masking is boot-time only; anything the guest creates post-boot is unmasked and freely readable — a stated, narrow residual, not a defect. |

**Most design-relevant finding overall:** S3's nuance — a secret violation is currently indistinguishable, from inside the guest, from an ordinary egress denial (`http_code=000`, TLS EOF). The block-and-log is real and does fire, but it's host-log-only; there's no in-guest or `rc doctor`-mined signal today that says "that failure was a credential-misdirection attempt," unlike the fix-hint flow already built for plain host-allowlist denials.

## Teardown confirmation

```
$ msb remove --force spike-s1-overmount
   ✓ Removed      spike-s1-overmount
$ msb remove --force spike-s2s3-secret
   ✓ Removed      spike-s2s3-secret
$ msb list
NAME                 IMAGE              STATUS     CREATED
personal-rip-cage    rip-cage:latest    stopped    2026-07-14 18:52:57
rc-r7-redcheck       rip-cage:latest    crashed    2026-07-13 00:58:04
```
Both pre-existing sandboxes (`personal-rip-cage`, `rc-r7-redcheck`) present and unmodified — untouched throughout, as required.

Scratch dir `~/tmp-spike-23cp/` removed at the end of this spike (`rm -rf ~/tmp-spike-23cp`), after this results doc was written.
