# ADR-022: SSH host + key allowlist as the first `.rip-cage.yaml` consumer

**Status:** Accepted — pending implementation (`rip-cage-b0c`)
**Date:** 2026-05-12
**Design:** [Design doc](../design/2026-05-12-ssh-allowlist-design.md)
**Builds on:** [ADR-021](ADR-021-layered-rip-cage-config.md) (`.rip-cage.yaml` substrate), [ADR-020](ADR-020-ssh-identity-routing.md) (config translation, pubkey mount), [ADR-018](ADR-018-macos-ssh-agent-discovery.md) (host-side socket discovery), [ADR-017](ADR-017-ssh-agent-forwarding-default.md) (forward-by-default)
**Edits in place per [ADR-011](ADR-011-adrs-reflect-target-architecture.md):** ADR-014 D2 caveat (line 79), ADR-020 D1 (mount description), ADR-020 D2 transform 5
**Related:** [ADR-001](ADR-001-fail-loud-pattern.md) (loud + actionable failure), project [CLAUDE.md](../../CLAUDE.md) philosophy section ("layers, not walls"; "80/20, not 100/0")

## Context

ADR-014 D2 introduced an image-baked `/etc/ssh/ssh_known_hosts` (github.com pins) plus a system `ssh_config` setting `UserKnownHostsFile=/etc/ssh/ssh_known_hosts`, intended as a non-interactive SSH posture defaulting to "github.com only." Its caveat at line 79 honestly named the reach limit: `Match final Host *` does not defeat explicit CLI `-o` flags or per-Host user-config values.

ADR-020 D2 transform 5 was added to defend D2's posture at the per-Host translation layer (rewrite user-config `UserKnownHostsFile` directives back to the image-baked file). It defends against per-Host *config* overrides but not against CLI `-o`. Combined with ADR-020 D1's wholesale `~/.ssh/known_hosts` mount, the result is: the file the rewrite redirects *away from* is mounted right next to the file it redirects *to*. Any caller passing `-o UserKnownHostsFile=~/.ssh/known_hosts` walks past the rewrite to the mounted file and reaches every host the user has ever pinned.

Confirmed 2026-05-11 in `~/code/personal/kinky-bubbles`: `ssh -o UserKnownHostsFile=~/.ssh/known_hosts switch.berlin` succeeds. The ADR-014 D2 caveat predicted exactly this.

The deeper architectural point: the cage controls two SSH-relevant capabilities, both at the mount layer — the `known_hosts` file content visible inside the cage, and the ssh-agent socket exposed inside the cage. Scoping at the *config* layer (transform 5) is at best a hint a polite caller will respect; scoping at the *mount* layer is enforcement, because there is no `-o` flag that can re-mount a file.

ADR-021 shipped the `.rip-cage.yaml` substrate (`rip-cage-o4z`). It explicitly anticipated this bead at three points:
- Line 14: "the downstream consumer (`rip-cage-b0c` SSH host+key allowlist) is what will actually replace ADR-014 D2's `known_hosts` rewrite with capability scoping."
- Line 257: "the right time to tighten defaults is when a downstream consumer ships, not when the substrate ships."
- Lines 67–68: pre-defined `ssh.allowed_hosts` as additive_list and `ssh.allowed_keys` as selection_list with full merge semantics.

This ADR is that consumer.

## Decisions

### D1: Schema — `ssh.allowed_hosts` (additive_list) + `ssh.allowed_keys` (selection_list)

**Firmness: FIRM**

`.rip-cage.yaml` and `~/.config/rip-cage/config.yaml` may declare:

```yaml
version: 1
ssh:
  allowed_hosts:
    - github.com
    - switch.berlin
    - "*.internal.example.com"
  allowed_keys:
    - id_ed25519_work
```

Per ADR-021 D2 merge rules:
- `allowed_hosts` is **additive_list** — global ∪ project, deduplicated, order-preserving.
- `allowed_keys` is **selection_list**, three-state — absent ⇒ inherit; non-empty ⇒ replace; `[]` ⇒ explicit zero-out.

`allowed_hosts` patterns mirror OpenSSH `known_hosts` semantics: exact, `*`/`?` wildcards, `[host]:port`, comma-separated host lines split per-host. Negation (`!host`) is **not supported** — composition footgun; users can omit entries instead.

`allowed_keys` matches by key **comment** (the trailing field of the `.pub` line, e.g. `id_ed25519_work`). Comment-matching maps cleanly to the established `id_ed25519_<role>` naming convention. Fingerprint matching is supported by the underlying tool (`ssh-agent-filter`) and may be added in a follow-up; v1 ships comment-only.

**Rationale:** Schema and merge semantics were settled in ADR-021 D2; this decision pins them as the v1 contract for downstream consumers and tooling. Comment-matching trades a small loss in robustness (key comments can collide; fingerprints can't) for a large gain in legibility (humans read comments, not fingerprints) — appropriate for the brevity-over-precision sweet spot rip-cage already lives in.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Filter by SHA256 fingerprint | `reasoned:` Robust but unreadable; user can't audit `.rip-cage.yaml` against memory. Add as opt-in if comment collisions show up in practice. |
| Per-destination scoping (`{host: github.com, keys: [id_ed25519_work]}`) | `reasoned:` Already provided at the config layer by ADR-020 D4 + `IdentitiesOnly yes`. Re-implementing here would duplicate D4 with worse ergonomics. |
| Single flat list mixing hosts and keys | `direct:` ADR-021 D2 distinguishes additive from selection list precisely because they have different blast-radius semantics; merging them violates D2. |

**What would invalidate this:** key-comment collisions become a routine source of misconfiguration. Promote fingerprint matching from "follow-up" to "v2 default."

### D2: Defaults — host arrow locks down; key arrow stays open

**Firmness: FIRM**

When neither layer declares `ssh.allowed_hosts`:
- The filtered `~/.ssh/known_hosts` mounted into the cage is **empty**.
- The image-baked `/etc/ssh/ssh_known_hosts` (github.com pins) remains the floor.
- Net effect: the cage trusts github.com only, regardless of `-o UserKnownHostsFile=~/.ssh/known_hosts` (the file inside is empty).

When neither layer declares `ssh.allowed_keys`:
- The host ssh-agent socket is bind-mounted directly to `/ssh-agent.sock` (today's behavior preserved).
- All keys in the host agent are usable, but only against hosts in `allowed_hosts`.

**Rationale:** The two arrows compose multiplicatively. Locking the host arrow alone closes the 2026-05-11 bypass at the source — the only host trust visible inside the cage is what the user explicitly authorizes via `allowed_hosts` (plus the github.com floor). Keeping the key arrow fully open by default preserves the "your existing workflow, caged" promise: today's pushes keep working without any `.rip-cage.yaml` authoring. Users who want to narrow further opt in by listing `allowed_keys`.

This deliberately tightens behavior on rc upgrade for users who currently SSH to non-github.com hosts via the cage. ADR-021 line 257 anticipated this — "the right time to tighten defaults is when a downstream consumer ships." Mitigation: the follow-up bead `rip-cage-97n` will detect SSH-using projects at `rc init` and offer interactive `.rip-cage.yaml` bootstrap.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Both arrows lock down by default (no agent forwarding either when `allowed_keys` absent) | `direct:` Breaks today's `git push` for everyone on rc upgrade. Per CLAUDE.md ("'It's annoying' is a design signal"), gating the legitimate path on opt-in config is exactly the friction the cage avoids. |
| Both arrows stay open (preserve all of today's behavior) | `direct:` Defeats the bead's purpose. The 2026-05-11 bypass remains; ADR-014 D2 caveat stays unfulfilled; the substrate's first consumer ships zero capability change. |
| Host arrow locks, key arrow auto-narrows to "first key whose comment matches the project's git remote" | `reasoned:` Magic — can't tell from a comment which key actually authenticates where; one heuristic away from the wrong-identity bug ADR-020 D3 exists to prevent. |

**What would invalidate this:** users routinely tightening `allowed_keys` to `[]` (cage shouldn't push) or to a single key (cage shouldn't see the others) frequently enough that "open by default" feels like the wrong polarity. At that point, flip to "all-narrow-by-default, full-forward opt-in."

### D3: Mechanism — `ssh-agent-filter` for the agent half; bash + openssl HMAC for the host half

**Firmness: FIRM**

**Agent half — `ssh-agent-filter` (Debian package `ssh-agent-filter`)**. A small C++ program that speaks the ssh-agent wire protocol, applies a comment- or fingerprint-based filter, and forwards matching requests to an upstream agent named via the `SSH_AUTH_SOCK` env var. Already packaged for Debian/Ubuntu; install via `apt-get install -y ssh-agent-filter` in the runtime stage of the Dockerfile. The package also ships a sibling binary `afssh` — that one is a one-shot wrapper that starts the filter, runs `ssh -A` once, and tears the filter down on ssh exit; it is **not** the daemon and is not used here. `init-rip-cage.sh` starts `ssh-agent-filter` when the in-cage sentinel `/etc/rip-cage/ssh-allowed-keys` signals filtering: from an agent-owned working directory (`/tmp/rip-cage-filter/`), invoke `SSH_AUTH_SOCK=/ssh-agent-upstream.sock ssh-agent-filter --comment c1 --comment c2 ...`. The daemon forks, picks `$PWD/agent.<PID>` as its socket path, and prints the path + PID to stdout (matching `ssh-agent`'s contract). `init` parses that output and `sudo ln -sfT <parsed-sock> /ssh-agent.sock` so the cage's existing `SSH_AUTH_SOCK=/ssh-agent.sock` contract holds without needing every consumer to learn a new path.

**Host half — bash + awk + openssl**. `rc up` calls `_filter_known_hosts` on the host: read `~/.ssh/known_hosts`, apply `allowed_hosts` patterns line-by-line, write to `~/.cache/rip-cage/<container>/known_hosts`. Bind-mount that into the cage at `~/.ssh/known_hosts` (read-only). For hashed entries (`|1|salt|hash`), compute HMAC-SHA1 via `openssl dgst -sha1 -mac HMAC -macopt hexkey:<salt>` against each exact `allowed_hosts` pattern; matches get unhashed and included. Wildcard patterns can't be exhaustively HMAC'd against unknown hashed entries → emit a warning naming the pattern and the `ssh-keyscan` workaround.

**Rationale:** `ssh-agent-filter` exists, is mature, and matches the sketch exactly — using it is a library choice, not a build project. ~70 LOC of bash to drive it (parse stdout, manage the symlink) vs ~200 LOC of new Python + a new ADR for the protocol implementation. The host-side filter is small enough (≈50 LOC awk + ≈20 LOC openssl HMAC) that bash without new dependencies wins on simplicity over a vendored Python helper.

**Alternatives considered:**

| Alternative | Rejected because |
|---|---|
| Custom Python ssh-agent proxy daemon | `reasoned:` ~200 LOC of binary protocol implementation when a packaged tool exists; ongoing maintenance surface for a problem someone else already solved. |
| Per-identity agent multiplexer (ssh-ident pattern) | `direct:` Requires private keys as files in the cage, violating ADR-017 D1 + ADR-020 D1 ("no private key material crosses the boundary"). |
| OpenSSH 8.9 destination constraints (`ssh-add -h <host>`) | `reasoned:` Native protocol extension, but enforcement requires updated `sshd` on every destination — outside our control. Useful as a defense-in-depth layer when widely deployed; not enforcement today. |
| Custom agent with allowlist (1Password agent.toml model) | `direct:` Only works if the agent is yours. The host agent is the user's, and the design goal is to *not* replace it. |
| Sidestep entirely — HTTPS with token broker (nanoclaw / Vault SSH CA) | `direct:` Different paradigm — no credentials in container, gateway injects per-request. Abandons "your existing workflow, caged" positioning. Worth knowing about; not what rip-cage is. |
| Host-side `ssh-keyscan` to auto-resolve hashed entries | `reasoned:` Adds silent TOFU on every `rc up` for any allowed host that's only present hashed; Option 3 (HMAC-against-salt) covers the same case without new TOFU. |

**What would invalidate this:** `ssh-agent-filter` is removed from Debian, or proves to have a wire-protocol regression that breaks newer ssh-agent features. Then the custom-proxy alternative gets promoted.

**Invalidation check (mechanical, runnable post-implementation):** `docker run --rm <rip-cage-image> apt list --installed 2>/dev/null | grep -q ssh-agent-filter` exits 0. Missing package means the agent half regressed to today's full-forward behavior.

### D4: Two arrows compose multiplicatively; ADR-014 D2 caveat is fulfilled

**Firmness: FIRM**

The cage's effective SSH reach is the intersection of the two filters:
- `allowed_hosts` × `(image-baked github.com floor)` = which destinations are trusted.
- `allowed_keys` × `(host agent contents)` = which credentials are offered.

A connection succeeds only if both filters pass. Either filter on its own narrows the cage; both together narrow it further. The `-o UserKnownHostsFile=...` bypass is closed structurally because the file inside the cage is the filtered file — there is no other known_hosts to point at.

This fulfills ADR-014 D2's line-79 caveat ("a future ... forwarded-agent scenario that requires real enforcement against user/CLI overrides would need a read-only `~/.ssh` bind mount akin to ADR-002 D11"). Per ADR-011, the caveat in ADR-014 D2 is edited in place to reference this ADR rather than call the gap open.

**Rationale:** Multiplicative composition is the simplest model that's also the strictest — neither arrow can silently widen the other. ADR-014 D2's caveat correctly identified the architectural shape the fix needed; this ADR delivers it.

**What would invalidate this:** evidence of an in-cage attack vector that bypasses both filters (e.g. a child process that re-mounts paths). Cage user namespace + read-only mounts make this implausible without root, and root is not given to the agent user. Re-evaluate if cage privilege model changes.

**Invalidation check (mechanical, runnable post-implementation):** In `tests/test-ssh-allowlist.sh`, with no `.rip-cage.yaml` present, exec inside cage: `ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/home/agent/.ssh/known_hosts switch.berlin` exits non-zero with a host-key-verification or no-route error (NOT a successful SSH session and NOT a TTY hang). The 2026-05-11 bypass is closed.

## Consequences

**Positive:**
- The 2026-05-11 `-o UserKnownHostsFile` bypass is structurally closed — the file inside the cage is the filtered file, period.
- `.rip-cage.yaml` gets a real first consumer; the layered config substrate proves itself in a non-trivial use case.
- ADR-014 D2's predicted enforcement gap is filled; the caveat collapses to a one-line cross-reference.
- The "your existing workflow, caged" positioning holds: today's pushes keep working with no config authoring. Tightening further is opt-in.
- Two new mount-layer enforcement surfaces (filtered known_hosts; filtered agent socket) that no `-o` flag can defeat.
- Scope reduction in ADR-020: D2 transform 5 narrows from defending four directives to defending two.

**Negative:**
- One new Debian package in the runtime image (`ssh-agent-filter` is small, ~30 KB).
- One new sentinel file (`/etc/rip-cage/ssh-allowed-keys`), one new background process inside the cage when `allowed_keys` is set (`ssh-agent-filter`), one new host-side cache file (`~/.cache/rip-cage/<container>/known_hosts`).
- Behavior change on rc upgrade for users who currently SSH to non-github.com hosts via the cage — they need a one-line `~/.config/rip-cage/config.yaml` or `.rip-cage.yaml`. Mitigation: `rip-cage-97n` ergonomics bead.
- Hashed `known_hosts` entries with wildcard `allowed_hosts` patterns can't be auto-resolved; a warning + `ssh-keyscan` recipe is the ergonomics seam.

**Neutral:**
- ~50 LOC bash agent-launcher + ~70 LOC bash known-hosts filter + ~80 LOC tests. Net ~200 LOC delta. Comparable to ADR-020 implementation.
- Filtering happens at `rc up` (host-side) and at `init-rip-cage.sh` start (cage-side). No per-SSH-call cost beyond `ssh-agent-filter`'s per-request filter, which is negligible.

## Implementation notes

- **`rc`** (host-side): add `_resolve_ssh_allowlists` (calls o4z `_load_effective_config`, aborts loud on D3 version drift via the existing central gate); add `_filter_known_hosts` (awk + openssl HMAC, idempotent, writes to `~/.cache/rip-cage/<container>/known_hosts`); edit `_build_ssh_mount_args` to bind-mount the filtered file (replacing the wholesale `~/.ssh/known_hosts` source) and to mount the upstream agent socket as `/ssh-agent-upstream.sock` when `allowed_keys` is set; edit `_tsc_process_file` transform 5 to drop the `UserKnownHostsFile`/`GlobalKnownHostsFile` rewrites (keep `BatchMode`/`StrictHostKeyChecking`).
- **`Dockerfile`**: add `ssh-agent-filter` to the apt-get install list in the runtime stage.
- **`init-rip-cage.sh`**: add an `ssh-agent-filter` launcher block that reads `/etc/rip-cage/ssh-allowed-keys`. If empty/absent, fall back to today's chown-and-use path; if present, run `ssh-agent-filter` from `/tmp/rip-cage-filter/` with upstream `SSH_AUTH_SOCK=/ssh-agent-upstream.sock`, parse the `SSH_AUTH_SOCK='…'` line it prints, and `sudo ln -sfT <parsed-sock> /ssh-agent.sock` so consumers find the filtered socket at the expected path. PID file at `/tmp/rip-cage.afssh.pid` (legacy filename retained for backward compat with diagnostic scripts).
- **Sentinel format**: `/etc/rip-cage/ssh-allowed-keys` is one comment per line; absent file = no allowlist (forward all); present file with zero non-comment lines = explicit zero-out (forward none); present file with N lines = forward those N.
- **Tests**: `tests/test-ssh-allowlist.sh` (new, ~14 cases per design doc); update `tests/test-ssh-config.sh` D2 transform-5 invalidation check.
- **Docs**: update `docs/reference/ssh.md` (or equivalent) with `.rip-cage.yaml` SSH section; cross-reference from ADR-021's "first consumer" section.
- **ADR alignment** (per ADR-011): see in-place edits to ADR-014 D2 caveat, ADR-020 D1 mount description, ADR-020 D2 transform 5.

## Carries over from upstream ADRs

- **ADR-021** D1 (precedence), D2 (per-field merge — additive_list, selection_list), D3 (version drift abort) — substrate this ADR consumes; unchanged.
- **ADR-020** D3 (github.com identity routing), D4 (`IdentitiesOnly yes` + pubkey mount), D5 (sentinels), D6 (identity preflight), D7 (opt-out flag) — orthogonal to this ADR; unchanged.
- **ADR-018** D1–D4 (host-side socket discovery) — unchanged. The discovered socket is bind-mounted as `/ssh-agent-upstream.sock` instead of `/ssh-agent.sock` when filtering is active; the discovery logic itself is untouched.
- **ADR-017** D1 (no private keys cross the boundary), D2 (`--no-forward-ssh`), D3 (LFS / session-close) — unchanged. The agent half adds a filter in front of the forwarded socket; it does not introduce key material into the cage.
- **ADR-014** D2 (non-interactive SSH posture: image-baked pins, `BatchMode=yes`, `StrictHostKeyChecking=yes`) — image-baked pins remain the floor; `BatchMode`/`StrictHostKeyChecking` overrides in ADR-020 D2 transform 5 remain. The line-79 caveat is updated in place to reference this ADR.
