# Shell Completions for `rc` CLI

**Date:** 2026-04-16
**Status:** Proposed
**Decisions:** [ADR-011](../docs/decisions/ADR-011-shell-completions.md)

## Problem

When multiple rip-cage containers are running, `rc down` lists all container names and the user must type one exactly. There's no tab completion for subcommands or container names, making the CLI feel unpolished — especially for new users coming from tools like `docker`, `gh`, or `kubectl` where completion is standard.

Since rip-cage is installed via `git clone` + `ln -sf` (no package manager), there's no natural mechanism to install completions automatically. The challenge is making completions easy to activate without being presumptuous about the user's shell configuration.

## Research

Surveyed how established CLI tools handle completions:

| Tool | Install method | Completion UX | Dotfile policy |
|------|---------------|---------------|----------------|
| gh | brew / binary | `gh completion -s zsh` → stdout, user places file | Never touches dotfiles |
| kubectl | brew / binary | `kubectl completion zsh` → stdout | Never touches dotfiles |
| docker | apt / brew / desktop | Bundled by package manager; `docker completion` for manual | Never touches dotfiles |
| fzf | git clone + `./install` | Interactive script asks before each change | Asks permission per feature |
| nvm | curl \| bash | Silently appends to .zshrc/.bashrc | No consent — widely criticized |
| starship | brew / binary | Docs say add `eval "$(starship init zsh)"` to .zshrc | Never touches dotfiles |
| rustup | installer | `rustup completions zsh` → stdout | Never touches dotfiles |

**Key patterns identified:**

1. **Every tool ships a `completion` subcommand** — universal building block, also what Homebrew's `generate_completions_from_executable` calls during formula install
2. **The `eval "$(tool completions zsh)"` one-liner** (starship/fnm model) — cleanest user experience for non-brew installs, one line in .zshrc, auto-updates with the binary
3. **fzf's interactive install is the trust benchmark** for git-cloned tools — asks before each dotfile change
4. **Silent dotfile mutation (nvm) erodes trust** — especially bad for a security-focused tool

## Design

### Two-tier approach

**Tier 1: `rc completions <shell>`** — the building block

Prints the completion script for the specified shell to stdout. This is the universal primitive that power users expect, Homebrew formulas call, and all other setup paths build on.

```bash
rc completions zsh    # prints zsh completion script
rc completions bash   # prints bash completion script
```

**Tier 2: `rc setup`** — the friendly path

An interactive setup command for new users. Detects the shell, explains what it will do, asks for consent, then adds a single `eval` line to the user's shell config.

```
$ rc setup

rc setup — shell integration

  Shell detected: zsh
  Config file:    ~/.zshrc

  This will add the following line to ~/.zshrc:

    eval "$(rc completions zsh)"

  This enables:
    • Tab completion for rc commands (build, up, down, ls, ...)
    • Tab completion for container names (rc down <TAB>)

  Add shell completions to ~/.zshrc? [y/N]
```

On yes: appends the eval line, confirms, suggests `exec zsh`. On no: prints the manual instructions and exits cleanly.

### What gets completed

| Position | Context | Completions |
|----------|---------|-------------|
| 1st arg | Any | Subcommands: `build`, `init`, `up`, `ls`, `attach`, `down`, `destroy`, `test`, `auth`, `schema` |
| 2nd arg | `attach`, `down`, `destroy`, `test` | Live container names (queries Docker via `rc.source.path` label) |
| 2nd arg | `up`, `init` | Directory paths |

Container name completion queries Docker live — no stale cache, always current.

### Implementation scope

| File | Purpose |
|------|---------|
| `rc` (new subcommands) | `rc completions zsh\|bash` and `rc setup` |
| `completions/_rc` | Zsh completion function (already drafted) |
| `completions/rc.bash` | Bash completion function (already drafted) |
| `README.md` | Add setup step to Quick Start |

### Future: Homebrew formula

When rip-cage is published as a Homebrew formula, the formula calls `generate_completions_from_executable(bin/"rc", "completions")` at install time. Completions become zero-config for brew users. The `rc completions` subcommand is the exact interface Homebrew expects — no additional work needed.

## Data flow

```
rc setup
  ├─ detect $SHELL → zsh|bash
  ├─ resolve config file (~/.zshrc or ~/.bashrc)
  ├─ check if eval line already present → skip if so
  ├─ show what will be added, ask y/N
  ├─ append: eval "$(rc completions zsh)"
  └─ suggest: exec zsh

On every new shell:
  eval "$(rc completions zsh)"
    └─ rc completions zsh
        └─ cat $SCRIPT_DIR/completions/_rc  (resolved through symlink)

On tab press:
  _rc()
    ├─ 1st arg → static subcommand list
    └─ 2nd arg → docker ps --filter label=rc.source.path --format '{{.Names}}'
```

## Edge cases

- **eval line already present**: `rc setup` greps for the line and skips with a message ("completions already configured")
- **Non-standard shell configs**: Detect `.zshrc` vs `.zprofile` vs `.bash_profile` vs `.bashrc` — use the same heuristic as fzf (check which files exist, prefer `.zshrc` / `.bashrc`)
- **fish shell**: Out of scope for now — print "fish not yet supported, PRs welcome"
- **rc not on PATH**: The eval line uses the full command name `rc` — if the user removes the symlink, eval fails silently (completion just doesn't load, no error on shell start)
- **Multiple rc installs**: The eval resolves through whatever `rc` is on PATH at shell start time — correct behavior
