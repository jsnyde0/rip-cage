# workbench recipe

A cage that works across many repos mounts none of them. Repos are cloned onto a disk the agent owns, and commits and pushes are the bridge back to the forge.

Not floor, never on by default. Nothing in `rc` names it: every step is a config line or one shell command ([ADR-031](../../docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D3, [ADR-005](../../docs/decisions/ADR-005-ecosystem-tools.md) D12). This is [ADR-002](../../docs/decisions/ADR-002-rip-cage-containers.md) D6's "clone mode", realised as composition.

The lines to merge are in [`cage.yaml.fragment`](cage.yaml.fragment); each block says which top-level key of your project config it joins. Placeholders: `<ABSOLUTE_PATH_TO_YOUR_FOLDER>`, `<VOLUME_NAME>`, `<VOLUME_PATH>`.

## 1. The idea

The host `.git` is never writable from the cage because it is never there. One named volume is one device, so repo count does not touch the device ceiling. The clone is a full git repo: `git push -u`, `git remote add` and repo-local `git config` all work.

## 2. The volume

A named volume in map form, owned by the agent user (`uid: 1000`, `gid: 1000`), created at `msb create`, at a target path you choose (`<VOLUME_PATH>`). Fields: [config.md, Named volumes](../../docs/reference/config.md#named-volumes).

## 3. The forge credential

A `secrets:` entry for `GH_TOKEN` allowed to `github.com`, plus the two egress lines. The declarations, the token file and the reason they are two separate declarations: [egress.md, Worked example](../../docs/reference/egress.md#worked-example-pushing-to-github-over-https). `github.com` carries clone and push; `api.github.com` is needed only for `gh` API calls. The guest sees a placeholder, never the token; the fragment's `env:` entry `GH_TOKEN` hands that placeholder to `gh`. Scope the token to the repos you want pushed.

HTTPS is the only remote form this serves: msb's secret substitution needs TLS inspection, so ssh and plain-HTTP remotes fall outside it.

## 4. Git picks up the credential

Three entries in the config's `env:` map declare a credential helper: `GIT_CONFIG_COUNT: "1"`, `GIT_CONFIG_KEY_0: credential.helper`, `GIT_CONFIG_VALUE_0: "!gh auth git-credential"`. Quote the value: a bare `!` is a YAML tag ([config.md, env](../../docs/reference/config.md)). `env:` survives `rc up --replace`; a `git config --global` line in the guest rootfs does not.

The alternative is the URL-embedded token form in egress.md's worked example.

Then, in the cage:

```bash
git clone https://github.com/<OWNER>/<REPO>.git <VOLUME_PATH>/<REPO>
```

## 5. Other folders

Each other folder is a per-folder `"<ABSOLUTE_PATH_TO_YOUR_FOLDER>:<GUEST_PATH>"` line, read-write, or `:ro` for read-only.

**Every git repo inside a read-write folder is hidden by rc:** the cage sees a directory holding one `README.md`. `rc up` prints which repos it hid ([config.md, Repos inside a mounted folder are hidden](../../docs/reference/config.md#repos-inside-a-mounted-folder-are-hidden)). The remedy is to clone it onto your volume. To work on one in place, add a read-write mount line for that repo's own directory; a read-only line leaves it hidden in the folder view.

## 6. Mixed folders

A folder holding documents and some repos mounts in one of two shapes. Pick the one with fewer lines: each line and each hide costs a device.

```yaml
# (a) mount the folder; rc hides each repo inside it
mounts:
  - "<ABSOLUTE_PATH_TO_YOUR_FOLDER>:<GUEST_PATH>"

# (b) mount only the wanted sub-folders; the repos are absent
mounts:
  - "<ABSOLUTE_PATH_TO_YOUR_FOLDER>/<DOCS_SUBFOLDER>:<GUEST_PATH>/<DOCS_SUBFOLDER>"
  - "<ABSOLUTE_PATH_TO_YOUR_FOLDER>/<OTHER_SUBFOLDER>:<GUEST_PATH>/<OTHER_SUBFOLDER>"
```

A folder of dozens of repos is not mounted: clone the ones you need onto your volume.

## 7. What persists

A volume declared in the config outlives `msb stop` and start, `rc up --replace` and `rc destroy`; remove it with `msb volume remove <VOLUME_NAME>` ([config.md, Named volumes](../../docs/reference/config.md#named-volumes)). The guest rootfs does not outlive `--replace`, which is why item 4 uses `env:`.

## 8. Secrets

A clone carries no `.env`: only committed files cross the forge. A mounted folder's secret names on the protected-paths list are covered ([config.md, Secret covers](../../docs/reference/config.md#secret-covers)); a cover is a visibility default, not a guarantee. Keep real keys in `secrets:`.

## 9. Two modes, side by side

| | `rc up <project>` | clone onto your volume |
|---|---|---|
| Shape | project mounted read-write at `/workspace`, live sync, no push | repo cloned onto the volume, push is the bridge |
| Host `.git` | on the mount; covers and their accepted costs ([ADR-002](../../docs/decisions/ADR-002-rip-cage-containers.md) D11) | absent |
| Upstream tracking, `git remote add` in the cage | limited by the covers | work |
| Pick it when | one project, you want edits on the host as they happen | many repos, or a repo you want the agent to own end to end |

Neither is the default for every cage; compose the one that fits.
