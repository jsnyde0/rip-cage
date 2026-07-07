# MicroVM spike — live evidence + deep research findings (2026-07-07)

Home bead: **rip-cage-gljd**. Companion to the research dossier
(`2026-07-07-microvm-isolation-primitive-research.md`) — that doc framed the question;
this one records what actually happened when we ran the experiments, plus two deep
research passes (official docs / primary sources). Status: **spike substantially answered
for microsandbox and sbx; broader-landscape round still to run before the final ADR-shaped
recommendation.**

---

## 1. Headline result: the bottom-layer-swap thesis is LIVE-PROVEN on microsandbox

The freshly-built `rip-cage:latest` (4.25GB, arm64, built 2026-07-07) boots under
microsandbox v0.6.4 on macOS 26.3 / Apple Silicon **unmodified**:

```
docker save docker.io/library/rip-cage:latest | msb load     # ~1-2 min one-time EROFS conversion
msb run -d --name rc-spike --entrypoint sleep rip-cage:latest -- infinity
```

Live evidence collected:

| Check | Result |
|---|---|
| Guest kernel | `Linux 6.12.91 aarch64` — **own kernel per cage** (libkrunfw), not OrbStack's shared VM kernel |
| Image USER honored | `msb exec` lands as `uid=1000(agent)`; `-u root` / in-guest `sudo -n` both work |
| rip-cage toolchain | `herdr` (0.7.0, runs), `dcg`, `claude`, `pi`, `node`, `python3` all present at their baked paths |
| Warm boot | **0.27s wall-clock** for run + teardown of the 4GB image (`msb run --entrypoint true`) |
| Per-VM host RSS | **~90–105 MB** per running sandbox → 10 concurrent cages ≈ 1 GB |
| Workspace mount | `-v /tmp/…:/workspace` (virtiofs): host uid 501 ↔ guest uid 1000 identity-mapped both ways; guest writes appear host-side owned by the user; RW works |
| Egress allowlist | `--net-default deny --net-rule "allow@api.anthropic.com:tcp:443"`: anthropic reachable (TLS+HTTP fine), `example.com` hard-blocked. Enforced in msb's **host-side user-space network stack** (smoltcp, DNS-pinned + SNI-checked) — outside the guest kernel entirely |
| tmux absent in guest | Also absent under plain Docker (control-checked) — image fact, not an msb delta |

**The one real breakage:** `init-firewall.sh` fails inside the guest —
`iptables: No chain/target/match by that name` (+ `Extension owner revision 0 not
supported`). The libkrunfw kernel lacks the **`xt_owner`** netfilter module, which our
transparent-redirect design depends on (`-m owner ! --uid-owner $RIP_PROXY_UID -j
REDIRECT --to-port 8080`, same for DNS :5300).

**Architectural read of that breakage:** under VM-per-cage, in-guest iptables is the
*wrong layer* anyway. Today's design puts the egress choke inside a kernel the agent
shares (and, with root, could theoretically fight). msb's policy engine enforces
default-deny + allowlist **on the host side of the VM boundary** — a rooted agent inside
the guest cannot lift it. The firewall layer doesn't port; it *relocates and gets
stronger*. What must be verified next: the mediator/iron-proxy composition in that world
(cooperative shape: `--net-default deny` + `allow@host:tcp:<port>` +
`HTTP_PROXY=host.microsandbox.internal:<port>` in-guest — same cage-points-at-mediator
shape as today, minus the transparent-redirect safety net; or msb's built-in
TLS-intercept proxy with its auto-CA). Not yet live-tested.

## 2. Docker sbx: competitor confirmed, substrate disconfirmed

Live findings (CLI 0.34.0 on this machine) + docs deep-dive
(docs.docker.com/ai/sandboxes/*, cited in bead notes):

- **Credential non-possession is mechanism-parity with iron-proxy, shipped.** Sandbox
  holds only sentinels (`proxy-managed`, `sbx-cs-<rand>`); host proxy terminates TLS with
  a pre-trusted CA and injects real secrets per request — including placeholder
  substitution in request *bodies* for arbitrary hosts (`sbx secret set-custom`,
  experimental). Agent OAuth (Claude Code/Codex/Cursor) is proxy-brokered; tokens never
  enter the sandbox. Secrets live in the OS keychain. **The dossier's "no competitor
  documented this" is falsified.**
- **Hard account coupling:** `sbx create`, `sbx policy ls`, `sbx setup` all 401 without
  Docker sign-in (browser OAuth; PAT for CI). Free incl. commercial; paid tier = org
  governance. No air-gapped mode; required-reachable Docker domains documented.
- **Mandatory explicit egress posture:** refuses to create sandboxes until
  `sbx policy init <allow-all|balanced|deny-all>`. Good posture design worth noting.
- **Custom images:** templates must *extend* `docker/sandbox-templates:<variant>` base
  images; "templates don't create new agent runtimes" (that's their Kits system). Booting
  `rip-cage:latest` as-is is undocumented/likely unsupported (one empirical attempt via
  `sbx template load` still possible post-login; expectations low).
- **Composition with an external mediator is structurally hostile:** proxy cannot be
  disabled; sandbox→host-localhost and private ranges are hard-blocked (not
  policy-changeable); only hook is daemon-side upstream chaining (`DOCKER_SANDBOXES_PROXY`,
  HTTP/HTTPS only) which puts their TLS-MITM in front of ours.
- **Mounts:** virtiofs at same absolute host path (matches our ADR-002 D9 path-parity);
  officially acknowledged slow `git status`/scans on large repos; `--clone` mode (agent
  works on a private in-VM clone, wired back as a `sandbox-<name>` git remote via
  localhost git-daemon; host `.git` untouchable) — **a genuinely good idea worth stealing
  regardless of verdict.**
- Default template embeds a full Docker Engine inside the microVM (privileged container,
  50GB sparse volume) — nested compose for free is table stakes in their product.

## 3. microsandbox deep-research facts that matter beyond the live test

(Primary sources: repo docs/source/issues, superradcompany/microsandbox, v0.6.4.)

- Root-with-normal-semantics by default; init systems, sudo, **Docker-in-Docker
  officially supported** (recipe boots `docker:dind` with `/var/lib/docker` on a
  disk-backed virtio-blk volume). docker-compose-inside unverified but structurally
  unobstructed → the DB-backed-test-suite problem (origin of this whole spike) plausibly
  dissolves.
- PID 1 is their guest agent (`agentd`); `--init` can hand off to real init;
  `msb exec` keeps working after handoff. `msb ssh` gives interactive shells +
  `msb ssh serve` exposes real ssh/sftp/port-forwarding without a guest sshd.
- Mount identity is *virtualized* by default (guest doesn't see host uid/gid;
  `host-perms=mirror` restores parity); ro enforced host-side; macOS path containment is
  weaker than Linux (`O_NOFOLLOW` vs `openat2`). Known heavy-IO reliability issue on
  virtiofs (Gradle, issue #949) — **virtiofs perf on a real repo is untested by us.**
- No project manifest yet (Sandboxfile is an open feature request #970) — per-sandbox
  config is CLI flags/SDK. Fine for us: rip-cage's manifest is the *image*; rc would
  generate the msb flags.
- Maturity: beta, weekly-ish releases, 2 dominant maintainers, 6.9k stars, YC-backed;
  all macOS/Apple-Silicon-labeled issues closed as of today; notable open: virtiofs
  heavy-IO (#949), non-loopback published-port throughput ~100KB/s (#914), no
  snapshot/resume yet (#250). Their own roadmap drifts toward credential substitution
  (#769 SOCKS secret-swap) — the swap-layer is commoditizing from both sides.

## 4. Spike-question scoreboard (from the bead's five questions)

1. **Can the rc-built image boot with init-firewall + iron-proxy + herdr functioning?**
   Boot: YES, unmodified. herdr: present + runs. init-firewall: FAILS as written
   (xt_owner) — but the control relocates host-side and gets stronger (see §1).
   iron-proxy composition: shape identified, **not yet live-tested**.
2. **File-sharing semantics + perf:** semantics PASS (identity mapping both ways, rw, ro
   available). Perf on a real repo: untested; known upstream heavy-IO caveat.
3. **Does sbx's proxy compose with iron-proxy?** Structurally hostile (see §2) — and
   moot: sbx is a competitor product, not a substrate. For microsandbox: cooperative
   composition path exists.
4. **Resource overhead:** ~100MB RSS + 0.27s warm boot per cage. Non-issue at
   several-cages scale.
5. **Which rc verbs break:** `exec` maps (incl. `-u root`); attach maps (`msb exec` TTY /
   `msb ssh`); boot-time `docker exec -u root … init-firewall.sh` step becomes msb
   `--net-*` flags at create; `doctor`/`reload` need redesign against msb's CLI; full
   verb-by-verb mapping deferred to migration-shape work.

## 5. Preliminary read (NOT the final recommendation)

Evidence so far points at **offer-as-second-primitive, likely-promote-to-default-on-macOS**:
strictly stronger isolation (kernel-per-cage), dissolves in-cage-services, negligible
overhead, image + toolchain carry over intact, and the one breakage (in-guest firewall)
relocates to a stronger host-side enforcement point. Held back from "adopt-as-default"
only by: iron-proxy composition not yet live-tested, virtiofs perf on real repos untested,
msb's beta maturity / bus-factor-2, and the broader landscape round not yet run.

rip-cage's durable differentiation, post-evidence: **the composition manifest + posture
layer + local-first (no vendor account) + substrate integration** — NOT credential
non-possession as a unique feature (sbx shipped it) and NOT the container primitive.
This *strengthens* the dossier §4 thesis: the substrate layer is commoditizing; the value
is the layer above, which ports.

## 6. Next round agenda

- **Broader microVM landscape sweep** (subagent fan-out): Firecracker (KVM-only — matters
  for Linux hosts, not macOS), Cloud Hypervisor, Kata Containers 4.x, krunvm/libkrun
  direct, Apple Containerization framework + `container` CLI, StrongVM/other 2026
  entrants, plus QEMU-microvm. Frame per-candidate: macOS story / Linux story / OCI
  compat / mount + egress semantics / maturity / license.
- **Live iron-proxy composition test** on microsandbox (the §1 cooperative shape).
- **virtiofs perf probe** on a real repo (git status / install / build in-guest).
- Herdr full session smoke (multiplexer behavior under msb TTY semantics).
- Migration-shape sketch: what `rc up` generates for msb; doctor/reload redesign;
  Linux-host story (msb uses KVM there — same UX?).
- Then: final go/no-go + ADR via `/adr-write`, `/adversarial-review` before stamping.

## Appendix: host-side gotchas hit during the spike (macOS 26.3)

- **Docker-signed `sbx` binary froze forever pre-main** (syspolicyd launched-suspended,
  provenance hold keyed to the file *inode*; survives `xattr -d com.apple.quarantine` and
  in-place re-sign). Fix: copy binary to a new inode and swap (`cp sbx sbx2 && mv sbx2
  sbx`). Cask helpers (`libexec/containerd-shim-nerdbox-v1`, hypervisor entitlement) may
  need the same treatment on first VM boot. `vmmap <pid>` saying "launched-suspended" is
  the diagnostic tell; `brew reinstall sbx` restores stock binaries.
- Homebrew tap-trust now gates third-party casks: `brew trust --cask docker/tap/sbx` (and
  `sbx@nightly`) before install.
- microsandbox installer (`get.microsandbox.dev`) is a checksum-verified GitHub-release
  fetcher into `~/.microsandbox` + `~/.local/bin` symlinks; repo org is now
  `superradcompany/microsandbox`.
