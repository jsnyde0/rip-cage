# Spike: current-stack (Docker/OrbStack) lock parity + LAN exposure shape (rip-cage-606c)

Facts-only probe spike. Machine: the mac mini. Date: 2026-07-10.

Two question groups:
- **Group A** — does today's Docker/OrbStack path propagate `flock` across the bind-mount
  boundary (A1), and is the image-bd-1.0.5 vs host-bd-1.1.0 skew already breaking in-cage bd
  writes today (A2). Feeds the msb-migration ADR.
- **Group B** — the three unmeasured host-service-seam inputs: source address guest traffic
  presents to a host LAN listener (B1), other-device reachability (B2), offline interface
  behaviour (B3). Feeds the host-service seam design bead.

**No design conclusions here — facts only.** Every claim below is backed by verbatim command
output captured live in this session.

## Verdict summary

| Leg | Verdict |
|---|---|
| **A1** flock across Docker bind-mount | **LOCKS-BROKEN-TOO** — both directions acquired GOT_LOCK while the other side provably held; marker-confirmed overlap. msb is NOT a regression on this axis; the race predates it. |
| **A2** bd version-skew liveness | **SKEW-LIVE** — a single host-1.1.0 write into a guest-1.0.5-initialized store permanently breaks subsequent guest writes (`Error 1105: Field 'id' doesn't have a default value`); a host-1.1.0-initialized store rejects guest writes immediately. In-cage bd writes are already broken/breakable on the current stack. |
| **B1** source address of guest→host traffic | **192.168.0.100** — the host's own LAN IP. Guest traffic is indistinguishable from any host-local process by source IP. Real sentinel banner received in-guest + matching host-side accept logged (not fake-accept). |
| **B2** other-device reachability | **PENDING-OPERATOR** — no same-LAN second device available (operator is remote in London; the mini + its LAN are in Berlin; the operator reaches the mini only over a Tailscale-style tunnel, which cannot reach a listener bound solely to the LAN IP). Not faked. Re-runnable recipe + URL recorded below for whenever a device is physically on the mini's LAN. |
| **B3** offline shape | **UNTESTED-REMOTE-HAZARD** — the mini reaches the LAN over Wi-Fi (`en1` carries both `192.168.0.100` and the default route; `en0` Ethernet is inactive). Toggling Wi-Fi would sever this session; not toggled. Interface/address facts recorded. |

## Environment baseline

```
$ msb --version
msb 0.6.4
$ msb list
No sandboxes found.

$ docker version --format '{{.Server.Version}}'
29.4.0
$ docker images rip-cage
rip-cage:latest     44ab3655f809       4.25GB         1.13GB   U
rip-cage:medproof   aab1c8f2b93d       4.23GB         1.13GB

$ bd version                                   # host
bd version 1.1.0 (Homebrew)
$ docker run --rm rip-cage:latest bd version   # guest baked-in
bd version 1.0.5 (dev: 6a3f515ced18)

$ ipconfig getifaddr en0 ; echo exit:$?
exit:1                                         # en0 has no address
$ ipconfig getifaddr en1 ; echo exit:$?
192.168.0.100
exit:0

$ /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
Firewall is disabled. (State = 0)
$ /usr/libexec/ApplicationFirewall/socketfilterfw --getblockall
Firewall has block all state set to disabled.
```

Image default user is `uid=1000(agent)`; `flock` present (`flock from util-linux 2.41`).

---

## Group A — current-stack (Docker/OrbStack) parity

### A1 — flock propagation across the Docker bind-mount boundary (both directions)

Recipe mirrors the msb virtiofs spike (rip-cage-9iab) Q2 exactly: a scratch host dir
(`/tmp/parity-fixture.54W6fW`, chmod 777, `lockfile` chmod 666) bind-mounted rw at `/workspace`
into a `docker run` from `rip-cage:latest`. Host side uses Python `fcntl.flock` (the same
`flock(2)` syscall the CLI wraps); the container uses `flock -n`. Overlap is confirmed with a
shared marker file and timestamps, **not** sleep-guessing.

#### Direction A — host holds, container tries

Host acquires an exclusive lock and holds ~25s (`nohup`'d):

```
$ nohup python3 parity_lock_hold.py "$FX/lockfile" 25 > parity_hold_A.log 2>&1 &
$ cat parity_hold_A.log     # (final, captured after the run)
HOST_LOCK_ACQUIRED 2026-07-10T15:45:11.749727Z
HOST_LOCK_RELEASED 2026-07-10T15:45:36.758237Z
```

Inside that hold window, the container tries non-blocking:

```
$ docker run --rm -v "$FX":/workspace rip-cage:latest sh -c \
    'date -u +GUEST_TRY_AT=%Y-%m-%dT%H:%M:%SZ; flock -n /workspace/lockfile -c "echo GOT_LOCK"; echo GUEST_FLOCK_EXIT:$?'
GUEST_TRY_AT=2026-07-10T15:45:28Z
GOT_LOCK
GUEST_FLOCK_EXIT:0
```

The container's try at **15:45:28Z** is squarely inside the host's hold window
**[15:45:11.749Z, 15:45:36.758Z]**. **Result: GOT_LOCK — lock NOT respected, direction A.**

#### Direction B — container holds, host tries

The container acquires the lock, touches a virtiofs/bind-mount-shared marker the instant it
holds, sleeps 25s, then removes the marker — so the host can poll for genuine overlap:

```
$ docker run --rm --name parity-hold -v "$FX":/workspace rip-cage:latest sh -c \
    'flock /workspace/lockfile -c "touch /workspace/.guest_holding; echo GUEST_LOCK_ACQUIRED $(date -u ...); sleep 25; ...; rm -f /workspace/.guest_holding"' > parity_hold_B.log 2>&1 &

$ # host polls for the marker
MARKER_PRESENT after 1 polls at 2026-07-10T15:46:03Z
-rw-r--r--  1 jonatanpi  wheel  0 Jul 10 17:46 /tmp/parity-fixture.54W6fW/.guest_holding
$ cat parity_hold_B.log     # (partial, marker already present)
GUEST_LOCK_ACQUIRED 2026-07-10T15:46:00.131898978Z
```

While the marker is present (container provably holding), the host tries non-blocking:

```
$ echo "MARKER_CHECK: $(ls "$FX/.guest_holding")"
MARKER_CHECK: /tmp/parity-fixture.54W6fW/.guest_holding
$ echo "HOST_TRY_AT $(date -u ...)"; python3 parity_lock_try.py "$FX/lockfile"; echo "MARKER_STILL: $(ls "$FX/.guest_holding")"
HOST_TRY_AT 2026-07-10T15:46:14.289726000Z
GOT_LOCK 2026-07-10T15:46:14.330189Z
MARKER_STILL: /tmp/parity-fixture.54W6fW/.guest_holding
```

The marker was confirmed present **immediately before and immediately after** the host's try at
**15:46:14Z** (container held `[15:46:00Z, ~15:46:25Z]`; the marker was removed only after the
container's 25s sleep — confirmed gone afterward: `ls: .../.guest_holding: No such file or directory`).
**Result: GOT_LOCK — lock NOT respected, direction B.**

> Caveat: the container hold log's two `echo` timestamps read identical
> (`GUEST_LOCK_ACQUIRED ...15:46:00.131898978Z` / `GUEST_LOCK_RELEASING ...15:46:00.132656517Z`)
> — a shell-expansion artifact (both `$(date)` substitutions are evaluated at `flock`
> command-parse time, before `sleep 25` runs), NOT evidence of an early release. The
> authoritative overlap proof is the **marker file** (touched inside the flock before the sleep,
> removed inside the flock after it), which was present throughout the host's try. This is exactly
> the marker-based method the bead demanded over sleep-guessing.

**A1 VERDICT: LOCKS-BROKEN-TOO.** An exclusive `flock` held on one side of the Docker bind-mount
does not block a non-blocking attempt on the other side, in either direction, with marker-confirmed
timing overlap. The current Docker/OrbStack path does **not** propagate advisory locks across the
bind-mount boundary either — so on the flock axis, msb's proven non-propagation (9iab Q2) is **not
a regression**; the race predates the migration.

### A2 — bd version-skew liveness on the current Docker stack

Versions (from baseline above): host `bd 1.1.0 (Homebrew)`, guest baked-in
`bd 1.0.5 (dev: 6a3f515ced18)`. All mutations on throwaway git fixtures
(`mktemp -d` → `git init` → empty commit → `bd init`).

#### (i) guest-initialized store, then one interleaved host write

```
# guest-init (bd 1.0.5, in container, fixture at /workspace):
$ docker run --rm -v "$FXG":/workspace -w /workspace rip-cage:latest bd init --non-interactive
  ... ✓ bd initialized successfully!  (Backend: dolt, Mode: embedded)
INIT_EXIT:0

# guest create #1 — OK:
$ docker run --rm -v "$FXG":/workspace -w /workspace rip-cage:latest bd create "guest issue 1" -d "..."
✓ Created issue: workspace-s75 — guest issue 1
CREATE_EXIT:0

# ONE host-side (1.1.0) write into the same store:
$ cd "$FXG" && bd create "host issue interleaved" -d "host 1.1.0 write"
✓ Created issue: workspace-5v0 — host issue interleaved
HOST_CREATE_EXIT:0

# guest create #2, after the host write — FAILS:
$ docker run --rm -v "$FXG":/workspace -w /workspace rip-cage:latest bd create "guest issue 2 after host write" -d "..."
Error: failed to record event for workspace-glk: record event in events: Error 1105: Field 'id' doesn't have a default value
GUEST_CREATE2_EXIT:1
# retry — still broken:
$ docker run --rm -v "$FXG":/workspace -w /workspace rip-cage:latest bd create "guest issue 3 retry" -d "retry"
Error: failed to record event for workspace-0pd: record event in events: Error 1105: Field 'id' doesn't have a default value
GUEST_CREATE3_EXIT:1
```

#### (ii) host-initialized store, one in-cage guest write

```
$ cd "$FXH" && bd init --non-interactive        # host bd 1.1.0
  ... Issue prefix: parity-fix-hostinit_cAlaon
$ docker run --rm -v "$FXH":/workspace -w /workspace rip-cage:latest bd create "guest into host-init store" -d "..."
Error: failed to record event for parity-fix-hostinit_cAlaon-vok: record event in events: Error 1105: Field 'id' doesn't have a default value
GUEST_CREATE_EXIT:1
```

**A2 VERDICT: SKEW-LIVE.** The exact 9iab Q1 error signature — `Error 1105: Field 'id' doesn't
have a default value` — fires on the current Docker/OrbStack stack, both ways:
a single host-1.1.0 write into a guest-1.0.5-initialized store permanently breaks all subsequent
guest writes; and a host-1.1.0-initialized store rejects the very first guest write immediately.
In-cage bd writes are already broken/breakable today; today's "no issues seen" is survivorship
(guest-only or host-only-so-far usage), and the pin-image-bd migration child is urgent.

---

## Group B — LAN exposure shape (msb + host listener)

Setup: host binds `python3 -m http.server 18080 --bind 192.168.0.100`, cwd a scratch dir serving
exactly one file `banner.txt` with the sentinel `LANX-BANNER-1783698539-0fa6b503`.
`http.server` logs client IPs to stderr (`/tmp/parity-listener.log`). Firewall disabled (see
baseline). msb sandbox prefix `lanx-`.

**Fake-accept discipline (bd memory `msb-netstack-fake-accepts`):** msb's userspace netstack
fake-accepts disallowed/unreachable TCP — `connect()` returns success with zero bytes. Every
reachability claim below is backed by the **real sentinel banner body received in-guest AND a
matching host-side accept in the listener's own log**, plus a two-port discriminating control
(a policy-allowed dead port must get a *genuine refusal*, not an identical fake success).

```
$ lsof -iTCP:18080 -sTCP:LISTEN -P -n
Python  37401 jonatanpi    4u  IPv4 ...  TCP 192.168.0.100:18080 (LISTEN)
$ curl -s http://192.168.0.100:18080/banner.txt      # host self-fetch baseline
LANX-BANNER-1783698539-0fa6b503
```

### B1 — source address of guest→host traffic

Sandbox `lanx-src` booted `--net-default deny --net-rule "allow@192.168.0.100:tcp:18080"`
(`uid=1000(agent)`, `curl` present). Guest fetch:

```
$ msb exec lanx-src -- curl -s --max-time 5 http://192.168.0.100:18080/banner.txt
LANX-BANNER-1783698539-0fa6b503
GUEST_CURL_EXIT:0
```

The guest received the exact sentinel body (real bidirectional application data, not
connect()-success). Two-port discriminating control (sandbox re-booted `--replace` with
`allow@192.168.0.100:tcp:18080,allow@192.168.0.100:tcp:44444`; nothing listens on 44444):

```
$ msb exec lanx-src -- curl -s --max-time 5 http://192.168.0.100:18080/banner.txt   # real port
LANX-BANNER-1783698539-0fa6b503
REAL_EXIT:0
$ msb exec lanx-src -- curl -s --max-time 5 http://192.168.0.100:44444/banner.txt   # dead port, policy-allowed
DEAD_EXIT:56
```

Real listener → sentinel banner (exit 0). Dead port, same host, same allowlist → genuine refusal
(`curl exit 56` = failure receiving network data / connection reset), **no banner** — the opposite
of fake-accept's identical zero-byte success. Host listener's own log (peer address per line):

```
$ cat /tmp/parity-listener.log
192.168.0.100 - - [10/Jul/2026 17:49:24] "GET /banner.txt HTTP/1.1" 200 -   # host self-fetch
192.168.0.100 - - [10/Jul/2026 17:49:59] "GET /banner.txt HTTP/1.1" 200 -   # guest B1 fetch
192.168.0.100 - - [10/Jul/2026 17:50:20] "GET /banner.txt HTTP/1.1" 200 -   # guest control fetch
```

Three accepts, all peer `192.168.0.100`; the dead port produced no accept line.

**B1 VERDICT: source address = `192.168.0.100` (the host's own LAN IP).** Guest→host traffic
arrives at a LAN-bound host listener from the host's own LAN address, indistinguishable from any
other host-local process by source IP. (`--net-rule` has no process/uid dimension; msb re-originates
guest egress as ordinary host-local egress.) Fake-accept ruled out by the real sentinel body +
matching fresh host-side accept + the dead-port discriminating refusal.

### B2 — other-device reachability (OPERATOR-ASSISTED)

Not runnable in this round: **no same-LAN second device was available.** The operator is remote in
London while the mini and its `192.168.0.100/24` LAN are in Berlin, reached only over a Tailscale-style
tunnel (`utun2` `100.111.85.79`, see B3). That tunnel cannot answer the "other device on the *same
wifi/LAN*" question, and it cannot reach a listener bound solely to the LAN IP anyway. Per the bead,
this leg is recorded PENDING-OPERATOR rather than faked. The B1 listener was killed at cleanup (nothing
left running).

**Ready-to-run recipe** (for whenever a device is physically on the mini's `192.168.0.x` LAN):

```
# on the mini — bring the listener back up:
D=$(mktemp -d); printf 'LANX-BANNER-RERUN\n' > "$D/banner.txt"
( cd "$D" && python3 -m http.server 18080 --bind 192.168.0.100 ) &
# then from a SECOND device on the same wifi:
curl -s --max-time 5 http://192.168.0.100:18080/banner.txt ; echo " exit:$?"
```

- **Success (REACHABLE-FROM-LAN):** the banner body comes back.
- **Refused/timeout (NOT-REACHABLE):** empty body + curl `exit:56`/`exit:28`. Pair with firewall
  state — firewall is disabled and the listener is LAN-bound, so nothing observed here would itself
  prevent another LAN device from connecting; a NOT-REACHABLE would point at network/AP isolation.

**B2 VERDICT: PENDING-OPERATOR** (no same-LAN device available this round; not faked).

### B3 — offline shape (HAZARD-GUARDED)

```
$ networksetup -listallhardwareports   # (excerpt)
Hardware Port: Ethernet      Device: en0
Hardware Port: Wi-Fi         Device: en1
$ networksetup -getairportpower en1
Wi-Fi Power (en1): On
$ ifconfig en0 | grep -E "status|inet "
	status: inactive               # en0 Ethernet: no inet address
$ ifconfig en1 | grep -E "status|inet "
	inet 192.168.0.100 netmask 0xffffff00 broadcast 192.168.0.255
	status: active
$ route -n get default | grep -E "interface|gateway"
    gateway: 192.168.0.1
  interface: en1
```

The LAN IP `192.168.0.100` **and** the default route both ride `en1` = **Wi-Fi**; `en0` Ethernet
is inactive with no address. Other host addresses present (for the "what offline leaves to bind to"
fact): `lo0` `127.0.0.1`; VM-networking bridges `bridge100` `192.168.139.3`, `bridge101`
`192.168.215.0`, `bridge102` `192.168.97.0`; tunnel `utun2` `100.111.85.79`. If Wi-Fi dropped, `en1`
would lose `192.168.0.100` and the default route, and `en0` offers nothing (inactive) — leaving only
loopback, the host-side VM bridges, and the tunnel address.

**B3 VERDICT: UNTESTED-REMOTE-HAZARD.** The mini is reached over Wi-Fi; toggling Wi-Fi off would
sever the LAN address, the default route, and this session. **Wi-Fi NOT toggled.** Interface/address
facts recorded above.

---

## Safety verification: zero mutations to any real beads store

All bd mutations in this spike targeted throwaway git fixtures under `/tmp/parity-fix-*`, either
host-side or inside the `rip-cage:latest` container with the fixture bind-mounted at `/workspace`.
The only commands run against the real rip-cage / dotpi stores were read-only (`bd show`, `bd list`).

```
# rip-cage repo (bd list | wc -l):   BEFORE 54   →   AFTER 54
# dotpi repo    (bd list | wc -l):   BEFORE 31   →   AFTER 31
```

Both counts unchanged. (Caveat, as in 9iab §8: these repos are actively multi-session/multi-machine
worked; a `bd list` line-count is a coarse proxy and any drift would reflect concurrent sessions, not
this spike. No `bd create`/`update`/`close`/`init` in this session ever named the real rip-cage or
dotpi repo as its working directory or target store.)

---

## Cleanup

Fully cleaned up — **nothing left running or on disk** (the earlier "left up for B2" listener was
killed once B2 resolved to PENDING-OPERATOR):
- `msb remove --force lanx-src` — removed; `msb list` → `No sandboxes found.`
- Docker scratch containers: all `docker run --rm` (auto-removed); `parity-hold` exited and was
  auto-removed; `docker ps -a --filter name=parity` → empty.
- B1/B2 host listener (was PID 37401, `python3 -m http.server 18080 --bind 192.168.0.100`) —
  killed; `ps -p 37401` → no such process, `lsof -iTCP:18080 -sTCP:LISTEN` → empty (port free).
- Throwaway fixtures removed by the worker via `find … -delete` (no DCG block hit):
  `/tmp/parity-fixture.54W6fW`, `/tmp/parity-fix-guestinit.I5OgAF`, `/tmp/parity-fix-hostinit.cAlaon`.
- B1/B2 serve dir `/tmp/parity-lanx-serve.aQzrHd` removed via `find … -delete`; all scratch
  helper/log/path files (`/tmp/parity_lock_*.py`, `/tmp/parity_hold_*.log`, `/tmp/parity-listener.log`,
  `/tmp/parity-*-path.txt`, `/tmp/parity-sentinel.txt`, `/tmp/parity-listener-pid.txt`) removed via
  `rm -f`. `ls -d /tmp/parity*` → no matches. No DCG-blocked removals; nothing left for the operator.
