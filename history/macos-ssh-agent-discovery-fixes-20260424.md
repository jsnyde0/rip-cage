# Fixes: macos-ssh-agent-discovery
Date: 2026-04-24
Review passes: 1
Commit under review: cc3be94

## Critical

- **`/workspace/rc`:2080-2259 (`cmd_doctor`)** — `rc doctor`'s ssh-forwarding probe branch never reads `/etc/rip-cage/ssh-agent-socket`. Produces `WARN — agent reachable but empty (host ssh-add -l?)` without naming the mounted socket. **Violates ADR-018 D3 FIRM** ("Banner text and `rc doctor` output read both and incorporate the path into fix hints"). Fix: in the running-container branch of `cmd_doctor`, `docker exec ... cat /etc/rip-cage/ssh-agent-socket` and interpolate the path into the `WARN`/`FAIL` ssh-forwarding messages so they match banner behavior.

- **`/workspace/rc`:1655 + 1272-1275** — On container resume (`cmd_up` for stopped container), `_UP_FORWARD_SSH_HOST_SOCK=""` is set, then `_up_ssh_preflight` unconditionally overwrites `/etc/rip-cage/ssh-agent-socket` with an empty value. The socket is still mounted (bind mounts persist across `docker stop`/`start`), so mount and sentinel diverge. After any `rc down && rc up`, banner shows `Socket: <unknown>` — defeating D3. **Violates ADR-018 D3 FIRM.** Fix: on resume, either (a) recover the original source from `docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/ssh-agent.sock" }}{{ .Source }}{{ end }}{{ end }}' "$name"` and populate `_UP_FORWARD_SSH_HOST_SOCK`, or (b) only include the `ssh-agent-socket` sentinel write in `_up_ssh_preflight`'s `docker exec` when `_UP_FORWARD_SSH_HOST_SOCK` is non-empty (preserves create-time value). Option (a) is preferred — it keeps the sentinel honest even after a cold restart.

## Important

- **`/workspace/rc`:1272-1275** — Shell injection: `_UP_FORWARD_SSH_HOST_SOCK` (derived from host `$SSH_AUTH_SOCK`) is interpolated unescaped into a single-quoted `sh -c` string passed to `docker exec`. A single-quote in the host path (e.g., `/tmp/a'b`) breaks quoting and allows arbitrary shell execution inside the container as root. Low real-world probability but textbook vulnerability. Fix: pass via env var, e.g., `docker exec -u root -e RC_SOCK="$_UP_FORWARD_SSH_HOST_SOCK" -e RC_STATUS="$_status" -e RC_HOST_OS="$_host_os" "$_name" sh -c 'mkdir -p /etc/rip-cage && printf "%s\n" "$RC_STATUS" > /etc/rip-cage/ssh-agent-status && printf "%s\n" "$RC_SOCK" > /etc/rip-cage/ssh-agent-socket && printf "%s\n" "$RC_HOST_OS" > /etc/rip-cage/host-os'`.

- **`/workspace/rc`:858-874** — `_resolve_host_ssh_sock` reads `_rc_forward_ssh` via bash dynamic scoping from caller's `local`. Undocumented API coupling. The inner short-circuit is also redundant (the sole caller gates before calling). Fix: accept `_rc_forward_ssh` as `$1` to make the contract explicit. Keep either the inner guard or outer gate but not both — prefer the outer gate (it's the more natural place).

- **`/workspace/tests/test-ssh-forwarding.sh`:303-327 (Test 8)** — Uses `mktemp /var/folders/rc-test-XXXXXX` which creates a regular file, not a Unix socket. Probe Gate 1 (`[[ -S "$_candidate" ]]`) rejects non-sockets before Gate 2 (the `/var/folders` bind-mount guard) is ever reached. Test passes whether or not the guard exists in code — zero coverage of the actual feature. Fix: create a real Unix socket in `/var/folders/` using `python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('$path')"` (background it), so Gate 1 passes and Gate 2 is exercised. Assert the container's `/ssh-agent.sock` mount source equals candidate #2, not the `/var/folders` path.

- **`/workspace/tests/test-ssh-forwarding.sh`:Tests 5 & 6 cleanup → Test 10** — Tests 5 and 6 run `eval "$(ssh-agent -a ...)"` which exports `SSH_AUTH_SOCK` into the test script's env. Cleanup runs `SSH_AUTH_SOCK=... ssh-agent -k` *without* `eval`, so the `unset` commands never execute. After cleanup, `SSH_AUTH_SOCK` in the test process still points at the now-removed socket. Test 10 (Linux-only) gates on `[[ -n "${SSH_AUTH_SOCK:-}" ]]`, proceeds with a dead socket, probe Gate 1 fails, sentinel is empty, Test 10 fails spuriously. Fix: wrap cleanups with `eval "$(ssh-agent -k 2>/dev/null)"` or explicitly `unset SSH_AUTH_SOCK SSH_AGENT_PID` at the end of each test's cleanup block.

- **`/workspace/zshrc`:59,82 + `/workspace/rc`:1270-1271,1275** — Dead code: `_rc_host_os` is read and unset in zshrc but no `case` branch consumes it. `/etc/rip-cage/host-os` is still written by preflight. Confuses readers. Fix: prefer removal — delete both the zshrc read/unset and the preflight write. (If any future feature wants OS-specific hints, reintroduce then.)

## Minor

- **`/workspace/zshrc`:77-78** — `no_host_agent` banner hint says "run 'ssh-add …' on host, then 'rc down && rc up'" but `rc down && rc up` preserves the `rc.forward-ssh=off` label on resume and skips probing. User needs `rc destroy && rc up` to re-probe. Fix: change the hint for the `no_host_agent` case only (empty/unreachable are correct with `rc down && rc up` because the socket stays mounted).

- **`/workspace/rc`:906,918,927** — `/tmp/rc-probe-out` is written (stdout+stderr of `ssh-add -l`) but never read; only the exit code matters. Fixed path is racy under concurrent `rc up`. Fix: redirect probe output to `/dev/null` and drop both `rm -f /tmp/rc-probe-out` calls.

- **`/workspace/rc`:866-874 (Linux branch of `_resolve_host_ssh_sock`)** — Only checks `[[ -S "$_candidate" ]]`; doesn't probe `ssh-add -l` like macOS does. A stale SSH_AUTH_SOCK (socket exists, agent dead) is mounted anyway. In-container preflight catches this as `unreachable`, so behavior is fine, but the asymmetry is undocumented. Fix: add a one-line comment: `# Linux defers reachability check to the in-container preflight (single candidate, no fallback needed).`

- **`/workspace/tests/test-ssh-forwarding.sh`:329-346 (Test 9 threshold)** — Assertion `(( _t_disabled - _t_probing )) -lt 8` tolerates a single 5s probe firing on the disabled path (5 < 8). Fix: tighten to `-lt 2` so a single probe timeout (5s) causes the test to fail.

## ADR Updates

None. All findings are implementation/test bugs. ADR-018 D1–D3 FIRM decisions are restored to compliance by the Critical-tier fixes above; D4 FLEXIBLE is already handled correctly. No ADR revision needed.

## Discarded

None. Every finding from both reviewers was folded into the fix list. Both reviewers converged on the same three highest-value issues (rc doctor gap, Test 8 bind-mount guard not exercised, `_rc_host_os` dead code), which is a strong signal they're real. The architecture reviewer's BLOCKED verdict was driven by the D3 FIRM violations (findings #1 and #2 above) — those are now tagged Critical in the fix list and will be addressed in the pipeline's fix implementation step.
