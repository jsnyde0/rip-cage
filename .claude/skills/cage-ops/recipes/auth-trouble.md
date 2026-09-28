# Recipe: the caged agent cannot authenticate

Claude Code in the cage reports an auth failure, or `rc up` refused to launch
naming auth. Two mechanisms get called "auth" here, and the fix depends on
which one this cage uses.

---

## 1. Tell them apart

```bash
rc doctor <cage>
```

Read its auth probe line, then check which mechanism this cage uses:

| This cage has | What that means | Section |
|---|---|---|
| the shipped `CCTOK` secret (or any `secrets:` entry) | msb injects the token on the wire; the guest holds only `$MSB_<NAME>` | 2 |
| `ANTHROPIC_API_KEY` in its environment | a plain API key, real value in-cage | 3 |

Check from inside:

```bash
msb exec <cage> -- sh -c 'echo "${CLAUDE_CODE_OAUTH_TOKEN:-unset}"'
```

A value of literally `$MSB_CCTOK` is **correct** — that is the placeholder,
and the real value is substituted on the wire. Claude's login never mounts a
credentials file into the cage.

---

## 2. The `CCTOK` secret (the Claude Code case)

The token never enters the cage, so nothing inside it can be wrong. What can
be wrong is host-side.

```bash
rc auth
```

This is the same no-prompt check `rc up` runs before booting a cage whose
config declares `CCTOK`.

- **`rc auth` fails, naming the file** → it is missing, not 0600, or not
  setup-token-shaped. Run `claude setup-token`, save the printed value to
  `~/.config/rip-cage/secrets/CCTOK`, `chmod 600`.
- **`rc auth` passes but requests are rejected** → the value is stale or
  belongs to a different account. Get a fresh `claude setup-token`, overwrite
  the file, then `rc up --replace <project>` — a running cage does not pick up
  a changed file on its own.
- **Requests reach the API but are rejected for a reason unrelated to the
  token shape** → check the secret's `allow:` list in the config actually
  names `api.anthropic.com`.

*Done when:* an actual request from inside the cage succeeds — not that the
file exists. Full mechanism: [`auth.md`](../../../../docs/reference/auth.md).

---

## 3. API key

```bash
msb exec <cage> -- sh -c 'echo "${ANTHROPIC_API_KEY:0:7}..."'
```

Empty means it never reached the cage: it comes in through the config's `env:`
block or `--env-file`, not from your host shell. Fix that and recreate. This
path is possession — the real key is in the guest — by design; it is the
alternative to the Claude login, not a bug.

---

## 4. Onboarding screens instead of an auth error

Interactive `claude` in the cage asks for a theme or shows a login wall, rather
than failing with an auth message.

That is a **seed** problem, not a credential problem. At boot, init snapshots
the mounted host Claude config to a seed file under `~/.claude`; when no host
config is mounted, it synthesizes a minimal seed carrying
`hasCompletedOnboarding: true` so those screens are skipped.

```bash
msb exec <cage> -- sh -c 'ls -l /home/agent/.claude/.claude.json.seed'
```

- **Missing** → init did not run, or ran before the mount existed. Check the
  `rc up` output for the init sentinel; `rc up --replace <project>` to re-run
  it.
- **Present, screens still appear** → the agent is using a different config
  directory than the seed. Check `CLAUDE_CONFIG_DIR`.

---

## 5. Two accounts, wrong one

A cage's config names exactly one secret (`CCTOK` by default), so switching
which account is active means overwriting that name's host-side file and
recreating — see [`auth.md`](../../../../docs/reference/auth.md#switching-accounts)
and the [multi-account rotation guide](../../../../docs/guides/multi-account-rotation.md).

For genuinely parallel accounts running at the same time, give each cage its
own secret name and its own host-side value file. That is the **cage-config**
skill, `recipes/multi-account.md`.

---

## What is not an auth problem

- **`$MSB_CCTOK` as the variable's value** — correct, the placeholder.
- **No Claude credentials file in the guest** — correct. Claude's login
  never mounts one under either mechanism above.
- **A request failing with connection refused rather than 401** — that is
  egress, not auth. `api.anthropic.com` must be on the allowlist. See
  [`denied-host.md`](denied-host.md).

That last one is worth checking first when the symptom is "cannot reach the
API": a blocked host and a bad token look similar from inside the agent, and
they have completely different fixes.
