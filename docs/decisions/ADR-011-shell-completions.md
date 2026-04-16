# ADR-011: Shell Completions for `rc` CLI

**Status:** Proposed
**Date:** 2026-04-16
**Design:** [Shell Completions](../../history/2026-04-16-shell-completions-design.md)
**Related:** [ADR-003](ADR-003-agent-friendly-cli.md) (agent-friendly CLI), [ADR-008](ADR-008-open-source-publication.md) (open-source publication)

## Context

The `rc` CLI manages multiple containers but offers no tab completion. Users must type container names exactly, often after running `rc ls` to see what's available. As rip-cage prepares for public release, this friction hurts first-run experience — especially since comparable tools (docker, gh, kubectl) all provide completions out of the box.

The install method (`git clone` + `ln -sf`) means there's no package manager to handle completion setup automatically.

## Decisions

### D1: Ship `rc completions <shell>` subcommand

**Firmness: FIRM**

Add `rc completions zsh` and `rc completions bash` that print the completion script to stdout. This is the universal building block — every major CLI tool provides this, and it's the exact interface Homebrew's `generate_completions_from_executable` calls.

```bash
rc completions zsh     # prints zsh completion script
rc completions bash    # prints bash completion script
```

**Rationale:** This is the industry-standard primitive. Power users know what to do with it, package managers call it, and all higher-level setup paths (eval, install scripts) build on it.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **`rc completions` subcommand** | Universal, expected, brew-ready | Requires user to wire it up |
| **Completions only in `completions/` dir** | Simpler code | Not discoverable, no standard interface for brew |
| **No completions** | No work | Poor UX, non-standard for a CLI tool |

**What would invalidate this:** Nothing — this is a universal pattern with no meaningful downsides.

### D2: Ship `rc setup` for interactive shell integration

**Firmness: FLEXIBLE**

Add `rc setup` that detects the user's shell, shows what it will do, asks for consent, then appends an `eval "$(rc completions zsh)"` line to the shell config file.

```
$ rc setup
rc setup — shell integration
  Shell detected: zsh
  Config file:    ~/.zshrc
  This will add:  eval "$(rc completions zsh)"
  Add shell completions? [y/N]
```

**Rationale:** rip-cage's install path (git clone) is identical to fzf's, and fzf's interactive-consent model is the gold standard for tools that need to modify dotfiles. The `eval` pattern (vs. writing a file to fpath) means completions auto-update when the user pulls new changes — no re-running setup. Default-no (`[y/N]`) is deliberate: a security tool should never default to modifying your shell config.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **Interactive `rc setup`** | Consent-driven, transparent, fzf-proven | One extra install step |
| **Silent dotfile modification (nvm model)** | Zero friction | Erodes trust, widely criticized, especially bad for a security tool |
| **`rc completions --install` (auto-place file)** | One command | Must guess fpath dir, may need sudo, harder to undo |
| **Only document manual steps** | No code | High friction, completion adoption will be near zero |

**What would invalidate this:** If rip-cage moves to a Homebrew-only distribution model, `rc setup` becomes unnecessary (brew handles it). Keep the subcommand but `rc setup` could be removed.

### D3: Default-deny consent for dotfile changes

**Firmness: FIRM**

`rc setup` defaults to No (`[y/N]`). The user must actively opt in to shell config modification.

**Rationale:** Rip-cage is a security tool — its whole value proposition is protecting users from unintended side effects. Defaulting to "yes, modify your dotfiles" contradicts that positioning. Users who are less familiar with coding may not understand what `.zshrc` modification means; a default-no with a clear explanation respects their autonomy.

**Alternatives considered:**

| Approach | Pros | Cons |
|----------|------|------|
| **Default-no `[y/N]`** | Respects user autonomy, consistent with security positioning | Slightly more friction |
| **Default-yes `[Y/n]`** | More users get completions | Presumptuous for a security tool |
| **No prompt, just do it** | Lowest friction | Trust violation |

**What would invalidate this:** User research showing that the default-no causes most users to skip completions. Could revisit to default-yes if data supports it.

### D4: Complete container names from live Docker state

**Firmness: FIRM**

Tab completion for `attach`, `down`, `destroy`, `test` queries `docker ps` live with the `rc.source.path` label filter. No cache, no stale state.

**Rationale:** Container state changes frequently (up, down, destroy). A cached list would be wrong more often than not. The Docker query is fast enough (~50ms) to feel instant during tab completion.

**What would invalidate this:** If users commonly have hundreds of rip-cage containers, making the Docker query noticeably slow. Unlikely given the use case.

### D5: Completion files live in `completions/` directory in the repo

**Firmness: FLEXIBLE**

Ship `completions/_rc` (zsh) and `completions/rc.bash` (bash) in the repo. The `rc completions <shell>` subcommand cats the appropriate file, resolved through the symlink.

**Rationale:** Keeps completion logic separate from the main `rc` script. The symlink resolution means `rc completions zsh` always returns the version matching the installed repo — no version skew.

**What would invalidate this:** If completions need to be dynamically generated (e.g., subcommands from plugins). Currently the subcommand list is static, so static files are simpler and faster.
