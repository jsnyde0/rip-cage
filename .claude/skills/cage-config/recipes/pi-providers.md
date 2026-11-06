# Recipe: in-cage pi on OpenRouter or the OpenAI subscription

pi in a cage gets its model credential the same way Claude Code does: an msb
`secrets:` entry, so the guest holds a placeholder and msb puts the real value
on the wire. rc never mounts the host's `~/.pi/agent/auth.json` into a cage.

Two providers are proven ([`tests/test-pi-e2e.sh`](../../../../tests/test-pi-e2e.sh)):
**OpenRouter** (an API key) and **openai-codex** (the OpenAI ChatGPT
subscription). **Never point pi at the Anthropic subscription** — no pi
provider rides CCTOK. Every block below already sits commented out in the
shipped template; this recipe says which lines to uncomment and what to save
host-side.

## OpenRouter (API key)

1. Save the key host-side, one line, mode 0600:
   `~/.config/rip-cage/secrets/OPENROUTER`.
2. In the cage config, uncomment:

   ```yaml
   secrets:
     OPENROUTER:
       allow:
         - "openrouter.ai"
   env:
     OPENROUTER_API_KEY: "\x24MSB_OPENROUTER"   # "\x24" is YAML for "$"
   network:
     allow:
       - "openrouter.ai:tcp:443"
   ```

Check: `pi -p --provider openrouter --model openai/gpt-4o-mini 'say hi'` inside
the cage answers.

## openai-codex (OpenAI ChatGPT subscription)

pi decodes this token inside the guest to read your account id, so a plain
`$` + `MSB_CODEX` placeholder fails. The placeholder is a fake token carrying only
that id, and the guest gets an auth.json holding it.

1. Log in on the host once: `pi`, then `/login` to the OpenAI (ChatGPT)
   subscription (provider `openai-codex`).
2. Run the host helper. It writes three files and prints the placeholder:
   `~/.config/rip-cage/secrets/CODEX` (the real token, 0600),
   `~/.config/rip-cage/pi-codex/auth.json` (pi-shaped placeholder, used here),
   and `~/.config/rip-cage/codex-cli/auth.json` (codex-shaped placeholder, for
   a cage that also runs codex — `examples/codex/`):

   ```bash
   <rc install dir>/examples/pi-providers/codex-secret.sh
   ```

3. In the cage config, uncomment and fill:

   ```yaml
   mounts:
     - "<ABSOLUTE_PATH_TO_YOUR_HOME>/.config/rip-cage/pi-codex/auth.json:/home/agent/.pi/agent/auth.json:ro"
   secrets:
     CODEX:
       allow:
         - "chatgpt.com"
       placeholder: "<the line codex-secret.sh printed>"
   network:
     allow:
       - "chatgpt.com:tcp:443"
   ```

   The placeholder only changes if your account changes; paste it once. Keep
   it out of files the caged agent reads: msb before 0.7.5 drops a request
   whose body quotes a bound placeholder (microsandbox#1354); msb 0.7.8 passed
   one unchanged in the codex spike (`docs/2026-11-06-codex-cli-in-cage-spike.md`
   Q3).

Check: `pi -p --provider openai-codex --model <id> 'say hi'` inside the cage
answers. Pass `--model` explicitly; the image's pi may list stale model ids.

**Freshness.** The host pi keeps the real token fresh; the access token lives
about ten days. msb reads `secrets/CODEX` only when the cage starts (create,
or resume of a stopped cage), and that file is only as fresh as your last
helper run. On a 401 from chatgpt.com inside the cage: run host `pi` once with
`--provider openai-codex`, re-run the helper, then `rc up --replace <project>`
(or `msb stop <cage>`, then `rc up <project>`). A plain `rc up` on a running
cage only attaches and keeps the old token. rc never refreshes the token
itself, and the guest cannot: its refresh token is a placeholder.

## Done when

`rc up` succeeds, the check prompt for each enabled provider answers inside the
cage, and `printenv` in the cage shows only `$` + `MSB_<NAME>` placeholders for them.
