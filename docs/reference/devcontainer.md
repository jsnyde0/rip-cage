# Dev Containers (VS Code)

Rip cage can generate a `.devcontainer/devcontainer.json` for VS Code integration. This is best for interactive development — VS Code runs inside the cage.

## Setup

```bash
rc init /path/to/your/project
```

Then open the project in VS Code and run **"Dev Containers: Reopen in Container"**.

That's it — you're in a caged environment. Open the terminal, run `claude`, and let it rip.

## Notes

- `.devcontainer/` and `.vscode/` are gitignored — they're generated per-project by `rc init`.
- Use `rc init --force` to regenerate an existing devcontainer config.
- The devcontainer uses the same safety stack as CLI mode.
