# Spike: guest→host connectivity via the host's real LAN IP under msb (rip-cage-akg5)

Machine: the mac mini, msb v0.6.4 at `/Users/jonatanpi/.local/bin/msb`, image `rip-cage:latest` (Debian 13 trixie guest).

Date: 2026-07-09.

## Setup

- Host LAN IP: `192.168.0.100` (interface `en1`; `en0` had no address — `ipconfig getifaddr en0` exited 1). All decisive probes below dial `192.168.0.100`, never `host.microsandbox.internal` or `127.0.0.1`.
- Host firewall: `socketfilterfw --getglobalstate` → `Firewall is disabled. (State = 0)`.
- `socat` was already present on the host (`/opt/homebrew/bin/socat`, `1.8.1.3`) from the prior ssh-agent spike (rip-cage-r6bo) — **not a new install for this spike**.
- No sandboxes running at start (`msb list` → "No sandboxes found."). All sandboxes in this spike prefixed `lanip-`.
- Central caveat applied throughout (bd memory `msb-netstack-fake-accepts-tcp-connect-not-egress`): msb's userspace netstack fake-accepts disallowed TCP — `connect()` returns success with zero bytes and the real destination is never reached. `connect()` exit 0 is never treated as proof by itself; every claim below is backed by either (a) real application-layer bytes read in-guest AND a matching accept in the host listener's own log, or (b) the two-port discriminating control (a real transport must show *different* behavior — banner+accept vs refused/empty — between a port with a real listener and a port with nothing listening; fake-accept shows both identical, per r6bo's confirmed reproduction).

## Q1 (decisive) — real byte exchange via the LAN IP, with the two-port discriminating control

Host listener bound to the LAN IP, logging verbosely:

```
$ socat -d -d TCP-LISTEN:38765,bind=192.168.0.100,fork SYSTEM:'echo HOSTBANNER-REAL-38765' > /tmp/lanip-spike/host-listener-38765.log 2>&1 &
$ lsof -iTCP:38765 -sTCP:LISTEN -P -n
COMMAND   PID      USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
socat1  89311 jonatanpi    5u  IPv4 ...      0t0  TCP 192.168.0.100:38765 (LISTEN)
```

Guest booted with an explicit allowlist covering **both** the real port (38765) and a definitely-dead port (44444, nothing listening on the host):

```
$ msb run -n lanip-q1 --net-default deny \
    --net-rule "allow@192.168.0.100:tcp:38765,allow@192.168.0.100:tcp:44444" \
    rip-cage:latest -- sh -c 'echo GUEST_UP; id'
GUEST_UP
uid=1000(agent) gid=1000(agent) groups=1000(agent)
```

**Probe A — port 38765 (real host listener), reading actual bytes with `cat`, not bare `connect()`:**

```
$ msb exec lanip-q1 -- bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/192.168.0.100/38765; cat <&3 > /tmp/banner38765.txt"; echo CONNECT_EXIT:$?; cat /tmp/banner38765.txt'
CONNECT_EXIT:0
HOSTBANNER-REAL-38765
```

The guest received the exact literal banner string the host process emits. Host listener's own log (`/tmp/lanip-spike/host-listener-38765.log`), captured independently, shows a real accept for this exact connection:

```
2026/07/09 13:43:01 socat[89311] N accepting connection from LEN=16 AF=2 192.168.0.100:57052 on LEN=16 AF=2 192.168.0.100:38765
2026/07/09 13:43:01 socat[89311] N forked off child process 92442
2026/07/09 13:43:01 socat[92442] N starting data transfer loop with FDs [6,6] and [5,5]
2026/07/09 13:43:01 socat[92442] N socket 2 (fd 5) is at EOF
2026/07/09 13:43:01 socat[92442] N socket 1 (fd 6) is at EOF
2026/07/09 13:43:01 socat[92442] N exiting with status 0
```

**Probe B — port 44444 (nothing listening on the host), same guest, same allowlist, immediately after Probe A:**

```
$ msb exec lanip-q1 -- bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/192.168.0.100/44444; cat <&3 > /tmp/banner44444.txt"; echo CONNECT_EXIT:$?; cat /tmp/banner44444.txt'
CONNECT_EXIT:1
cat: -: Connection reset by peer
```

**Discriminating result:** Probe A (real listener) → `connect()` succeeds, real banner bytes delivered, host-side accept logged. Probe B (dead port, same host, same allowlist) → `connect()` **fails** (exit 1, "Connection reset by peer" — a genuine refusal, no banner). This is the opposite of the fake-accept signature from r6bo (where *both* ports "succeeded" identically with zero host-side accepts). Real transport, real host-kernel-level TCP RST on a closed port, confirmed by two independent lines of evidence (in-guest bytes + host accept log).

**Verdict Q1: WORKS.** Guest→host connections to the host's real LAN IP are NOT fake-accepted by msb's userspace netstack — they are genuinely delivered to a host-bound socket, with real bidirectional byte flow. `host.microsandbox.internal` is a synthetic gateway with fake-accept behavior (per r6bo); the host's actual LAN address is not.

## Q2 — re-run the ssh-agent socat bridge end-to-end via the LAN IP

Host bridge, bound to the LAN IP, connected to the real (unmodified) `$SSH_AUTH_SOCK`:

```
$ socat -d -d TCP-LISTEN:38766,bind=192.168.0.100,fork UNIX-CONNECT:"$SSH_AUTH_SOCK" > /tmp/lanip-spike/host-agent-bridge.log 2>&1 &
$ lsof -iTCP:38766 -sTCP:LISTEN -P -n
socat1  92994 jonatanpi 5u IPv4 ... TCP 192.168.0.100:38766 (LISTEN)
```

Guest booted allowlisting `deb.debian.org` (needed for `apt-get install socat` — no socat in the base image, matches r6bo's net-rule gotcha for DNS-vs-IP-group rules) plus the bridge port on the LAN IP:

```
$ msb run -n lanip-q2 --net-default deny \
    --net-rule "allow@deb.debian.org,allow@192.168.0.100:tcp:38766" \
    rip-cage:latest -- sh -c 'sudo -n apt-get update -qq; sudo -n apt-get install -y -qq socat; which socat; echo INSTALL_EXIT:$?'
...
Setting up socat (1.8.0.3-1) ...
/usr/bin/socat
INSTALL_EXIT:0
```

Confirmed no local keys/agent exist in the guest before bridging (so any successful `ssh-add -l` below can only be relaying the host's agent):

```
$ msb exec lanip-q2 -- sh -c 'ls -la ~/.ssh 2>&1; find / -xdev -iname "id_*" 2>/dev/null'
ls: cannot access '/home/agent/.ssh': No such file or directory
(no id_* key files found on the guest filesystem)
```

Guest-side bridge + `ssh-add -l` through it:

```
$ msb exec lanip-q2 -- bash -c '
    socat UNIX-LISTEN:/tmp/agent-bridge.sock,fork TCP:192.168.0.100:38766 &
    sleep 1
    SSH_AUTH_SOCK=/tmp/agent-bridge.sock ssh-add -l
    echo SSH_ADD_EXIT:$?
'
256 SHA256:KEqjoPqgiOISGenGT/cdCqXwkHCeOqsaYDd/LJBYYEo jonatanpi-mac-mini-work (ED25519)
256 SHA256:hpox/7CN4Lc8RPYLKR1uAu5WWMSkIAOq8L3CkbV2GTs jonatanpi-mac-mini-personal (ED25519)
SSH_ADD_EXIT:0
```

These are the **exact same two fingerprints** as the host's own `ssh-add -l` at the start of the spike — the guest is listing keys it does not itself possess, relayed live through the LAN-IP bridge. Host bridge log confirms a real accept + a real connection opened to the host agent socket:

```
2026/07/09 13:44:43 socat[92994] N accepting connection from LEN=16 AF=2 192.168.0.100:57063 on LEN=16 AF=2 192.168.0.100:38766
2026/07/09 13:44:43 socat[93473] N opening connection to LEN=59 AF=1 "/Users/jonatanpi/.ssh/agent/s.rmDl4VGKLw.agent.nkA3ydgLhz"
2026/07/09 13:44:43 socat[93473] N successfully connected from local address LEN=16 AF=1 ""
2026/07/09 13:44:43 socat[93473] N starting data transfer loop with FDs [6,6] and [5,5]
```

**Completing the arrow** — re-booted the guest (`--replace`) adding `allow@github.com:tcp:22`, reinstalled socat, re-established the bridge, and used it for a real SSH auth + git operation:

```
$ msb exec lanip-q2 -- bash -c '
    socat UNIX-LISTEN:/tmp/agent-bridge.sock,fork TCP:192.168.0.100:38766 &
    sleep 1
    export SSH_AUTH_SOCK=/tmp/agent-bridge.sock
    ssh -T -o StrictHostKeyChecking=accept-new git@github.com
    echo SSH_T_EXIT:$?
    git ls-remote git@github.com:git/git.git HEAD
    echo LS_REMOTE_EXIT:$?
'
Hi jonatan-mapular! You've successfully authenticated, but GitHub does not provide shell access.
SSH_T_EXIT:1
f85a7e662054a7b0d9070e432508831afa214b47	HEAD
LS_REMOTE_EXIT:0
```

(`ssh -T` exit 1 is GitHub's normal "no shell access" response for a successful auth, not a failure — the greeting line is the proof of successful authentication. `git ls-remote` over the SSH transport succeeded with exit 0 and a real ref hash, using only the bridged host agent — no key material of any kind exists in the guest filesystem, confirmed above.)

**Verdict Q2: WORKS, end-to-end.** The ssh-agent socat bridge — declared `NO-VIABLE-PATH` in r6bo purely because it dialed the fake-accepting `host.microsandbox.internal` gateway — is fully functional when the guest dials the host's real LAN IP instead. `ssh-add -l` inside the guest lists the host's real loaded keys, and a real SSH-authenticated git operation against GitHub succeeds through it.

## Q3 — security-shape facts (no decisions)

- **Source-address visibility:** the host bridge's own log shows every guest-originated connection arriving *from the host's own LAN address* (`192.168.0.100:<ephemeral-port>`), not from a distinguishable sandbox-subnet address. (Contrast with r6bo's finding that the guest's *outbound* view assigns it a per-boot `172.16.0.x` address on a subnet with no host-visible interface.) **Fact: the host cannot distinguish an msb-guest-originated connection from any other local host process by source IP** — both present as the host's own address to a listener bound on the LAN IP. `--net-rule` (confirmed again this spike, matching r6bo) has no process/uid dimension, so this is consistent: msb's egress path re-originates guest traffic as ordinary host-local egress, indistinguishable at the TCP-accept layer from any other process on the same box.
- **Other-LAN-machine reachability:** the listener is bound to `192.168.0.100` (the real LAN interface, not loopback), and the macOS Application Firewall is **disabled** (`State = 0`). No second LAN device with shell access was available in this environment to run an actual reachability probe *from* — `arp -a` shows only the router (`kabelbox.local`, `192.168.0.1`) and internal `bridge100`/`bridge102` VM-networking addresses, no other host to log into. **This is recorded as untested** (per the bead's explicit fallback), with the topological fact stated plainly: nothing observed in this spike prevents another device on the same LAN segment from opening a TCP connection to `192.168.0.100:<port>` while the firewall is disabled and the listener is LAN-bound — the exposure is not scoped to "this Mac's local processes only," it is "anything that can route to this LAN IP."
- Firewall state, restated for the record: `socketfilterfw --getglobalstate` → `Firewall is disabled. (State = 0)`.

## Q4 — loopback-only listener (expected negative, defines the exposure floor)

Host listener bound to `127.0.0.1` only:

```
$ socat -d -d TCP-LISTEN:38767,bind=127.0.0.1,fork SYSTEM:'echo HOSTBANNER-LOOPBACK-38767' > /tmp/lanip-spike/host-listener-loopback-38767.log 2>&1 &
```

Guest booted allowlisting `127.0.0.1:tcp:38767` explicitly (so any refusal below is a genuine transport refusal, not an msb policy denial):

```
$ msb run -n lanip-q1 --net-default deny --net-rule "allow@127.0.0.1:tcp:38767" rip-cage:latest -- sh -c 'echo GUEST_UP'
```

```
$ msb exec lanip-q1 -- bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/38767; cat <&3 > /tmp/loopback.txt"; echo CONNECT_EXIT:$?'
CONNECT_EXIT:1
bash: connect: Connection refused
bash: line 1: /dev/tcp/127.0.0.1/38767: Connection refused
```

Host listener's log shows no accept at all across the whole session (only its own boot-time listening line):

```
2026/07/09 13:46:02 socat[94514] N listening on LEN=16 AF=2 127.0.0.1:38767
```

**Verdict Q4: confirmed negative, as expected.** `127.0.0.1` inside the guest is the guest's own loopback, not the host's — a host listener bound to loopback-only is genuinely unreachable from the guest, even with an explicit policy allow. **This defines the exposure floor: LAN-IP binding is required for a guest→host service to work at all; loopback-only binding is not an option for this topology.** Any host service a cage needs to reach must bind to the LAN interface (or an equivalent host-reachable address) — which is exactly the exposure surface documented under Q3.

## Verdict

**WORKS** — real byte exchange proven for Q1 (two-port discriminating control: real listener gets banner+host-side-accept, dead port gets a genuine refusal, not identical fake-accept behavior), and the ssh-agent socat bridge (Q2) re-run end-to-end successfully, including a real SSH-authenticated GitHub operation using only the host's bridged agent.

Facts established, in order:
1. Guest→host TCP to the host's **real LAN IP** is genuinely delivered — not fake-accepted — proven by real application bytes received in-guest, a matching accept in the host listener's independently-captured log, and a discriminating control (a definitely-dead port on the same host, same allowlist, gets a real refusal, not an identical fake success). This reopens both downstream consumers named in the bead:
   - **ssh-agent-bridge design:** the exact socat-bridge topology r6bo declared dead is viable — the only defect was dialing the fake-accepting `host.microsandbox.internal` gateway instead of the host's real LAN address. `ssh-add -l` and a real SSH-authenticated `git ls-remote` against GitHub both succeeded through the bridge, using only host-side key material (confirmed absent from the guest filesystem).
   - **shared-host-service topology** (host-side beads server etc.): the same mechanism — a host process bound to the LAN IP, guest dials that IP with an explicit `--net-rule` allow — is a generically viable guest→host channel, not specific to ssh-agent. Any host-side TCP service reachable at the LAN IP is reachable the same way.
2. The exposure floor is LAN-IP binding, not loopback: a host listener bound to `127.0.0.1` is unreachable from the guest even with an explicit allow rule (Q4, confirmed negative) — so any design building on this must accept the LAN-IP exposure documented in Q3, there is no loopback-only fallback.
3. Security-shape facts for the design/brainstorm to reason over (not decisions): the host cannot distinguish msb-guest-originated connections from other local host processes by source IP (both present as the host's own LAN address); with the firewall disabled and the listener LAN-bound, other-LAN-machine reachability is architecturally plausible but was untested for lack of a second device in this environment — record as an open risk, not a cleared one, for any design that proceeds from this spike.

## Cleanup performed

- All `lanip-` sandboxes stopped and removed: `msb remove --force lanip-q1 lanip-q2` → both reported `Removed`; `msb list` afterward → `No sandboxes found.` (verified fresh, post-cleanup).
- All three host listeners killed by PID (`38765` echo-banner listener, `38766` ssh-agent bridge, `38767` loopback listener) — verified with `lsof -iTCP:38765,38766,38767 -P -n` (empty) and `ps aux | grep -i socat` (empty) after kill.
- No stray `msb exec`/`msb run` host-side processes remained (`ps aux | grep -i "msb "` empty after cleanup).
- Host tool installs: **none new**. `socat` was already installed via `brew install socat` from the prior r6bo spike (`socat 1.8.1.3` present at spike start) — reused, not reinstalled, for this spike.
- Scratch log files retained under `/tmp/lanip-spike/` (host listener logs, referenced verbatim above) for review; these are `/tmp` and will not persist across a reboot — not repo state, no cleanup action needed beyond what's already noted.
