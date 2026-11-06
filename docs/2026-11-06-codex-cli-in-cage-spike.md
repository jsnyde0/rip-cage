# Spike: the Codex CLI in a cage on the ChatGPT subscription, placeholder-only (rip-cage-bygi.1)

**Question.** Can the `codex` CLI run inside a rip-cage cage on the host's
ChatGPT/Codex subscription while the guest holds only a placeholder token?
Answers the five "Not yet specified" questions on `rip-cage-bygi`.

**Verdict: GO for the `examples/codex` recipe.** `codex exec` completed a model
reply (`pong`) in a cage whose egress was `chatgpt.com:tcp:443` only, with the
real access token held by msb and absent from every guest surface scanned.

**Environment (pinned).** Host mini-pc, Linux 7.2.15 (Omarchy), msb 0.7.8,
codex-cli 0.167.0 (host: mise; guest: `npm install -g @openai/codex@0.167.0`
on top of `rip-cage:latest`). Run 2026-11-06 ~14:50–15:05 UTC. Scratch cage
`bygi1-probe-proj`, project dir `/tmp/bygi1-probe/proj`, both destroyed after.

**Redaction.** No token value appears here. Tokens are described by field
name, length, JWT claim name, or a 16-hex sha256 prefix compared host-side.

---

## Answers

| # | Question | Answer (observed) |
|---|----------|-------------------|
| 1 | Does codex accept a placeholder `auth.json` and run without refreshing? Which fields does it decode? | **Yes.** The fake JWT pi uses (alg none, payload = `iss`, `exp` 2100-01-01, `https://api.openai.com/auth.chatgpt_account_id`) works as both `tokens.access_token` and `tokens.id_token`. **Required:** `tokens.id_token`, `tokens.access_token`, `tokens.refresh_token` (any string), top-level `last_refresh` (any timestamp, age irrelevant). **Optional:** `tokens.account_id`, `auth_mode`. No refresh happens while chatgpt.com answers 200. **On a 401 codex does try to refresh** (`refresh_reason: unauthorized_recovery`, POST `https://auth.openai.com/oauth/token`); in the cage that fails at DNS and codex exits 1. |
| 2 | Which hosts on the subscription path? | Model call: **`chatgpt.com`** only (websocket `/backend-api/codex/responses`, plus `/backend-api/codex/models`, `/backend-api/wham/...`). By default codex also calls **`ab.chatgpt.com`** (telemetry) and **`*.oaiusercontent.com`** (remote plugin bundle downloads). Both were denied and the reply still completed. Four flags silence them (Q5). `auth.openai.com` is called only to refresh; `api.openai.com` only when `auth.json` fails to load as ChatGPT auth. |
| 3 | Does any request body echo the placeholder (#1354 drop rule)? | **Not in normal operation.** In the host stub run, no request body carried the access token (0 of all logged bodies). It rides only the `authorization: Bearer` header plus a `chatgpt-account-id` header. **Forced echo:** codex `jq`-read the placeholder in the cage, so it landed in the next model request body. The session **survived** and msb logged no violation. The model saw the **placeholder unchanged** (`YES 230`: it ends `rc-placeholder` and is 230 chars, while the real token is 1797). That matches msb ≥0.7.5 (#1700): body substitution is off by default, and a placeholder passes unchanged toward its own allowed host. Observed over codex's websocket transport. |
| 4 | Can pi's `CODEX` secret and a codex-CLI secret share one helper / one token? | **Yes, one token and one placeholder serve both.** pi's and codex's host logins are separate OAuth sessions (different access and refresh tokens) on the same `client_id` and the same `chatgpt_account_id`. **pi's access token, injected under the pi-helper placeholder, drove `codex exec` to `pong`.** The two guests need differently shaped `auth.json` files: pi's `{"openai-codex":{...}}` vs codex's `{"tokens":{...},"last_refresh":...}`. Both carry the same placeholder string. |
| 5 | What the desk passes in — flag names | See "Flags" below. `--dangerously-bypass-approvals-and-sandbox` is the codex flag for "externally sandboxed". `CODEX_HOME` must be a guest-writable directory holding the placeholder `auth.json`. |

### Config lines that worked (the scratch config, verbatim except the placeholder)

```yaml
image: rip-cage:bygi1-codex
cpus: 2
memory: 2G
workdir: /workspace
labels:
  rc.managed: "true"
mounts:
  - "/tmp/bygi1-probe/proj:/workspace"
  - "/tmp/bygi1-probe/guest:/home/agent/rc-codex-placeholder:ro"
secrets:
  CODEXCLI:
    allow:
      - "chatgpt.com"
    placeholder: "<the line examples/pi-providers/codex-secret.sh --print-placeholder prints>"
network:
  policy: none
  allow:
    - "chatgpt.com:tcp:443"
```

- **network.allow:** `"chatgpt.com:tcp:443"` and nothing else, given the Q5 flags.
- **Secret host binding:** `allow: ["chatgpt.com"]`. Header substitution is the default. No `substitution:` or `passthrough:` key was needed.
- **Secret value:** the host login's `tokens.access_token` (1797 bytes) or pi's `openai-codex.access` (1758 bytes). Either worked, written 0600 at `$XDG_CONFIG_HOME/rip-cage/secrets/<NAME>`.

### Flags (Q5) — what the Switch desk passes to run codex non-interactively

```bash
CODEX_HOME=<guest-writable dir containing the placeholder auth.json> \
codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  --disable plugins --disable remote_plugin --disable apps \
  -c analytics.enabled=false \
  [--skip-git-repo-check] [--ephemeral] [-o <last-message-file>] [--json] \
  "<prompt>" </dev/null
```

- `--dangerously-bypass-approvals-and-sandbox`: no approvals, no codex sandbox. Help text: "Intended solely for running in environments that are externally sandboxed". The banner then reads `approval: never` / `sandbox: danger-full-access`.
- `--disable plugins --disable remote_plugin --disable apps -c analytics.enabled=false`: with all four, codex opened connections **only to chatgpt.com** (0 denials, 0 WARN/ERROR lines). Without them it hits `ab.chatgpt.com` and `*.oaiusercontent.com`. Those calls are denied, cost nothing functional, and fill the denial log.
- `</dev/null`: when stdin is not a TTY, codex prints `Reading additional input from stdin...` and reads stdin. Close it, or pass the prompt as `-` on stdin.
- `--skip-git-repo-check` is needed only when the working dir is not a git repo. `--ephemeral` skips session files. Drop it if the desk wants `codex exec resume`, which needs a persistent `CODEX_HOME`.

### Residuals observed (not fixed here)

- **Mount-parent ownership.** Mounting the placeholder file at `/home/agent/.codex/auth.json:ro` made `/home/agent/.codex` root-owned. codex failed with `Error: failed to initialize in-process app-server client: Permission denied (os error 13)`, and `msb exec` has no passwordless sudo. Fix used: mount the placeholder directory at a neutral path and copy `auth.json` into a writable `CODEX_HOME`.
- **401 → refresh storm.** When the token is not substituted (real token expired, or a wrong placeholder), codex makes 16 connection attempts to `auth.openai.com` per run (64 msb DNS denials) and exits 1 with `workspace routing discovery unauthorized (401)`. The fix is the pi loop: re-run the helper, then `rc up`. The access token lives about 10 days (host token: `exp - iat` = 864000 s).
- **Response reflection** (see the memory `test-response-reflection-not-just-request-side-substitution`) was not tested with an echo endpoint. The real token rides only the Authorization header toward chatgpt.com. The model never saw it: in the forced-echo probe, body substitution was off.
- **Host tooling.** The session's secret-read hook blocks any command text containing `~/.codex/auth.json`, even a guest path holding a placeholder. That is another reason to mount the placeholder at a neutral path.
- **Stub run side effect.** The host stub run (fake CODEX_HOME) sent **placeholder** tokens to the real `chatgpt.com/backend-api/codex/models`. That endpoint ignores `chatgpt_base_url`. The reply was `401 invalid_issuer`. No real credential was involved.

---

## Probe log (verbatim, redacted)

### P0 — host login shape (names, lengths, claim names only)

```
auth_mode: str len=7            # value: chatgpt
OPENAI_API_KEY: NoneType None
tokens: {
  id_token: str len=1896 JWT
     claim https://api.openai.com/auth: keys=['chatgpt_account_id', 'chatgpt_plan_type', 'chatgpt_subscription_active_start', 'chatgpt_subscription_active_until', 'chatgpt_subscription_last_checked', 'chatgpt_user_id', 'groups', 'organizations', 'user_id']
     claim exp: 1793789295 (past)
  access_token: str len=1797 JWT
     claim client_id: str
     claim https://api.openai.com/auth: keys=['amr', 'chatgpt_account_id', 'chatgpt_account_user_id', 'chatgpt_compute_residency', 'chatgpt_plan_type', 'chatgpt_user_id', 'poid', 'user_id']
     claim iat: 1793785695 (past)
     claim exp: 1794649695 (future)
  refresh_token: str len=196
  account_id: str len=36
}
last_refresh: str len=30
```

Endpoints compiled into the binary (`strings`, abridged): `https://chatgpt.com/backend-api/codex`,
`https://auth.openai.com/oauth/token`, `https://ab.chatgpt.com/otlp/v1/metrics`,
`https://api.openai.com/v1/responses`. Env knobs: `CODEX_HOME`, `CODEX_REFRESH_TOKEN_URL_OVERRIDE`, `CODEX_ACCESS_TOKEN`.

### P1 — host, fake CODEX_HOME, local logging stub answering 401

`CODEX_REFRESH_TOKEN_URL_OVERRIDE=http://127.0.0.1:18999/oauth/token`, `-c chatgpt_base_url=http://127.0.0.1:18999/backend-api/`.

```
=== POST /oauth/token
  BODY b'{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann","grant_type":"refresh_token","refresh_reason":"unauthorized_recovery","refresh_token":"rc-placeholder-no-refresh"}'
...
ERROR: Your access token could not be refreshed. Please log out and sign in again.
body lines containing access-token payload segment: 0
header lines: 22
```

### P2 — host stub, `last_refresh` 2020, stub answering 404

No `POST /oauth/token` in the request log. Run ended on `ERROR: workspace routing discovery failed`. The stub cannot fake ChatGPT routing, so the real model call moved to the cage.

### P3 — cage, placeholder auth, default flags

```
codex_exit=0
LAST: pong
## connections opened
      1 starting new connection: https://ab.chatgpt.com/
     12 starting new connection: https://chatgpt.com/
      1 starting new connection: https://sdmntprcentralus.oaiusercontent.com/
      3 starting new connection: https://sdmntprsouthcentralus.oaiusercontent.com/
## refresh mentions
0
## 401 mentions
0
## msb denials
      4 denied by network policy domain=ab.chatgpt.com
      4 denied by network policy domain=sdmntprcentralus.oaiusercontent.com
     12 denied by network policy domain=sdmntprsouthcentralus.oaiusercontent.com
```

Transport line: `model_client.websocket_connection{provider=OpenAI wire_api=responses transport="responses_websocket" api.path="/responses"}`.

### P4 — guest possession (scan as guest root)

All 67 `/proc/*/environ` plus `grep -r` for JWT-shaped strings in `/home /tmp /etc /workspace /root /var /opt /usr/local`. Each hit's sha256 prefix was compared on the host against the real token's.

```
guest JWT-shaped strings (root scan): 2      # the placeholder + nothing real
real token hash present: 0
procs scanned: 67
MSB_ names in any proc environ: 0
permission denied: 0
```

### P5 — placeholder forced into a request body (Q3)

The prompt had codex run `jq -r .tokens.access_token <placeholder auth.json>`, then report YES/NO for "ends with rc-placeholder" and the length.

```
codex_exit=0
LAST: YES 230
## msb secret/violation log lines
(none)
```

### P6 — the four quieting flags

```
codex_exit=0
LAST: pong
## connections opened
      3 starting new connection: https://chatgpt.com/
## warnings/errors
new denials: 0
```

### P7 — forced 401 (access token = not the bound placeholder)

```
codex_exit=1
## connections opened
     16 starting new connection: https://auth.openai.com/
     36 starting new connection: https://chatgpt.com/
      1 ... codex_login::auth::manager: Refreshing token      (x7)
auth.json rewritten: no
ERROR: workspace routing discovery unauthorized (401)
## new msb denials
     64 denied by network policy domain=auth.openai.com
```

### P8 — pi's token under the pi placeholder (Q4)

The secret file was swapped to pi's `openai-codex.access` (1758 bytes), then `rc up --replace`:

```
codex_exit=0
LAST: pong
## connections opened
      4 starting new connection: https://chatgpt.com/
```

### P9 — auth.json field variants (Q1)

```
idtoken_eq_access: exit=0 reply='pong'
no_idtoken:        exit=124  hosts=[15 https://api.openai.com/]
no_account_id:     exit=0 reply='pong'
no_last_refresh:   exit=1    hosts=[16 https://auth.openai.com/, 36 https://chatgpt.com/] login=[Refreshing token]
no_refresh_token:  exit=124  hosts=[15 https://api.openai.com/]
no_auth_mode:      exit=0 reply='pong'
minimal (no account_id, no last_refresh): exit=1 'Skipping auth reload because no account id is available' / 'Your access token could not be refreshed because you have since logged out or signed in to another account.'
lr_2020:       exit=0 reply='pong' refreshing=0
lr_9d_ago:     exit=0 reply='pong' refreshing=0
lr_7d_ago:     exit=0 reply='pong' refreshing=0
lr_far_future: exit=0 reply='pong' refreshing=0
```

### P10 — host login after the spike (acceptance)

```
$ codex exec --skip-git-repo-check --ephemeral -o host-last.txt "Reply with exactly the word: pong" </dev/null
exit=0
reply: pong
```

### Teardown

`rc destroy bygi1-probe-proj` printed `Container bygi1-probe-proj and volumes destroyed.` The scratch secret file and the scratch config were deleted, and the image `rip-cage:bygi1-codex` was removed from msb and docker. Checks after: 0 cages named bygi1, 0 real-token copies under `/tmp/bygi1-probe`. The human's `secrets/` dir still holds exactly `CCTOK CODEX OPENROUTER`, untouched. Probe scripts were throwaway and are not committed.
