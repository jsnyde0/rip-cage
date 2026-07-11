# msb migration — per-file test classification (RETIRE / KEEP / REFACTOR / UNSURE)

**Bead:** rip-cage-hdcl. **Date:** 2026-07-11. **Status:** classification artifact (pure read; no code moved).

Discharges the per-file read that the pattern-only partition map
(`docs/2026-07-08-msb-migration-partition-map.md` §B) explicitly deferred (§F: "~170 test
files classified by filename pattern, not read"). Every `tests/test-*.sh` and `tests/test_*.py`
file was **read** against the rubric below; the golden-master net (`tests/golden-master/`) is one
row-group. Rubric per bead DESIGN, anchored to ADR-029 D2/D3 (engine + ssh deletion), ADR-021
(config), ADR-022 (ssh allowlist, retired), ADR-023 (mount denylist, KEEP).

Buckets: **RETIRE** (assertion target is the in-guest engine ADR-029 D2/D3 deletes — iptables/nft,
rip_cage_router/egress/dns, mediator archetype, init-firewall phases, ssh cluster); **KEEP**
(isolation-primitive-independent: config/manifest semantics, mount denylist, container naming, JSON
shapes, host-side CLI that never reaches a real daemon); **REFACTOR** (behavior survives, mechanics
re-platform — sub-tag: `exec` docker exec to msb exec, `stub` fake-docker PATH shim to msb-CLI stub,
`fixture-image` docker build to docker save + msb load, `lifecycle` up/down/destroy/resume to msb
create/remove/snapshot-amend); **UNSURE** (genuine design call for Fable).

Tie-breaks applied: a file mixing engine assertions AND surviving behavior is **REFACTOR + split
note**, never RETIRE. `NC?` = NEEDS_CONTAINER per the driver denylist (run-host.sh:36-56, 21
entries) — strict denylist membership; factual container need for unwired/self-skip files is noted
in the reason. `par?` = parity-relevant (yes iff KEEP or REFACTOR). `pres?` = presence-assertion
flag (asserts a rule/flag/mount-arg PRESENCE as a behavior proxy rather than the runtime effect —
the fail-open defect class, bd memory `rip-cage-firewall-rule-presence-not-enforcement`).

---

## 1. Per-file table

### RETIRE (19)

| file | reason (one line) | evidence | NC? | par? | pres? |
|---|---|---|---|---|---|
| test-egress-firewall.sh | in-cage SNI destination-router egress checks — the engine D2 deletes | :2 "pure destination router" | no1 | no | no |
| test-firewall-tcp22.sh | asserts iptables ACCEPT/DROP TCP-22 rules + `_get_tcp22_allowed_ips` in init-firewall.sh | :8,:13 iptables rules | no | no | **yes** |
| test-mediator-lifecycle.sh | `_up_init_mediator` + init-mediator.sh launch seam — MEDIATOR archetype deleted (D2) | :9 "_up_init_mediator + init-mediator.sh" | no | no | no |
| test-mediator-manifest.sh | MEDIATOR-archetype manifest validation — archetype deleted (D2) | :2 "MEDIATOR archetype manifest" | no | no | no |
| test-mediator-validator.sh | MEDIATOR hook-bounds validator (RIP_CAGE_EGRESS/iptables/nft in hooks) — archetype deleted | :8-9 "RIP_CAGE_EGRESS ... iptables/nft" | no | no | no |
| test-selftest-classifier.sh | classifies the iptables-REDIRECT-to-proxy startup self-test — self-test deleted (D2, re-homed to msb effect probe) | :6-7 ENFORCED/BYPASSED probe | no | no | no |
| test-selftest-integration.sh | init-firewall.sh to curl to iptables REDIRECT to proxy end-to-end | :4-5 "init-firewall.sh ... real iptables REDIRECT" | no1 | no | no |
| test-selftest-mode-gating.sh | startup self-test mode-gating (block/observe/legacy) — self-test + observe-mode deleted (D2/D4) | :5-8 mode-gating ENFORCED | no | no | no |
| test-ssh-allowlist.sh | SSH host+key allowlist, filtered known_hosts (ADR-022) — ssh cluster retires (D3) | :2 "SSH host + key allowlist (ADR-022)" | no | no | no |
| test-ssh-bypass-demotion.sh | block-ssh-bypass.sh hook — named in D3's ssh-cluster retirement list | :10 "block-ssh-bypass.sh absent from baked hooks" | no | no | no |
| test-ssh-config.sh | SSH identity-routing / host-config translation (ADR-020) — ssh cluster retires (D3) | :2 "SSH identity routing (ADR-020)" | no | no | no |
| test-ssh-forwarding.sh | ADR-017 ssh agent-forwarding default — asserts the agent socket is mounted, label set, sentinel written | :2-4 forwarding surfaces | **yes** | no | **yes** |
| test-ssh-preflight.sh | in-cage github.com ssh preflight plus sentinel writer (ADR-020) — ssh cluster retires | :2 preflight + sentinel | no | no | no |
| test-ssh-resolver.sh | four-layer github ssh identity resolver — ssh cluster retires (selection SHAPE informs the successor identity-selection design, net-new) | :2,:6 four-layer resolver | **yes** | no | no |
| test-ssh-visibility.sh | ssh github-identity banner / rc ls GH-IDENTITY col / init echo — ssh cluster retires | :5-7 sentinel banner surfaces | no | no | no |
| test_dns_decide.py | rip_cage_dns.py `dns_decide()` sidecar — deleted (D2; §D DNS question RESOLVED to clean RETIRE) | :3 "rip_cage_dns.py — DNS resolver sidecar" | no | no | no |
| test_dns_seam.py | network.dns.forward_to specialist seam — DNS sidecar deleted (D2) | :3-6 "DNS forward-to-specialist seam" | no | no | no |
| test_egress_proxy.py | rip_cage_egress.py `decide()` destination router — deleted (D2) | :3 "rip_cage_egress.py — pure destination router" | no | no | no |
| test_selftest_endpoint.py | self-test reserved endpoint inside rip_cage_egress.py — deleted (D2) | :3 "self-test endpoint in rip_cage_egress.py" | no | no | no |

1 not in the driver denylist (wired non-denylist or in-cage), but factually requires a live
cage/iptables; NC=no is strict denylist membership only.

### KEEP (58)

| file | reason | evidence | NC? | par? | pres? |
|---|---|---|---|---|---|
| test-agent-readability.sh | host-side agent-*.md readability classifier (pure bash, no docker) | :2-3 "host-side fixture tests" | no | yes | no |
| test-allowed-roots-bypass.sh | validate_path / allowed-roots regression (host-side, ADR-003/023) | :3-4 "validate_path ... realpath" | no | yes | no |
| test-attach-exec-errors.sh | attach/exec argv error matrix — host-side, container-free | :2-6 "host-side ... error matrix" | no | yes | no |
| test-auth-refresh.sh | host-side keychain-extraction + cmd_auth_refresh logic | :4-5 "rc auth refresh ... helper extraction" | no | yes | no |
| test-auto-seed.sh | rc up auto-seed of global config (config layer) | :2-8 "auto-seed of global config" | no | yes | no |
| test-bd-host-preflight.sh | `_bd_host_preflight` dolt-server preflight (beads substrate, host-unit) | :2 "host-unit, no docker" | no | yes | no |
| test-bd-roundtrip.sh | bd CLI roundtrip (beads substrate) | :2-4 "bd CLI roundtrip" | no | yes | no |
| test-bd-wrapper.sh | bd-wrapper.sh host-side units (beads substrate, KEEP §B) | :2 "bd-wrapper.sh" | no | yes | no |
| test-code-review-fixes.sh | host-side source-content assertions (json_error, cmd_up/ls bodies) | :12-18 grep source shapes | no | yes | no |
| test-completions.sh | rc completions + rc setup shell syntax (host-side CLI) | :2 "rc completions and rc setup" | no | yes | no |
| test-config-loader.sh | layered .rip-cage.yaml merge semantics (ADR-021 — explicit KEEP) | :2 "config loader (ADR-021)" | no | yes | no |
| test-container-name.sh | container_name() collision-hash disambiguation (naming, host-side shim) | :2-3 "container_name() collision-hash" | no | yes | no |
| test-dcg-demotion.sh | dcg-as-recipe Dockerfile structural greps (DCG survives §B; image artifact survives) | :2-11 "dcg demoted ... composable recipe" | no | yes | no |
| test-dcg-policy.sh | DCG host-adoptable policy config/merged-config (ADR-025, host-side) | :2 "DCG host-adoptable policy" | no | yes | no |
| test-denylist-matching.sh | `_check_secret_path_denylist` component-match (ADR-023 — explicit KEEP; §B mis-bucketed) | :2 "_check_secret_path_denylist (ADR-023)" | no | yes | no |
| test-dg6.2.sh | --dry-run + input hardening + agent context (host CLI, no container) | :8-9 "WITHOUT requiring Docker" | no | yes | no |
| test-dockerfile-sudoers.sh | Dockerfile sudoers-pin + pre-created dirs (image artifact + in-guest floor survives D2) | :2-3 sudoers/pre-created dirs | no | yes | no |
| test-doctor-version-skew.sh | `_doctor_bd_version_compare` pure string logic (host-only; bd pin matters D7) | :2 "pure string logic ... host-only" | no | yes | no |
| test-extract-credentials.sh | keychain-extraction warning gating (host-side) | :2-9 "keychain-extraction warning" | no | yes | no |
| test-generate-dockerfile.sh | rc generate-dockerfile structural (image artifact + verb survive) | :2-8 "rc generate-dockerfile" | no | yes | no |
| test-golden-master-sandbox-isolation.sh | GM_ROOT per-process uniqueness — meta-test of the harness sandbox (isolation-independent) | :2-4 "golden-master sandbox ... GM_ROOT" | no | yes | no |
| test-json-output.sh | --output json shapes (explicit KEEP; no container) | :8-9 "JSON output ... without ... containers" | no | yes | no |
| test-lfs-warning.sh | LFS pointer-stub detection via dry-run (ADR-014 D4, transport-agnostic — explicit survive) | :2-3 "LFS pointer-stub ... no docker" | no | yes | no |
| test-manifest-agent-mail.sh | IN-CAGE-DAEMON manifest fixture semantics (T1 host-only dominant; T2 e2e needs fixture-image+exec) | :6-8 archetype validation | no | yes | no |
| test-manifest-cm.sh | cm from-source manifest worked example (T1 host-only; e2e self-skips) | :2-5 "manifest worked example" | no | yes | no |
| test-manifest-cross.sh | cross-cutting manifest regressions (byte-for-byte default Dockerfile, floor intact) | :2-4 "Cross-cutting manifest regression" | no | yes | no |
| test-manifest-daemon.sh | IN-CAGE-DAEMON codegen/lifecycle (archetype survives; e2e note) | :3-4 "IN-CAGE-DAEMON archetype" | no | yes | no |
| test-manifest-herdr.sh | herdr TOOL/MULTIPLEXER manifest fixture (T1a-g host-only; T2 e2e is a deferred build-heavy mux test) | :2-5 "herdr TOOL manifest fixture" | no | yes | no |
| test-manifest-mount-mode.sh | per-asset ro/rw + root_owned validator schema (ADR-027 D1 survives; mount-arg gen re-platforms — note) | :2-3 "per-asset ro/rw mount mode" | no | yes | no |
| test-manifest-mounts.sh | manifest mounts {host,dest} schema + denylist (ADR-023) | :2-3 "manifest mounts ... schema" | no | yes | no |
| test-manifest-multiplexer-validate.sh | MULTIPLEXER manifest validation (archetype survives) | :2 "MULTIPLEXER archetype manifest validation" | no | yes | no |
| test-manifest-reconcile-verb.sh | rc manifest reconcile verb (backup-before-overwrite, host-side CLI) | :2-8 "rc manifest reconcile" | no | yes | no |
| test-manifest-schema.sh | tool-manifest schema loader/validator (explicit KEEP: manifest semantics) | :2 "tool manifest schema loader" | no | yes | no |
| test-manifest-security.sh | binary-root-owned + build-isolation (in-guest floor survives D2; host-only dominant, e2e note) | :6-10 "binary-root-owned" | no | yes | no |
| test-manifest-seed-drift.sh | manifest seed-drift detection + reconcile (host-side CLI) | :2-4 "manifest seed-drift" | no | yes | no |
| test-manifest-shell.sh | SHELL-INTEGRATION shell_init codegen (host-only T1) | :2-3 "shell_init eval-line baking" | no | yes | no |
| test-manifest-source.sh | from-source builder-stage schema + codegen (ADR-005 D6/D11) | :2-4 "from-source builder stage" | no | yes | no |
| test-manifest-tool-init-hook.sh | TOOL 'init' boot-hook codegen seam (host-only T1) | :2-4 "TOOL archetype 'init' ... boot-hook" | no | yes | no |
| test-manifest-tool.sh | TOOL install-step codegen (host-only T1 dominant) | :2 "TOOL archetype install-step generation" | no | yes | no |
| test-mount-seam-integration.sh | codegen seam: arbitrary TOOL composes through generate-dockerfile (Tier-1 host-side dominant) | :6-10 "Codegen seam" | no | yes | no |
| test-multiplexer-config-dynamic.sh | session.multiplexer dynamic config-validate from baked registry (host-only) | :5-7 "derives dynamically from ... registry" | no | yes | no |
| test-multiplexer-registry-bake.sh | rc build bakes multiplexer registry + label (build codegen; host-only T1) | :2-5 "bakes MULTIPLEXER ... registry" | no | yes | no |
| test-pi-cold-start-seed.sh | pi auth cold-start seeding (host-side, temp HOME; pi possession survives D5) | :2-5 "pi auth cold-start seeding" | no | yes | no |
| test-pi-recipe-lifecycle.sh | pi-recipe manifest ownership + init-rip-cage de-pi audit (host-side) | :2-8 "pi-recipe full-lifecycle ownership" | no | yes | no |
| test-pi-wrapper-glob.sh | manifest launch_args assembly, generic-shim invariant (host-side grep) | :2-8 "manifest launch_args assembly" | no | yes | no |
| test-rc-install.sh | rc install idempotency + reinstall-guard matrix (installer host CLI) | :2-6 idempotency | no | yes | no |
| test-rc-source-isolation.sh | sourcing rc must not impose strict-mode on the caller (source-hygiene meta-test) | :5-6 source hygiene | no | yes | no |
| test-rc-commands.sh | rc build/CLI helper surface (host-side; no engine assertions on read) | :8 "rc build commands and helpers" | no | yes | no |
| test-rc-decomposition-structure.sh | rc module-split structural invariants (code-organization meta-test) | :2-3 "post-split structural harness" | no | yes | no |
| test-rc-setup.sh | rc setup idempotency (shell completions host CLI) | :2-6 "rc setup IDEMPOTENCY" | no | yes | no |
| test-secret-path-denylist.sh | ADR-023 denylist plumbing integration (explicit KEEP + survives in D2 floor; §B mis-bucketed as RETIRE) | :2 "ADR-023 denylist plumbing" | no | yes | no |
| test-security-hardening.sh | dot-env symlink + allowed-roots + denylist (host-side path validation; no real docker) | :22-26 symlink-outside-roots | no | yes | no |
| test-skill-manifest-author.sh | repo-shipped skill well-formed + cm example passes _manifest_validate (host-only) | :2-6 "skill is well-formed" | no | yes | no |
| test-symlink-follow.sh | mounts.symlinks scanner + denylist gating (ADR-023; host-side; mount-arg synth re-platforms — note) | :5-10 "_collect_dangling_symlinks" | **yes** | yes | no |
| test-up-validate-warning-seam.sh | RC_VALIDATE_WARNING write-to-read seam (host-side validate_path to json) | :2-5 "validate_path to _up_json_output seam" | no | yes | no |
| test-workspace-trust.sh | workspace settings.json base-URL redirect validator (ADR-024 injection defense, host-side) | :2,:11 "base-URL redirect validator; no Docker" | no | yes | no |
| test-worktree-support.sh | git worktree detection (host-side source grep over cli/up.sh) | :6-9 "worktree-detection source" | no | yes | no |
| test_skill_server.py | skill-server.py MCP shim units (KEEP §B: skill substrate) | :3 "skill-server.py - MCP shim" | no | yes | no |

### REFACTOR (38) — behavior survives, mechanics re-platform

| file | sub-tag | reason / split note | evidence | NC? | par? | pres? |
|---|---|---|---|---|---|---|
| test-agent-cli.sh | lifecycle | full rc up/attach/exec/down lifecycle to msb create/exec/remove | :2,:18 "rc up container" | **yes** | yes | no |
| test-agent-mail-concurrent.sh | fixture-image+exec | two live pi agents via am CLI; agent_mail fixture image + docker exec | :18-20 fixture image + am CLI | **yes** | yes | no |
| test-cc-dcg-managed-settings.sh | exec | DCG managed-settings enforcement survives; needs live authed cage + docker exec claude -p | :4-9 managed-settings enforce | **yes** | yes | no |
| test-cc-managed-settings-probe.sh | exec | CC managed-settings anchor probe survives; live cage + docker exec | :4-6 managed-settings probe | **yes** | yes | no |
| test-claude-concurrency.sh | exec | per-session Claude config isolation survives; live cage exec | :4 "per-session Claude config isolation" | **yes** | yes | no |
| test-claude-json-seed-synthesis.sh | lifecycle | init-rip-cage R4 seed synthesis survives; real docker-stop + rc-up resume | :4-5,:17 "docker-stop + rc-up resume" | **yes** | yes | no |
| test-config-init.sh | (split) | config-init/build_yaml survive; SPLIT: ssh-host detect cases C1-C7 retire with ssh cluster (D3) | :7-13 detect_ssh_hosts | no | yes | no |
| test-config-ro-mount.sh | lifecycle | .rip-cage.yaml ro shadow-mount survives (ADR-021 D7) to msb mount syntax; label-lock re-binds to msb metadata (ADR-028) | :5-7 shadow-mount :ro in run args | no | yes | **yes** |
| test-credential-mounts.sh | lifecycle | per-tool credential-mount posture (ADR-026 D7) survives to msb injection/mounts; asserts mount-arg presence/absence | :11-16 mount present/absent | no | yes | **yes** |
| test-docker-daemon-hang.sh | stub | fail-loud-on-wedged-backend survives; fake docker-info PATH shim to msb-CLI stub | :7-10 fake docker on PATH | no | yes | no |
| test-doctor-dead-mount.sh | stub | dead-handle detection survives; stubbed docker inspect/exec to msb (virtiofs single-file behavior re-verify) | :2-7 "dead-handle detection bind mounts" | no | yes | no |
| test-doctor-runnability.sh | lifecycle | rc doctor cwd/workspace probes survive; spins live cages (rc up + docker run) | :6-7 "spins real cages via rc up" | **yes** | yes | no |
| test-dry-run-resume-guards.sh | lifecycle | resume-guard parity survives; resume semantics to msb snapshot/recreate | :2-8 resume guard set | no | yes | no |
| test-e2e-lifecycle.sh | lifecycle | rc up/down/destroy + regression guards to msb create/remove | :2 "rc up/down/destroy" | no1 | yes | no |
| test-image-drift-resume.sh | lifecycle+stub | resume image-drift guard survives; docker PATH-shim to msb; image-ID to msb image | :2-6 "blind-resuming stale image" | no | yes | no |
| test-ls-mode-source.sh | (split) | "ls reads live source not stale label" survives; SPLIT: observe/block network.mode (M1/M2) retire with observe-mode (D4) | :4-10 mode from .rip-cage.yaml | no | yes | no |
| test-manifest-egress.sh | config-to-net-rule | manifest egress declaration is survivor INTENT-data to --net-rule; build/up-time IOC floor mechanics change | :2-6 "manifest-declared egress floor" | no | yes | no |
| test-mount-mode-e2e.sh | exec | real-cage ro/rw behavioral effect survives to msb virtiofs ro/rw; live cage exec | :2-6 "real-cage RC_E2E" | **yes** | yes | no |
| test-multiplexer-agent-e2e.sh | exec | pi agent works through mux survives; docker exec send-keys to msb exec | :9 "docker exec tmux send-keys" | **yes** | yes | no |
| test-multiplexer-composable.sh | exec | fakemux composability survives (G1 host-only greps stay); E1 e2e to msb exec/lifecycle | :5-7 fakemux full lifecycle | **yes** | yes | no |
| test-multiplexer-lifecycle.sh | exec+lifecycle | mux lifecycle none/tmux/herdr survives; live cage to msb (deferred build-heavy mux test) | :4-10 "parameterized over session.multiplexer" | **yes** | yes | no |
| test-pi-auth-mount.sh | exec | pi possession-mode auth.json mount survives (D5); docker mount+exec to msb virtiofs | :6-9 auth.json mounted+readable | **yes** | yes | no |
| test-pi-cage-context.sh | exec | cage-pi CLAUDE.md substrate projection survives (init-rip-cage); live-cage inspect to msb exec | :6-9 CLAUDE.md topology fence | **yes** | yes | no |
| test-pi-e2e.sh | exec+lifecycle | pi -p smoke survives; rc up + docker exec to msb | :2 "pi -p smoke test inside rip-cage" | **yes** | yes | no |
| test-pi-install.sh | exec+fixture-image | pi TOOL recipe install + dir pre-create survive; docker run image to msb load/exec | :4-10 "docker run rip-cage:latest" | **yes** | yes | no |
| test-pi-no-extensions.sh | exec | LOCKED-variant extensions/DCG guard survives; live cage to msb exec | :2 "pi --no-extensions bypass guard" | **yes** | yes | no |
| test-pi-substrate-mounts.sh | lifecycle | pi substrate mount-arg synthesis to msb mounts; denylist (B) + init symlinks (D) portions are KEEP-class | :5-8 "_up_prepare_docker_mounts emits :ro" | no | yes | no |
| test-prerequisites.sh | stub | fail-loud-on-missing-prereq survives; docker preflight to msb; PATH-shim stub | :4-5 "simulate missing tools" | no | yes | no |
| test-pull-first.sh | stub+fixture-image | pull-before-build survives; docker pull/build to msb image load; fake docker shim | :7-10 fake docker image inspect | no | yes | no |
| test-rc-reload.sh | lifecycle (split) | reload verb re-homes to D4 deny-fix-reload snapshot-amend; SPLIT: allowed_keys C3/C4 (ssh) + egress.mode C5 retire | :2-9 "rc reload; allowed_keys; egress.mode" | no | yes | no |
| test-reload-exit-trap-seam.sh | lifecycle | reload lock-dir EXIT-trap survives; gated behind docker reload gates to msb | :2-10 "reload EXIT-trap; docker gates" | no | yes | no |
| test-safety-stack.sh | (split) | generic name-free presence+behavioral runner survives; SPLIT: floor list re-enumerates (D2), egress/firewall guard smoke retires | :1-9 safety-stack SKIP_AUTH | no2 | yes | no |
| test-scratch-cage-cleanup.sh | lifecycle | leaked-cage cleanup survives; docker ps/rm/volume to msb list/remove/destroy | :4-10 residual containers+volumes | no2 | yes | no |
| test-security-model-injection.sh | exec (split) | injection BLOCK-OUTCOME survives to msb-side effect probes; SPLIT: vectors hitting SNI-router/DNS/mediator re-map, survivor vectors (denylist/DCG) stay | :4-6 "BLOCK OUTCOME; real staged cages" | no1 | yes | no |
| test-session-persistence.sh | lifecycle | session JSONL persist-to-host survives (D4 pre-creates dirs); bind-mount to msb virtiofs; rc destroy to msb remove | :6-9 "lands on host; survives rc destroy" | **yes** | yes | no |
| test-skills.sh | exec | MCP skill discovery survives (skill-server.py KEEP); in-cage handshake to msb exec | :2-6 "skill discovery; MCP server" | **yes** | yes | no |
| test-up-run-args-e2e.sh | stub | up run-arg generation to msb-flag generation; content-keyed fake docker to msb-CLI stub; asserts run-arg presence | :4-6 content-keyed fake docker | no | yes | **yes** |
| test-up-run-args-full-chain.sh | lifecycle | _UP_RUN_ARGS create-path flag-gen to msb create-flag gen; asserts generated flag array | :4-9 "_UP_RUN_ARGS create-path" | no | yes | **yes** |

### UNSURE (3)

| file | reason | evidence | NC? | par? | pres? |
|---|---|---|---|---|---|
| test-egress-rules-gen.sh | config-to-egress-rules.yaml generator: intent survives but §C says the msb --net-rule generator is "net-new code, not a port"; artifact format + observe/block mode die (D4) | :6-14 IOC floor + mode=observe/block | no | (see Q1) | **yes** |
| test-rc-allowlist.sh | §B/§D lists rc allowlist UNSURE ("may disappear rather than refactor"); add writes survivor config, show --observed reads the retiring egress JSONL log | :5-10 allowlist add / show --observed | no | (see Q2) | no |
| test-placeholder-env-file.sh | auth.placeholder_env_file is modeled on the RETIRE-listed _up_resolve_mediator_env_file; msb injects from a same-name host var (ADR-029 D3 ENV-at-HOST form), not a placeholder file | :5-10 placeholder-file resolver | no | (see Q3) | no |

### Golden-master net (row-group) — REFACTOR / stub

| group | sub-tag | reason | evidence | NC? | par? | pres? |
|---|---|---|---|---|---|---|
| tests/golden-master/ (capture.sh, cases.sh, self-check.sh, lib/fake-bin/docker) | stub | rc-CLI byte-diff behavior-preservation net; pure-CLI cases (usage/schema/completions/version) KEEP, up/build/resume cases re-platform; the content-keyed fake-docker shim to msb-CLI stub is the central re-platform | cases.sh:9-30 GM_CASES catalog | no | yes | no |

---

## 2. Counts summary — reconciled against partition-map §B

This pass (118 files + 1 golden-master row-group):

| bucket | count |
|---|---|
| RETIRE | 19 |
| KEEP | 58 |
| REFACTOR | 38 |
| UNSURE | 3 |
| total files | 118 |
| golden-master row-group | 1 (REFACTOR/stub) |

Parity-relevant (KEEP+REFACTOR) = 96 files + golden-master group. These 96 rows pre-cutover ledger status is the behavior-preservation baseline for rip-cage-5iti / the Part-B ledger (rip-cage-7atw.14).

Reconciliation vs §B pattern-only estimate ("~16 engine tests"):

- §B RETIRE list named: test-egress-*, test-firewall-tcp22, test-mediator-*, test_egress_proxy, test-denylist-*, test-secret-path-denylist. Read result diverges on several:
  - test-denylist-matching.sh to KEEP, not RETIRE. It is the ADR-023 _check_secret_path_denylist component-match test (mount denylist), explicitly KEEP per the Fable partition-map correction and surviving in the D2 floor. §B test-denylist-* glob mis-swept it.
  - test-secret-path-denylist.sh to KEEP, not RETIRE. Same ADR-023 mount-denylist family; §B listed it under RETIRE by name — direct contradiction with the ADR-023-KEEP correction and ADR-029 D2 ("secret-path mount denylist survives in the D2 floor").
  - test-egress-rules-gen.sh to UNSURE, not RETIRE. The config-to-policy INTENT is survivor intent-data (§C), but the generator is "net-new, not a port" — a genuine call (Q1).
  - test-egress-firewall.sh, test-firewall-tcp22.sh, test-mediator-{lifecycle,manifest,validator}.sh, test_egress_proxy.py to RETIRE as §B predicted.
- §B UNDER-COUNTED RETIRE. §B "~16" omitted these because they sat in §D-UNSURE or other sections pre-ADR-029:
  - the ssh cluster (7 files): ssh-allowlist, ssh-bypass-demotion, ssh-config, ssh-forwarding, ssh-preflight, ssh-resolver, ssh-visibility. §B §D listed the ssh-arrow model UNSURE; ADR-029 D3 (FIRM, decided after the 2026-07-08 map) resolves it to RETIRE — the single biggest delta from §B.
  - the selftest cluster (4): selftest-classifier, selftest-integration, selftest-mode-gating, test_selftest_endpoint.py — all assert the deleted startup self-test / rip_cage_egress endpoint.
  - the DNS tests (2): test_dns_decide.py, test_dns_seam.py — §D marked the DNS question RESOLVED to clean RETIRE; the two test files follow.
  Net RETIRE = 19, not ~16.
- §B "~32 files hand-roll docker shims" (the REFACTOR/stub-replatform driver): consistent — the REFACTOR bucket (38) is dominated by exec/stub/lifecycle re-platform of docker-touching tests plus the golden-master fake-docker shim.
- Naming note: test-golden-master-sandbox-isolation.sh (a test-*.sh file, KEEP — meta-test of the harness sandbox) is distinct from the tests/golden-master/ net (row-group, REFACTOR); do not conflate.

Wiring reconciliation (bead DESIGN said "~114 wired, 21 denylist"): actual = 110 wired test-*/test_* files + golden-master/capture.sh, with 21 NEEDS_CONTAINER denylist entries (confirmed, run-host.sh:36-56). 8 files are NOT wired into run-host.sh: test_dns_seam.py, test-bd-roundtrip.sh, test-e2e-lifecycle.sh, test-egress-firewall.sh, test-pi-wrapper-glob.sh, test-placeholder-env-file.sh, test-safety-stack.sh, test-security-model-injection.sh. So the "~114" estimate is ~110; the "21 denylist" is exact.

1 Unwired e2e/in-cage file: NC=no is strict denylist membership; it factually needs a live cage.
2 Self-skips without docker; not in the denylist.

---

## 3. UNSURE — adjudication questions for Fable

Q1 — test-egress-rules-gen.sh. The config-to-egress-rules.yaml generation pipeline (baseline whitelist, IOC floor, network.mode observe/block, allowed_hosts merge) — does its coverage PORT to a new test over the msb --net-rule flag-generator, or RETIRE, given partition-map §C states "every current reader is on the retire list; the msb flag-generator is net-new code, not a port" and D4 retires observe/block mode entirely?

Q2 — test-rc-allowlist.sh. Does the rc allowlist verb survive the cutover — re-homed as the editor for the ADR-029 D4 deny-fix-reload --net-rule config (so allowlist add KEEPs and only allowlist show --observed, which parses the retiring egress JSONL log, drops) — or does the whole verb disappear, as partition-map §D flags ("may disappear rather than refactor")?

Q3 — test-placeholder-env-file.sh. Does auth.placeholder_env_file survive as the binding source for msb secret-injection (i.e. the placeholder-file pointer re-platforms to the host-var generator), or does it RETIRE with the _up_resolve_mediator_env_file resolver it is modeled on — given ADR-029 D3 generator constraint that msb secret-injection accepts only the ENV-at-HOST form resolved from a same-name host var, not a placeholder file?
