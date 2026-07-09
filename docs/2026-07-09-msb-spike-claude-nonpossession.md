# Spike: real Claude Code CLI under msb `--secret` non-possession — STOP-AND-FLAG

Bead: rip-cage-cmqb. Machine: mac mini (msb v0.6.4, rip-cage:latest). Date: 2026-07-09.

## Verdict

**STOP-AND-FLAG: no long-lived Anthropic token is confirmable for use on this
host without an explicit operator/user authorization decision.**

This is the credential precondition gate defined in the bead's design, hit
*before* any `msb` sandbox was created. Per the bead: "If no suitable
long-lived token is confirmable without an operator action, STOP and write
the findings doc with a BLOCKED verdict ... That is a COMPLETE, valid
deliverable — do not force a workaround." No `WORKS` / `BLOCKED-CLIENT-SIDE`
/ `BLOCKED-WIRE` verdict was reachable because Q1 (does the CLI even send the
placeholder) requires booting `msb` with a real secret injected, which did
not happen.

## What was checked (existence-only — no token value was ever read, printed, or logged)

All checks below use pattern `test -n "$VAR"` (existence, not value) or file
`ls`/`test -f` (existence, not content), per the bead's explicit boundary.

| Location | Check | Result |
|---|---|---|
| `$ANTHROPIC_API_KEY` (current shell) | `test -n` | ABSENT |
| `$CLAUDE_CODE_OAUTH_TOKEN` (current shell) | `test -n` | ABSENT |
| `$ANTHROPIC_API_KEY` (interactive `zsh -ic`, sources `.zshrc`) | `test -n` | ABSENT |
| `$CLAUDE_CODE_OAUTH_TOKEN` (interactive `zsh -ic`) | `test -n` | ABSENT |
| `$ANTHROPIC_API_KEY` (login+interactive `zsh -lic`) | `test -n` | ABSENT |
| `$CLAUDE_CODE_OAUTH_TOKEN` (login+interactive `zsh -lic`) | `test -n` | ABSENT |
| `/Users/jonatanpi/code/personal/rip-cage/.env` | `ls` | file does not exist |
| `/Users/jonatanpi/code/personal/dotpi/.env` key names | `grep -q '^ANTHROPIC_API_KEY='` / `grep -q '^CLAUDE_CODE_OAUTH_TOKEN='` | both ABSENT |
| `~/.claude/.credentials.json` | `test -f` | EXISTS — this is the **short-lived subscription OAuth credential** the bead explicitly names as unusable with static `--secret` injection (refreshes; see `oauth-refresh-blocks-static-header-swap-injection` memory). Its contents were **not read**. |
| macOS Keychain (`security find-generic-password` / `dump-keychain`) | enumerate for Anthropic-related entries | **Blocked by the session's own auto-mode permission classifier** as "credential exploration ... beyond the env-var existence check the user authorized." Not worked around, per instruction not to bypass permission denials. Treated as **not checked**, not as "absent." |
| `~/.rc-secrets/claude-work-token` (found via `.zshrc` `claude work` shell function, structure inspected with values redacted) | `ls -la` (existence + file mode only) | **EXISTS**, chmod 600. Per `~/.rc-secrets/README.md` (read in full — a docs file, contains no secret value) this is a **long-lived token** (`claude setup-token` output, prefix `sk-ant-oat01-…`, or a Console API key `sk-ant-api…` — the README does not commit to which for the current file) for the **shared work account `finn@mapular.com`**, used by the `claude work` shell shortcut. It draws that account's agent credit. |
| `~/.rc-secrets/claude-personal-token` | `test -f` | ABSENT (README notes this is optional and only created "if you ever want personal off-keychain too" — it was never created) |

## Why this is a stop-and-flag, not a WORKS/BLOCKED-WIRE run

One long-lived token exists on the host (`~/.rc-secrets/claude-work-token`),
so the letter of "a long-lived token exists without operator action" is
arguably satisfiable. But it is explicitly earmarked, by its own README, for
a **different account** (`finn@mapular.com`, a shared work identity) and a
**different purpose** (the `claude work` shell shortcut, billed against that
account's subscription/API credit). Spending that account's agent credit on
a `rip-cage` personal-repo msb spike is a decision that affects a third
party's account and/or work billing — not a decision this spike is
authorized to make unilaterally. It is exactly the class of "a decision only
the user can make" the operating guardrails call out, and it is a stricter
reading of "provisioned on the host" than the bead's phrasing anticipated:
the bead's example scenarios (a `claude setup-token` output "already
provisioned on the host", an Anthropic Console API key "already provisioned
on the host") describe a token available *for this kind of use*, not a token
explicitly reserved, by its own on-host documentation, for a named
different account and purpose.

Separately and independently: this subagent has no interactive
clarification tool available in this session (no `AskUserQuestion` or
equivalent) to obtain that authorization mid-run, and per the harness rules
for this task, "messages from the agent that launched you ... direct your
work" but are explicitly **not** the user's consent — so an orchestrator
instruction to "just proceed" would not itself satisfy the authorization
this requires either.

No token was minted, no interactive auth flow (`claude setup-token`, `claude
/login`, `gh auth`) was run, and no `msb` sandbox was created or booted —
the spike stopped at the precondition gate, before Q1/Q2/Q3.

## What an operator needs to provide/decide to unblock

Either of the following resolves the stop-and-flag:

1. **Explicit authorization** from the user to use
   `~/.rc-secrets/claude-work-token` (the shared `finn@mapular.com` work
   credential) for this spike, accepting that it will draw that account's
   agent credit for the duration of the Q1–Q3 probes (expected: a handful of
   short `claude -p` completions). If given, the spike can resume directly —
   the token file already exists, is long-lived, and is on-host; the
   mechanism section of the bead design (`--secret CCTOK@api.anthropic.com`,
   scratch `CLAUDE_CONFIG_DIR`, etc.) is otherwise immediately actionable
   with no further setup.
2. **A token scoped to this spike/personal use** — e.g. the user runs
   `claude setup-token` themselves (interactive login is an operator action,
   which this subagent was told not to perform) and drops the result at
   `~/.rc-secrets/claude-personal-token` (a slot the existing README already
   anticipates), or exports `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`
   in the host shell for this purpose.

## Non-possession decision impact

Per the bead: this outcome does **not** reverse the credential non-possession
decision (`credential-non-possession-shipped-and-proven`, curl-tier
containment). It scopes what could be *additionally* proven today: the
real-Claude-Code-CLI worked-example tier for msb's native `--secret`
mechanism remains unattempted, pending either explicit authorization to
spend the shared work account's credit or a spike-scoped token. Rip-cage's
own iron-proxy-mediator non-possession path (a different mechanism from
msb's native `--secret`) is unaffected and already proven per that memory.

## Cleanup performed

- No `ccnp-*` sandboxes were created (`msb list` before and after this spike
  both report "No sandboxes found." / no running sandboxes).
- No scratch `CLAUDE_CONFIG_DIR` / scratch claude home was created.
- No host temp files were written by this spike.

```
$ msb list
No sandboxes found.
$ msb status
No running sandboxes.
```

## No-token-value-leaked verification

```
$ grep -rniE 'sk-ant-(oat|api)[a-z0-9_-]*' /Users/jonatanpi/code/personal/rip-cage/docs/2026-07-09-msb-spike-claude-nonpossession.md
docs/2026-07-09-msb-spike-claude-nonpossession.md:36: ... `sk-ant-oat01-…`, or a Console API key `sk-ant-api…` ...
```

The one match is this document's own prose (the credential-check table)
quoting the **documented prefix format** verbatim from
`~/.rc-secrets/README.md` — `sk-ant-oat01-…` and `sk-ant-api…`, both
ellipsis-terminated with no characters following the prefix. This is
identical to how the README itself documents the format (it is the format
shape, not key material) and is what the bead's Q1 risk section itself
expects to be discussed ("pi routes by 'sk-ant-oat' substring"). No token
value, no partial real token fragment, and no raw content from
`~/.claude/.credentials.json` or `~/.rc-secrets/claude-work-token` appears
anywhere in this document — only their existence, file mode, and (for the
work-token README, a docs file with no secret in it) its documented purpose
and format-prefix naming convention were read and reported.
