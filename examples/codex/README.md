# codex recipe — the Codex CLI on the ChatGPT subscription, placeholder-only

Runs OpenAI's `codex` CLI in a cage on your ChatGPT/Codex subscription. The
guest holds only a **placeholder** token; msb holds the real one and puts it on
the wire toward `chatgpt.com`. Proven on msb 0.7.8 and codex 0.167.0
([spike](../../docs/2026-11-06-codex-cli-in-cage-spike.md), rip-cage-bygi.1;
recipe live-checked under rip-cage-bygi.2).

Not floor, never on by default (ADR-005 D12 FIRM). Nothing in `rc` knows this
recipe exists; it is composition you paste in yourself.

**One token serves pi and codex.** The real token comes from the host pi's
`openai-codex` login, through the same helper and the same `CODEX` secret as
[`pi-providers/`](../pi-providers/). Only the guest file differs: pi and codex
read differently shaped `auth.json` files carrying the same placeholder.

## What is in here

| file | what it is |
|---|---|
| `Dockerfile.snippet` | installs `codex` (pinned), puts the base image's launch wrapper at `codex`, merges the boot fragment |
| `boot-fragment.json` | a `tools[]` entry named `codex` whose `init` copies the placeholder `auth.json` into `CODEX_HOME` at every boot |

## Use it

1. **Host login, once.** Run `pi` on the host and `/login` to the OpenAI
   (ChatGPT) subscription (provider `openai-codex`).

2. **Run the host helper.** It writes three files and prints the placeholder:

   ```bash
   <rc install dir>/examples/pi-providers/codex-secret.sh
   ```

   - `~/.config/rip-cage/secrets/CODEX` — the real access token, 0600. rc
     reads it at every `rc up`; it never enters the guest.
   - `~/.config/rip-cage/codex-cli/auth.json` — the codex-shaped placeholder.
   - `~/.config/rip-cage/pi-codex/auth.json` — the pi-shaped placeholder
     (unused here unless the cage also runs pi on `openai-codex`).

3. **Build the image.** Paste `Dockerfile.snippet` into your own Dockerfile,
   outside every directory a cage mounts (`~/.config/rip-cage/images/` is a
   good home), and copy `boot-fragment.json` next to it:

   ```dockerfile
   FROM ghcr.io/jsnyde0/rip-cage:latest
   # ...paste Dockerfile.snippet here...
   ```

   ```bash
   RC_IMAGE=my-codex-cage:latest rc build --file ~/.config/rip-cage/images/Dockerfile
   ```

4. **Add these lines to the cage config** (`~/.config/rip-cage/projects/<cage>.yaml`),
   and point `image:` at the tag you built:

   ```yaml
   image: my-codex-cage:latest
   mounts:
     - "<ABSOLUTE_PATH_TO_YOUR_HOME>/.config/rip-cage/codex-cli:/home/agent/rc-codex-placeholder:ro"
   secrets:
     CODEX:
       allow:
         - "chatgpt.com"
       placeholder: "<the line codex-secret.sh printed>"
   network:
     allow:
       - "chatgpt.com:tcp:443"
   ```

   - **Mount the directory, at that neutral path.** Do not mount the file at
     `~/.codex/auth.json`: the mount makes `~/.codex` root-owned and codex then
     fails with `Permission denied (os error 13)`. The boot hook copies the
     file into `~/.codex/` (or `$CODEX_HOME` when the cage env sets it), mode
     0600, owned by `agent`.
   - **The placeholder** only changes if your ChatGPT account changes; paste it
     once. A cage that already runs pi on `openai-codex` has the `CODEX` secret
     and the `chatgpt.com` line already; add only the mount.
   - `chatgpt.com:tcp:443` is the only host codex needs, given the flags below.

5. `rc up <project>` (or `rc up --replace <project>` for an existing cage, so it
   picks up the new image and mount).

**Check**, inside the cage:

```bash
codex exec --dangerously-bypass-approvals-and-sandbox --disable plugins --disable remote_plugin \
  --disable apps -c analytics.enabled=false --skip-git-repo-check --ephemeral \
  "Reply with exactly the word: pong" </dev/null
```

It answers `pong`, and `rc doctor <cage>` shows no denials.

## What a launcher passes in (the Switch desk)

A launcher that runs codex non-interactively in this cage passes exactly:

```bash
CODEX_HOME=<guest-writable dir holding the placeholder auth.json> \
codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  --disable plugins --disable remote_plugin --disable apps \
  -c analytics.enabled=false \
  [--skip-git-repo-check] [--ephemeral] [-o <last-message-file> | --json] \
  "<prompt>" </dev/null
```

| input | why |
|---|---|
| `CODEX_HOME` | Optional. Unset, codex uses `~/.codex`, which the boot hook already filled. A launcher that wants a separate home per run copies the placeholder in first: `mkdir -p "$D" && cp ~/rc-codex-placeholder/auth.json "$D/"`. The directory must be writable by `agent`. |
| `--dangerously-bypass-approvals-and-sandbox` | No approval prompts, no codex sandbox. Codex's help calls it "intended solely for running in environments that are externally sandboxed" — the cage is that sandbox. |
| `--disable plugins --disable remote_plugin --disable apps` and `-c analytics.enabled=false` | With all four, codex talks only to `chatgpt.com`. Without them it also calls `ab.chatgpt.com` (telemetry) and `*.oaiusercontent.com` (plugin bundles). Those calls are denied and cost nothing, but they fill the denial log `rc doctor` reads. |
| `</dev/null` | With a non-TTY stdin, codex waits to read more prompt from stdin. Close it, or pass the prompt as `-` on stdin. |
| `--skip-git-repo-check` | Only when the working directory is not a git repo. |
| `--ephemeral` | Skips session files. Drop it if you want `codex exec resume`, which needs a `CODEX_HOME` that persists. |
| `-o <file>` / `--json` | `-o` writes the last reply to a file; `--json` streams events. Pick what the launcher parses. |

Nothing else: no API key, no `OPENAI_API_KEY`, no token in the environment.

## When the token goes stale (401)

The access token lives about ten days. The host pi keeps the real one fresh;
`secrets/CODEX` is only as fresh as your last helper run.

**Symptom in the cage:** codex exits 1 with
`workspace routing discovery unauthorized (401)`, and `rc doctor` shows a burst
of denials for `auth.openai.com`. That is codex trying to refresh with the
placeholder refresh token. It is denied and harmless; the guest cannot refresh,
by design.

**Fix, on the host:** run `pi` once with `--provider openai-codex` (so it
refreshes), re-run `codex-secret.sh`, then `rc up <project>`. A resume re-reads
the secret file. rc never refreshes the token itself.

## Residuals

- **Response reflection is untested.** The real token rides only the
  `Authorization` header toward `chatgpt.com`, and the spike saw no request body
  carry it. Whether a `chatgpt.com` response could echo it back into the guest
  was not tested; msb does no response scrubbing.
- **A quoted placeholder.** If codex reads the placeholder into a prompt, msb
  0.7.8 passes it to `chatgpt.com` unchanged and the session survives (spike
  Q3). Older msb dropped such requests (microsandbox#1354). Keep the placeholder
  out of files the caged agent reads anyway.
- **Version pin.** A newer codex may call new hosts or require new `auth.json`
  fields. After bumping `CODEX_VERSION`, re-run the Check step.
