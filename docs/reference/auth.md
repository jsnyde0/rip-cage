# Auth

Rip cage uses the login you already have. No API key required.

There are **two postures**, and a cage can be in either. Knowing which one you are in is the whole of this page.

| Posture | The credential is | Set up by |
|---|---|---|
| **Possession** (default) | a real token, in a file mounted into the cage | `rc up` finding your login and mounting it |
| **Non-possession** | a placeholder in the guest; msb injects the real value on the wire | a `secrets:` entry in the cage config |

Non-possession is stronger — a prompt-injected agent has nothing to exfiltrate — but it is something **you** configure, not something you get by default. `rc doctor <cage>`'s `auth` probe names which one a live cage is in.

> **The Claude login is possession today.** `rc auth` finds it in your keychain and `rc up` mounts the file; the two mechanisms below are not bridged. `--secret` carries credentials **you** nominate and whose value **you** put in place. Wiring the Claude login through `--secret` is charted as `rip-cage-ely4.7.17` and is not shipped — see [ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D1's realized-vs-charted note.

---

## Possession — the default path

`rc up` pulls the Claude login from the macOS keychain before the sandbox exists, writes it to `~/.claude/.credentials.json`, and mounts that file read-write into the cage at `/home/agent/.claude/.credentials.json`.

- **macOS:** the token lives in the keychain under `"Claude Code-credentials"`. `rc` extracts it for you.
- **Linux:** there is no keychain. `~/.claude/.credentials.json`, from a previous `claude /login`, is mounted directly.
- **API key:** set `ANTHROPIC_API_KEY` in an env file and pass `rc up --env-file`.

`rc up` also warns when the token has expired or expires within ten minutes, so a walk-away run fails at launch rather than an hour in.

### Switching accounts

Switching accounts on the host updates the keychain, not the mounted file. Run:

```bash
rc auth refresh
```

This re-extracts from the keychain. Running cages pick the change up **immediately** through the mount — no recreate. On Linux, edit `~/.claude/.credentials.json` directly; same effect.

`rc auth refresh` writes **in place** (truncate-and-write, same inode) rather than renaming over the file. That matters — see the gotcha below.

For rotating between several accounts, see the [multi-account rotation guide](../guides/multi-account-rotation.md).

### Gotcha: an atomic rename on the host can sever a live single-file mount

The credential mount is a **single-file** mount. An external writer that does the standard safe-rewrite — write a temp file, rename over the target — allocates a **new inode**, and a single-file mount bound to the old one is left holding a dead handle. The host path looks perfectly normal; the in-cage path goes `ENOENT`.

**Symptom:** the caged agent reports `Not logged in — Please run /login`, possibly an hour into a healthy session, whenever some host writer next rewrites the file.

**Status: confirmed under the pre-cutover Docker bind mount; unverified under msb's virtiofs.** It was observed live on macOS: a host Claude Code session rewrote `.credentials.json` about 30 seconds after cage start, and the in-cage `claude` went to "Not logged in" while the mount still listed as present. Under msb the mount mechanic changed, and this single-file shape has not been re-tested — tracked in `rip-cage-9mbw`. A directory mount was separately measured clean through an inode-changing delete-and-recreate, but that is a different shape and settles nothing here. Treat the mechanism as the working assumption, not a proven-live msb fact.

**`rc`'s own writer never triggers it** — both `rc auth refresh` and `rc up`'s extraction truncate-and-write the same inode ([ADR-010](../decisions/ADR-010-auth-refresh.md) D4). The hazard is external writers.

**Detection:** `rc doctor <cage>`. Its `dead_mounts` probe enumerates every single-file mount generically and checks the **in-cage destination first**:

```
Live probes:
  dead-mounts    : FAIL — dead handle(s): /home/agent/.claude/.credentials.json
                   (host file was replaced by atomic rename; the mount still points at the old inode)
```

Destination-first ordering is deliberate. Some legitimate mounts have a host source that is never host-visible — a forwarded socket materialized only inside the guest's mount namespace. Checking host-source existence first would warn on every one of those, on every healthy cage, forever.

**Repair:** `rc up --replace <path>` — recreates the cage and re-binds every mount against the current inode. Nothing is lost; the cage never touched the credentials file.

**Why rip-cage does not snapshot this file** the way it snapshots `~/.claude.json`: credentials **expire**. A copy taken at boot goes stale the moment the host token refreshes, trading an intermittent *detectable* accident for a guaranteed-stale credential that `rc auth refresh` could no longer fix without a recreate. The live mount is what lets a host-side refresh reach a running cage. `~/.claude.json` is project state, not an expiring secret, so a boot-time snapshot costs nothing there — and it is mounted `:ro`, because read-write would hand a prompt-injected agent a write into the `mcpServers` and `hooks` your **host** Claude later executes.

---

## Non-possession — the `--secret` path

A `secrets:` entry in the cage config binds a credential **name** to the hosts it may be injected toward. msb injects the real value on the wire toward those hosts only; the guest holds the string `$MSB_<NAME>` — on disk, in its environment, in `/proc`.

```yaml
secrets:
  CCTOK:
    allow:
      - "api.anthropic.com"

env:
  CLAUDE_CODE_OAUTH_TOKEN: "$MSB_CCTOK"
```

**Leave `value:` out.** msb's schema has the field; filling it would put the secret in a file you edit, which is the one thing this shape exists to avoid. Omitted, msb resolves the value from the **host environment variable of the same name** at boot.

**Where that variable comes from, unattended.** Requiring you to export it before every launch would put a human in the loop on a walk-away run. So `rc up` reads the value from `$XDG_CONFIG_HOME/rip-cage/secrets/<NAME>` when that file exists and exports it for the launch — host-side, outside every cage mount, the same location class as the protected-paths list. If the file is absent, export the variable yourself; msb fails loud naming it.

**Nothing bridges this to the keychain.** `rc auth` writes your Claude login to `~/.claude/.credentials.json`, which gets mounted; it does not write it into the secrets directory. So the example above puts a cage in non-possession **only if you put a token at `~/.config/rip-cage/secrets/CCTOK` yourself**. A cage whose config declares `CCTOK` while `rc up` also mounts the credentials file is still holding the real token in the guest — the mount is what Claude Code actually reads.

Closing that gap is `rip-cage-ely4.7.17`: `rc auth` writes the token under `rip-cage/secrets`, and `rc up` stops mounting the file once the secret is declared. Not shipped.

`rc doctor` reports the posture:

```
auth : OK — non-possession posture (CLAUDE_CODE_OAUTH_TOKEN present; msb --secret-injected auth)
```

Full design and the tiering judgment: [secret-posture.md](secret-posture.md).

---

## pi auth

pi stores credentials at `~/.pi/agent/auth.json` (mode 0600, auto-refreshed). `rc up` mounts that file read-write at `/home/agent/.pi/agent/auth.json` and sets `PI_CODING_AGENT_DIR` ([ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D1).

**First run:** if the host file does not exist, `rc up` seeds an empty `{}` so the mount fires. Then, inside the cage:

```
pi /login
```

pi writes in place to the mounted file, so the credential lands on the host immediately and survives every later recreate. If seeding fails — a symlink at that path, a permissions error — `rc up` warns and skips the mount; pi's own `/login` surfaces the problem on first request. Rip cage adds no startup auth banner: banners get banner-blind fast, and pi's own prompt is the right surface ([ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D2).

**Providers.** pi supports Anthropic, OpenAI (including Codex via ChatGPT OAuth), Gemini, Mistral, Groq, Cerebras, xAI, OpenRouter, Azure OpenAI and more — see [pi's provider docs](https://github.com/mariozechner/pi-coding-agent/blob/main/docs/providers.md). `rc up` forwards a fixed set of provider API-key variables from host to guest when they are set and non-empty. When `auth.json` is also present it wins, which is pi's own precedence.

`rc auth refresh` is **Claude-only**. pi refreshes its own credentials against the mounted file; no rip-cage helper is involved. Generalizing credential discovery to pi's Codex login is [roadmap](../ROADMAP.md), not a claim.

### Subscription auth — read before using

> Two subscription OAuth flows raise policy questions.
>
> - **pi → OpenAI Codex (ChatGPT Plus/Pro):** pi's own docs carry a "personal use only" statement for this flow. Driving automated agent sessions with it sits in a gray area under the [OpenAI Service Terms](https://openai.com/policies/service-terms/).
> - **pi → Anthropic OAuth (Claude Max/Pro):** this sends subscription credentials through a third-party harness. Anthropic's January 2026 enforcement action against third-party Claude access tools applies; review the [Anthropic Consumer Terms](https://www.anthropic.com/legal/consumer-terms).
>
> There is no runtime banner for this ([ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D6) — you have already opted in by running `pi /login`. The callout lives here, findable and version-controlled.

### Why rip-cage ships no paranoid mode

A related project takes the opposite approach: an `LD_PRELOAD` syscall firewall, a V8 filesystem hook, a SUID vault binary, and removal of `su`/`mount`/`passwd`. Rip cage deliberately declines all of it ([ADR-019](../decisions/ADR-019-pi-coding-agent-support.md) D7).

That project targets a motivated attacker. Rip cage's threat model is an autonomous agent's *accidents*, plus injected instructions it follows in good faith. Adversarial mitigations add fragility and detection-evasion-flavored UX: a write blocked at the `LD_PRELOAD` level makes an agent retry and fail confusingly, which trades away the autonomy the cage exists to protect. The layers rip-cage already runs catch the realistic failure modes.
