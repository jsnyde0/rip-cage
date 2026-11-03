# Auth

Rip cage runs Claude Code on your subscription through one long-lived token you save once on the host. No API key required.

**Claude Code's login reaches the cage through exactly one mechanism: msb `--secret`.** The guest never holds the real token — only a placeholder, substituted on the wire toward `api.anthropic.com`. There is no possession path and no fallback. `rc doctor <cage>`'s `auth` probe confirms a live cage is authenticated.

Proven for the real Claude Code CLI by the July spike [`docs/2026-07-09-msb-spike-claude-nonpossession.md`](../2026-07-09-msb-spike-claude-nonpossession.md) (`rip-cage-cmqb`): placeholder-only in the guest environment and `/proc`, wire-level substitution toward `api.anthropic.com` confirmed with a real completion.

---

## The one mechanism

The shipped template declares:

```yaml
secrets:
  CCTOK:
    allow:
      - "api.anthropic.com"

env:
  CLAUDE_CODE_OAUTH_TOKEN: "\x24MSB_CCTOK"
```

msb injects the real value on the wire toward `api.anthropic.com` only; the guest holds the placeholder, `$` + `MSB_CCTOK` — on disk, in its environment, in `/proc`. The config writes it as `"\x24MSB_CCTOK"`, which YAML decodes to the same string (measured on msb 0.7.4).

**The placeholder is never spelled verbatim in `docs/reference/`, the README, the template or the skills.** msb drops any request whose body carries a bound secret's placeholder as a leak ([superradcompany/microsandbox#1354](https://github.com/superradcompany/microsandbox/issues/1354), fix unmerged). A caged agent that read such a doc and quoted it would send the placeholder in its next model call, and every call after it, and lose the session. So the prose says `$` + `MSB_<NAME>` and the YAML says `\x24`. `tests/test-no-verbatim-placeholder.sh` holds that line; drop it once upstream #1354 ships. `init-rip-cage.sh` reads only what the config mounted; it never touches a keychain, and there is no Claude credentials file in the guest.

### msb version floor

rip-cage needs **msb 0.7.4 or newer**. On msb 0.7.3 the `--secret` substitution drops any TLS request whose body contains a `%` — the guest sees `unexpected eof` and claude reports `API Error: Connection dropped (ECONNRESET)` — and claude's real requests always carry one, so a CCTOK-bound cage cannot make a single model call ([superradcompany/microsandbox#1664](https://github.com/superradcompany/microsandbox/issues/1664), fixed in 0.7.4). `rc up` refuses an older msb and names the upgrade, `msb update`, which restarts running cages. `rc doctor --host` shows the installed version against the floor. The floor is one constant, `RC_MSB_MIN_VERSION` in `cli/lib/msb_runtime.sh`.

### The token, and where it lives

The credential is the **long-lived** token from `claude setup-token`, not the short-lived access token a keychain login holds. A keychain token refreshes through a refresh-token flow that a static placeholder swap cannot carry — there is no refresh request to intercept, so it cannot work here.

Get one, once, on the host, then save it to `$XDG_CONFIG_HOME/rip-cage/secrets/CCTOK` (typically `~/.config/rip-cage/secrets/CCTOK`), mode `0600`, host-side, outside every cage mount ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5(a)):

```bash
claude setup-token
# paste the printed token into the file above, then:
chmod 600 ~/.config/rip-cage/secrets/CCTOK
```

`rc up` reads that file and exports it for msb, so an unattended run needs no pre-export.

A cage config mount that equals or contains `$XDG_CONFIG_HOME/rip-cage/secrets` is refused before any msb call (`SECRETS_DIR_INSIDE_MOUNT`), and one of rc's own skill/agent/pi-substrate symlink-parent mounts that would contain it is skipped with a stderr warning instead — either way, the file above never rides into a cage as a mounted directory.

### `rc auth`

```bash
rc auth
```

A no-prompt check: the file exists, is `0600`, and holds a setup-token-shaped value. It never prompts, never opens a browser, never reads a keychain. On failure it exits non-zero, names the file, and prints the one-time human step: run `claude setup-token` in a terminal, save the token to that file, `chmod 600`.

`rc up` runs the same check when the config declares `CCTOK`, and fails loud before booting rather than handing an unauthenticated cage to a walk-away run.

### Switching accounts

Replace the contents of the CCTOK file with the other account's setup-token (same command as above), `chmod 600` again, then recreate:

```bash
rc up --replace <project>
```

A cage already running does not pick this up live — the value is read once, at launch. For rotating between several accounts, see the [multi-account rotation guide](../guides/multi-account-rotation.md).

### `rc doctor`

```
  auth           : OK — CLAUDE_CODE_OAUTH_TOKEN present (msb --secret-injected, non-possession)
  auth (host)    : OK — /path/to/secrets/CCTOK (0600, setup-token-shaped)
```

`auth` is the in-cage probe: OK when `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` is present in-cage, FAIL otherwise (needs a live cage). `auth (host)` is the host-side counterpart: the same check `rc auth` runs, reported only when the cage's config declares a `CCTOK` secret (`n/a` otherwise, so an API-key cage never shows FAIL). JSON: `probes.host_auth`, next to `probes.auth`. `rc doctor` needs an existing cage; before anything boots, run `rc auth` directly.

---

## API key — still possession

`rc up --env-file <path>` with `ANTHROPIC_API_KEY` set in that file works, and reaches the guest as a real value — this one **is** possession, not the `--secret` mechanism above. Use it if you'd rather authenticate with a plain API key than a Claude login.

The shipped template always declares `secrets: CCTOK`, so `rc auth` and the `rc up` pre-check refuse by default — to use `ANTHROPIC_API_KEY` instead, delete the `secrets: CCTOK` block and the `CLAUDE_CODE_OAUTH_TOKEN` env line from this cage's config (`rc auth`'s failure message says the same).

Full model for credentials you nominate yourself, including the shapes `--secret` does not protect: [secret-posture.md](secret-posture.md).

---

## pi auth

**rc never mounts the host's `~/.pi/agent/auth.json`.** That file holds every login the operator's pi has made, the Anthropic subscription included, and a read-write bind would let the guest rewrite a host file. `rc up` sets `PI_CODING_AGENT_DIR=/home/agent/.pi/agent` (a cage-local dir, [ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D1) and stamps the constant label `rc.auth.credential-mounts.pi=none`; the symlink-follow path skips an `auth.json` leaf too.

**Provider API keys ride msb `secrets:`** in the project config, the same mechanism as the Claude login above: a `secrets:` entry binds the key to the provider's host, an `env:` line exposes the placeholder under the variable name pi reads (for example `OPENROUTER_API_KEY`), and `network.allow` carries the provider's `:tcp:443` line. The guest holds only the placeholder. How to write the entry and where the value lives on the host: the [`cage-config`](../../.claude/skills/cage-config/SKILL.md) skill.

**Subscription logins** (openai-codex) ride the same `secrets:` path: the operator's host pi keeps the real token fresh, and `examples/pi-providers/codex-secret.sh` copies it into a secret file and writes the placeholder `auth.json` the cage mounts `:ro`. Recipe: [`pi-providers.md`](../../.claude/skills/cage-config/recipes/pi-providers.md).

**Providers.** pi supports OpenAI, Gemini, Mistral, Groq, Cerebras, xAI, OpenRouter, Azure OpenAI and more — see [pi's provider docs](https://github.com/mariozechner/pi-coding-agent/blob/main/docs/providers.md). A provider key exported in the host shell does **not** reach the guest: `rc up` forwards no provider API-key variable, so a `secrets:` binding is the one path for a provider key ([ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D5). `rc up` forwards only the non-secret pi knobs `PI_SKIP_VERSION_CHECK` and `PI_CACHE_RETENTION`.

**A cage created before this change** carries the old read-write `auth.json` mount until `rc up --replace` recreates it; `rc up` on such a cage resumes it as-is and does not flag the mount.

### Subscription auth — read before using

> Subscription OAuth logins raise policy questions. rc ships a path for openai-codex only (the recipe above); it ships none for the Anthropic subscription.
>
> - **pi → Anthropic OAuth (Claude Max/Pro):** this sends subscription credentials through a third-party harness. Anthropic's January 2026 enforcement action against third-party Claude access tools applies; review the [Anthropic Consumer Terms](https://www.anthropic.com/legal/consumer-terms). Do not use pi with the Anthropic subscription.
> - **pi → OpenAI Codex (ChatGPT Plus/Pro):** pi's own docs carry a "personal use only" statement for this flow. Driving automated agent sessions with it sits in a gray area under the [OpenAI Service Terms](https://openai.com/policies/service-terms/).
>
> There is no runtime banner for this ([ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D6). The callout lives here, findable and version-controlled.

### Why rip-cage ships no paranoid mode

A related project takes the opposite approach: an `LD_PRELOAD` syscall firewall, a V8 filesystem hook, a SUID vault binary, and removal of `su`/`mount`/`passwd`. Rip cage deliberately declines all of it ([ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D7).

That project targets a motivated attacker. Rip cage's threat model is an autonomous agent's *accidents*, plus injected instructions it follows in good faith. Adversarial mitigations add fragility and detection-evasion-flavored UX: a write blocked at the `LD_PRELOAD` level makes an agent retry and fail confusingly, which trades away the autonomy the cage exists to protect. The layers rip-cage already runs catch the realistic failure modes.
