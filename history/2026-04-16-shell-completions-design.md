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
| 1st arg | Any | Subcommands: `build`, `init`, `up`, `ls`, `attach`, `down`, `destroy`, `test`, `auth`, `schema`, `completions`, `setup` |
| 2nd arg | `attach`, `down`, `test` | Running container names (`docker ps --filter label=rc.source.path`) |
| 2nd arg | `destroy` | All container names including stopped (`docker ps -a --filter label=rc.source.path`) |
| 2nd arg | `up`, `init` | Directory paths |
| 2nd arg | `auth` | Subcommands: `refresh` |
| 2nd arg | `completions` | Shell names: `zsh`, `bash` |

Container name completion queries Docker live — no stale cache, always current. The `destroy` command needs to see stopped containers (it operates on any state), while `attach`/`down`/`test` only work on running containers.

**Scope note:** Flag completion (both global flags like `--output json`/`--dry-run` and per-subcommand flags like `--force`, `--cpus`) is deferred to a follow-up. The initial implementation covers subcommand names, container names, directory paths, and nested subcommand arguments.

### Implementation scope

| File | Purpose |
|------|---------|
| `rc` (new subcommands) | `rc completions zsh\|bash` and `rc setup` |
| `completions/_rc` | Zsh completion function |
| `completions/rc.bash` | Bash completion function (must be Bash 3.2 compatible per ADR-008 D5) |
| `tests/test-completions.sh` | Syntax validation + subcommand sync test |
| `README.md` | Add setup step to Quick Start |

**Bash 3.2 compatibility (ADR-008 D5, FIRM):** Both the new subcommands in `rc` and the `completions/rc.bash` file must work with Bash 3.2 (macOS default). No associative arrays, no `${var,,}`, no `|&`, no `mapfile`.

**Codebase integration checklist:**
- `--output json` guard (~line 1427): add `completions` and `setup` to the rejection list
- Main dispatch `case` (~line 1454): add entries for `completions` and `setup`
- `cmd_schema` JSON (~line 1329): add `completions` and `setup` to the schema output (ADR-003 D5)
- `usage()` help text: add `completions` and `setup`

**Fast-path optimization:** The `rc completions` subcommand should dispatch immediately after `SCRIPT_DIR` resolution, skipping `rc.conf` sourcing, `VERSION` reading, and global flag parsing. This keeps shell startup overhead to ~5-10ms (symlink resolution + cat) rather than ~30-50ms for the full init path.

### Future: Homebrew formula

When rip-cage is published as a Homebrew formula, the formula calls `generate_completions_from_executable(bin/"rc", "completions")` at install time. Completions become zero-config for brew users. The `rc completions` subcommand is the exact interface Homebrew expects — no additional work needed.

## Data flow

```
rc setup
  ├─ detect $SHELL → zsh|bash (login shell, standard heuristic)
  ├─ resolve config file (~/.zshrc or ~/.bashrc)
  ├─ check if eval line already present (grep for 'rc completions') → skip if so
  ├─ show what will be added, ask y/N
  ├─ append: eval "$(rc completions zsh)"
  └─ suggest: exec zsh

On every new shell:
  eval "$(rc completions zsh)"
    └─ rc completions zsh (fast-path: dispatches after SCRIPT_DIR resolution only)
        └─ cat $SCRIPT_DIR/completions/_rc  (resolved through symlink)

On tab press:
  _rc()
    ├─ 1st arg → static subcommand list
    ├─ 2nd arg (attach/down/test) → docker ps --filter label=rc.source.path --format '{{.Names}}'
    ├─ 2nd arg (destroy) → docker ps -a --filter label=rc.source.path --format '{{.Names}}'
    ├─ 2nd arg (auth) → refresh
    └─ 2nd arg (completions) → zsh bash
```

## Edge cases

- **eval line already present**: `rc setup` greps for `rc completions` (not the full eval line) and skips with a message ("completions already configured"). The relaxed pattern catches user-modified variations (e.g., added `2>/dev/null`) and prevents double-insertion.
- **Non-standard shell configs**: Detect `.zshrc` vs `.zprofile` vs `.bash_profile` vs `.bashrc` — use the same heuristic as fzf (check which files exist, prefer `.zshrc` / `.bashrc`)
- **fish shell**: Out of scope for now — print "fish not yet supported, PRs welcome"
- **rc not on PATH**: The eval line uses the full command name `rc` — if the user removes the symlink, eval fails silently (completion just doesn't load, no error on shell start)
- **rc errors during eval**: `rc completions` must send all errors to stderr, never stdout, because stdout is fed to `eval`. If errors leak to stdout, they would be executed as shell code on every shell start. This is a correctness requirement.
- **`$SHELL` vs running shell**: `$SHELL` reflects the login shell, not necessarily the shell currently running. This is the standard heuristic (used by fzf, starship). Users running a different shell interactively can use `rc completions <shell>` directly.
- **Multiple rc installs**: The eval resolves through whatever `rc` is on PATH at shell start time — correct behavior

## Testing

- **Syntax validation**: CI runs `zsh -c 'autoload -Uz compinit && compinit && source completions/_rc'` and `bash -c 'source completions/rc.bash'` to catch syntax errors that would break users' shell startup.
- **Subcommand sync test**: Compare the completion script's static subcommand list against `rc schema` output (or the dispatch case statement). Prevents new subcommands from being silently missing from completions. This also mitigates the maintenance cost of having the subcommand list in multiple locations (usage, schema, dispatch, zsh completions, bash completions).
- **Interactive `rc setup` flow**: The `y/N` prompt requires a TTY. Test the non-interactive path (pipe `echo y | rc setup`) and verify idempotency (running twice doesn't double-append). The interactive prompt itself is validated manually.
- **Test location**: `tests/test-completions.sh` — host-side test, not run inside containers via `rc test`.
