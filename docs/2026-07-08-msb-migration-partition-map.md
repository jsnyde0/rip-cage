# msb migration — codebase partition map (RETIRE / KEEP / REFACTOR / UNSURE)

**Status: DRAFT / pre-Fable.** Companion to the migration epic **rip-cage-tsf2** and to
`docs/rip-cage-on-msb-direction.md` (product direction) + `docs/2026-07-07-microvm-spike-findings.md`
(§8b verb→flag map is the enforcement-side sketch this file partitions the *code* against).
Built 2026-07-08 from a full-tree inventory pass. **This is a planning artifact, not a set of
applied changes** — no code has moved. It should get the same Fable review pass as the migration
epic (a clean partition is far cheaper to adversarially check than raw code, and two of its calls
are genuinely unadjudicated — see §D).

Purpose: (1) tell current-dev what is load-bearing vs. dead-code-walking; (2) give the migration a
blueprint so removal is a clean amputation, not surgery through entangled code; (3) hand Fable a
pre-digested map with the real design questions isolated.

---

## A. The one structural fact that dominates everything

**`rc` is a single 12,866-line monolithic bash script** holding every verb (`build`, `up`, `exec`,
`attach`, `down`, `doctor`, `reload`, `allowlist`, `manifest`, `config`, …). It cannot be bucketed as
one atom: internally it is ~half survivor-orchestration (build/manifest/config/substrate) and ~half
dying-engine-orchestration (firewall/mediator/router lifecycle — ~348 egress/firewall refs, ~264
mediator refs). The migration's *core work* is a **function-level split inside `rc`**, not a
file-level move. Same shape (survivor logic wearing a firewall coat) for `Dockerfile` and
`init-rip-cage.sh`. This is why "just delete the retire files" understates the job.

## B. The partition

### RETIRE — superseded by msb host-side primitives; delete, don't port
- `rip_cage_router.py` (SNI/dest router) → msb `--net-default deny` + `--net-rule` (smoltcp host stack)
- `rip_cage_egress.py` (`decide()` policy engine) → policy moves host-side to `--net-rule`
- `init-firewall.sh` (iptables REDIRECT/uid-owner) → xt_owner breaks under libkrun anyway; → `--net-*`
  — **caveat: it also hosts the ssh-allowlist library `rc` still calls live. See §C.**
- `init-mediator.sh` + the MEDIATOR archetype → `--secret ENV@HOST` + `--tls-intercept`
- `rip_cage_dns.py` + `rip-dns-start.sh` (DNS-query-shape exfil guard) → **DNS-exfil spike (findings
  §12, 2026-07-08) proved msb refuses non-allowlisted DNS queries at the resolver *before* egress,
  live on the wire — strictly dominates the guard's forward-clean/block-shaped heuristic on the
  deny+allowlist default. Delete is a security improvement. Residual: loses the guard's structured
  agent-actionable denial logging (`egress-dns.log` fix-hints) — a DevEx loss, not a containment loss.**
- `rip-proxy-start.sh` (wrapper for the retired router)
- `examples/iron-proxy/*`, `examples/mitmproxy/*`, and their compose recipes → mediator/MITM
  composition superseded by `--tls-intercept` / `--secret`
- ~16 engine tests (`test-egress-*`, `test-firewall-tcp22`, `test-mediator-*`, `test_egress_proxy`,
  `test-denylist-*`, `test-secret-path-denylist`) → die with the engine they cover
- Dockerfile fragments that exist *only* for the above: `apt install iptables`, `useradd rip-proxy`,
  the `COPY` of the retired scripts

### KEEP — survives ~as-is (isolation-independent)
- `dcg/dcg-guard` + `dcg/default-config.toml` — DCG (destructive-command guard), configured as a TOOL
- `bd-wrapper.sh`, `skill-server.py` — beads + skill substrate projection
- `claude-session-wrapper.sh` — per-session agent config isolation
- `dist/default-tools.yaml` — the composition manifest / tools catalog (mediator/egress *entries*
  get pruned, but the artifact survives)
- Image env + agent guidance: `settings.json`, `zshrc`, `tmux.conf`, `cage-claude.md`, `cage-pi.md`
- Distribution: `Formula/`, `homebrew-rip-cage/`, `scripts/update-formula-sha.sh`
- Docs (rewritten in content where they describe retired machinery, but not code)

### REFACTOR — survives, but the msb move changes it
- `rc` — survivor CLI; `up` becomes an msb-flag generator, `down`→`msb remove`, `exec/attach`→
  `msb exec/-t/ssh`; **the firewall/mediator/router/allowlist lifecycle orchestration is gutted from
  the inside** (this is the function-level split of §A); `doctor`/`reload` need redesign vs. the msb CLI
- `Dockerfile` — image still the artifact (`rc build` unchanged, boots on msb); strip the
  retire-only packages/user/COPYs
- `init-rip-cage.sh` — its **bulk is survivor substrate-projection**; only the `firewall-env`
  sourcing + firewall-phase coupling drops (see §C — survivor logic buried in a dying pipeline)
- `egress-rules.yaml` + `.rip-cage.yaml` (`network.allowed_hosts`, mediator posture) — **survivor
  INTENT-data**, not dead: §8b maps them 1:1 to `--net-rule` / `--secret`. Only the *enforcement
  mechanism* dies; the human-reviewable posture is exactly what rip-cage owns. The flag-generator
  that reads them is net-new code (every *current* reader is on the retire list).
- `completions/_rc`, `rc.bash` — follow the `rc` verb changes

### UNSURE — genuine design calls, do NOT auto-bucket (Fable adjudicates — §D)
- The **ssh-arrow cluster**: `hooks/block-ssh-bypass.sh`, `ssh/known_hosts.github`, `ssh/ssh_config`,
  `scripts/refresh-github-known-hosts.sh` — fate follows whether the cage's host-ssh
  agent-forwarding "arrow" model persists under msb host-side networking.
- `clawpatrol` recipe (`examples/compose-rc-with-clawpatrol.md`) — the ONE mediator-class capability
  msb may not replace: **method/path-aware egress rules**, which a destination router / `--net-rule`
  can't express and `--tls-intercept` only reaches "if body/header rewrite." Possibly the sliver of
  the security engine that *survives at the higher altitude* the earn-its-keep guardrail cares about.
- `rc allowlist` verb + `rc doctor`'s egress-probe — survivor-CLI surface whose reason-to-exist
  largely evaporates; may *disappear* rather than refactor (depends on the ssh-arrow + DNS calls).
- ~170 unclassified test files (fixtures, safety-stack, scratch-cage, image-drift) — not individually
  read; classify during decompose.

## C. Cross-bucket entanglements — the actual migration work

Survivor code that imports/hard-depends on dying code. These are where "delete the retire files"
breaks something the CLI still calls:

- **`init-firewall.sh` is not purely firewall.** `_get_tcp22_allowed_ips` (the ssh-allowlist
  resolver) lives *inside* the retire-listed script and is **`source`d live by `rc allowlist` and
  `rc reload`** (rc:4000). Deleting the file naively drops ssh-allowlist resolution the CLI depends
  on. → extract the survivor library before the file dies.
- **`init-rip-cage.sh` is mostly survivor.** The substrate-projection body (link host
  skills/commands/agents, pi-substrate, beads-mode) is pure KEEP, but it's gated behind
  `source /etc/rip-cage/firewall-env` and runs in the same root-exec chain as the dying
  firewall/mediator phases. → decouple projection from the firewall phase.
- **`rc` → retire scripts:** `_up_init_firewall` / `_up_init_mediator` root-exec them on create+resume
  (rc:4069, 4318); `_rip_bounce` pkill/restarts router+dns on reload (rc:4050); `cmd_doctor` probes
  `pgrep rip_cage_router.py` (rc:7015); `cmd_manifest` validator enforces the `network.egress.mediator`
  field (rc:5344, 8790).
- **`Dockerfile` → all 7 retire scripts + iptables + rip-proxy user** (lines 30, 114, 145-164).
- **`egress-rules.yaml`'s only readers are all on the retire list** — the intent-data survives, its
  consumers don't; the msb flag-generator is therefore new code, not a port.

## D. The design calls Fable must resolve before decompose

(The DNS-exfil-guard question is now **RESOLVED** — findings §12 spike proved msb closes the channel
at the resolver; `rip_cage_dns.py` is a clean RETIRE. Two calls remain.)

1. **ssh-arrow model** — does the cage's host-ssh agent-forwarding + filtered-known_hosts arrow
   persist under msb host-side networking, or dissolve? Decides the fate of the whole ssh cluster +
   `rc allowlist`.
2. **method/path egress (clawpatrol)** — is method/path-aware exfil control in-scope for rip-cage
   post-msb (a genuine survivor of the "security engine" at manifest altitude), or dropped?

## E. What this implies for prep-refactoring (the question that started this)

The safe, earn-its-keep prep is **decoupling survivor code from dying code along the §C seams** — NOT
improving the dying engine, and NOT redesigning the survivor layer.

- **Safe-regardless now:** extract the substrate-projection body out of `init-rip-cage.sh` (it
  survives under *every* resolution of the §D questions). Low-risk, helps current dev, and pre-clears
  the pipeline for msb.
- **Higher-value but sequence after §D:** the `rc` monolith decomposition (§A) and the
  `init-firewall.sh` ssh-allowlist extraction. Their cleanest seams run *through* the UNSURE design
  calls (allowlist verb, ssh-arrow, DNS guard) — refactoring before those land risks doing it twice.
- **Do NOT** run a broad `/improve-codebase` over the tree: ~half of it (the RETIRE bucket) is about
  to be deleted; polishing it is wasted and entrenches code we want gone.

## F. Coverage / what's not yet done
- The **function-level KEEP-vs-RETIRE split inside `rc`** (the 12.8k-line body) is mapped by
  command-dispatch + coupling-grep only, not line-by-line. That split *is* the migration's core and
  needs a dedicated pass (decompose-time).
- ~170 test files classified by filename pattern, not read.
- ADR bodies (024/025/026/027) not re-read here; bucket reasoning leans on the direction/findings
  framing of them + tsf2's DNS carve-out. Fable should reconcile against ADR text.
- `dist/default-tools.yaml` (89KB) bucketed KEEP structurally; its individual entries (some
  mediator/egress recipes that prune) not enumerated.
