# ADR-032: Host-tool line — a declared, typed call from the cage to a host command

**Status:** Proposed — 2026-11-06, bead `rip-cage-mgp6`; decisions human-ratified in-pane in one brainstorm sitting (rulings recorded as comments on that bead), then two fresh-context adversarial review rounds folded before filing (records on that bead). The code lands under the epic filed from that sitting; this ADR is the canon it implements.

**Firmness:** per-decision, see each Dn. D1, D2, D3, D4, D5 FIRM (D2 and D3 each carry a FLEXIBLE vocabulary inside the FIRM rule, stated in the decision); D6, D7 FLEXIBLE.

**Citation form:** `rip-cage ADR-032 D<k>`. Bare `ADR-032` is ambiguous across corpora (see rip-cage ADR-031's citation note).

## Context

msb `--secret` gives a caged agent the use of a credential without possessing it — for exactly one shape of secret: a value msb can substitute into an HTTP header, query or body on a TLS-intercepted flow toward an allowed host (rip-cage ADR-029 D5). A second class exists that it cannot reach: protocols that are not HTTP (Telegram's MTProto, SSH, IMAP/SMTP, database wires), HTTPS where the key *signs* the request instead of being sent (AWS SigV4, HMAC APIs), and tools whose reply would hand a key back (token refresh). For that class the operator of the `switch-desk` project improvised cage-to-host plumbing by hand — a gate on the Docker bridge, a command-shape table, a unix-socket keyholder process, a Telegram approval card — and the human ruled that this plumbing is not a project's job but rip-cage's (`switch-desk` bead `sd-952`, 2026-11-06).

Three research files precede this ADR and are its evidence base: `docs/2026-11-06-host-tool-line-R1-prior-art.md` (rip-cage never had a configured host-tool line; the nearest things — the ADR-026 D5 mediator seam and ssh-agent forwarding — retired when `--secret` made them redundant, and the ssh forward also leaked every host key), `-R2-risks.md` (the must-holds: argv-only exec, verb parameters constrained host-side, no credentials in replies, an authenticated or non-network channel; a host-tool line is a path *around* the egress allowlist), and `-R3-msb-native.md` (msb has had `--vsock HOST_PATH:PORT` since 0.6.9: the guest dials AF_VSOCK CID 2, msb connects it to a host unix socket, no TCP, no LAN, outside the network policy; it is a create-time flag with no `--conf` key; msb has no host-exec or hook surface).

Measured in the sitting (msb 0.7.8, Linux/KVM, scratch sandbox, `rip-cage-mgp6` comments): bytes cross under `network.policy: none` with egress still denied; a neighbouring port without a route is refused instantly; the route survives `msb stop`/`start`; a missing host socket is a fast connect error, never a boot failure, and recovers when the socket reappears; **a dead gatekeeper behind a live route produces the same fast connect error as no route at all**; the route is visible at `msb inspect --format json` under `active_config.vsock.routes[]`; **payloads of 64 KiB and above stall or time out.** `brain:switch-desk` confirmed (mail, 2026-11-06 16:15) that every keyholder request fits under 32 KiB, three replies need paging, paging is acceptable, and no bulk transfer is planned.

## Terms

- **Host tool** — an operator-owned command on the host that holds, or can reach, a credential the cage must never possess. rip-cage names none.
- **Line** — the whole mechanism this ADR defines: declaration, channel, gatekeeper, in-cage client. One line per cage; many tools and verbs on it.
- **Declaration** — the host-side file listing, per tool, the verbs the cage may call: each verb's fixed command line, its typed slots, its timeout, and whether its reply may carry a credential.
- **Verb** — one named call on one tool, mapped to one fixed host command line.
- **Slot** — a typed hole in a verb's command line that the agent's argument fills after validation.
- **Gatekeeper** — the host-side process rip-cage ships: it listens on the line's unix socket, validates each call against the declaration, runs the command as an argv array, and returns a typed reply. **Every decision the line makes is made here.**
- **`host-tool`** — the in-cage client baked into the base image. It is the shipped convenience door, not a boundary: any guest process could dial the vsock port, and the gatekeeper would treat it identically.
- **State directory** — `${RC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rip-cage}/<cage>/`, new with this ADR; rc keeps the line's socket, pid, normalized declaration and log there. It is also every tool's working directory, and it is added to the protected-paths list so no cage can mount it.

## Decisions

### D1: rip-cage owns the line as a generic seam and names no tool

**Firmness: FIRM** (human-ratified in-pane 2026-11-06, "A" on the own-it-or-not decision; consequence of rip-cage ADR-005 D12)

rc owns the mechanical parts that are identical for every tool: the channel, the declaration schema and its validation, the gatekeeper, the in-cage client, lifecycle, and doctor/test visibility. The tool, its verbs, and anything that wraps a verb (approval, rate limits, allowlists) are operator composition, declared in config and never special-cased in rc. A worked declaration and wrapper live under `examples/`, never in the binary.

**Rationale:** `direct:` R2 §1 and §4 — the dangerous part of a host-tool call is the argument check, not the pipe; if every tool re-implements it, the second tool is the one that forgets. `direct:` the human, in-pane: "it puts the dangerous part in one place, written once." `reasoned:` a generic validator in front of an operator's command is a composition interface in rip-cage ADR-005 D12's sense, the same shape as the retired ADR-026 D5 mediator seam ("rc owns the interface, blesses no mediator, none by default").

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Channel only: rc provides the vsock route; each tool validates its own verbs and approvals | `reasoned:` leaves R2's must-holds (argv-only, constrained parameters) to every tool author; one sloppy tool is a host hole. `direct:` the human chose A over B after this exact framing. |
| Nothing in rc; the desk keeps its plumbing | `direct:` `sd-952` — the human ruled the plumbing is not the desk's job. |
| A Telegram-specific line | `direct:` rip-cage ADR-005 D12 forbids rc naming a tool. |

**What would invalidate this:** a second operator building their own validator *beside* the gatekeeper because its slot vocabulary cannot express their verb — that is the cue D3's vocabulary is too narrow, not that D1 is wrong.

### D2: The declaration is a host-side sibling file, read by rc and never merged into the msb config

**Firmness: FIRM** (the location rule and the "never merged" rule; the file name and schema below are FLEXIBLE. Human-ratified in-pane 2026-11-06, including the one-sentence amendment to rip-cage ADR-031 D2 this requires)

The declaration lives next to the project config, as `$XDG_CONFIG_HOME/rip-cage/projects/<cage>.tools.yaml`, in the directory rip-cage ADR-031 D5(a) already reserves for composition inputs: host-side, outside every cage mount, never on a path a cage config can point at. rc reads it at `rc up` and refuses to launch unless every check passes: the declaration file itself and the state directory lie outside every mount; **every element of every `argv` that is an absolute path — the command, an interpreter's script, a wrapper's target — resolves (symlinks followed) to a location outside every mount the cage will actually get** (the config's rows plus the mounts rc computes: worktree `.git`, skill-symlink parents, the substrate projection); `argv[0]` is absolute, exists and is executable; relative elements resolve against the state directory, which is every tool's working directory, never against `rc up`'s cwd; placeholders and slots match one-to-one; no unknown keys. The projects directory and the state directory join `share/rip-cage/protected-paths`, so the existing mount rule refuses a config that mounts either. rc merges nothing from it into the msb config; the msb file stays whole and native. With no declaration present there is no route, no socket, no gatekeeper.

Minimal schema (FLEXIBLE; the `cage-config` skill is its documentation home):

```yaml
tools:
  <tool-name>:
    verbs:
      <verb-name>:
        argv: ["/abs/path/to/command", "sub", "--chat", "{chat}", "--limit", "{limit}"]
        slots:
          chat:  {type: string, regex: "^-?[1-9][0-9]*$", allow_dash: true}   # negative ids are legitimate here
          limit: {type: int, min: 1, max: 100, default: 20}
        timeout: 30s            # per verb; a verb that waits on a human declares a long one
        returns_secret: false   # D5
```

**Rationale:** `direct:` rip-cage ADR-031 D5(a) — everything that defines authority lives where the caged agent cannot reach it; R2 §6a names the self-escalation that follows from a declaration in a workspace file, and the same escalation follows from a *script path* inside a mount (`["/usr/bin/python3", "/workspace/tool.py"]`), which is why every path element is checked, not only the command. `direct:` msb's `--conf` loader is `deny_unknown_fields` (R3 a1, e1), so the declaration cannot live in the msb file. `reasoned:` the protected-paths list is already a second host-side data file rc reads under rip-cage ADR-031 D2; this is the same kind of thing, and it is not a merge: rc never writes it into the msb config, it only acts on it (a launch flag and a host process), which is the carve-out rip-cage ADR-031 D3 already names for `--name`, `--log-level`, computed mounts and covers.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Upstream a `vsock:` key to msb's `--conf` and keep everything native | `reasoned:` solves the route only; verbs, slots and timeouts still have no native home. Worth doing later for the route alone (D6 predicate), not a substitute. |
| Smuggle the declaration through a native key (`labels:`, `env:`) | `reasoned:` a schema encoded in label strings is a transpiler in disguise, the thing rip-cage ADR-031 D2 struck. |
| Declare tools in the workspace (`.rip-cage/tools.yaml`) for convenience | `direct:` rip-cage ADR-031 D5(a); R2 §6a — an injected agent would widen its own verbs. |
| Check only `argv[0]` against the mounts | `reasoned:` an interpreter plus a mounted script is host code execution from the workspace; the check is on every path element or it is not a check. |
| A shared host-wide tool library referenced by name | `reasoned:` reuse is real (a keyholder serves several cages) but adds a second file and a resolution rule before any consumer exists; held as fog in the epic. |

**What would invalidate this:** msb ships additive `--conf` layering *and* a native host-tool schema — then the sibling file folds into the msb file through the `cage-config` skill, never through merge code in rc.

### D3: A verb is a fixed command line with typed slots, executed as an argv array, never a shell

**Firmness: FIRM** (the rule; the slot vocabulary and caps below are FLEXIBLE. Human-ratified in-pane 2026-11-06, after the correction that the gatekeeper runs commands, not daemons)

The gatekeeper fills a verb's declared `argv` template from the agent's named arguments, one slot per placeholder, after validating each value against its slot type. It then executes that array directly. No code path joins agent text into a command string; no shell is involved. Validation is strict by construction: regexes are anchored full-matches; every string slot rejects control characters, newlines and NUL; an `int` slot accepts only a JSON integer (never a boolean, never a numeric string); values beginning with `-` are rejected unless the slot declares `allow_dash: true`; unknown arguments, missing required slots, unknown verbs and unknown tools are typed errors, and the error names the slot, never the value. A positional separator (`--`) is the template author's choice, placed in `argv` where the tool wants it; the gatekeeper does not insert one because the template is fixed and the slots cannot move.

Caps and bounds (FLEXIBLE defaults): the **encoded** request line and the **encoded** reply line are each capped at 32 KiB — the cap is measured on the bytes that cross the vsock, not on the tool's raw stdout, so JSON escaping cannot push a reply past the measured 64 KiB stall; a per-verb timeout; a per-cage concurrency bound. A command runs in its own session (process group); on timeout the whole group is killed, so a wrapper's grandchildren cannot outlive the call or hold the pipes. A command's exit status and stdout are the whole reply surface: stdout is read with a bound of the cap plus one byte and returned as the result; a request over the cap is `request-too-large` (refused, nothing ran); a reply over the cap is `reply-too-large` (the command **ran**, the group is killed at the bound, nothing partial is returned) — two kinds, because an agent must never retry a side-effecting verb believing it did not run; non-zero exit yields `tool-failed` with **no stderr, path or traceback forwarded** — raw stderr goes to the host-side log (R2 §3b).

Initial slot vocabulary (FLEXIBLE): `string` (max length, optional regex), `int` (min, max), `enum` (values), each with an optional `default`. There is deliberately **no path slot** in the first cut (R2 §1c); a tool that needs a file takes it through a mount, not an argument.

Long-lived tools (a Telegram session that must stay logged in) are the operator's business: the declared command is that tool's own small client, and keeping the daemon alive is not rc's job. rc checks at `rc up` that the command exists and is executable, nothing more.

**Rationale:** `direct:` R2 §1a–1b (host RCE from a prompt-injected agent via shell metacharacters or option smuggling; "cheapest mitigation: rc execs an argv array, never a shell"). `direct:` the human, in-pane: ssh signing and git push are plain host commands and must not need a daemon. `direct:` the desk's keyholder already exposes exactly such a client (`keyholder-telegram <verb>`), reached by the desk's gate via argv. `reasoned:` one mode (exec) is less surface than two (exec plus socket-forward) and already covers the daemon case through its client. `direct:` review round 1 — the 32 KiB cap on raw stdout would have let a 6× JSON-escaped reply reach the stall; `$`-anchored regexes admit a trailing newline; Python's `bool` is an `int`; `subprocess` kills only its direct child.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Forward framed JSON to the tool's own unix socket | `reasoned:` two modes for one job; the daemon case is already served by exec-ing the daemon's client. Held as fog if a tool appears with no CLI. |
| Shell template with quoting | `direct:` R2 §1a; quoting is the bug class, not the fix. |
| Trust the tool to validate its own arguments | `direct:` D1's warrant — the check is the dangerous part and belongs in one place. |
| Gatekeeper inserts `--` before positionals (R2 constraint 1) | `reasoned:` meaningful for free-form argv, not for a fixed template where the author places slots and separators; inserting one blindly breaks tools that take no `--`. |
| A per-session call budget (R2 §4c) | `reasoned:` deferred: timeouts plus the concurrency bound cover the runaway case; a budget needs a reset policy nobody can state yet. Fog in the epic. |

**What would invalidate this:** a legitimate verb that cannot be expressed as fixed argv plus typed slots (streaming input, a path the tool must open itself). The cue is an operator wrapping the gatekeeper in a shell script to get around it — widen the vocabulary then, never relax the no-shell rule.

### D4: rc has no approval concept

**Firmness: FIRM** (human-ratified in-pane 2026-11-06: "I'm not sure rc needs to know about all this stuff; we just want to provide the clean mechanical seam")

Nothing in the declaration, the gatekeeper or the client knows the words approval, hook, card or policy. A verb that should ask before it acts is declared with a wrapper command that asks however the operator likes — show a card and wait, check a recipient allowlist, rate-limit — and then runs the real command or exits non-zero. The only things rc gives that case are D3's per-verb timeout, so a verb that waits on a human declares a long one, and D3's typed "tool failed" reply, so a denied agent carries on with other work instead of hanging. **A wrapper has no terminal:** it runs from the gatekeeper with stdin closed, detached from any session; a recipe that asks must ask through something that is not a prompt on stdin. A worked ask-then-run wrapper is an `examples/` recipe.

**Rationale:** `direct:` the human struck the hook as "bringing in how something else externally works into rc." `reasoned:` an approval protocol is the highest-drift part of the whole design (today a desk card, tomorrow something else); rip-cage ADR-026 D2's drift-rate test puts it outside rc. `reasoned:` nothing is lost on safety: the gatekeeper validates the arguments before the wrapper sees them, and because the wrapper both asks and runs, R2 §2b's approved-versus-executed gap closes by construction. `direct:` CLAUDE.md — approval off by default keeps the autonomous path unblocked.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| A per-verb `approve:` hook in the declaration, fail-closed on anything but an explicit ALLOW | `direct:` the human struck it; `reasoned:` rc would own an approval protocol it cannot keep aligned with whichever app shows the card. |
| Approval inside the gatekeeper as an allowlist DSL | `reasoned:` a policy language is exactly the content-policy business rip-cage ADR-026 D1 keeps out of rc. |

**What would invalidate this:** several operators independently writing the same ask-then-run wrapper shape — that is a cue for a better `examples/` recipe, and only if the shapes converge byte-for-byte a cue to reconsider a hook.

### D5: Replies never carry a credential unless the verb declares it

**Firmness: FIRM** (human-ratified in-pane 2026-11-06: "of course!"; consequence of rip-cage ADR-029 D5 and ADR-030)

A verb whose reply must hand the cage a real secret (the token-refresh class) sets `returns_secret: true` in the declaration. `rc doctor` lists such verbs as possession-mode for that cage. The preferred shape for refresh is the tool writing the new value to the host-side store msb `--secret` substitutes from, so the guest keeps its placeholder; a verb that returns the secret is the explicit exception. rc never scrubs reply content (it does not read it; rip-cage ADR-026 D1) — the declaration is the only honesty mechanism.

**Rationale:** `direct:` R2 §3a — a returned key defeats non-possession directly and is the class's sharpest conflict with rip-cage ADR-029 D5. `direct:` the desk keyholder already returns no credential on any verb.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Scrub replies for secret-shaped strings in the gatekeeper | `direct:` rip-cage ADR-026 D1 — rc never reads application content; `reasoned:` pattern scrubbing is a false floor. |
| Forbid secret-returning verbs outright | `reasoned:` the token-refresh class is one of the three reasons the line exists; a declared, visible exception is honest, a ban pushes it into an undeclared verb. |

**What would invalidate this:** a cage with a `returns_secret` verb that nobody notices in `rc doctor` — the cue that visibility, not the rule, needs work.

### D6: The channel is msb `--vsock`; the parts, their environment, and their lifecycle

**Firmness: FLEXIBLE** (mechanism measured once, Linux/KVM, msb 0.7.8; macOS/HVF unmeasured — see the epic's spike)

- **Route.** When a declaration exists, `rc up` appends `--vsock <state>/host-tool.sock:7700` to the `msb create` argv it already assembles (within rip-cage ADR-031 D3's "what no config file can hold"). The port is the constant `7700`, defined once in rc and once in the client; the socket path is under the state directory, mode 0600, owned by the operator, and `rc up` refuses with a clear error if that path exceeds the platform's unix-socket limit (104 bytes on macOS), naming `RC_STATE_DIR` as the override. The route is a create-time shape and depends only on whether a declaration **exists**, so `rc up` stamps a create-time label `rc.host-tools=present|absent` beside the existing `rc.cage-conf-sha` label (rip-cage ADR-028 D1 instance, no minted state file) and the stopped-cage converge rip-cage ADR-031 D3 already runs recreates the cage when presence changed. Declaration **contents** never force a recreate: the gatekeeper reads the file fresh at every start.
- **What takes effect when.** Honest and the same shape as an egress-allowlist edit: on a **stopped** cage, plain `rc up` applies everything (presence via converge, contents via the gatekeeper's fresh start). On a **running** cage, `rc up` only attaches; it restarts the gatekeeper only if it is dead, never kills a live one (in-flight calls, including a pending ask-then-run wrapper, finish), prints one line when the file differs from what the gatekeeper loaded — "host-tool declaration changed; takes effect on `rc up --replace`" — and `rc doctor` reports the same drift. **Revocation on a running cage therefore needs `rc up --replace`**, exactly like a tightened allowlist. `--no-reload` with a presence change is refused with a clear error (a route without a gatekeeper, or the reverse, is not a state rc will create).
- **Gatekeeper.** One process per cage, started by `rc up` **after** `msb create`/`msb start` returns success and before init runs, from the current declaration. The gatekeeper itself calls `setsid()` at startup (macOS ships no `setsid` binary), writes its own pid file after that, redirects stdio to the log, and so survives the attached terminal's hangup. rc takes a lock only around the start/stop section — never across attach — releases the lock's descriptor before launching so the child does not inherit it, and on macOS uses a pid-carrying `mkdir` lock treated as stale when its pid is dead. rc waits up to 5 s for the pid file and a listening socket; if the gatekeeper fails to start, `rc up` exits non-zero naming the log, the cage stays as created with no line (the agent gets exit 5), and nothing is served half-configured. A stale socket whose pid is dead is unlinked before bind. The gatekeeper is stopped (SIGTERM, then SIGKILL after 5 s; socket and pid removed) by `rc destroy`, by `rc up --replace`, and when `msb create` or init fails before attach — **never** on attach exit, whose status is the user's shell. `rc doctor` reports a dead gatekeeper, an orphan, and declaration drift. No supervisor and no auto-restart.
- **Environment.** The gatekeeper rebuilds its own process environment at startup to **exactly** `PATH=<platform default>`, `HOME`, `LANG`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME` — an allowlist built from scratch, never a filtered copy — and runs every command with that environment and with the state directory as working directory. It is never `rc up`'s environment, which holds the real values of every `secrets:` entry under that entry's own name (`cli/up.sh`, `_up_prepare_conf_secret_env`). Tool-specific variables are the wrapper's job; a wrapper that needs a per-login value such as `SSH_AUTH_SOCK` sets it from a fixed, operator-known path. This is a floor property: a tool must not be able to read a secret out of its environment, and a wrapper calling a bare `jq` must not find one planted in a mounted `bin/`. The proof is an exact-key-set assertion, not a denylist check.
- **Host requirement.** Python 3 standard library on the host. The prerequisite check resolves `python3` to an absolute path under rc's own `PATH` (override `RC_PYTHON3`), runs `<abs> -c 'import socket, json, subprocess'` on that path, treats failure or a stub (macOS `/usr/bin/python3` without the Command Line Tools) as missing, refuses before any msb call, and launches the gatekeeper with that same absolute path — the check and the launch can never resolve different interpreters.
- **Client.** `host-tool <tool> <verb> [--<slot> <value>]...` is baked into the base image beside the floor probe and the skills shim, root-owned and not writable, and the floor probe asserts that through its guard-path list (check `guard-file /usr/local/bin/host-tool`). It dials AF_VSOCK CID 2 on port 7700, sends one JSON line, prints the result to stdout, and exits with a typed code: **0** ok; **2** refused, nothing ran (`no-such-tool`, `no-such-verb`, `bad-argument`, `request-too-large`); **3** the command ran and failed or its reply was withheld (`tool-failed`, `reply-too-large`); **4** the gatekeeper answered but could not run it (`timeout`, `busy`, `unavailable` — command vanished or could not be executed); **5** the line did not answer — connect reset or connect timeout — with one message naming all three causes (no declaration for this cage; declaration added but the cage not yet recreated; gatekeeper down) and `rc doctor` on this cage as the operator's next step. Reply timeouts come from the `list` reply, which carries each verb's declared timeout. The probe-checked baked file protects the agent from a tampered client misleading it; it is not what keeps the host safe — the gatekeeper is (rip-cage ADR-029 D2: every decision host-side).
- **Wire.** One JSON line per request — `{"v":1,"tool":"…","verb":"…","args":{…}}` — and one per reply — `{"ok":true,"result":"<stdout>"}` or `{"ok":false,"error":{"kind":"…","message":"…"}}` — with the closed error vocabulary `no-such-tool`, `no-such-verb`, `bad-argument`, `request-too-large`, `reply-too-large`, `timeout`, `tool-failed`, `busy`, `unavailable`. One built-in request, `{"v":1,"list":true}` (a separate field, so no tool or verb name is reserved), returns tool names, verb names, each verb's timeout, and each slot's name and type — never an `argv` template, never a host path. Unknown fields are rejected. The tool pages; the line does not stream.
- **Isolation.** The route exposes exactly one host endpoint, the declared socket; everything else the guest cannot reach is msb's property, unchanged by this ADR (egress still denied, measured). Host processes under the operator's uid can reach the socket too, which is no new capability — they can already run the command.

**Rationale:** `direct:` R3 "Cheapest native line" and the sitting's spike (every measurement above). `direct:` R2 §5 — the LAN-IP listener is open to the LAN and source address is useless for identity; vsock has no network. `reasoned:` baking the client follows how rc ships its other guest halves (floor probe, init, skills shim), and rip-cage ADR-008 D6's version-staleness check already covers image-versus-rc drift. `direct:` review rounds 1 and 2 — rc's environment carries the exported secret values; a `PATH` through a mount is a planted binary; an inherited cwd in the workspace turns a relative script path into workspace code on the host; a gatekeeper started before `msb create` is orphaned on a failed boot; attach exit is the user's shell status, not a failure; a running cage is the normal state and the ADR must say what `rc up` does there; a content hash would recreate a cage, with transcript-loss risk, for an edit that only needs a gatekeeper restart.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| `host.microsandbox.internal` + `allow host:tcp:<port>` (pure config) | `direct:` R3 a2 — unverified on 0.7.x, last rip-cage measurement was a fake-accept; `reasoned:` every loopback listener on that port becomes reachable, and callers are indistinguishable. |
| Host LAN IP (`rip-cage-o7tx`) | `direct:` R2 §5a–5c; `docs/2026-07-10-current-stack-parity-and-lan-exposure.md` B2 never measured. Dominated by vsock for this consumer. |
| Mount the client from the host at `rc up` instead of baking it | `reasoned:` a mount can be omitted by a config; a baked, probe-checked file cannot. |
| A per-call bearer secret on the wire | `reasoned:` unnecessary on a channel only the routed cage can reach; add only if a shared-socket shape ever appears. |
| Hash the declaration's contents into the converge check | `direct:` review round 2 — recreates a cage (transcript-loss risk) for an edit the gatekeeper's fresh start already applies; presence is the only create-time fact. |
| Restart a live gatekeeper on every `rc up` so edits apply to a running cage | `reasoned:` kills in-flight calls including a pending approval wrapper; the honest rule is the same as the allowlist's — `--replace`. |
| Restart the gatekeeper with backoff (R2 §7b) | `reasoned:` a supervisor is lifecycle machinery rc would then own; exit 5 plus a doctor line plus restart-on-`rc up` is the same autonomy outcome with less surface. |
| Inherit `rc up`'s environment into the gatekeeper, filtered | `direct:` review rounds 1–2 — that environment holds the real secret values under arbitrary names; a filter is a denylist and a denylist test cannot catch a denylist guard. |

**What would invalidate this:** the 64 KiB stall turning out to bite ordinary verbs in practice (the cue is operators raising the cap); msb exposing a `vsock` `--conf` key (then the route becomes config and rc stops appending it); or a measured failure on macOS/HVF.

### D7: Visibility — a line is a path around the egress allowlist, and rc says so

**Firmness: FLEXIBLE**

`rc doctor <cage>` lists every declared tool and verb beside `network.allow`, with one fixed sentence: a host tool reaches whatever its command reaches on the host; the egress allowlist does not see it. Verbs with `returns_secret` are listed as possession-mode. Doctor also reports a dead or orphaned gatekeeper, a declaration whose presence changed since the cage was created (recreate pending), and contents that differ from what the running gatekeeper loaded (`rc up --replace` pending). `rc test <cage>` proves, from inside the cage, that the declared socket answers, that a neighbouring port is refused, that ordinary egress is still denied, and that `host-tool` refuses an undeclared verb with the typed error — and names plainly that this is a sample of the route's scope, not a proof of msb's isolation. rip-cage ADR-024 D2's layer table gains a row for the host-mediated path (an epic child edits it in place).

**Rationale:** `direct:` R2 §4b and §11 — the allowlist stops being a sufficient exfiltration layer for any cage that has a line, and the honest move is to say that next to the allowlist, where the operator already looks.

**Alternatives considered:**

| Alternative | Rejection |
|---|---|
| Treat the line as covered by the existing egress story | `direct:` R2 §4b — default-deny egress never sees this traffic. |

**What would invalidate this:** an operator surprised that a verb sent data out despite a tight `network.allow` — the cue that the doctor line was not loud enough.

## What would invalidate this ADR

The line retires, in place, if msb ships a native way for a guest to trigger a declared host command with argument checking, or a `--conf` schema that makes the vsock route plus a verb table native. Partial fire: a native `vsock` key retires only D6's route-appending; the declaration, gatekeeper and client stay until the verb table is native too.

## Sibling reconciliation

- **rip-cage ADR-031 D2** — amended in place this sitting (human-ratified, one sentence): an rc-read declaration file is allowed for what msb's config cannot express, never merged into it.
- **rip-cage ADR-031 D3** — honoured: the `--vsock` flag is of the kind D3's carve-out names (a flag no config file can hold) and the declaration rides D3's converge-on-up rule; the six-verb set is unchanged (doctor and test grow output, no new verb). **Pending, not applied:** adding `--vsock` to D3's enumeration and naming the declaration in D5(a) as a composition input are two cross-reference sentences in FIRM text the human has not yet ratified; the epic's docs child carries them behind that ruling.
- **rip-cage ADR-031 D5(a)/(b)** — honoured: the declaration lives by D5(a)'s location rule; the floor probe gains a named `host-tool` check under D5(b).
- **rip-cage ADR-028 D1** — instance: the create-time `rc.host-tools=present|absent` label, compared on the stopped-cage converge, because the vsock route is a create-time shape. ADR-028's own instance list gains this row (epic docs child).
- **rip-cage ADR-005 D12** — honoured: rc names no tool; recipes under `examples/`.
- **rip-cage ADR-024 D2 / D6** — to be evolved by an epic child: a row for the host-mediated path in the layer table; D6's host-placed shim residual now has a declared, verb-scoped path, which narrows the residual rather than removing it.
- **rip-cage ADR-026 D1 / D4** — honoured: the gatekeeper validates argument *shape* against the declaration and never reads application content or replies; it is admission control on a call, not mediation of a conversation, so D4's "no mediation built into rip-cage" stands.
- **rip-cage ADR-029 D2** — honoured: `host-tool` is a thin client (one JSON line each way), not an in-cage engine; every decision lives host-side in the gatekeeper.
- **rip-cage ADR-029 D3** — one finding is now stale: "msb cannot carry a unix socket mount" is still true, but `--vsock` carries a unix socket *endpoint* without a mount (R3 a1). The ssh-agent retirement stands on its other ground (whole-agent identity leak).
- **rip-cage ADR-029 D5 / ADR-030** — honoured by D5 here.
- **rip-cage ADR-016 D3** — honoured: no `docker.sock`, no port probing; a verb-scoped line is the opposite of a raw socket exposure.
- **`rip-cage-o7tx`** — its host-tool consumer (item 4) moves here; its other consumers stay captured there.

## canonical_refs

- `docs/decisions/ADR-005-ecosystem-tools.md` (rip-cage) — D12 composable seam, never a bundler; governs D1.
- `docs/decisions/ADR-031-opinionated-distribution-of-microsandbox.md` (rip-cage) — D2 amended in place for D2 here; D3 carve-out and converge-on-up used by D6; D5(a) location rule and D5(b) floor probe relied on.
- `docs/decisions/ADR-028-mount-shape-label-lock.md` (rip-cage) — D1 create-time label-lock; the `rc.host-tools` presence label is an instance.
- `docs/decisions/ADR-029-msb-migration.md` (rip-cage) — D2 no in-cage engine (the client is thin); D3 ssh retirement (one finding stale per above); D5 non-possession governs D5 here; D6 platform scoping gates D6 here on macOS.
- `docs/decisions/ADR-024-prompt-injection-threat-model.md` (rip-cage) — D1 injection in scope (the confused-deputy case R2 §4a); D2 layer table to gain a row; D5 self-describing errors (the client's messages); D6 host-placed shim residual narrowed.
- `docs/decisions/ADR-026-containment-mediation-identity.md` (rip-cage) — D1 rc never reads content; D2 drift-rate test behind D4; D4 no mediation in rc; D5 (retired) the seam template D1 follows.
- `docs/decisions/ADR-030-classify-by-use-secret-posture.md` (rip-cage) — possession-mode vocabulary used by D5.
- `docs/decisions/ADR-016-cage-host-network-awareness.md` (rip-cage) — D3 no `docker.sock`.
- `docs/decisions/ADR-008-open-source-publication.md` (rip-cage) — D6 version-staleness check relied on by D6 here.
- `docs/2026-11-06-host-tool-line-R1-prior-art.md`, `-R2-risks.md`, `-R3-msb-native.md` — the evidence base.
- `docs/2026-07-09-msb-spike-lan-ip-host-service.md`, `docs/2026-07-10-current-stack-parity-and-lan-exposure.md` — the rejected LAN-IP channel's measurements.
- `cli/up.sh` — `_up_build_msb_create_argv` (where the flag is appended), `_up_prepare_conf_secret_env` (why the environment is rebuilt), `_up_converge_needed` and the `rc.cage-conf-sha` label (the shape the presence label follows); `share/rip-cage/protected-paths` (gains the projects and state directories).
- Beads: `rip-cage-mgp6` (the sitting; rulings, spike and review record verbatim in its comments and notes), `rip-cage-o7tx` (prior seam capture), `switch-desk` `sd-952` (the consumer's seed).
- `~/.claude/docs/decisions/ADR-008-adr-predicates-and-plan.md` (dotclaude) D1, D5, D8; `~/.claude/docs/decisions/ADR-011-*.md` (dotclaude) D1 — in-place evolution.
