# Target repo layout + `rc` decomposition (refactor plan)

**Status: DRAFT (rev.2 — two adversarial-review rounds folded in 2026-07-08; round 1 = F1–F7 below,
round 2 = enumeration fixes in checklist item 2 + 4).** For sign-off before any file moves.
Isolation-agnostic:
this reorganizes *current* rip-cage reality; it does **not** presuppose the post-msb structure (that's
the migration's call — rip-cage-tsf2 + `docs/2026-07-08-msb-migration-partition-map.md`). Safe to do
before the Fable migration review; a clean repo is a *better* substrate for that review than the
current organic sprawl. Built 2026-07-08.

## Why (the friction)
- `rc` is a single **12,866-line bash monolith** — past ~1000 lines a coding agent can't hold the file,
  so every edit is partial-context. Bad design on its own terms, agent-hostile today.
- The **root is a junk drawer**: ~20 loose scripts + config files sitting flat next to a dozen
  single-purpose dirs. Grew organically; no logical grouping.

## The organizing principle (chosen: "by lifecycle")
Top-level split = **does it run on the host (`cli/`) or get baked into / run inside the cage
(`cage/`)**. Rejected alternatives: *flat by-concern* (separates the Dockerfile from the files it
bakes — keeps the COPY-path spaghetti); *by-migration-fate* (hard-codes the current RETIRE/KEEP
partition into the tree, which Fable may move — structure must not bet on it).

Bonus (not a bet): this seam *aligns* with the msb migration seam — `cage/` is the image that boots
unchanged on msb (findings §8b keeps `rc build`), `cli/` is what gets rewired; `cage/egress/` is the
RETIRE bucket as one deletable directory.

**Correction (F7):** `cage/` is the *primary* in-cage runtime, NOT the *complete* baked set. The
Dockerfile also bakes 7 files from `tests/` (Dockerfile:133-135,143-144,153-154) and `bd` from the
go-builder stage (Dockerfile:84), and `tests/` stays at root. **Therefore the `docker build` context
MUST remain the repo root** (`rc` builds with context `$SCRIPT_DIR` = root; rc:311/335/449). Moving
`Dockerfile` into `cage/` is fine, but the build must be invoked `-f cage/Dockerfile` with context =
root, and **every `COPY <src>` inside it becomes root-relative** (`cage/egress/…`, `cage/substrate/…`,
`tests/…`) — not just the moved ones. This is the single biggest execution subtlety.

## Guardrail (from the design conversation)
Decompose **everything** into clean module homes — **including** code slated for deletion (a clean
module is a clean delete, and the partition may shift, so uniform structure is robust). The one thing
NOT to do: **redesign the internals** of RETIRE-bucket code. Clean home yes; polish the logic no.

## Target tree
```
rip-cage/
├── rc                    # thin entrypoint — arg dispatch only; sources cli/*
├── cli/                  # the decomposed rc, one module per verb (sourced by rc)
│   ├── build.sh up.sh exec.sh attach.sh down.sh
│   ├── doctor.sh reload.sh allowlist.sh manifest.sh config.sh
│   └── lib/              # shared helpers (arg-parse, container-naming, logging, …)
├── completions/          # _rc, rc.bash        (stays top-level — conventional)
├── cage/                 # everything baked into / run inside the cage image
│   ├── Dockerfile
│   ├── init/             # init-rip-cage.sh    (substrate projection; KEEP)
│   ├── egress/           # ← THE RETIRE BUCKET, isolated in one dir
│   │   ├── rip_cage_router.py  rip_cage_egress.py  rip_cage_dns.py
│   │   ├── init-firewall.sh    init-mediator.sh
│   │   ├── rip-proxy-start.sh  rip-dns-start.sh
│   │   └── egress-rules.yaml
│   ├── substrate/        # skill-server.py  bd-wrapper.sh  claude-session-wrapper.sh
│   ├── guards/           # dcg/  hooks/  ssh/
│   └── agent/            # settings.json  cage-claude.md  cage-pi.md  zshrc  tmux.conf
├── manifest/             # dist/default-tools.yaml (tool catalog); .rip-cage.yaml (example)
├── packaging/            # Formula/  homebrew-rip-cage/  scripts/
├── examples/  tests/  docs/                    (unchanged homes)
└── README AGENTS CLAUDE CHANGELOG CONTRIBUTING CODE_OF_CONDUCT LICENSE Makefile VERSION .gitignore
```

## File-by-file move table (from → to)
Naming decisions applied: `cage/` (baked-runtime subtree), `egress/` (retire bucket), `rc` stays at
root.

| current | → target |
|---|---|
| `rc` | `rc` (stays; body decomposed into `cli/` — see below) |
| `completions/{_rc,rc.bash}` | `completions/` (unchanged) |
| `rip_cage_router.py` | `cage/egress/rip_cage_router.py` |
| `rip_cage_egress.py` | `cage/egress/rip_cage_egress.py` |
| `rip_cage_dns.py` | `cage/egress/rip_cage_dns.py` |
| `init-firewall.sh` | `cage/egress/init-firewall.sh` |
| `init-mediator.sh` | `cage/egress/init-mediator.sh` |
| `rip-proxy-start.sh` | `cage/egress/rip-proxy-start.sh` |
| `rip-dns-start.sh` | `cage/egress/rip-dns-start.sh` |
| `egress-rules.yaml` | `cage/egress/egress-rules.yaml` |
| `init-rip-cage.sh` | `cage/init/init-rip-cage.sh` |
| `skill-server.py` | `cage/substrate/skill-server.py` |
| `bd-wrapper.sh` | `cage/substrate/bd-wrapper.sh` |
| `claude-session-wrapper.sh` | `cage/substrate/claude-session-wrapper.sh` |
| `dcg/{dcg-guard,default-config.toml}` | `cage/guards/dcg/` |
| `hooks/block-ssh-bypass.sh` | `cage/guards/hooks/block-ssh-bypass.sh` |
| `ssh/{known_hosts.github,ssh_config}` | `cage/guards/ssh/` |
| `settings.json` | `cage/agent/settings.json` |
| `cage-claude.md`, `cage-pi.md` | `cage/agent/` |
| `zshrc`, `tmux.conf` | `cage/agent/` |
| `Dockerfile` | `cage/Dockerfile` |
| `dist/default-tools.yaml` | `manifest/default-tools.yaml` (updates rc:7859-7860 + 2 CI refs — see checklist) |
| `.rip-cage.yaml` | **STAYS AT ROOT (F3)** — this repo's LIVE self-hosting manifest, discovered from CWD/workspace by `rc:1306/6164/11550`; moving it breaks dogfooding. Not an example. (On-disk only — untracked, not in `git ls-files`.) |
| `Formula/`, `homebrew-rip-cage/` | `packaging/Formula/`, `packaging/homebrew-rip-cage/` |
| `scripts/update-formula-sha.sh` | `packaging/scripts/update-formula-sha.sh` |
| `scripts/refresh-github-known-hosts.sh` | `packaging/scripts/refresh-github-known-hosts.sh` (dev tooling for the ssh guard; low-confidence home — could go `cage/guards/ssh/`) |
| `examples/`, `tests/`, `docs/` | unchanged (`tests/` MUST stay at root — baked by Dockerfile, F7) |
| `history/` (40 tracked files, F1) | STAYS AT ROOT, unchanged (design/fixes history; docs-adjacent) |
| `.agents/ .beads/ .claude/ .codex/ .github/` (F2) | STAY AT ROOT, unchanged (`.claude/harness.md` + `.github/workflows/` are load-bearing — see checklist) |
| root project docs, `Makefile`, `VERSION`, `.gitignore`, `.rip-cage.yaml` | unchanged (root) |

## `rc` decomposition
Split the monolith into `cli/` modules by verb-cluster; `rc` becomes a thin entrypoint that parses the
verb and sources the matching module. Shared helpers → `cli/lib/`. The **allowlist** and **doctor**
egress-probe surfaces sit on the two open migration questions (ssh-arrow; §D of the partition map) —
decompose them into modules like everything else, but do NOT redesign their behavior pending Fable.

## Path-coupling checklist (what makes this careful, not trivial — execution MUST satisfy all)
There are **two path classes**, and rev.1 sharpens the earlier framing:
- **(a) In-image baked DEST paths stay constant.** The Dockerfile COPYs to destinations like
  `/usr/local/lib/rip-cage/…`; keep those *destinations* identical, so in-cage runtime `source
  /usr/local/lib/rip-cage/…` and absolute in-cage paths do **not** change.
- **(b) Host-side `$SCRIPT_DIR`-relative SOURCE references in `rc` and infra DO move and MUST be
  updated.** The earlier "only build-time source paths move" line understated this — `rc` itself
  hardcodes several source-tree paths. Enumerated below.

Update together and re-verify:
1. **Dockerfile `COPY` sources + build context (F7).** Build stays context = repo root, invoked
   `-f cage/Dockerfile`. Rewrite every `COPY <src>` root-relative (`cage/egress/…`, `cage/substrate/…`,
   `cage/agent/…`, `cage/guards/…`, `cage/init/…`, `tests/…`); keep every `<dst>` stable. Verify the
   go-builder `bd` copy (Dockerfile:84) and the 7 `tests/` bakes still resolve from root.
2. **`rc`'s `$SCRIPT_DIR`-relative source-file READS (F4) — the load-bearing edit, done by METHOD not
   a frozen line-list** (round 2: a hand list was 1-of-6 wrong AND mis-tagged context args). For each
   moved file, `grep -n '<filename>' rc` and rewrite every ref that **reads the source file** to its
   new subpath (`default-tools.yaml`→`manifest/`, `Dockerfile`→`cage/`, `egress-rules.yaml`→`cage/egress/`).
   **CRITICAL discriminating rule (round-2 F2):** `$SCRIPT_DIR` ALSO appears as the trailing
   `docker build … "$SCRIPT_DIR"` **build-CONTEXT** arg — that MUST stay repo root; do NOT rewrite it.
   Per hit ask: *read of a moved file* (rewrite) or *build-context arg* (leave)?
   Known refs at authoring time (NON-authoritative — re-grep at execution, line numbers drift):
   default-tools.yaml `rc:7859-7860`; `${SCRIPT_DIR}/Dockerfile` READS at `rc:247,253,284,289,429,433,9398`;
   `egress-rules.yaml` READS at `rc:272,3669,3789,4613,6077,10650`; build-CONTEXT arg (LEAVE) at
   `rc:311,335,449`. Some reads sit on verb paths (`rc:6077` allowlist-promote, `rc:10650` IOC-parse)
   the `rc build`/`rc up` smoke won't exercise — so grep-completeness, not the gate, is the safety here.
3. **CI workflows (F5).** `.github/workflows/ci.yml:43` and `release.yml:114` hardcode
   `RC_MANIFEST_GLOBAL=dist/default-tools.yaml ./rc generate-dockerfile` → update to `manifest/…`.
   (CI is NOT run by the local gate — grep the workflows explicitly.)
4. **Homebrew Formula test assertions (F6).** `Formula/rip-cage.rb` asserts moved paths exist under
   `libexec/` (`libexec.install Dir["*"]` preserves tree). Update all three: `:42` `Dockerfile`→
   `cage/Dockerfile`; `:43` `init-rip-cage.sh`→`cage/init/init-rip-cage.sh`; `:44`
   `hooks/block-compound-commands.sh`→`cage/guards/hooks/block-compound-commands.sh`. (`brew test` is
   NOT in the local gate — assert Formula paths explicitly.) **Pre-existing oddity to verify (round-2):**
   `:44` names `hooks/block-compound-commands.sh` but `hooks/` tracks only `block-ssh-bypass.sh` — the
   Formula asserts a file not in the tree. Investigate separately; the restructure must not worsen it.
5. **`rc` → `cli/` sibling sourcing.** New `cli/*.sh` sourced as `${SCRIPT_DIR}/cli/…`; `rc:11-22`
   `_resolve_script_dir` already resolves symlinks (incl. the Homebrew `libexec/` case), so this
   pattern is proven safe — mirror it.
6. **Test path refs.** `tests/` builds `${REPO_ROOT}/<file>` / `${SCRIPT_DIR}/../<file>` in ≥23 places
   for moved files — these self-catch on a red suite (good), but update them in the same pass.
7. **`.gitignore` / packaging manifests / Makefile** naming any moved path.

## Verification gate (EXPANDED — the local gate alone is insufficient, per F3/F5/F6)
The `rc build` + `tests/` suite catches the Dockerfile-COPY and test-ref classes but is STRUCTURALLY
BLIND to three classes the review found. Full gate = all of:
- **`rc build` succeeds** AND **full `tests/` suite green** (the ~234-test behavioral net).
- **Dogfood `rc up` smoke** in the repo root — proves `.rip-cage.yaml` is still discovered (F3; `rc up`
  is on the CI NEEDS_CONTAINER denylist so CI never exercises this — it's local-only).
- **CI-workflow path grep** — assert no workflow still names `dist/default-tools.yaml` (F5).
- **Formula assertion check** — `brew test` (or at minimum assert the Formula's `libexec/…` paths
  match the new tree) (F6).

## Sequence
1. Capture (this doc) + refactor bead `rip-cage-5jp3`. ✓
2. **Adversarial review of THIS plan** — ✓ done, returned REVISE; F1–F7 folded into rev.1 (approach
   validated as sound, findings were additive coupling-catches, not a doomed design).
3. Execute: create dirs, move files, decompose `rc`, update ALL coupling points (checklist 1–7),
   verify via the EXPANDED gate. ← next, on user go
4. Commit as one coherent refactor (structure-only; no behavior change).
