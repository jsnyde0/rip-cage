# pi-providers — host helper for in-cage pi on the OpenAI subscription

One host-side script, `codex-secret.sh`. Run it on the host before `rc up`
when a cage's pi uses provider `openai-codex` (the OpenAI ChatGPT
subscription). It reads the host pi's auth.json, writes the real access token
to `~/.config/rip-cage/secrets/CODEX` for msb to inject on the wire, writes a
placeholder auth.json for the guest, and prints the placeholder for the cage
config. It also writes the same placeholder in the Codex CLI's shape at
`~/.config/rip-cage/codex-cli/auth.json`, for a cage that runs `codex`
([`examples/codex/`](../codex/)). `codex-secret.sh --print-placeholder` prints
it and writes nothing.

Not floor, never on by default (ADR-005 D12). Nothing in `rc` knows this
script exists or reads pi's files; it is composition you run yourself.

The steps, the config lines, and the token-freshness loop live in the
`cage-config` skill:
[`.claude/skills/cage-config/recipes/pi-providers.md`](../../.claude/skills/cage-config/recipes/pi-providers.md).
OpenRouter needs no helper — that recipe covers it too.
