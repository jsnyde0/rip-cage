# Recipe: `rc up` will not start the cage

`rc up` refuses or fails. Several layers can say no, and each says no in its own
words. Read the message before changing anything — the fix is almost always
named in it.

---

## 1. Find out which layer refused

```bash
rc up --dry-run <project>
```

`--dry-run` assembles the whole launch without touching msb or the keychain.

- **`--dry-run` also refuses** → the refusal is host-side: config resolution,
  a protected path, a multiplexer check, a network-policy check. Go to the
  table below.
- **`--dry-run` succeeds, the real run fails** → the failure is at BOOT: a
  mount source, an image, a secret. Go to section 3.

---

## 2. Host-side refusals, before any msb call

| Message names | Cause | Fix |
|---|---|---|
| `CAGE_CONFIG_MISSING` | no config at the path `rc` resolves | write one — **cage-config**, `recipes/first-cage.md`. The filename must match the derived cage name, or pass `--conf <path>` |
| a protected path | a mount hands over a credential store | remove that mount. `share/rip-cage/protected-paths` lists the names and its header explains what each line does |
| a multiplexer | `RC_MULTIPLEXER` names one the image's descriptor does not declare | unset it, or rebuild the image with that recipe's boot fragment — **cage-image** |
| `network.policy` | the config sets a policy other than `none` | `policy: none` is the floor, not a setting. Set it back |
| the config resolves inside a mount | the config file sits in a tree the same config mounts | move it to `~/.config/rip-cage/projects/` |

The cage-name derivation, if the filename is the suspect:

```bash
bash -c "source \"\$(command -v rc)\"; container_name \"\$(cd <project> && pwd -P)\""
```

---

## 3. Boot-time failures, after msb is handed the config

| Message | Cause | Fix |
|---|---|---|
| `mount ...: Not a directory (os error 20)` | a **symlink** in a bind source | msb does not follow host-side symlinks. On macOS `/tmp` and `/var` are symlinks — rewrite that path with `cd <p> && pwd -P` |
| a mount source that does not exist | a declared path is absent on this host | delete the line, or create the path |
| image not found | the `image:` tag was never built, or names another tag | `rc build`, or fix the line — **cage-image** |
| a named secret variable | a `secrets:` entry with no host-side value | put the value in `~/.config/rip-cage/secrets/<NAME>`, or export it before `rc up` |
| `agent relay socket path is too long` | `$HOME` is a deep temporary path | msb derives a unix socket path from `$HOME` and hits the 104-byte limit. Use a real `$HOME`, or point `MSB_HOME` at the normal one |

---

## 4. The cage exists but comes back wrong

**It resumed, but everything inside is gone.** Expected, partly: every resume is
a fresh kernel boot, so processes die on stop. `rc` re-runs init each time. What
should NOT be gone is the workspace, the Claude session, or the named volumes —
if those are missing, check the config's `mounts:` block against
`share/rip-cage/cage.yaml.template`.

**It booted as a root shell with the mounts missing.** The image's Dockerfile
ends on `USER root`. Fix the Dockerfile to end on `USER agent`, rebuild, and
`rc up --replace` — **cage-image**.

**A tool you added is not there.** The cage still runs the old image. `rc up
--replace <project>`. If it is still missing, check for the msb-cache drift
warning and resync with `docker save <tag> | msb load --tag <tag>`.

**A daemon you declared is not running.** Init runs each declared daemon's
`health` at boot and warns rather than failing, so the verdict is in the `rc up`
output — grep it for `[rip-cage] daemon`. "Dead but the process exists" is a
`start` that records a wrapper's pid; "alive but not serving" is a `health`
that checks a pid against a zombie. Both in **cage-image**,
`references/boot-descriptor.md`.

---

## 5. When you want to start over

```bash
rc destroy <cage>
rc up <project>
```

`rc destroy` removes the cage **and its named volumes** — the cage-local agent
state and shell history go with it. The workspace and the host-mounted Claude
session do not.

**Pass the name.** `rc destroy` with no name, or a name it cannot resolve,
refuses with exit 2 and lists the cages it did not touch. It will not pick one
for you — an empty name from a failed lookup is how a daily cage got deleted
once.

*Done when:* `rc up <project>` reaches the shell and `msb exec <cage> -- ls
/workspace` lists your files.

---

## Always report the actual message

When you hand this back, quote the refusal or the boot error verbatim. Each
layer names its own cause, and a paraphrase usually loses the one word that
identified which layer spoke.
