# Isolation-boundary review — where the msb cage boundary can fail (2026-10-03)

Source bead: `dotpi-wyf.10` (dotpi tracker). Findings parent: `rip-cage-p4ss`. Reviewer seat: `driver:dotpi-wyf.10`, dispatched by `brain:dotpi`. Builds on the composed-posture review (`docs/2026-10-03-composed-posture-review.md`, findings `rip-cage-rsh9`); none of those are re-filed here.

Defensive, read-only review. No cage or msb VM was started, stopped or changed, and no rip-cage code was edited. Probes ran on the host only: the protected-paths matcher under bash with the shipped list, `jq`/`tr` byte probes, `ls` of `~/.microsandbox`, and a read-only read of one live cage config in `msb.db`. Anything that needs a live guest is marked **unconfirmed** with the probe it needs.

## What was reviewed

Three boundary surfaces, one read-only reviewer each, with the driver re-checking every high and medium claim in source:

| Surface | Question |
|---|---|
| Shares | What host paths enter the guest, rw or ro, and what host process later reads or runs what the guest wrote there |
| Network | Where egress is enforced, what the guest can reach on the host, LAN and other cages, and whether the rules can be bypassed |
| Host-side parsers and supply chain | Every place the host consumes guest bytes, how the image is built and pinned, and what persists across cages |

The enforcement points themselves hold. Egress is enforced in msb's host-side network stack, which the guest cannot reach. msb has no TCP listener; its control sockets are host-only. Mount identity is virtualised, so guest writes land as the host user and cannot create root-owned host files.

## Ranked findings

| Rank | Bead | Sev | Surface | Finding | Status |
|---|---|---|---|---|---|
| 1 | `rip-cage-p4ss.1` | high | shares | A guest-written `.beads/redirect` makes the next `rc up` mount `~/.claude`, `~/.pi/agent` or another project **rw** into the cage. That is host code execution at the next host Claude or pi launch. Gates refuse `~/.ssh` and `$HOME`, but not these. | **Confirmed** by host probe (`cli/up.sh:1017-1053`) |
| 2 | `rip-cage-p4ss.2` | high | shares / persistence | `rc-mise-cache` is one rw volume shared by every cage and kept past `rc destroy`. One cage can plant a trojaned `node` or shim that every later cage runs. | Confirmed in source; live cross-cage probe pending |
| 3 | `rip-cage-p4ss.3` | med | shares | Host tools auto-run guest-written workspace config: Claude hooks, `.mcp.json`, `.pi/`, `.vscode/tasks.json`, `.envrc`, `.mise.toml`. Same class as `rsh9.2`. | Confirmed in source |
| 4 | `rip-cage-p4ss.4` | med | host parsers | Guest bytes reach the host terminal unfiltered: `rc up` error text, `rc doctor` port and status lines, raw `msb exec -t` attach. The tmux recipe relays guest OSC 52 to the **host clipboard**, which is a copy-paste exec primitive. | Confirmed in source and byte probe; herdr unprobed |
| 5 | `rip-cage-p4ss.9` | med | network | Nothing flags weak allow rules. Raw-IP/CIDR and non-443 rules skip DNS-deny, TLS interception and authority checks; one live cage has port-80 rules for Telegram ranges. `strict:false` is not refused. Host, private, link-local and cross-cage reachability is never asserted. | Rule shapes confirmed; reachability unconfirmed |
| 6 | `rip-cage-p4ss.5` | med | supply chain | Image build is unpinned: `FROM` by tag, claude and pi `@latest`, `curl \| sh` installers, GHCR pulled by mutable tag with no digest or signature. | Confirmed in source |
| 7 | `rip-cage-p4ss.7` | med | shares | `~/.claude/projects` and `sessions` are mounted whole and rw. Any cage reads and edits every project's transcripts and memory; guest symlinks there may be followed by host Claude. | Unconfirmed |
| 8 | `rip-cage-p4ss.8` | med | shares | The whole `~/.claude.json` is mounted ro. It may hold MCP server tokens and every project's entries. | Unconfirmed (owner should list key names only) |
| 9 | `rip-cage-p4ss.6` | med | resources | No disk quota on rw shares, named volumes or root disk. A guest can fill the host volume. | Unconfirmed |
| 10 | `rip-cage-p4ss.10` | med→low | network | `rc up --port` publishes with no bind address; the msb default may be all interfaces. | Unconfirmed |
| 11 | `rip-cage-p4ss.11` | low | mixed | Bundle: doctor turns guest-chosen DNS names into paste-ready allowlist lines; `msb.db` 0644 and runtime logs 0666 (mitigated by `$HOME` 0750); `cage-reach` output not documented as untrusted; 4-digit cage-name hash; host `bd` reading guest-written `.beads` config not yet ruled safe. | Mostly confirmed |

Each bead carries file:line evidence, the gap, a fix direction, the live probe where one is needed, and its own `## Verification target`.

## Extensions to existing beads (commented, not re-filed)

- `rip-cage-rsh9.6` — **DNS-tunnel question closed** for the shipped config, pending one probe. Every rule is an exact domain, gateway DNS applies the same policy, and direct UDP/53 is denied. The residual is any operator `*.suffix` rule. The new raw-IP channel class is rank 5.
- `rip-cage-rsh9.11` — substitution is headers-only (`query:false, body:false`) with `block-and-log`. Reflection of the real header by an allowed host is still unproven; the probe is on the bead.
- `rip-cage-rsh9.1` — persistence angle: attach hooks are read from the live guest's `boot.json` and run on the next `rc up` attach. With root in the guest, that is control over what the human's attach runs.
- `rip-cage-rsh9.2` — rank 3 is the same class with other files; one ro-cover mechanism should serve both.
- `rip-cage-2slc` — rank 7 widens it to cross-project scope and the symlink angle.

## Checked and holding

- Egress default-deny is refused-if-absent, with no opt-out (`cli/up.sh:1385-1417`). Hostname rules are tcp/443 (`cli/lib/msb_flags.sh:222-231`). QUIC is blocked under interception. Upstream TLS is verified and host CAs are not trusted.
- Ingress is default-deny and the live cage publishes no ports.
- The CCTOK value is in neither the guest nor the stored sandbox config. The secret-violation miner is kept apart from the allowlist hint (`cli/lib/msb_runtime.sh:575-610`).
- The worktree `.git-main` gitdir is validated by shape, backlink and location (`cli/up.sh:236-290`). Rank 1 should copy this.
- The secrets-dir ancestor test runs at every rc-generated mount site (`cli/lib/protected_paths.sh:232-251`).
- No host-side `eval` or word-splitting of guest data. Guest values reach jq through `--arg`. `msb exec` always gets an argv array. JSON-mode output escapes control bytes.
- Labels, names and mounts read through `msb inspect` are host-set at create time and are not guest-writable.
- `rc reload` recreates the sandbox, so the overlay is discarded. It only persists on an in-place crash restart.
- Memory and CPU are bounded by the template.

## Probes this review needs (live, throwaway cage)

1. **Rank 2:** in cage A run `touch ~/.local/share/mise/PLANT`; in fresh cage B run `ls` on the same path.
2. **Rank 4:** in a herdr pane run `printf '\e]52;c;%s\a' "$(printf evil|base64)"` while watching the host clipboard.
3. **Rank 5:** fronting and reachability: `curl --resolve evil.example:443:<pypi ip> https://evil.example/`, then `curl -m3` to the host LAN IP, to `169.254.169.254`, to `host.microsandbox.internal:5432` and to another cage's gateway. All must fail fast.
4. **Rank 6:** run `dd` into `/workspace`, the mise volume and `/tmp` while watching host `df`.
5. **Rank 7:** run `ln -s ../../.ssh ~/.claude/projects/x` in the guest and check what the host resolves; `ls ~/.claude/projects` from the guest.
6. **Rank 10:** create a sandbox with `-p 18999:18999`, then `lsof -iTCP:18999 -sTCP:LISTEN -n -P`.
7. **`rsh9.6`:** run `getent hosts zz1.github.com` in a cage, then grep `msb logs` for the denial.
8. **`rsh9.11`:** reflection: an error endpoint must not echo the real token.

## Decisions that want an ADR (proposed, not written)

1. **ADR-015: shared mise cache.** Proposed evolution: make the cache per-project, or ro at runtime with build-time population. The speed win does not cover a cross-cage persistence channel under ADR-024's steered-agent model.
2. **ADR-024: host tools running guest-written workspace config.** Either ro-cover a named deny-list under every rw project mount (together with `rsh9.2`'s `.git/config`), or record it as an explicit accepted residual. Today it is neither.
3. **ADR-029 D2: egress rule shapes.** Record that only port-443 hostname rules get interception and authority checks, that rules are exact-match, and that `strict:false` is refused.
4. **ADR-019 D8: `PI_VERSION=latest`.** Pinning it, plus digest-pinning the image, trades auto-update for a reproducible guest. This is the owner's call.
