# Fixes: ssh-agent-forwarding
Date: 2026-04-23
Review passes: 1 (architecture + implementation in parallel)

## Critical
_none_

## Important

- **rc:998-1004 / rc:1138-1188** — Label-lies-about-wiring (arch #6 + impl #1 combined).
  When the host has no resolvable ssh-agent socket (e.g. Linux with `SSH_AUTH_SOCK`
  unset), the code emits a warning, skips the mount, but still writes
  `rc.forward-ssh=on`. Preflight then classifies the resulting no-socket state
  as `unreachable` and prints a message referencing "socket mounted but not
  reachable" + "VM boundary" — wrong cause, wrong hint for the Linux-no-agent
  user. Fix: when the host socket can't be resolved, set `rc.forward-ssh=off`
  (forwarding was requested but couldn't be wired) and introduce a new sentinel
  value `no_host_agent` so the banner/preflight can distinguish the three cases
  (user opted out vs no host agent vs mounted-but-broken). Track the actual
  wiring outcome via a new `_UP_FORWARD_SSH_WIRED` global read by the preflight.

- **rc:1138-1188** — `ssh-add -l` has no timeout (impl #2). A zombie ssh-agent
  that accepts the connection but never responds would hang `rc up` indefinitely.
  Fix: wrap with `timeout 5 ssh-add -l` inside the container (coreutils
  `timeout` is present in the Debian base image). Exit code 124 maps to
  `unreachable`.

- **rc:1199-1323** — Missing `RIP_CAGE_FORWARD_SSH` env var (arch #1). The
  sibling `rc.egress` pattern supports `RIP_CAGE_EGRESS` as a project-level
  env default plus a CLI override. Forward-ssh has only a flag. Fix: read
  `RIP_CAGE_FORWARD_SSH` with `--no-forward-ssh` overriding, matching egress.
  Also unblocks the rc init / devcontainer parity (rip-cage-akd) by giving
  that code path an env to key off.

## Minor

- **rc:1187** — `_UP_SSH_PREFLIGHT_STATUS` is assigned but never read (arch #3).
  Dead write. Delete the line.

- **rc:1156** — Key-count via `grep -c '^'` on `ssh-add -l 2>&1` is inflatable
  by stderr warnings (arch #7). Fix: use `ssh-add -L` (one public key per
  line, deterministic) or count only fingerprint-matching lines.

- **tests/test-ssh-forwarding.sh:45** — Pre-computed `CONTAINER` name in the
  cleanup trap can drift from the real container name on `rc` collision-hash
  fallback (impl #3). Fix: in the trap, resolve the name via
  `docker ps --filter "label=rc.source.path=..."` instead of the pre-computed
  value.

- **docs/decisions/ADR-017-ssh-agent-forwarding-default.md (Implementation notes)** —
  Sentinel path documented as `/home/agent/.rc-context/ssh-agent-status`; actual
  path is `/etc/rip-cage/ssh-agent-status` (impl #4). Fix: update the ADR to
  match the implementation (the `/etc/rip-cage/` location is the correct one —
  root-owned, consistent with `firewall-env`).

## ADR Updates

- **ADR-017** (Implementation notes): sentinel path corrected to
  `/etc/rip-cage/ssh-agent-status` (was `/home/agent/.rc-context/...`).
- **ADR-017 D4** (Preflight behavior): extend the status taxonomy from four
  values (`ok:N`, `empty`, `unreachable`, `disabled`) to five by adding
  `no_host_agent` — the case where forwarding was on by default but the host
  provided no agent. Makes the warning message accurate per-platform.

## Discarded

- **Arch #2** (`_up_ssh_preflight` couples probe/classify/side-effects): the
  shell-quoting concern was verified by the impl reviewer as non-exploitable
  given the controlled status-value set. Splitting would add indirection
  without a concrete payoff today. Revisit if the sentinel gains more
  writers or the status values become user-controlled.

- **Arch #4** (skip docker roundtrip when forwarding disabled): the saved
  round-trip is measured in single-digit milliseconds and runs once per
  `rc up`. Not worth the refactor.

- **Arch #5** (extract `init-ssh-agent.sh`): the chown is one conditional
  line. The `init-firewall.sh` separation exists because firewall setup is
  a multi-step phase-1-as-root sequence. Single-line posture adjustments
  don't meet that bar.

- **Arch #8** (`is_macos()` helper): only two call sites today. The
  refactor is the natural third-call-site trigger — will land with
  rip-cage-akd (devcontainer parity).
