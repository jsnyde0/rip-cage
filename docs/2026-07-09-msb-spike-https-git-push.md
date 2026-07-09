# msb spike — HTTPS git push with a host-bound token via `--secret` (2026-07-09)

Home bead: **rip-cage-7fqe**. Facts-only spike; the git-push design decision itself happens
in the epic brainstorm (rip-cage-tsf2). Machine: the Mac mini (msb v0.6.4, image
`rip-cage:latest`, macOS/HVF). GitHub account: **jsnyde0**, `gh auth token` (`repo` scope).
Scratch repo: `jsnyde0/httpspush-msb-spike-scratch` (private, created and deleted for this
spike).

**Netstack caveat applied throughout:** per the `msb-netstack-fake-accepts-tcp-connect-not-egress`
memory, `connect()`/exit-0 alone is never treated as proof. Every "works" claim below is backed
by real bidirectional application data: an actual `git push` landing a real commit (verified
independently via `gh api` from the host, outside the guest), real HTTP response bodies
(`size_download` > 0, real JSON), or a real GitHub-generated PR.

---

## Setup

```
export GH_TOKEN="$(gh auth token)"
msb run -d --name httpspush-basic \
  --net-default deny \
  --net-rule "allow@github.com:tcp:443" \
  --secret "GH_TOKEN@github.com" \
  --on-secret-violation block-and-log \
  rip-cage:latest -- sleep 900
```

**Syntax note (not in the bead's draft command):** `msb run --secret "GH_TOKEN=<value>@HOST"`
(inline value) is **rejected** at create time: *"inline secret values ... are not supported by
`create`: the value would be stored in the sandbox config at rest. Export the value as a host
environment variable and reference it with `GH_TOKEN@HOST` instead."* The working form reads the
value from a host env var at start time: `export GH_TOKEN="$(gh auth token)"` then
`--secret "GH_TOKEN@github.com"` (bare `ENV@HOST`, no `=VALUE`).

Confirmed in-guest immediately after boot:

```
$ msb exec httpspush-basic -- sh -c 'echo GH_TOKEN=$GH_TOKEN'
GH_TOKEN=$MSB_GH_TOKEN
```

```
$ msb exec httpspush-basic -- sh -c 'grep -a GH_TOKEN /proc/1/environ'
grep: /proc/1/environ: Permission denied
```

Placeholder form confirmed (`$MSB_GH_TOKEN`, never the real OAuth-token value); the real value is
also unreadable via `/proc/1/environ` (EACCES).

---

## Q1 — substitution through git's auth paths (the encoding crux)

Tested three forms against `github.com` (the private scratch repo requires auth; a negative
control with garbage credentials confirms the repo is not silently public — see below).

**(a) URL-embedded form** — `https://x-access-token:$GH_TOKEN@github.com/....git`. git/libcurl
base64-encodes this internally into an `Authorization: Basic` header before sending.

```
$ msb exec httpspush-basic -- sh -c 'cd /tmp && GIT_TERMINAL_PROMPT=0 git clone \
    "https://x-access-token:$GH_TOKEN@github.com/jsnyde0/httpspush-msb-spike-scratch.git" q1a-url-clone'
Cloning into 'q1a-url-clone'...
warning: You appear to have cloned an empty repository.
EXIT=0
```

Negative control (garbage token, same URL form, proves the repo actually enforces auth):

```
$ msb exec httpspush-basic -- sh -c 'cd /tmp && GIT_TERMINAL_PROMPT=0 git clone \
    "https://x-access-token:garbage-not-a-real-token@github.com/jsnyde0/httpspush-msb-spike-scratch.git" q1a-negative-control'
remote: Invalid username or token. Password authentication is not supported for Git operations.
fatal: Authentication failed for 'https://github.com/jsnyde0/httpspush-msb-spike-scratch.git/'
EXIT=128
```

→ **Basic-auth-via-URL form works.** The placeholder was substituted with the real token even
though it was base64-encoded by git's own HTTP backend before hitting the wire.

**(b) Header form, explicit Bearer** — `git -c http.extraHeader="Authorization: Bearer $GH_TOKEN"`:

```
$ msb exec httpspush-basic -- sh -c 'cd /tmp && GIT_TERMINAL_PROMPT=0 git -c http.extraHeader="Authorization: Bearer $GH_TOKEN" clone \
    "https://github.com/jsnyde0/httpspush-msb-spike-scratch.git" q1b-header-clone'
fatal: could not read Username for 'https://github.com': terminal prompts disabled
EXIT=128
```

Isolated with raw curl against the git smart-HTTP endpoint directly (removes git's credential-prompt
noise):

```
$ msb exec httpspush-basic -- sh -c 'curl -sS -o /tmp/q1b-curl-out.txt -w "HTTP_CODE=%{http_code} SIZE=%{size_download}\n" \
    -H "Authorization: Bearer $GH_TOKEN" "https://github.com/.../info/refs?service=git-upload-pack"'
HTTP_CODE=401 SIZE=19
```

**Disambiguation control — run on the HOST directly, with the real token, never printed:**

```
$ curl -sS -o /dev/null -w "HTTP_CODE=%{http_code}\n" -H "Authorization: Bearer $(gh auth token)" \
    "https://github.com/.../info/refs?service=git-upload-pack"
HTTP_CODE=401
```

**The 401 is GitHub-side, not an msb substitution miss.** GitHub's git-smart-HTTP endpoint rejects
the `Bearer` scheme for a classic OAuth PAT even with the real token — confirmed
independent of msb entirely. (The prior 2026-07-07 spike §1b already live-proved msb's raw-Bearer
substitution mechanism works in general, against `postman-echo.com` — this is a GitHub API/token-type
constraint, not an msb gap.)

**(c) Basic-auth header, both curl-internal and guest-computed base64:**

```
$ msb exec httpspush-basic -- sh -c 'curl -sS -o /tmp/q1c-curl-out.txt -w "HTTP_CODE=%{http_code} SIZE=%{size_download}\n" \
    -u "x-access-token:$GH_TOKEN" "https://github.com/.../info/refs?service=git-upload-pack"'
HTTP_CODE=200 SIZE=366
```

```
$ msb exec httpspush-basic -- sh -c 'B64=$(printf "x-access-token:%s" "$GH_TOKEN" | base64 -w0); \
    curl -sS -o /tmp/q1d-curl-out.txt -w "HTTP_CODE=%{http_code} SIZE=%{size_download}\n" \
    -H "Authorization: Basic $B64" "https://github.com/.../info/refs?service=git-upload-pack"'
HTTP_CODE=200 SIZE=366
```

Both succeed with real data (366-byte git-upload-pack advertisement) — including the case where
the **guest itself** computed the base64 encoding and put it in a raw `Authorization: Basic ...`
header, not just the case where libcurl did it internally.

**The crux fact, nailed via the Q4a negative-control log line (see below):** msb's secret handler
logs an explicit `match_form` field. The egress-observability spike (2026-07-09) had only ever
observed `match_form=raw` (plain-text Bearer header). This spike's negative control produced:

```
match_form=basic_auth_decoded
```

**Conclusion: msb's TLS-intercept proxy decodes base64 `Authorization: Basic` credentials and
matches the placeholder against the decoded value — it is NOT a literal raw-byte string match
against the wire bytes.** The bead's stated worry ("raw-string match may miss base64-encoded Basic
auth") is **disconfirmed**: msb has a dedicated `basic_auth_decoded` match form distinct from
`raw`, and both are live-proven working. Two known match forms now confirmed: `raw` (plain header,
2026-07-07 spike) and `basic_auth_decoded` (this spike). `Bearer` scheme substitution itself is
proven to work generically (2026-07-07 spike); the one negative result in this spike (`Bearer` to
git-smart-HTTP) is a GitHub-side rejection of the scheme for classic PATs, not an msb miss.

---

## Q2 — the autonomy proof: clone + commit + push end-to-end, real token never in-guest

Using the working URL-embedded form (Q1a), from inside the cage:

```
$ msb exec httpspush-basic -- sh -c 'cd /tmp/q1a-url-clone && git config user.email spike@example.com \
    && git config user.name "msb spike" && echo "hello from inside an msb cage" > SPIKE.md \
    && git add SPIKE.md && git commit -m "spike: prove push from msb cage via secret-bound placeholder"'
[main (root-commit) a370914] spike: prove push from msb cage via secret-bound placeholder
 1 file changed, 1 insertion(+)
 create mode 100644 SPIKE.md
COMMIT_EXIT=0

$ msb exec httpspush-basic -- sh -c 'cd /tmp/q1a-url-clone && GIT_TERMINAL_PROMPT=0 git push origin main'
To https://github.com/jsnyde0/httpspush-msb-spike-scratch.git
 * [new branch]      main -> main
PUSH_EXIT=0
```

**Independent verification from the HOST (not the guest), via `gh api`:**

```
$ gh api repos/jsnyde0/httpspush-msb-spike-scratch/commits --jq '.[].commit.message'
spike: prove push from msb cage via secret-bound placeholder

$ gh api repos/jsnyde0/httpspush-msb-spike-scratch/contents/SPIKE.md --jq '.content' | base64 -d
hello from inside an msb cage
```

The commit and its content are real and independently confirmed on GitHub's servers.

**Placeholder re-verified post-push** — real token never touched the guest, not even on disk in
`.git/config`:

```
$ msb exec httpspush-basic -- sh -c 'echo GH_TOKEN=$GH_TOKEN; cat /tmp/q1a-url-clone/.git/config'
GH_TOKEN=$MSB_GH_TOKEN
...
[remote "origin"]
	url = https://x-access-token:$MSB_GH_TOKEN@github.com/jsnyde0/httpspush-msb-spike-scratch.git
...
```

The persisted git remote URL itself stores the **placeholder**, not the real token — the real
value never exists anywhere in guest memory or guest disk at any point.

**Q2 verdict: WORKS END-TO-END.** clone → commit → push, real token never present in-guest,
independently verified via the GitHub API from the host.

---

## Q3 — CA trust

```
$ msb exec httpspush-basic -- sh -c 'ls -la /.msb/tls/'
-rw-r--r-- 1 501 dialout 635 Jul  9 11:23 ca.pem

$ msb exec httpspush-basic -- sh -c 'curl -sS -o /dev/null -w "HTTP_CODE=%{http_code} SIZE=%{size_download}\n" https://github.com'
HTTP_CODE=200 SIZE=576663
```

No `GIT_SSL_NO_VERIFY`, no `curl -k`, no `--cacert` override — plain default trust. Confirmed the
guest's system trust store actually has the intercept CA installed and git/curl use it natively
(not accidentally passing due to some bypass):

```
$ msb exec httpspush-basic -- sh -c 'curl -v -sS -o /dev/null https://github.com 2>&1 | grep -i "issuer\|subject\|SSL certificate verify"'
*  subject: CN=github.com
*  subjectAltName: host "github.com" matched cert's "github.com"
*  issuer: CN=microsandbox CA; O=microsandbox
*  SSL certificate verify ok.
```

**Q3 verdict: WORKS out of the box, zero friction.** The `rip-cage:latest` image trusts the msb
TLS-intercept CA natively (Debian/Ubuntu base auto-loads `/.msb/tls/ca.pem` into the system trust
store at boot, per the CA-cert-found log line noted in the prior 2026-07-09 egress spike). No
migration work item here — nothing to fix.

---

## Q4 — negative controls

### Q4a — secret sent to an allowlisted-but-not-secret-bound host, must block + log

Recreated with a second allowlisted host `example.org`, secret still scoped only to `github.com`
(live rule mutation is not supported per the prior spike — recreate is required):

```
export GH_TOKEN="$(gh auth token)"
msb run -d --name httpspush-negctrl \
  --net-default deny \
  --net-rule "allow@github.com:tcp:443,allow@example.org:tcp:443" \
  --secret "GH_TOKEN@github.com" \
  --on-secret-violation block-and-log \
  rip-cage:latest -- sleep 600
```

```
$ msb exec httpspush-negctrl -- sh -c 'curl -sS -o /tmp/negctrl-basic.txt -w "HTTP_CODE=%{http_code}\n" \
    -u "x-access-token:$GH_TOKEN" https://example.org/'
curl: (56) OpenSSL SSL_read: OpenSSL/3.5.6: error:0A000126:SSL routines::unexpected eof while reading, errno 0
HTTP_CODE=000
```

Blocked. Host-side WARN log line (`msb logs httpspush-negctrl --source system --json`):

```
{"d":"WARN microsandbox_network::secrets::handler: secret violation: placeholder detected for
disallowed host action=block-and-log secret_env_var=GH_TOKEN placeholder=$MSB_GH_TOKEN
protocol=http/1.1 sni=example.org host=example.org method=GET path=/
location=authorization_basic match_form=basic_auth_decoded guest_dst=104.20.26.136:443
http2_stream_id=", "s":"system", "t":"2026-07-09T11:27:02.409Z"}
```

**This is the Q1 crux evidence: `match_form=basic_auth_decoded`.**

Control — plain non-secret request to the same allowlisted host succeeds normally (proves the
block above is the secret-scoping firing, not `example.org` being unreachable):

```
$ msb exec httpspush-negctrl -- sh -c 'curl -sS -o /dev/null -w "example.org no-token HTTP_CODE=%{http_code} SIZE=%{size_download}\n" https://example.org/'
example.org no-token HTTP_CODE=200 SIZE=559
```

### Q4b — push to a repo the token cannot write to → ordinary 403, not a hang

```
$ msb exec httpspush-basic -- sh -c 'cd /tmp && GIT_TERMINAL_PROMPT=0 timeout 30 git clone \
    "https://x-access-token:$GH_TOKEN@github.com/octocat/Hello-World.git" q4b-noaccess-v2 \
    && cd q4b-noaccess-v2 && echo "should not be able to push this" > NOACCESS.md \
    && git add NOACCESS.md \
    && git -c user.email=spike@example.com -c user.name="msb spike" commit -m "should be rejected" \
    && GIT_TERMINAL_PROMPT=0 timeout 30 git push origin master'
Cloning into 'q4b-noaccess-v2'...
[master 97623d0] should be rejected
 1 file changed, 1 insertion(+)
 create mode 100644 NOACCESS.md
remote: Permission to octocat/Hello-World.git denied to jsnyde0.
fatal: unable to access 'https://github.com/octocat/Hello-World.git/': The requested URL returned error: 403
PUSH_EXIT=128
```

**Q4 verdict: both negative controls behave correctly.** Cross-host secret misuse is
blocked-and-logged with rich, actionable detail (`host`, `sni`, `guest_dst`, `method`, `path`,
`match_form`, `location`). Ordinary auth-denied pushes surface a legible GitHub 403 message within
the 30s timeout — no hang.

---

## Q5 — `gh` CLI and multi-host secret binding syntax

`gh` talks to `api.github.com`, a different host from `github.com`. Established the exact syntax
for binding one secret's value to multiple hosts — **and found a real footgun**.

**Attempt 1 — repeat the `--secret` flag with the SAME env var name for two hosts:**

```
--secret "GH_TOKEN@github.com" --secret "GH_TOKEN@api.github.com"
```

Boots without error. But **both hosts then fail** — including `github.com`, which worked fine in
isolation:

```
$ msb exec httpspush-q5-repeat -- sh -c 'curl -sS -u "x-access-token:$GH_TOKEN" ".../github.com/..."'
curl: (56) ... unexpected eof ...
$ msb exec httpspush-q5-repeat -- sh -c 'curl -sS -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user'
curl: (56) ... unexpected eof ...
```

Host-side logs show BOTH as violations — `github.com` itself now logged as a "disallowed host" for
`GH_TOKEN`:

```
{"...":"secret violation: placeholder detected for disallowed host ... secret_env_var=GH_TOKEN ... sni=github.com ... match_form=basic_auth_decoded ..."}
{"...":"secret violation: placeholder detected for disallowed host ... secret_env_var=GH_TOKEN ... sni=api.github.com ... match_form=raw ..."}
```

**Finding: repeating `--secret` with the same ENV var name for two different hosts does not bind
"either" or "last wins" — it silently breaks BOTH bindings** (both hosts end up treated as
disallowed for that placeholder). No boot-time error/warning is surfaced — this is a real
migration footgun to document.

**Attempt 2 — comma-separated host list in a single `--secret` value:**

```
--secret "GH_TOKEN@github.com,api.github.com"
```

Also boots without error, also fails for **both** hosts (same violation-log pattern). Not valid
syntax either (no boot-time rejection to signal that — another footgun).

**Attempt 3 — distinct ENV var names per host, both sourced from the same real token (the working
form):**

```
export GH_TOKEN_GIT="$(gh auth token)"
export GH_TOKEN_API="$GH_TOKEN_GIT"
msb run -d --name httpspush-q5-distinct \
  --net-default deny \
  --net-rule "allow@github.com:tcp:443,allow@api.github.com:tcp:443" \
  --secret "GH_TOKEN_GIT@github.com" \
  --secret "GH_TOKEN_API@api.github.com" \
  --on-secret-violation block-and-log \
  rip-cage:latest -- sleep 600
```

```
$ msb exec httpspush-q5-distinct -- sh -c 'echo GIT=$GH_TOKEN_GIT API=$GH_TOKEN_API'
GIT=$MSB_GH_TOKEN_GIT API=$MSB_GH_TOKEN_API

$ msb exec httpspush-q5-distinct -- sh -c 'curl -sS -u "x-access-token:$GH_TOKEN_GIT" ".../github.com/..."'
github.com HTTP_CODE=200

$ msb exec httpspush-q5-distinct -- sh -c 'curl -sS -H "Authorization: Bearer $GH_TOKEN_API" https://api.github.com/user'
api.github.com HTTP_CODE=200
```

Real body confirmed for the `api.github.com` call (not a fake-accept):

```
{
  "login": "jsnyde0",
  "id": 10712160,
  ...
```

**Actual `gh` CLI, end-to-end, from inside the cage:**

```
$ msb exec httpspush-q5-distinct -- sh -c 'GH_TOKEN=$GH_TOKEN_API gh api user --jq ".login, .id"'
jsnyde0
10712160
```

**`gh pr create`, full workflow — branch, push, PR, all from inside the cage:**

```
$ msb exec httpspush-q5-distinct -- sh -c 'cd /tmp && GIT_TERMINAL_PROMPT=0 git clone \
    "https://x-access-token:$GH_TOKEN_GIT@github.com/jsnyde0/httpspush-msb-spike-scratch.git" q5-pr-clone \
    && cd q5-pr-clone && git config user.email spike@example.com && git config user.name "msb spike" \
    && git checkout -b spike-branch && echo "pr test from msb cage" > PR_TEST.md \
    && git add PR_TEST.md && git commit -m "spike: gh pr create test" \
    && GIT_TERMINAL_PROMPT=0 git push origin spike-branch'
...
To https://github.com/jsnyde0/httpspush-msb-spike-scratch.git
 * [new branch]      spike-branch -> spike-branch
PUSH_EXIT=0

$ msb exec httpspush-q5-distinct -- sh -c 'cd /tmp/q5-pr-clone && GH_TOKEN=$GH_TOKEN_API gh pr create \
    --title "spike: gh pr create from msb cage" --body "proves gh pr create works from inside msb cage with placeholder token" \
    --head spike-branch --base main'
https://github.com/jsnyde0/httpspush-msb-spike-scratch/pull/1
```

Independently verified from the HOST:

```
$ gh pr view 1 --repo jsnyde0/httpspush-msb-spike-scratch --json title,state,url
{"state":"OPEN","title":"spike: gh pr create from msb cage","url":"https://github.com/jsnyde0/httpspush-msb-spike-scratch/pull/1"}
```

**Q5 verdict: `gh api` and `gh pr create` both WORK end-to-end from inside the cage, real token
never in-guest.** The working multi-host binding pattern is **distinct ENV var names per host,
each `--secret` flag repeated once per (var, host) pair** — `--secret "VAR1@host1" --secret
"VAR2@host2"`, sourcing both host env vars from the same real credential. Same-var-name repetition
and comma-separated host lists inside one `--secret` value are BOTH silently broken (no boot-time
error, both hosts end up blocked) — **a migration footgun worth flagging upstream and documenting
in the rip-cage manifest generator** so it never emits either broken form.

---

## VERDICT

**WORKS-END-TO-END.**

The exact working config/remote-URL form:

```
export GH_TOKEN="$(gh auth token)"
msb run -d --name <cage> \
  --net-default deny \
  --net-rule "allow@github.com:tcp:443[,allow@api.github.com:tcp:443]" \
  --secret "GH_TOKEN@github.com" \
  [--secret "GH_TOKEN_API@api.github.com"   # separate ENV var name if gh CLI is also needed]
  --on-secret-violation block-and-log \
  rip-cage:latest -- <cmd>
```

Git remote form that works (both git's native handling and manual curl equivalents proven):

```
https://x-access-token:$GH_TOKEN@github.com/<owner>/<repo>.git
```

- **Q1** — both the URL-embedded Basic-auth form and manually-constructed `Authorization: Basic`
  headers substitute correctly; msb decodes base64 credentials (`match_form=basic_auth_decoded`),
  it does not do literal raw-byte matching only. The bead's stated encoding-miss risk is
  disconfirmed. `Bearer` scheme fails against GitHub's git-smart-HTTP specifically because GitHub
  rejects that scheme for classic PATs (confirmed with the real token on the host, independent of
  msb) — not an msb gap.
- **Q2** — clone → commit → push proven end-to-end, independently verified via `gh api` from the
  host; real token never enters the guest at any point, including on disk in `.git/config`
  (persists the placeholder).
- **Q3** — CA trust works with zero friction; `rip-cage:latest` trusts `/.msb/tls/ca.pem` natively,
  confirmed via TLS handshake issuer inspection (`CN=microsandbox CA`). No migration work item.
- **Q4** — negative controls behave correctly: cross-host secret misuse is blocked-and-logged with
  rich detail; auth-denied pushes surface a legible 403, not a hang.
- **Q5** — `gh api` and `gh pr create` both work end-to-end. Multi-host binding for one credential
  requires **distinct ENV var names per host** (`--secret VAR1@host1 --secret VAR2@host2`).
  Same-var-name repetition and comma-separated hosts in one `--secret` are both silently broken —
  a real footgun with no boot-time error, worth flagging upstream and guarding against in any
  rip-cage manifest→msb-flags generator.

**This candidate dissolves the git-push blocker.** It is strictly stronger than the ssh-agent
socket path (which the r6bo spike already disproved on msb): push autonomy, credential
non-possession (real token never touches guest memory or disk), and destination scoping (secret
misuse to any other host is blocked-and-logged), all enforced host-side outside the guest kernel.

---

## Migration work items surfaced

1. **`--secret` inline-value syntax changed/is stricter than the bead's draft command assumed** —
   requires `export VAR=value` on the host first, then `--secret "VAR@HOST"` (no `=VALUE` in the
   flag itself). Any manifest-generator code must emit two steps (host env export + bare
   `VAR@HOST` flag), not one.
2. **Multi-host secret binding footgun** — same-ENV-var-name repetition and comma-separated host
   lists in one `--secret` value are both silently broken (blocks BOTH hosts, no boot-time error).
   The only correct pattern is one distinct ENV var name per host. A manifest generator that maps
   a rip-cage MEDIATOR entry needing multiple hosts (e.g. a GitHub credential used for both git-http
   and the API) must emit N `--secret` flags with N distinct synthesized env var names, not attempt
   either broken shorthand.
3. **CA trust has zero friction on `rip-cage:latest`** — no work item, confirmed clean.

## Cleanup

- Stopped and removed all 5 `httpspush-`-prefixed sandboxes (`httpspush-basic`,
  `httpspush-negctrl`, `httpspush-q5-repeat`, `httpspush-q5-comma`, `httpspush-q5-distinct`) —
  confirmed via `msb list` showing zero remaining `httpspush-` entries.
- **Scratch repo `jsnyde0/httpspush-msb-spike-scratch` deletion is INCOMPLETE — flagged, not
  silently skipped.** `gh repo delete` requires the `delete_repo` OAuth scope, which the active
  `jsnyde0` token does not have (`repo` scope only). `gh auth refresh -s delete_repo` requires an
  interactive browser device-flow approval (`https://github.com/login/device`, one-time code) that
  this agent cannot complete headlessly. **Operator action needed:** either run
  `gh auth refresh -h github.com -s delete_repo` (approve the device code in a browser) then
  `gh repo delete jsnyde0/httpspush-msb-spike-scratch --yes`, or delete the repo manually via the
  GitHub web UI (Settings → Danger Zone). The repo is private, contains only spike test commits/a
  test PR, and no secrets.
- Grepped this findings doc and all host-side temp files (`/tmp/msb_boot_*.sh`,
  `/tmp/gh_auth_refresh_out.txt`) for `gho_`/token-shaped strings — none found; only placeholder
  forms (`$MSB_GH_TOKEN`, `$MSB_GH_TOKEN_GIT`, `$MSB_GH_TOKEN_API`) and prose references without
  the literal prefix appear anywhere. (The per-probe `curl` output files referenced inline in this
  doc were written inside the guest sandboxes' own `/tmp`, not on the host — they no longer exist
  now that the sandboxes are removed.)
