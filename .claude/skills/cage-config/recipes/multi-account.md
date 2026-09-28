# Recipe: two cages, two accounts, one host

Use this when one machine runs cages under different identities — a work
account and a personal one, two git forges, two API keys — and neither cage
should be able to reach the other's credential.

The separation is per-cage, and it lives in three places: the config file name,
the `secrets:` binding, and the mount set. Get all three right and the cages
cannot see each other's tokens even though they share a host.

---

## 1. One config file per cage, named after the cage

Config paths derive from the project path, so two projects already get two
files:

```
~/.config/rip-cage/projects/work-service.yaml
~/.config/rip-cage/projects/personal-sideproject.yaml
```

Same project, two identities? Give each a **distinct project path** — two
checkouts, or a worktree — so the derived names differ. Do not try to serve two
identities from one config; there is no per-identity switch in the file, by
design.

*Done when:* `container_name` on each project path prints a different name, and
each name has its own file.

---

## 2. One secret name per account, bound to its own hosts

Each cage's config declares a `secrets:` entry whose NAME is unique to that
account, and whose `allow:` list names only the hosts that account talks to:

```yaml
secrets:
  CCTOK_WORK:
    allow:
      - "api.anthropic.com"

env:
  CLAUDE_CODE_OAUTH_TOKEN: "$MSB_CCTOK_WORK"
```

and in the other cage, `CCTOK_PERSONAL` bound the same way (`env:
CLAUDE_CODE_OAUTH_TOKEN: "$MSB_CCTOK_PERSONAL"`). Both leave `value:` out. The
`env:` line is not optional — without it the secret is injected on the wire
but never lands in `CLAUDE_CODE_OAUTH_TOKEN` for Claude Code to read.

Host-side, one file per name:

```
~/.config/rip-cage/secrets/CCTOK_WORK
~/.config/rip-cage/secrets/CCTOK_PERSONAL
```

`rc` reads the one its config names and bridges only that one. The guest sees
`$MSB_CCTOK_WORK` — a placeholder — and nothing about the other account exists
in its environment, on its disk, or in `/proc`.

**`rc auth` and the `rc up` pre-check only ever check the literal secret name
`CCTOK`** — a renamed secret like `CCTOK_WORK` gets neither the host-side
shape check nor the before-any-msb-call refusal; a bad or missing token
under a renamed secret is caught later, by msb's own native validation at
create time instead.

*Done when:* each config names exactly one secret, each secret file exists
host-side mode 600, and neither config mentions the other's name.

---

## 3. Mount only the identity that cage should have

This is where the leak usually is, because the credential-shaped files are in
`$HOME` and it is easy to hand over the whole directory.

- **Never mount `$HOME`, or a directory containing both accounts' credentials.**
  `rc up`'s protected-paths floor refuses the well-known credential stores
  outright, but it cannot know that `~/work-secrets/` belongs to the other
  identity.
- **Git:** authenticate over HTTPS with the per-cage token msb injects. Do not
  mount an ssh agent socket or a key directory into either cage.
- **The host Claude config** (`~/.claude.json`) is a single file shared by both
  accounts. Mount it read-only, as the template does — read-only is what stops
  one cage from editing the `mcpServers` and `hooks` that the HOST Claude later
  executes.
- **Project-specific secrets:** cover them with an empty read-only file mount.
  See the template's secret-covers block.

*Done when:* for every mount line in each config you can say which identity it
belongs to, and no line belongs to both.

---

## 4. Rotating one account's token

Get a fresh long-lived token for that account (`claude setup-token`, logged in
as it), overwrite `~/.config/rip-cage/secrets/<NAME>`, `chmod 600`, and
recreate that cage (`rc up --replace <project>`). Only the cage whose config
names that secret is affected; the other keeps running.

Each account's token is independent — there is no shared keychain state to
distinguish, and nothing to refresh. Keep the values in the per-name secret
files above.

*Done when:* the rotated cage reaches its API with the new value and the other
cage is still up and unaffected (`msb list` shows both).

---

## What this does not protect against

Both cages run on the same host, under the same user, with the same `rc`. This
recipe stops one cage from **reading** the other's credential. It does not make
them two machines. A human with host access sees both; so does anything running
on the host outside a cage.
