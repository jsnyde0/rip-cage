# Adding a Shell-Integration Tool (SHELL-INTEGRATION archetype)

This walkthrough covers the **SHELL-INTEGRATION manifest archetype** ([ADR-005 D7](../decisions/ADR-005-ecosystem-tools.md)) — for tools that integrate with the agent's shell via an rc-file `eval` line rather than (or in addition to) a binary on PATH. Shell-history managers, smarter-`cd` tools, and prompt/env hooks are the typical class: the binary alone does nothing until the shell sources its init hook on every interactive shell start.

**ADR-005 D12 (FIRM):** rip-cage never blesses, bundles, or defaults any shell-integration tool. `zoxide` is used below **as illustration only** — it is not recommended, not shipped, and not special-cased anywhere in `rc`. `atuin`, `direnv`, `starship`, or your own hook script compose identically. The default image contains zero SHELL-INTEGRATION entries.

---

## What the archetype is for

A plain TOOL entry gives you *reachability*: a binary on PATH the agent can invoke. Some tools additionally need a line evaluated in the shell's own process at startup — `eval "$(zoxide init zsh)"` defines the `z` function; `eval "$(atuin init zsh)"` rebinds history keys. That line cannot be a binary install step; it has to land in the shell rc file the in-cage agent's interactive shell reads.

SHELL-INTEGRATION is the seam for exactly that: **one `shell_init` field**, baked into the cage's `/home/agent/.zshrc` at build time.

## Eval-into-shell mechanics

`rc build` (via `_manifest_generate_shell_init_zshrc_steps`) emits, for each SHELL-INTEGRATION entry, a Dockerfile `RUN` step that appends the `shell_init` line to `/home/agent/.zshrc` — injected after the base `COPY zshrc /home/agent/.zshrc` step, in agent context. The line is base64-encoded in the generated step and decoded at image-build time, so any single-line content (quotes, `$(...)`, parens) survives baking intact.

Consequences worth knowing:

- **Build-time, not runtime** (ADR-005 D1 FIRM: install = build-time). Changing `shell_init` means `rc build` + recreating the cage. There is no runtime hook-injection path.
- **Interactive shells only.** The hook lives in `.zshrc`, so it fires in interactive shells (`zsh -lic`, the shell you get at `rc attach`) and does **not** fire in non-interactive `zsh -c` invocations — e.g. commands an agent runs through a bare `bash`/`zsh -c` tool call. If your tool must affect non-interactive commands too, SHELL-INTEGRATION is the wrong seam.
- **Single line, enforced fail-closed.** `shell_init` must be exactly one line. A newline is rejected by the manifest validator at load (`_manifest_validate`) and again at the generation site (defense-in-depth) — multi-line content could inject arbitrary Dockerfile directives. See [manifest-validator.md](manifest-validator.md).
- **No hook-registration reach.** `shell_init` lands in the agent-owned `.zshrc` — agent-writable space. It cannot touch the containment floor, and it is not a mechanism for registering lifecycle interceptors (that whole surface is bounded elsewhere; ADR-005 D9).

## Manifest shape — the two-entry pattern

The archetype declares only the shell hook. The binary itself is installed by an ordinary **TOOL entry** in the same fragment — the same two-entry pattern multiplexers use (TOOL for the install + MULTIPLEXER for the hooks). Compose both:

```yaml
# ~/.config/rip-cage/tools.yaml — illustration only (ADR-005 D12); replace zoxide
# with any tool that installs a binary + wants a shell init hook.
version: 1
tools:
  # Entry 1: install the binary (plain TOOL — see adding-a-tool.md)
  - name: zoxide-bin
    archetype: TOOL
    version_pin: "0.9.6-debian"
    install_cmd: "apt-get install -y --no-install-recommends zoxide"
    egress: []
    mounts: []

  # Entry 2: wire the shell hook (SHELL-INTEGRATION)
  - name: zoxide
    archetype: SHELL-INTEGRATION
    version_pin: "0.9.6-debian"
    shell_init: 'eval "$(zoxide init zsh)"'
```

Field notes:

- **`name`** — required on every entry.
- **`archetype: SHELL-INTEGRATION`** — selects the eval-into-shell path.
- **`version_pin`** — required on all archetypes ([ADR-005 D3](../decisions/ADR-005-ecosystem-tools.md), FIRM: pinned, never `latest`).
- **`shell_init`** — required; the single line appended to `/home/agent/.zshrc`. Anything zsh can evaluate on one line is valid — an `eval "$(tool init zsh)"` idiom, an `alias`, a `source /path` line.

`egress` and `mounts` are not required fields on this archetype (the validator requires them on TOOL entries only) — declare install-time egress on the companion TOOL entry that runs the download. If a SHELL-INTEGRATION entry does declare `egress:`, those hosts are still IOC-checked like any other entry's ([manifest-validator.md](manifest-validator.md)).

## Build and verify

```bash
rc build
rc up /path/to/workspace
# Inside the cage, in the interactive shell:
type z          # illustration: zoxide's function is defined
tail -3 ~/.zshrc  # shows the "# rip-cage manifest SHELL-INTEGRATION: zoxide" block
```

If the hook did not fire, check that you are in an interactive shell — `zsh -c 'type z'` will not see it (by design, see mechanics above).

---

## See also

- [docs/reference/README.md](README.md) — seam catalog (this archetype's entry, plus TOOL and all other seams)
- [adding-a-tool.md](adding-a-tool.md) — the companion TOOL entry walkthrough (install paths, checksums, mounts)
- [manifest-validator.md](manifest-validator.md) — the fail-closed checks every entry passes at `rc build`
- `tests/fixtures/manifest-with-shell-integration.yaml`, `tests/fixtures/manifest-e2e-shell-integration.yaml` — the harness fixtures exercising this seam (interactive-vs-non-interactive proof lives in `tests/test-manifest-shell.sh`)
- [ADR-005 D7/D12](../decisions/ADR-005-ecosystem-tools.md) — archetype definition; illustration-only rule
