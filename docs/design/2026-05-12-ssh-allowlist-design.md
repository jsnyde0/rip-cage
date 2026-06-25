# SSH host + key allowlist as the first `.rip-cage.yaml` consumer

**Date:** 2026-05-12
**Status:** Design — pending implementation (`rip-cage-b0c`)
**Decisions:** [ADR-022](../decisions/ADR-022-ssh-allowlist.md)
**Builds on:** [ADR-021](../decisions/ADR-021-layered-rip-cage-config.md) (`.rip-cage.yaml` substrate), [ADR-020](../decisions/ADR-020-ssh-identity-routing.md) (config translation, pubkey mount), [ADR-018](../decisions/ADR-018-macos-ssh-agent-discovery.md) (host-side socket discovery), [ADR-017](../decisions/ADR-017-ssh-agent-forwarding-default.md) (forward-by-default)
**Edits in place per the in-place-evolution convention:** ADR-020 D1, ADR-020 D2 transform 5, ADR-014 D2 caveat
**Follow-up:** `rip-cage-97n` (interactive `.rip-cage.yaml` bootstrap for ergonomic adoption)

## Problem

Today's in-cage SSH posture has two bind-mount surfaces and a config rewrite working in parallel:

1. **Host trust** — `~/.ssh/known_hosts` is bind-mounted wholesale (ADR-020 D1). The cage trusts every host the user has ever SSH'd to.
2. **Capability** — the host ssh-agent socket is forwarded (ADR-017). Every key loaded in the host agent is offered for any session inside the cage.
3. **The "fix"** — translated user `~/.ssh/config` rewrites `UserKnownHostsFile`/`GlobalKnownHostsFile` per-Host to `/etc/ssh/ssh_known_hosts` (image-baked github.com pins) (ADR-020 D2 transform 5, defending ADR-014 D2).

Verified 2026-05-11 in `~/code/personal/kinky-bubbles`: `ssh -o UserKnownHostsFile=~/.ssh/known_hosts switch.berlin` walks past the rewrite. The host pin is in `~/.ssh/known_hosts` (mounted in step 1); the rewrite (step 3) only edits the *config*, not the *mount*. CLI `-o` beats config; the rewrite is theater. ADR-014 D2's caveat at line 79 already named this reach limit honestly.

The deeper architectural point: **the rewrite was the wrong layer**. The capabilities the cage actually controls are the two mounts (known_hosts file, ssh-agent socket). Scoping at the config layer is at best a hint; scoping at the mount layer is enforcement.

This design replaces the rewrite with mount-layer enforcement, driven by the `.rip-cage.yaml` substrate from ADR-021.

## Approach

Two arrows change. Everything else (config translation, pubkey mount, github.com identity routing, image-baked floor) stays.

### Arrow 1 — host trust becomes a filtered slice

`~/.ssh/known_hosts` is no longer mounted wholesale. `rc up` reads `ssh.allowed_hosts` from the merged effective config, runs the host file through a filter on the host, and bind-mounts the *filtered output* into the cage at `~/.ssh/known_hosts`.

The image-baked `/etc/ssh/ssh_known_hosts` (github.com pins) is unchanged — that remains the floor when `~/.ssh/known_hosts` is empty/absent. So the user's `git clone git@github.com:` always works regardless of `.rip-cage.yaml` state.

**Pattern semantics** (mirror OpenSSH `known_hosts`):
- Exact hostname match (`switch.berlin`)
- Standard wildcards (`*.example.com`, `192.168.1.?`)
- `[host]:port` notation
- Comma-separated host lines split per-host before filtering; line kept if any sub-host matches
- Negation (`!host`) **not supported** — adds composition footguns; users can omit instead

**Hashed entries** (`|1|salt|hash`) — the macOS default if `HashKnownHosts=yes`:
- Try each `allowed_hosts` pattern (after wildcard expansion to candidate concrete hosts where possible) against the line's salt using HMAC-SHA1. Match → unhash + include. Non-match → drop.
- For wildcard patterns where exhaustive candidate enumeration isn't tractable (`*.example.com`), drop the hashed line and emit a warning at `rc up`: `'*.example.com' in ssh.allowed_hosts cannot match hashed known_hosts entries; add unhashed entries via 'ssh-keyscan -t ed25519 host.example.com >> ~/.ssh/known_hosts'`.
- For exact patterns (`switch.berlin`), HMAC matching is cheap and fully covers the common case.

### Arrow 2 — capability becomes a filtered agent

The host ssh-agent socket is no longer mounted directly into the cage as `/ssh-agent.sock`. Instead:

1. Host-side socket discovery (ADR-018, unchanged) finds the right host socket → bind-mount as `/ssh-agent-upstream.sock` inside the cage.
2. `init-rip-cage.sh` reads `ssh.allowed_keys` from a sentinel written by `rc up`.
3. `init-rip-cage.sh` starts `ssh-agent-filter` (Debian package `ssh-agent-filter`) with `--comment <key>` flags from the allowlist and `SSH_AUTH_SOCK=/ssh-agent-upstream.sock`. The daemon picks `$PWD/agent.<PID>` as its socket path; init parses the printed `SSH_AUTH_SOCK='…'` line and `sudo ln -sfT <parsed-sock> /ssh-agent.sock` so the cage's `SSH_AUTH_SOCK=/ssh-agent.sock` contract holds without consumers learning a new path.
4. The cage shell sees `SSH_AUTH_SOCK=/ssh-agent.sock` (unchanged from today's contract).

`ssh-agent-filter` is a small C++ program packaged in Debian. It speaks the ssh-agent wire protocol, applies the filter, and forwards matching requests upstream. Filtering is by key **comment** (the trailing field of a `.pub` line — `id_ed25519_work` for the user's keys) or by SHA256 fingerprint. Comment matches the user's existing naming convention; b0c uses comment-matching as the default. Note: the package also ships a sibling binary `afssh` — that one is a one-shot wrapper (`afssh [filter-opts] -- [ssh-args]` starts the filter, runs `ssh -A`, kills the filter on ssh exit). It is **not** the daemon and is not used by rip-cage.

When `ssh.allowed_keys` is absent (the default), `ssh-agent-filter` is skipped and the upstream socket is bind-mounted directly to `/ssh-agent.sock` (today's behavior). When `ssh.allowed_keys: []` is explicit (selection-list zero-out per ADR-021), `ssh-agent-filter` runs with no comments → empty filter → no keys forwarded.

### Defaults (no `.rip-cage.yaml`)

- `allowed_hosts` absent → filtered file is empty; cage relies entirely on the image-baked github.com pins. The `-o UserKnownHostsFile=~/.ssh/known_hosts` bypass evaporates: that file inside the cage is empty.
- `allowed_keys` absent → full agent forwarded (today's behavior preserved).

This deliberately tightens the host arrow on `rc upgrade` for users without a config file. ADR-021 line 257 anticipated this — "the right time to tighten defaults is when a downstream consumer ships, not when the substrate ships." This bead is that consumer.

For users who have been SSHing to non-github.com hosts via the cage (the kinky-bubbles + switch.berlin pattern), upgrade requires either a one-line `~/.config/rip-cage/config.yaml` (`ssh: { allowed_hosts: [switch.berlin] }`) or a per-project `.rip-cage.yaml`. The follow-up bead `rip-cage-97n` makes that bootstrap interactive and ergonomic.

## Component layout

| Component | Where | What |
|---|---|---|
| `_resolve_ssh_allowlists` | `rc` (host-side, new) | Reads merged config (loader from o4z), returns two arrays: hosts + keys. Calls `_load_effective_config` from o4z; aborts loud on D3 version-drift per o4z's central gate. |
| `_filter_known_hosts` | `rc` (host-side, new) | Awk + openssl HMAC. Reads `~/.ssh/known_hosts` line-by-line, applies pattern semantics + hashed-entry handling. Writes to `~/.cache/rip-cage/<container>/known_hosts`. Idempotent. |
| `_build_ssh_mount_args` | `rc` (existing, edited) | Replaces today's `~/.ssh/known_hosts` source with the filtered cache path. Adds `--mount` for upstream socket → `/ssh-agent-upstream.sock` when allowlist is present. |
| `_tsc_process_file` transform 5 | `rc` (existing, edited) | Drops `UserKnownHostsFile`/`GlobalKnownHostsFile` rewrites. Keeps `BatchMode`/`StrictHostKeyChecking` overrides. |
| `/etc/rip-cage/ssh-allowed-keys` | sentinel (new) | One key comment per line. Written by `rc up` from merged config. Read by `init-rip-cage.sh`. Empty if `allowed_keys` absent → `init` knows to skip the filter daemon. Distinct from "empty list specified" which writes a single sentinel marker. |
| `init-rip-cage.sh` filter launcher | `init-rip-cage.sh` (new block) | If sentinel signals filtering: cd to `/tmp/rip-cage-filter/`, run `SSH_AUTH_SOCK=/ssh-agent-upstream.sock ssh-agent-filter --comment <c1> --comment <c2> ...`, parse the printed socket path, `sudo ln -sfT <parsed-sock> /ssh-agent.sock`. If sentinel signals zero-out: same daemon launched with no `--comment` flags (forwards nothing). If sentinel absent: chown + use upstream socket directly as `/ssh-agent.sock` (today's path). |
| `Dockerfile` | new line | `apt-get install -y ssh-agent-filter` in the runtime stage. |
| `tests/test-ssh-allowlist.sh` | new | See test plan below. |

## Control flow at `rc up`

```
rc up <path>
├─ _load_effective_config (o4z) ────► aborts on D3 version drift
├─ _resolve_ssh_allowlists ─────────► hosts[], keys[]
├─ _filter_known_hosts hosts[] ─────► ~/.cache/rip-cage/<c>/known_hosts
├─ write /etc/rip-cage/ssh-allowed-keys (via docker cp on create / docker exec on resume)
├─ _translate_ssh_config (ADR-020 D2) ─► transform 5 no longer rewrites UserKnownHostsFile
├─ _build_ssh_mount_args:
│   --mount ~/.cache/rip-cage/<c>/known_hosts → ~/.ssh/known_hosts (ro)
│   --mount <discovered host socket>           → /ssh-agent-upstream.sock (ro)
└─ docker run / docker start

inside cage (init-rip-cage.sh):
├─ if /etc/rip-cage/ssh-allowed-keys present:
│   ├─ run ssh-agent-filter (--comment <c> per line) from /tmp/rip-cage-filter/, upstream=/ssh-agent-upstream.sock
│   ├─ parse SSH_AUTH_SOCK='…' from filter stdout
│   └─ sudo ln -sfT <parsed-sock> /ssh-agent.sock
└─ else:
    └─ chown agent:agent /ssh-agent-upstream.sock; symlink to /ssh-agent.sock (today's path)
```

## Test plan

`tests/test-ssh-allowlist.sh`, follows `tests/test-config-loader.sh` style:

1. **Regression — no `.rip-cage.yaml`, github.com still works**: fresh project with no config, `rc up`, exec `ssh -T -o BatchMode=yes git@github.com` returns `Hi <user>!` (or `permission denied (publickey)` if no key — both prove host trust + agent reachability).
2. **Regression — no `.rip-cage.yaml`, switch.berlin no longer works**: same project, exec `ssh -T -o BatchMode=yes -o ConnectTimeout=5 switch.berlin` fails with host-key-verification or no-route, NOT a TTY hang.
3. **Bypass closed**: same project, exec `ssh -T -o UserKnownHostsFile=~/.ssh/known_hosts switch.berlin` — the in-cage `~/.ssh/known_hosts` is the filtered (empty) file, so this also fails. The 2026-05-11 trigger.
4. **Allowed host**: project with `ssh: { allowed_hosts: [switch.berlin] }`, `rc up`, exec `ssh -T switch.berlin` — host trust passes, agent attempts auth.
5. **Wildcard host**: `allowed_hosts: ["*.internal.example.com"]`, exec `ssh foo.internal.example.com` — host trust passes if pre-pinned.
6. **Hashed entry, exact pattern**: host `~/.ssh/known_hosts` contains hashed entry for `switch.berlin`; `allowed_hosts: [switch.berlin]` → filtered file contains the unhashed line.
7. **Hashed entry, wildcard pattern**: host file has hashed entry for `foo.example.com`; `allowed_hosts: ["*.example.com"]` → filtered file omits the entry; `rc up` warning surfaced.
8. **Allowed_keys filter — subset**: host agent has `id_ed25519_personal` + `id_ed25519_work`; `allowed_keys: [id_ed25519_work]` → exec `ssh-add -L` shows only `id_ed25519_work`.
9. **Allowed_keys filter — zero-out**: same agent state; `allowed_keys: []` → `ssh-add -L` returns "The agent has no identities."
10. **Allowed_keys absent**: same agent state; no `ssh:` block → `ssh-add -L` returns both keys (today's behavior).
11. **Filter daemon survives**: after `rc up`, `pgrep -af ssh-agent-filter` inside cage shows the process; killing it produces clear failure on next `ssh-add -L` (loud, not silent).
12. **Resume preserves filtering**: `rc up` once with allowlist, `rc down`, `rc up` again — filtering reapplied (loader re-runs, sentinel rewritten, `ssh-agent-filter` restarted).
13. **D3 version-drift abort propagates**: `.rip-cage.yaml` declares `version: 99` with `allowed_keys` — `rc up` aborts before any mount.
14. **Acceptance integration**: existing `tests/test-ssh-config.sh` D2 transform-5 invalidation check is updated — the BatchMode/StrictHostKeyChecking overrides remain; the UserKnownHostsFile/GlobalKnownHostsFile rewrites must NOT appear in translated output.

## Out of scope (explicit deferrals)

- **Interactive `.rip-cage.yaml` bootstrap.** Filed as `rip-cage-97n`. b0c ships the substrate; 97n ships the ergonomic on-ramp.
- **`rc doctor` integration** showing live `ssh-add -L` filtered output, `ssh-agent-filter` PID, last filter event. Future bead.
- **Egress-allowlist coupling.** `ssh.allowed_hosts` is host-trust scoping, not egress scoping. A host can be in the allowlist and still be unreachable due to egress firewall (or vice versa). Deliberate separation; documenting `egress.allow` integration is for the egress-firewall bead.
- **Negation patterns** (`!host`) — composition footgun, omit.
- **Filter by key fingerprint** instead of comment — `ssh-agent-filter` supports it; b0c ships comment-only because that matches the user's existing convention. Trivial to add later.
- **Per-host key scoping** (e.g. "id_ed25519_work only for github.com, never for switch.berlin"). `ssh-agent-filter` filters globally; per-destination scoping is what `IdentitiesOnly yes` + ADR-020 D4 already do at the config layer. Deliberate non-overlap.

## Acceptance (matches updated b0c bead)

See ADR-022 for full decision-level acceptance. Implementation acceptance:
- Tests 1–14 above pass.
- ADR-020 D1 mount language updated; ADR-020 D2 transform 5 narrowed; ADR-014 D2 caveat updated.
- `apt list --installed 2>/dev/null | grep ssh-agent-filter` returns a line in a fresh image.
- `_filter_known_hosts` is idempotent (run twice, output byte-identical).
- D3 abort path propagates from loader through `rc up` (ADR-021 D3 + o4z's `_config_validate_or_abort`).
