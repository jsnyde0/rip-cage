# Recipe: the caged agent cannot authenticate

Claude Code in the cage reports an auth failure, or `rc up` warned about an
expired token. Three different things get called "auth" here, and the fix
depends on which one it is.

---

## 1. Tell the three apart

```bash
rc doctor <cage>
```

Read its auth probe line, then check which mechanism this cage uses:

| This cage has | What that means | Section |
|---|---|---|
| a `secrets:` entry in its config | msb injects the token on the wire; the guest holds only `$MSB_<NAME>` | 2 |
| a mounted `~/.claude/.credentials.json` | the cage reads the host's OAuth credentials directly | 3 |
| `ANTHROPIC_API_KEY` in its environment | a plain API key | 4 |

Check from inside:

```bash
msb exec <cage> -- sh -c 'test -f /home/agent/.claude/.credentials.json && echo creds-mounted || echo no-creds'
msb exec <cage> -- sh -c 'echo "${CLAUDE_CODE_OAUTH_TOKEN:-unset}"'
```

A value of literally `$MSB_CCTOK` (or similar) is **correct** for a
secrets-bound cage — that is the placeholder, and the real value is substituted
on the wire. It is not a broken variable.

---

## 2. Secrets-bound cage

The token never enters the cage, so nothing inside it can be wrong. What can be
wrong is host-side.

```bash
ls -l ~/.config/rip-cage/secrets/           # the value rc bridges from
```

- **Missing file, and the variable is not exported** → msb fails the boot
  naming the variable. Write the value to
  `~/.config/rip-cage/secrets/<NAME>`, mode 600.
- **Stale value** → replace the file's contents, then `rc up --replace
  <project>`.
- **Requests reach the API but are rejected** → the value is wrong, or bound to
  hosts that do not include the one being called. Check the entry's `allow:`
  list in the config.

*Done when:* an actual request from inside the cage succeeds — not that the
file exists.

---

## 3. Mounted host credentials (the common Claude Code case)

```bash
rc auth refresh
```

On **macOS** this re-extracts the OAuth credentials from the keychain. Running
cages pick the new value up on their next API call — no recreate needed, the
file is a bind mount.

If it fails: the host is not logged in. Run `claude auth login` on the HOST
first, then `rc auth refresh` again.

On **Linux** there is no keychain and `rc auth refresh` is a no-op that says
so. Update `~/.claude/.credentials.json` on the host directly; the mount carries
it straight through.

`rc up` warns at launch when the token is already expired, or expires within
ten minutes. That warning is harmless if this cage does not run Claude Code.

*Done when:* `rc doctor <cage>` reports the auth probe OK, and a real request
from the cage succeeds.

---

## 4. API key

```bash
msb exec <cage> -- sh -c 'echo "${ANTHROPIC_API_KEY:0:7}..."'
```

Empty means it never reached the cage: it comes in through the config's `env:`
block or `--env-file`, not from your host shell. Fix that and recreate.

---

## 5. Onboarding screens instead of an auth error

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

## 6. Two accounts, wrong one

The macOS keychain holds one logged-in Claude identity at a time, so
`rc auth refresh` refreshes whichever you are currently logged in as — it
cannot serve two cages under two accounts.

For genuinely parallel accounts, give each cage its own `secrets:` name and its
own host-side value file. That is the **cage-config** skill,
`recipes/multi-account.md`.

---

## What is not an auth problem

- **`$MSB_<NAME>` as the variable's value** — correct for a secrets-bound cage.
- **`.credentials.json` absent inside a secrets-bound cage** — correct. The
  posture is that the cage never holds the token.
- **A request failing with connection refused rather than 401** — that is
  egress, not auth. `api.anthropic.com` must be on the allowlist. See
  [`denied-host.md`](denied-host.md).

That last one is worth checking first when the symptom is "cannot reach the
API": a blocked host and a bad token look similar from inside the agent, and
they have completely different fixes.
