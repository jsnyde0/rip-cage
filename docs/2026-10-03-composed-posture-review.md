# Composed-posture review — the cage composed with its guards (2026-10-03)

Source bead: `dotpi-wyf.3` (dotpi tracker). Findings parent: `rip-cage-rsh9`. Reviewer seat: `driver:dotpi-wyf.3`, dispatched by `brain:dotpi`.

Defensive, read-only review. No cage was started and no rip-cage code was changed. Probes ran on the host only, in `mktemp -d` trees, against `cli/lib/protected_paths.sh` and a host `dcg` v0.4.0 with the recipe's core-only config. Deep isolation-boundary enumeration is out of scope; that is `dotpi-wyf.10`.

## What was reviewed

The bead was written before ADR-029 and ADR-031. The tools manifest, the three-layer config and iron-proxy mediation it names are retired. The review mapped its three layers onto today's shape:

| Layer | Today's mechanism | Anchors |
|---|---|---|
| Mount layer | One native msb config per project, plus the protected-paths rule and the D5(a) location rule in `rc up` | ADR-031 D2, D5(a), D5(d) |
| Guards | DCG recipe (Claude managed hook, pi `dcg-gate.ts`), floor probe, scoped sudo, read-only `.git/hooks` | ADR-031 D5(b), ADR-002 D11/D12, ADR-019 D8, ADR-027 D1 |
| Credential mediation | msb `--secret` placeholder for CCTOK, `secrets.<NAME>.allow` host binding, default-deny egress | ADR-031 D1, D2 amendment, ADR-029 D3/D5 |

The composition seams between layers were the primary target, as the bead asked.

## Ranked findings

| Rank | Bead | Sev | Layer / seam | Finding |
|---|---|---|---|---|
| 1 | `rip-cage-rsh9.1` | high | guards | Scoped sudo grants `apt-get` and `dpkg`, which run arbitrary code as root. Every root-owned guard is then editable. ADR-002 D12 (FIRM) premise not met. **ADR fork.** Unconfirmed in a live cage. |
| 2 | `rip-cage-rsh9.2` | high | mount x guards | `.git/config` is writable, so one git config key runs a command on the **host** at its next `git status`. Wider than the hooksPath risk ADR-002 D11 accepted in April. Hooks-ro only covers the `rc up` path argument. **ADR fork.** |
| 3 | `rip-cage-rsh9.3` | high | mount | A trailing slash on a mount source silently disables auto-cover, with exit 0. **Reproduced by the driver.** |
| 4 | `rip-cage-rsh9.4` | high | credentials | Host provider API keys and pi's `auth.json` reach the guest as real values by default. Non-possession holds for CCTOK only. |
| 5 | `rip-cage-rsh9.5` | high | guards (DCG-side) | DCG allows any command whose hook input is over 256 KiB. Confirmed in DCG source. Fixable in the recipe wrapper. |
| 6 | `rip-cage-rsh9.6` | med | credentials x mount | The default allowlist holds open exfil channels: datadog log intake, github.com in full, registry publish. Only an attacker token in the injected text is needed. DNS-tunnel question open. |
| 7 | `rip-cage-rsh9.7` | med | mount | Protected-paths matcher holes: exact names only, silent depth-2 truncation, final-component symlinks and case variants pass refusal. |
| 8 | `rip-cage-rsh9.8` | med | mount | The D5(a) location rule is enforced only for the msb config, not for the list, Dockerfile or rc install. A symlinked config passes. |
| 9 | `rip-cage-rsh9.9` | med | guards (DCG-side) | The floor probe passes with DCG absent or with pi's gate dropped from a merged launch. The headless-throttle remedy is a documented way to drop it. |
| 10 | `rip-cage-rsh9.10` | med | guards (DCG-side) | Only the core pack is enabled and only Bash is hooked. Interpreter, variable-built and file-staged commands pass. Should be documented as a speed bump. |
| 11 | `rip-cage-rsh9.11` | med | credentials | The placeholder works on any api.anthropic.com endpoint, not just model calls. `--on-secret-violation` is never pinned. |
| 12 | `rip-cage-rsh9.12` | low | guards (DCG-side) | The pi gate fails open on any error, and `pi-real` is directly executable. |
| 13 | `rip-cage-rsh9.13` | low | credentials, mount | Bundle: secret-file checks cover only CCTOK, an unknown msb version fails open, the cover breadcrumb is shared, and there is no regression check for the token in trace logs. |

Each bead carries file:line evidence, the gap, a fix direction and its own `## Verification target`.

## Known residuals the bead named

- **DCG open extension discovery: still open, by design.** pi extension discovery is OPEN by default and LOCKED is opt-in (`examples/dcg/README.md`, ADR-027 D1 FIRM). It now compounds with ranks 1 and 12. This review does not reopen ADR-027 D1.
- **pi headless throttle: a reliability issue, with one security seam.** Unpinned headless pi hits a 400 from the third-party throttle. The documented remedy is hand-authoring a pi `launch`, which can silently drop the DCG gate. That seam is rank 9.

## Cross-references to existing beads

- `rip-cage-csol`: the worktree `.git-main` mount skips auto-cover. A sibling of ranks 3, 7 and 8; a comment links them.
- `rip-cage-2slc`: the rw `~/.claude` mount posture. Commented: rw session transcripts that host Claude re-reads are a prompt-injection persistence channel.
- `rip-cage-pacg`: the dead `.git/hooks` deny rule. Commented: the runtime settings file is agent-editable, and the ro hooks mount is skipped when the directory is absent at launch.

## Checked and holding

- The guest holds only the CCTOK placeholder. The config has no `value:`, and `msb inspect` showed an empty value in the spike.
- A placeholder sent to a host it is not bound to is blocked, not substituted.
- Every generated mount is checked against the secrets dir, including symlink, worktree and beads-redirect sources.
- The protected-paths list resolves from host-only locations. A missing explicit override or an empty list fails closed before any msb call.
- The floor probe runs first in init, has no skip flag, and refuses the agent shell on any failure.
- The managed-settings file is root-owned in a root-owned dir, and DCG's config walk-up is suppressed by the wrapper. This holds unless rank 1 applies.
- Egress is `policy: none` with explicit host:443 entries and strict authority checking.
- No gh token, npm token, `.netrc`, ssh agent or ssh key is mounted by default.

## Not filed

- The real secret is exported into rc's own process env before `msb create`. Same-user host processes can read that env, but they can already read the 0600 secrets file, so no boundary is lost.

## Decisions that want an ADR (proposed, not written)

1. **ADR-002 D12 (FIRM): scoped sudo.** Proposed evolution: drop `apt-get` and `dpkg` from sudoers. ADR-031 D4 already gives users a build-time install path through their FROM-extension Dockerfile. The alternative is a root-owned allowlist wrapper. Needs the human's ruling because D12 is FIRM.
2. **ADR-002 D11 / the 2026-04-09 accepted risk: writable git config.** Proposed evolution: cover `.git/config`, `.git/info` and `.gitattributes` read-only under every mounted repo, and retire the accepted risk. The original acceptance predates ADR-024's steered-agent threat model and did not consider single-step keys such as `core.fsmonitor`.
3. **ADR-031 D1, scope of "credentials never enter the VM".** Either extend non-possession to provider keys and pi auth (rank 4), or narrow the claim in the README's two-column table. This is a positioning call.
