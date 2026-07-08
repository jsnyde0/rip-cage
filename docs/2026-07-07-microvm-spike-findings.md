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

## 1b. Credential non-possession is LIVE-PROVEN native in microsandbox (2026-07-07, round 2)

The single biggest moat question — "does msb do credential-swap, or is that still rip-cage's?" —
is now answered empirically on this machine. **msb ships the entire rip-cage egress+credential
stack as host-side, un-bypassable CLI primitives**, and they work end-to-end against our image:

- `--net-default deny` + `--net-rule "allow@host:tcp:443"` — the destination allowlist
  (already proven §1); replaces `rip_cage_router.py` (the SNI destination router).
- `--tls-intercept` (+ `--tls-intercept-ca-cert/--tls-intercept-ca-key`, custom CA) — a built-in
  host-side TLS MITM proxy; replaces the per-mediator MITM that `init-mediator.sh` stands up
  in-cage with a generated CA.
- `--secret ENV@HOST` + `--on-secret-violation block|block-and-log|block-and-terminate` —
  **credential non-possession**; replaces the `RIPCAGE_MEDIATOR_*` secret channel + the
  placeholder-token-swap the mediator performs.

Live proof (rip-cage:latest, `--secret RC_TEST_SECRET@postman-echo.com`, host env
`RC_TEST_SECRET=SEKRET-VALUE-abc123XYZ`):

| Probe | Result |
|---|---|
| Guest env value | `RC_TEST_SECRET=$MSB_RC_TEST_SECRET` — guest holds a **placeholder**, never the real value |
| Real value in guest? | **Absent** from `env` and from `/proc/1/environ` — the agent cannot read it |
| Swap on bound host | `curl -H "Authorization: Bearer $RC_TEST_SECRET" https://postman-echo.com/get` → echo shows `authorization: Bearer SEKRET-VALUE-abc123XYZ` — msb injected the real value host-side |
| Exfil to wrong host | Same placeholder header to `httpbin.org` (net-allowed, but NOT the secret's bound host) → connection reset (`curl exit 56`), blocked by `--on-secret-violation` |
| Controls | httpbin reachable without the placeholder (exit 0); a plain non-secret header to httpbin passes (exit 0) — proving the block is the secret-scoping firing, not the host being down |

**Architectural consequence:** on msb, rip-cage does **not** compose an in-cage iron-proxy or
mediator at all. `init-firewall.sh` (transparent-redirect), `rip_cage_router.py` (destination
router), `init-mediator.sh` (credential MITM) all collapse into three `msb run` flags enforced
*outside* the guest kernel. This is strictly stronger than today's design: a rooted agent inside
the cage cannot lift the allowlist, cannot read the real secret, and cannot exfiltrate the
placeholder to an unauthorized host. The "iron-proxy composition not yet live-tested" gating item
from §5 is resolved — **in the better direction: there is nothing to compose, because the
substrate provides it host-side.** (msb roadmap issue #769 SOCKS secret-swap is the *next* rung;
the `--secret` HTTP/TLS path is already shipped and works.)

This also **falsifies the last-standing moat claim** from the research dossier (§4: "credential
non-possession — no surveyed competitor documented this"). Two competitors now ship it
(Docker sbx §2; microsandbox here), and msb's is a host-side primitive, not a product feature we'd
be building on top of.

## 1c. virtiofs performance profile on a real repo (2026-07-07, round 2)

Mounted the dotpi repo (211 MB, 4,914 files, 86 git objects) into a cage via `-v host:/workspace`
and timed against a host baseline. The known heavy-IO caveat (#949) is real but bounded:

| Operation | Host | Guest (virtiofs) | Read |
|---|---|---|---|
| `git status` (warm) | ~10 ms | **82 ms** | Fine for interactive use |
| `git ls-files \| xargs wc -l` | ~80 ms | **81 ms** | No penalty (git index, sequential) |
| `find . -type f` (4,914) | ~70 ms | **827 ms** | ~12× — metadata walk tax |
| `grep -rl ADR .` | ~0 ms | **1,772 ms** | Full-tree stat+read walk, slow |
| `tar czf /dev/null .git` | — | **19 ms** | Bulk sequential read: fast |
| write 2,000 small files | — | **1,596 ms** (~1,250 files/s) | Small-file writes are the tax |
| `rm -rf` 2,000 files | — | **5,620 ms** (~2.8 ms/file) | Deletions worst — 3× writes |

**Read:** interactive git and bulk sequential throughput are fine; the tax is per-file metadata
latency (open/stat/unlink) on full-tree walks and many-small-file writes. At this repo size it's a
noticeable-but-usable 1–2 s on `find`/`grep -r`. It would bite hard on a build writing tens of
thousands of files to the mount (an npm install of ~30k files ≈ 24 s of pure virtiofs write, worse
for the delete pass). **Mitigation is architectural, not a blocker:** mount source read-mostly and
keep build output (`node_modules`, `target/`, `.venv`) on VM-local overlay/tmpfs, not on the
virtiofs mount. Untested-at-scale: a 100k-file monorepo, where #949 would be more severe.

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

## 3b. Broader microVM landscape sweep (2026-07-07, round 2 — two subagent surveys)

Two fresh-context surveys (macOS-native candidates; Linux-host candidates). Bottom line:
**nothing surveyed is a stronger bet than microsandbox for our ask** (boot an unmodified OCI image,
host-side domain-pinned egress, fast boot, low RSS, embeddable, local-first), on either host OS.

**macOS-native candidates:**
- **Apple Containerization + `container` CLI** (v1.0.0, 2026-06-09; Apple-backed, OCI-compatible,
  VM-per-container on Virtualization.framework). The **most credible long-term threat** — stable,
  first-party, ecosystem consolidating onto it (CodeRunner/InstaVM, vmette build on it). **But the
  disqualifier today is egress:** no first-party domain-allowlist; maintainers explicitly declined a
  `pf`-based approach (Discussion #719), and the host gateway is reachable from the container network
  (guest-side iptables can't filter it). We'd rebuild our entire smoltcp-equivalent allowlist from
  nothing. Small-file I/O reportedly slower than shared-VM Docker. Worth re-checking in 6–12 months.
- **libkrun / krunvm direct** — this *is* microsandbox's own substrate (HVF on macOS / KVM on Linux).
  Going direct sheds microsandbox's value-add (image handling, snapshot/fork, egress-allowlist crate,
  CLI/SDK) for zero isolation gain. Only interesting as a fallback if msb dies (see bus-factor).
  libkrun is mid-2.0 (API-breaking, pre-stable); stricter virtiofs perms than applehv — test our
  mount patterns.
- **Docker Sandboxes** — the good egress UX (Sandbox Kits: declarative domain allowlist + injected
  creds) is **proprietary, Docker-Desktop-locked**. The OSS piece (`containerd/nerdbox`) is just
  libkrun again, experimental, containerd-shim-shaped (heavier than we need).
- **Tart** — **disqualified**: runs only Tart-built images, not Docker images. Plus the team dispersed
  post-OpenAI-acquisition (April 2026). Its Softnet CIDR allowlist is interesting but CIDR-not-domain.
- **Lima+vz / colima** — VM-per-cage viable but at full-VM cost (seconds, heavy RSS), no microVM-native
  egress primitive. Wrong shape.
- **OrbStack** — still a single shared VM; "extra-isolated machines" is a mode, not per-container
  microVMs. Not a candidate (this is our *current* class).

**Linux-host candidates** (all KVM-only — none run on macOS, so they're a Linux-tier story, not a
laptop story):
- **Firecracker** (AWS, ~125ms boot, <5MB overhead, jailer hardening, built-in rate limiters) —
  battle-tested at Lambda scale, but **no OCI-native boot** (bake ext4 rootfs yourself, E2B-style
  5–15 min template builds) and **no virtiofs** (workspace-mount is a block-device/bake-in hack).
  Highest integration burden.
- **Cloud Hypervisor** (Intel/MS/LF) — like Firecracker but **has virtiofs** and an existing OCI
  bridge to adopt (`cocoonstack/cocoon`). Still KVM-only, still kernel+rootfs assembly.
- **Kata Containers 4.x** — OCI-native via containerd, virtiofs default, but needs a full
  containerd/CRI/CNI stack — heaviest operational burden for a local-first single-host tool.
  Mid-migration to runtime-rs (Rust).
- **QEMU microvm** — x86-only machine type (no aarch64 fast-path), manual OCI bridging.
- **New entrants:** **SmolVM** (Celesto AI, <3mo old, Firecracker-on-Linux/QEMU-on-macOS, built-in
  `allowed_domains` egress — worth watching its allowlist impl); **E2B** (Firecracker incumbent, the
  reference for "how much tooling raw Firecracker needs"); **Morph** (250ms VM-state forking — relevant
  if rip-cage ever wants "fork a running cage"); **cocoon** (CH-based, OCI + snapshot/clone).

**microsandbox bus-factor (concrete):** 2 dominant maintainers (appcypher 366 commits, toksdotdev
133; steep dropoff after). Company = Super Rad Company (rebranded from Zerocore AI), YC X26, cloud in
closed beta. Repo active (pushed today), 6.9k★. **The de-risking fact:** the isolation core is
libkrun (separately governed, healthy, its own org) — msb's *own* code is the smoltcp network/egress
crate + orchestration + SDKs. If Super Rad folds, the fallback is "re-home the network/egress crate
onto raw libkrun," a scoped Rust rebuild — **not** a hypervisor rewrite. That is the correct hedge:
not "switch platforms," but "keep the option to fork the network crate." Our current plan (compose
above msb's CLI) already permits it.

**Linux-host verdict:** "microsandbox on KVM" is the default Linux answer (same libkrun substrate,
UX should carry ~1:1) — worth empirically confirming the KVM path is as dogfooded as the HVF path.
Firecracker/Cloud Hypervisor offer *production-hardening* extras microsandbox lacks (jailer-equivalent
defense-in-depth, mature snapshot/restore, per-device rate limiting) — reasons to keep them in reserve
for a high-multi-tenancy Linux tier, **not** reasons to switch the primitive.

## 4. Spike-question scoreboard (from the bead's five questions)

1. **Can the rc-built image boot with init-firewall + iron-proxy + herdr functioning?**
   Boot: YES, unmodified. herdr: present + runs. init-firewall: FAILS as written
   (xt_owner) — but the whole egress+credential stack relocates host-side and gets
   stronger. iron-proxy composition: **RESOLVED (§1b)** — nothing to compose; msb's
   `--net-default deny` + `--tls-intercept` + `--secret ENV@HOST` provide the destination
   allowlist, TLS-MITM, and credential-swap as host-side un-bypassable primitives,
   **live-proven end-to-end** against rip-cage:latest.
2. **File-sharing semantics + perf:** semantics PASS (identity mapping both ways, rw, ro
   available). **Perf PROFILED (§1c):** interactive git ~80 ms; full-tree metadata walks
   ~10–12× slower (1–2 s on a 5k-file repo); small-file writes/deletes are the real tax —
   mitigated by keeping build output on VM-local storage, not the mount. Not a blocker at
   this repo scale; untested at 100k-file monorepo scale.
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

Evidence now points at **adopt microsandbox as the macOS isolation primitive** (offer-as-second
during a transition, promote-to-default on macOS): strictly stronger isolation (kernel-per-cage),
dissolves in-cage-services, negligible overhead, image + toolchain carry over intact, and the entire
in-cage egress+credential stack relocates to stronger host-side msb primitives (live-proven §1b).
Of the round-1 hold-backs, two are now cleared: iron-proxy composition (resolved — nothing to
compose) and virtiofs perf (profiled — usable with a build-output mitigation). Remaining caveats:
msb's beta maturity / bus-factor-2 (mitigated by the scoped libkrun fallback, §3b), the KVM-path
dogfooding question for a future Linux tier, and herdr full-session TTY smoke (not yet run).

**The moat picture has sharpened, and it is uncomfortable (see the dedicated moat analysis, §7).**
The three things the dossier once listed as differentiators are now substrate-provided or
commoditized: credential non-possession (msb `--secret`, live-proven §1b; also Docker sbx), egress
allowlist (msb `--net-*`), and own-kernel isolation (the whole point of switching). What plausibly
remains rip-cage's is **the layer above the VM**: the reviewable composition manifest
(tools/guards/multiplexers as YAML a human reads before build), per-project config layering, the
`rc` UX, and substrate integration (beads/memories/session-hooks) — i.e. the opinionated
agent-workbench, not the sandbox. That layer ports onto msb intact. The honest risk is that msb's
own roadmap (#970 Sandboxfile manifest, #769 richer secret-substitution, their cloud + SDKs) is
climbing into exactly that layer.

## 6. Round-2 status + remaining agenda

**DONE this round:**
- ✅ Broader microVM landscape sweep — two subagent surveys (§3b). Verdict: nothing beats
  microsandbox for our ask on either host OS; Apple `container` is the long-term macOS threat
  (blocked today on egress); Linux tier = "msb on KVM" default, Firecracker/CH in reserve.
- ✅ Live iron-proxy composition — RESOLVED as "nothing to compose" (§1b): msb's
  `--secret`/`--tls-intercept`/`--net-*` provide the whole stack host-side, live-proven.
- ✅ virtiofs perf probe on a real repo (§1c) — profiled; usable with build-output mitigation.
- ✅ Moat analysis vs msb itself (§7).

- ✅ Herdr full session smoke — PASS under msb via the factory socket-API pattern (§8a); two
  headless gotchas documented (per-session socket path; pane-width needs a sized client).
- ✅ Migration-shape sketch — `rc` verb → msb flag mapping (§8b); MEDIATOR entries map 1:1 to
  `--secret`, egress-rules to `--net-rule`.

**REMAINING before the final go/no-go + ADR:**
- **Strategic product-direction decision (operator's call, §7)** — adopt-msb is settled on the
  isolation axis; the product/moat axis (posture-layer vs substrate-niche vs fold) is the open
  decision that gates what the ADR concludes.
- Interactive sized-client herdr attach via `msb run -t` / `msb ssh` (socket-API path already proven).
- Empirically confirm the msb **KVM/Linux** path is as dogfooded as the HVF/macOS path (future
  Linux tier).
- Then: ADR via `/adr-write`, `/adversarial-review` before stamping.
  Bead acceptance still open pending the explicit adopt/second-primitive/reject recommendation +
  the operator's product-direction steer.

## 7. Moat analysis: rip-cage vs microsandbox itself (2026-07-07, round 2)

The workstream-3 question ("if rip-cage re-platforms onto msb, what UVP survives?") answered
honestly, no sunk-cost. Fresh-context analysis + one verified-against-source crux.

**The headline is uncomfortable: rip-cage's three security headliners are not just matched —
they are architecturally *exceeded*, and the strongest one is actually inferior today.**

- Egress allowlist, TLS-MITM, credential non-possession: all three shipped host-side by BOTH msb
  (`--net-*`, `--tls-intercept`, `--secret`) and Docker sbx. Commoditized (§1b, §2).
- The sharp part — **credential non-possession, verified against ADR-026 line 106:** rip-cage's is a
  **co-located-process-under-a-dedicated-uid** boundary "(not a separate container — keeping it within
  the single cage per ADR-005 D8)"; non-possession is proven by a *cross-uid* `/proc/1/environ` EACCES.
  That is a **uid boundary inside one shared kernel**, not a host/guest boundary. A guest-kernel
  compromise or container escape defeats it. msb keeps the real secret in the **host** process, outside
  the VM — defeating it requires compromising the host. **So re-platforming onto msb is not optional
  hardening; it fixes a genuine weakness in rip-cage's current strongest claim.** The redundant code
  (`rip_cage_router.py`, `rip_cage_egress.py`, `rip_cage_dns.py`, `init-mediator.sh`, the MEDIATOR
  archetype machinery) should be **deleted, not ported** — it becomes objectively inferior to the
  substrate.

**What survives deletion (the thin residual):**
- **Destructive-command guard (DCG)** — but it's a Claude Code/pi PreToolUse hook; ADR-025's own title
  ("host-adoptable DCG policy") concedes it doesn't need a cage. Docker *philosophically rejects* the
  concept ("isolation replaces approval prompts"). The moat is curation + documented hardening, not an
  uncopyable mechanism.
- **ADR-024 prompt-injection threat-model posture** — thought leadership, not defensible IP.
- **Host-substrate projection** (ADR-027: live RO-projection of the user's skills/commands/agents +
  beads task-tracking into the cage) — the **most substantive survivor**, and off-thesis for VM
  vendors (Docker's kit `agentContext` is a static-file analog; msb has nothing). But it is a
  devEx/workflow layer, not security — and arguably doesn't require VM isolation at all.

**Temporary leads (12-month replication risk):** the composition manifest (msb #970 Sandboxfile is
WIP; Docker "kits" already cover ~60% of tools.yaml's ground and ship ~weekly) and per-project config
layering. Resourcing asymmetry is stark: single-operator vs a YC-backed team (~29 releases/3mo) and
Docker (incumbent, acquired microVM team). Any *closable* gap likely closes on their timeline.

**Four strategic options (honest one-liners):**
1. **Posture layer on msb** — delete the egress/credential engine, translate tools.yaml/.rip-cage.yaml
   to msb flags, keep DCG + ADR-024 posture + ADR-027 projection atop msb's stronger isolation. *Most
   defensible near-term; inherits a better boundary for free — but the retained surface is thin and its
   defensibility depends on msb/Docker continuing not to bother.*
2. **Contribute upstream + own the agent-workbench UX** — publish DCG/threat-model as an msb/Docker
   kit, be the agent-safety reference authority. *Reputation, not capture; no obvious revenue model.*
3. **Niche on substrate-integration, drop the sandboxing pitch** — reposition around
   beads/memories/skills-projection ("your workflow, caged"). *Probably the only slice big enough to be
   a standalone product, but a smaller/harder pitch — and plain devcontainers could serve much of it.*
4. **Fold** — adopt msb/Docker directly, upstream the ideas, keep projection as a personal layer.
   *Under a genuine no-sunk-cost lens this is a legitimate live option: the egress/TLS/credential code
   is likely throwaway within 6–12 months regardless, because both competitors already do that job
   better, host-side, today.*

**My synthesis for the ADR (to be adversarially reviewed before stamping):** the *isolation-primitive*
question and the *product-moat* question have now cleanly separated. On isolation: **adopt
microsandbox** — the evidence is decisive and it fixes a real security weakness, not just adds a
feature. On product: the honest position is **option 1 (opinionated posture + substrate-integration
layer on msb)**, entered with clear eyes that the moat is thin and the defensible core is the
agent-workbench/substrate layer (ADR-027 projection + the composition manifest as *reviewable
intent*), NOT the sandbox. The security engineering that this repo has invested most in is the part
that should be retired. That is the no-sunk-cost read.

## 8. herdr session smoke + migration-shape sketch (2026-07-07, round 2)

### 8a. herdr full-session smoke under microsandbox — PASS (with one headless caveat)

herdr 0.7.0 (baked in the image) drives correctly under msb using the **factory pattern**
(socket-API, not interactive attach):

- Server boots headless and **persists across `msb exec` sessions** once properly detached
  (`setsid`+`nohup`+`script -qec` to give the TUI a PTY; a bare `&` dies when the exec returns).
- `herdr --session <name> status server` → running; `pane list` → the pane exists (`w1:p1`).
- `herdr --session <name> pane run w1:p1 "<cmd>"` **submits and executes** (shell ran the command);
  `pane read w1:p1 --source visible` **returns the output** — the exact `pane run`/`pane read`
  primitives dotpi-3bi's drover/herdr automation depends on.
- **Gotcha 1 (socket path):** a `--session <name>` server puts its socket at
  `~/.config/herdr/sessions/<name>/herdr.sock`, NOT the default `~/.config/herdr/herdr.sock`.
  A plain `herdr status` checks the default and falsely reports "not running" — always
  session-target status/pane calls.
- **Gotcha 2 (headless pane width):** with no client attached, the pane defaults to a **~4-column**
  width, so `pane read` returns output hard-wrapped every 4 chars (the sentinel was present but
  looked like `NTIN`/`EL-4`/`2`). This is a herdr headless characteristic, **not an msb break** —
  the spawner must set pane dimensions (attach a sized client, or provide size) rather than rely on
  the default. Worth carrying into the migration: the factory's pane spawner sets dimensions
  explicitly. `resize` is directional-only (client layout), not absolute cols/rows.
- Not yet done: a real sized-client attach via `msb run -t` / `msb ssh` (interactive; blocks a
  non-interactive shell) — confirm interactively before the factory port, but the socket-API path
  (what the automation actually uses) is proven.

### 8b. Migration-shape sketch: `rc` verbs on microsandbox

The image and manifest stay the source of truth; `rc up` shrinks from "docker run + three root-exec
init phases" to "generate msb flags + orchestrate substrate projection."

| rc today | On microsandbox | Notes |
|---|---|---|
| `rc build` (tools.yaml→Dockerfile→image) | **Unchanged** + one-time `docker save \| msb load` (EROFS convert) | image *is* the manifest artifact; msb has no Sandboxfile yet (#970) |
| `rc up`: `docker run --cap-add NET_ADMIN` | `msb run -d` (no NET_ADMIN, no privileged) | isolation is the VM boundary now |
| `init-firewall.sh` (iptables REDIRECT, xt_owner) | **DELETE** → `--net-default deny` + `--net-rule allow@<host>:tcp:443` per `egress-rules.yaml` | host-side, un-bypassable |
| `init-mediator.sh` + MEDIATOR archetype + `RIPCAGE_MEDIATOR_*` | **DELETE** → `--secret ENV@HOST` per manifest MEDIATOR entry (+ `--on-secret-violation block-and-terminate`) | host-side credential swap (§1b) |
| `rip_cage_router.py` / `_egress.py` / `_dns.py` | **DELETE** → msb smoltcp host stack | msb owns SNI/DNS-pin |
| mediator TLS-MITM + generated CA | `--tls-intercept` (+ `--tls-intercept-ca-*`) only if body/header rewrite needed | most `--secret` cases need only header injection |
| `-v /workspace`, `~/.claude` binds (ADR-027 projection) | `-v host:guest` (+ `host-perms=mirror` for uid parity) | keep build output off the mount (§1c) |
| `rc exec` / `rc attach` | `msb exec` / `msb exec -t` / `msb ssh` | TTY + SSH both host-side |
| `rc down` | `msb rm` | |
| `rc doctor` / `rc reload` | **Redesign** against msb CLI (`msb ls`, `msb image list`); reload has no docker-restart analog | msb sandboxes are more ephemeral |
| DCG (PreToolUse hook) | **Unchanged** — baked in image, host-adoptable, substrate-agnostic | ADR-025 |
| beads/memories/hooks (bd-wrapper, `bd prime`) | **Unchanged** — in-image | ADR-002 D10 |

**The clean mapping insight:** the manifest's MEDIATOR entries map 1:1 to `msb run --secret ENV@HOST`
bindings, and `egress-rules.yaml` maps 1:1 to `--net-rule allow@host` flags. So `rc` becomes an
**msb-flag generator + substrate-projection orchestrator** — the composition manifest survives as the
human-reviewable intent that compiles to msb flags instead of to init-scripts. That is precisely the
"posture layer on a commodity runtime" shape (§7 option 1) expressed at the CLI level.

## 9. Interesting-entrant deep dives — SmolVM / cocoon / Morph (2026-07-08)

Three fresh-context source-grounded evaluations, each scored on the same 11 fields against the msb
baseline (does it run on macOS / OCI-boot / virtiofs / **host-side egress allowlist** /
**credential non-possession** / boot+overhead / TTY-exec / snapshot-fork / maturity / integration
burden). **All three reinforce staying on msb; none is a viable substrate.**

- **SmolVM** (CelestoAI, ~3mo old, YC W26) — **NO-GO.** macOS defaults to **QEMU, not HVF/libkrun**
  (~4–7× slower boot than msb), and on that QEMU/macOS path its `allowed_domains` egress control is a
  **documented no-op** (SLIRP user-mode net bypasses host firewalls — their own docs say so). Even on
  Linux/Firecracker the allowlist is IP-based with **no DNS-pinning and no SNI check** (the exact gaps
  msb closes). Credentials are the **structural opposite of non-possession** — injected plaintext and
  persisted into the guest disk (`/etc/profile.d/…`), incl. live Keychain extraction. No unmodified-OCI
  boot (builds an ext4 rootfs). Bus factor worse than msb (~90% one contributor). *Worth noting:* it
  ships turnkey **claude/codex/pi presets** and snapshot/resume — ergonomics msb lacks, but orthogonal
  to the security requirements driving this.
- **cocoon** (cocoonstack, ~4.5mo old, CH-based) — **NO-GO as primary; marginal as a Linux tier.**
  **Linux/KVM-only, confirmed at source** (`lifecycle_darwin.go` stubs every net op to "not supported
  on darwin") — zero macOS path, disqualifying for a local-first Mac tool. **No egress allowlist and no
  credential injection at all** (plain CNI/TAP — same 100%-build-it-yourself burden as raw Cloud
  Hypervisor). Its one genuine edge over msb is **snapshot/clone maturity** (content-addressed snapshot
  registry "Epoch", real CH upstream patches) — but clone has a documented **post-fork IP-conflict
  race** that directly threatens the isolated-fork-per-cage property you'd want it for. Solo maintainer
  (468/472 commits). Re-look only if a Linux-fleet snapshot tier is ever needed.
- **Morph / Infinibranch** (Morph Labs, $57.5M raised) — **DISQUALIFIED as substrate, but steal the
  idea.** **Cloud-only SaaS, no self-host, closed proprietary stack** (custom "MorphVM"/"MorphFS", not
  confirmed Firecracker), no unmodified-OCI boot (nested-docker only), no egress/credential
  agent-safety model — fails local-first outright. **BUT** its differentiator — *fork a running VM
  with full state (incl. DB) in <250ms*, "git for compute" (`clone()`/`merge_selective()` verbs) — is
  a genuinely compelling agent-workflow primitive (branch a cage, try two approaches, keep the winner).
  It is **not a hypervisor trick unique to Morph**: msb/libkrun already advertise snapshot/fork/restore
  (WIP, #250; also cf. `forkd` doing 100-child fork in ~100ms on KVM). **Steal the fork UX; deliver it
  locally on msb — no Morph dependency.**

**Cross-cutting signal (matters for the substrate decision AND the other thread):** every young entrant
is pre-1.0 and effectively single-maintainer — msb's 2 maintainers is *above* median for this field,
and its libkrun core is separately governed (the real de-risk). More strategically: the recurring gap
across the *entire* field is exactly rip-cage's two hardest needs — a **host-side, un-bypassable egress
allowlist (DNS-pinned + SNI-checked)** and **credential non-possession**. **msb is the only surveyed
runtime that ships both host-side.** Two ideas worth carrying regardless of substrate: Morph's
**fork-a-running-cage** UX (deliverable via msb snapshot/fork once matured) and cocoon's
**content-addressed snapshot/golden-image registry** model.

## 10. Original-problem spike: `docker compose up` inside a msb cage (2026-07-08)

The investigation started because a caged agent couldn't run a Postgres+pgvector docker-compose test
suite under shared-kernel OrbStack. **The capability that was impossible before is PROVEN under msb** —
with two operational sharp edges to design around.

**Proven end-to-end:** a msb cage runs a real docker daemon (`docker:dind`, Docker **29.6.1**, cgroup
v2, kernel 6.12.91); `docker pull` works (nested egress to Docker Hub); `docker compose up -d` creates
the network and container; the **Postgres 16.14 + pgvector** service initializes, listens on 5432, and
runs healthy checkpoints — served for 17 minutes. So the own-kernel-per-cage thesis dissolves the
in-cage-services blocker: **DinD + compose + a real DB service work in a cage.**

**Sharp edge 1 — DinD needs block-backed storage, not msb's virtiofs volumes.** docker's default
`overlay2` can't write whiteout files onto virtiofs/overlayfs (`failed to convert whiteout file …
operation not permitted`), and **msb `--mount-named` volumes are virtiofs-backed** (not virtio-blk
ext4). Workaround used for the spike: `dockerd --storage-driver=vfs`. **Production fix:** overlay2 on a
real block device via `--mount-disk <ext4-image>:/var/lib/docker`.

**Sharp edge 2 — vfs I/O latency is severe** (a real but separate issue). Under `vfs`, a Postgres
checkpoint took **4.2s to write 44 buffers** (normally ms). Not a msb gap (`msb exec` is instant); just
a reason not to use vfs. **RESOLVED by §10b** below — block-backed storage removes the need for vfs.

**Boot detail:** msb runs `/init.krun` as PID1 and does NOT auto-run the image entrypoint — hand off to
the daemon with `--init /usr/local/bin/dockerd-entrypoint.sh --init-arg dockerd`. A bare backgrounded
`dockerd &` dies when `msb exec` returns (same reaping as the herdr smoke, §8a).

### 10b. Block-backed rerun — FULLY GREEN, end-to-end (2026-07-08)

Redid the spike with a **disk-kind** msb volume (informed by superradcompany's own `skills` repo — see
§11) and it closes cleanly. Two corrections to the round-1 read:

- **The storage fix is a disk-kind named volume, not `--mount-disk`.** `msb volume create <n> --kind
  disk --size 12G` makes a **raw ext4 virtio-blk** volume; mount it with
  `--mount-named <n>:/var/lib/docker:kind=disk,size=12G` (the `kind=disk,size=` in the *mount spec* is
  required, or msb tries a `dir`/virtiofs mount and conflicts). Result: docker's default **`overlayfs`
  driver on `/dev/vdc` ext4** — no whiteout failure, no vfs. `docker compose up` is fast.
- **The query round-trip hang was NOT storage — it was psql SSL negotiation.** psql's default
  `sslmode=prefer` stalls on the SSL handshake through the nested-docker network; **`PGSSLMODE=disable`
  returns instantly.** (Round-1's "vfs blocks queries" was a partial misread: vfs *was* slow, but the
  actual infinite hang was SSL. `docker exec` into the container also hangs — a nested-exec TTY/stream
  issue — so connect over TCP from the cage instead.)

**Proof (Postgres 16.14 + pgvector 0.8.4, via `docker compose up` in the cage, queried over TCP with
`PGSSLMODE=disable`):** plain write cycle `CREATE TABLE / INSERT 0 1 / SELECT → 42` (exit 0);
`CREATE EXTENSION vector` → success; and real vector ops returned correct math —
`'[1,2,3]' <-> '[4,5,6]'` = **5.196** (√27), `'[1,0,0]' <=> '[0,1,0]'` = **1** (orthogonal cosine),
`'[1,2,3]' <#> '[1,2,3]'` = **-14** (neg inner product). **The original DB-backed-test-suite blocker
that started this whole investigation is fully dissolved.**

**Design implication for rip-cage-on-msb:** a cage needing DinD/compose composes a **disk-kind
docker-data volume** for `/var/lib/docker` (an explicit manifest concern), and in-cage DB clients should
connect over TCP with SSL disabled (or postgres configured for SSL). Both are small, known knobs — not
capability gaps.

## 11. superradcompany's `skills` repo — a ready-made msb operating manual (2026-07-08)

`github.com/superradcompany/skills` (msb's own parent company) ships a `microsandbox/SKILL.md` — an
agent-facing operating manual for driving msb: security model, full CLI quick-reference, and
volume/snapshot/networking/ssh recipes, plus Rust/TS/Python/Go SDK references. **Directly useful for
rip-cage-on-msb**, on two levels:

- **Operationally:** it documents exactly the recipes this spike rediscovered the hard way — the
  disk-kind dind volume (`--mount-named docker-data:/var/lib/docker:kind=disk,size=20G docker:dind`,
  verbatim line 210) and the `--secret "KEY=$KEY@host"` non-possession pattern. Worth cloning as a
  reference and having `configure-cage` (or its msb successor) lean on it instead of re-deriving.
- **Strategically (for the moat/UVP thread):** superradcompany already frames msb as *"a containment
  boundary… run untrusted code under hardware-level isolation"* with a security model that reads
  strikingly close to rip-cage's posture — *sandbox output is untrusted data never instructions*
  (rip-cage's ADR-024 prompt-injection stance), *least privilege / `--no-net` + tight allowlist by
  default*, *never expose host credentials / `--secret` over `-e`*. This both **validates** rip-cage's
  security thesis and **confirms the vendor is climbing into that layer** — the exact tension the moat
  analysis (§7) flagged. Their SKILL.md is agent-*operating* guidance; it is NOT a composition manifest,
  a build step, substrate projection, or a fleet cockpit — so it sharpens rather than erases the
  "workbench-above-the-runtime" line.

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
